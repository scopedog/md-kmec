#!/bin/bash
#
# raidkm-test-declustered-shrink.sh — declustered POOL SHRINK gate
# (dcl-shrink-design.md D1): N -> N-g (one group removed, g/m/s and the layout
# word fixed, ngroups drops by 1) via the BACKWARD COW walk, driven by the
# rk_dcl_reshape trigger (the mdadm driver is a separate change).
#
#   T1  array-size-first enforced: the shrink trigger WITHOUT the
#       --array-size clamp is refused, and no reshape starts.
#   T5  guard rails (runs right after T1, while the array is still N wide):
#       a non-quantum shrink (more than one group at once) is rejected.
#   T2  happy path: clamp + shrink N->N-g; data byte-exact, scrub clean,
#       capacity dropped to the new geometry and raid_disks to N-g.
#   T4  the departing members are demoted to SPARES by the finalize:
#       removable, zeroable, and the array reassembles from the survivors
#       with size + data intact.  Runs BEFORE the failure tests — freed
#       spares left in the array are legitimate hot-spare rebuild targets
#       for any later member failure, which is exactly the admin flow the
#       mdadm driver will steer away from (remove the freed members first).
#   T3  decode oracle on the reassembled survivors-only array: fail m
#       members -> degraded read must reconstruct byte-exact (test the
#       DECODE, not just scrub).
#   T6  same happy path at m=3.
# Scrubs use the settled idiom (wait for a NEW "check done." in dmesg) —
# mismatch_cnt read after an INTR'd check is garbage.
#
# Env: DCL_N/DCL_G/DCL_M/DCL_S/DCL_NBASE/DCL_SEED/DCL_NEWSEED/PATMB.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-20}; G=${DCL_G:-6}; M=${DCL_M:-2}; S=${DCL_S:-2}
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}; NEWSEED=${DCL_NEWSEED:-0x77}
PATMB=${PATMB:-48}

NEWN=$(( N - G ))
OLD_NG=$(( (N - S) / G ))
NEW_NG=$(( (NEWN - S) / G ))
TRIG=/sys/block/$MDNAME/md/rk_dcl_reshape

rk_load_modules || exit 1
rk_setup_brd "$N" || exit 1
MEMBERS=($(rk_pick_disks "$N"))

wipe_members() {
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	sudo udevadm settle 2>/dev/null
	for d in "${MEMBERS[@]}"; do
		sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
		sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
	sudo udevadm settle 2>/dev/null
}

mk_dcl() {	# $1 = m
	local m=$1
	sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$m \
		--layout=declustered --group-width=$G --spare-columns=$S \
		--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
		--raid-devices=$N "${MEMBERS[@]}" --run >/dev/null 2>&1 &&
	grep -q "$MDNAME : active" /proc/mdstat || return 1
	rk_wait_idle
	sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
	sync; PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
	OLD_SIZE=$(cat /sys/block/$MDNAME/size)
	NEW_SIZE_EXPECT=$(( OLD_SIZE * NEW_NG / OLD_NG ))
	return 0
}

read_md5() {
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null |
		md5sum | cut -d' ' -f1
}

wait_trigger_idle() {
	local i
	for i in $(seq 1 240); do
		case "$(cat "$TRIG" 2>/dev/null)" in idle*) return 0;; esac
		sleep 2
	done
	return 1
}

# scrub that waits for a NEW "check done." — a check INTR'd by md's reap
# leaves garbage in mismatch_cnt (kmec scrub-after-reshape race)
scrub_settled() {
	local d0 i
	d0=$(sudo dmesg | grep -c "check done")
	echo check | sudo tee "/sys/block/$MDNAME/md/sync_action" >/dev/null
	for i in $(seq 1 600); do
		[ "$(sudo dmesg | grep -c 'check done')" -gt "$d0" ] && {
			cat "/sys/block/$MDNAME/md/mismatch_cnt"
			return 0
		}
		sleep 0.5
	done
	echo "check-never-completed"
}

