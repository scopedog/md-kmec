#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# raidkm-test-snap-convert.sh: add native snapshots to an existing --row-map
# array, offline (mdadm --grow /dev/mdX --snapshots=N <members>, stopped).
#
#   C1  refused while the array runs; refused with a member missing
#   C2  ext4 with files, then a convert before the tail was given up: refused,
#       naming the row that holds data and the size to shrink to
#   C3  resize2fs to that size, blkdiscard the rest, convert: done; the array
#       exports the origin (the size it named), the files match, e2fsck clean
#   C4  snapshots work: create, overwrite files, the snapshot mounts with the
#       old ones; across a stop and assemble too
#   C5  converting again: nothing to do
#   C6  interrupted after k superblocks (MDADM_TEST_GROW_SNAP_STOP), the same
#       command again finishes it (with --snapshots after the members); a
#       different reserve is refused; files match
#   C7  an array without the row map: refused
# SC_CSUM=1: every array with --checksum (the CRC region moves too; no csum
# mismatch the whole run).  SC_DCL=N:g:s: declustered (the rkdcl block moves).
#
#   sudo RAIDKM_KO=.../raidkm.ko ISAL_KO=.../isal_lib.ko MDADM=.../mdadm \
#        [SC_CSUM=1] [SC_DCL=14:6:2] bash tools/raidkm-test-snap-convert.sh
if command -v gnudd >/dev/null 2>&1; then dd() { gnudd "$@"; }; fi
set -u
# the kernel-log verdict every suite shares: RK_SPLAT with the known platform
# artifacts (RK_DMESG_KNOWN) filtered out
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"
splats() { dmesg | rk_dmesg_filter_known | grep -E "$RK_SPLAT"; }
TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
KO=${RAIDKM_KO:-$TREE/km/raidkm.ko}
ISAL=${ISAL_KO:-$TREE/isa-l/isal_lib.ko}
MDADM=${MDADM:-$(command -v mdadm)}
RK_DIR=${RK_TMP:-/tmp/raidkm-test}/snapconv; mkdir -p "$RK_DIR" || exit 1
MEM=$RK_DIR/mem; MNT=$RK_DIR/mnt; SMNT=$RK_DIR/smnt; mkdir -p $MNT $SMNT
MD=/dev/md70; MDN=md70; SYS=/sys/block/$MDN/md
NMEM=10; MEMSZ=${SC_MEMSZ:-160}; CHUNK=128; PCT=20
CSUM=; [ "${SC_CSUM:-0}" = 1 ] && CSUM=--checksum
GEOM=(--raid-devices=$NMEM)
if [ -n "${SC_DCL:-}" ]; then
	IFS=: read -r NMEM DG DS <<<"$SC_DCL"
	GEOM=(--raid-devices=$NMEM --layout=declustered --group-width=$DG --spare-columns=$DS)
else
	GEOM+=(--layout=rotating)
fi
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }
sv() { awk -v k="$1" '$1 == k {print $2}' $SYS/rk_snap; }
idle() { local t=0; while ! grep -q idle $SYS/sync_action 2>/dev/null; do
	[ $t -ge 1200 ] && break; sleep 0.5; t=$((t + 1)); done; }
M=()
teardown() {
	umount $SMNT 2>/dev/null; umount $MNT 2>/dev/null
	$MDADM --stop $MD >/dev/null 2>&1
	local l
	for l in "${M[@]:-}"; do [ -n "$l" ] && losetup -d "$l" 2>/dev/null; done
	M=()
	memfree
}
memfree() {	# loop detach is asynchronous: wait for it, never stack tmpfs mounts
	local t
	for t in $(seq 50); do mountpoint -q $MEM || return 0; umount $MEM 2>/dev/null; sleep 0.2; done
	umount -l $MEM
}
trap teardown EXIT
# raidkm-test-ci.sh ends a suite past its limit with SIGTERM, which skips an
# EXIT trap unless it is turned into an exit
trap 'exit 130' INT
trap 'exit 143' TERM
load() {
	modprobe -a md_mod raid6_pq async_tx async_xor async_memcpy async_pq async_raid6_recov 2>/dev/null
	lsmod | grep -q '^raidkm' && { rmmod raidkm || exit 1; }
	lsmod | grep -q '^isal_lib' || { [ -f "$ISAL" ] && insmod "$ISAL" || modprobe isal_lib; }
	if [ -f "$KO" ]; then insmod "$KO"; else modprobe raidkm; fi || exit 1
}
members() {
	memfree; mkdir -p $MEM; mount -t tmpfs -o size=$(( NMEM * MEMSZ + 32 ))m tmpfs $MEM || exit 1
	local i
	for i in $(seq 0 $((NMEM - 1))); do
		truncate -s ${MEMSZ}M $MEM/m$i; M+=("$(losetup -f --show $MEM/m$i)")
	done
}
create() {	# create [--row-map]
	$MDADM --create $MD --level=raidkm --parity-count=2 "${GEOM[@]}" --chunk=$CHUNK \
		--bitmap=none "$@" $CSUM --run --force "${M[@]}" >$RK_DIR/create.out 2>&1 ||
		{ fail "create: $(tail -1 $RK_DIR/create.out)"; return 1; }
	idle
}
asm() { $MDADM --assemble $MD "${M[@]}" >$RK_DIR/asm.out 2>&1 && idle; }
conv() { $MDADM --grow $MD --snapshots=$PCT "${M[@]}" >$RK_DIR/conv.out 2>&1; }
files() {	# files <tag>: 12 files of 4 MiB, their md5s to $RK_DIR/<tag>.md5
	local i
	for i in $(seq 1 12); do head -c 4M /dev/urandom > $MNT/f$i; done
	sync; (cd $MNT && md5sum f* > $RK_DIR/$1.md5)
}
check_files() { (cd "$1" && md5sum -c --quiet $RK_DIR/$2.md5 >/dev/null 2>&1); }

