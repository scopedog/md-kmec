#!/bin/bash
# raidkm-test-grow-traditional.sh — grow data capacity via the *stock* mdadm
# command syntax (no --add-data tag), the way you'd grow a RAID6.
#
# raidkm adds --add-data/--add-parity, but an untagged grow should still behave
# like stock mdraid: an explicit --raid-devices=N grows DATA at fixed parity.
# Two entry forms are exercised:
#   A. two-step  : `mdadm --add <disk>` (hot spare) then `mdadm --grow
#                  --raid-devices=N`  (consume the existing spare)
#   B. one-line  : `mdadm --grow --raid-devices=N --add <disk>`
# For each we assert the array CAPACITY grew (proves a data grow, not a parity
# grow — parity grow leaves size unchanged), the data is intact, scrub is clean,
# and a max-degraded read still reconstructs.  m=3 so the ISA-L encode tables
# (rebuilt for the new k) are exercised across the reshape.
#
#   sudo bash tools/raidkm-test-grow-traditional.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SZ="${SZ:-48}"

rk_load_modules || exit 1
rk_setup_brd 8 || exit 1
rk_dmesg_clear

cap() { sudo blockdev --getsize64 "$MD" 2>/dev/null; }

# grow_traditional <form> <layout> : create m=3,k=3 (6 disks), grow by one data
# disk to k=4 using the given stock-style command form, and validate.
grow_traditional() {
	local form="$1" layout="$2" tag="form-$1 m=3 $2"
	local disks base add c0 c1
	disks=$(rk_pick_disks 8) || { rk_fail "$tag: not enough ramdisks"; return; }
	base=$(echo $disks | cut -d' ' -f1-6)     # m=3, k=3, N=6
	add=$(echo  $disks | cut -d' ' -f7)        # the new data disk
	local newn=7

	rk_create "$layout" $base || { rk_fail "$tag: create failed"; return; }
	rk_write "$SZ"
	c0=$(cap)

	case "$form" in
	A)	# two-step: add a hot spare, then grow raid-devices into it
		sudo "$MDADM" --add "$MD" $add >/dev/null 2>&1 || {
			rk_fail "$tag: --add spare failed"; rk_stop; return; }
		sudo "$MDADM" --grow "$MD" --raid-devices=$newn >/dev/null 2>&1 || {
			rk_fail "$tag: --grow --raid-devices failed"; rk_stop; return; }
		;;
	B)	# one-line: grow raid-devices with the new disk on the same line
		sudo "$MDADM" --grow "$MD" --raid-devices=$newn --add $add >/dev/null 2>&1 || {
			rk_fail "$tag: --grow --raid-devices --add failed"; rk_stop; return; }
		;;
	esac
	rk_wait_idle
	c1=$(cap)

	if [ "${c1:-0}" -gt "${c0:-0}" ]; then
		rk_pass "$tag: capacity grew $((c0/1048576))->$((c1/1048576)) MiB (data grow) $(rk_geom)"
	else
		rk_fail "$tag: capacity did NOT grow ($c0 -> $c1) — routed to parity grow?"
		rk_stop; return
	fi
	if rk_readback "$SZ"; then
		rk_pass "$tag: data intact after grow"
	else
		rk_fail "$tag: data MISMATCH after grow"
	fi
	local mm; mm=$(rk_scrub)
	if [ "$mm" = 0 ]; then
		rk_pass "$tag: scrub clean (mismatch_cnt=0)"
	else
		rk_fail "$tag: scrub mismatch_cnt=$mm"
	fi
	rk_fail_disks $(rk_pick_disks 3)           # max-degraded for m=3 at N=7
	if rk_readback "$SZ"; then
		rk_pass "$tag: degraded read reconstructs after grow"
	else
		rk_fail "$tag: degraded read CORRUPT after grow"
	fi
	rk_stop
}

# Negative: an untagged --grow --raid-devices=N with no spare present and no
# disk on the line must fail cleanly (and must not have started anything).
neg_no_spare() {
	local disks base
	disks=$(rk_pick_disks 6) || { rk_fail "neg: not enough ramdisks"; return; }
	base=$(echo $disks | cut -d' ' -f1-6)
	rk_create 3 $base || { rk_fail "neg: create failed"; return; }
	if sudo "$MDADM" --grow "$MD" --raid-devices=7 >/dev/null 2>&1; then
		rk_fail "neg: --grow --raid-devices=7 with no spare should have failed"
	else
		rk_pass "neg: --grow --raid-devices with no spare rejected"
	fi
	rk_stop
}

grow_traditional A 3
grow_traditional A 3r
grow_traditional B 3
grow_traditional B 3r
neg_no_spare

rk_dmesg_clean || rk_fail "kernel log shows WARN/BUG during traditional grow"
rk_summary
