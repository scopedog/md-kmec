#!/bin/bash
# raidkm-test-row-write.sh — full-row writes through the row layer.
#
# With rk_row_write=1 a write covering a whole row (k chunks at one member
# offset) skips the 4 KiB stripe cache: parity is computed from the caller's
# pages and each member gets one request (raidkm_row_write_bio).  Everything
# here checks the bytes, the parity, or both:
#   T1  aligned 1 MiB writes take the row path (write_done moves); the data
#       reads back and a scrub finds no parity mismatch.
#   T2  spans that start and end mid-row: the array splits bios at row
#       boundaries (queue chunk_sectors), so exactly the whole rows inside each
#       bio take the row path, the partial rows the stripe cache; the result is
#       right.
#   T3  the stale-cache case.  4 KiB read-modify-writes leave a stripe's
#       parity cached; a row write then rewrites the members underneath; the
#       next read-modify-write of the same stripe must not use the old parity
#       (scrub).
#   T4  4 KiB writes, row writes and stripe-cache reads racing over the same
#       rows: the parity stays consistent (scrub) and a final pass is right.
#   T5  after row writes, a member fails (degraded reads decode from the parity
#       the row path wrote); whole rows keep taking the row path while
#       degraded (write_degraded moves) and read back right; they decline
#       while a spare is being recovered; the rebuild leaves a consistent
#       array with its row boundary unchanged.
#   T6  a minimal rk_row_write_depth under many writers: most rows find no context
#       and go to the stripe cache (write_nobuf moves); fio's own verify
#       passes.
#   T7  a scrub running while row writes are issued: row writes stand aside
#       for the pass, and the parity is consistent afterwards.
#   T8  m=3 (Vandermonde) and m=4 (Cauchy) generators, and the parity-last
#       layout: data right, scrub clean; with two members failed, row writes
#       still run and read back right.
#   T9  control: rk_row_write=0 leaves write_done still, so T1's counter is a
#       real signal.
#   T10 an internal write-intent bitmap: row writes count in it (dirty bits
#       right after them), data right, scrub clean.
#   T11 rows over 1 MiB (10+2), written from huge pages so a bio can hold a
#       whole row: the row path takes them; the same bios through the stripe
#       cache are right too (fio verify, scrub).
#   T12 the row boundary: queue chunk_sectors is the row at create (6+2, a
#       row that is not a power of two) and after a grow to 8+2; one-and-a-half
#       row bios from huge pages keep their whole rows (one per bio, where a
#       bio starting mid-row used to lose its row to the 1 MiB split); fio
#       verify, scrub.
#   T13 a chunk-size reshape (128K -> 64K through md's chunk_size and
#       sync_action, as mdadm refuses it at this level): chunk_sectors,
#       minimum_io_size and optimal_io_size follow the new chunk; the data
#       reads back, the scrub is clean, whole rows still take the row path.
#   T14 a grow that takes the row past the bio cap (8+2 -> 10+2): the
#       boundary stays at the cap (max_hw_sectors, fixed at run time), not
#       at the larger row, so bios are not cut at both; the data reads back.
#   T15 a member lost under row writes on an array with a bitmap, its
#       superblock write failing late (dm-delay over an error device) while
#       rows keep finishing on a slow healthy member: the member comes back
#       through --re-add (a bitmap resync, not a full rebuild) and the parity
#       is clean afterwards.
#   T16 degraded, with a bitmap: a row write drops the stripe cache's page
#       of the gone member (rebuilt by a degraded read through the cache), so
#       neither a later read nor a read-modify-write of the stripe uses the
#       old block; 4 KiB writes, row writes and reads race while degraded;
#       rows written while the member was gone are resynced onto it by a
#       --re-add (a healthy read is right, scrub clean).
#   T17 a second member lost under degraded row writes, its writes failing
#       (dm error): rows whose writes fail on it, with one member already
#       gone, still complete (m=2); the data reads back right.
#   T18 the stripe path with a bitmap (row path off): 4 KiB random writes
#       against 1 MiB full-stripe writes, healthy then degraded -- every
#       write completes.  The bitmap accounting once dropped the stripe lock
#       between the devices of one request, and a small write linked under a
#       full-stripe one was never completed.
#
# Usage: bash <this>    (CHUNK_KB default 128; RW_N/RW_M the classic geometry)
set -u
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

CHUNK_KB=${CHUNK_KB:-128}
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${RW_N:-10}; M=${RW_M:-2}
PATMB=${PATMB:-64}
RK_CREATE_EXTRA="${RK_CREATE_EXTRA:---bitmap=none}"
MEMBERS=()