load
modprobe ext4 2>/dev/null
dmesg -C
# ---- C1, C2, C3 ---------------------------------------------------------------
members; create --row-map || exit 1
mkfs.ext4 -q -F $MD && mount $MD $MNT || { fail "mkfs/mount"; exit 1; }
files a
# fill the filesystem once (mkfs discarded the array, and ext4 keeps its
# metadata near the start): rows past the origin hold data now
dd if=/dev/zero of=$MNT/fill bs=1M status=none 2>/dev/null; sync; rm -f $MNT/fill
umount $MNT
conv && fail "C1 converted a running array" || {
	grep -q "is active" $RK_DIR/conv.out && pass "C1 refused while the array runs" ||
		fail "C1 refusal: $(cat $RK_DIR/conv.out)"; }
$MDADM --stop $MD >/dev/null
$MDADM --grow $MD --snapshots=$PCT "${M[@]:1}" >$RK_DIR/conv.out 2>&1 && fail "C1 converted with a member missing" || {
	grep -q "the array has $NMEM" $RK_DIR/conv.out && pass "C1 refused with a member missing" ||
		fail "C1 member missing: $(cat $RK_DIR/conv.out)"; }
conv && fail "C2 converted with data past the origin" || {
	if grep -q "holds data" $RK_DIR/conv.out; then
		pass "C2 refused: $(head -1 $RK_DIR/conv.out | sed 's/^mdadm: //')"
	else
		fail "C2 refusal: $(cat $RK_DIR/conv.out)"
	fi; }
OB=$(sed -n 's/.*Shrink the filesystem to at most \([0-9]*\) bytes.*/\1/p' $RK_DIR/conv.out)
[ -n "$OB" ] || { fail "C2 no size to shrink to"; exit 1; }
asm || { fail "C3 assemble: $(tail -1 $RK_DIR/asm.out)"; exit 1; }
e2fsck -fy $MD >/dev/null 2>&1
resize2fs $MD $(( OB / 1024 ))K >$RK_DIR/resize.out 2>&1 || { fail "C3 resize2fs: $(tail -1 $RK_DIR/resize.out)"; exit 1; }
blkdiscard -o $OB $MD || fail "C3 blkdiscard"
$MDADM --stop $MD >/dev/null
if conv; then
	pass "C3 converted: $(grep -o 'origin [0-9]* of [0-9]* rows[^;]*' $RK_DIR/conv.out)"
else
	fail "C3 convert: $(cat $RK_DIR/conv.out)"; exit 1
fi
asm || { fail "C3 assemble after: $(tail -1 $RK_DIR/asm.out)"; exit 1; }
[ "$(blockdev --getsize64 $MD)" = "$OB" ] && [ "$(sv reserve_pct)" = $PCT ] &&
	pass "C3 the array exports the origin ($OB bytes), reserve $PCT% ($(sv reserve_rows) rows)" ||
	fail "C3 size $(blockdev --getsize64 $MD), expected $OB; rk_snap: $(head -3 $SYS/rk_snap 2>&1 | tr '\n' ' ')"
e2fsck -fn $MD >/dev/null 2>&1 && pass "C3 e2fsck clean" || fail "C3 e2fsck"
mount $MD $MNT && check_files $MNT a && pass "C3 the files match" || fail "C3 files differ"

