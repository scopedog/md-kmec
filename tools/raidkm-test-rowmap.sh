#!/bin/bash
# raidkm row state map (RAIDKM_LAYOUT_ROWMAP, mdadm --row-map) functional test.
# Run as root.  Members: 11 loop devices on a private tmpfs, filled with
# random bytes first so a row whose parity was never built really is
# inconsistent.  Reloads raidkm.
#   MDADM=...      a raidkm-aware mdadm with --row-map (required)
#   RM_NO_RCW=1    negative control: load with rowmap_test_no_rcw=Y; T4 must FAIL
#   RM_NO_RECSKIP=1 load with rowmap_test_no_recskip=Y; T10's stripe check must FAIL
#   RM_CSUM=1      every array with --checksum too; T17-T19 run
#   RM_NO_CSUM_DROP=1 (with RM_CSUM=1) load with csum_test_no_discard_drop=Y;
#                  T17 must FAIL
#   RM_DISC_RACE=1 (with RM_CSUM=1) load T18 with csum_test_discard_race=Y
#                  (the old order); T18 must FAIL
#   RM_T18_SECS=N  T18's write + trim race, seconds (default 20)
#   RM_U_FIRST=1   (with RM_CSUM=1) load T19 with csum_test_u_first=Y (rows U
#                  before their CRCs are dropped, the old order); T19 must FAIL
#   (a module from before the 10-31 review fixes fails T9, T11 and T12;
#   one from before the bitmap fix fails T14)
# Ubuntu 26.04's dd is uutils coreutils, whose O_DIRECT I/O of 128 KiB and
# more fails with EINVAL (and may not issue a block as one write); GNU dd is
# installed beside it as gnudd.
if command -v gnudd >/dev/null 2>&1; then dd() { gnudd "$@"; }; fi
set -u
TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
KO=${RAIDKM_KO:-$TREE/km/raidkm.ko}
ISAL_KO=${ISAL_KO:-$TREE/isa-l/isal_lib.ko}
MDADM=${MDADM:-$(command -v mdadm)}
grep -qa -- row-map "$MDADM" 2>/dev/null || { echo "set MDADM to a raidkm-aware mdadm with --row-map"; exit 1; }
# Packaged installs (raidkm-test-ci.sh in CI) have no .ko beside the tree:
# a module path that does not exist loads the packaged module with modprobe,
# and MDADM defaults to the mdadm on PATH.
# scratch space under RK_TMP (raidkm-test-lib.sh's convention): the CI image's
# root filesystem is read-only
RK_DIR=${RK_TMP:-/tmp/raidkm-test}/rowmap; mkdir -p "$RK_DIR" || exit 1
RMMEM=$RK_DIR/mem
rk_modload() {	# rk_modload <ko path> <module> [params...]
	local ko=$1 mod=$2; shift 2
	if [ -f "$ko" ]; then insmod "$ko" "$@"; else modprobe "$mod" "$@"; fi
}
MD=/dev/md70; MDN=md70
NMEM=10; MEMSZ=64		# MiB
# RM_CSUM=1: every array also gets native checksums (--checksum); T17 runs
CSUM_OPT=(); [ "${RM_CSUM:-0}" = 1 ] && CSUM_OPT=(--checksum)
CHUNK=128			# KiB; row = 8 x 128K = 1 MiB of data
ROW=$((1024 * 1024))
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }
rm_get() { awk -v k="$1" '$1 == k {print $2}' /sys/block/$MDN/md/rk_rowmap; }
# mdadm --examine "Tail Regions" against md/rk_rowmap: mdadm (super1.c
# rk_tail_sectors) and the kernel (raidkm_tail_start) work the tail layout
# out apart and must agree.  An mdadm without the line is only noted.
tail_agree() {
	local ex k d out bad=0 none=0
	k="$(rm_get csum_region) $(rm_get map_region) $(rm_get snap_region)"
	for d in "${M[@]}"; do
		if ! out=$($MDADM --examine "$d" 2>&1) || ! grep -q "Raid Level" <<<"$out"; then
			fail "$1 --examine $d failed: $(head -1 <<<"$out")"; bad=1; continue
		fi
		ex=$(awk '/Tail Regions/ {print $5, $7, $9}' <<<"$out")
		if [ -z "$ex" ]; then
			none=1
		elif [ "$ex" != "$k" ]; then
			fail "$1 tail regions on $d: mdadm $ex, kernel $k"; bad=1
		fi
	done
	if [ $none = 1 ]; then
		echo "  note: $1 this mdadm prints no Tail Regions: not compared"
	elif [ $bad = 0 ]; then
		pass "$1 mdadm (every member) and the kernel agree on the tail regions ($k)"
	fi
}
idle() {	# wait for sync to finish; a missing array (failed assemble) fails, not hangs
	local t=0
	while ! grep -q idle /sys/block/$MDN/md/sync_action 2>/dev/null; do
		[ $t -ge 1200 ] && { fail "array $MDN not idle after 600 s ($(ls /sys/block/$MDN/md 2>/dev/null >/dev/null && echo syncing || echo missing))"; break; }
		sleep 0.5; t=$((t + 1))
	done
	sleep 0.5
}

