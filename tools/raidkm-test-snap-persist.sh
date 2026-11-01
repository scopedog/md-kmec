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
set -u
KO=${RAIDKM_KO:?set RAIDKM_KO to raidkm.ko}
ISAL_KO=${ISAL_KO:?set ISAL_KO to isal_lib.ko}
MDADM=${MDADM:?set MDADM to an mdadm with --snapshots}
MD=/dev/md70; MDN=md70
NMEM=10; MEMSZ=64		# MiB
ROW=$((1024 * 1024))
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }
sn_get() { awk -v k="$1" '$1 == k {print $2}' /sys/block/$MDN/md/rk_snap; }
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

teardown() {
	$MDADM --stop $MD >/dev/null 2>&1
	for f in /snmem/*; do
		[ -e "$f" ] || continue
		for l in $(losetup -j "$f" -O NAME -n); do losetup -d "$l"; done
	done
	umount /snmem 2>/dev/null
}

load() {
	modprobe -a md_mod raid6_pq async_tx async_xor async_memcpy async_pq async_raid6_recov 2>/dev/null
	lsmod | grep -q '^raidkm' && { rmmod raidkm || exit 1; }
	lsmod | grep -q '^isal_lib' || insmod $ISAL_KO
	insmod $KO || exit 1
}

members() {
	mkdir -p /snmem; mount -t tmpfs -o size=$(( (NMEM + 2) * MEMSZ + 32 ))m tmpfs /snmem
	M=()
	for i in $(seq 0 $NMEM); do
		head -c ${MEMSZ}M /dev/urandom > /snmem/m$i
		M+=("$(losetup -f --show /snmem/m$i)")
	done
	SPARE=${M[$NMEM]}; unset "M[$NMEM]"
}

assemble() {	# assemble [members...]: default all
	local mem=("$@")
	[ ${#mem[@]} -gt 0 ] || mem=("${M[@]}")
	$MDADM --assemble --run $MD "${mem[@]}" >/tmp/sn-asm.log 2>&1 || { cat /tmp/sn-asm.log; return 1; }
	idle
}

restart() {	# stop, assemble [members]
	$MDADM --stop $MD >/dev/null || { fail "stop"; return 1; }
	assemble "$@"
}

echo "== snapshot persistence test"
trap teardown EXIT
teardown
load
dmesg -C
members
$MDADM --create $MD --level=raidkm --parity-count=2 --layout=rotating \
	--raid-devices=$NMEM --chunk=128 --bitmap=none --snapshots=20 \
	--run --force "${M[@]}" >/tmp/sn-create.log 2>&1 || { cat /tmp/sn-create.log; exit 1; }
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
[ "$(sn_get cow_whole)" -ge 10 ] && [ "$(sn_get cow_partial)" -ge 10 ] && \
	pass "T2 COWs: $(sn_get cow_whole) whole, $(sn_get cow_partial) partial" || \
	fail "T2 cow counts $(sn_get cow_whole) $(sn_get cow_partial)"

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
# (chunk-rounded) + the row map's pages
SZ=$(( $(cat /sys/block/$MDN/md/component_size) * 2 / 256 * 256 ))
$MDADM --stop $MD >/dev/null
DO=$($MDADM --examine "${M[5]}" | awk '/Data Offset/ {print $4}')
[ -n "$DO" ] && [ "$SZ" -gt 0 ] || fail "T8 region offset (data offset '$DO', size '$SZ')"
ROWS=$(( SZ / 256 )); RMP=$(( (ROWS + 16319) / 16320 ))
SNOFF=$(( (DO + SZ) / 8 + RMP ))		# 4 KiB page of the region's start
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
truncate -s $(( MEMSZ - 3 ))M /snmem/small
SMALL=$(losetup -f --show /snmem/small)
$MDADM $MD --add "$SMALL" >/tmp/sn-small.log 2>&1 && fail "T12 a too small spare was added" || \
	pass "T12 too small spare refused: $(tail -1 /tmp/sn-small.log)"
grep -q "$(basename $SMALL)" /proc/mdstat && fail "T12 $SMALL in the array" || pass "T12 array unchanged"
losetup -d "$SMALL"; rm -f /snmem/small

dmesg | grep -qE "WARNING|BUG|Oops|inconsistent" && fail "kernel warnings (dmesg)" || pass "no kernel warnings"
echo "RESULT pass=$PASS fail=$FAIL"
[ $FAIL = 0 ]