# ---- C4 -----------------------------------------------------------------------
fsfreeze -f $MNT; echo "create s1" > $SYS/rk_snap; fsfreeze -u $MNT
files b
S1=$(awk '$1 == "snap" && $2 == "name=s1" {sub("dev=", "", $5); print $5}' $SYS/rk_snap); udevadm settle
mount -o ro,noload $S1 $SMNT 2>/dev/null && check_files $SMNT a && pass "C4 the snapshot has the old files, the origin the new ($(sv cow_whole) + $(sv cow_partial) COWs)" ||
	fail "C4 snapshot $S1"
umount $SMNT 2>/dev/null
check_files $MNT b || fail "C4 origin files"
umount $MNT; $MDADM --stop $MD >/dev/null; asm
S1=$(awk '$1 == "snap" && $2 == "name=s1" {sub("dev=", "", $5); print $5}' $SYS/rk_snap); udevadm settle
mount -o ro,noload $S1 $SMNT 2>/dev/null && check_files $SMNT a && mount $MD $MNT && check_files $MNT b &&
	pass "C4 both after a stop and assemble" || fail "C4 after assemble"
umount $SMNT 2>/dev/null; umount $MNT 2>/dev/null
$MDADM --stop $MD >/dev/null

# ---- C5 -----------------------------------------------------------------------
conv && grep -q "nothing to do" $RK_DIR/conv.out && pass "C5 converting again: nothing to do" ||
	fail "C5 again: $(cat $RK_DIR/conv.out)"
teardown

# ---- C6 -----------------------------------------------------------------------
members; create --row-map || exit 1
mkfs.ext4 -q -F $MD && mount $MD $MNT && files c &&
	{ dd if=/dev/zero of=$MNT/fill bs=1M status=none 2>/dev/null; sync; rm -f $MNT/fill; umount $MNT; }
$MDADM --stop $MD >/dev/null; conv
OB=$(sed -n 's/.*Shrink the filesystem to at most \([0-9]*\) bytes.*/\1/p' $RK_DIR/conv.out)
asm; e2fsck -fy $MD >/dev/null 2>&1; resize2fs $MD $(( OB / 1024 ))K >/dev/null 2>&1
blkdiscard -o $OB $MD; $MDADM --stop $MD >/dev/null
MDADM_TEST_GROW_SNAP_STOP=4 $MDADM --grow $MD --snapshots=$PCT "${M[@]}" >$RK_DIR/conv.out 2>&1 &&
	fail "C6 the stop hook did not stop" ||
	grep -q "MDADM_TEST_GROW_SNAP_STOP" $RK_DIR/conv.out || fail "C6 hook: $(cat $RK_DIR/conv.out)"
$MDADM --grow $MD --snapshots=$((PCT + 10)) "${M[@]}" >$RK_DIR/conv.out 2>&1 &&
	fail "C6 finished with another reserve" ||
	{ grep -q "was converted with --snapshots=$PCT" $RK_DIR/conv.out &&
		pass "C6 finishing with another reserve is refused" ||
		fail "C6 other reserve: $(cat $RK_DIR/conv.out)"; }
# the members first, --snapshots after: either order works
$MDADM --grow $MD "${M[@]}" --snapshots=$PCT >$RK_DIR/conv.out 2>&1 &&
	grep -q "now has snapshots" $RK_DIR/conv.out && pass "C6 interrupted after 4 superblocks, the same command finished it" ||
	fail "C6 finish: $(cat $RK_DIR/conv.out)"
asm && [ "$(blockdev --getsize64 $MD)" = "$OB" ] && e2fsck -fn $MD >/dev/null 2>&1 &&
	mount $MD $MNT && check_files $MNT c && pass "C6 assembled: origin size, e2fsck clean, files match" ||
	fail "C6 after finish: size $(blockdev --getsize64 $MD 2>/dev/null) vs $OB"
umount $MNT 2>/dev/null
teardown

# ---- C7 -----------------------------------------------------------------------
members; create || exit 1
$MDADM --stop $MD >/dev/null
conv && fail "C7 converted an array without the row map" ||
	{ grep -q "no row map" $RK_DIR/conv.out && pass "C7 refused without the row map" ||
		fail "C7: $(cat $RK_DIR/conv.out)"; }
teardown

if [ -n "$CSUM" ]; then
	n=$(dmesg | grep -c "native csum mismatch")
	[ "$n" = 0 ] && pass "no native csum mismatch" || fail "$n native csum mismatch(es)"
fi
splats | grep -q . && fail "kernel: $(splats | head -1)" || pass "no WARN/BUG"
echo "==== snap-convert: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
