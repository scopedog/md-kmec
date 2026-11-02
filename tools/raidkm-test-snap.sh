#!/bin/bash
# raidkm native snapshots: content, freeze, and the regression cases.
#
#   content  a chain of 3, destroy the middle, the newest, the last one; the
#            freed rows go U in the row map at once
#   freeze   ext4 on the origin, a snapshot under load: no needs_recovery,
#            files match, e2fsck clean
#   F1  4 MiB rows: partial COW (pieces of BIO_MAX_VECS)
#   F2  4 KiB at a 512 B offset in a shared row (the merge's page split)
#   F3  1.25 MiB rows on members capped at 1 MiB: 2-piece COWs, snapshot
#       reads across rows (the snapshot queue splits them itself)
#   F4  the array exports the origin, array_size cannot grow past it
#   F5  stop refused while a snapshot is open; stop vs rk_snap commands race
#   F6  more than 64 COWs in flight (overflow list), fio verify
#   F7  WRITE_ZEROES into a shared row reads back zeroes
#   F8  attributes: replacing a key that is not the last one
#   F9  more snapshots with attributes than md/rk_snap's one page holds:
#       mdadm --snapshot lists, finds and destroys them all
#   perf (SNAP_PERF=1)  4K / 1M first and second pass after a snapshot,
#            member bytes per user byte (rk_row_write=1)
#
#   sudo RAIDKM_KO=.../raidkm.ko ISAL_KO=.../isal_lib.ko MDADM=.../mdadm \
#        [SKIP="f3 ..."] [SNAP_PERF=1] bash tools/raidkm-test-snap.sh
# Arrays are created with --snapshots=25 (origin 3/4 of the rows).
# Ubuntu 26.04's dd is uutils coreutils, whose O_DIRECT I/O of 128 KiB and
# more fails with EINVAL (and may not issue a block as one write); GNU dd is
# installed beside it as gnudd.
if command -v gnudd >/dev/null 2>&1; then dd() { gnudd "$@"; }; fi
set -u
TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
KO=${RAIDKM_KO:-$TREE/km/raidkm.ko}
ISAL=${ISAL_KO:-$TREE/isa-l/isal_lib.ko}
MDADM=${MDADM:-$(command -v mdadm)}
grep -qa -- --snapshots "$MDADM" 2>/dev/null || { echo "set MDADM to an mdadm with --snapshots"; exit 1; }
# Packaged installs (raidkm-test-ci.sh in CI) have no .ko beside the tree:
# a module path that does not exist loads the packaged module with modprobe,
# and MDADM defaults to the mdadm on PATH.
# scratch space under RK_TMP (raidkm-test-lib.sh's convention): the CI image's
# root filesystem is read-only
RK_DIR=${RK_TMP:-/tmp/raidkm-test}/snap; mkdir -p "$RK_DIR" || exit 1
SNAPMEM=$RK_DIR/mem; SNAPO=$RK_DIR/origin; SNAPS=$RK_DIR/snap
rk_modload() {	# rk_modload <ko path> <module> [params...]
	local ko=$1 mod=$2; shift 2
	if [ -f "$ko" ]; then insmod "$ko" "$@"; else modprobe "$mod" "$@"; fi
}
MD=/dev/md70; MDN=md70; SYS=/sys/block/$MDN/md
NMEM=10; MEMSZ=${MEMSZ:-320}
REG=${REG:-192}			# MiB of origin the content tests use (3 x 192 rows fit the reserve)
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }
sv() { awk -v k="$1" '$1 == k {print $2}' $SYS/rk_snap; }
snap() { $MDADM --snapshot $MD "$@"; }
idle() { while ! grep -q idle $SYS/sync_action 2>/dev/null; do sleep 0.5; done; }
dev_of() { awk -v n="name=$1" '$1 == "snap" && $2 == n {sub("dev=", "", $5); print $5}' $SYS/rk_snap; }
sum() {	# a read error must never compare equal
	local s; s=$(set -o pipefail; dd if=$1 bs=1M count=$REG iflag=direct status=none | md5sum) ||
		{ echo "  READ ERROR on $1" >&2; echo "READERR-$RANDOM"; return; }
	echo ${s:0:32}; }
