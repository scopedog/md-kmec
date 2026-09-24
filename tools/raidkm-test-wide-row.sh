#!/bin/bash
# raidkm-test-wide-row.sh — arrays whose row is over 1 MiB take whole-row bios.
#
# raid5_set_limits() raises max_hw_sectors to io_opt (one row) when a row is
# over RAID5_MAX_REQ_STRIPES stripes, so raid5_make_request() sees bios of
# more stripes than the old fixed on-stack bitmap held: 10+2 at 256 KiB is a
# 2.5 MiB row, 640 stripes, against 320 bits.  The request context now comes
# from a pool sized for the largest bio (raid5_create_ctx_pool).  Under KASAN
# the old code reports stack-out-of-bounds in __bitmap_set on the first such
# bio; everywhere, the data and parity must be right.  A bio over 1 MiB needs
# physically contiguous pages (256 segments per bio), so the large-bio
# writes come from huge pages (fio --iomem=shmhuge).
#   T1  the array advertises whole-row bios
#   T2  aligned whole-row bios from huge pages: fio write+verify, scrub
#   T3  the same size, unaligned (one stripe past a row): fio verify, scrub
#   T4  ordinary dd writes of a row each: read back, scrub
#
# Usage: bash <this>
set -u
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

CHUNK_KB=${CHUNK_KB:-256}
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=12; M=2
RK_CREATE_EXTRA="${RK_CREATE_EXTRA:---bitmap=none}"
MEMBERS=()
cleanup() {
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	local d
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
}
trap cleanup EXIT

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
rk_setup_brd "$N" || exit 1
DISKS=$(rk_pick_disks "$N") || { echo "ERROR: need $N devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"
splats() { sudo dmesg | grep -cE "WARNING:|BUG:|KASAN:|blocked for more than"; }
same() {	# same <file> <offset bytes>
	local len want got
	len=$(stat -c %s "$1"); want=$(md5sum < "$1" | cut -d' ' -f1)
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	got=$(sudo dd if="$MD" bs=1M skip="$2" iflag=direct,skip_bytes status=none 2>/dev/null |
		head -c "$len" | md5sum | cut -d' ' -f1)
	[ "$want" = "$got" ]
}

sudo dmesg -C
rk_create "${M}r" "${MEMBERS[@]:0:$N}" || { rk_fail "create $((N - M))+$M at ${CHUNK_KB}K"; rk_summary; exit 1; }
ROWB=$(( (N - M) * CHUNK_KB * 1024 ))
STRIPEB=4096

echo "=== T1: row $((ROWB / 1024)) KiB ==="
MAXKB=$(cat "/sys/block/$MDNAME/queue/max_hw_sectors_kb")
[ $((MAXKB * 1024)) -ge "$ROWB" ] && rk_pass "T1: max_hw_sectors_kb $MAXKB covers a row" \
	|| rk_fail "T1: max_hw_sectors_kb $MAXKB below a row: the test proves nothing"

HP0=$(cat /proc/sys/vm/nr_hugepages)
echo 64 | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
fiow() {	# fiow <tag> <offset bytes>: whole-row bios from huge pages, verified
	sudo fio --output="$RK_TMP/wide-$1.fio" --name=w --filename="$MD" --direct=1 \
		--ioengine=libaio --rw=write --bs="$ROWB" --iodepth=4 --offset="$2" \
		--size=$(( 16 * ROWB )) --iomem=shmhuge --verify=crc32c --verify_fatal=1 \
		>/dev/null 2>&1
}
if [ "$(awk '/HugePages_Free/{print $2}' /proc/meminfo)" -ge 8 ]; then
	echo "=== T2: aligned whole-row bios ==="
	fiow aligned 0 && rk_pass "T2: fio write+verify clean" || rk_fail "T2: fio verify FAILED"
	[ "$(rk_scrub)" = 0 ] && rk_pass "T2: scrub clean" || rk_fail "T2: parity mismatch"
	echo "=== T3: unaligned bios of a row plus a stripe ==="
	fiow unaligned "$STRIPEB" && rk_pass "T3: fio write+verify clean" || rk_fail "T3: fio verify FAILED"
	[ "$(rk_scrub)" = 0 ] && rk_pass "T3: scrub clean" || rk_fail "T3: parity mismatch"
else
	rk_skip_check "T2/T3: no huge pages to write whole-row bios from"
fi
echo "$HP0" | sudo tee /proc/sys/vm/nr_hugepages >/dev/null

echo "=== T4: ordinary dd writes of a row each ==="
dd if=/dev/urandom of="$RK_TMP/wr" bs="$ROWB" count=24 status=none
sudo dd if="$RK_TMP/wr" of="$MD" bs="$ROWB" oflag=direct status=none 2>/dev/null
same "$RK_TMP/wr" 0 && rk_pass "T4: data right" || rk_fail "T4: data WRONG"
[ "$(rk_scrub)" = 0 ] && rk_pass "T4: scrub clean" || rk_fail "T4: parity mismatch"

[ "$(splats)" = 0 ] && rk_pass "no WARN/BUG/KASAN/hung task" || rk_fail "$(splats) kernel splat line(s)"
rk_summary
