#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# raidkm-test-gtc-swap.sh — group_thread_cnt / worker_thread_cnt written while
# the stripe workers are busy (a field report: GPF in handle_active_stripes when a
# management tool wrote group_thread_cnt=16 a few ms after assembling an
# unclean array, as its resync started with the default 128 workers per
# group: workers queued before the worker-group swap ran after it and took
# their group index against the new array).
#
# What this proves (4 members, k=2 m=2 rotating, chunk 512 KiB, internal
# bitmap -- the reporter's geometry), new arrays at 128 workers per group:
#   G1  GS_ITER times: stop an unclean array, assemble it, and at once write
#       stripe_cache_size 8192, group_thread_cnt 16, skip_copy 1 and
#       sync_speed_max (the reporter's sequence); let the resync run a
#       moment
#   G2  a writer and a repair running, group_thread_cnt flipped GS_FLIPS
#       times through 128 16 0 4 1 64, and worker_thread_cnt every 5th
#   G3  fault-inject build only (make RAIDKM_FAULT_INJECT=1): workers held
#       50 ms at their start (gtc_test_work_delay_ms) are in flight across
#       10 swaps; the fixed order drains them first.  GS_NEG=1
#       (gtc_test_old_order: swap, then drain) is a manual negative control:
#       the worker guard must WARN (where the old code GPFs).  Its WARN is
#       expected, so never run GS_NEG=1 under raidkm-test-ci.sh; it reloads
#       raidkm (the guard warns once per load).
#   after each: no kernel splat (known artifacts filtered, as every suite),
#   the written data reads back, a check finds mismatch_cnt 0
# A small VM rarely hits G1/G2's natural window (the reporter's host had 256
# cores); G3 is the deterministic gate.
#
# Usage: bash <this>     (see raidkm-test-lib.sh for configuration)
#   GS_ITER=40 GS_FLIPS=60   G1 / G2 rounds
#   GS_CSUM=1                the array with --checksum (the CRC hold, the
#                            resync marking the array dirty and the quiesce
#                            write-back run alongside the swaps)
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

CHUNK_KB=512
ITER=${GS_ITER:-40}; FLIPS=${GS_FLIPS:-60}; NEG=${GS_NEG:-0}
# the guard is a WARN_ON_ONCE: a module that has fired it once cannot show the
# negative control again, so GS_NEG=1 always starts from a fresh load
[ "$NEG" = 1 ] && RK_RELOAD=1
RK_CREATE_EXTRA="--bitmap=internal"
[ "${GS_CSUM:-0}" = 1 ] && RK_CREATE_EXTRA+=" --checksum"
SYS=/sys/block/$MDNAME/md
P=/sys/module/raidkm/parameters
BG=; OLDDEF=; DISKS=()

cleanup() {
	# the writer and the dd it is running (a timeout's SIGTERM reaches only
	# this shell: left alone they would write into the next suite's array)
	[ -n "$BG" ] && { pkill -P "$BG" 2>/dev/null; kill "$BG" 2>/dev/null; wait "$BG" 2>/dev/null; }
	[ -n "$OLDDEF" ] && echo "$OLDDEF" > $P/default_group_thread_cnt
	echo 0 > $P/gtc_test_work_delay_ms 2>/dev/null
	echo N > $P/gtc_test_old_order 2>/dev/null
	rk_stop
}
trap cleanup EXIT
# raidkm-test-ci.sh ends a suite past its time limit with SIGTERM, which skips
# an EXIT trap unless it is turned into an exit: restore the module defaults,
# the test knobs and the writer on every way out
trap 'exit 130' INT
trap 'exit 143' TERM

splats() {	# splats <case>: no kernel splat since the last rk_dmesg_clear
	local f="$RK_TMP/gtc-$1.dmesg" n
	dmesg > "$f"
	n=$(rk_dmesg_splats "$f")
	[ "${n:-0}" = 0 ] && rk_pass "$1: kernel log clean" ||
		{ rk_fail "$1: $n kernel splat line(s)"; grep -m12 -E "$RK_SPLAT" "$f" >&2; }
}
checkdata() {	# checkdata <case>
	rk_wait_idle
	if dd if="$MD" bs=1M count=64 iflag=direct status=none 2>/dev/null |
	   cmp -s - "$RK_TMP/gtc-pat"; then
		rk_pass "$1: data reads back"
	else
		rk_fail "$1: data differs"
	fi
	echo check > $SYS/sync_action; sleep 0.5; rk_wait_idle
	[ "$(cat $SYS/mismatch_cnt)" = 0 ] && rk_pass "$1: check clean" ||
		rk_fail "$1: check: mismatch_cnt $(cat $SYS/mismatch_cnt)"
}
writer() {	# 8 MiB direct writes past the pattern, until killed
	local mb=$(( $(blockdev --getsize64 "$MD") >> 20 ))
	while :; do
		dd if=/dev/urandom of="$MD" bs=1M count=8 seek=$(( 64 + RANDOM % (mb - 80) )) \
			oflag=direct status=none 2>/dev/null
	done
}

