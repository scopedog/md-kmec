#!/bin/bash
#
# raidkm-test-shrink-crash.sh — crash/resume for the BACKWARD COW shrink.
# A throttled shrink is stopped mid-flight (~half the walk), the array is
# re-assembled, and the journal recovery must resume the DESCENDING walk
# (raidkm_reshape_recover's shrink frontier: COMMIT/DONE -> resume BELOW the
# band, STAGE -> redo it) and complete: data byte-exact, scrub clean,
# geometry persisted, decode oracle at m.  Two rounds (different stop
# points).  Clean --stop tier; the torn-write tiers ride the shared
# CONFIG_RAIDKM_FAULT_INJECT contract in raidkm-test-reshape-crash.sh.
set -u
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${SH_N:-6}; M=${SH_M:-2}
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

read_md5() {
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null |
		md5sum | cut -d' ' -f1
}
scrub_settled() {	# positive-completion scrub (see raidkm-test-shrink.sh)
	local try d0 i
	sleep 3
	for try in 1 2 3; do
		d0=$(sudo dmesg | grep -c "check done")
		echo check | sudo tee "/sys/block/$MDNAME/md/sync_action" >/dev/null
		for i in $(seq 1 600); do
			[ "$(sudo dmesg | grep -c 'check done')" -gt "$d0" ] &&
				{ cat "/sys/block/$MDNAME/md/mismatch_cnt"; return 0; }
			sleep 0.5
		done
		sleep 3
	done
	echo "check-never-completed"
}

for ROUND in 1 2; do
	echo "=== round $ROUND: shrink, --stop mid-walk, re-assemble, resume ==="
	rk_create "${M}r" "${MEMBERS[@]}" || { rk_fail "r$ROUND: create"; rk_summary; exit 1; }
	sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
	sync
	PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
	DEVKB=$(sudo "$MDADM" --detail "$MD" | sed -n 's/.*Used Dev Size : \([0-9]*\).*/\1/p')
	sudo "$MDADM" --grow "$MD" --array-size=$(( DEVKB * (N - M - 1) )) >/dev/null 2>&1
	# throttle hard so the stop lands mid-walk (round 2 stops later)
	echo 3000 | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
	echo $((N - 1)) | sudo tee /sys/block/$MDNAME/md/raid_disks >/dev/null 2>&1 ||
		{ rk_fail "r$ROUND: stage refused"; rk_summary; exit 1; }
	echo reshape | sudo tee /sys/block/$MDNAME/md/sync_action >/dev/null 2>&1 ||
		{ rk_fail "r$ROUND: start refused"; rk_summary; exit 1; }
	for i in $(seq 1 100); do grep -q reshape /proc/mdstat && break; sleep 0.1; done
	sleep $(( ROUND * 2 ))
	grep -q reshape /proc/mdstat || { rk_fail "r$ROUND: reshape finished before the stop (throttle too weak)"; continue; }
	POS_STOP=$(cat /sys/block/$MDNAME/md/reshape_position)
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1 || { rk_fail "r$ROUND: --stop failed"; rk_summary; exit 1; }
	rk_pass "r$ROUND: stopped mid-shrink (reshape_position=$POS_STOP)"
	sudo udevadm settle 2>/dev/null
	sudo "$MDADM" --stop --scan >/dev/null 2>&1	# udev may have grabbed members
	sudo dmesg -C
	rk_assemble "${MEMBERS[@]}" || { rk_fail "r$ROUND: re-assemble failed"; rk_summary; exit 1; }
	sudo dmesg | grep -q "reshape recover" &&
		rk_pass "r$ROUND: journal recovery engaged on assembly" ||
		rk_fail "r$ROUND: no 'reshape recover' in dmesg"
	echo 2000000 | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
	for i in $(seq 1 600); do grep -q reshape /proc/mdstat || break; sleep 0.5; done
	grep -q reshape /proc/mdstat && { rk_fail "r$ROUND: resumed reshape did not finish"; rk_summary; exit 1; }
	rk_pass "r$ROUND: resumed shrink completed"
	[ "$PRE" = "$(read_md5)" ] && rk_pass "r$ROUND: data intact across crash+resume" \
				   || rk_fail "r$ROUND: DATA MISMATCH"
	mm=$(scrub_settled); [ "$mm" = 0 ] && rk_pass "r$ROUND: scrub clean" \
					   || rk_fail "r$ROUND: scrub mismatch_cnt=$mm"
	for d in "${MEMBERS[@]:0:$M}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
	[ "$PRE" = "$(read_md5)" ] && rk_pass "r$ROUND: degraded-decode EC-correct post-resume" \
				   || rk_fail "r$ROUND: degraded read wrong"
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	for d in "${MEMBERS[@]}"; do sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
	sudo udevadm settle 2>/dev/null
done

sudo dmesg | grep -iE "WARN|BUG|call trace|gf_invert" | tail -5 || true
rk_summary
