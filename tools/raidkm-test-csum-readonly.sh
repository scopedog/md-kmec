#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# raidkm-test-csum-readonly.sh: a native CRC mismatch the parity cannot repair
# fails the read with EIO on a read-only array -- it must not hang the array.
#
# md core records the bad block unacknowledged and sets MD_SB_CHANGE_PENDING;
# a read-only array never writes its superblock, so before the fix the flag
# stayed and every stripe (and so every read) waited for it forever.
#
# One clean image (6 members, m=2, --checksum, 8 MiB of known bytes, stopped:
# its CRCs on disk) is restored for each case; the cases rot the first 4 KiB
# of member data area on some members (one stripe, every member slot of it):
#
#   R1  one member rotted (the one holding array offset 0), --readonly:
#       the read repairs through the parity (the bytes come back right, the
#       mismatch is seen, no bad block -- a read-only array does not rewrite
#       the block)
#   R1b two members (m; array offsets 0 and 64 KiB), --readonly: the same
#   R2  three members rotted (> m), --readonly: the stripe's 4 KiB pieces
#       fail with EIO within the timeout, the rest of the array reads back
#       right, the array stays read-only, a second read of the stripe fails
#       again, mdadm --stop works
#   R3  the same, read-auto (md_mod start_ro=1): the same, read-auto kept
#   R4  the same, read-write: EIO, the bad blocks are acknowledged (written
#       to the superblock), the rest reads back right
#
# A hung read is reported and the suite stops: the array cannot be stopped
# then, reboot the host.  The released module before the fix hangs in R2.
#
#   sudo RAIDKM_KO=.../raidkm.ko ISAL_KO=.../isal_lib.ko MDADM=.../mdadm \
#        bash tools/raidkm-test-csum-readonly.sh
if command -v gnudd >/dev/null 2>&1; then dd() { gnudd "$@"; }; fi
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"
TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
KO=${RAIDKM_KO:-$TREE/km/raidkm.ko}
ISAL=${ISAL_KO:-$TREE/isa-l/isal_lib.ko}
MDADM=${MDADM:-$(command -v mdadm)}
RK_DIR=${RK_TMP:-/tmp/raidkm-test}/csum-ro; mkdir -p "$RK_DIR" || exit 1
MEM=$RK_DIR/mem
MD=/dev/md73; MDN=md73; SYS=/sys/block/$MDN/md
NMEM=6; MEMSZ=64; CHUNK=64; GENMB=8; NDATA=4
TMO=${RO_TIMEOUT:-60}
PASS=0; FAIL=0; HUNG=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }
idle() { local t=0; while ! grep -q idle $SYS/sync_action 2>/dev/null; do
	[ $t -ge 1200 ] && break; sleep 0.5; t=$((t + 1)); done; }