# mem_off <dir>: detach the loop devices on <dir>'s files, then unmount every
# tmpfs stacked there.  A loop device still open when it is detached (udev
# probing the members after the array stops: CI's system mdadm handles
# raidkm) detaches only when closed, and its file keeps the tmpfs busy; an
# umount that fails then leaked the whole tmpfs (the next case mounts on top)
# and ran the 5 GiB CI guest out of memory.
mem_off() {
	local d=$1 f l t=0
	udevadm settle 2>/dev/null
	while mountpoint -q "$d"; do
		for f in "$d"/*; do [ -e "$f" ] || continue
			for l in $(losetup -j "$f" -O NAME -n); do losetup -d "$l" 2>/dev/null; done
		done
		umount "$d" 2>/dev/null && continue
		[ $t -ge 300 ] && { echo "  $d still busy after 30 s: $(losetup -l -O NAME,BACK-FILE -n | grep -F "$d" | head -3 | tr '\n' ' ')"; return 1; }
		sleep 0.1; t=$((t + 1))
	done
}

# mem_on <dir>: a tmpfs still mounted there (mem_off gave up) is never stacked
# on: that is the leak mem_off exists to stop.  The suite stops instead.
mem_on() {
	mkdir -p "$1"
	mountpoint -q "$1" && { fail "$1 still mounted: not stacking another tmpfs on it"; exit 1; }
	mount -t tmpfs -o size=$2 tmpfs "$1" || { fail "mount tmpfs on $1"; exit 1; }
}

# T16's dm devices over the members; dm_off removes them (teardown too).  One
# that will not go stays in DMN for the next try, and is a FAIL: it holds
# its member loop device, and with it the member tmpfs.
DMN=()
dm_off() {
	local d left=()
	udevadm settle 2>/dev/null
	for d in "${DMN[@]}"; do
		dmsetup remove --retry "$d" 2>/dev/null && continue
		dmsetup info "$d" >/dev/null 2>&1 || continue	# already gone
		fail "dmsetup remove $d: $(dmsetup info -c --noheadings -o open "$d" 2>&1) opener(s)"
		left+=("$d")
	done
	DMN=("${left[@]}")
}

teardown() {
	$MDADM --stop $MD >/dev/null 2>&1
	dm_off
	mem_off $RMMEM || fail "teardown: $RMMEM still mounted (its tmpfs would leak)"
}
# any exit (an early exit 1 included) gives back md70, the dm devices, the
# loop devices and the tmpfs: the CI guest has no RAM to leave them in
trap teardown EXIT

load() {
	modprobe -a md_mod raid6_pq async_tx async_xor async_memcpy async_pq async_raid6_recov 2>/dev/null
	lsmod | grep -q '^raidkm' && { rmmod raidkm || exit 1; }
	lsmod | grep -q '^isal_lib' || rk_modload $ISAL_KO isal_lib
	rk_modload $KO raidkm rowmap_test_no_rcw=$([ "${RM_NO_RCW:-0}" = 1 ] && echo Y || echo N) \
		${RM_NO_RECSKIP:+rowmap_test_no_recskip=Y} \
		${RM_NO_CSUM_DROP:+csum_test_no_discard_drop=Y} "$@" || exit 1
}

members() {	# fill members with random bytes so unsynced parity is garbage
	mem_on $RMMEM $(( (NMEM + 2) * MEMSZ + 32 ))m
	M=()
	for i in $(seq 0 $NMEM); do
		head -c ${MEMSZ}M /dev/urandom > $RMMEM/m$i
		M+=("$(losetup -f --show $RMMEM/m$i)")
	done
	SPARE=${M[$NMEM]}; unset "M[$NMEM]"
}

create() {	# create [extra mdadm options]
	$MDADM --create $MD --level=raidkm --parity-count=2 --layout=rotating \
		--raid-devices=$NMEM --chunk=$CHUNK --bitmap=${RM_BITMAP:-none} --row-map \
		${CSUM_OPT[@]} --run --force "$@" "${M[@]}" >$RK_DIR/rm-create.log 2>&1 || { cat $RK_DIR/rm-create.log; exit 1; }
	idle
}

# write <offset-bytes> <len-bytes> <seed> : deterministic data, direct I/O
wr() { openssl enc -aes-128-ctr -pass pass:$3 -nosalt -pbkdf2 </dev/zero 2>/dev/null | head -c $2 | \
	dd of=$MD bs=$2 seek=$1 count=1 oflag=direct,seek_bytes iflag=fullblock status=none; }
expect() { openssl enc -aes-128-ctr -pass pass:$3 -nosalt -pbkdf2 </dev/zero 2>/dev/null | head -c $2 | md5sum | cut -c1-32; }
rd() { dd if=$MD bs=4k skip=$(($1 / 4096)) count=$(($2 / 4096)) iflag=direct status=none | md5sum | cut -c1-32; }

# the written pieces: N rows get 4K at varying chunk offsets, W rows whole
PIECES=()
write_set() {
	local r
	for r in $(seq 0 39); do	# rows 0..39: one 4K piece each -> N
		local off=$(( r * ROW + (r % 8) * CHUNK * 1024 + (r % 5) * 4096 ))
		wr $off 4096 n$r; PIECES+=("$off 4096 n$r")
	done
	for r in $(seq 60 69); do	# rows 60..69: whole rows -> W
		wr $((r * ROW)) $ROW w$r; PIECES+=("$((r * ROW)) $ROW w$r")
	done
}
verify_set() {	# verify_set <label>
	local bad=0 p off len seed
	for p in "${PIECES[@]}"; do
		read off len seed <<<"$p"
		[ "$(rd $off $len)" = "$(expect $off $len $seed)" ] || bad=$((bad + 1))
	done
	[ $bad = 0 ] && pass "$1: ${#PIECES[@]} pieces read back" || fail "$1: $bad of ${#PIECES[@]} pieces wrong"
}

echo "== row map test (negative control: ${RM_NO_RCW:-0})"
mk0="raidkm-test-rowmap start $$.$(date +%s%N)"; echo "$mk0" > /dev/kmsg
teardown; load; members; create
ROWS=$(rm_get rows)
echo "    rows $ROWS, map pages $(rm_get pages)"

# T1 new array: all U, and the initial resync skipped them all
[ "$(rm_get unwritten)" = "$ROWS" ] && pass "T1 new array all unwritten ($ROWS)" || fail "T1 unwritten $(rm_get unwritten) of $ROWS"
[ "$(rm_get skipped_rows)" -ge "$ROWS" ] && pass "T1 initial resync skipped every row" || fail "T1 skipped_rows $(rm_get skipped_rows)"

# T1b an array without --snapshots: every mdadm --snapshot op exits 22 (how
# callers such as snapshot tools check support before they freeze anything)
if grep -qa -- "--checkpoint" "$MDADM"; then
	bad=""
	for op in "--list" "--list --export" "--exists x" "--create x" "--destroy x" "--checkpoint"; do
		$MDADM --snapshot $MD $op >/dev/null 2>&1; rc=$?
		[ $rc = 22 ] || bad="$bad [$op]=$rc"
	done
	[ -z "$bad" ] && pass "T1b --snapshot ops exit 22 without --snapshots" || fail "T1b exit codes:$bad"
fi

# T2 partial writes -> N, whole rows -> W
write_set
[ "$(rm_get needsync)" = 40 ] && pass "T2 40 rows needsync" || fail "T2 needsync $(rm_get needsync)"
[ "$(rm_get written)" = 10 ] && pass "T2 10 rows written" || fail "T2 written $(rm_get written)"
verify_set "T2 healthy"

# T3 persistence
$MDADM --stop $MD >/dev/null; $MDADM --assemble $MD "${M[@]}" >/dev/null 2>&1; idle
[ "$(rm_get needsync)" = 40 ] && [ "$(rm_get written)" = 10 ] && pass "T3 states survive stop/assemble" || \
	fail "T3 after assemble: needsync $(rm_get needsync) written $(rm_get written)"

# T4 degraded read of the pieces: the parity written into unsynced rows
# must decode them (forced reconstruct-write)
for d in 0 1 2 3 4 5 6 7 8 9; do
	$MDADM $MD --fail ${M[$d]} >/dev/null 2>&1; sleep 0.3
	bad=0
	for p in "${PIECES[@]}"; do
		read off len seed <<<"$p"
		[ "$(rd $off $len)" = "$(expect $off $len $seed)" ] || bad=$((bad + 1))
	done
	[ $bad = 0 ] || { echo "    member $d failed: $bad piece(s) wrong"; T4BAD=1; }
	$MDADM $MD --remove ${M[$d]} >/dev/null 2>&1
	$MDADM $MD --re-add ${M[$d]} >/dev/null 2>&1 || $MDADM $MD --add ${M[$d]} >/dev/null 2>&1
	idle
done
[ -z "${T4BAD:-}" ] && pass "T4 every piece decodes with any one member failed" || fail "T4 degraded reads wrong"
[ "${RM_NO_RCW:-0}" = 1 ] && { echo "== negative control done: T4 must have FAILED above"; teardown; echo "RESULT pass=$PASS fail=$FAIL"; exit 0; }

# T5 rebuild onto a new member skips U rows; data intact after; second failure
sk0=$(rm_get skipped_rows)
$MDADM $MD --fail ${M[3]} >/dev/null 2>&1; $MDADM $MD --remove ${M[3]} >/dev/null 2>&1
dd if=/dev/urandom of=$SPARE bs=1M count=$MEMSZ status=none
t0=$(date +%s.%N); $MDADM $MD --add $SPARE >/dev/null 2>&1; sleep 1; idle; t1=$(date +%s.%N)
sk=$(( $(rm_get skipped_rows) - sk0 ))
[ $sk -ge $((ROWS - 50)) ] && pass "T5 rebuild skipped $sk rows ($(echo "$t1 - $t0" | bc) s)" || fail "T5 rebuild skipped only $sk"
verify_set "T5 after rebuild"
$MDADM $MD --fail ${M[5]} >/dev/null 2>&1; sleep 0.3
verify_set "T5 rebuilt member + another failed"
$MDADM $MD --remove ${M[5]} >/dev/null 2>&1; $MDADM $MD --re-add ${M[5]} >/dev/null 2>&1 || $MDADM $MD --add ${M[5]} >/dev/null 2>&1; idle

# T6 discard whole rows -> U
u0=$(rm_get unwritten)
blkdiscard -o $((60 * ROW)) -l $((5 * ROW)) $MD
[ "$(rm_get unwritten)" = $((u0 + 5)) ] && pass "T6 discard of 5 rows -> unwritten" || fail "T6 unwritten $u0 -> $(rm_get unwritten)"
blkdiscard -o $((30 * ROW + 4096)) -l $((2 * ROW)) $MD	# N rows 30-32, partial ends: only row 31 whole
[ "$(rm_get unwritten)" = $((u0 + 6)) ] && pass "T6 partial-row discard turns only the whole row U" || fail "T6b unwritten $(rm_get unwritten)"
NEWP=(); for p in "${PIECES[@]}"; do read off len seed <<<"$p"
	{ [ $off -ge $((60 * ROW)) ] && [ $off -lt $((65 * ROW)) ]; } || { [ $off -ge $((31 * ROW)) ] && [ $off -lt $((32 * ROW)) ]; } || NEWP+=("$p"); done
PIECES=("${NEWP[@]}")

# T7 check: no mismatch (N rows skipped); repair promotes N -> W; check again
echo check > /sys/block/$MDN/md/sync_action; sleep 1; idle
mc=$(cat /sys/block/$MDN/md/mismatch_cnt)
[ "$mc" = 0 ] && pass "T7 check: mismatch_cnt 0" || fail "T7 check mismatch_cnt $mc"
echo repair > /sys/block/$MDN/md/sync_action; sleep 1; idle
[ "$(rm_get needsync)" = 0 ] && [ "$(rm_get syncing)" = 0 ] && pass "T7 repair promoted every N row (promoted $(rm_get promoted))" || \
	fail "T7 after repair needsync $(rm_get needsync) syncing $(rm_get syncing)"
echo check > /sys/block/$MDN/md/sync_action; sleep 1; idle
mc=$(cat /sys/block/$MDN/md/mismatch_cnt)
[ "$mc" = 0 ] && pass "T7 check after repair: mismatch_cnt 0 over all written rows" || fail "T7 check after repair $mc"
verify_set "T7 after repair"

# T8 map written to the rebuilt member: stop, assemble without the old
# members' copies being the only ones (fail 2 originals first)
echo flush > /sys/block/$MDN/md/rk_rowmap
w=$(rm_get written); n=$(rm_get needsync); u=$(rm_get unwritten)
$MDADM --stop $MD >/dev/null
$MDADM --assemble --run $MD "${M[@]:0:3}" "${M[@]:4:4}" $SPARE >/dev/null 2>&1; idle	# 2 originals missing
[ "$(rm_get written)" = $w ] && [ "$(rm_get unwritten)" = $u ] && pass "T8 map loads with 2 members missing (incl. rebuilt one's copy)" || \
	fail "T8 written $(rm_get written)/$w unwritten $(rm_get unwritten)/$u"
verify_set "T8 two members missing"

# T9 (review 3) a UUID change must not make the map look unused: pages of
# another id are untrusted (all N), never "never written" (all U)
$MDADM --stop $MD >/dev/null
$MDADM --assemble --run --update=uuid --uuid=0badc0de:0badc0de:0badc0de:0badc0de \
	$MD "${M[@]:0:3}" "${M[@]:4:4}" $SPARE >/dev/null 2>&1; idle
[ "$(rm_get unwritten)" = 0 ] && pass "T9 after --update=uuid no row is unwritten (needsync $(rm_get needsync))" || \
	fail "T9 after --update=uuid unwritten $(rm_get unwritten) of $ROWS"
verify_set "T9 after --update=uuid"
teardown

# T10 (review 1) a recovery skips U rows, then a write turns one N before
# the rebuilt member's recovery_offset passes it.  The skip must be short
# (under max_sectors/16, or md checkpoints recovery_offset past it at
# once) and followed by a slow crawl: W rows 0-1, U rows 2-21, W 22-59.
# Afterwards each written stripe must read the same with the rebuilt
# member in and failed (its chunks match the parity the write built).
members; create
for r in 0 1 $(seq 22 59); do wr $((r * ROW)) $ROW x$r; done
$MDADM $MD --fail ${M[3]} >/dev/null 2>&1; $MDADM $MD --remove ${M[3]} >/dev/null 2>&1
dd if=/dev/urandom of=$SPARE bs=1M count=$MEMSZ status=none
echo 10 > /sys/block/$MDN/md/sync_speed_min; echo 50 > /sys/block/$MDN/md/sync_speed_max
sk0=$(rm_get skipped_rows)
$MDADM $MD --add $SPARE >/dev/null 2>&1
SD=$(basename $SPARE)
t=0; while [ $(( $(rm_get skipped_rows) - sk0 )) -lt 20 ] && [ $t -lt 300 ]; do sleep 0.1; t=$((t + 1)); done
for r in $(seq 2 21); do wr $(( r * ROW + (r % 8) * CHUNK * 1024 + (r % 3) * 4096 )) 4096 r$r; done
rs=$(cat /sys/block/$MDN/md/dev-$SD/recovery_start)
if grep -q recover /sys/block/$MDN/md/sync_action && [ "$rs" != none ] && [ "$rs" -lt $((22 * CHUNK * 2)) ]; then
	pass "T10 20 writes into skipped rows below the rebuilt member's recovery_start ($rs)"
else
	fail "T10 timing: writes not inside the window (action $(cat /sys/block/$MDN/md/sync_action), recovery_start $rs)"
fi
echo system > /sys/block/$MDN/md/sync_speed_max; echo system > /sys/block/$MDN/md/sync_speed_min
idle
stripes() { local r c; for r in $(seq 2 21); do for c in 0 1 2 3 4 5 6 7; do
	dd if=$MD bs=4096 skip=$(( (r * ROW + c * CHUNK * 1024 + (r % 3) * 4096) / 4096 )) count=1 iflag=direct status=none
	done | md5sum | cut -c1-8; done; }
s_in=$(stripes); $MDADM $MD --fail $SPARE >/dev/null 2>&1; sleep 0.3; s_out=$(stripes)
nd=$(diff <(echo "$s_in") <(echo "$s_out") | grep -c "^<")
[ "$nd" = 0 ] && pass "T10 the 20 written stripes read the same with the rebuilt member failed" || \
	fail "T10 $nd of 20 written stripes differ with the rebuilt member failed (its chunks do not match the parity)"
teardown

# T11 (review 2) a resync limited by the write-intent bitmap (unclean
# shutdown: --update=resync) skips each bitmap-clean chunk, so it does not
# sync an N row's unwritten stripes there and must not make the row W.
# Chunks get clean only through a pass over a row that is not U (a chunk
# of nothing but U rows stays dirty), so: row 8c of each 8-row chunk N,
# repair (-> W, chunk clean), then row 8c+1 N in the same chunk.
members; RM_BITMAP=internal create --bitmap-chunk=1M	# bitmap chunk = 8 rows
for c in $(seq 0 19); do wr $(( c * 8 * ROW )) 4096 a$c; done
echo repair > /sys/block/$MDN/md/sync_action; sleep 1; idle; sleep 15
for c in $(seq 0 19); do wr $(( (c * 8 + 1) * ROW + 3 * CHUNK * 1024 )) 4096 b$c; done
sleep 15	# the bitmap daemon clears the bits of the finished writes
p0=$(rm_get promoted)
$MDADM --stop $MD >/dev/null
$MDADM --assemble --update=resync $MD "${M[@]}" >/dev/null 2>&1; sleep 1; idle
[ "$(rm_get needsync)" = 20 ] && [ "$(rm_get promoted)" = 0 ] && pass "T11 bitmap-limited resync left the 20 new N rows N" || \
	fail "T11 bitmap-limited resync: needsync $(rm_get needsync) promoted $(rm_get promoted) (before $p0)"
echo check > /sys/block/$MDN/md/sync_action; sleep 1; idle
mc=$(cat /sys/block/$MDN/md/mismatch_cnt)
[ "$mc" = 0 ] && pass "T11 check after it: mismatch_cnt 0" || fail "T11 check after it: mismatch_cnt $mc (rows called W over unsynced parity)"

# T12 (review 4) the members get discards only with devices_handle_discard_safely
dhs=$(cat /sys/module/raidkm/parameters/devices_handle_discard_safely)
md_=$(rm_get member_discard)
{ [ "$dhs" = N ] && [ "$md_" = 0 ]; } || { [ "$dhs" = Y ] && [ "$md_" = 1 ]; } && \
	pass "T12 member_discard $md_ with devices_handle_discard_safely=$dhs" || \
	fail "T12 member_discard $md_ with devices_handle_discard_safely=$dhs"
teardown

# T13 (review 5, 6) mdadm refuses --row-map with metadata 1.0 and with --assume-clean
members
for f in "-e 1.0" "--assume-clean"; do
	if $MDADM --create $MD --level=raidkm --parity-count=2 --raid-devices=$NMEM --chunk=$CHUNK \
		--bitmap=none --row-map --run --force $f "${M[@]}" >$RK_DIR/rm-create.log 2>&1; then
		fail "T13 --row-map $f was accepted"; $MDADM --stop $MD >/dev/null 2>&1
	else
		grep -q -- "--row-map" $RK_DIR/rm-create.log && pass "T13 --row-map $f refused: $(grep -- --row-map $RK_DIR/rm-create.log | head -1 | cut -c1-70)" || \
			fail "T13 --row-map $f failed for another reason: $(tail -1 $RK_DIR/rm-create.log)"
	fi
done

teardown

# T14 the write-intent bitmap comes clean: a bitmap chunk of U rows only
# learns it is in sync only if the skip tells it (start_sync/close_sync),
# else a new array stays all dirty, and so does every chunk never written
members; RM_BITMAP=internal create --bitmap-chunk=1M	# bitmap chunk = 8 rows
dirty() { $MDADM -X "${M[0]}" 2>/dev/null | grep -o "[0-9]* dirty" | cut -d' ' -f1; }
bits() { $MDADM -X "${M[0]}" 2>/dev/null | grep -o "[0-9]* bits" | head -1 | cut -d' ' -f1; }
# poll, not a fixed sleep: a new array comes clean 16 s after create (three
# 5 s daemon rounds); a module without the skip fix never reaches 0
clean_wait() { local t=0 d; while d=$(dirty); [ "$d" != 0 ] && [ $t -lt 60 ]; do sleep 1; t=$((t + 1)); done; echo "$d"; }
d0=$(clean_wait)
[ "$d0" = 0 ] && pass "T14 new array: bitmap clean after the initial pass (0 of $(bits) dirty)" || \
	fail "T14 new array: $d0 of $(bits) bitmap chunks still dirty"
for r in 3 17 40; do wr $(( r * ROW + 4096 )) 4096 t$r; done
d1=$(clean_wait)	# as without the map: written chunks come clean in 15-20 s
[ "$d1" = 0 ] && pass "T14 after partial writes: bitmap clean again" || fail "T14 after writes: $d1 dirty"
$MDADM --stop $MD >/dev/null
$MDADM --assemble --update=resync $MD "${M[@]}" >/dev/null 2>&1; sleep 1; idle
d2=$(clean_wait)
[ "$d2" = 0 ] && pass "T14 after a full resync: bitmap clean ($(rm_get needsync) N rows)" || fail "T14 after a resync: $d2 dirty"
for p in "3 t3" "17 t17" "40 t40"; do read r s <<<"$p"
	[ "$(rd $(( r * ROW + 4096 )) 4096)" = "$(expect 0 4096 $s)" ] || fail "T14 row $r data"; done

# T15 a dirty degraded start is refused, not "run" with no conf: the row
# map's init used to leave 0 in raid5_run()'s ret, so the refusal returned
# success and md_run() dereferenced NULL in pers->size() (a panic)
$MDADM --stop $MD >/dev/null
$MDADM --assemble --run --update=resync $MD "${M[@]:1}" >/dev/null 2>&1	# member 0 missing, dirty
if grep -q "^$MDN : active" /proc/mdstat; then
	fail "T15 a dirty degraded array started"
else
	pass "T15 dirty degraded start refused"
fi
dmesg | grep -q "cannot start dirty degraded" && pass "T15 md said why" || fail "T15 no refusal message"
$MDADM --stop $MD >/dev/null 2>&1
$MDADM --assemble $MD "${M[@]}" >/dev/null 2>&1; idle
grep -q "^$MDN : active" /proc/mdstat && pass "T15 the whole array still assembles" || fail "T15 no assemble"

# T16 (PR #19 review) a map page unreadable on every in-sync member loads
# as all N, never as the zeroed all U: before the fix the read error set
# neither "have" nor "bad" and resync/rebuild/check skipped rows with data.
# Each member under dm: linear, except the map region, which is flakey in
# its down state with error_reads + drop_writes (reads fail, writes vanish;
# drop_writes alone lets reads through).
$MDADM --stop $MD >/dev/null 2>&1
teardown; members; create; PIECES=(); write_set
echo flush > /sys/block/$MDN/md/rk_rowmap
w16=$(rm_get written); n16=$(rm_get needsync); p16=$(rm_get pages)
# the map's place on each member: data offset + the kernel's map_region
# (after the data, and after the CRC region with --checksum)
mreg=$(rm_get map_region)
tail_agree T16
$MDADM --stop $MD >/dev/null
doff=$($MDADM --examine "${M[0]}" | awk '/Data Offset/ {print $4}')
if [ -z "$doff" ] || [ "${mreg:-0}" -le 0 ]; then
	fail "T16 no data offset ($doff) or map_region ($mreg)"
	$MDADM --examine "${M[0]}" | sed 's/^/    /'
else
	a=$((doff + mreg)); len=$((p16 * 8)); D=()
	for i in "${!M[@]}"; do
		tot=$(blockdev --getsz "${M[$i]}"); n=rm16_$i
		printf '%s\n' "0 $a linear ${M[$i]} 0" \
			"$a $len flakey ${M[$i]} $a 0 1 2 error_reads drop_writes" \
			"$((a + len)) $((tot - a - len)) linear ${M[$i]} $((a + len))" |
			dmsetup create $n || { fail "T16 dmsetup create $n"; break; }
		DMN+=($n); D+=(/dev/mapper/$n)
	done
	# udev's incremental assembly may grab the new devices: stop what it built
	udevadm settle
	for d in "${D[@]}"; do
		for h in /sys/class/block/$(basename "$(readlink -f "$d")")/holders/md*; do
			[ -e "$h" ] && $MDADM --stop /dev/$(basename "$h") >/dev/null 2>&1
		done
	done
	mk16="raidkm-test-rowmap T16 assemble $$.$(date +%s%N)"	# unique: the ring keeps earlier runs
	echo "$mk16" > /dev/kmsg
	[ ${#D[@]} = ${#M[@]} ] && out16=$($MDADM --assemble --run $MD "${D[@]}" 2>&1)
	sleep 1
	k16() { dmesg | sed -n "/$mk16/,\$p"; }
	if [ ${#D[@]} != ${#M[@]} ]; then
		:	# a dmsetup create failed (counted above): no degraded half-set
	elif ! grep -q "^$MDN : active" /proc/mdstat; then
		fail "T16 no assemble over the unreadable map region: $out16"
		k16 | tail -8 | sed 's/^/    /'
	else
		u=$(rm_get unwritten)
		[ "$u" = 0 ] && pass "T16 unreadable map: no row loads unwritten (needsync $(rm_get needsync), was $n16; written $w16 before)" || \
			fail "T16 unreadable map: $u of $ROWS rows load unwritten (all-U, skipped by resync)"
		k16 | grep -q "row map: .* $p16 damaged" && pass "T16 md reports $p16 damaged page(s)" || \
			fail "T16 no damaged pages reported: $(k16 | grep 'row map:' | tail -1)"
		idle; verify_set "T16 after resync with the map unreadable"
	fi
	$MDADM --stop $MD >/dev/null 2>&1
	dm_off
fi

if [ "${RM_CSUM:-0}" = 1 ]; then
# T1-T16 corrupt no data: with --checksum any mismatch so far is a stale or
# missing CRC (or a CRC region overlapping the row map)
n=$(dmesg | sed -n "/$mk0/,\$p" | grep -c "native csum mismatch")
[ "$n" = 0 ] && pass "T1-T16 with --checksum: no csum mismatch" || fail "T1-T16 with --checksum: $n csum mismatch(es)"
# members start as random bytes: mdadm zeroes the CRC region at create, so
# no page of it loads as damaged
n=$(dmesg | sed -n "/$mk0/,\$p" | grep -c "native csum region page rotted")
[ "$n" = 0 ] && pass "T1-T16 with --checksum: the CRC region starts zeroed (no rotted page)" || fail "T1-T16 with --checksum: $n rotted region page(s)"
# T17 native checksums and member discards.  Members that take a discard
# read the trimmed blocks back as zeroes, so the CRCs of those blocks must
# be off the region -- on disk, before the discard goes out: the region is
# written back lazily, and a resync skips U rows, so nothing would
# re-derive them after a crash.  Stale ones false-mismatch on every later
# read of the rows and on the reconstruct-write a partial write into them
# does.  The neighbouring rows keep theirs, and a block written after that
# has its CRC (rot is caught).
teardown; load devices_handle_discard_safely=Y; members; create
creg=$(rm_get csum_region)	# the CRC region: data offset + this, on every member
doff=$($MDADM --examine "${M[0]}" | awk '/Data Offset/ {print $4}')
if [ "$(rm_get member_discard)" != 1 ]; then
	fail "T17 member_discard $(rm_get member_discard) with devices_handle_discard_safely=Y"
elif [ -z "$doff" ] || [ "${creg:--1}" -le 0 ]; then
	fail "T17 no data offset ($doff) or csum_region ($creg): T17 skipped"
else
R=100; NR=64; C2=$((CHUNK * 2)); NB=$((C2 / 8))	# rows R..R+63; a chunk in sectors, 4K blocks
b0=$((R * NB)); nb=$((NR * NB))			# their blocks on every member: 3 region pages
mk17="raidkm-test-rowmap T17 $$.$(date +%s%N)"; echo "$mk17" > /dev/kmsg
mm17() { dmesg | sed -n "/$mk17/,\$p" | grep -c "native csum mismatch"; }
nz() {	# nz <member> <blk> <n>: slots of blocks blk..blk+n-1 holding a CRC, on disk
	local d=$1 b=$2 n=$3 p base=$(( (doff + creg) / 8 ))
	for p in $(seq $((b / 1022)) $(((b + n - 1) / 1022))); do
		dd if=$d bs=4096 skip=$((base + p)) count=1 iflag=direct status=none | od -An -v -tu4 -w4 |
			awk -v lo=$((b - p * 1022)) -v hi=$((b + n - 1 - p * 1022)) \
				'NR - 1 >= lo && NR - 1 <= hi && NR <= 1022 && $1 != 0 {c++} END {print c + 0}'
	done | awk '{s += $1} END {print s + 0}'
}
z=0; for d in "${M[@]}"; do z=$((z + $(nz $d $b0 $nb))); done
[ $z = 0 ] && pass "T17 a new array's CRC region is zeroed over random members" || fail "T17 $z non-zero slots in a new array's CRC region"
wr $(((R - 1) * ROW)) $(((NR + 2) * ROW)) s17		# whole rows, a neighbour each side
$MDADM --stop $MD >/dev/null				# the CRCs go to the region
$MDADM --assemble $MD "${M[@]}" >/dev/null 2>&1; idle
[ "$(nz ${M[0]} $b0 $nb)" = $nb ] && pass "T17 the rows' CRCs are on disk" || fail "T17 $(nz ${M[0]} $b0 $nb) of $nb CRCs on disk before the discard"
u0=$(rm_get unwritten)
blkdiscard -o $((R * ROW)) -l $((NR * ROW)) $MD
[ "$(rm_get unwritten)" = $((u0 + NR)) ] && pass "T17 $NR discarded rows are U" || fail "T17 unwritten $u0 -> $(rm_get unwritten)"
z=0; k=0
for d in "${M[@]}"; do					# the array still runs: nothing flushed since
	z=$((z + $(nz $d $b0 $nb)))
	k=$((k + $(nz $d $((b0 - NB)) $NB) + $(nz $d $((b0 + nb)) $NB)))
done
[ $z = 0 ] && pass "T17 the trimmed rows' CRCs are off every member's disk" || fail "T17 $z CRCs of trimmed blocks still on disk"
[ $k = $((2 * NB * NMEM)) ] && pass "T17 the neighbouring rows keep theirs" || fail "T17 neighbours: $k of $((2 * NB * NMEM)) CRCs"
dd if=$MD of=/dev/null bs=1M skip=$R count=$NR iflag=direct status=none && \
	[ "$(mm17)" = 0 ] && pass "T17 reads of the trimmed rows check no stale CRC" || fail "T17 trimmed rows: $(mm17) mismatch(es)"
P=$((R * ROW + 2 * CHUNK * 1024 + 8192))		# 4K in row R's 3rd data chunk
wr $P 4096 p17						# U -> N: reconstruct-write reads the rest
dd if=$MD of=/dev/null bs=1M skip=$R count=1 iflag=direct status=none
[ "$(rd $P 4096)" = "$(expect 0 4096 p17)" ] && pass "T17 the 4K written into a U row reads back" || fail "T17 4K piece wrong"
[ "$(mm17)" = 0 ] && pass "T17 no stale CRC checked after the row left U" || fail "T17 $(mm17) mismatch(es) after the row left U"
[ "$(rm_get needsync)" -ge 1 ] || fail "T17 row $R not N"
# the new block's own CRC is there: rot on its member is caught and healed
$MDADM --stop $MD >/dev/null
want=$(expect 0 4096 p17); hit=""
for d in "${M[@]}"; do
	for o in $(seq 0 $((C2 / 8 - 1))); do	# the member and the 4K slot within its chunk
		[ "$(dd if=$d bs=4096 skip=$(( (doff + R * C2) / 8 + o )) count=1 iflag=direct status=none | md5sum | cut -c1-32)" = "$want" ] && { hit="$d $o"; break 2; }
	done
done
if [ -z "$hit" ]; then
	fail "T17 the written 4K is on no member"
else
	read d o <<<"$hit"
	dd if=/dev/urandom of=$d bs=4096 seek=$(( (doff + R * C2) / 8 + o )) count=1 oflag=direct conv=notrunc status=none
	$MDADM --assemble $MD "${M[@]}" >/dev/null 2>&1; idle
	m0=$(mm17)
	[ "$(rd $P 4096)" = "$want" ] && pass "T17 rot in the new block: original bytes back" || fail "T17 rot in the new block not healed"
	[ "$(mm17)" -gt "$m0" ] && pass "T17 its CRC caught the rot" || fail "T17 no mismatch on a rotted block with a CRC"
fi
fi

# T18 a write racing a member discard of the same rows.  The discard drops
# the rows' CRCs and then attaches to their stripes; a write issued in
# between used to store a CRC the trim then made stale: a block that fails
# its CRC on every read, bad blocks, and with m of them in one stripe data
# nobody can repair (found 11-04 on GCP NVMe).  4K random writes, whole-row
# random writes (the row layer stores their CRCs from submit_bio, where the
# store must not wait on region I/O) and one-row random trims over the whole
# array at once, then every block is read: no mismatch during the race or
# after, no bad block.  Plus 4K writes and trims on the first 16 rows only,
# so a row is trimmed again while a write that joined its last discard is
# still going (11-05: the discard stripe went out of the hash with that
# write on it; the next discard of the row did not see it, and the write's
# CRCs landed over blocks the new trim zeroed -- 3 mismatches a run at
# 120 s without these jobs).
teardown
load devices_handle_discard_safely=Y \
	$([ "${RM_DISC_RACE:-0}" = 1 ] && echo csum_test_discard_race=Y)
members; create
if [ "$(rm_get member_discard)" != 1 ]; then
	fail "T18 member_discard $(rm_get member_discard) with devices_handle_discard_safely=Y"
elif ! command -v fio >/dev/null; then
	fail "T18 needs fio"
else
	mk18="raidkm-test-rowmap T18 $$.$(date +%s%N)"; echo "$mk18" > /dev/kmsg
	mm18() { dmesg | sed -n "/$mk18/,\$p" | grep -c "native csum mismatch"; }
	bb18() { cat /sys/block/$MDN/md/dev-*/bad_blocks 2>/dev/null | grep -c .; }
	fio --name=fill --filename=$MD --rw=write --bs=1M --iodepth=8 --ioengine=libaio \
		--direct=1 --size=100% --output-format=terse >/dev/null 2>&1
	dio() { awk '{print $12}' /sys/block/$MDN/stat; }	# discard I/Os the array took
	t0=$(dio)
	fio --filename=$MD --ioengine=libaio --direct=1 --time_based --runtime=${RM_T18_SECS:-20} \
		--name=wr --rw=randwrite --bs=4k --iodepth=16 --numjobs=4 \
		--name=wrow --rw=randwrite --bs=$ROW --blockalign=$ROW --iodepth=4 \
		--name=t --rw=randtrim --bs=$ROW --blockalign=$ROW --iodepth=1 \
		--name=hw --rw=randwrite --bs=4k --iodepth=16 --size=$((16 * ROW)) \
		--name=ht --rw=randtrim --bs=$ROW --blockalign=$ROW --iodepth=1 --size=$((16 * ROW)) \
		--output-format=terse >$RK_DIR/t18.fio 2>&1
	nt=$(dio)
	m1=$(mm18)
	dd if=$MD of=/dev/null bs=1M iflag=direct status=none
	m2=$(mm18); b=$(bb18)
	[ -n "$t0" ] && [ -n "$nt" ] && [ "$nt" -gt "$t0" ] && \
		pass "T18 $((nt - t0)) trims raced the writes" || fail "T18 no trim reached the array ($t0 -> $nt)"
	[ "$m1" = 0 ] && pass "T18 no csum mismatch during the race" || fail "T18 $m1 csum mismatch(es) during the race"
	[ "$m2" = "$m1" ] && pass "T18 reading every block after it checks no stale CRC" || \
		fail "T18 read-back: $((m2 - m1)) csum mismatch(es)"
	[ "$b" = 0 ] && pass "T18 no bad block" || fail "T18 $b bad-block range(s)"
	fi

