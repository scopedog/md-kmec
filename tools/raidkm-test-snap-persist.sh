#!/bin/bash
# raidkm native snapshots: they survive stop/assemble, a stop without a
# checkpoint (the journal replays), journal wraps with checkpoints, a
# degraded assemble, a rebuild followed by losing other members, and a
# damaged header copy.  Everything through `mdadm --snapshot`.
#
#   sudo RAIDKM_KO=.../raidkm.ko ISAL_KO=.../isal_lib.ko MDADM=.../mdadm \
#        bash tools/raidkm-test-snap-persist.sh
#
# Members are tmpfs-backed loop devices (8+2, 128 KiB chunks: rows of
# 1 MiB of data), snapshots on 20% of the rows.
#
# SNAP_DCL=<N>:<g>:<s> runs it on a declustered array instead: a pool of N
# members, groups of g = k + 2, s spare columns (14:6:2 = two 4+2 groups,
# rows of 1 MiB again; 20:6:2 = three, rows of 1.5 MiB), and adds T13: a
# member populated into the spare columns, then copied back to a new disk.
# Ubuntu 26.04's dd is uutils coreutils, whose O_DIRECT I/O of 128 KiB and
# more fails with EINVAL (and may not issue a block as one write); GNU dd is
# installed beside it as gnudd.
if command -v gnudd >/dev/null 2>&1; then dd() { gnudd "$@"; }; fi
set -u
TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
KO=${RAIDKM_KO:-$TREE/km/raidkm.ko}
ISAL_KO=${ISAL_KO:-$TREE/isa-l/isal_lib.ko}
MDADM=${MDADM:-$(command -v mdadm)}
grep -qa -- --snapshots "$MDADM" 2>/dev/null || { echo "set MDADM to an mdadm with --snapshots"; exit 1; }
# Packaged installs (raidkm-test-ci.sh in CI) have no .ko beside the tree:
# a module path that does not exist loads the packaged module with modprobe,
# and MDADM defaults to the mdadm on PATH.
# scratch space under RK_TMP (raidkm-test-lib.sh's convention): the CI image's
# root filesystem is read-only
RK_DIR=${RK_TMP:-/tmp/raidkm-test}/snap-persist; mkdir -p "$RK_DIR" || exit 1
SNMEM=$RK_DIR/mem
rk_modload() {	# rk_modload <ko path> <module> [params...]
	local ko=$1 mod=$2; shift 2
	if [ -f "$ko" ]; then insmod "$ko" "$@"; else modprobe "$mod" "$@"; fi
}
MD=/dev/md70; MDN=md70
NMEM=10; MEMSZ=64		# MiB
# SNAP_CSUM=1: the arrays also get native checksums (--checksum)
CSUM_OPT=(); [ "${SNAP_CSUM:-0}" = 1 ] && CSUM_OPT=(--checksum)
ROW=$((1024 * 1024))
CHUNK=$((128 * 1024))
LAYOUT=(--layout=rotating); DCL_SECT=0; DCL_NAME=
if [ -n "${SNAP_DCL:-}" ]; then
	IFS=: read -r NMEM DCL_G DCL_S <<<"$SNAP_DCL"
	[[ "$NMEM" =~ ^[0-9]+$ && "$DCL_G" =~ ^[0-9]+$ && "$DCL_S" =~ ^[0-9]+$ ]] && \
		[ "$DCL_G" -gt 2 ] && [ "$NMEM" -gt "$DCL_S" ] || \
		{ echo "SNAP_DCL=$SNAP_DCL: want <N>:<g>:<s>, g > 2 (m = 2), N > s"; exit 1; }
	DCL_NG=$(( (NMEM - DCL_S) / DCL_G ))
	[ $DCL_NG -ge 1 ] && [ $(( DCL_NG * DCL_G + DCL_S )) = "$NMEM" ] || { echo "SNAP_DCL=$SNAP_DCL: N - s is not a multiple of g"; exit 1; }
	ROW=$(( CHUNK * DCL_NG * (DCL_G - 2) ))
	LAYOUT=(--layout=declustered --group-width=$DCL_G --spare-columns=$DCL_S)
	DCL_SECT=$(( CHUNK / 512 ))	# the rkdcl chunk before the row map
	DCL_NAME=" (declustered $SNAP_DCL, $DCL_NG group(s), rows of $(( ROW / 1024 )) KiB)"