rk_load_modules || exit 1
rk_setup_brd 4 || { rk_fail "not enough ramdisks"; rk_summary; exit 1; }
read -r -a DISKS <<< "$(rk_pick_disks 4)"
OLDDEF=$(cat $P/default_group_thread_cnt)
echo 128 > $P/default_group_thread_cnt
rk_create 2r "${DISKS[@]}" || { rk_fail "create"; rk_summary; exit 1; }
head -c 64M /dev/urandom > "$RK_TMP/gtc-pat"
dd if="$RK_TMP/gtc-pat" of="$MD" bs=1M oflag=direct status=none

# ---- G1 ------------------------------------------------------------------------
echo "=== G1: assemble an unclean array and write the tunables at once, x$ITER ==="
rk_dmesg_clear
for it in $(seq 1 "$ITER"); do
	# unclean: resync_start 0 (md takes it only frozen) reaches the
	# superblock at the stop, so the next assembly starts a full resync
	echo frozen > $SYS/sync_action 2>/dev/null
	echo 0 > $SYS/resync_start 2>/dev/null || { rk_fail "G1: resync_start (round $it)"; break; }
	"$MDADM" --stop "$MD" >/dev/null 2>&1 || { rk_fail "G1: stop (round $it)"; break; }
	# the stop's member events can make udev assemble the members as md127
	# (INCREMENTAL); the assembly below would then find them busy
	udevadm settle 2>/dev/null
	"$MDADM" --stop /dev/md127 >/dev/null 2>&1
	"$MDADM" --assemble "$MD" "${DISKS[@]}" >/dev/null 2>&1 &
	# the writes race the assembly, as the management tool's do
	for t in $(seq 400); do [ -w $SYS/group_thread_cnt ] && break; sleep 0.005; done
	echo 8192 > $SYS/stripe_cache_size 2>/dev/null
	echo 16 > $SYS/group_thread_cnt 2>/dev/null
	echo 1 > $SYS/skip_copy 2>/dev/null
	echo 4000000 > $SYS/sync_speed_max 2>/dev/null
	wait
	sleep 0.$(( RANDOM % 4 ))
	echo 128 > $SYS/group_thread_cnt 2>/dev/null
done
rk_log "resyncs started: $(dmesg | grep -c "resync of RAID array $MDNAME")"
grep -q "^$MDNAME : active" /proc/mdstat && rk_pass "G1: array assembled after $ITER rounds" ||
	{ rk_fail "G1: array not active"; rk_summary; exit 1; }
splats G1
checkdata G1

# ---- G2 ------------------------------------------------------------------------
echo "=== G2: flip the worker count $FLIPS times under a writer and a repair ==="
rk_dmesg_clear
writer & BG=$!
rk_throttle 20000
echo repair > $SYS/sync_action
vals=(128 16 0 4 1 64)
for f in $(seq 1 "$FLIPS"); do
	v=${vals[$(( f % ${#vals[@]} ))]}
	if [ $(( f % 5 )) = 0 ]; then
		echo "$v" > $SYS/worker_thread_cnt 2>/dev/null
	else
		echo "$v" > $SYS/group_thread_cnt 2>/dev/null
	fi
	sleep 0.0$(( RANDOM % 10 ))
	grep -q -E "resync|repair|check" /proc/mdstat || echo repair > $SYS/sync_action
done
kill "$BG"; wait "$BG" 2>/dev/null; BG=
echo idle > $SYS/sync_action; rk_unthrottle
splats G2
checkdata G2

# ---- G3 ------------------------------------------------------------------------
if [ -w $P/gtc_test_work_delay_ms ]; then
	echo "=== G3: workers in flight across the swap$([ "$NEG" = 1 ] && echo ' (old order: NEG)') ==="
	rk_dmesg_clear
	[ "$NEG" = 1 ] && echo Y > $P/gtc_test_old_order
	echo 128 > $SYS/group_thread_cnt
	echo 50 > $P/gtc_test_work_delay_ms
	writer & BG=$!
	for f in $(seq 1 10); do
		sleep 0.3
		echo $(( f % 2 ? 16 : 128 )) > $SYS/group_thread_cnt
	done
	echo 0 > $P/gtc_test_work_delay_ms
	kill "$BG"; wait "$BG" 2>/dev/null; BG=
	echo N > $P/gtc_test_old_order
	if [ "$NEG" = 1 ]; then
		w=$(dmesg | grep -c "WARNING:.*raid5_do_work")
		[ "$w" -gt 0 ] && rk_pass "G3 NEG: the guard caught a worker of the old groups" ||
			rk_fail "G3 NEG: no stale worker seen (window not hit)"
	else
		splats G3
	fi
	checkdata G3
else
	rk_skip_check "G3: needs a fault-inject build (make RAIDKM_FAULT_INJECT=1)"
fi

rk_summary
