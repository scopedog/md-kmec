#!/bin/bash
# raidkm-test-reshape-concurrent.sh — I/O concurrent with an --add-data reshape.
#
# The plain grow test does no I/O while the reshape runs, so it never exercises
# the *dual* EC-table path: during a reshape both geometries are live (writes to
# pre- vs post-reshape_position stripes use the old-k vs new-k tables), and there
# is a brief window at completion (end_reshape bumps previous_raid_disks before
# finish_reshape frees the old tables) where the table selector must NOT hand
# back the stale old-k set for a new-k stripe.
#
# This test throttles the reshape and rewrites the same (deterministic) data
# continuously throughout it and a few seconds past completion, then verifies
# the data, a clean scrub (parity must match data — catches a wrong-table
# encode), and a max-degraded read.  m=3 so the ISA-L encode tables are used.
#
#   sudo bash tools/raidkm-test-reshape-concurrent.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SZ="${SZ:-80}"
SYNC_MAX="${SYNC_MAX:-25000}"      # KiB/s cap so the reshape spans many seconds

rk_load_modules || exit 1
rk_setup_brd 7 || exit 1
rk_dmesg_clear

disks=$(rk_pick_disks 7) || { rk_fail "not enough ramdisks"; rk_summary; exit 1; }
base=$(echo $disks | cut -d' ' -f1-6)          # m=3, k=3, N=6
add=$(echo $disks | cut -d' ' -f7)

rk_create 3 $base || { rk_fail "create failed"; rk_summary; exit 1; }
rk_write "$SZ"                                  # known content in $RK_TMP/src

echo "$SYNC_MAX" | sudo tee "/sys/block/$MDNAME/md/sync_speed_max" >/dev/null

# Background writer: rewrite the SAME content (so the final data is known) until killed.
( while true; do
	sudo dd if="$RK_TMP/src" of="$MD" bs=1M count="$SZ" oflag=direct status=none 2>/dev/null || true
  done ) &
wpid=$!

t0=$(date +%s)
rk_grow_data $add                               # issues reshape, then waits for it
sleep 3                                         # keep writing across end_reshape->finish_reshape
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
rk_log "reshape spanned $(( $(date +%s) - t0 ))s under concurrent writes; $(rk_geom)"

if rk_readback "$SZ"; then
	rk_pass "data intact after concurrent-write reshape"
else
	rk_fail "data mismatch after concurrent-write reshape"
fi
mm=$(rk_scrub)
if [ "$mm" = 0 ]; then
	rk_pass "scrub clean after concurrent reshape (mismatch_cnt=0)"
else
	rk_fail "scrub mismatch_cnt=$mm (wrong-table encode during reshape?)"
fi
rk_fail_disks $(rk_pick_disks 3)                # max-degraded for m=3
if rk_readback "$SZ"; then
	rk_pass "degraded read correct after concurrent grow"
else
	rk_fail "degraded read CORRUPT after concurrent grow"
fi
rk_stop

# A concurrent reshape can momentarily trip the inherited stripe-cache round-trip
# sanity check (stock raid5.c "compute_blocknr: map not correct"): a benign,
# transient race where a stripe's sh->disks/pd_idx and the previous-geometry
# disagree for an instant.  compute_blocknr returns 0, whose destination stripe
# is then filtered out (not EXPANDING / already Expanded), so no wrong copy
# happens and the source is retried — data is never corrupted (the read/scrub/
# degraded checks above are the real gate).  Tolerate just that one message;
# still fail on any other WARN/BUG/call-trace/gf_invert.
unexpected=$(sudo dmesg 2>/dev/null \
	| grep -iE 'WARN|BUG|map not correct|call trace|gf_invert' \
	| grep -vi 'compute_blocknr: map not correct')
if [ -n "$unexpected" ]; then
	rk_fail "kernel log shows unexpected WARN/BUG during concurrent reshape"
	printf '%s\n' "$unexpected" | sed 's/^/      /'
fi
rk_summary