fi
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }
sn_get() { awk -v k="$1" '$1 == k {print $2}' /sys/block/$MDN/md/rk_snap; }
rm_get() { awk -v k="$1" '$1 == k {print $2}' /sys/block/$MDN/md/rk_rowmap; }
snap() { $MDADM --snapshot $MD "$@"; }
idle() {
	local t=0
	while ! grep -q idle /sys/block/$MDN/md/sync_action 2>/dev/null; do
		[ $t -ge 1200 ] && { fail "array $MDN not idle after 600 s"; break; }
		sleep 0.5; t=$((t + 1))
	done
	sleep 0.5
}
# the snapshot disk of <name>, once udev made it
sdev() {
	local d t=0
	while :; do
		d=$(snap --list "$1" 2>/dev/null | grep -o 'dev=[^ ]*' | cut -d= -f2)
		[ -n "$d" ] && [ "$d" != - ] && [ -b "$d" ] && { echo "$d"; return; }
		[ $t -ge 50 ] && return 1
		sleep 0.2; t=$((t + 1))
	done
}
md5() { [ -b "$1" ] || { echo "nodev:$1"; return; }; dd if="$1" bs=1M iflag=direct status=none | md5sum | cut -c1-32; }
# same <label> <expected> <device>: md5 of device is expected (prints both if not)
same() { local got; got=$(md5 "$3"); [ "$got" = "$2" ] && return 0
	echo "    $1: $3 md5 $got, expected $2"; return 1; }
# the three things every check looks at
content() {	# content <label> <origin md5>
	local ok=0
	same "$1 s1" "$h0" "$(sdev s1)" || ok=1
	same "$1 s3" "$h4" "$(sdev s3)" || ok=1
	same "$1 origin" "$2" $MD || ok=1
	return $ok
}
# write <offset-bytes> <len-bytes> <seed>
wr() { openssl enc -aes-128-ctr -pass pass:$3 -nosalt -pbkdf2 </dev/zero 2>/dev/null | head -c $2 | \
	dd of=$MD bs=$2 seek=$1 count=1 oflag=direct,seek_bytes iflag=fullblock status=none; }

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

teardown() {
	$MDADM --stop $MD >/dev/null 2>&1
	mem_off $SNMEM || fail "teardown: $SNMEM still mounted (its tmpfs would leak)"
}

load() {
	modprobe -a md_mod raid6_pq async_tx async_xor async_memcpy async_pq async_raid6_recov 2>/dev/null
	lsmod | grep -q '^raidkm' && { rmmod raidkm || exit 1; }
	lsmod | grep -q '^isal_lib' || rk_modload $ISAL_KO isal_lib
	rk_modload $KO raidkm || exit 1
}

members() {
	mem_on $SNMEM $(( (NMEM + 2) * MEMSZ + 32 ))m
	M=()
	for i in $(seq 0 $NMEM); do
		head -c ${MEMSZ}M /dev/urandom > $SNMEM/m$i
		M+=("$(losetup -f --show $SNMEM/m$i)")
	done
	SPARE=${M[$NMEM]}; unset "M[$NMEM]"
}