# ---- T1: array-size-first is enforced ---------------------------------------
echo "MARK T1" 2>/dev/null | sudo tee /dev/kmsg >/dev/null
echo "=== T1: shrink N=$N->$NEWN without the --array-size clamp must be refused ==="
wipe_members
mk_dcl "$M" || { rk_fail "T1: create"; rk_summary; exit 1; }
if echo "$NEWN:$NEWSEED" | sudo tee "$TRIG" >/dev/null 2>&1; then
	rk_fail "T1: shrink STARTED without the array-size clamp"
	wait_trigger_idle
else
	rk_pass "T1: shrink refused without the clamp"
fi
grep -q reshape /proc/mdstat && rk_fail "T1: a reshape is running" \
			     || rk_pass "T1: no reshape started"

# ---- T5: guard rails (while the array is still N=20) -------------------------
# quantum precedes the array-size gate in the trigger, so this rejection is
# deterministic even with the array unclamped
echo "MARK T5" 2>/dev/null | sudo tee /dev/kmsg >/dev/null
TWO=$(( N - 2 * G ))
echo "=== T5: non-quantum shrink N=$N->$TWO (two groups at once) must be rejected ==="
if echo "$TWO:$NEWSEED" | sudo tee "$TRIG" >/dev/null 2>&1; then
	rk_fail "T5: two-group shrink accepted (v1 quantum is one group)"
	wait_trigger_idle
else
	rk_pass "T5: two-group shrink rejected (v1 quantum enforced)"
fi

# ---- T2: clamp + happy path --------------------------------------------------
echo "MARK T2" 2>/dev/null | sudo tee /dev/kmsg >/dev/null
echo "=== T2: clamp to $((NEW_SIZE_EXPECT / 2)) KB then shrink N=$N->$NEWN (ngroups $OLD_NG->$NEW_NG, m=$M) ==="
sudo "$MDADM" --grow "$MD" --array-size="$(( NEW_SIZE_EXPECT / 2 ))" >/dev/null 2>&1 ||
	{ rk_fail "T2: --array-size clamp failed"; rk_summary; exit 1; }
echo "$NEWN:$NEWSEED" | sudo tee "$TRIG" >/dev/null 2>&1 ||
	{ rk_fail "T2: shrink trigger rejected after the clamp"; rk_summary; exit 1; }
rk_pass "T2: shrink started (backward COW)"
wait_trigger_idle || { rk_fail "T2: reshape did not finish"; sudo dmesg | tail -8; rk_summary; exit 1; }
rk_pass "T2: shrink completed"
[ "$PRE" = "$(read_md5)" ] && rk_pass "T2: data intact across the shrink" \
			   || rk_fail "T2: DATA MISMATCH"
mm=$(scrub_settled); [ "$mm" = 0 ] && rk_pass "T2: scrub clean over the re-laid rows" \
			           || rk_fail "T2: scrub mismatch_cnt=$mm"
NEW_SIZE=$(cat /sys/block/$MDNAME/size)
[ "$NEW_SIZE" = "$NEW_SIZE_EXPECT" ] &&
	rk_pass "T2: capacity dropped to the new geometry ($OLD_SIZE -> $NEW_SIZE sectors)" ||
	rk_fail "T2: capacity $NEW_SIZE (want $NEW_SIZE_EXPECT)"
ndisks=$(sudo "$MDADM" --detail "$MD" | sed -n 's/.*Raid Devices : \([0-9]*\).*/\1/p')
[ "$ndisks" = "$NEWN" ] && rk_pass "T2: raid_disks now $NEWN" \
			|| rk_fail "T2: raid_disks=$ndisks (want $NEWN)"

