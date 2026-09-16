#!/bin/bash
# raidkm-test-scrub-badblocks.sh — scrub/repair over a live member's bad blocks.
#
# md does not fail a member on a write error when the bad-block log can record
# it: the member stays In_sync and analyse_stripe marks just the blocks in the
# recorded range not-in-sync.  A check over such a stripe counts that slot as
# failed.  For a DATA slot raidkm reconstructs it; for a PARITY slot it does
# not (fetch_block only reconstructs parity for a recoverable read error), and
# handle_parity_checks6's compute_result used to WARN "disk N not up to date"
# for it.  Found by kernel fault injection (fail_make_request) on NVMe; stock
# raid6 reaches the same state and skips the write-back to the acknowledged bad
# block, so the slot is simply left alone — which is what raidkm now does too,
# without the WARN.
#
# What this proves (k=4 m=2 rotating, bad blocks spread over one member so
# every row puts P or Q on it somewhere):
#   T1  the bad-block log accepted the ranges (otherwise nothing is tested)
#   T2  check completes, no WARN/BUG, and the data reads back unchanged
#   T3  repair completes, no WARN/BUG, and the data reads back unchanged
#
# WARN_ONCE hides a second hit in the same boot, so the test re-arms it via
# /sys/kernel/debug/clear_warn_once when debugfs is available.
#
# Usage: bash <this>     (geometry via RC_N; see raidkm-test-lib.sh)
set -u
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${RC_N:-6}
DATAMB=${DATAMB:-64}
BADMB=${BADMB:-32}			# member MiBs carrying a bad range
MEMBERS=()

cleanup() {
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	local d
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
}
trap cleanup EXIT

rearm_warn_once() {
	mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
	[ -w /sys/kernel/debug/clear_warn_once ] && echo 1 > /sys/kernel/debug/clear_warn_once
}
not_uptodate() { sudo dmesg | grep -c "not up to date"; }
run_action() {	# check|repair
	echo "$1" > "/sys/block/$MDNAME/md/sync_action"
	sleep 1
	rk_wait_idle
}

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
rk_setup_brd "$N" || exit 1
DISKS=$(rk_pick_disks "$N") || { echo "ERROR: need $N devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

echo "== scrub over a live member's bad blocks (k=$((N - 2)) m=2 rotating)"
rk_create 2r "${MEMBERS[@]}" || { rk_fail "create"; rk_summary; exit 1; }
rk_write "$DATAMB"

# ---- T1: record bad blocks on member 1 ----------------------------------------
VICTIM=${MEMBERS[1]}
BB=/sys/block/$MDNAME/md/dev-$(basename "$VICTIM")/bad_blocks
OFF=$(rk_data_offset "$VICTIM")
# 256 KiB bad at the start of each of the first BADMB MiB of the member's data
# area: several chunks per MiB, so rotating parity lands on the range too.
# The log stores absolute device sectors (is_badblock adds data_offset).
for i in $(seq 0 $((BADMB - 1))); do
	echo "$((OFF + i * 2048)) 512" > "$BB" 2>/dev/null
done
NBB=$(grep -c . "$BB" 2>/dev/null)
if [ -n "$OFF" ] && [ "${NBB:-0}" -gt 0 ]; then
	rk_pass "T1 bad-block log holds $NBB range(s) on $(basename "$VICTIM") (data_offset $OFF)"
else
	rk_fail "T1 bad-block log refused the ranges (data_offset '${OFF}', entries ${NBB:-0})"
	rk_summary; exit 1
fi

# ---- T2: check --------------------------------------------------------------
rearm_warn_once; rk_dmesg_clear
run_action check
w=$(not_uptodate)
if [ "$w" -eq 0 ] && rk_dmesg_clean; then
	rk_pass "T2 check over bad blocks: no WARN (mismatch_cnt $(cat /sys/block/$MDNAME/md/mismatch_cnt))"
else
	rk_fail "T2 check over bad blocks: $w 'not up to date' WARN(s) / kernel report"
	sudo dmesg | grep -iE 'WARN|not up to date|BUG' | head -5
fi
rk_readback "$DATAMB" && rk_pass "T2 data unchanged after check" || rk_fail "T2 data changed after check"

# ---- T3: repair -------------------------------------------------------------
rearm_warn_once; rk_dmesg_clear
run_action repair
w=$(not_uptodate)
if [ "$w" -eq 0 ] && rk_dmesg_clean; then
	rk_pass "T3 repair over bad blocks: no WARN"
else
	rk_fail "T3 repair over bad blocks: $w 'not up to date' WARN(s) / kernel report"
	sudo dmesg | grep -iE 'WARN|not up to date|BUG' | head -5
fi
rk_readback "$DATAMB" && rk_pass "T3 data unchanged after repair" || rk_fail "T3 data changed after repair"

rk_summary
