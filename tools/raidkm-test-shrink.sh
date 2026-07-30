#!/bin/bash
#
# raidkm-test-shrink.sh — shrink-data (k -> k-1, m fixed, delta_disks = -1)
# via the BACKWARD COW reshape (raidkm_reshape_cow_shrink; see
# notes shrink-data-design.md).  Driven at the sysfs level (the mdadm
# raidkm_shrink_data driver is a separate change): --array-size clamp first,
# then raid_disks-1, then sync_action=reshape.
#
#   T1  array-size-first enforced: a raid_disks decrease WITHOUT the
#       --array-size clamp is refused (raid5_start_reshape size gate).
#   T2  happy path, rotating m=2: clamp, shrink k=4->3 online, data
#       byte-exact, scrub clean, geometry persists across stop/re-assemble,
#       the freed member becomes a spare and can be removed + reused.
#   T3  decode oracle at the shrunk geometry: fail m members one at a time
#       -> data still byte-exact (the re-encoded parity is genuinely
#       EC-correct — scrub alone is insufficient).
#   T4  same happy path on parity-last (PARITY_N) and at m=3.
#   T5  v1 scope: delta_disks < -1 rejected.
#   T6  concurrent I/O: fio randwrite+verify racing a throttled shrink —
#       the backward frontier serves ahead (below) as OLD geometry and
#       behind (above) as new while bands migrate.
#
# Usage: bash <this>
set -u
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${SH_N:-6}; M=${SH_M:-2}		# k=4 -> 3
PATMB=${PATMB:-24}
MEMBERS=()

