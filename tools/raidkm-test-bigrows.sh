#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# raidkm-test-bigrows.sh: arrays with more rows than one kmalloc can hold a
# bit for.  The row map and the snapshots keep one bit per row in core
# (rm->rec_skipped, sn->used, the moved bitmap at assemble; the origin map is
# a sparse directory of leaves, sn->odir); with
# kmalloc (bitmap_zalloc) an array past 33.5 M rows failed RUN_ARRAY with
# ENOMEM and a page_alloc WARNING.
#
# 12 sparse members of BR_SIZE (140 GiB) at --chunk=4: 36.7 M rows.  Each
# case creates the array, writes and reads back at both ends, takes a
# snapshot and overwrites (the snapshot case), stops and assembles again
# (the map load and, with snapshots, rk_sn_derive()), and reads back.
#
# Needs ~2.5 GiB of real disk under RK_TMP (default /var/tmp: the members
# are sparse, tmpfs would hold them in RAM) and ~1 GiB of RAM.
#
#   sudo RAIDKM_KO=km/raidkm.ko ISAL_KO=.../isal_lib.ko MDADM=.../mdadm \
#        tools/raidkm-test-bigrows.sh
BR_TMP=${RK_TMP:-/var/tmp}	# before the lib sets its own RK_TMP default
# the kernel-log verdict every suite shares: RK_SPLAT with the known platform
# artifacts (RK_DMESG_KNOWN) filtered out
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"
splats() { dmesg | rk_dmesg_filter_known | grep -E "$RK_SPLAT"; }
TREE=$(cd "$(dirname "$0")/.." && pwd)
KO=${RAIDKM_KO:-$TREE/km/raidkm.ko}
ISAL_KO=${ISAL_KO:-$TREE/isa-l/isal_lib.ko}
MDADM=${MDADM:-$(command -v mdadm)}
grep -qa -- --snapshots "$MDADM" 2>/dev/null || { echo "set MDADM to an mdadm with --snapshots"; exit 1; }
SIZE=${BR_SIZE:-140G}
NMEM=12
D=$BR_TMP/raidkm-test/bigrows
MD=/dev/md71; MDN=md71
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; }
rk_modload() {	# rk_modload <ko path> <module> [params...]
	local ko=$1 mod=$2; shift 2
	if [ -f "$ko" ]; then insmod "$ko" "$@"; else modprobe "$mod" "$@"; fi
}
L=()
teardown() {
	$MDADM --stop $MD >/dev/null 2>&1
	for l in "${L[@]}"; do losetup -d "$l" 2>/dev/null; done
	rm -rf "$D"
}
trap teardown EXIT
# raidkm-test-ci.sh ends a suite past its limit with SIGTERM, which skips an
# EXIT trap unless it is turned into an exit
trap 'exit 130' INT
trap 'exit 143' TERM

modprobe -a md_mod raid6_pq async_tx async_xor async_memcpy async_pq async_raid6_recov 2>/dev/null
if [ "${RK_RELOAD:-1}" = 1 ]; then
	lsmod | grep -q '^raidkm' && { rmmod raidkm || exit 1; }
	lsmod | grep -q '^isal_lib' || rk_modload "$ISAL_KO" isal_lib
	rk_modload "$KO" raidkm || exit 1
fi
mkdir -p "$D" || exit 1
for i in $(seq 0 $((NMEM - 1))); do
	truncate -s "$SIZE" "$D/m$i" || exit 1
	L+=("$(losetup -f --show "$D/m$i")") || exit 1
done

snap() { $MDADM --snapshot $MD "$@"; }
sdev() {	# the snapshot disk of <name>, once udev made it
	local d t=0
	while :; do
		d=$(snap --list "$1" 2>/dev/null | grep -o 'dev=[^ ]*' | cut -d= -f2)
		[ -n "$d" ] && [ "$d" != - ] && [ -b "$d" ] && { echo "$d"; return; }
		[ $t -ge 50 ] && return 1
		sleep 0.2; t=$((t + 1))
	done
}
# md5 of 4 MiB of <dev> at MiB offset <off>
md5at() { dd if="$1" bs=1M skip="$2" count=4 iflag=direct status=none | md5sum | cut -c1-32; }
putat() {	# putat <dev> <MiB offset> <file>
	dd if="$3" of="$1" bs=1M seek="$2" count=4 oflag=direct conv=notrunc status=none
}
head -c 4M /dev/urandom > "$D/a"; head -c 4M /dev/urandom > "$D/b"
HA=$(md5sum < "$D/a" | cut -c1-32); HB=$(md5sum < "$D/b" | cut -c1-32)

