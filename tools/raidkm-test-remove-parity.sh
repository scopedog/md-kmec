#!/bin/bash
#
# raidkm-test-remove-parity.sh — classic remove-parity gate (m -> m-1 via the
# online COW walk; remove-parity-design.md).  k is fixed, so capacity must be
# UNCHANGED and every row re-encodes in place at the new rotation.
#
#   T1  happy path m=3->2 (rotating) via mdadm --grow --remove-parity:
#       completes online, data byte-exact, capacity unchanged, settled scrub
#       clean, raid_disks collapsed.
#   T2  decode oracle at the NEW m: fail m-1 members -> reconstruct; freed
#       member -> spare -> removable; survivors-only reassemble persists.
#   T3  same happy path on PARITY_N (uniform COW covers both layouts).
#   T4  m=4->3 (rotating) — crosses the Cauchy->Vandermonde threshold; the
#       COW re-encode makes it a non-event.  Decode oracle at 3.
#   T5  guard: m=2 -> --remove-parity refused (new_m >= 2 floor).
#   T7  csum: remove-parity on a --checksum array -> zero mismatches on full
#       re-read + the csum layout bit SURVIVES (--examine crc32c) — proves
#       the m-only layout-word rule + band re-key.
#   T8  crash: --stop mid-walk -> reassemble -> journal recovery resumes ->
#       completes; data + settled scrub + decode.
#
# Env: RP_N (default 7 -> k=4 at m=3), PATMB, SYNC_MAX_KB.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${RP_N:-7}			# m=3 -> k=4
PATMB=${PATMB:-24}
SPEED=${SYNC_MAX_KB:-2000}

rk_load_modules || exit 1
rk_setup_brd "$((N + 1))" || exit 1	# +1 for the m=4 case
MEMBERS_ALL=($(rk_pick_disks "$((N + 1))"))
MEMBERS=("${MEMBERS_ALL[@]:0:$N}")

mkarray() {	# mkarray <layout> [members...]
	local layout="$1"; shift
	rk_create "$layout" "$@" || return 1
	rk_wait_idle
	sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
	sync
	PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
	OLD_SIZE=$(cat /sys/block/$MDNAME/size)
}
read_md5() {
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null |
		md5sum | cut -d' ' -f1
}
wait_reshape_done() {
	local i
	for i in $(seq 1 240); do
		grep -q reshape /proc/mdstat || return 0
		sleep 2
	done
	return 1
}
scrub_settled() {
	local d0 i
	sleep 3
	d0=$(sudo dmesg | grep -c "check done")
	echo check | sudo tee "/sys/block/$MDNAME/md/sync_action" >/dev/null
	for i in $(seq 1 600); do
		[ "$(sudo dmesg | grep -c 'check done')" -gt "$d0" ] && {
			cat "/sys/block/$MDNAME/md/mismatch_cnt"; return 0
		}
		sleep 0.5
	done
	echo "check-never-completed"
}
remove_parity() {	# remove_parity -> 0 if started
	sudo "$MDADM" --grow "$MD" --remove-parity >/dev/null 2>&1
}
verify_after() {	# verify_after <tag> <want_m> <want_n>
	local tag="$1" want_m="$2" want_n="$3" mm nd
	[ "$PRE" = "$(read_md5)" ] && rk_pass "$tag: data intact" \
				   || rk_fail "$tag: DATA MISMATCH"
	[ "$(cat /sys/block/$MDNAME/size)" = "$OLD_SIZE" ] &&
		rk_pass "$tag: capacity unchanged (k fixed)" ||
		rk_fail "$tag: capacity moved ($OLD_SIZE -> $(cat /sys/block/$MDNAME/size))"
	nd=$(sudo "$MDADM" --detail "$MD" | sed -n 's/.*Raid Devices : \([0-9]*\).*/\1/p')
	[ "$nd" = "$want_n" ] && rk_pass "$tag: raid_disks now $want_n" \
			      || rk_fail "$tag: raid_disks=$nd (want $want_n)"
	mm=$(scrub_settled)
	[ "$mm" = 0 ] && rk_pass "$tag: settled scrub clean" \
		      || rk_fail "$tag: scrub mismatch_cnt=$mm"
}

