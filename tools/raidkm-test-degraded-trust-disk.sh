#!/bin/bash
# raidkm-test-degraded-trust-disk.sh — a readable block is read, not decoded.
#
# fetch_block used to reconstruct EVERY uncached data slot of a stripe from
# parity as soon as k slots were cached, including slots that are perfectly
# readable from an in-sync member.  fetch_block walks the slots downwards, so
# the uncached healthy slots BELOW a failed slot could be reached only after
# the failed slot's decode had been scheduled with them as extra targets --
# decoded from parity instead of read from disk.  While parity is right that
# gives the same bytes; where it is not (--assume-clean, ahead of resync, a
# silently corrupt parity block) a healthy neighbour would come back as
# garbage and be cached as UPTODATE.  Stock raid5/6 reads the healthy blocks
# and computes only the failed one, and raidkm now does the same.
#
# This test pins that contract on arrays whose parity is deliberately wrong.
# It passed before the change too: the write and read paths that were tried
# gather what they need before the compute fires, so no corruption was ever
# reproduced from the old behaviour -- the change is a hardening, and this
# test keeps the read path from regressing into trusting parity for a
# readable block.
#
# The sequence that triggers it, per stripe (k=4 m=2 parity-last, member 2
# failed = data slot 2; slot 0 stays uncached and below it):
#   1. 4 KiB RMW writes into slots 1 and 3  -> cache holds 1, 3, P, Q = k slots
#   2. 4 KiB write into failed slot 2       -> slot 2 must be reconstructed;
#      old code also decodes slot 0 from P/Q, new code leaves it to be read
#   3. evict the stripe cache, read slot 2 back -> decoded from slot 0 +
#      parity: right only if that parity was computed from slot 0's real
#      contents
#
# What this proves:
#   T1  --assume-clean over random-filled members (parity wrong everywhere):
#       every written 4 KiB on the failed slot reads back intact
#   T2  same sequence on a resynced array whose Q member was overwritten with
#       garbage after the fact: intact (one failure decodes with P; the
#       corrupt Q must not leak in through a decoded neighbour)
#   T3  no kernel report throughout
#
# Usage: bash <this>     (geometry via RC_N; see raidkm-test-lib.sh)
set -u
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${RC_N:-6}
M=2
K=$((N - M))
NSTRIPES=${NSTRIPES:-32}
FAILED_SLOT=${FAILED_SLOT:-2}		# data slot (= member index, parity-last)
MEMBERS=()

cleanup() {
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	local d
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
}
trap cleanup EXIT

[ "$FAILED_SLOT" -ge 1 ] && [ "$FAILED_SLOT" -lt "$K" ] || { echo "ERROR: FAILED_SLOT must be 1..$((K - 1))" >&2; exit 1; }

# 4 KiB block index of the first block of <stripe> <slot> on the array
blk() { echo $(( ($1 * K + $2) * CHUNK_KB / 4 )); }
wr4k() {	# wr4k <stripe> <slot> <srcfile>
	sudo dd if="$3" of="$MD" bs=4k count=1 seek="$(blk "$1" "$2")" oflag=direct conv=notrunc status=none
}
rd4k() {	# rd4k <stripe> <slot> <dstfile>
	sudo dd if="$MD" of="$3" bs=4k count=1 skip="$(blk "$1" "$2")" iflag=direct status=none
}

# garbage_fill <dev...> : random contents, so parity assumed clean is wrong
garbage_fill() {
	local d
	for d in "$@"; do
		sudo dd if=/dev/urandom of="$d" bs=1M status=none 2>/dev/null || true
	done
}

# run_sequence <tag> : the trigger sequence over NSTRIPES stripes, then a
# cold read-back of every block written to the failed slot
run_sequence() {
	local tag=$1 s bad=0 lower=$(( FAILED_SLOT - 1 )) upper=$(( FAILED_SLOT + 1 ))
	[ "$upper" -ge "$K" ] && upper=$lower
	sudo dd if=/dev/urandom of="$RK_TMP/a" bs=4k count=1 status=none
	for s in $(seq 0 $((NSTRIPES - 1))); do
		sudo dd if=/dev/urandom of="$RK_TMP/b$s" bs=4k count=1 status=none
		wr4k "$s" "$lower" "$RK_TMP/a"
		wr4k "$s" "$upper" "$RK_TMP/a"
		wr4k "$s" "$FAILED_SLOT" "$RK_TMP/b$s"
	done
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	# drop_caches leaves the stripe cache alone, and the stripes still hold
	# the written slot UPTODATE; evict them so the read-back really decodes
	local scs; scs=$(cat "/sys/block/$MDNAME/md/stripe_cache_size")
	echo 17 | sudo tee "/sys/block/$MDNAME/md/stripe_cache_size" >/dev/null || rk_log "(stripe cache shrink refused)"; sleep 1
	echo "$scs" | sudo tee "/sys/block/$MDNAME/md/stripe_cache_size" >/dev/null
	for s in $(seq 0 $((NSTRIPES - 1))); do
		rd4k "$s" "$FAILED_SLOT" "$RK_TMP/r"
		cmp -s "$RK_TMP/r" "$RK_TMP/b$s" || bad=$((bad + 1))
	done
	if [ "$bad" = 0 ]; then
		rk_pass "$tag all $NSTRIPES blocks written to failed slot $FAILED_SLOT read back intact"
	else
		rk_fail "$tag $bad of $NSTRIPES blocks written to failed slot $FAILED_SLOT read back WRONG"
	fi
}

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
rk_setup_brd "$N" || exit 1
DISKS=$(rk_pick_disks "$N") || { echo "ERROR: need $N devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

echo "== a readable block is read, not decoded (k=$K m=$M parity-last, slot $FAILED_SLOT failed)"

# ---- T1: parity never valid (--assume-clean over garbage) -------------------
garbage_fill "${MEMBERS[@]}"
RK_CREATE_EXTRA="--assume-clean" rk_create $M "${MEMBERS[@]}" || { rk_fail "T1 create"; rk_summary; exit 1; }
rk_dmesg_clear
# skip_copy borrows the write bio's page, so a written slot is not left
# UPTODATE in the cache; the early-compute window only opens with a copy
echo "${RK_SKIP_COPY:-0}" | sudo tee "/sys/block/$MDNAME/md/skip_copy" >/dev/null
rk_fail_disks "${MEMBERS[$FAILED_SLOT]}"
if [ "$(rk_geom)" = "[$N/$((N - 1))]" ]; then
	run_sequence "T1 (assume-clean, garbage parity):"
else
	rk_fail "T1 array not degraded as expected: $(rk_geom)"
fi
rk_dmesg_clean && rk_pass "T1 no kernel report" || rk_fail "T1 kernel report"

# ---- T2: valid parity, then Q silently corrupted -------------------------------
rk_stop
for d in "${MEMBERS[@]}"; do sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
rk_create $M "${MEMBERS[@]}" || { rk_fail "T2 create"; rk_summary; exit 1; }
rk_write 8
QDEV=${MEMBERS[$((N - 1))]}
QOFF=$(rk_data_offset "$QDEV")
sudo dd if=/dev/urandom of="$QDEV" bs=512 seek="${QOFF:-0}" status=none 2>/dev/null || true
rk_dmesg_clear
echo "${RK_SKIP_COPY:-0}" | sudo tee "/sys/block/$MDNAME/md/skip_copy" >/dev/null
rk_fail_disks "${MEMBERS[$FAILED_SLOT]}"
run_sequence "T2 (corrupt Q):"
rk_dmesg_clean && rk_pass "T2 no kernel report" || rk_fail "T2 kernel report"

rk_summary
