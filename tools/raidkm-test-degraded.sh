#!/bin/bash
# raidkm-test-degraded.sh — max-degraded reconstruction (read and write).
#
# For each layout (parity-last and rotating) at m = 2, 3, 4: create a k=3 array,
# write data, fail m disks (the maximum the array tolerates), then
#   1. read the data back   — exercises the gf_invert decode (reconstruct), and
#   2. write fresh data and read it back — exercises the degraded write path.
# Both must reconstruct/return the correct data.
#
#   sudo bash tools/raidkm-test-degraded.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SZ="${SZ:-24}"

rk_load_modules || exit 1
rk_setup_brd 7 || exit 1     # widest geometry below is m=4,k=3 -> n=7 ram disks

for layout in 2 2r 3 3r 4 4r; do
	m=$(rk_m_of "$layout")
	n=$((3 + m))
	lbl=$([ "${layout: -1}" = r ] && echo rotating || echo parity-last)
	disks=$(rk_pick_disks "$n") || { rk_fail "m=$m: not enough ramdisks"; continue; }

	if ! rk_create "$layout" $disks; then
		rk_fail "m=$m $lbl: create failed"; continue
	fi
	rk_write "$SZ"

	# Fail the first m members (max-degraded) and reconstruct on read.
	rk_fail_disks $(echo $disks | tr ' ' '\n' | head -n "$m")
	if rk_readback "$SZ"; then
		rk_pass "m=$m $lbl: degraded read reconstructs $m-disk loss $(rk_geom)"
	else
		rk_fail "m=$m $lbl: degraded read CORRUPT after $m-disk loss"
	fi

	# Degraded write: overwrite, then read back.
	rk_write "$SZ"
	if rk_readback "$SZ"; then
		rk_pass "m=$m $lbl: degraded write + read-back"
	else
		rk_fail "m=$m $lbl: degraded write MISMATCH"
	fi
	rk_stop
done

rk_summary