# the bitmaps at stake are only past 4 MiB when rows > 33.5 M
rows_of() { awk '$1 == "rows" {print $2}' /sys/block/$MDN/md/rk_rowmap 2>/dev/null; }

run_case() {	# run_case <label> <create options...>
	local lab=$1 rows end; shift
	echo "== $lab: $*"
	dmesg -C
	if ! $MDADM --create $MD --level=raidkm --parity-count=2 --raid-devices=$NMEM \
		--chunk=4 --bitmap=none "$@" --run --force "${L[@]}" >"$D/create.log" 2>&1; then
		fail "$lab: create: $(grep -v Defaulting "$D/create.log" | tail -1)"
		dmesg | grep -E "WARNING|alloc|RUN_ARRAY" | head -3
		cleanup_case; return
	fi
	pass "$lab: created"
	rows=$(rows_of)
	if [ -n "$rows" ] && [ "$rows" -gt 33554432 ]; then
		pass "$lab: $rows rows (more than one kmalloc'd bitmap holds)"
	else
		fail "$lab: rows '$rows' not past 33.5 M (BR_SIZE too small?)"
	fi
	end=$(( $(blockdev --getsize64 $MD) / 1048576 - 4 ))
	putat $MD 0 "$D/a"; putat $MD $end "$D/b"
	if [ "$(md5at $MD 0)" = "$HA" ] && [ "$(md5at $MD $end)" = "$HB" ]; then
		pass "$lab: write and read back at both ends"
	else
		fail "$lab: read back at the ends"
	fi
	if [ "$lab" = snapshots ]; then
		# sparse origin map: ~8 bytes per 1024 rows until rows move,
		# where a flat map took 4 bytes per row
		local ob o
		ob=$(awk '$1 == "origin_map_bytes" {print $2}' /sys/block/$MDN/md/rk_snap)
		o=$(awk '$1 == "origin_rows" {print $2}' /sys/block/$MDN/md/rk_snap)
		[ -n "$ob" ] && [ "$ob" -lt $(( o / 64 )) ] &&
			pass "$lab: origin map $ob bytes for $o rows (flat: $(( o * 4 )))" ||
			fail "$lab: origin map '$ob' bytes for $o rows"
		snap --create s1 || fail "$lab: snapshot create"
		putat $MD 0 "$D/b"; putat $MD $end "$D/a"
		local s; s=$(sdev s1)
		if [ -n "$s" ] && [ "$(md5at "$s" 0)" = "$HA" ] && [ "$(md5at "$s" $end)" = "$HB" ] &&
		   [ "$(md5at $MD 0)" = "$HB" ] && [ "$(md5at $MD $end)" = "$HA" ]; then
			pass "$lab: overwrite after a snapshot (COW at both ends)"
		else
			fail "$lab: COW: snapshot '$s' or origin reads wrong"
		fi
	fi
	$MDADM --stop $MD >/dev/null 2>&1 || fail "$lab: stop"
	if $MDADM --assemble $MD --run "${L[@]}" >"$D/asm.log" 2>&1; then
		pass "$lab: assembled again"
		local x y
		if [ "$lab" = snapshots ]; then x=$HB; y=$HA; else x=$HA; y=$HB; fi
		[ "$(md5at $MD 0)" = "$x" ] && [ "$(md5at $MD $end)" = "$y" ] &&
			pass "$lab: content after assemble" || fail "$lab: content after assemble"
		if [ "$lab" = snapshots ]; then
			s=$(sdev s1)
			[ -n "$s" ] && [ "$(md5at "$s" 0)" = "$HA" ] && [ "$(md5at "$s" $end)" = "$HB" ] &&
				pass "$lab: snapshot after assemble" || fail "$lab: snapshot after assemble"
		fi
	else
		fail "$lab: assemble: $(tail -1 "$D/asm.log")"
	fi
	if splats | grep -q . || dmesg | grep -q "Cannot allocate"; then
		fail "$lab: kernel log: $({ splats; dmesg | grep "Cannot allocate"; } | head -1)"
	else
		pass "$lab: no WARNING"
	fi
	cleanup_case
}
cleanup_case() {
	$MDADM --stop $MD >/dev/null 2>&1
	for l in "${L[@]}"; do $MDADM --zero-superblock "$l" >/dev/null 2>&1; done
	# drop what the case wrote: the next case starts from sparse members
	for i in $(seq 0 $((NMEM - 1))); do
		truncate -s 0 "$D/m$i"; truncate -s "$SIZE" "$D/m$i"
	done
	for l in "${L[@]}"; do losetup -c "$l"; done
}

run_case rowmap --row-map
run_case checksum --row-map --checksum
run_case snapshots --snapshots=10

echo "==== raidkm-test-bigrows.sh: $PASS passed, $FAIL failed ===="
[ $FAIL = 0 ]