# ---- T4: departing members ejected; survivors reassemble ---------------------
echo "MARK T4" 2>/dev/null | sudo tee /dev/kmsg >/dev/null
echo "=== T4: departing members (slots >= $NEWN) ejected + survivors-only reassemble ==="
# the ejected slots are demoted to spares by md_check_recovery AFTER the
# finalize — --remove races that, so retry until each departing member
# detaches (the finalize itself only clears In_sync)
freed=0
for d in "${MEMBERS[@]:$NEWN}"; do
	for i in $(seq 1 30); do
		sudo "$MDADM" --remove "$MD" "$d" >/dev/null 2>&1 &&
			{ freed=$((freed + 1)); break; }
		sleep 1
	done
done
[ "$freed" = "$G" ] && rk_pass "T4: all $G departing members removable" \
		    || { rk_fail "T4: only $freed/$G departing members removable"
			 grep -H . /sys/block/$MDNAME/md/dev-*/state 2>/dev/null | sed 's/^/      · /'; }
for d in "${MEMBERS[@]:$NEWN}"; do sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
sudo "$MDADM" --stop "$MD" 2>/dev/null; sudo udevadm settle 2>/dev/null
# udev may have incremental-assembled the just-freed members into an inactive
# md holding them busy — stop strays before the survivors-only assemble
sudo "$MDADM" --stop --scan 2>/dev/null; sudo udevadm settle 2>/dev/null
sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]:0:$NEWN}" >/dev/null 2>&1 &&
	grep -q "$MDNAME : active" /proc/mdstat &&
	rk_pass "T4: survivors-only assemble" || rk_fail "T4: assemble from $NEWN survivors failed"
[ "$(cat /sys/block/$MDNAME/size)" = "$NEW_SIZE_EXPECT" ] &&
	rk_pass "T4: capacity persists across re-assemble" || rk_fail "T4: capacity not persisted"
[ "$PRE" = "$(read_md5)" ] && rk_pass "T4: data persists across re-assemble" \
			   || rk_fail "T4: data lost on re-assemble"
sudo "$MDADM" --examine "${MEMBERS[0]}" | grep -q "Raid Devices : $NEWN" &&
	rk_pass "T4: new pool size persisted (--examine N=$NEWN)" ||
	rk_fail "T4: --examine does not show Raid Devices : $NEWN"

# ---- T3: decode oracle on the survivors-only array ---------------------------
echo "MARK T3" 2>/dev/null | sudo tee /dev/kmsg >/dev/null
echo "=== T3: fail m=$M members of the reassembled array -> degraded decode ==="
for d in "${MEMBERS[@]:0:$M}"; do
	sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1
done
deg=$(cat /sys/block/$MDNAME/md/degraded)
DEG=$(read_md5)
[ "$deg" = "$M" ] && [ "$PRE" = "$DEG" ] &&
	rk_pass "T3: degraded-decode m=$M EC-correct post-shrink" ||
	rk_fail "T3: degraded-decode failed (deg=$deg want $M)"

# ---- T6: happy path at m=3 ---------------------------------------------------
echo "MARK T6" 2>/dev/null | sudo tee /dev/kmsg >/dev/null
echo "=== T6: shrink at m=3 (k=$((G-3)), decode-side coverage) ==="
wipe_members
if mk_dcl 3; then
	sudo "$MDADM" --grow "$MD" --array-size="$(( NEW_SIZE_EXPECT / 2 ))" >/dev/null 2>&1
	if echo "$NEWN:$NEWSEED" | sudo tee "$TRIG" >/dev/null 2>&1 && wait_trigger_idle; then
		[ "$PRE" = "$(read_md5)" ] && rk_pass "T6: m=3 shrink data intact" \
					   || rk_fail "T6: m=3 DATA MISMATCH"
		mm=$(scrub_settled); [ "$mm" = 0 ] && rk_pass "T6: m=3 scrub clean" \
						   || rk_fail "T6: m=3 scrub mismatch_cnt=$mm"
		for d in "${MEMBERS[@]:0:3}"; do
			sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1
		done
		[ "$(read_md5)" = "$PRE" ] && rk_pass "T6: m=3 degraded-decode EC-correct" \
					   || rk_fail "T6: m=3 degraded-decode failed"
	else
		rk_fail "T6: m=3 shrink did not start/finish"
	fi
