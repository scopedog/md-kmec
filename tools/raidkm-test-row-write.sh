#!/bin/bash
# raidkm-test-row-write.sh — full-row writes through the row layer.
#
# With rk_row_write=1 a write covering a whole row (k chunks at one member
# offset) skips the 4 KiB stripe cache: parity is computed from the caller's
# pages and each member gets one request (raidkm_row_write_bio).  Everything
# here checks the bytes, the parity, or both:
#   T1  aligned 1 MiB writes take the row path (write_done moves); the data
#       reads back and a scrub finds no parity mismatch.
#   T2  spans that start and end mid-row: a bio goes to the row path only if
#       it is made of whole rows, all or nothing, so these go to the stripe
#       cache whole, and the result is right.
#   T3  the stale-cache case.  4 KiB read-modify-writes leave a stripe's
#       parity cached; a row write then rewrites the members underneath; the
#       next read-modify-write of the same stripe must not use the old parity
#       (scrub).
#   T4  4 KiB writes, row writes and stripe-cache reads racing over the same
#       rows: the parity stays consistent (scrub) and a final pass is right.
#   T5  after row writes, a member fails (degraded reads decode from the parity
#       the row path wrote), row writes decline while degraded, and a rebuild
#       onto a spare leaves a consistent array.
#   T6  a minimal rk_row_write_depth under many writers: most rows find no context
#       and go to the stripe cache (write_nobuf moves); fio's own verify
#       passes.
#   T7  a scrub running while row writes are issued: row writes stand aside
#       for the pass, and the parity is consistent afterwards.
#   T8  m=3 (Vandermonde) and m=4 (Cauchy) generators, and the parity-last
#       layout: data right, scrub clean.
#   T9  control: rk_row_write=0 leaves write_done still, so T1's counter is a
#       real signal.
#   T10 an internal write-intent bitmap: row writes count in it (dirty bits
#       right after them), data right, scrub clean.
#   T11 rows over 1 MiB (10+2), written from huge pages so a bio can hold a
#       whole row: the row path takes them; the same bios through the stripe
#       cache are right too (fio verify, scrub).
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
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	local d
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
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
# A bio goes to the row path only if it is made of whole rows (all or
# nothing: raidkm_row_write_bio), so a span starting 64K into a row -- whose
# 1 MiB bios never line up with rows -- goes to the stripe cache whole, at
# any chunk size.  The data must be right, and the parity.
mk_pattern "$RK_TMP/B" 20
D0=$(row_stat write_done)
put "$RK_TMP/B" $(( ROWB + 64 * 1024 )) 1M	# starts 64K into a row
D1=$(row_stat write_done)
[ "$((D1 - D0))" = 0 ] && rk_pass "T2: no bio with a partial row took the row path" \
	|| rk_fail "T2: row path took $((D1 - D0)) row(s) from bios with partial rows"
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
put "$RK_TMP/A" 0 1M
rk_fail_disks "${MEMBERS[2]}"
same "$RK_TMP/A" 0 && rk_pass "T5: degraded read decodes the row path's parity" \
	|| rk_fail "T5: degraded read WRONG"
D0=$(row_stat write_done)
put "$RK_TMP/B" 0 1M
[ "$(row_stat write_done)" = "$D0" ] && rk_pass "T5: row writes decline while degraded" \
	|| rk_fail "T5: row path ran on a degraded array ($D0 -> $(row_stat write_done))"
same "$RK_TMP/B" 0 && rk_pass "T5: degraded writes right" || rk_fail "T5: degraded write WRONG"
rk_remove_disks "${MEMBERS[2]}"
sudo "$MDADM" --zero-superblock "${MEMBERS[2]}" 2>/dev/null
rk_add_disks "${MEMBERS[10]}"
rk_wait_full 2>/dev/null || rk_wait_idle
grep -A1 "^$MDNAME" /proc/mdstat | grep -q "\[$(printf 'U%.0s' $(seq 1 "$N"))\]" && rk_pass "T5: rebuilt onto the spare" \
	|| rk_fail "T5: array not back to $N/$N: $(grep -A1 "^$MDNAME" /proc/mdstat | tail -1)"
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
else
	rk_fail "T10: create with an internal bitmap"
fi

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

[ "$(splats)" = 0 ] && rk_pass "no WARN/BUG/KASAN/hung task" || rk_fail "$(splats) kernel splat line(s)"
rk_summary
