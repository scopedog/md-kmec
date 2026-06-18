#!/bin/bash
# raidkm-test-functional.sh — create / write / read-back / scrub for raidkm.
#
# For each layout (parity-last and rotating) at m = 2, 3, 4: create a k=3 array,
# write random data, read it back (must match), and scrub (mismatch_cnt must
# be 0).  This is the basic "does it store and protect data" smoke test.
#
#   sudo bash tools/raidkm-test-functional.sh
#
# See raidkm-test-lib.sh for configuration (MD, MDADM, module paths, ...).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SZ="${SZ:-24}"          # MiB of test data per array

rk_load_modules || exit 1
rk_setup_brd 5 || exit 1

for layout in 2 2r 3 3r 4 4r; do
	m=$(rk_m_of "$layout")
	n=$((3 + m))                              # k = 3 data disks
	lbl=$([ "${layout: -1}" = r ] && echo rotating || echo parity-last)
	disks=$(rk_pick_disks "$n") || { rk_fail "m=$m: not enough ramdisks"; continue; }

	if ! rk_create "$layout" $disks; then
		rk_fail "m=$m $lbl: create failed"; continue
	fi
	rk_write "$SZ"
	if rk_readback "$SZ"; then
		rk_pass "m=$m $lbl: create + write/read-back $(rk_geom)"
	else
		rk_fail "m=$m $lbl: read-back MISMATCH"
	fi
	mm=$(rk_scrub)
	if [ "$mm" = 0 ]; then
		rk_pass "m=$m $lbl: scrub clean (mismatch_cnt=0)"
	else
		rk_fail "m=$m $lbl: scrub mismatch_cnt=$mm"
	fi
	rk_stop
done

rk_summary
