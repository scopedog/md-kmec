#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# raidkm-test-csum-crashlag.sh: native CRCs written back lazily must survive a
# crash at any moment md thinks the array is consistent
# (notes md-kmec/csum-crash-lag-2026-11-05.md, hotfix H, and
# csum-crash-lag-plan-a-2026-11-06.md, plan A).
#
# The CRC region is written back lazily: by a write-back epoch's pass
# (csum_epoch_quiet_ms after the last store, at least every csum_epoch_max_ms),
# at quiesce, stop, eviction and discard drops; md may mark the array clean
# only after the pass.  A crash re-derives CRCs over the resync's scope.  Each
# case writes
# generation 1, stops and assembles (its CRCs on disk), writes generation 2
# (its CRCs in the cache only), then takes a crash image (a copy of every
# member while the array runs), assembles the copies and reads generation 2
# back: no EIO, the bytes of generation 2, no csum mismatch, no bad block,
# then a check: mismatch_cnt 0, still no csum mismatch.
#
#   L1  idle 1 s: the epoch's pass writes the CRCs back, then md marks the
#       array clean; the copies need no resync and read back clean
#   L2  the same with --row-map
#   L3  write-intent bitmap, 1 MiB chunks, time_base 1 s, a writer in another
#       chunk for 8 s: generation 2's bits clear, the resync must not skip it
#   L4  the epoch held open (its pass delayed 10 min): "clean" written to
#       array_state is refused, safe_mode_delay 0.001 does not make it clean
#       either (both checked within ~1 s); the pass at the epoch's ceiling
#       (csum_epoch_max_ms 4 s) writes the CRCs back, the array goes clean,
#       and the copies need no resync
#   L5  mdadm --readonly (md writes the superblock clean): the CRCs reached
#       the disk first, the clean copies need no resync
#   L6  a second crash while the copies' resync is held half way (sync_max):
#       held there, the copies are clean with the checkpoint as their resync
#       offset (their re-derived CRCs below it on disk, plan A step 2); the
#       second copies resync from it and read back clean
#   L7  blocks read (into the stripe cache, verify skipped) while the resync
#       is held after its first chunk: the resync must re-derive their CRCs
#       although they are cached (udev's probe of block 0 hit this in L1)
#   L8  the epoch held open, idle 1 s: the array stays "active" with CRCs in
#       the cache only; the copies resync (H's L1)
#   L9  write-intent bitmap (time_base 1 s) with the epoch held open: the bits
#       of generation 2's chunks stay set on disk while its CRCs are in the
#       cache (plan A step 3), and the copies' bitmap-scoped resync re-derives
#       them and reads back clean
#   L10 a crash image of a module that took no bitmap holds (array active,
#       bits cleared, CRCs in the cache only), started with
#       csum_bitmap_resync=N: the resync ignores the bitmap, reads back clean
#       (skipped in the NEG control)
# L6, L7 and L8 take their first image with the epoch held open, so that it
# needs a resync; the hold is released before the copy (the array's queued
# pass keeps its time), so the copies run with the default epoch times.
# CL_ONLY="L1 L7": run only those cases.  CL_NO_REREAD=1 (csum_test_no_reread=Y)
# with CL_ONLY=L7 must fail L7.
#
# CL_NEG=1: csum_test_no_hold=Y, no epochs and no write-back before md marks
# the array clean; L1, L4, L5 and L9 must fail
# (the run reports "NEG control: failed as expected" and exits 0 then).  L6
# and L7 are skipped: their read-only start of a clean image with stale CRCs
# fails with EIO (before raidkm-test-csum-readonly.sh's fix it blocked on the
# bad blocks md cannot acknowledge read-only).
#
#   sudo RAIDKM_KO=.../raidkm.ko ISAL_KO=.../isal_lib.ko MDADM=.../mdadm \
#        [CL_NEG=1] bash tools/raidkm-test-csum-crashlag.sh
if command -v gnudd >/dev/null 2>&1; then dd() { gnudd "$@"; }; fi
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"
TREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
KO=${RAIDKM_KO:-$TREE/km/raidkm.ko}
ISAL=${ISAL_KO:-$TREE/isa-l/isal_lib.ko}
MDADM=${MDADM:-$(command -v mdadm)}
RK_DIR=${RK_TMP:-/tmp/raidkm-test}/crashlag; mkdir -p "$RK_DIR" || exit 1
MEM=$RK_DIR/mem
MD=/dev/md72; MDN=md72; SYS=/sys/block/$MDN/md
NMEM=6; MEMSZ=${CL_MEMSZ:-96}; CHUNK=64; GENMB=8
NEG=${CL_NEG:-0}
PASS=0; FAIL=0; NEGHIT=()
pass() { PASS=$((PASS + 1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $*"; NEGHIT+=("${CASE:-?}"); }
idle() { local t=0; while ! grep -q idle $SYS/sync_action 2>/dev/null; do
	[ $t -ge 1200 ] && break; sleep 0.5; t=$((t + 1)); done; }
M=(); C=()
detach() { local l; for l in "$@"; do [ -n "$l" ] && losetup -d "$l" 2>/dev/null; done; }
teardown() {
	$MDADM --stop $MD >/dev/null 2>&1
	detach "${M[@]:-}" "${C[@]:-}"; M=(); C=()
	memfree
}
memfree() {	# loop detach is asynchronous: wait for it, never stack tmpfs mounts
	local t
	for t in $(seq 50); do mountpoint -q $MEM || return 0; umount $MEM 2>/dev/null; sleep 0.2; done
	umount -l $MEM
}
P=/sys/module/raidkm/parameters
# epoch_hold [max_ms]: the open epoch's pass waits 10 min, or max_ms (the
# array stays dirty while the CRCs are in the cache only); epoch_release: the
# defaults again (a pass already queued keeps its time)
epoch_hold() { echo 600000 > $P/csum_epoch_quiet_ms; echo ${1:-600000} > $P/csum_epoch_max_ms; }
epoch_release() { echo $EQ > $P/csum_epoch_quiet_ms; echo $EM > $P/csum_epoch_max_ms; }
EQ=100; EM=5000
restore() {
	[ -w $P/csum_epoch_quiet_ms ] && epoch_release
	[ -w /sys/module/raidkm/parameters/csum_test_no_reread ] &&
		echo N > /sys/module/raidkm/parameters/csum_test_no_reread
	[ -w /sys/module/raidkm/parameters/csum_test_no_hold ] &&
		echo N > /sys/module/raidkm/parameters/csum_test_no_hold
	[ -w $P/csum_bitmap_resync ] && echo Y > $P/csum_bitmap_resync
	teardown
}
trap restore EXIT
# raidkm-test-ci.sh ends a suite past its limit with SIGTERM, which skips an
# EXIT trap unless it is turned into an exit: the test parameters and the
# members are restored on every way out
trap 'exit 130' INT
trap 'exit 143' TERM
load() {
	modprobe -a md_mod raid6_pq async_tx async_xor async_memcpy async_pq async_raid6_recov 2>/dev/null
	lsmod | grep -q '^raidkm' && { rmmod raidkm || exit 1; }
	lsmod | grep -q '^isal_lib' || { [ -f "$ISAL" ] && insmod "$ISAL" || modprobe isal_lib; }
	if [ -f "$KO" ]; then insmod "$KO"; else modprobe raidkm; fi || exit 1
	[ -w /sys/module/raidkm/parameters/csum_test_no_hold ] ||
		{ echo "module has no csum_test_no_hold (no hotfix H)"; [ "$NEG" = 1 ] && exit 2; }
	[ -w $P/csum_epoch_quiet_ms ] ||
		{ echo "module has no csum_epoch_quiet_ms (no plan A)"; exit 2; }
	EQ=$(cat $P/csum_epoch_quiet_ms); EM=$(cat $P/csum_epoch_max_ms)
	[ "$NEG" = 1 ] && echo Y > /sys/module/raidkm/parameters/csum_test_no_hold
	[ "${CL_NO_REREAD:-0}" = 1 ] && echo Y > /sys/module/raidkm/parameters/csum_test_no_reread
}
members() {
	memfree; mkdir -p $MEM
	mount -t tmpfs -o size=$(( NMEM * MEMSZ * 3 + 64 ))m tmpfs $MEM || exit 1
	local i
	for i in $(seq 0 $((NMEM - 1))); do
		truncate -s ${MEMSZ}M $MEM/m$i; M+=("$(losetup -f --show $MEM/m$i)")
	done
}
create() {	# create [extra create options]
	$MDADM --create $MD --level=raidkm --parity-count=2 --layout=rotating \
		--raid-devices=$NMEM --chunk=$CHUNK --checksum --run --force "$@" \
		"${M[@]}" >$RK_DIR/create.out 2>&1 ||
		{ fail "create: $(tail -1 $RK_DIR/create.out)"; return 1; }
	idle
}
gen() {	# gen <n>: GENMB MiB of new bytes at offset 0, kept in $RK_DIR/g<n>
	head -c ${GENMB}M /dev/urandom > $RK_DIR/g$1
	dd if=$RK_DIR/g$1 of=$MD bs=1M oflag=direct status=none
}
mark() { MK="crashlag $$.$(date +%s%N)"; echo "$MK" > /dev/kmsg; }
mm() { dmesg | sed -n "/$MK/,\$p" | grep -c "native csum mismatch"; }
bb() { cat $SYS/dev-*/bad_blocks 2>/dev/null | grep -c .; }
resynced() { dmesg | sed -n "/$MK/,\$p" | grep -q "resync of RAID array $MDN"; }
crash() {	# crash <tag> [assemble options]: copy the members of the running
		# array, stop it, assemble the copies (members now = the copies)
	local tag=$1 i old=("${M[@]}"); shift
	for i in $(seq 0 $((NMEM - 1))); do cp --sparse=always $MEM/m$i $MEM/$tag$i; done
	$MDADM --stop $MD >/dev/null 2>&1
	detach "${old[@]}"; M=()
	for i in $(seq 0 $((NMEM - 1))); do rm -f $MEM/m$i; mv $MEM/$tag$i $MEM/m$i; done
	sleep 0.5
	for i in $(seq 0 $((NMEM - 1))); do M+=("$(losetup -f --show $MEM/m$i)"); done
	$MDADM --assemble "$@" $MD "${M[@]}" >$RK_DIR/asm.out 2>&1 ||
		{ fail "$CASE assemble the crash image: $(tail -1 $RK_DIR/asm.out)"; return 1; }
}
verify() {	# verify <gen> [want_resync 0|1]: read back, compare, check
	idle
	if [ $# -ge 2 ]; then
		if resynced; then
			[ "$2" = 1 ] && pass "$CASE the crash image resynced" ||
				fail "$CASE the clean image resynced"
		else
			[ "$2" = 1 ] && fail "$CASE the crash image did not resync" ||
				pass "$CASE no resync (clean)"
		fi
	fi
	if ! dd if=$MD of=$RK_DIR/rb bs=1M count=$GENMB iflag=direct status=none 2>$RK_DIR/rd.err; then
		fail "$CASE read: $(head -1 $RK_DIR/rd.err)"
	elif cmp -s $RK_DIR/rb $RK_DIR/g$1; then
		pass "$CASE generation $1 reads back"
	else
		fail "$CASE generation $1 bytes differ"
	fi
	local n=$(mm) b=$(bb)
	[ "$n" = 0 ] && [ "$b" = 0 ] && pass "$CASE no csum mismatch, no bad block" ||
		fail "$CASE $n csum mismatch(es), $b bad-block range(s)"
	echo check > $SYS/sync_action; sleep 0.5; idle
	n=$(mm)
	[ "$(cat $SYS/mismatch_cnt)" = 0 ] && [ "$n" = 0 ] && pass "$CASE check clean" ||
		fail "$CASE check: mismatch_cnt $(cat $SYS/mismatch_cnt), $n csum mismatch(es)"
}
stopasm() {
	$MDADM --stop $MD >/dev/null 2>&1
	$MDADM --assemble $MD "${M[@]}" >$RK_DIR/asm.out 2>&1 ||
		{ fail "$CASE assemble: $(tail -1 $RK_DIR/asm.out)"; return 1; }
	idle
}
state() { cat $SYS/array_state; }

want() { [ -z "${CL_ONLY:-}" ] || [[ " $CL_ONLY " == *" $1 "* ]]; }

load
dmesg -C
echo "csum_test_no_hold=$(cat /sys/module/raidkm/parameters/csum_test_no_hold 2>/dev/null)"

# ---- L1, L2: idle ------------------------------------------------------------
for CASE in L1 L2; do
	want $CASE || continue
	echo "== $CASE: idle 1 s$([ $CASE = L2 ] && echo ', --row-map')"
	members
	if [ $CASE = L2 ]; then create --bitmap=none --row-map; else create --bitmap=none; fi || { teardown; continue; }
	gen 1; stopasm
	mark; gen 2; sleep 1
	[ "$(state)" = clean ] && pass "$CASE array clean after 1 s idle" ||
		fail "$CASE array_state $(state) after 1 s idle"
	crash c && verify 2 0
	teardown
done

# ---- L8: idle, the epoch held open ---------------------------------------------
CASE=L8
if want L8; then
	echo "== L8: idle 1 s, the epoch held open"
	members
	if create --bitmap=none; then
		gen 1; stopasm
		epoch_hold
		mark; gen 2; sleep 1
		[ "$(state)" = active ] && pass "L8 array stays active" ||
			fail "L8 array_state $(state) after 1 s idle"
		# released before the copy: this array's queued pass keeps its
		# 10 min, the copies run with the defaults
		epoch_release
		crash c && verify 2 1
	fi
	teardown
fi

# ---- L3: bitmap ----------------------------------------------------------------
CASE=L3; echo "== L3: bitmap 1 MiB chunks, writer elsewhere"
members
if want L3 && create --bitmap=internal --bitmap-chunk=1M; then
	echo 1 > $SYS/bitmap/time_base 2>/dev/null
	gen 1; stopasm; echo 1 > $SYS/bitmap/time_base 2>/dev/null
	mark; gen 2
	( while :; do dd if=/dev/urandom of=$MD bs=4k count=1 oflag=direct status=none \
		seek=$(( (MEMSZ * 4 / 2 - 8) * 256 + RANDOM % 1024 )); sleep 0.05; done ) & BG=$!
	sleep 8
	dirty=$($MDADM -X "${M[0]}" 2>/dev/null | grep -o "[0-9]* dirty")
	echo "  bitmap before the crash: $dirty"
	kill $BG; wait $BG 2>/dev/null
	crash c && verify 2 1
fi
teardown

# ---- L9: bitmap, the epoch held open ----------------------------------------------
CASE=L9; echo "== L9: bitmap 1 MiB chunks, the epoch held open"
members
if want L9 && create --bitmap=internal --bitmap-chunk=1M; then
	echo 1 > $SYS/bitmap/time_base 2>/dev/null
	gen 1; stopasm; echo 1 > $SYS/bitmap/time_base 2>/dev/null
	epoch_hold
	mark; gen 2; sleep 5	# md's daemon (1 s) clears an idle bit in ~2 s
	dirty=$($MDADM -X "${M[0]}" 2>/dev/null | grep -o "[0-9]* dirty"); n=${dirty%% *}
	[ "${n:-0}" -gt 0 ] && pass "L9 generation 2's bits held ($dirty)" ||
		fail "L9 bitmap clean while the CRCs are in the cache (${dirty:-?})"
	epoch_release	# as in L8
	crash c && verify 2 1
fi
teardown

# ---- L10: an image of a module that took no bitmap holds -------------------------
# What the modules of 2026-11-06/07 left after a crash: the array active, the
# bits of written chunks cleared, their CRCs in the cache only.  Made here
# by assembling with csum_test_no_hold=Y (no epochs, no holds) and a long
# safe_mode_delay (md does not mark it clean).  Started with
# csum_bitmap_resync=N the resync ignores the bitmap and re-derives every
# CRC.  The control starts the same image with Y: the bitmap-scoped resync
# skips those chunks and the stale CRCs surface (the field manual's upgrade
# note).
l10_image() {	# l10_image: leaves the copies assembled under csum_bitmap_resync=$1
	members
	create --bitmap=internal --bitmap-chunk=1M || return 1
	gen 1; echo Y > $P/csum_test_no_hold; stopasm || return 1
	echo 1 > $SYS/bitmap/time_base 2>/dev/null; echo 600 > $SYS/safe_mode_delay
	mark; gen 2; sleep 5	# bits clear in ~2 s; the CRCs stay in the cache
	dirty=$($MDADM -X "${M[0]}" 2>/dev/null | grep -o "[0-9]* dirty"); n=${dirty%% *}
	echo "  bitmap before the crash: ${dirty:-?}, array $(state)"
	[ "${n:-1}" = 0 ] && [ "$(state)" = active ] ||
		{ fail "L10 image not as wanted (${dirty:-?}, $(state))"; return 1; }
	echo N > $P/csum_test_no_hold; echo $1 > $P/csum_bitmap_resync
	crash c
}
CASE=L10; echo "== L10: a crash image without bitmap holds, started with csum_bitmap_resync=N"
if want L10 && [ "$NEG" != 1 ] && [ -w $P/csum_bitmap_resync ]; then
	if l10_image N; then
		pass "L10 image: active, bitmap clean, CRCs in the cache only"
		dmesg | sed -n "/$MK/,\$p" | grep -q "ignores the bitmap (csum_bitmap_resync=N)" &&
			pass "L10 the resync ignores the bitmap" ||
			fail "L10 no 'ignores the bitmap' message"
		verify 2 1
	fi
	teardown
	echo "  L10 control: the same image with csum_bitmap_resync=Y"
	if l10_image Y; then
		idle
		dd if=$MD of=$RK_DIR/rb bs=1M count=$GENMB iflag=direct status=none 2>/dev/null
		n=$(mm)
		[ "${n:-0}" -gt 0 ] || [ "$(bb)" -gt 0 ] &&
			pass "L10 control: with Y the stale CRCs surface ($n mismatch(es), $(bb) bad-block range(s))" ||
			fail "L10 control: with Y no stale CRC surfaced (the image tests nothing)"
	fi
	echo Y > $P/csum_bitmap_resync
fi
teardown

# ---- L4: array_state / safe_mode_delay writes ------------------------------------
CASE=L4; echo "== L4: clean / safe_mode_delay writes"
members
if want L4 && create --bitmap=none; then
	gen 1; stopasm
	epoch_hold 4000
	mark; gen 2
	echo clean > $SYS/array_state 2>/dev/null &&
		[ "$(state)" = clean ] && fail "L4 array_state clean accepted" ||
		pass "L4 array_state clean refused ($(state))"
	echo 0.001 > $SYS/safe_mode_delay; sleep 1
	[ "$(state)" = active ] && pass "L4 still active with safe_mode_delay 0.001" ||
		fail "L4 array_state $(state) with safe_mode_delay 0.001"
	# the epoch's pass at its ceiling (4 s after it opened; no store
	# since): md marks the array clean after it
	t=0; while [ "$(state)" != clean ] && [ $t -lt 60 ]; do sleep 0.1; t=$((t + 1)); done
	[ "$(state)" = clean ] && pass "L4 clean after the pass at the ceiling (+$((t * 100)) ms)" ||
		fail "L4 array_state $(state) 6 s after the checks"
	epoch_release
	echo 0.200 > $SYS/safe_mode_delay
	crash c && verify 2 0
fi
teardown

# ---- L5: --readonly --------------------------------------------------------------
CASE=L5; echo "== L5: mdadm --readonly"
members
if want L5 && create --bitmap=none; then
	gen 1; stopasm
	mark; gen 2
	# md refuses while another opener (udev's probe after the writes)
	# holds the array: settle, retry
	ro=0
	for t in 1 2 3 4 5; do
		udevadm settle 2>/dev/null
		$MDADM --readonly $MD >$RK_DIR/ro.out 2>&1 && { ro=1; break; }
		sleep 1
	done
	[ $ro = 1 ] || fail "L5 --readonly: $(tail -1 $RK_DIR/ro.out)"
	echo "  array_state $(state)"
	crash c && verify 2 0
fi
teardown

# ---- L6: second crash during the resync -------------------------------------------
CASE=L6; echo "== L6: crash during the post-crash resync"
members
if want L6 && [ "$NEG" != 1 ] && create --bitmap=none; then
	gen 1; stopasm
	epoch_hold
	mark; gen 2; sleep 1
	# the crash image read-only (its resync waits), the resync capped half
	# way (sync_max, a whole number of chunks), then read-write: md
	# checkpoints the resync on the way to the cap
	epoch_release	# as in L8
	if crash c --readonly; then
		cs=$(( CHUNK * 2 ))		# chunk sectors; sync_max is in sectors
		half=$(( $(cat $SYS/component_size) / cs * cs ))
		echo $half > $SYS/sync_max || fail "L6 sync_max $half"
		$MDADM --readwrite $MD || fail "L6 --readwrite"
		t=0
		while [ $t -lt 240 ]; do
			sc=$(cat $SYS/sync_completed); a=${sc%% /*}
			[[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge "$half" ] && break
			sleep 0.5; t=$((t + 1))
		done
		sleep 1		# the checkpoint's superblock write
		echo "  sync_completed at the second crash: $(cat $SYS/sync_completed) (sync_max $half)"
		sc=$(cat $SYS/sync_completed); a=${sc%% /*}; b=${sc##*/ }
		[[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge "$half" ] && [ "$a" -lt "$b" ] ||
			fail "L6 resync not held near sync_max ($sc)"
		# the superblock carries the checkpoint only while the array is
		# clean (md writes resync offset 0 for an active one)
		st=$(state); rs=$(cat $SYS/resync_start)
		[ "$st" = clean ] && [[ "$rs" =~ ^[0-9]+$ ]] && [ "$rs" -ge $(( half * 9 / 10 )) ] &&
			pass "L6 the checkpoint is on disk (clean, resync_start $rs)" ||
			fail "L6 no checkpoint on disk (array_state $st, resync_start $rs, sync_max $half)"
		mark	# the second image's own resync, not the first one's
		crash d && verify 2 1
	fi
fi
teardown

# ---- L7: blocks cached before the resync reaches them --------------------------------
CASE=L7; echo "== L7: blocks read (cached) ahead of the resync"
members
if want L7 && [ "$NEG" != 1 ] && create --bitmap=none; then
	gen 1; stopasm
	epoch_hold
	mark; gen 2; sleep 1
	epoch_release	# as in L8
	if crash c --readonly; then
		echo 4096 > $SYS/stripe_cache_size
		echo $(( CHUNK * 2 )) > $SYS/sync_max || fail "L7 sync_max"	# one chunk, in sectors
		$MDADM --readwrite $MD || fail "L7 --readwrite"
		t=0
		while [ $t -lt 120 ]; do
			sc=$(cat $SYS/sync_completed); a=${sc%% /*}
			[[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge $(( CHUNK * 2 )) ] && break
			sleep 0.5; t=$((t + 1))
		done
		# 64 blocks of generation 2 well past the resync (array 6 MiB =
		# member ~1.5 MiB): a 512-byte read of each goes through the
		# stripe cache (a sub-block read takes no bypass on a csum
		# array), which reads the whole block and keeps it; verify is
		# skipped (the resync window)
		echo "  resync held at: $(cat $SYS/sync_completed)"
		for b in $(seq 1536 1599); do
			dd if=$MD of=/dev/null bs=512 skip=$(( b * 8 )) count=1 iflag=direct status=none ||
				{ fail "L7 read ahead of the resync"; break; }
		done
		echo max > $SYS/sync_max
		verify 2 1
	fi
fi
teardown

echo "==== raidkm-test-csum-crashlag.sh: $PASS passed, $FAIL failed ===="
if [ "$NEG" = 1 ]; then
	hit=" ${NEGHIT[*]:-} " need=${CL_ONLY:-L1 L4 L5 L9} miss=
	for c in $need; do [[ "$hit" == *" $c "* ]] || miss+=" $c"; done
	if [ -z "$miss" ]; then
		echo "NEG control: failed as expected (cases:$(printf ' %s' $(printf '%s\n' "${NEGHIT[@]}" | sort -u)))"
		exit 0
	fi
	echo "NEG control: did not fail:$miss"
	exit 1
fi
[ $FAIL = 0 ]