# ---- T1: rotating m=3 -> 2 ---------------------------------------------------
echo "MARK T1" | sudo tee /dev/kmsg >/dev/null
echo "=== T1: m=3->2 rotating (N=$N -> $((N-1)), k fixed) ==="
mkarray 3r "${MEMBERS[@]}" || { rk_fail "T1: create"; rk_summary; exit 1; }
if remove_parity; then
	rk_pass "T1: remove-parity started (online)"
	wait_reshape_done || { rk_fail "T1: reshape did not finish"; rk_summary; exit 1; }
	verify_after "T1" 2 "$((N-1))"
else
	rk_fail "T1: mdadm --grow --remove-parity rejected"; rk_summary; exit 1
fi

# ---- T2: decode oracle + ejection + persistence ------------------------------
echo "MARK T2" | sudo tee /dev/kmsg >/dev/null
echo "=== T2: freed member -> spare -> removable; survivors persist; decode at m=2 ==="
freed=0
for d in "${MEMBERS[@]}"; do
	state=$(cat /sys/block/$MDNAME/md/dev-${d##*/}/state 2>/dev/null)
	[ "$state" = "spare" ] || continue
	for i in $(seq 1 30); do
		sudo "$MDADM" --remove "$MD" "$d" >/dev/null 2>&1 && { freed=1; FREED_DEV=$d; break; }
		sleep 1
	done
done
[ "$freed" = 1 ] && rk_pass "T2: freed member removable ($FREED_DEV)" \
		 || rk_fail "T2: no freed spare found/removable"
sudo "$MDADM" --zero-superblock "$FREED_DEV" 2>/dev/null
SURV=(); for d in "${MEMBERS[@]}"; do [ "$d" = "${FREED_DEV:-}" ] || SURV+=("$d"); done
sudo "$MDADM" --stop "$MD" 2>/dev/null; sudo udevadm settle 2>/dev/null
sudo "$MDADM" --stop --scan 2>/dev/null; sudo udevadm settle 2>/dev/null
sudo "$MDADM" --assemble "$MD" "${SURV[@]}" >/dev/null 2>&1 &&
	grep -q "$MDNAME : active" /proc/mdstat &&
	rk_pass "T2: survivors-only assemble" || rk_fail "T2: assemble failed"
[ "$PRE" = "$(read_md5)" ] && rk_pass "T2: data persists across re-assemble" \
			   || rk_fail "T2: data lost on re-assemble"
for d in "${SURV[@]:0:2}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
deg=$(cat /sys/block/$MDNAME/md/degraded)
[ "$deg" = 2 ] && [ "$PRE" = "$(read_md5)" ] &&
	rk_pass "T2: degraded-decode m=2 EC-correct" ||
	rk_fail "T2: degraded-decode failed (deg=$deg)"

# ---- T3: PARITY_N m=3 -> 2 ---------------------------------------------------
echo "MARK T3" | sudo tee /dev/kmsg >/dev/null
echo "=== T3: m=3->2 PARITY_N (uniform online COW) ==="
mkarray 3 "${MEMBERS[@]}" || { rk_fail "T3: create"; rk_summary; exit 1; }
if remove_parity && wait_reshape_done; then
	verify_after "T3" 2 "$((N-1))"
	for d in "${MEMBERS[@]:1:2}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
	[ "$PRE" = "$(read_md5)" ] && rk_pass "T3: degraded-decode m=2 EC-correct" \
				   || rk_fail "T3: degraded-decode failed"
else
	rk_fail "T3: PARITY_N remove-parity did not start/finish"
fi

# ---- T4: m=4 -> 3 (Cauchy -> Vandermonde threshold) --------------------------
echo "MARK T4" | sudo tee /dev/kmsg >/dev/null
echo "=== T4: m=4->3 rotating (N=$((N+1)) -> $N; crosses the Cauchy/Vandermonde boundary) ==="
mkarray 4r "${MEMBERS_ALL[@]}" || { rk_fail "T4: create m=4"; rk_summary; exit 1; }
if remove_parity && wait_reshape_done; then
	verify_after "T4" 3 "$N"
	for d in "${MEMBERS_ALL[@]:0:3}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
	[ "$PRE" = "$(read_md5)" ] && rk_pass "T4: degraded-decode m=3 EC-correct (re-encoded Vandermonde)" \
				   || rk_fail "T4: degraded-decode failed"
else
	rk_fail "T4: m=4->3 remove-parity did not start/finish"
fi

# ---- T5: m=2 floor -----------------------------------------------------------
echo "MARK T5" | sudo tee /dev/kmsg >/dev/null
echo "=== T5: m=2 -> --remove-parity must be refused ==="
mkarray 2r "${MEMBERS[@]:0:$((N-1))}" || { rk_fail "T5: create"; rk_summary; exit 1; }
if remove_parity; then
	rk_fail "T5: remove-parity ACCEPTED at m=2"
	wait_reshape_done
else
	rk_pass "T5: refused at m=2 (floor holds)"
fi

# (No mid-walk member-failure leg: the COW band's migrate-read is
#  non-degraded-only — the inherited classic gap, reshape-cow-design §6/§9 —
#  so a failure DURING the walk stalls the band-retry loop until healed.
#  The has_failed() min(old_m,new_m) tolerance fix is review-validated;
#  degraded start is refused by the driver + kernel gates as everywhere.)

# ---- T7: csum ----------------------------------------------------------------
echo "MARK T7" | sudo tee /dev/kmsg >/dev/null
echo "=== T7: remove-parity on --checksum: zero mismatches + csum bit survives ==="
RK_CREATE_EXTRA="--checksum" mkarray 3r "${MEMBERS[@]}" ||
	{ rk_fail "T7: create --checksum"; rk_summary; exit 1; }
rk_dmesg_clear
if remove_parity && wait_reshape_done; then
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo dd if="$MD" of=/dev/null bs=1M iflag=direct status=none 2>/dev/null
	storm=$(sudo dmesg | grep -c "native csum mismatch")
	[ "$storm" = 0 ] && rk_pass "T7: zero csum mismatches on full re-read (re-key correct)" \
			 || rk_fail "T7: $storm csum mismatches (stale-key storm)"
	sudo "$MDADM" --examine "${MEMBERS[0]}" 2>/dev/null | grep -q "crc32c" &&
		rk_pass "T7: csum layout bit survived the m-change" ||
		rk_fail "T7: csum layout bit LOST (m-only word rule broken)"
	[ "$PRE" = "$(read_md5)" ] && rk_pass "T7: data intact" || rk_fail "T7: DATA MISMATCH"
else
	rk_fail "T7: csum remove-parity did not start/finish"
fi

# ---- T8: crash / resume ------------------------------------------------------
echo "MARK T8" | sudo tee /dev/kmsg >/dev/null
echo "=== T8: --stop mid-walk -> reassemble -> journal recovery -> completes ==="
mkarray 3r "${MEMBERS[@]}" || { rk_fail "T8: create"; rk_summary; exit 1; }
echo "$SPEED" | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
if remove_parity; then
	stopped=0
	for i in $(seq 1 120); do
		# right after sync_action=reshape mdstat briefly shows
		# "resync=DELAYED" with no "reshape" string — only break once
		# NEITHER marker is present (the walk truly finished)
		grep -qE "reshape|DELAYED" /proc/mdstat || break
		pct=$(sed -n 's/.*reshape = *\([0-9]*\)\..*/\1/p' /proc/mdstat)
		[ -z "$pct" ] && { sleep 1; continue; }
		if [ "$pct" -ge 20 ] && [ "$pct" -le 75 ]; then
			sudo "$MDADM" --stop "$MD" >/dev/null 2>&1 && stopped=1
			break
		fi
		sleep 1
	done
	[ "$stopped" = 1 ] && rk_pass "T8: stopped mid-walk (~${pct}%)" \
			   || { rk_fail "T8: could not stop mid-walk"; rk_summary; exit 1; }
	rk_dmesg_clear
	sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]}" >/dev/null 2>&1 &&
		grep -q "$MDNAME : active" /proc/mdstat ||
		{ rk_fail "T8: reassemble failed"; sudo dmesg | tail -8; rk_summary; exit 1; }
	sudo dmesg | grep -qiE "reshape.*(recover|resum)|resuming reshape|md: reshape" &&
		rk_pass "T8: reshape resumed on reassemble" ||
		rk_fail "T8: no reshape resume evidence in dmesg"
	echo 2000000 | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
	wait_reshape_done || { rk_fail "T8: resumed reshape did not finish"; rk_summary; exit 1; }
	verify_after "T8" 2 "$((N-1))"
	for d in "${MEMBERS[@]:2:2}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
	[ "$PRE" = "$(read_md5)" ] && rk_pass "T8: degraded-decode after crash+resume" \
				   || rk_fail "T8: degraded-decode failed"
else
	rk_fail "T8: remove-parity did not start"
fi

sudo "$MDADM" --stop "$MD" 2>/dev/null
sudo udevadm settle 2>/dev/null
for d in "${MEMBERS_ALL[@]}"; do sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
sudo dmesg | grep -iE "WARN|BUG|gf_invert" | tail -3 || true
rk_summary