assemble() {	# assemble [members...]: default all
	local mem=("$@")
	[ ${#mem[@]} -gt 0 ] || mem=("${M[@]}")
	$MDADM --assemble --run $MD "${mem[@]}" >$RK_DIR/sn-asm.log 2>&1 || { cat $RK_DIR/sn-asm.log; return 1; }
	idle
}

restart() {	# stop, assemble [members]
	$MDADM --stop $MD >/dev/null || { fail "stop"; return 1; }
	assemble "$@"
}

echo "== snapshot persistence test$DCL_NAME"
trap teardown EXIT
teardown
load
dmesg -C
members

# T0 (declustered) the row map alone: bios are cut at its row (every
# group of a device row), so a whole-row write makes the row W
if [ -n "${SNAP_DCL:-}" ]; then
	$MDADM --create $MD --level=raidkm --parity-count=2 "${LAYOUT[@]}" \
		--raid-devices=$NMEM --chunk=$(( CHUNK / 1024 )) --bitmap=none --row-map \
		"${CSUM_OPT[@]}" --run --force "${M[@]}" >$RK_DIR/sn-create0.log 2>&1 || { cat $RK_DIR/sn-create0.log; exit 1; }
	idle
	[ "$(cat /sys/block/$MDN/queue/optimal_io_size)" = $ROW ] && \
		[ "$(cat /sys/block/$MDN/queue/chunk_sectors)" = $(( ROW / 512 )) -o $ROW -gt $((1024 * 1024)) ] && \
		pass "T0 row map alone: io_opt = the row ($ROW)" || \
		fail "T0 io_opt $(cat /sys/block/$MDN/queue/optimal_io_size) chunk_sectors $(cat /sys/block/$MDN/queue/chunk_sectors), row $ROW"
	for r in $(seq 0 9); do wr $(( r * ROW )) $ROW r0-$r; done
	if [ $ROW -le $((1024 * 1024)) ]; then
		[ "$(rm_get written)" -ge 10 ] && [ "$(rm_get needsync)" = 0 ] && \
			pass "T0 10 whole-row writes: $(rm_get written) row(s) W" || \
			fail "T0 written $(rm_get written) needsync $(rm_get needsync)"
	fi
	$MDADM --stop $MD >/dev/null
fi

$MDADM --create $MD --level=raidkm --parity-count=2 "${LAYOUT[@]}" \
	--raid-devices=$NMEM --chunk=$(( CHUNK / 1024 )) --bitmap=none --snapshots=20 \
	"${CSUM_OPT[@]}" --run --force "${M[@]}" >$RK_DIR/sn-create.log 2>&1 || { cat $RK_DIR/sn-create.log; exit 1; }
idle

# T1 the array exports the origin only
O=$(sn_get origin_rows); RES=$(sn_get reserve_rows)
[ -n "$O" ] && [ "$O" -gt 0 ] && [ "$RES" -gt 0 ] && \
	[ $(( O * 100 / (O + RES) )) -ge 79 ] && [ $(( O * 100 / (O + RES) )) -le 80 ] && \
	pass "T1 origin $O rows, reserve $RES (20%)" || fail "T1 origin $O reserve $RES"
[ "$(blockdev --getsize64 $MD)" = $(( O * ROW )) ] && pass "T1 capacity = origin rows" || \
	fail "T1 capacity $(blockdev --getsize64 $MD) != $(( O * ROW ))"
$MDADM --examine "${M[0]}" | grep -q "Snapshots : on" && pass "T1 --examine shows snapshots" || \
	fail "T1 --examine"

# T2 a snapshot keeps its content across overwrites.  Every origin row is
# written first: there is no initial sync, so a row never written has
# garbage parity and reads differently when a member is missing
for r in $(seq 0 $(( O - 1 ))); do wr $(( r * ROW )) $ROW base$r; done
h0=$(md5 $MD)
snap --create s1 --tag fs --attr fsname=t1 || fail "T2 create s1"
d1=$(sdev s1) || fail "T2 no device for s1"
for r in $(seq 0 9); do wr $(( r * ROW )) $ROW new$r; done		# whole rows
for r in $(seq 10 19); do wr $(( r * ROW + 8192 )) 4096 part$r; done	# partial
h1=$(md5 $MD)
[ "$(md5 "$d1")" = "$h0" ] && pass "T2 s1 = the origin at create" || fail "T2 s1 changed"
[ "$h1" != "$h0" ] && pass "T2 origin changed" || fail "T2 origin unchanged"
# every COW wrote its new row whole (in more than one bio when the row is
# over 1 MiB): those rows are W, not N
[ "$(rm_get written)" -ge 20 ] && pass "T2 COW target rows W ($(rm_get written) written, $(rm_get needsync) needsync)" || \
	fail "T2 written $(rm_get written) needsync $(rm_get needsync)"
if [ $ROW -le $((1024 * 1024)) ]; then
	[ "$(rm_get needsync)" = 0 ] && pass "T2 no row left N" || fail "T2 needsync $(rm_get needsync)"
fi
# A whole-row COW needs the row in one bio: a direct write from 4 KiB
# pages comes in bios of at most 256 pages (BIO_MAX_VECS), so a row over
# 1 MiB (20:6:2's 1.5 MiB) is always two pieces and copied partially
if [ $ROW -le $((1024 * 1024)) ]; then
	[ "$(sn_get cow_whole)" -ge 10 ] && [ "$(sn_get cow_partial)" -ge 10 ] && \
		pass "T2 COWs: $(sn_get cow_whole) whole, $(sn_get cow_partial) partial" || \
		fail "T2 cow counts $(sn_get cow_whole) $(sn_get cow_partial)"
else
	[ $(( $(sn_get cow_whole) + $(sn_get cow_partial) )) -ge 20 ] && \
		pass "T2 COWs: $(sn_get cow_whole) whole, $(sn_get cow_partial) partial (rows over 1 MiB: two bios each)" || \
		fail "T2 cow counts $(sn_get cow_whole) $(sn_get cow_partial)"
fi

# T3 clean stop/assemble: everything back from the checkpoint
restart || exit 1
d1=$(sdev s1) || fail "T3 no device for s1 after assemble"
[ "$(md5 "$d1")" = "$h0" ] && pass "T3 s1 intact after stop/assemble" || fail "T3 s1 changed"
[ "$(md5 $MD)" = "$h1" ] && pass "T3 origin intact" || fail "T3 origin changed"
snap --list s1 | grep -q "magic=fs-ss fsname=t1" && pass "T3 attributes kept" || \
	fail "T3 attributes: $(snap --list s1)"
[ "$(sn_get replayed)" = 0 ] && pass "T3 nothing to replay after a clean stop" || \
	fail "T3 replayed $(sn_get replayed)"

# T4 a stop without a checkpoint: the journal replays
echo Y > /sys/module/raidkm/parameters/snap_test_no_stop_ckpt
for r in $(seq 20 29); do wr $(( r * ROW )) $ROW j$r; done
snap --create s2 --attr made=t4 || fail "T4 create s2"
for r in $(seq 30 39); do wr $(( r * ROW + 4096 )) 8192 k$r; done
snap --rename s2 s2b || fail "T4 rename"
snap --set s2b note=x || fail "T4 set"
h2=$(md5 "$(sdev s2b)"); h3=$(md5 $MD)
restart || exit 1
echo N > /sys/module/raidkm/parameters/snap_test_no_stop_ckpt
[ "$(sn_get replayed)" -gt 0 ] && pass "T4 replayed $(sn_get replayed) journal op(s)" || \
	fail "T4 nothing replayed"
[ "$(md5 "$(sdev s1)")" = "$h0" ] && [ "$(md5 "$(sdev s2b)")" = "$h2" ] && \
	[ "$(md5 $MD)" = "$h3" ] && pass "T4 s1, s2b, origin intact after replay" || \
	fail "T4 content after replay"
snap --list s2b | grep -q "note=x" && ! snap --exists s2 && \
	pass "T4 rename and set replayed" || fail "T4 rename/set: $(snap --list)"
snap --list s2b | grep -q "made=t4" && pass "T4 attributes given at create replayed" || \
	fail "T4 create's attributes lost in replay: $(snap --list s2b)"
# the first record after a replay comes after a checkpoint of it (replay
# may have taken the last record from one member only)
c0=$(sn_get checkpoints)
wr $(( 45 * ROW )) $ROW after-replay
[ "$(sn_get checkpoints)" -gt "$c0" ] && [ "$(sn_get journal_tail)" -ge $(( $(sn_get journal_head) - 1 )) ] && \
	pass "T4 first commit after the replay settled it (checkpoint, tail $(sn_get journal_tail) head $(sn_get journal_head))" || \
	fail "T4 no checkpoint before the first record after replay (checkpoints $c0 -> $(sn_get checkpoints))"
h3=$(md5 $MD)

# T5 destroy the middle one, stop/assemble
snap --create s3 || fail "T5 create s3"
for r in $(seq 40 49); do wr $(( r * ROW )) $ROW m$r; done
h4=$(md5 "$(sdev s3)"); h5=$(md5 $MD)
snap --destroy s2b || fail "T5 destroy s2b"
restart || exit 1
[ "$(md5 "$(sdev s1)")" = "$h0" ] && [ "$(md5 "$(sdev s3)")" = "$h4" ] && \
	[ "$(md5 $MD)" = "$h5" ] && ! snap --exists s2b && \
	pass "T5 middle destroyed; s1, s3, origin intact" || fail "T5 after destroy"

# T6 many commits: the ring (1024 records) wraps, checkpoints are taken at
# half full.  A set is one record and needs no rows; COWs in between
c0=$(sn_get checkpoints); j0=$(sn_get journal_head)
for i in $(seq 1 1300); do
	snap --set s1 n=$i || { fail "T6 set $i"; break; }
	[ $((i % 100)) = 0 ] && { snap --create w$i; wr $(( (i / 100) * ROW + 4096 )) 4096 w$i; snap --destroy w$i; }
done
[ "$(sn_get checkpoints)" -gt "$c0" ] && [ $(( $(sn_get journal_head) - j0 )) -gt 1024 ] && \
	pass "T6 $(( $(sn_get journal_head) - j0 )) records, $(( $(sn_get checkpoints) - c0 )) checkpoint(s)" || \
	fail "T6 records $(( $(sn_get journal_head) - j0 )) checkpoints $(( $(sn_get checkpoints) - c0 ))"
h6=$(md5 $MD)
echo Y > /sys/module/raidkm/parameters/snap_test_no_stop_ckpt
restart || exit 1
echo N > /sys/module/raidkm/parameters/snap_test_no_stop_ckpt
content T6 "$h6" && snap --list s1 | grep -q " n=1300" && \
	pass "T6 intact after the wraps (replayed $(sn_get replayed))" || fail "T6 content after wraps"

# T7 degraded: two members missing
h7=$(md5 $MD)
restart "${M[@]:2}" || exit 1
content T7 "$h7" && pass "T7 degraded by 2: intact" || fail "T7 degraded"

# T8 the two come back (stale: a full rebuild each, seeded first).  Their
# metadata must be what the others hold, byte for byte (load would fall
# back to another member and hide a bad copy), and the array must come up
# without two members that were never rebuilt
$MDADM $MD --add "${M[0]}" >/dev/null 2>&1 || fail "T8 add ${M[0]}"
$MDADM $MD --add "${M[1]}" >/dev/null 2>&1 || fail "T8 add ${M[1]}"
idle
snap --set s3 t8=1 || fail "T8 set"		# a record after the seed
# where the region starts: data_offset + the kernel's component size
# (chunk-rounded) [+ the rkdcl chunk] + the row map's pages
SZ=$(( $(cat /sys/block/$MDN/md/component_size) * 2 / 256 * 256 ))
$MDADM --stop $MD >/dev/null
DO=$($MDADM --examine "${M[5]}" | awk '/Data Offset/ {print $4}')
[ -n "$DO" ] && [ "$SZ" -gt 0 ] || fail "T8 region offset (data offset '$DO', size '$SZ')"
ROWS=$(( SZ / 256 )); RMP=$(( (ROWS + 16319) / 16320 ))
# with --checksum the CRC region sits before the row map (km
# raidkm_csum_reserve_sectors(): a slot per 4K, 1022 per page, 64 KiB-rounded)
CSR=0; [ "${SNAP_CSUM:-0}" = 1 ] && CSR=$(( ( (SZ / 8 + 1021) / 1022 * 8 + 127) / 128 * 128 ))
SNOFF=$(( (DO + SZ + DCL_SECT + CSR) / 8 + RMP ))	# 4 KiB page of the region's start
NRM=$(( (ROWS + 509) / 510 )); NPM=$(( (NRM + 4079) / 4080 ))
# header, table and pmap copies: the seed's and the stop's checkpoints write
# both copies of each to every member.  (Not the rmap slots: the slot a page
# is not in may hold anything, e.g. what a re-added member had before.)
META=$(( 46 + 2 * NPM ))
regmd5() { dd if="$1" bs=4096 skip=$SNOFF count=$META status=none | md5sum | cut -c1-32; }
r5=$(regmd5 "${M[5]}")
[ "$(regmd5 "${M[0]}")" = "$r5" ] && [ "$(regmd5 "${M[1]}")" = "$r5" ] && \
	pass "T8 rebuilt members hold the same metadata as the others" || \
	fail "T8 metadata differs: m0 $(regmd5 "${M[0]}") m1 $(regmd5 "${M[1]}") m5 $r5"
assemble "${M[0]}" "${M[1]}" "${M[@]:4}" || exit 1	# 2, 3 left out
content T8 "$h7" && snap --list s3 | grep -q "t8=1" && \
	pass "T8 the rebuilt two + 6 others: intact" || fail "T8 after rebuild"

# T9 both header copies and the table damaged on the first member
$MDADM --stop $MD >/dev/null
dd if=/dev/urandom of="${M[0]}" bs=4096 count=46 seek=$SNOFF conv=notrunc status=none
assemble "${M[@]}" || { fail "T9 no assemble with a damaged header"; exit 1; }
content T9 "$h7" && pass "T9 damaged header and table on one member: read from the others" || \
	fail "T9"

# T10 the reserve fills up: writes fail with ENOSPC, snapshots intact
snap --create full || fail "T10 create"
n=0
for r in $(seq 0 $(( O - 1 ))); do wr $(( r * ROW )) $ROW f$r 2>/dev/null || n=$((n + 1)); done
[ "$n" -gt 0 ] && [ "$(sn_get cow_nospc)" -gt 0 ] && pass "T10 $n write(s) refused, reserve full" || \
	fail "T10 nospc $n $(sn_get cow_nospc)"
same T10 "$h0" "$(sdev s1)" && pass "T10 s1 intact with the reserve full" || fail "T10 s1"
snap --destroy full && snap --destroy s3 && pass "T10 destroy frees rows ($(sn_get free_rows) free)" || \
	fail "T10 destroy"

# T11 auto-read-only after assemble (md_mod start_ro=1): a snapshot command
# switches the array to read-write as a first write would, and works
$MDADM --stop $MD >/dev/null
echo 1 > /sys/module/md_mod/parameters/start_ro
assemble "${M[@]}" || exit 1
echo 0 > /sys/module/md_mod/parameters/start_ro
st0=$(cat /sys/block/$MDN/md/array_state)
$MDADM --stop $MD >/dev/null
echo 1 > /sys/module/md_mod/parameters/start_ro
assemble "${M[@]}" || exit 1
echo 0 > /sys/module/md_mod/parameters/start_ro
snap --checkpoint && [ "$(cat /sys/block/$MDN/md/array_state)" != read-auto ] && \
	pass "T11 checkpoint on a read-auto array switches it and writes" || \
	fail "T11 checkpoint on read-auto ($(cat /sys/block/$MDN/md/array_state))"
$MDADM --stop $MD >/dev/null
echo 1 > /sys/module/md_mod/parameters/start_ro
assemble "${M[@]}" || exit 1
echo 0 > /sys/module/md_mod/parameters/start_ro
snap --create ro1 && [ "$(cat /sys/block/$MDN/md/array_state)" != read-auto ] && \
	pass "T11 create on a read-auto array ($st0 -> $(cat /sys/block/$MDN/md/array_state))" || \
	fail "T11 create on read-auto ($st0 -> $(cat /sys/block/$MDN/md/array_state))"
restart || exit 1
snap --exists ro1 && pass "T11 it persists" || fail "T11 ro1 gone after restart"
snap --destroy ro1

# T12 a spare without room for the snapshot metadata is refused
truncate -s $(( MEMSZ - 3 ))M $SNMEM/small
SMALL=$(losetup -f --show $SNMEM/small)
$MDADM $MD --add "$SMALL" >$RK_DIR/sn-small.log 2>&1 && fail "T12 a too small spare was added" || \
	pass "T12 too small spare refused: $(tail -1 $RK_DIR/sn-small.log)"
grep -q "$(basename $SMALL)" /proc/mdstat && fail "T12 $SMALL in the array" || pass "T12 array unchanged"
losetup -d "$SMALL"; rm -f $SNMEM/small

# T13 (declustered) a member fails and is populated into the spare
# columns: the snapshots and the origin read the same from there; then a
# new disk takes its place by the copy from the spare, and gets the row map
# and the snapshot metadata before the copy (it is seeded as a recovering
# member is): the array comes up from it without two other members
if [ -n "${SNAP_DCL:-}" ]; then
	wr $(( 5 * ROW )) $ROW t13a
	snap --create p1 || fail "T13 create p1"
	for r in $(seq 50 59); do wr $(( r * ROW )) $ROW t13-$r; done
	wr $(( 60 * ROW + 4096 )) 4096 t13part
	hp=$(md5 "$(sdev p1)"); hs1=$(md5 "$(sdev s1)"); h13=$(md5 $MD)
	V=${M[3]}; VS=$(cat /sys/block/$MDN/md/dev-$(basename "$V")/slot)
	$MDADM $MD --fail "$V" >/dev/null 2>&1 && $MDADM $MD --remove "$V" >/dev/null 2>&1 || fail "T13 fail/remove $V"
	echo "$VS" > /sys/block/$MDN/md/rk_dcl_populate 2>/dev/null || fail "T13 arm population of slot $VS"
	t=0
	until grep -q "^populated $VS " /sys/block/$MDN/md/rk_dcl_populate; do
		[ $t -ge 600 ] && { fail "T13 population: $(cat /sys/block/$MDN/md/rk_dcl_populate | tr '\n' ' ')"; break; }
		sleep 0.5; t=$((t + 1))
	done
	idle
	same "T13 populated p1" "$hp" "$(sdev p1)" && same "T13 populated s1" "$hs1" "$(sdev s1)" && \
		same "T13 populated origin" "$h13" $MD && \
		pass "T13 slot $VS populated into the spare: p1, s1, origin intact" || fail "T13 after population"
	# a COW while populated: the write goes to the spare columns
	wr $(( 70 * ROW )) $ROW t13pop; wr $(( 71 * ROW + 8192 )) 4096 t13pop2
	h13=$(md5 $MD)
	same "T13 COW while populated" "$hp" "$(sdev p1)" && pass "T13 COWs while populated keep p1" || \
		fail "T13 COWs while populated"
	dd if=/dev/zero of="$SPARE" bs=1M count=$MEMSZ status=none
	$MDADM $MD --add "$SPARE" >/dev/null 2>&1 || fail "T13 add $SPARE"
	idle
	dmesg | grep -q "copy of disk .* COMPLETE" && pass "T13 copy-back from the spare to the new disk" || \
		fail "T13 no copy-back ($(dmesg | grep -iE 'declustered|retired|copy' | tail -2 | tr '\n' ' '))"
	dmesg | grep -q "row map: .* page(s) written to $(basename "$SPARE") before its rebuild" && \
		pass "T13 the new disk got the row map before the copy" || fail "T13 no row map seed for $SPARE"
	[ "$(cat /sys/block/$MDN/md/degraded)" = 0 ] && pass "T13 not degraded" || \
		fail "T13 degraded $(cat /sys/block/$MDN/md/degraded)"
	snap --set p1 t13=1 || fail "T13 set"
	$MDADM --stop $MD >/dev/null
	r5=$(regmd5 "${M[5]}")
	[ "$(regmd5 "$SPARE")" = "$r5" ] && pass "T13 the new disk holds the same snapshot metadata" || \
		fail "T13 metadata on $SPARE $(regmd5 "$SPARE"), others $r5"
	RMOFF=$(( (DO + SZ + DCL_SECT + CSR) / 8 ))	# past the CRC region with --checksum
	rmmd5() { dd if="$1" bs=4096 skip=$RMOFF count=$RMP status=none | md5sum | cut -c1-32; }
	[ "$(rmmd5 "$SPARE")" = "$(rmmd5 "${M[5]}")" ] && pass "T13 and the same row map" || \
		fail "T13 row map on $SPARE differs"
	NEW=("${M[@]:0:3}" "$SPARE" "${M[@]:6}")	# 4 and 5 left out
	assemble "${NEW[@]}" || exit 1
	same "T13 p1" "$hp" "$(sdev p1)" && same "T13 s1" "$hs1" "$(sdev s1)" && same "T13 origin" "$h13" $MD && \
		snap --list p1 | grep -q "t13=1" && pass "T13 the new disk + others, two left out: intact" || \
		fail "T13 after the copy-back"
	M=("${NEW[@]:0:3}" "$SPARE" "${M[4]}" "${M[5]}" "${M[@]:6}")
fi

dmesg | grep -qE "WARNING|BUG|Oops|inconsistent" && fail "kernel warnings (dmesg)" || pass "no kernel warnings"
teardown	# before the verdict: a tmpfs that will not unmount is a FAIL
# with --checksum no test here corrupts data: any mismatch is a stale or
# missing CRC (the dmesg ring was cleared at the start)
if [ "${SNAP_CSUM:-0}" = 1 ]; then
	n=$(dmesg | grep -c "native csum mismatch")
	[ "$n" = 0 ] && pass "no native csum mismatch" || fail "$n native csum mismatch(es)"
fi
echo "RESULT pass=$PASS fail=$FAIL"
echo "==== snap-persist: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