cleanup() {
	[ -n "${BGPID:-}" ] && kill "$BGPID" 2>/dev/null
	# T10 trusts discard on brd only: never leave that on for the host
	[ -n "${DSAFE0:-}" ] && echo "$DSAFE0" | sudo tee "$DSAFE" >/dev/null 2>&1
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	local d t p
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
	for p in 1 2; do	# T15's dead member is a delay over rkrwerr: two passes
		for t in $(dmsetup ls 2>/dev/null | awk '/^rkrw/ {print $1}'); do
			dmsetup remove "$t" 2>/dev/null
		done
	done
}
trap cleanup EXIT

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
rk_setup_brd 12 || exit 1
DISKS=$(rk_pick_disks 12) || { echo "ERROR: need 12 devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

SYS() { echo "/sys/block/$MDNAME/md/$1"; }
row_stat() {	# never empty: an empty value would turn [ -gt ] into a green run
	local v
	v=$(sed -n "s/^$1 //p" "$(SYS rk_row_stats)" 2>/dev/null)
	echo "${v:-0}"
}
knob()   { echo "$2" | sudo tee "$(SYS "$1")" >/dev/null 2>&1; }
splats() { sudo dmesg | grep -cE "WARNING:|BUG:|KASAN:|blocked for more than"; }
dropc()  { echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; }
qlim()   { cat "/sys/block/$MDNAME/queue/$1"; }
ROWB=0	# bytes per row, set by setup

# setup <layout> <ndisks>: a fresh array with the row path on
setup() {
	rk_create "$1" "${MEMBERS[@]:0:$2}" || return 1
	knob skip_copy 1
	knob rk_row_write 1
	local m; m=$(rk_m_of "$1")
	ROWB=$(( ($2 - m) * CHUNK_KB * 1024 ))
	[ "$(cat "$(SYS rk_row_write)")" = 1 ] && [ "$(cat "$(SYS skip_copy)")" = 1 ]
}

mk_pattern() {	# mk_pattern <file> <MiB>
	dd if=/dev/urandom of="$1" bs=1M count="$2" status=none
}
# put <file> <offset bytes> <bs>: write a file to the array at an offset
put() {
	sudo dd if="$1" of="$MD" bs="$3" seek="$2" oflag=direct,seek_bytes \
		status=none 2>/dev/null
}
# same <file> <offset bytes> [bs]: array content at offset equals the file
same() {
	local len want got
	len=$(stat -c %s "$1")
	want=$(md5sum < "$1" | cut -d' ' -f1)
	dropc
	got=$(sudo dd if="$MD" bs="${3:-1M}" skip="$2" iflag=direct,skip_bytes \
		status=none 2>/dev/null | head -c "$len" | md5sum | cut -d' ' -f1)
	[ "$want" = "$got" ]
}
scrub_clean() {
	local mm
	mm=$(rk_scrub)
	[ "$mm" = 0 ] || echo "mismatch_cnt $mm" >&2
	[ "$mm" = 0 ]
}
sudo dmesg -C

# ---- T1: aligned full rows ------------------------------------------------
echo "=== T1: $((N - M))+$M rotating, ${CHUNK_KB}K chunk: aligned 1 MiB writes ==="
setup "${M}r" "$N" || { rk_fail "T1: create ${N}/${M} with row path on"; rk_summary; exit 1; }
mk_pattern "$RK_TMP/A" "$PATMB"
D0=$(row_stat write_done)
put "$RK_TMP/A" 0 1M
D1=$(row_stat write_done)
ROWS=$(( PATMB * 1048576 / ROWB ))
[ "$((D1 - D0))" -ge "$ROWS" ] && rk_pass "T1: $((D1 - D0)) rows via the row path (>= $ROWS expected)" \
	|| rk_fail "T1: write_done $D0 -> $D1, expected >= $ROWS (busy $(row_stat write_busy) nobuf $(row_stat write_nobuf) declined $(row_stat write_declined))"
same "$RK_TMP/A" 0 && rk_pass "T1: data reads back" || rk_fail "T1: data WRONG"
scrub_clean && rk_pass "T1: scrub clean" || rk_fail "T1: parity mismatch after row writes"

# ---- T2: spans with partial rows at both ends -----------------------------
echo "=== T2: spans starting and ending mid-row ==="
# The array splits bios at row boundaries (queue chunk_sectors), and the row
# path takes a bio made of whole rows: of a span starting 64K into a row,
# written as 1 MiB bios, exactly the whole rows inside each bio go to the row
# path (none with a 1 MiB row), the partial rows to the stripe cache.  The
# data must be right, and the parity.
mk_pattern "$RK_TMP/B" 20
T2OFF=$(( ROWB + 64 * 1024 ))	# starts 64K into a row
# whole_rows <offset> <MiB>: the whole rows inside the 1 MiB bios `put ... 1M`
# writes from <offset> -- what the row path can take of it
whole_rows() {
	local i s a b n=0
	for i in $(seq 0 $(( $2 - 1 ))); do
		s=$(( $1 + i * 1048576 )); a=$(( (s + ROWB - 1) / ROWB )); b=$(( (s + 1048576) / ROWB ))
		[ "$b" -gt "$a" ] && n=$(( n + b - a ))
	done
	echo "$n"
}
WANT=$(whole_rows "$T2OFF" 20)
fallbacks() { echo $(( $(row_stat write_nobuf) + $(row_stat write_busy) + $(row_stat write_declined) )); }
D0=$(row_stat write_done); F0=$(fallbacks)
put "$RK_TMP/B" "$T2OFF" 1M
D1=$(row_stat write_done); F1=$(fallbacks)
# never more rows than the bios hold whole; fewer only with a counted fallback
# (no context, a busy row, a decline: the stripe cache then writes it)
if [ "$((D1 - D0))" -gt "$WANT" ]; then
	rk_fail "T2: row path took $((D1 - D0)) row(s), more than the $WANT whole rows inside the bios"
elif [ "$((D1 - D0))" = "$WANT" ] || [ "$F1" -gt "$F0" ]; then
	rk_pass "T2: the row path took $((D1 - D0)) of the $WANT whole row(s) inside the bios ($((F1 - F0)) fallback(s))"
else
	rk_fail "T2: row path took $((D1 - D0)) row(s), $WANT whole rows inside the bios, no fallback counted"
fi
same "$RK_TMP/B" $(( ROWB + 64 * 1024 )) && rk_pass "T2: unaligned span right" \
	|| rk_fail "T2: unaligned span WRONG"
head -c "$(( ROWB + 64 * 1024 ))" "$RK_TMP/A" > "$RK_TMP/A.head"
same "$RK_TMP/A.head" 0 && rk_pass "T2: the bytes before the span untouched" \
	|| rk_fail "T2: bytes before the span CHANGED"
scrub_clean && rk_pass "T2: scrub clean" || rk_fail "T2: parity mismatch"

# ---- T3: stale stripe-cache pages ----------------------------------------
# On a healthy array reads bypass the stripe cache (split per chunk, one
# member each), so what the cache keeps is parity: a 4 KiB write is a
# read-modify-write that leaves the stripe's parity pages cached and
# up-to-date.  A row write then rewrites the members underneath.  If those
# pages survived it, the next 4 KiB write to the same stripe would compute
# its parity from the old parity -- wrong on disk, caught by the scrub, and
# by a degraded read of the member that write missed.
echo "=== T3: cached stripe pages are dropped by a row write ==="
SPAN=16
NROWS=$(( SPAN * 1048576 / ROWB ))
mk_pattern "$RK_TMP/C1" "$SPAN"; mk_pattern "$RK_TMP/C2" "$SPAN"
put "$RK_TMP/C1" 0 1M
# prime: in every row, 4 KiB into chunk 1 at block 2 -> that stripe's parity
# is now cached
for r in $(seq 0 $((NROWS - 1))); do
	dd if=/dev/urandom of="$RK_TMP/blk" bs=4096 count=1 status=none
	put "$RK_TMP/blk" $(( r * ROWB + 1 * CHUNK_KB * 1024 + 2 * 4096 )) 4096
done
D0=$(row_stat write_done)
put "$RK_TMP/C2" 0 1M		# no drop_caches: md's stripe cache is what matters
D1=$(row_stat write_done)
[ "$((D1 - D0))" -ge "$NROWS" ] && rk_pass "T3: the rewrite took the row path ($((D1 - D0)) rows)" \
	|| rk_fail "T3: the rewrite did not take the row path ($D0 -> $D1): the test proves nothing"
# the same stripes again: 4 KiB into chunk 3 at block 2 (same stripe head,
# another data block), a read-modify-write against whatever parity is cached
cp "$RK_TMP/C2" "$RK_TMP/C3"
for r in $(seq 0 $((NROWS - 1))); do
	off=$(( r * ROWB + 3 * CHUNK_KB * 1024 + 2 * 4096 ))
	dd if=/dev/urandom of="$RK_TMP/blk" bs=4096 count=1 status=none
	put "$RK_TMP/blk" "$off" 4096
	dd if="$RK_TMP/blk" of="$RK_TMP/C3" bs=4096 seek="$off" oflag=seek_bytes conv=notrunc status=none
done
same "$RK_TMP/C3" 0 && rk_pass "T3: data right after the read-modify-writes" \
	|| rk_fail "T3: data WRONG after read-modify-writes"
scrub_clean && rk_pass "T3: scrub clean (no read-modify-write used a stale cached parity)" \
	|| rk_fail "T3: parity mismatch: a stale cached page fed a read-modify-write"

# ---- T4: races over the same rows --------------------------------------------
echo "=== T4: 4 KiB writes, row writes and stripe-cache reads on the same rows ==="
RSPAN=$(( 8 * ROWB ))	# eight rows: plenty of collisions
B0=$(row_stat write_busy); D0=$(row_stat write_done)
sudo fio --output="$RK_TMP/t4.fio" --filename="$MD" --direct=1 --ioengine=libaio \
	--time_based --runtime=25 --group_reporting --size="$RSPAN" \
	--name=small --rw=randwrite --bs=4k --iodepth=16 --numjobs=2 \
	--name=rows --rw=randwrite --bs=1M --blockalign="$ROWB" --iodepth=4 --numjobs=2 \
	--name=reads --rw=randread --bs=8k --blockalign=4k --offset=4k --iodepth=8 --numjobs=1 \
	>/dev/null 2>&1
B1=$(row_stat write_busy); D1=$(row_stat write_done)
[ "$((D1 - D0))" -gt 0 ] && rk_pass "T4: row writes ran in the mix ($((D1 - D0)) rows, $((B1 - B0)) found their row busy)" \
	|| rk_fail "T4: no row write ran in the mix"
scrub_clean && rk_pass "T4: scrub clean after the races" || rk_fail "T4: parity mismatch after the races"
mk_pattern "$RK_TMP/D" 8
put "$RK_TMP/D" 0 1M
same "$RK_TMP/D" 0 && rk_pass "T4: a pass written afterwards reads back right" || rk_fail "T4: data WRONG afterwards"

# ---- T5: degraded and rebuild ----------------------------------------------
echo "=== T5: fail a member after row writes; rebuild onto a spare ==="
CS0=$(qlim chunk_sectors)
put "$RK_TMP/A" 0 1M
rk_fail_disks "${MEMBERS[2]}"
same "$RK_TMP/A" 0 && rk_pass "T5: degraded read decodes the row path's parity" \
	|| rk_fail "T5: degraded read WRONG"
D0=$(row_stat write_done); G0=$(row_stat write_degraded); F0=$(fallbacks)
put "$RK_TMP/B" 0 1M
D1=$(row_stat write_done); G1=$(row_stat write_degraded); F1=$(fallbacks)
ROWS=$(whole_rows 0 20)
# every row write here is a degraded one; fewer than all the rows only with
# a counted fallback (a busy row, no context: the stripe cache writes it)
if [ "$((G1 - G0))" != "$((D1 - D0))" ] || [ "$((G1 - G0))" = 0 ]; then
	rk_fail "T5: degraded: write_done $D0 -> $D1, write_degraded $G0 -> $G1"
elif [ "$((G1 - G0))" -ge "$ROWS" ] || [ "$F1" -gt "$F0" ]; then
	rk_pass "T5: $((G1 - G0)) of $ROWS rows via the row path while degraded ($((F1 - F0)) fallback(s))"
else
	rk_fail "T5: $((G1 - G0)) of $ROWS rows via the row path while degraded, no fallback counted"
fi
same "$RK_TMP/B" 0 && rk_pass "T5: degraded writes right" || rk_fail "T5: degraded write WRONG"
rk_remove_disks "${MEMBERS[2]}"
sudo "$MDADM" --zero-superblock "${MEMBERS[2]}" 2>/dev/null
rk_throttle 20000
rk_add_disks "${MEMBERS[10]}"
if rk_wait_recovery_active; then
	# the spare is in sync only up to recovery_offset: the stripe path's
	# business, and the recovery pass fences row writes anyway
	D0=$(row_stat write_done)
	put "$RK_TMP/B" 0 1M		# the same bytes: the checks below hold
	[ "$(row_stat write_done)" = "$D0" ] && rk_pass "T5: row writes decline while the spare recovers" \
		|| rk_log "T5: $(( $(row_stat write_done) - D0 )) row writes during the recovery (it may have ended early)"
else
	rk_log "T5: recovery not seen in flight; the decline during it is not checked"
fi
rk_unthrottle
rk_wait_full 2>/dev/null || rk_wait_idle
grep -A1 "^$MDNAME" /proc/mdstat | grep -q "\[$(printf 'U%.0s' $(seq 1 "$N"))\]" && rk_pass "T5: rebuilt onto the spare" \
	|| rk_fail "T5: array not back to $N/$N: $(grep -A1 "^$MDNAME" /proc/mdstat | tail -1)"
# adding a member must not re-stack the limits under the row boundary (a
# spare's own chunk_sectors would gcd into it): raidkm never re-stacks
[ "$(qlim chunk_sectors)" = "$CS0" ] && rk_pass "T5: chunk_sectors $CS0 unchanged by the spare and the rebuild" \
	|| rk_fail "T5: chunk_sectors $CS0 -> $(qlim chunk_sectors) after the spare and the rebuild"
same "$RK_TMP/B" 0 && rk_pass "T5: data right after the rebuild" || rk_fail "T5: data WRONG after rebuild"
D0=$(row_stat write_done)
put "$RK_TMP/A" 0 1M
[ "$(row_stat write_done)" -gt "$D0" ] && rk_pass "T5: row path back on the healthy array" \
	|| rk_fail "T5: row path did not come back after the rebuild"
scrub_clean && rk_pass "T5: scrub clean after the rebuild" || rk_fail "T5: parity mismatch after the rebuild"

# ---- T6: one context, many writers ---------------------------------------------
# Depth = the rows in one 1 MiB bio: a bio takes the row path only with a
# context for every row (all or nothing), so this is the smallest depth at
# which it can at all, and 32 bios in flight compete for it.
TDEPTH=$(( 1048576 / ROWB ))
if [ "$TDEPTH" -lt 1 ]; then
	# a row over 1 MiB: dd/fio's 1 MiB bios never hold one, nothing to share
	rk_skip_check "T6: rows of $((ROWB / 1024)) KiB exceed a 1 MiB bio"
else
echo "=== T6: rk_row_write_depth=$TDEPTH under 4 writers x QD8 ==="
knob rk_row_write_depth "$TDEPTH"
NB0=$(row_stat write_nobuf); D0=$(row_stat write_done)
if sudo fio --output="$RK_TMP/t6.fio" --filename="$MD" --direct=1 --ioengine=libaio \
	--name=v --rw=write --bs=1M --iodepth=8 --numjobs=4 --size=24M \
	--offset_increment=24M --verify=crc32c --verify_fatal=1 --group_reporting \
	>/dev/null 2>&1; then
	rk_pass "T6: fio write+verify clean"
else
	rk_fail "T6: fio verify FAILED (see $RK_TMP/t6.fio)"
fi
NB1=$(row_stat write_nobuf); D1=$(row_stat write_done)
[ "$((NB1 - NB0))" -gt 0 ] && [ "$((D1 - D0))" -gt 0 ] \
	&& rk_pass "T6: rows shared out ($((D1 - D0)) row path, $((NB1 - NB0)) without a context -> stripe cache)" \
	|| rk_fail "T6: expected both paths (done +$((D1 - D0)), nobuf +$((NB1 - NB0)))"
fi
knob rk_row_write_depth 64
scrub_clean && rk_pass "T6: scrub clean" || rk_fail "T6: parity mismatch"

# ---- T7: a scrub running under row writes ------------------------------------
echo "=== T7: row writes while a check pass runs ==="
rk_throttle 20000
echo check | sudo tee "$(SYS sync_action)" >/dev/null
sleep 1
D0=$(row_stat write_done)
for i in 1 2 3; do put "$RK_TMP/A" 0 1M; done
D1=$(row_stat write_done)
rk_unthrottle
rk_wait_idle
[ "$D1" = "$D0" ] && rk_pass "T7: row writes stood aside during the pass" \
	|| rk_log "T7: $((D1 - D0)) row writes during the pass (the pass may have ended early)"
same "$RK_TMP/A" 0 && rk_pass "T7: data right" || rk_fail "T7: data WRONG"
scrub_clean && rk_pass "T7: scrub clean" || rk_fail "T7: parity mismatch"

# ---- T9: control --------------------------------------------------------------
echo "=== T9: rk_row_write=0 control ==="
knob rk_row_write 0
D0=$(row_stat write_done)
put "$RK_TMP/B" 0 1M
[ "$(row_stat write_done)" = "$D0" ] && rk_pass "T9: knob off, row path off" \
	|| rk_fail "T9: write_done moved with rk_row_write=0"
same "$RK_TMP/B" 0 && rk_pass "T9: stripe-cache write right" || rk_fail "T9: data WRONG"

# ---- T8: other generators and layouts --------------------------------------
for geo in "3r 11" "4r 12" "2 10"; do
	set -- $geo
	echo "=== T8: layout $1 on $2 members ==="
	if setup "$1" "$2"; then
		D0=$(row_stat write_done)
		put "$RK_TMP/A" 0 1M
		[ "$(row_stat write_done)" -gt "$D0" ] && rk_pass "T8[$1]: row path ran" \
			|| rk_fail "T8[$1]: row path did not run"
		same "$RK_TMP/A" 0 && rk_pass "T8[$1]: data right" || rk_fail "T8[$1]: data WRONG"
		scrub_clean && rk_pass "T8[$1]: scrub clean (parity matches the stripe path's generator)" \
			|| rk_fail "T8[$1]: parity mismatch"
		rk_fail_disks "${MEMBERS[0]}" "${MEMBERS[1]}"
		same "$RK_TMP/A" 0 && rk_pass "T8[$1]: two members failed, data decodes right" \
			|| rk_fail "T8[$1]: double-degraded read WRONG"
		G0=$(row_stat write_degraded)
		put "$RK_TMP/B" 0 1M
		[ "$(row_stat write_degraded)" -gt "$G0" ] && rk_pass "T8[$1]: row writes with two members gone" \
			|| rk_fail "T8[$1]: no row write with two members gone (declined $(row_stat write_declined))"
		same "$RK_TMP/B" 0 && rk_pass "T8[$1]: rows written with two members gone read back right" \
			|| rk_fail "T8[$1]: rows written with two members gone WRONG"
	else
		rk_fail "T8[$1]: create"
	fi
done

# ---- T10: write-intent bitmap ---------------------------------------------
# The row path counts each row in the bitmap and flushes it before the row's
# member writes (as the stripe path parks a stripe on bitmap_list until
# raid5d does).  Right after row writes, and before the bitmap daemon clears
# anything (daemon_sleep 5 s, two passes), the members' bitmaps show dirty
# chunks -- set by the row path, since nothing else wrote.
echo "=== T10: internal write-intent bitmap ==="
DSAFE=/sys/module/raidkm/parameters/devices_handle_discard_safely
DSAFE0=$(cat "$DSAFE" 2>/dev/null)
echo Y | sudo tee "$DSAFE" >/dev/null 2>&1	# brd discards safely: let T10 discard
if RK_CREATE_EXTRA="--bitmap=internal --bitmap-chunk=4M" setup "${M}r" "$N"; then
	sleep 12	# let the create's own bits clear
	D0=$(row_stat write_done)
	put "$RK_TMP/A" 0 1M
	DIRTY=$(sudo "$MDADM" -X "${MEMBERS[0]}" 2>/dev/null | sed -n 's/.* \([0-9]*\) dirty.*/\1/p' | head -1)
	[ "$(row_stat write_done)" -gt "$D0" ] && rk_pass "T10: row path runs with a bitmap" \
		|| rk_fail "T10: row path did not run with a bitmap"
	[ "${DIRTY:-0}" -gt 0 ] && rk_pass "T10: $DIRTY dirty bitmap chunk(s) right after the row writes" \
		|| rk_fail "T10: bitmap shows ${DIRTY:-?} dirty chunks after row writes"
	same "$RK_TMP/A" 0 && rk_pass "T10: data right" || rk_fail "T10: data WRONG"
	scrub_clean && rk_pass "T10: scrub clean" || rk_fail "T10: parity mismatch"
	# every count md core started is ended: on a healthy, idle array the
	# bits clear (two daemon passes, daemon_sleep 5 s) -- after row writes,
	# 4 KiB stripe-path writes and a discard of whole rows
	for r in $(seq 0 15); do
		dd if=/dev/urandom of="$RK_TMP/blk" bs=4096 count=1 status=none
		put "$RK_TMP/blk" $(( r * ROWB + 3 * 4096 )) 4096
	done
	put "$RK_TMP/A" 0 1M
	if sudo blkdiscard -o $(( 32 * ROWB )) -l $(( 8 * ROWB )) "$MD" 2>/dev/null; then
		rk_pass "T10: a discard of whole rows went through"
	else
		rk_log "T10: the array refused the discard (no discard support)"
	fi
	t0=$SECONDS
	while :; do
		DIRTY=$(sudo "$MDADM" -X "${MEMBERS[0]}" 2>/dev/null | sed -n 's/.* \([0-9]*\) dirty.*/\1/p' | head -1)
		[ "${DIRTY:-1}" = 0 ] || [ $(( SECONDS - t0 )) -ge 40 ] && break
		sleep 2
	done
	[ "${DIRTY:-?}" = 0 ] && rk_pass "T10: every bit cleared once idle ($(( SECONDS - t0 )) s): starts and ends balance" \
		|| rk_fail "T10: ${DIRTY:-?} bitmap chunk(s) still dirty 40 s after the writes: a count was never ended"
else
	rk_fail "T10: create with an internal bitmap"
fi
[ -n "$DSAFE0" ] && echo "$DSAFE0" | sudo tee "$DSAFE" >/dev/null 2>&1

# ---- T11: rows over 1 MiB ---------------------------------------------------
# 10+2 at CHUNK_KB: a row of 10 chunks (1.25 MiB at 128K).  The array takes
# bios of a whole row (raid5_set_limits raises max_hw_sectors to io_opt), and
# the request context's stripe bitmap is sized for them (raid5_create_ctx_pool)
# -- it used to be a fixed 1 MiB bitmap on the stack.  A bio over 1 MiB needs
# physically contiguous pages (a bio holds 256 segments), so the writer uses
# huge pages; ordinary 4 KiB pages reach md as bios of at most 1 MiB, and
# then no bio holds a whole row.  fio verifies the data itself.
echo "=== T11: rows over 1 MiB (10+2) ==="
ROW11=$(( 10 * CHUNK_KB * 1024 ))
if [ "$ROW11" -le 1048576 ]; then
	rk_skip_check "T11: a 10+2 row at ${CHUNK_KB}K is $((ROW11 / 1024)) KiB, not over 1 MiB"
elif setup "${M}r" 12; then
	MAXKB=$(cat "/sys/block/$MDNAME/queue/max_hw_sectors_kb")
	[ $((MAXKB * 1024)) -ge "$ROWB" ] && rk_pass "T11: the array takes whole-row bios (max_hw_sectors_kb $MAXKB, row $((ROWB / 1024)) KiB)" \
		|| rk_fail "T11: max_hw_sectors_kb $MAXKB below the row ($((ROWB / 1024)) KiB)"
	HP0=$(cat /proc/sys/vm/nr_hugepages)
	echo 64 | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
	if [ "$(awk '/HugePages_Free/{print $2}' /proc/meminfo)" -ge 8 ]; then
		for arm in 1 0; do
			knob rk_row_write "$arm"
			D0=$(row_stat write_done)
			if sudo fio --output="$RK_TMP/t11-$arm.fio" --name=w --filename="$MD" \
				--direct=1 --ioengine=libaio --rw=write --bs="$ROWB" --iodepth=4 \
				--size=$(( 48 * ROWB )) --iomem=shmhuge --verify=crc32c \
				--verify_fatal=1 >/dev/null 2>&1; then
				rk_pass "T11[row_write=$arm]: fio write+verify of whole-row bios clean"
			else
				rk_fail "T11[row_write=$arm]: fio verify FAILED ($RK_TMP/t11-$arm.fio)"
			fi
			D1=$(row_stat write_done)
			if [ "$arm" = 1 ]; then
				[ "$((D1 - D0))" -ge 40 ] && rk_pass "T11: $((D1 - D0)) rows of $((ROWB / 1024)) KiB via the row path" \
					|| rk_fail "T11: row path took $((D1 - D0)) of 48 rows"
			fi
			scrub_clean && rk_pass "T11[row_write=$arm]: scrub clean" \
				|| rk_fail "T11[row_write=$arm]: parity mismatch"
		done
	else
		rk_skip_check "T11: no huge pages to write whole-row bios from"
	fi
	echo "$HP0" | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
else
	rk_fail "T11: create 10+2 (row $((ROWB / 1024)) KiB)"
fi

# ---- T12: the row boundary ---------------------------------------------------
# raid5_set_limits() sets queue chunk_sectors to the row so the block layer
# splits bios at rows; a reshape moves it with io_opt.  Without it, a bio over
# max_sectors (1 MiB) is cut into pieces counted from the bio's own start: one
# starting mid-row reaches us as pieces that each straddle two rows, and its
# whole rows go to the stripe cache.  Bios of one and a half rows from huge
# pages (one bio each, as in T11): every bio holds one whole row, half of them
# from a mid-row start.
echo "=== T12: bios split at row boundaries (6+2, grown to 8+2) ==="
t12_write() {	# t12_write <tag>: 16 bios of 1.5 rows; one row each on the row path
	local bs=$(( ROWB * 3 / 2 )) d0 d1
	d0=$(row_stat write_done)
	if sudo fio --output="$RK_TMP/t12-$1.fio" --name=w --filename="$MD" \
		--direct=1 --ioengine=libaio --rw=write --bs="$bs" --iodepth=4 \
		--size=$(( 16 * bs )) --iomem=shmhuge --verify=crc32c \
		--verify_fatal=1 >/dev/null 2>&1; then
		rk_pass "T12[$1]: fio write+verify of 1.5-row bios clean"
	else
		rk_fail "T12[$1]: fio verify FAILED ($RK_TMP/t12-$1.fio)"
	fi
	d1=$(row_stat write_done)
	[ "$((d1 - d0))" -ge 16 ] && rk_pass "T12[$1]: $((d1 - d0)) rows via the row path (16 bios, one whole row each)" \
		|| rk_fail "T12[$1]: row path took $((d1 - d0)) rows of 16 bios holding one whole row each"
}
if setup "${M}r" $(( N - 2 )); then
	CAP=$(( $(qlim max_sectors_kb) * 2 ))
	WANT=$(( ROWB / 512 < CAP ? ROWB / 512 : CAP ))
	[ "$(qlim chunk_sectors)" = "$WANT" ] && rk_pass "T12: chunk_sectors $WANT (the $(( N - 2 - M ))+$M row $(( ROWB / 512 )), bio cap $CAP)" \
		|| rk_fail "T12: chunk_sectors $(qlim chunk_sectors), want $WANT (row $(( ROWB / 512 )), bio cap $CAP)"
	HP0=$(cat /proc/sys/vm/nr_hugepages)
	echo 64 | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
	HPOK=0; [ "$(awk '/HugePages_Free/{print $2}' /proc/meminfo)" -ge 8 ] && HPOK=1
	if [ "$HPOK" = 1 ]; then
		t12_write create
	else
		rk_skip_check "T12: no huge pages to write 1.5-row bios from"
	fi
	# the two members still carry T11's superblock, and udev may have
	# assembled them into an array of their own since: stop that, clear the
	# superblock, then add them
	for d in "${MEMBERS[@]:$(( N - 2 )):2}"; do
		for h in /sys/block/"$(basename "$d")"/holders/md*; do
			[ -e "$h" ] && sudo "$MDADM" --stop "/dev/$(basename "$h")" >/dev/null 2>&1
		done
		sudo "$MDADM" --zero-superblock "$d" >/dev/null 2>&1
	done
	if ! sudo "$MDADM" --add "$MD" "${MEMBERS[@]:$(( N - 2 )):2}" >/dev/null 2>&1; then
		rk_fail "T12: add ${MEMBERS[*]:$(( N - 2 )):2} as spares for the grow"
	elif sudo "$MDADM" --grow "$MD" --raid-devices="$N" --backup-file="$RK_TMP/t12.bak" >/dev/null 2>&1; then
		sleep 1; rk_wait_idle
		ROWB=$(( (N - M) * CHUNK_KB * 1024 ))
		# the bio cap is fixed at run time: a row grown past it keeps the
		# boundary at the cap, and no bio holds a whole row then
		CAP=$(( $(qlim max_sectors_kb) * 2 ))
		WANT=$(( ROWB / 512 < CAP ? ROWB / 512 : CAP ))
		[ "$(qlim chunk_sectors)" = "$WANT" ] && rk_pass "T12: after the grow chunk_sectors $WANT (the $(( N - M ))+$M row $(( ROWB / 512 )), bio cap $CAP)" \
			|| rk_fail "T12: after the grow chunk_sectors $(qlim chunk_sectors), want $WANT (row $(( ROWB / 512 )), bio cap $CAP)"
		# a bio over the cap is split at the cap and the row, so its whole
		# row still goes through -- unless the row itself is over the cap
		if [ "$HPOK" = 1 ] && [ $(( ROWB / 512 )) -le "$CAP" ]; then
			t12_write grown
		elif [ "$HPOK" = 1 ]; then
			rk_skip_check "T12[grown]: the row ($(( ROWB / 1024 )) KiB) is over the bio cap"
		fi
		scrub_clean && rk_pass "T12: scrub clean after the grow" || rk_fail "T12: parity mismatch after the grow"
	else
		rk_fail "T12: grow to $N devices"
	fi
	echo "$HP0" | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
else
	rk_fail "T12: create $(( N - 2 - M ))+$M"
fi

# ---- T13: a chunk-size reshape ------------------------------------------------
# The live io_min is the old chunk after it, so the limits are recomputed from
# the new geometry (raidkm_update_row_limits), not carried over.
echo "=== T13: chunk-size reshape ${CHUNK_KB}K -> $((CHUNK_KB / 2))K ==="
if [ "$CHUNK_KB" -lt 8 ]; then
	rk_skip_check "T13: a ${CHUNK_KB}K chunk cannot be halved"
elif setup "${M}r" "$N"; then
	mk_pattern "$RK_TMP/E" 32
	put "$RK_TMP/E" 0 1M
	NEWC=$(( CHUNK_KB / 2 ))
	if echo $(( NEWC * 1024 )) | sudo tee "$(SYS chunk_size)" >/dev/null 2>&1 &&
	   echo reshape | sudo tee "$(SYS sync_action)" >/dev/null 2>&1; then
		rk_wait_pass
		ROWB=$(( (N - M) * NEWC * 1024 ))
		lims="$(qlim chunk_sectors) $(qlim minimum_io_size) $(qlim optimal_io_size)"
		[ "$lims" = "$(( ROWB / 512 )) $(( NEWC * 1024 )) $ROWB" ] \
			&& rk_pass "T13: chunk_sectors, minimum_io_size, optimal_io_size follow the ${NEWC}K chunk ($lims)" \
			|| rk_fail "T13: limits after the reshape '$lims', want '$(( ROWB / 512 )) $(( NEWC * 1024 )) $ROWB'"
		same "$RK_TMP/E" 0 && rk_pass "T13: data reads back after the reshape" || rk_fail "T13: data WRONG after the reshape"
		mk_pattern "$RK_TMP/F" 8
		D0=$(row_stat write_done)
		put "$RK_TMP/F" 0 "$ROWB"
		D1=$(row_stat write_done)
		[ "$((D1 - D0))" -ge $(( 8 * 1048576 / ROWB - 1 )) ] && rk_pass "T13: $((D1 - D0)) whole ${ROWB}-byte rows via the row path" \
			|| rk_fail "T13: row path took $((D1 - D0)) rows of $(( 8 * 1048576 / ROWB ))"
		scrub_clean && rk_pass "T13: scrub clean" || rk_fail "T13: parity mismatch after the reshape"
	else
		rk_skip_check "T13: md would not start a chunk-size reshape"
	fi
else
	rk_fail "T13: create ${N}/${M}"
fi

# ---- T14: a grow past the bio cap ---------------------------------------------
# raid5_set_limits() raises the bio cap to the row only at run time; a grow
# that makes the row larger than it keeps the cap, and the boundary must not
# go past it, or bios would be cut at both (cap, then row).
echo "=== T14: grow $((N - M))+$M -> $((N + 2 - M))+$M: the boundary stays at the bio cap ==="
if [ ${#MEMBERS[@]} -lt $(( N + 2 )) ]; then
	rk_skip_check "T14: needs $(( N + 2 )) members"
elif setup "${M}r" "$N"; then
	mk_pattern "$RK_TMP/G" 16
	put "$RK_TMP/G" 0 1M
	CAP=$(( $(qlim max_hw_sectors_kb) * 2 ))
	NEWROW=$(( (N + 2 - M) * CHUNK_KB * 2 ))
	for d in "${MEMBERS[@]:$N:2}"; do
		for h in /sys/block/"$(basename "$d")"/holders/md*; do
			[ -e "$h" ] && sudo "$MDADM" --stop "/dev/$(basename "$h")" >/dev/null 2>&1
		done
		sudo "$MDADM" --zero-superblock "$d" >/dev/null 2>&1
	done
	if ! sudo "$MDADM" --add "$MD" "${MEMBERS[@]:$N:2}" >/dev/null 2>&1; then
		rk_fail "T14: add ${MEMBERS[*]:$N:2} as spares for the grow"
	elif sudo "$MDADM" --grow "$MD" --raid-devices=$(( N + 2 )) --backup-file="$RK_TMP/t14.bak" >/dev/null 2>&1; then
		sleep 1; rk_wait_idle
		WANT=$(( NEWROW < CAP ? NEWROW : CAP ))
		[ "$(qlim chunk_sectors)" = "$WANT" ] \
			&& rk_pass "T14: chunk_sectors $WANT (row $NEWROW, bio cap $CAP)" \
			|| rk_fail "T14: chunk_sectors $(qlim chunk_sectors), want $WANT (row $NEWROW, bio cap $CAP)"
		same "$RK_TMP/G" 0 && rk_pass "T14: data reads back after the grow" || rk_fail "T14: data WRONG after the grow"
	else
		rk_fail "T14: grow to $(( N + 2 )) devices"
	fi
else
	rk_fail "T14: create ${N}/${M}"
fi

# ---- T15: a member lost while its superblock write fails ------------------------
# A member dies under row writes.  Its first failed row records a bad block,
# which asks for a superblock write (MD_SB_CHANGE_PENDING, events + 1); that
# write fails on the dead member, and only then is the member failed.  A row
# that ends its bitmap write inside that window -- the array still not
# degraded -- moves events_cleared past the member's events, and the member's
# re-add is refused for good (a full rebuild).  Here the dead member's
# metadata writes fail only after a second (dm-delay over an error device) and
# member 0's writes take 50 ms, so rows keep finishing through the window.
# Without the wait in raidkm_row_write_done() 10 of 12 rounds were refused
# (four runs, each failed); with it none.
t15() {
local i sz doff x r t0 saved=("${MEMBERS[@]}") dm=() ok=0 bad=() rig=()
modprobe dm-delay 2>/dev/null
if ! dmsetup targets 2>/dev/null | grep -q '^delay'; then
	rk_skip_check "T15: no dm-delay target on this kernel"
	return
fi
rk_stop
for i in $(seq 0 $(( N - 1 ))); do
	"$MDADM" --zero-superblock "${saved[$i]}" 2>/dev/null
	dd if=/dev/zero of="${saved[$i]}" bs=1M count=4 status=none 2>/dev/null
done
rk_udev_quiesce
sz=$(blockdev --getsz "${saved[0]}")
dmsetup create rkrwerr --table "0 $sz error" || { rk_fail "T15: error device"; return; }
for i in $(seq 0 $(( N - 1 ))); do
	dmsetup create "rkrw$i" --table "0 $sz linear ${saved[$i]} 0" ||
		{ rk_fail "T15: dm-linear setup"; break; }
	dm+=("/dev/mapper/rkrw$i")
done
udevadm settle 2>/dev/null
MEMBERS=("${dm[@]}")
if [ "${#dm[@]}" = "$N" ] &&
   RK_CREATE_EXTRA="--bitmap=internal --bitmap-chunk=4M" setup "${M}r" "$N"; then
	doff=$("$MDADM" -E "${dm[1]}" | sed -n 's/.*Data Offset : \([0-9]*\) sectors.*/\1/p')
	# the slow healthy member, now that the create's resync is over
	if [ -z "$doff" ] ||
	   ! dmsetup load rkrw0 --table "0 $sz delay ${saved[0]} 0 0 ${saved[0]} 0 50" ||
	   ! dmsetup resume rkrw0; then
		rk_fail "T15: rig: data offset '$doff' from mdadm -E, or member 0's delay table"
	else
	for x in 3 6 9; do
		[ "$x" -lt "$N" ] || continue
		sleep 6		# a quiet array: the bitmap catches up
		fio --name=rows --filename="$MD" --rw=write --bs="$ROWB" --direct=1 \
		    --ioengine=libaio --iodepth=16 --time_based --runtime=60 \
		    --output="$RK_TMP/fio-t15.out" >/dev/null 2>&1 &
		BGPID=$!
		sleep 2
		printf '0 %s delay /dev/mapper/rkrwerr 0 0 /dev/mapper/rkrwerr 0 1000\n%s %s error\n' \
			"$doff" "$doff" $(( sz - doff )) | dmsetup load "rkrw$x" &&
			dmsetup resume "rkrw$x" || rig+=("member $x: dead table not loaded")
		t0=$SECONDS
		while [ "$(cat "$(SYS degraded)")" = 0 ] && [ $(( SECONDS - t0 )) -lt 20 ]; do
			sleep 0.2
		done
		kill "$BGPID" 2>/dev/null; wait "$BGPID" 2>/dev/null; BGPID=
		dmsetup load "rkrw$x" --table "0 $sz linear ${saved[$x]} 0" &&
			dmsetup resume "rkrw$x" || rig+=("member $x: linear table not restored")
		if [ "$(cat "$(SYS degraded)")" = 0 ]; then
			rig+=("member $x: not failed within 20 s")
			continue
		fi
		for r in $(seq 50); do
			"$MDADM" "$MD" --remove "${dm[$x]}" >/dev/null 2>&1 && break
			sleep 0.2
		done
		if "$MDADM" "$MD" --re-add "${dm[$x]}" >/dev/null 2>&1; then
			ok=$(( ok + 1 ))
		else
			bad+=("member $x: events $("$MDADM" -E "${dm[$x]}" | sed -n 's/.* Events : //p'), bitmap $("$MDADM" -X "${dm[1]}" | sed -n 's/^ *Events Cleared : /events_cleared /p')")
			"$MDADM" "$MD" --add "${dm[$x]}" >/dev/null 2>&1
		fi
		sleep 1; rk_wait_full 2>/dev/null || rk_wait_idle
	done
	# a round whose member never failed says nothing about the re-add
	[ "${#rig[@]}" = 0 ] || rk_fail "T15: rig, not a re-add verdict: ${rig[*]}"
	if [ "${#bad[@]}" -gt 0 ]; then
		rk_fail "T15: re-add refused ${#bad[@]} times (${bad[*]}), accepted $ok"
	elif [ "$ok" -gt 0 ]; then
		rk_pass "T15: $ok lost members came back through --re-add"
	fi
	[ "$(cat "$(SYS degraded)")" = 0 ] && scrub_clean &&
		rk_pass "T15: back in sync, scrub clean" ||
		rk_fail "T15: degraded $(cat "$(SYS degraded)") or parity mismatch after the resyncs"
	fi
else
	rk_fail "T15: setup"
fi
rk_stop
udevadm settle 2>/dev/null	# udev still holding one fails its remove
for i in "${dm[@]}"; do
	"$MDADM" --zero-superblock "$i" 2>/dev/null
	dmsetup remove --retry "$(basename "$i")" 2>/dev/null
done
dmsetup remove --retry rkrwerr 2>/dev/null
MEMBERS=("${saved[@]}")
rk_udev_quiesce
}
echo "=== T15: a member lost while its superblock write fails: re-add through the bitmap ==="
t15

# ---- T16: degraded, with a bitmap -------------------------------------------
# A gone member is not written by a row write, but the stripe cache may hold
# a page for it: a degraded read through the cache (rk_row_dread 0) rebuilds
# the gone block from the others and keeps it, up to date.  The row write
# must drop that page as it drops the others (raidkm_row_write_lock), or the
# cache serves the old block to the next read of it, and a reconstruct-write
# of the stripe encodes it into the new parity.  Then the races of T4, degraded,
# and a --re-add: what the row path wrote while the member was gone must be
# on it after the bitmap resync, which a healthy read of every chunk shows.
t16() {
local gone r c off g0 g1 nrows k=$(( N - M ))
if ! RK_CREATE_EXTRA="--bitmap=internal --bitmap-chunk=4M" setup "${M}r" "$N"; then
	rk_fail "T16: create with an internal bitmap"
	return
fi
if [ "$(whole_rows 0 16)" = 0 ]; then
	# a row over 1 MiB: dd's 1 MiB bios never hold one, the checks would
	# pass with no row write at all
	rk_skip_check "T16: rows of $((ROWB / 1024)) KiB exceed a 1 MiB bio"
	return
fi
put "$RK_TMP/A" 0 1M
gone=${MEMBERS[3]}
rk_fail_disks "$gone"
rk_remove_disks "$gone"
nrows=$(( 16 * 1048576 / ROWB ))	# the rows primed
mk_pattern "$RK_TMP/C1" 16; mk_pattern "$RK_TMP/C2" 16
put "$RK_TMP/C1" 0 1M
knob rk_row_dread 0	# degraded reads through the stripe cache
for r in $(seq 0 $((nrows - 1))); do	# leave the gone block cached
	dd if=/dev/urandom of="$RK_TMP/blk" bs=4096 count=1 status=none
	put "$RK_TMP/blk" $(( r * ROWB + 1 * CHUNK_KB * 1024 + 2 * 4096 )) 4096
	for c in $(seq 0 $(( k - 1 ))); do	# block 2 of every chunk: the gone one too
		sudo dd if="$MD" of=/dev/null bs=4096 count=1 iflag=direct,skip_bytes \
			skip=$(( r * ROWB + c * CHUNK_KB * 1024 + 2 * 4096 )) status=none 2>/dev/null
	done
done
g0=$(row_stat write_degraded)
put "$RK_TMP/C2" 0 1M
g1=$(row_stat write_degraded)
[ "$((g1 - g0))" -ge "$(whole_rows 0 16)" ] && rk_pass "T16: the rewrite took the row path while degraded ($((g1 - g0)) rows)" \
	|| rk_fail "T16: the degraded rewrite did not take the row path ($g0 -> $g1): the test proves nothing"
cp "$RK_TMP/C2" "$RK_TMP/C3"
for r in $(seq 0 $((nrows - 1))); do
	off=$(( r * ROWB + 3 * CHUNK_KB * 1024 + 2 * 4096 ))
	dd if=/dev/urandom of="$RK_TMP/blk" bs=4096 count=1 status=none
	put "$RK_TMP/blk" "$off" 4096
	dd if="$RK_TMP/blk" of="$RK_TMP/C3" bs=4096 seek="$off" oflag=seek_bytes conv=notrunc status=none
done
same "$RK_TMP/C3" 0 && rk_pass "T16: degraded read through the stripe cache right (no stale page of the gone member)" \
	|| rk_fail "T16: degraded read through the stripe cache WRONG: it kept the gone member's old block over a row write"
knob rk_row_dread 1	# decoded from the members: what is on disk
same "$RK_TMP/C3" 0 && rk_pass "T16: degraded read through the row layer right (the parity on disk is right)" \
	|| rk_fail "T16: degraded read through the row layer WRONG: a stale cached block went into the parity"

g0=$(row_stat write_degraded)
sudo fio --output="$RK_TMP/t16.fio" --filename="$MD" --direct=1 --ioengine=libaio \
	--time_based --runtime=15 --group_reporting --size=$(( 8 * ROWB )) \
	--name=small --rw=randwrite --bs=4k --iodepth=16 --numjobs=2 \
	--name=rows --rw=randwrite --bs=1M --blockalign="$ROWB" --iodepth=4 --numjobs=2 \
	--name=reads --rw=randread --bs=8k --blockalign=4k --offset=4k --iodepth=8 --numjobs=1 \
	>/dev/null 2>&1
g1=$(row_stat write_degraded)
[ "$((g1 - g0))" -gt 0 ] && rk_pass "T16: degraded row writes ran in the mix ($((g1 - g0)) rows)" \
	|| rk_fail "T16: no degraded row write ran in the mix"

mk_pattern "$RK_TMP/F" 32
g0=$(row_stat write_degraded)
put "$RK_TMP/F" 0 1M
g1=$(row_stat write_degraded)
[ "$((g1 - g0))" -gt 0 ] && rk_pass "T16: $((g1 - g0)) rows written with the member gone" \
	|| rk_fail "T16: no row written with the member gone"
same "$RK_TMP/F" 0 && rk_pass "T16: degraded read right" || rk_fail "T16: degraded read WRONG"
if ! sudo "$MDADM" "$MD" --re-add "$gone" >/dev/null 2>&1; then
	rk_fail "T16: --re-add of the gone member refused"
	return
fi
sleep 1; rk_wait_full 2>/dev/null || rk_wait_idle
[ "$(cat "$(SYS degraded)")" = 0 ] && rk_pass "T16: back in sync after the re-add" \
	|| rk_fail "T16: degraded $(cat "$(SYS degraded)") after the re-add"
same "$RK_TMP/F" 0 && rk_pass "T16: healthy read right: the rows written while gone were resynced onto the member" \
	|| rk_fail "T16: healthy read WRONG after the re-add: the bitmap resync missed rows written while the member was gone"
scrub_clean && rk_pass "T16: scrub clean" || rk_fail "T16: parity mismatch after the re-add"
}
echo "=== T16: degraded with a bitmap: cached pages, races, re-add ==="
t16

# no superblock update pending or in flight: array_state is not write-pending
# and the event count holds still for a second (at most ~10 s)
sb_settle() {
	local i e p=""
	for i in $(seq 1 20); do
		e=$("$MDADM" --detail "$MD" 2>/dev/null | awk '/Events :/ {print $3}')
		if ! grep -q write-pending "$(SYS array_state)" && [ -n "$e" ] && [ "$e" = "$p" ]; then
			return 0
		fi
		p=$e; sleep 0.5
	done
}

# ---- T17: a second member lost under degraded row writes ----------------------
# One member gone, then another one's writes fail (dm error): each row write
# that fails on it has m - 1 = 1 gone member plus 1 failed write, within the
# parity, so the caller's write completes; md records bad blocks or fails the
# member (its superblock write fails too).  The data must read back right
# from what is left.
t17() {
local i sz x=$(( N - 1 )) rc e0 g0 saved=("${MEMBERS[@]}") dm=()
if [ "$M" -lt 2 ] || [ "$N" -lt 5 ]; then	# member 3 goes, the last one fails
	rk_skip_check "T17: needs m >= 2 and 5 members"
	return
fi
rk_stop
for i in $(seq 0 $(( N - 1 ))); do
	"$MDADM" --zero-superblock "${saved[$i]}" 2>/dev/null
	dd if=/dev/zero of="${saved[$i]}" bs=1M count=4 status=none 2>/dev/null
done
rk_udev_quiesce
sz=$(blockdev --getsz "${saved[0]}")
for i in $(seq 0 $(( N - 1 ))); do
	dmsetup create "rkrw17_$i" --table "0 $sz linear ${saved[$i]} 0" ||
		{ rk_fail "T17: dm-linear setup"; break; }
	dm+=("/dev/mapper/rkrw17_$i")
done
udevadm settle 2>/dev/null
MEMBERS=("${dm[@]}")
if [ "${#dm[@]}" = "$N" ] && setup "${M}r" "$N"; then
	put "$RK_TMP/A" 0 1M
	rk_fail_disks "${dm[3]}"
	# keep the array active: an idle one goes clean, and its next write's
	# superblock update would fail the member before any row write met it
	knob safe_mode_delay 600
	put "$RK_TMP/A" 0 1M
	# the superblock update that records the first loss must be on disk
	# before the second member's writes fail: if it comes after, it meets
	# the error table first and md fails the member before any row write
	# does (seen on RHEL 9.8: super_written error, then the failure)
	sb_settle
	e0=$(row_stat write_errors); g0=$(row_stat write_degraded)
	if dmsetup load "rkrw17_$x" --table "0 $sz error" && dmsetup resume "rkrw17_$x"; then
		put "$RK_TMP/B" 0 1M; rc=$?
		[ "$rc" = 0 ] && rk_pass "T17: the writes completed with one member gone and another failing" \
			|| rk_fail "T17: write returned an error (dd rc $rc) with one member gone and another failing"
		[ "$(row_stat write_errors)" -gt "$e0" ] && [ "$(row_stat write_degraded)" -gt "$g0" ] \
			&& rk_pass "T17: degraded row writes met the failing member (write_errors $e0 -> $(row_stat write_errors))" \
			|| rk_fail "T17: the failing member was not met by a degraded row write (write_errors $e0 -> $(row_stat write_errors), write_degraded $g0 -> $(row_stat write_degraded))"
		same "$RK_TMP/B" 0 && rk_pass "T17: data right from what is left (degraded $(cat "$(SYS degraded)"))" \
			|| rk_fail "T17: data WRONG after the second loss"
	else
		rk_fail "T17: rig: error table not loaded on member $x"
	fi
else
	rk_fail "T17: setup"
fi
rk_stop
udevadm settle 2>/dev/null
for i in "${dm[@]}"; do
	"$MDADM" --zero-superblock "$i" 2>/dev/null
	dmsetup remove --retry "$(basename "$i")" 2>/dev/null
done
MEMBERS=("${saved[@]}")
rk_udev_quiesce
}
echo "=== T17: a second member lost under degraded row writes ==="
t17

# ---- T18: small writes against full-stripe writes, bitmap, stripe path --------
# __add_stripe_bio used to drop the stripe lock for bitmap_startwrite at each
# device's first write, inside add_all_stripe_bios -- after the overlap
# checks, between the links.  A 4 KiB write could then pass its check on a
# device a 1 MiB write had not linked yet, and the 1 MiB bio was linked on
# top of it: the clean event's r5_next_bio stopped at the bio running past
# the page and never completed the 4 KiB one.  On this rig fio wedged within
# its first 15 s every time (32 writes in flight for good).  Now md core
# counts the bitmap (raidkm_bitmap_sector) and the lock stays held.  A
# wedged array cannot be stopped, so a hang ends the suite here.
t18() {	# t18 <tag>: the mix, under a deadline
	local rc inf
	timeout -s KILL 120 fio --output="$RK_TMP/t18-$1.fio" --filename="$MD" --direct=1 \
		--ioengine=libaio --time_based --runtime=20 --group_reporting \
		--size=$(( 8 * ROWB )) \
		--name=small --rw=randwrite --bs=4k --iodepth=16 --numjobs=2 \
		--name=rows --rw=randwrite --bs=1M --blockalign="$ROWB" --iodepth=4 --numjobs=2 \
		>/dev/null 2>&1
	rc=$?
	inf=$(awk '{print $2}' "/sys/block/$MDNAME/inflight")
	if [ "$rc" = 0 ] && [ "$inf" = 0 ]; then
		rk_pass "T18[$1]: every write of the mix completed"
		return 0
	fi
	rk_fail "T18[$1]: fio rc $rc, $inf writes still in flight: writes lost in the stripe cache"
	trap - EXIT	# the array cannot be stopped now
	rk_summary
	exit 1
}
echo "=== T18: 4 KiB against full-stripe writes, bitmap, stripe path ==="
if RK_CREATE_EXTRA="--bitmap=internal --bitmap-chunk=4M" setup "${M}r" "$N"; then
	knob rk_row_write 0
	t18 healthy
	rk_fail_disks "${MEMBERS[3]}"
	t18 degraded
	rk_remove_disks "${MEMBERS[3]}"
	sudo "$MDADM" --zero-superblock "${MEMBERS[3]}" 2>/dev/null
	rk_add_disks "${MEMBERS[3]}"
	sleep 1; rk_wait_full 2>/dev/null || rk_wait_idle
	scrub_clean && rk_pass "T18: scrub clean after the rebuild" || rk_fail "T18: parity mismatch"
else
	rk_fail "T18: create with an internal bitmap"
fi

[ "$(splats)" = 0 ] && rk_pass "no WARN/BUG/KASAN/hung task" || rk_fail "$(splats) kernel splat line(s)"
rk_summary