# T19 a crash while a discard is on its way (11-05, power-cut rm-d).  A
# resync skips U rows, and the CRC region goes to disk lazily: a row whose
# U reached the disk before its CRCs were dropped kept the CRC of an older
# write over newer data.  A row written and stopped (its CRCs on disk), 4K
# rewritten (that CRC in the cache only), then discarded with the drop held
# back (csum_test_drop_delay_ms) past the map's lazy write-back: copies of
# the members taken then are the crash.  Assembled, resynced and checked:
# no csum mismatch.  RM_U_FIRST=1 marks the rows U first (the old order):
# T19 must FAIL.
teardown
load devices_handle_discard_safely=Y csum_test_drop_delay_ms=8000 \
	$([ "${RM_U_FIRST:-0}" = 1 ] && echo csum_test_u_first=Y)
members; create
mount -o remount,size=$(( (2 * NMEM + 2) * MEMSZ + 64 ))m $RMMEM		# room for the copies
R=200; P=$((R * ROW + 8192))
wr $((R * ROW)) $ROW a19				# U -> W, whole row
$MDADM --stop $MD >/dev/null				# its CRCs go to the region
$MDADM --assemble $MD "${M[@]}" >/dev/null 2>&1; idle
wr $P 4096 b19						# this CRC in the cache only
mk19="raidkm-test-rowmap T19 $$.$(date +%s%N)"; echo "$mk19" > /dev/kmsg
mm19() { dmesg | sed -n "/$mk19/,\$p" | grep -c "native csum mismatch"; }
blkdiscard -o $((R * ROW)) -l $ROW $MD & dpid=$!
sleep 6.5						# the map's lazy write-back: 5 s
st=$(cat /sys/block/$MDN/md/array_state)
C=(); for i in "${!M[@]}"; do cp --sparse=always $RMMEM/m$i $RMMEM/c$i; done
wait $dpid
$MDADM --stop $MD >/dev/null
echo 0 > /sys/module/raidkm/parameters/csum_test_drop_delay_ms
for i in "${!M[@]}"; do C+=("$(losetup -f --show $RMMEM/c$i)"); done
$MDADM --assemble $MD "${C[@]}" >/dev/null 2>&1; idle
if [ ! -e /sys/block/$MDN/md/array_state ]; then
	fail "T19 the crash copies do not assemble"
else
	echo check > /sys/block/$MDN/md/sync_action; sleep 1; idle
	z4=$(dd if=/dev/zero bs=4096 count=1 status=none | md5sum | cut -c1-32)
	r=$(rd $P 4096)
	[ "$r" = "$(expect 0 4096 b19)" ] || [ "$r" = "$z4" ] || fail "T19 the rewritten 4K reads neither its data nor zeroes"
	[ "$st" != clean ] || fail "T19 the array was clean at the copy (nothing to resync)"
	[ "$(mm19)" = 0 ] && pass "T19 a crash before the drop leaves no stale CRC (map $(rm_get unwritten) U, array $st at the cut)" || \
		fail "T19 $(mm19) csum mismatch(es) after a crash before the drop"
	$MDADM --stop $MD >/dev/null
fi
for d in "${C[@]}"; do losetup -d $d; done; rm -f $RMMEM/c*
fi

dmesg | grep -E "BUG|WARNING|Oops|KASAN" | tail -5
teardown
echo "RESULT pass=$PASS fail=$FAIL"
echo "==== rowmap: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
