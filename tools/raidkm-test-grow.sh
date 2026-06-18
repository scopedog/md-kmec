#!/bin/bash
# raidkm-test-grow.sh — grow (capacity and parity) coverage.
#
# 1. --add-data (online data-disk grow, fixed m), parity-last + rotating, m=2/3:
#       create k=3, write, grow +1 data disk, then
#         (a) read back + scrub clean       (clean array intact after reshape)
#         (b) fail m disks + read back      (THE regression: EC matrix/tables
#             must be rebuilt for the grown k, or degraded read corrupts —
#             a bug scrub alone does NOT catch).
#    Plus a multi-disk grow (+2 in one --add-data).
# 2. --add-parity (offline recreate, parity-last only): m=2 -> 3, data preserved.
#    (rotating --add-parity is an online reshape; see
#     raidkm-test-grow-parity-rotating.sh.)
#
#   sudo bash tools/raidkm-test-grow.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SZ="${SZ:-24}"

rk_load_modules || exit 1
rk_setup_brd 9 || exit 1
rk_dmesg_clear          # scope the end-of-run WARN/BUG check to this suite

# ---- 1. online --add-data, with degraded-read-after-grow ----
for layout in 2 2r 3 3r; do
	m=$(rk_m_of "$layout")
	oldn=$((3 + m)); newn=$((oldn + 1))       # k=3 -> 4
	lbl=$([ "${layout: -1}" = r ] && echo rotating || echo parity-last)
	all=$(rk_pick_disks "$newn") || { rk_fail "m=$m: not enough ramdisks"; continue; }
	base=$(echo $all | cut -d' ' -f1-"$oldn")
	add=$(echo $all | cut -d' ' -f"$newn")

	rk_create "$layout" $base || { rk_fail "m=$m $lbl: create failed"; continue; }
	rk_write "$SZ"
	if ! rk_grow_data $add; then
		rk_fail "m=$m $lbl: --add-data failed"; rk_stop; continue
	fi
	geom=$(rk_geom)
	if rk_readback "$SZ" && [ "$(rk_scrub)" = 0 ]; then
		rk_pass "m=$m $lbl: --add-data k=3->4 clean read+scrub $geom"
	else
		rk_fail "m=$m $lbl: --add-data k=3->4 data/scrub bad $geom"
	fi
	# Regression: reconstruct after the grow (fail m of the new N disks).
	rk_fail_disks $(rk_pick_disks "$m")
	if rk_readback "$SZ"; then
		rk_pass "m=$m $lbl: degraded read after grow (EC rebuilt for new k)"
	else
		rk_fail "m=$m $lbl: degraded read after grow CORRUPT (stale EC table?)"
	fi
	rk_stop
done

# ---- multi-disk --add-data (+2 at once) ----
all=$(rk_pick_disks 8) || true
if [ "$(echo $all | wc -w)" -ge 8 ]; then
	base=$(echo $all | cut -d' ' -f1-5)       # m=2, k=3, N=5
	add=$(echo $all | cut -d' ' -f6-7)        # add 2 -> k=5, N=7
	rk_create 2 $base && rk_write "$SZ"
	if rk_grow_data $add && rk_readback "$SZ" && [ "$(rk_scrub)" = 0 ]; then
		rk_pass "m=2 parity-last: --add-data +2 (k=3->5) $(rk_geom)"
	else
		rk_fail "m=2 parity-last: --add-data +2 failed"
	fi
	rk_stop
fi

# ---- 2. offline --add-parity (parity-last), m=2 -> 3 ----
all=$(rk_pick_disks 6)
base=$(echo $all | cut -d' ' -f1-5)           # m=2, k=3, N=5
add=$(echo $all | cut -d' ' -f6)
rk_create 2 $base && rk_write "$SZ"
if rk_grow_parity $add && rk_readback "$SZ" && [ "$(rk_scrub)" = 0 ]; then
	rk_pass "m=2 parity-last: --add-parity m=2->3 data preserved $(rk_geom)"
else
	rk_fail "m=2 parity-last: --add-parity m=2->3 failed"
fi
rk_stop

# Rotating --add-parity is an ONLINE reshape (m -> m+1); it has its own
# dedicated coverage in raidkm-test-grow-parity-rotating.sh.

rk_dmesg_clean || rk_fail "kernel log shows WARN/BUG/gf_invert during grow tests"
rk_summary