M=()
START_RO=$(cat /sys/module/md_mod/parameters/start_ro 2>/dev/null || echo 0)
detach() { local l; for l in "$@"; do [ -n "$l" ] && losetup -d "$l" 2>/dev/null; done; }
memfree() {	# loop detach is asynchronous: wait for it, never stack tmpfs mounts
	local t
	for t in $(seq 50); do mountpoint -q $MEM || return 0; umount $MEM 2>/dev/null; sleep 0.2; done
	umount -l $MEM
}
teardown() {
	$MDADM --stop $MD >/dev/null 2>&1
	detach "${M[@]:-}"; M=()
	memfree
}
restore() {
	echo "$START_RO" > /sys/module/md_mod/parameters/start_ro 2>/dev/null
	# a hung array cannot be stopped: leave it, say so
	[ $HUNG = 1 ] && { echo "a read hung: $MD left as it is, reboot the host"; return; }
	teardown
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
load() {
	modprobe -a md_mod raid6_pq async_tx async_xor async_memcpy async_pq async_raid6_recov 2>/dev/null
	lsmod | grep -q '^raidkm' && { rmmod raidkm || exit 1; }
	lsmod | grep -q '^isal_lib' || { [ -f "$ISAL" ] && insmod "$ISAL" || modprobe isal_lib; }
	if [ -f "$KO" ]; then insmod "$KO"; else modprobe raidkm; fi || exit 1
}
mark() { MK="csum-ro $$.$(date +%s%N)"; echo "$MK" > /dev/kmsg; }
mm() { dmesg | sed -n "/$MK/,\$p" | grep -c "native csum mismatch"; }
bb() { cat $SYS/dev-*/bad_blocks 2>/dev/null | grep -c .; }
ubb() { cat $SYS/dev-*/unacknowledged_bad_blocks 2>/dev/null | grep -c .; }
state() { cat $SYS/array_state 2>/dev/null; }
# rd <out> <skip KiB> <count KiB>: O_DIRECT read in the background, waited for
# TMO s; 0 = read, 1 = I/O error, 2 = still running (hung)
rd() {
	local out=$1 t pid rc
	dd if=$MD of=$out bs=4k skip=$(($2 / 4)) count=$(($3 / 4)) iflag=direct \
		status=none 2>$RK_DIR/rd.err &
	pid=$!
	for t in $(seq $((TMO * 4))); do
		kill -0 $pid 2>/dev/null || break
		sleep 0.25
	done
	if kill -0 $pid 2>/dev/null; then
		HUNG=1
		return 2
	fi
	wait $pid; rc=$?
	[ $rc = 0 ] && return 0 || return 1
}
# watch <what> <command...>: run it in the background, waited for TMO s; a
# command still running then is a hang: report it and stop the suite
watch() {
	local what=$1 t pid; shift
	"$@" >$RK_DIR/watch.out 2>&1 &
	pid=$!
	for t in $(seq $((TMO * 4))); do kill -0 $pid 2>/dev/null || break; sleep 0.25; done
	if kill -0 $pid 2>/dev/null; then
		HUNG=1
		fail "${CASE:-?} $what HUNG ($TMO s): $(state), $(ubb) unacknowledged bad block(s)"
		exit 1
	fi
	wait $pid
}
# same <KiB offset> <KiB count> <file>: the bytes match generation 1
same() { cmp -s <(dd if=$RK_DIR/g bs=4k skip=$(($1 / 4)) count=$(($2 / 4)) status=none) "$3"; }
image() {	# the clean image: g on the array, stopped, a copy of each member
	local i
	memfree; mkdir -p $MEM
	mount -t tmpfs -o size=$(( NMEM * MEMSZ * 2 + 64 ))m tmpfs $MEM || exit 1
	for i in $(seq 0 $((NMEM - 1))); do
		truncate -s ${MEMSZ}M $MEM/m$i; M+=("$(losetup -f --show $MEM/m$i)")
	done
	$MDADM --create $MD --level=raidkm --parity-count=2 --layout=rotating \
		--raid-devices=$NMEM --chunk=$CHUNK --checksum --run --force \
		"${M[@]}" >$RK_DIR/create.out 2>&1 ||
		{ echo "create: $(tail -1 $RK_DIR/create.out)"; exit 1; }
	idle
	head -c ${GENMB}M /dev/urandom > $RK_DIR/g
	dd if=$RK_DIR/g of=$MD bs=1M oflag=direct status=none || { echo "write failed"; exit 1; }
	DOFF=$($MDADM --examine ${M[0]} | awk '/Data Offset/ {print $4}')
	[ -n "$DOFF" ] || { echo "no Data Offset in --examine"; exit 1; }
	# the members holding array KiB 0 and 64 (data, not parity, at the
	# stripe the cases rot)
	D0=$(owner 0); D1=$(owner $CHUNK)
	[ -n "$D0" ] && [ -n "$D1" ] || { echo "no member holds array KiB 0/$CHUNK"; exit 1; }
	$MDADM --stop $MD >/dev/null 2>&1 || { echo "stop failed"; exit 1; }
	detach "${M[@]}"; M=()
	sleep 0.5
	for i in $(seq 0 $((NMEM - 1))); do cp --sparse=always $MEM/m$i $MEM/c$i; done
}
owner() {	# owner <array KiB>: the member whose first 4 KiB of data are those
	local i
	for i in $(seq 0 $((NMEM - 1))); do
		cmp -s <(dd if=${M[$i]} bs=512 skip=$DOFF count=8 status=none) \
			<(dd if=$RK_DIR/g bs=4k skip=$(($1 / 4)) count=1 status=none) &&
			{ echo $i; return; }
	done
}
# start <case> <rotted members...> -- <assemble options>: restore the image,
# rot the first 4 KiB of the data area on the given members, assemble
start() {
	local i r=() a=()
	CASE=$1; shift
	while [ $# -gt 0 ] && [ "$1" != -- ]; do r+=("$1"); shift; done
	[ $# -gt 0 ] && shift; a=("$@")
	$MDADM --stop $MD >/dev/null 2>&1
	detach "${M[@]:-}"; M=()
	sleep 0.5
	for i in $(seq 0 $((NMEM - 1))); do cp --sparse=always $MEM/c$i $MEM/m$i; done
	for i in "${r[@]}"; do
		head -c 4096 /dev/urandom | dd of=$MEM/m$i bs=512 seek=$DOFF conv=notrunc status=none
	done
	for i in $(seq 0 $((NMEM - 1))); do M+=("$(losetup -f --show $MEM/m$i)"); done
	mark
	# the old hang caught mdadm's own probe of block 0 (the stripe rotted
	# here): watched like a read
	watch "assemble" $MDADM --assemble "${a[@]}" $MD "${M[@]}" ||
		{ fail "$CASE assemble: $(tail -1 $RK_DIR/watch.out)"; return 1; }
	watch "udevadm settle" udevadm settle
	idle
}
hung() { fail "$CASE read HUNG ($TMO s): $(state), $(ubb) unacknowledged bad block(s)"; exit 1; }
# the stripe the cases rot: member offset 0 of each data slot, array KiB
# offsets 0, 64, 128, 192 (the slot order does not matter, all four are read)
stripe_eio() {	# stripe_eio <tag>: each 4 KiB piece fails, none hangs
	local o bad=0 ok=0 rc
	for o in $(seq 0 $CHUNK $(( (NDATA - 1) * CHUNK ))); do
		rd $RK_DIR/p $o 4; rc=$?
		[ $rc = 2 ] && hung
		[ $rc = 1 ] && bad=$((bad + 1)) || ok=$((ok + 1))
	done
	# with m=2 three rotted members leave every data piece of the stripe
	# unrepairable only if they include it; at least one piece is on them
	[ $bad -ge 1 ] && pass "$CASE $1: $bad of $NDATA stripe pieces fail with EIO" ||
		fail "$CASE $1: no stripe piece failed"
}
rest_ok() {	# the array beyond the stripe reads back right
	local rc
	rd $RK_DIR/r 4 $((CHUNK - 4)); rc=$?
	[ $rc = 2 ] && hung
	[ $rc = 0 ] && same 4 $((CHUNK - 4)) $RK_DIR/r &&
		pass "$CASE the rest of the first chunk reads back right" ||
		fail "$CASE the rest of the first chunk: rc $rc"
	rd $RK_DIR/r 1024 $(( (GENMB - 1) * 1024 )); rc=$?
	[ $rc = 2 ] && hung
	[ $rc = 0 ] && same 1024 $(( (GENMB - 1) * 1024 )) $RK_DIR/r &&
		pass "$CASE MiB 1..$GENMB read back right" ||
		fail "$CASE MiB 1..$GENMB: rc $rc"
}
stop_ok() {
	watch "mdadm --stop" $MDADM --stop $MD && pass "$CASE mdadm --stop" ||
		fail "$CASE stop: $(tail -1 $RK_DIR/watch.out)"
}

load
image
echo "image: data offset $DOFF sectors, array KiB 0 on member $D0, KiB $CHUNK on member $D1"

repaired() {	# repaired <case> <rotted members...>
	local c=$1 rc n; shift
	echo "== $c: $# rotted member(s) ($*), --readonly"
	start $c "$@" -- --readonly || return
	[ "$(state)" = readonly ] && pass "$c read-only" || fail "$c state $(state)"
	rd $RK_DIR/r 0 $((GENMB * 1024)); rc=$?
	[ $rc = 2 ] && hung
	n=$(mm)
	[ $rc = 0 ] && same 0 $((GENMB * 1024)) $RK_DIR/r && [ "$n" -ge $# ] &&
		pass "$c all $GENMB MiB read back right ($n csum mismatch(es) repaired)" ||
		fail "$c read: rc $rc, $n csum mismatch(es) $(head -1 $RK_DIR/rd.err)"
	[ "$(bb)" = 0 ] && [ "$(ubb)" = 0 ] && pass "$c no bad block" ||
		fail "$c $(bb) bad-block range(s), $(ubb) unacknowledged"
	stop_ok
}
# ---- R1, R1b: within the parity, --readonly --------------------------------
repaired R1 $D0
repaired R1b $D0 $D1

# ---- R2: three members, --readonly ---------------------------------------
echo "== R2: three rotted members, --readonly"
if start R2 0 1 2 -- --readonly; then
	[ "$(state)" = readonly ] && pass "R2 read-only" || fail "R2 state $(state)"
	stripe_eio "first read"
	rest_ok
	stripe_eio "second read"
	[ "$(state)" = readonly ] && pass "R2 still read-only" || fail "R2 state now $(state)"
	echo "  R2: $(mm) csum mismatch(es), $(ubb) unacknowledged bad block(s)"
	stop_ok
fi

# ---- R3: three members, read-auto -----------------------------------------
echo "== R3: three rotted members, read-auto"
if echo 1 > /sys/module/md_mod/parameters/start_ro && start R3 0 1 2 --; then
	[ "$(state)" = read-auto ] && pass "R3 read-auto" || fail "R3 state $(state)"
	stripe_eio "first read"
	rest_ok
	[ "$(state)" = read-auto ] && pass "R3 still read-auto" || fail "R3 state now $(state)"
	stop_ok
fi
echo "$START_RO" > /sys/module/md_mod/parameters/start_ro

# ---- R4: three members, read-write ----------------------------------------
echo "== R4: three rotted members, read-write"
if start R4 0 1 2 --; then
	[ "$(state)" = clean ] || [ "$(state)" = active ] && pass "R4 read-write ($(state))" ||
		fail "R4 state $(state)"
	stripe_eio "first read"
	rest_ok
	# md acknowledges them in its next superblock write: poll
	for t in $(seq $((TMO * 4))); do
		[ "$(bb)" -ge 1 ] && [ "$(ubb)" = 0 ] && break
		sleep 0.25
	done
	[ "$(bb)" -ge 1 ] && [ "$(ubb)" = 0 ] &&
		pass "R4 bad blocks acknowledged ($(bb) range(s))" ||
		fail "R4 bad blocks: $(bb) acknowledged, $(ubb) not"
	stop_ok
fi

echo "==== raidkm-test-csum-readonly.sh: $PASS passed, $FAIL failed ===="
[ $FAIL = 0 ]