cleanup() {
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	local d
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
}
trap cleanup EXIT

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
rk_setup_brd "$N" || exit 1
DISKS=$(rk_pick_disks "$N") || { echo "ERROR: need $N devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

new_capacity_kb() {	# capacity of the shrunk geometry, in KiB (k-1 data disks)
	local dev_kb
	dev_kb=$(( $(sudo "$MDADM" --detail "$MD" | sed -n 's/.*Used Dev Size : \([0-9]*\).*/\1/p') ))
	echo $(( dev_kb * (N - M - 1) ))
}
start_shrink() {	# stage delta=-1 + kick the reshape; echo err text on failure
	local i
	if ! echo $((N - 1)) | sudo tee /sys/block/$MDNAME/md/raid_disks >/dev/null 2>&1; then
		echo "raid_disks-stage-refused"; return 1
	fi
	if ! echo reshape | sudo tee /sys/block/$MDNAME/md/sync_action >/dev/null 2>&1; then
		echo "sync_action-refused"; return 1
	fi
	# START BARRIER: the sync thread spawns asynchronously — without this,
	# a wait-for-idle poll can slip through the sub-second window before
	# the reshape appears in mdstat and every later assertion races the
	# still-running migration (found the hard way: "stale parity" that was
	# simply a mid-reshape scrub).  Completion (already idle again) also
	# satisfies it via reshape_position going back to 'none'.
	for i in $(seq 1 200); do
		grep -q reshape /proc/mdstat && return 0
		[ "$(cat /sys/block/$MDNAME/md/reshape_position 2>/dev/null)" = none ] &&
			return 0
		sleep 0.1
	done
	echo "reshape-never-started"; return 1
}
mkarray() {	# mkarray <layout: 2r|2|3r> — fresh array + pattern
	rk_create "$1" "${MEMBERS[@]}" || return 1
	sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
	sync
	PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
}
read_md5() {
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null |
		md5sum | cut -d' ' -f1
}
# rk_scrub is not robust right after a reshape: md's async reap of the reshape
# thread INTRs a check written into that window ("md: <dev>: check
# interrupted."), and an interrupted check leaves a GARBAGE mismatch_cnt — a
# huge false-fail or a 0-count false-PASS.  Require POSITIVE completion: the
# check's own "check done." must appear in dmesg after our trigger; anything
# else (interrupted, never started) retries after a settle.  Verified
# manually: an 8s-settled post-shrink check runs to completion with
# mismatch=0 where the racing one was INTR'd at ~0.1s with counts in the
# hundreds of thousands.
scrub_settled() {
	local try d0 mm i
	sleep 3					# let the reshape reap settle
	for try in 1 2 3 4 5; do
		d0=$(sudo dmesg | grep -c "check done")
		echo check | sudo tee "/sys/block/$MDNAME/md/sync_action" >/dev/null
		for i in $(seq 1 600); do
			[ "$(sudo dmesg | grep -c 'check done')" -gt "$d0" ] && {
				cat "/sys/block/$MDNAME/md/mismatch_cnt"
				return 0
			}
			sleep 0.5
		done
		sleep 3
	done
	echo "check-never-completed"
}

# ---- T1: array-size-first is enforced ---------------------------------------
echo "MARK T1" 2>/dev/null | sudo tee /dev/kmsg >/dev/null; echo "=== T1: shrink without the --array-size clamp must be refused ==="
mkarray "${M}r" || { rk_fail "T1: create"; rk_summary; exit 1; }
if err=$(start_shrink); then
	rk_fail "T1: shrink STARTED without the array-size clamp"
	rk_wait_idle
else
	rk_pass "T1: shrink refused without the clamp ($err)"
fi
grep -q reshape /proc/mdstat && rk_fail "T1: a reshape is running" \
			     || rk_pass "T1: no reshape started"
# un-stage the rejected delta so T2's fresh create isn't confused
sudo "$MDADM" --stop "$MD" 2>/dev/null

# ---- T2: happy path (rotating, m=2) ------------------------------------------
echo "MARK T2" 2>/dev/null | sudo tee /dev/kmsg >/dev/null; echo "=== T2: clamp + shrink k=$((N-M))->$((N-M-1)) (rotating m=$M) ==="
mkarray "${M}r" || { rk_fail "T2: create"; rk_summary; exit 1; }
CLAMP=$(new_capacity_kb)
sudo "$MDADM" --grow "$MD" --array-size="$CLAMP" >/dev/null 2>&1 ||
	{ rk_fail "T2: --array-size clamp failed"; rk_summary; exit 1; }
start_shrink >/dev/null || { rk_fail "T2: shrink did not start"; rk_summary; exit 1; }
rk_pass "T2: shrink started (backward COW)"
rk_wait_idle
grep -q reshape /proc/mdstat && { rk_fail "T2: reshape did not finish"; rk_summary; exit 1; }
rk_pass "T2: shrink completed"
[ "$PRE" = "$(read_md5)" ] && rk_pass "T2: data intact across the shrink" \
			   || rk_fail "T2: DATA MISMATCH"
mm=$(scrub_settled); [ "$mm" = 0 ] && rk_pass "T2: scrub clean" || rk_fail "T2: scrub mismatch_cnt=$mm"
ndisks=$(sudo "$MDADM" --detail "$MD" | sed -n 's/.*Raid Devices : \([0-9]*\).*/\1/p')
[ "$ndisks" = "$((N-1))" ] && rk_pass "T2: raid_disks now $((N-1))" \
			   || rk_fail "T2: raid_disks=$ndisks (want $((N-1)))"
# the freed member must be removable and re-usable
FREED=$(sudo "$MDADM" --detail "$MD" | awk '/spare/ {print $NF; exit}')
if [ -n "$FREED" ] && sudo "$MDADM" --remove "$MD" "$FREED" >/dev/null 2>&1; then
	rk_pass "T2: freed member ($FREED) became a spare and was removed"
else
	rk_fail "T2: freed member not removable (detail: $(sudo "$MDADM" --detail "$MD" | tail -3 | tr '\n' ' '))"
fi
# persistence
sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
rk_assemble "${MEMBERS[@]:0:$((N-1))}" || { rk_fail "T2: re-assemble failed"; rk_summary; exit 1; }
[ "$PRE" = "$(read_md5)" ] && rk_pass "T2: geometry + data persist across re-assemble" \
			   || rk_fail "T2: DATA MISMATCH after re-assemble"

# ---- T3: decode oracle at the shrunk geometry --------------------------------
echo "MARK T3" 2>/dev/null | sudo tee /dev/kmsg >/dev/null; echo "=== T3: fail $M member(s) -> reconstructed data must be byte-exact ==="
for d in "${MEMBERS[@]:0:$M}"; do
	sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1
done
deg=$(cat /sys/block/$MDNAME/md/degraded)
[ "$deg" = "$M" ] && [ "$PRE" = "$(read_md5)" ] &&
	rk_pass "T3: degraded-decode at m=$M EC-correct after shrink" ||
	rk_fail "T3: degraded read wrong (deg=$deg)"

# ---- T4: parity-last + m=3 ----------------------------------------------------
for CASE in "2" "3r"; do
	M2=$(rk_m_of "$CASE")
	[ "${CASE: -1}" = r ] && LBL=rotating || LBL=parity-last
	echo "=== T4: shrink k=$((N-M2))->$((N-M2-1)) ($LBL m=$M2) ==="
	M=$M2 mkarray "$CASE" || { rk_fail "T4 $LBL m=$M2: create"; continue; }
	CLAMP=$(M=$M2 new_capacity_kb)
	sudo "$MDADM" --grow "$MD" --array-size="$CLAMP" >/dev/null 2>&1
	start_shrink >/dev/null || { rk_fail "T4 $LBL m=$M2: shrink did not start"; continue; }
	rk_wait_idle
	grep -q reshape /proc/mdstat && { rk_fail "T4 $LBL m=$M2: did not finish"; continue; }
	[ "$PRE" = "$(read_md5)" ] && rk_pass "T4 $LBL m=$M2: data intact" \
				   || rk_fail "T4 $LBL m=$M2: DATA MISMATCH"
	mm=$(scrub_settled); [ "$mm" = 0 ] && rk_pass "T4 $LBL m=$M2: scrub clean" \
				      || rk_fail "T4 $LBL m=$M2: scrub=$mm"
done

# ---- T5: v1 scope — only delta = -1 ------------------------------------------
echo "MARK T5" 2>/dev/null | sudo tee /dev/kmsg >/dev/null; echo "=== T5: delta_disks < -1 must be rejected ==="
mkarray "2r" || { rk_fail "T5: create"; rk_summary; exit 1; }
CLAMP=$(( $(M=2 new_capacity_kb) / 2 ))
sudo "$MDADM" --grow "$MD" --array-size="$CLAMP" >/dev/null 2>&1
if echo $((N - 2)) | sudo tee /sys/block/$MDNAME/md/raid_disks >/dev/null 2>&1; then
	echo reshape | sudo tee /sys/block/$MDNAME/md/sync_action >/dev/null 2>&1 &&
		rk_fail "T5: a 2-disk shrink STARTED (v1 is delta=-1 only)" ||
		rk_pass "T5: 2-disk shrink rejected at start"
	rk_wait_idle
else
	rk_pass "T5: 2-disk shrink rejected at stage"
fi

# ---- T6: concurrent I/O across the backward frontier --------------------------
echo "MARK T6" 2>/dev/null | sudo tee /dev/kmsg >/dev/null; echo "=== T6: fio randwrite+verify racing a throttled shrink (rotating m=2) ==="
command -v fio >/dev/null || { rk_fail "T6: fio required"; rk_summary; exit 1; }
mkarray "2r" || { rk_fail "T6: create"; rk_summary; exit 1; }
CLAMP=$(M=2 new_capacity_kb)
sudo "$MDADM" --grow "$MD" --array-size="$CLAMP" >/dev/null 2>&1
RGN=$(( CLAMP / 4 ))			# fio churns the low quarter (KiB)
sudo fio --name=shrinkio --filename="$MD" --direct=1 --rw=randwrite \
	--bs=64k --iodepth=8 --ioengine=libaio \
	--verify=crc32c --verify_backlog=64 --verify_fatal=1 --do_verify=1 \
	--size="${RGN}k" --runtime=45 --time_based=1 --loops=100000 \
	--verify_dump=1 --output="$RK_TMP/fio-shrink.log" > /dev/null 2>&1 &
FIO_PID=$!
sleep 3
echo 1500 | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
start_shrink >/dev/null || { rk_fail "T6: shrink did not start under load"; kill "$FIO_PID"; rk_summary; exit 1; }
rk_pass "T6: shrink accepted with the array in active use"
OVERLAP=no
for i in $(seq 1 360); do
	grep -q reshape /proc/mdstat || break
	kill -0 "$FIO_PID" 2>/dev/null && OVERLAP=yes
	sleep 0.5
done
echo 2000000 | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
rk_wait_idle
[ "$OVERLAP" = yes ] && rk_pass "T6: shrink genuinely overlapped live fio" \
		     || rk_fail "T6: no observed overlap (inconclusive run)"
if wait "$FIO_PID"; then
	rk_pass "T6: fio randwrite+verify clean across the backward frontier"
else
	rk_fail "T6: fio verify FAILED during the shrink"
	grep -iE "verify|error|bad" "$RK_TMP/fio-shrink.log" | head -4 | sed 's/^/      · /'
fi
mm=$(scrub_settled); [ "$mm" = 0 ] && rk_pass "T6: scrub clean after concurrent shrink" \
			      || rk_fail "T6: scrub mismatch_cnt=$mm"

# ---- T7: csum × shrink (the generalized verify-src/re-key band helpers) ------
echo "MARK T7" 2>/dev/null | sudo tee /dev/kmsg >/dev/null; echo "=== T7: shrink a --checksum array (rotating m=2) — re-key + storm detector ==="
RK_CREATE_EXTRA="--checksum"
mkarray "2r" || { rk_fail "T7: create --checksum"; rk_summary; exit 1; }
S0=$(sudo dmesg | grep -c "native csum mismatch")
CLAMP=$(M=2 new_capacity_kb)
sudo "$MDADM" --grow "$MD" --array-size="$CLAMP" >/dev/null 2>&1
start_shrink >/dev/null || { rk_fail "T7: csum shrink did not start"; rk_summary; exit 1; }
rk_wait_idle
grep -q reshape /proc/mdstat && { rk_fail "T7: did not finish"; rk_summary; exit 1; }
rk_pass "T7: shrink completed on a --checksum array"
[ "$PRE" = "$(read_md5)" ] && rk_pass "T7: data intact" || rk_fail "T7: DATA MISMATCH"
# storm detector: full re-read through the verify path — every CRC must have
# been re-keyed by the band (every block moved disks and/or rows)
sudo dd if="$MD" of=/dev/null bs=1M iflag=direct status=none 2>/dev/null
storm=$(( $(sudo dmesg | grep -c "native csum mismatch") - S0 ))
[ "$storm" = 0 ] && rk_pass "T7: zero csum mismatches on full re-read (re-key correct)" \
		 || rk_fail "T7: $storm csum mismatches (stale-key storm)"
mm=$(scrub_settled); [ "$mm" = 0 ] && rk_pass "T7: scrub clean" || rk_fail "T7: scrub mismatch_cnt=$mm"

# ---- T8: the mdadm driver (raidkm_shrink_data) --------------------------------
echo "MARK T8" 2>/dev/null | sudo tee /dev/kmsg >/dev/null; echo "=== T8: mdadm --grow --raid-devices=$((N-1)) drives the shrink ==="
RK_CREATE_EXTRA=""
mkarray "2r" || { rk_fail "T8: create"; rk_summary; exit 1; }
# without the clamp: refused with the actionable --array-size hint
if OUT=$(sudo "$MDADM" --grow "$MD" --raid-devices=$((N-1)) 2>&1); then
	rk_fail "T8: mdadm shrink SUCCEEDED without the array-size clamp"
	rk_wait_idle
else
	echo "$OUT" | grep -q -- "--array-size=" &&
		rk_pass "T8: refused with the actionable --array-size hint" ||
		rk_fail "T8: refusal lacks the --array-size hint: $(echo "$OUT" | head -2 | tr '\n' ' ')"
fi
CLAMP=$(M=2 new_capacity_kb)
sudo "$MDADM" --grow "$MD" --array-size="$CLAMP" >/dev/null 2>&1
sudo "$MDADM" --grow "$MD" --raid-devices=$((N-1)) >/dev/null 2>&1 ||
	{ rk_fail "T8: mdadm shrink did not start after the clamp"; rk_summary; exit 1; }
rk_pass "T8: mdadm-driven shrink started"
for i in $(seq 1 100); do grep -q reshape /proc/mdstat && break; sleep 0.1; done
rk_wait_idle
grep -q reshape /proc/mdstat && { rk_fail "T8: did not finish"; rk_summary; exit 1; }
[ "$PRE" = "$(read_md5)" ] && rk_pass "T8: data intact (mdadm driver)" \
			   || rk_fail "T8: DATA MISMATCH (mdadm driver)"
mm=$(scrub_settled); [ "$mm" = 0 ] && rk_pass "T8: scrub clean" || rk_fail "T8: scrub mismatch_cnt=$mm"

sudo dmesg | grep -iE "WARN|BUG|call trace|gf_invert" | tail -5 || true
rk_summary