else
	rk_fail "T6: m=3 create failed"
fi

# ---- T7: mdadm drivers (pool shrink + spare-count increase) ------------------
echo "MARK T7" 2>/dev/null | sudo tee /dev/kmsg >/dev/null
echo "=== T7: mdadm --grow --raid-devices=$NEWN (refusal UX + happy path) ==="
wipe_members
if mk_dcl "$M"; then
	out=$(sudo "$MDADM" --grow "$MD" --raid-devices="$NEWN" 2>&1)
	if [ $? -ne 0 ] && grep -q -- "--array-size=" <<< "$out"; then
		rk_pass "T7: mdadm refused without the clamp AND printed the exact --array-size"
	else
		rk_fail "T7: mdadm refusal UX wrong: $out"
	fi
	sudo "$MDADM" --grow "$MD" --array-size="$(( NEW_SIZE_EXPECT / 2 ))" >/dev/null 2>&1
	if sudo "$MDADM" --grow "$MD" --raid-devices="$NEWN" >/dev/null 2>&1; then
		rk_pass "T7: mdadm-driven pool shrink started"
		wait_trigger_idle || rk_fail "T7: mdadm-driven shrink did not finish"
		[ "$PRE" = "$(read_md5)" ] && rk_pass "T7: data intact (mdadm-driven shrink)" \
					   || rk_fail "T7: DATA MISMATCH (mdadm-driven)"
		ndisks=$(sudo "$MDADM" --detail "$MD" | sed -n 's/.*Raid Devices : \([0-9]*\).*/\1/p')
		[ "$ndisks" = "$NEWN" ] && rk_pass "T7: raid_disks $NEWN via mdadm" \
					|| rk_fail "T7: raid_disks=$ndisks"
		# s-increase via mdadm on the shrunk array: s=2->8 on N=14
		# ((14-8)%6==0, ngroups 2->1, capacity halves)
		S2=8
		cur=$(cat /sys/block/$MDNAME/size)
		clamp2=$(( cur * ((NEWN - S2) / G) / ((NEWN - S) / G) ))
		out=$(sudo "$MDADM" --grow "$MD" --spare-columns="$S2" 2>&1)
		if [ $? -ne 0 ] && grep -q -- "--array-size=" <<< "$out"; then
			rk_pass "T7: s-increase refused without the clamp (actionable)"
		else
			rk_fail "T7: s-increase refusal UX wrong: $out"
		fi
		sudo "$MDADM" --grow "$MD" --array-size="$(( clamp2 / 2 ))" >/dev/null 2>&1
		if sudo "$MDADM" --grow "$MD" --spare-columns="$S2" >/dev/null 2>&1; then
			rk_pass "T7: mdadm-driven s-increase started"
			wait_trigger_idle || rk_fail "T7: s-increase did not finish"
			[ "$PRE" = "$(read_md5)" ] && rk_pass "T7: data intact (mdadm s-increase)" \
						   || rk_fail "T7: DATA MISMATCH (s-increase)"
			sudo "$MDADM" --examine "${MEMBERS[0]}" | grep -q "$S2 spare column" &&
				rk_pass "T7: s=$S2 persisted (--examine)" ||
				rk_fail "T7: s not persisted"
		else
			rk_fail "T7: mdadm-driven s-increase rejected with the clamp"
		fi
	else
		rk_fail "T7: mdadm-driven pool shrink rejected with the clamp in place"
	fi
else
	rk_fail "T7: create failed"
fi

wipe_members
sudo dmesg | grep -iE "WARN|BUG|gf_invert" | tail -3 || true
rk_summary