sumr() {	# sumr <dev> <offset MiB> <MiB>
	local s; s=$(set -o pipefail; dd if=$1 bs=1M skip=$2 count=$3 iflag=direct status=none | md5sum) ||
		{ echo "  READ ERROR on $1" >&2; echo "READERR-$RANDOM"; return; }
	echo ${s:0:32}; }
M=()

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

teardown() {
	exec 3<&-
	umount $SNAPO $SNAPS 2>/dev/null
	$MDADM --stop $MD >/dev/null 2>&1
	mem_off $SNAPMEM || fail "teardown: $SNAPMEM still mounted (its tmpfs would leak)"
	if [ -d /sys/kernel/config/nullb ]; then
		for d in /sys/kernel/config/nullb/rk*; do [ -d "$d" ] || continue
			echo 0 > $d/power 2>/dev/null; rmdir $d; done
	fi
	M=()
}
# any exit (an early exit 1 included) gives back md70, the loop devices and
# the tmpfs: the CI guest has no RAM to leave them in
trap teardown EXIT
# mem_on <dir>: a tmpfs still mounted there (mem_off gave up) is never stacked
# on: that is the leak mem_off exists to stop.  The suite stops instead.
mem_on() {
	mkdir -p "$1"
	mountpoint -q "$1" && { fail "$1 still mounted: not stacking another tmpfs on it"; exit 1; }
	mount -t tmpfs -o size=$2 tmpfs "$1" || { fail "mount tmpfs on $1"; exit 1; }
}
loadmod() {
	modprobe -a md_mod raid6_pq async_tx async_xor async_memcpy async_pq async_raid6_recov 2>/dev/null
	lsmod | grep -q '^raidkm' && { rmmod raidkm || exit 1; }
	lsmod | grep -q '^isal_lib' || rk_modload $ISAL isal_lib || exit 1
	rk_modload $KO raidkm || exit 1
}
# mk_loop <n> <MiB each>
mk_loop() {
	mem_on $SNAPMEM $(( $1 * $2 + 64 ))m
	for i in $(seq 0 $(($1 - 1))); do truncate -s ${2}M $SNAPMEM/m$i; M+=("$(losetup -f --show $SNAPMEM/m$i)"); done
}
# mk_nullb <n> <MiB each> <max_sectors>
mk_nullb() {
	modprobe null_blk nr_devices=0 || return 1
	mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
	grep -qw max_sectors /sys/kernel/config/nullb/features || { echo "  null_blk has no max_sectors"; return 1; }
	for i in $(seq 0 $(($1 - 1))); do
		d=/sys/kernel/config/nullb/rk$i; mkdir $d
		echo $2 > $d/size; echo 1 > $d/memory_backed; echo 512 > $d/blocksize
		echo $3 > $d/max_sectors; echo 1 > $d/power
		M+=("/dev/rk$i")
	done
}
# mkarray <chunk KiB>: snapshots on a quarter of the rows
mkarray() {
	$MDADM --create $MD --level=raidkm --parity-count=2 --layout=rotating --raid-devices=${#M[@]} \
		--chunk=$1 --bitmap=none --snapshots=25 --run --force "${M[@]}" >$RK_DIR/mkarray.out 2>&1 || { fail "mdadm --create: $(tail -1 $RK_DIR/mkarray.out)"; return 1; }
	idle
	ROWK=$(( $1 * (${#M[@]} - 2) ))			# row in KiB
}
pyw() {	# pyw <dev> <byte offset> <bytes> <seed> : one O_DIRECT write, data also to $RK_DIR/pyw.<seed>
	python3 -I - "$@" "$RK_DIR/pyw.$4" <<'EOF'
import mmap, os, random, sys
dev, off, n, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
random.seed(seed); data = bytes(random.getrandbits(8) for _ in range(n))
buf = mmap.mmap(-1, (n + 4095) // 4096 * 4096); buf[:n] = data
fd = os.open(dev, os.O_WRONLY | os.O_DIRECT)
w = os.pwritev(fd, [memoryview(buf)[:n]], off); os.close(fd)
open(sys.argv[5], 'wb').write(data)
sys.exit(0 if w == n else 1)
EOF
}
pyr() {	# pyr <dev> <byte offset> <bytes> <seed> : read back == $RK_DIR/pyw.<seed>
	python3 -I - "$@" "$RK_DIR/pyw.$4" <<'EOF'
import os, sys
dev, off, n, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
fd = os.open(dev, os.O_RDONLY); os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
got = os.pread(fd, n, off); os.close(fd)
sys.exit(0 if got == open(sys.argv[5], 'rb').read() else 1)
EOF
}
fill() { fio --name=f --filename=$MD --direct=1 --rw=write --bs=1M --size=${1}M >/dev/null 2>&1; }

f1() {
	echo "== F1: 4 MiB rows (512K chunk x 8), partial COW"
	mk_loop 10 400; mkarray 512 || return
	fill 64; A=$(sumr $MD 0 64)
	echo "create s1" > $SYS/rk_snap; S1=$(dev_of s1); udevadm settle
	ok=1; for i in 0 1 2 3 4 5; do pyw $MD $(( i * 4 * 1048576 + 8192 )) 4096 $((100 + i)) || ok=0; done
	[ $ok = 1 ] && pass "6 partial writes into 4 MiB shared rows (cow_partial $(sv cow_partial))" || fail "partial writes"
	ok=1; for i in 0 1 2 3 4 5; do pyr $MD $(( i * 4 * 1048576 + 8192 )) 4096 $((100 + i)) || ok=0; done
	[ $ok = 1 ] && pass "origin reads the new data" || fail "origin data"
	[ "$(sumr $S1 0 64)" = $A ] && pass "s1 unchanged" || fail "s1 changed"
	echo "destroy s1" > $SYS/rk_snap; teardown
}
f2() {
	echo "== F2: 4 KiB at a 512 B offset in a shared row"
	mk_loop 10 320; mkarray 128 || return
	fill 16; A=$(sumr $MD 0 16)
	echo "create s1" > $SYS/rk_snap; S1=$(dev_of s1); udevadm settle
	pyw $MD 512 4096 200 && pyw $MD $(( 1048576 + 3584 )) 8192 201 || fail "unaligned writes"
	pyr $MD 512 4096 200 && pyr $MD $(( 1048576 + 3584 )) 8192 201 && pass "unaligned partial COWs read back right" || fail "unaligned COW data wrong"
	pyw $MD $(( 2 * 1048576 )) 4096 202; pyr $MD 512 4096 200 && pass "still right after more COWs" || fail "data changed"
	[ "$(sumr $S1 0 16)" = $A ] && pass "s1 unchanged" || fail "s1 changed"
	echo "destroy s1" > $SYS/rk_snap; teardown
}
f3() {
	echo "== F3: 1.25 MiB rows, 1 MiB member cap, snapshot reads across rows"
	mk_nullb 12 320 2048 || { echo "  SKIP F3"; teardown; return; }
	mkarray 128 || return
	echo "    md queue: chunk_sectors $(cat /sys/block/$MDN/queue/chunk_sectors) max_sectors_kb $(cat /sys/block/$MDN/queue/max_sectors_kb), row $ROWK KiB"
	fill 40; A=$(sumr $MD 0 40)
	echo "create s1" > $SYS/rk_snap; S1=$(dev_of s1); udevadm settle
	fio --name=v --filename=$MD --direct=1 --ioengine=libaio --iodepth=8 --rw=write --bs=1M --size=40M \
	    --verify=crc32c --do_verify=1 >$RK_DIR/f3.fio 2>&1 && pass "1M writes across rows + verify" || fail "fio across rows: $(grep -m1 -iE 'err|verify' $RK_DIR/f3.fio)"
	[ "$(sumr $S1 0 40)" = $A ] && pass "s1 unchanged" || fail "s1 changed"
	r=$(sumr $S1 0 40); [ "$r" = $A ] && pass "snapshot reads across rows" || fail "snapshot read"
	echo "destroy s1" > $SYS/rk_snap; teardown
}
f4() {
	echo "== F4: the array exports the origin; array_size cannot grow past it"
	mk_loop 10 320; mkarray 128 || return
	o=$(sv origin_rows); r=$(sv reserve_rows)
	[ "$(blockdev --getsize64 $MD)" = $(( o * ROWK * 1024 )) ] && pass "capacity = $o origin rows of $ROWK KiB ($r reserve)" || \
		fail "capacity $(blockdev --getsize64 $MD) != $o rows"
	echo $(( (o + 1) * ROWK )) > $SYS/array_size 2>/dev/null && fail "array_size raised past the origin" || \
		pass "array_size past the origin refused"
	teardown
}
f5() {
	echo "== F5: stop while a snapshot is open; stop vs commands"
	mk_loop 10 320; mkarray 128 || return
	fill 16; echo "create s1" > $SYS/rk_snap; S1=$(dev_of s1); udevadm settle
	exec 3<$S1
	$MDADM --stop $MD >/dev/null 2>&1 && fail "stop accepted with $S1 open" || pass "stop refused while $S1 is open"
	[ -b $S1 ] && [ "$(sv snapshots)" = 1 ] && pass "array and snapshot still there" || fail "array gone"
	exec 3<&-
	( for i in $(seq 1 200); do echo "create r$i" > $SYS/rk_snap 2>/dev/null; cat $SYS/rk_snap >/dev/null 2>&1
	    echo "destroy r$i" > $SYS/rk_snap 2>/dev/null; done ) &
	L=$!; n=0
	# and opens of the snapshot disks meanwhile: an open waits for md's
	# open_mutex under the disk's own, a stop holds md's and deletes the
	# disks (an ABBA before: both hung)
	( while kill -0 $L 2>/dev/null; do for d in /dev/${MDN}s*; do
		[ -b "$d" ] && dd if=$d of=/dev/null bs=4k count=1 iflag=direct status=none 2>/dev/null; done; done ) &
	O=$!
	while kill -0 $L 2>/dev/null; do $MDADM --stop $MD >/dev/null 2>&1 && break; n=$((n+1)); sleep 0.05; done
	wait $L 2>/dev/null; kill $O 2>/dev/null; wait $O 2>/dev/null
	[ -e /sys/block/$MDN/md/rk_snap ] && $MDADM --stop $MD >/dev/null 2>&1
	[ ! -e /sys/block/$MDN/md/rk_snap ] && pass "stopped after $n refused tries while commands ran" || fail "array did not stop"
	teardown
}
f6() {
	echo "== F6: > 64 COWs in flight (overflow), verify"
	mk_loop 10 320; mkarray 128 || return
	fill 192; echo "create s1" > $SYS/rk_snap; A=$(sumr $(dev_of s1) 0 192)
	fio --name=o --filename=$MD --direct=1 --ioengine=libaio --iodepth=256 --numjobs=2 --rw=randwrite --bs=4k \
	    --size=96M --offset_increment=96M --io_size=12M --verify=crc32c --do_verify=1 --verify_backlog=0 --randseed=7 --group_reporting >$RK_DIR/f6.fio 2>&1 &&
		pass "iodepth 512 random 4K + verify (cow_partial $(sv cow_partial), cow_fail $(sv cow_fail))" || fail "fio: $(grep -m1 -iE 'err|verify' $RK_DIR/f6.fio)"
	[ "$(sumr $(dev_of s1) 0 192)" = $A ] && pass "s1 unchanged" || fail "s1 changed"
	echo "destroy s1" > $SYS/rk_snap; teardown
}
f7() {
	echo "== F7: WRITE_ZEROES into a shared row"
	mk_loop 10 320; mkarray 128 || return
	wz=$(cat /sys/block/$MDN/queue/write_zeroes_max_bytes)
	[ "$wz" -gt 0 ] || { echo "  SKIP F7: write_zeroes_max_bytes 0"; teardown; return; }
	fio --name=f --filename=$MD --direct=1 --rw=write --bs=1M --size=8M --buffer_pattern=0x5a >/dev/null 2>&1
	echo "create s1" > $SYS/rk_snap; S1=$(dev_of s1); A=$(sumr $S1 0 8)
	blkdiscard -z -o $(( 1048576 + 65536 )) -l 8192 $MD || fail "blkdiscard -z"
	z=$(dd if=$MD bs=4096 skip=$(( (1048576 + 65536) / 4096 )) count=2 iflag=direct status=none | tr -d '\0' | wc -c)
	[ "$z" = 0 ] && pass "zeroed range reads zeroes" || fail "zeroed range has $z non-zero bytes"
	[ "$(sumr $S1 0 8)" = $A ] && pass "s1 unchanged" || fail "s1 changed"
	echo "destroy s1" > $SYS/rk_snap; teardown
}
f8() {
	echo "== F8: attrs, replace a key that is not last"
	mk_loop 10 320; mkarray 128 || return
	echo "create a1 k1=one k2=two k3=three" > $SYS/rk_snap
	echo "set a1 k1=uno" > $SYS/rk_snap
	l=$(grep "name=a1 " $SYS/rk_snap | sed 's/.*exc=[0-9]* //')
	[ "$l" = "k2=two k3=three k1=uno" ] && pass "attrs '$l'" || fail "attrs '$l'"
	big=$(printf 'v%.0s' $(seq 1 990))
	echo "set a1 k2=$big" > $SYS/rk_snap && echo "set a1 k3=x" > $SYS/rk_snap && pass "near-full attrs replaced" || fail "set near full"
	echo "destroy a1" > $SYS/rk_snap; teardown
}

f9() {
	echo "== F9: a listing past one page (12 snapshots, ~900 B of attributes each)"
	mk_loop 10 320; mkarray 128 || return
	big=$(printf 'x%.0s' $(seq 1 880))
	for i in $(seq 1 12); do snap --create b$i --attr pad=$big --attr n=$i || { fail "create b$i"; return; }; done
	l=$(snap --list); c=$(echo "$l" | grep -c "pad=$big")
	[ "$c" = 12 ] && pass "--list shows all 12 with their attributes ($(echo "$l" | wc -c) bytes)" || fail "--list shows $c of 12"
	[ "$(echo "$l" | sed -n 's/^name=\([^ ]*\).*/\1/p' | tr '\n' ' ')" = "b1 b2 b3 b4 b5 b6 b7 b8 b9 b10 b11 b12 " ] && \
		pass "in id order" || fail "order: $(echo "$l" | sed -n 's/^name=\([^ ]*\).*/\1/p' | tr '\n' ' ')"
	snap --exists b12 && snap --list b12 | grep -q " n=12" && pass "--exists / --list of the last one" || fail "b12 not found"
	snap --destroy b12 && ! snap --exists b12 && pass "--destroy of the last one" || fail "destroy b12"
	snap --destroy nosuch; [ $? = 1 ] && pass "--destroy of a missing one: exit 1" || fail "destroy nosuch rc"
	for i in $(seq 1 11); do snap --destroy b$i || fail "destroy b$i"; done
	[ "$(snap --list | wc -l)" = 0 ] && pass "all destroyed" || fail "left: $(snap --list | wc -l)"
	teardown
}

setup_content() {
	mk_loop $NMEM $MEMSZ; mkarray 128 || exit 1
	echo "    origin $(sv origin_rows) rows, reserve $(sv reserve_rows) rows"
}
pat() {	# pat <seed> : 4K random + some 1M writes over the region
	fio --name=p --filename=$MD --direct=1 --ioengine=libaio --iodepth=16 --size=${REG}M \
	    --rw=randwrite --bs=4k --io_size=8M --randrepeat=0 --randseed=$1 >/dev/null 2>&1 || fail "pat $1: 4k writes failed"
	fio --name=q --filename=$MD --direct=1 --ioengine=libaio --iodepth=4 --size=${REG}M \
	    --rw=randwrite --bs=1M --io_size=32M --randrepeat=0 --randseed=$(( $1 + 7 )) >/dev/null 2>&1 || fail "pat $1: 1M writes failed"
}
content() {
	echo "== content: chain of 3, destroy middle, destroy newest"
	fio --name=f --filename=$MD --direct=1 --rw=write --bs=1M --size=${REG}M >/dev/null 2>&1
	A=$(sum $MD)
	snap --create s1; S1=$(dev_of s1); udevadm settle
	[ -b "$S1" ] && [ "$(sum $S1)" = $A ] && pass "s1 ($S1) = origin at create" || fail "s1 dev '$S1' content"
	pat 1; B=$(sum $MD)
	[ "$(sum $S1)" = $A ] && [ $B != $A ] && pass "origin changed (cow_whole $(sv cow_whole) cow_partial $(sv cow_partial)), s1 unchanged" || fail "s1 after writes"
	echo "create s2" > $SYS/rk_snap; S2=$(dev_of s2); pat 2; C=$(sum $MD)
	echo "create s3" > $SYS/rk_snap; S3=$(dev_of s3); udevadm settle; pat 3; D=$(sum $MD)
	[ "$(sum $S1)" = $A ] && [ "$(sum $S2)" = $B ] && [ "$(sum $S3)" = $C ] && pass "s1=A s2=B s3=C origin=D" || \
		fail "chain: s1 $( [ "$(sum $S1)" = $A ] && echo ok || echo BAD) s2 $( [ "$(sum $S2)" = $B ] && echo ok || echo BAD) s3 $( [ "$(sum $S3)" = $C ] && echo ok || echo BAD)"
	echo "write" | dd of=$S1 oflag=direct bs=4k count=1 status=none 2>/dev/null && fail "write to a snapshot accepted" || pass "snapshot device refuses writes"
	echo "destroy s2" > $SYS/rk_snap
	[ "$(sum $S1)" = $A ] && [ "$(sum $S3)" = $C ] && [ "$(sum $MD)" = $D ] && pass "destroy middle: s1=A s3=C origin=D" || fail "after destroy s2"
	echo "destroy s3" > $SYS/rk_snap
	pat 4; E=$(sum $MD)
	[ "$(sum $S1)" = $A ] && pass "destroy newest, write more: s1 still A" || fail "s1 after destroy s3 + writes"
	u0=$(awk '$1=="unwritten"{print $2}' $SYS/rk_rowmap)
	echo "destroy s1" > $SYS/rk_snap
	u1=$(awk '$1=="unwritten"{print $2}' $SYS/rk_rowmap)
	[ "$(sum $MD)" = $E ] && pass "destroy last: origin intact; freed $(sv freed) rows, row map unwritten $u0 -> $u1" || fail "origin after destroy s1"
	[ $u1 -gt $u0 ] && pass "freed snapshot rows went U in the row map at once" || fail "row map U $u0 -> $u1"
	[ "$(sv snapshots)" = 0 ] && [ ! -b "$S1" ] && pass "no snapshots left, devices gone" || fail "snapshots $(sv snapshots)"
}

freeze() {
	echo "== freeze: ext4 on the origin, snapshot while mounted under load"
	mkfs.ext4 -q -F -E stride=32,stripe_width=256,nodiscard $MD
	mkdir -p $SNAPO $SNAPS; mount $MD $SNAPO
	for i in $(seq 1 20); do dd if=/dev/urandom of=$SNAPO/f$i bs=1M count=2 status=none; done; sync
	( i=0; while [ -e $SNAPO/f1 ]; do echo $i > $SNAPO/live; i=$((i+1)); dd if=/dev/zero of=$SNAPO/g bs=64k count=16 conv=fsync status=none 2>/dev/null; done ) &
	LOAD=$!; sleep 2
	t0=$(date +%s.%N); echo "create fz" > $SYS/rk_snap; t1=$(date +%s.%N)
	kill $LOAD; wait $LOAD 2>/dev/null
	FZ=$(dev_of fz); udevadm settle
	st=$(dumpe2fs -h $FZ 2>/dev/null | grep -iE "^Filesystem features" | grep -c needs_recovery)
	[ "$st" = 0 ] && pass "snapshot taken under load in $(echo "$t1 - $t0" | bc) s, no needs_recovery" || fail "snapshot needs journal replay"
	mount -o ro,noload $FZ $SNAPS && {
		bad=0; for i in $(seq 1 20); do cmp -s $SNAPO/f$i $SNAPS/f$i || bad=$((bad+1)); done
		[ $bad = 0 ] && pass "20 files on the snapshot match the origin" || fail "$bad files differ"
		umount $SNAPS; }
	e2fsck -fn $FZ >/dev/null 2>&1 && pass "e2fsck -fn on the snapshot: clean" || fail "e2fsck on the snapshot"
	umount $SNAPO
	echo "destroy fz" > $SYS/rk_snap
}

perf() {	# the Phase 0b cases, member bytes per user byte
	echo "== perf vs Phase 0b (rk_row_write=1)"
	echo 1 > $SYS/rk_row_write
	mem() { local r=0 w=0 l s; for l in "${M[@]}"; do s=($(cat /sys/block/$(basename $l)/stat)); r=$((r+s[2])); w=$((w+s[6])); done; echo "$r $w"; }
	run() { local label=$1; shift; sync; echo 3 > /proc/sys/vm/drop_caches; local a=($(mem))
		fio --name=$label --filename=$MD --direct=1 --ioengine=libaio --output-format=json --output=$RK_DIR/sp-$label.json "$@" >/dev/null 2>&1 || fail "fio $label failed"
		local b=($(mem)); read ub iops bw < <(python3 -I -c "import json;d=json.load(open('$RK_DIR/sp-$label.json'))['jobs'][0]['write'];print(d['io_bytes'],round(d['iops']),round(d['bw_bytes']/1048576,1))")
		printf "    %-18s iops=%6s MiB/s=%7s rd/user=%5.2f wr/user=%5.2f\n" $label $iops $bw \
			"$(echo "scale=2; ($((b[0]-a[0]))*512)/$ub" | bc)" "$(echo "scale=2; ($((b[1]-a[1]))*512)/$ub" | bc)"; }
	R4=(--rw=randwrite --bs=4k --iodepth=16 --size=512M --io_size=16M --randrepeat=1 --randseed=42 --norandommap)
	S1M=(--rw=write --bs=1M --iodepth=8 --size=512M)
	run fill-1M "${S1M[@]}"
	run nosnap-4k "${R4[@]}"
	echo "create p1" > $SYS/rk_snap
	run snap-4k-pass1 "${R4[@]}"
	run snap-4k-pass2 "${R4[@]}"
	echo "destroy p1" > $SYS/rk_snap	# its 512 rows back to the reserve
	echo "create p2" > $SYS/rk_snap
	run snap-1M-pass1 "${S1M[@]}"
	run snap-1M-pass2 "${S1M[@]}"
	echo "    cow_whole $(sv cow_whole) cow_partial $(sv cow_partial) cow_fail $(sv cow_fail)"
	[ "$(sv cow_fail)" = 0 ] && [ "$(sv cow_nospc)" = 0 ] && pass "no failed copy-on-write" || fail "cow_fail $(sv cow_fail) cow_nospc $(sv cow_nospc)"
	echo "destroy p2" > $SYS/rk_snap
}


teardown; loadmod
dmesg -C
for t in content freeze f1 f2 f3 f4 f5 f6 f7 f8 f9; do
	case " ${SKIP:-} " in *" $t "*) echo "== $t SKIPPED"; continue ;; esac
	case $t in content|freeze) [ $t = content ] && setup_content; $t; [ $t = freeze ] && teardown ;; *) $t; teardown ;; esac
done
if [ "${SNAP_PERF:-0}" = 1 ]; then setup_content; perf; teardown; fi
dmesg | grep -iE "BUG|WARNING|Oops|KASAN|call trace|beyond end of device|spans a row" | tail -5
dmesg | grep -qiE "BUG|WARNING|Oops|KASAN|beyond end of device" && fail "kernel messages above"
teardown
echo "RESULT pass=$PASS fail=$FAIL"
echo "==== snap: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
