#!/bin/bash
# raidkm-test-csum-thrash.sh — P3 demand-paged native-checksum region-page cache
# thrash.  The P3 cache replaced the old load-all-on-assemble / flush-all-on-stop
# xarray with a bounded LRU of 4 KiB region pages faulted in on demand, so RAM no
# longer scales with array size.  This test drives the array with a region
# footprint several times the cache ceiling so pages are continuously faulted in,
# evicted, written back under pressure, and re-faulted from the on-disk region --
# exactly the paths that did not exist in the load/flush model.
#
# It proves both directions of the CRC round-trip through eviction:
#   (T1) NO false positive — a large write+verify workload whose CRC pages are
#        repeatedly evicted+reloaded logs no "native csum mismatch" and does not
#        bump healed_blocks: a reloaded CRC is never WRONG (rules out corruption
#        of the CRC across writeback/reload).
#   (T2) data integrity — fio --verify is clean under the churn.
#   (T3) NO false negative — a REAL silent corruption of a block whose CRC page
#        was evicted mid-operation is still detected and healed from parity after
#        the page is re-faulted from the region (rules out LOSS of the CRC).
#   (T4) a mixed random read/write churn under the tiny cache stays clean, and a
#        final scrub reports mismatch==0, with no WARN/BUG/KASAN in dmesg.
#   (T5) ZERO_MARK escape — a block whose GENUINE CRC-32C is 0xffffffff (the
#        slot encoding's crc-0 marker) must read back clean, repeatedly and
#        across a stop/re-assemble.  Pre-fold kernels stored it as the raw
#        marker, decoded expected-0, and heal-looped on every read.
#
# Disk-backed native checksum only (the region is where pages page to/from).
#
#   sudo NATIVE=1 bash tools/raidkm-test-csum-thrash.sh
#
# Extra config (beyond raidkm-test-lib.sh):
#   NDISK        members                                  (default 8)
#   M            parity count                             (default 2, parity-last)
#   CACHE_PAGES  raidkm_csum_cache_pages (floors to 64)   (default 8 -> 64 in-kernel)
#   THRASH_MIB   data written across the array            (default 768)
#   THRASH_SECS  duration of the random-rw churn phase    (default 60)
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

NDISK="${NDISK:-8}"
M="${M:-2}"
CACHE_PAGES="${CACHE_PAGES:-8}"                  # < 64 -> kernel floors to 64 pages
THRASH_MIB="${THRASH_MIB:-768}"                  # >> cache coverage (64 pg ~= 256 MiB)
THRASH_SECS="${THRASH_SECS:-60}"
BLK=4096
: "${BRD_NR:=$NDISK}" ; export BRD_NR
: "${BRD_SIZE_KB:=262144}" ; export BRD_SIZE_KB  # 256 MiB members
NATIVE="${NATIVE:-1}"                            # disk-backed region only

MEMBERS=()

cleanup() { rk_stop; }
trap cleanup EXIT

healed() { cat "/sys/block/$MDNAME/md/healed_blocks" 2>/dev/null || echo 0; }
# True iff NO native-csum mismatch has been logged since the last rk_dmesg_clear.
no_mismatch() { ! sudo dmesg 2>/dev/null | grep -qiE 'native csum mismatch'; }

if [ "$NATIVE" != 1 ]; then
	echo "ERROR: this test is disk-backed native-checksum only; run with NATIVE=1" >&2
	exit 1
fi

rk_load_modules || exit 1
grep -qa integrity "$MDADM" || { echo "ERROR: this mdadm lacks --integrity (rebuild the fork)" >&2; exit 1; }

# Shrink the region-page cache BEFORE --create: the ceiling is latched into the
# per-array cache at setup_conf time, so the param must be set first.
if [ -w /sys/module/raidkm/parameters/raidkm_csum_cache_pages ]; then
	echo "$CACHE_PAGES" | sudo tee /sys/module/raidkm/parameters/raidkm_csum_cache_pages >/dev/null
	eff=$(cat /sys/module/raidkm/parameters/raidkm_csum_cache_pages)
	rk_log "raidkm_csum_cache_pages set to $eff (kernel floors to 64); array footprint ~${THRASH_MIB} MiB >> cache"
else
	echo "ERROR: raidkm_csum_cache_pages param not present — is this a P3 build?" >&2
	exit 1
fi

export RK_CREATE_EXTRA="--integrity=crc32c"

rk_setup_brd "$NDISK" || exit 1
DISKS=$(rk_pick_disks "$NDISK") || { echo "ERROR: need $NDISK ramdisks" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"
rk_log "native thrash stack: $NDISK raw members [$DISKS], m=$M parity-last"

if ! rk_create "$M" "${MEMBERS[@]}"; then
	rk_fail "create raidkm m=$M over [$DISKS] failed"; rk_summary; exit 1
fi
rk_wait_full

# ---- T1 + T2: write + verify the full span (>> cache) ---------------------
# fio writes the whole span (storing a CRC per block, evicting pages to the
# region under the tiny ceiling) then verifies it (re-faulting every CRC page
# back from the region).  A broken round-trip that CORRUPTED a CRC would fire a
# native-csum mismatch on read and heal a block that was never really corrupt.
rk_dmesg_clear
h0=$(healed)
if sudo fio --name=thrash-wv --filename="$MD" --direct=1 --bs="$BLK" \
	--rw=write --size="${THRASH_MIB}M" --ioengine=libaio --iodepth=16 \
	--verify=crc32c --do_verify=1 --verify_fatal=1 \
	--group_reporting --output="$RK_TMP/fio-wv.log" >/dev/null 2>&1; then
	rk_pass "T2: fio write+verify clean under cache thrash (${THRASH_MIB} MiB, cache=64 pg)"
else
	rk_fail "T2: fio write+verify FAILED under thrash (data integrity) — see $RK_TMP/fio-wv.log"
	tail -5 "$RK_TMP/fio-wv.log" 2>/dev/null | sed 's/^/      · /'
fi
h1=$(healed)
if no_mismatch && [ "$h1" = "$h0" ]; then
	rk_pass "T1: no false csum mismatch / no spurious heal across evict+reload ($h0->$h1)"
else
	rk_fail "T1: spurious csum activity on a clean array (healed $h0->$h1) — CRC corrupted across round-trip"
	sudo dmesg 2>/dev/null | grep -iE 'native csum mismatch' | tail -4 | sed 's/^/      · /'
fi
rk_dmesg_clean || rk_fail "T1/T2: WARN/BUG in dmesg after write+verify thrash"

# ---- T4: mixed random read/write churn under the tiny cache ----------------
# 4 jobs of random 4 KiB rw over the full span keep faults, evictions, and
# writebacks racing; --verify guards data integrity throughout.
rk_dmesg_clear
if sudo fio --name=thrash-rw --filename="$MD" --direct=1 --bs="$BLK" \
	--rw=randrw --rwmixread=50 --size="${THRASH_MIB}M" --ioengine=libaio \
	--iodepth=16 --numjobs=4 --time_based --runtime="${THRASH_SECS}" \
	--verify=crc32c --verify_backlog=512 --verify_fatal=1 \
	--group_reporting --output="$RK_TMP/fio-rw.log" >/dev/null 2>&1; then
	rk_pass "T4: ${THRASH_SECS}s random-rw churn clean (4 jobs, verify=crc32c)"
else
	rk_fail "T4: random-rw churn FAILED — see $RK_TMP/fio-rw.log"
	tail -5 "$RK_TMP/fio-rw.log" 2>/dev/null | sed 's/^/      · /'
fi
rk_dmesg_clean || rk_fail "T4: WARN/BUG in dmesg during random-rw churn"

# ---- T3: real heal through the region round-trip ---------------------------
# After thrashing the tiny cache, stop the array (flushing every dirty region
# page) and re-assemble it (empty CRC cache).  Array block 0's CRC now lives ONLY
# in the on-disk region.  Silently corrupt block 0's data (parity-last -> data
# slot 0 -> member 0 at data_offset), then read block 0 as the FIRST array read
# since assembly -- a cold read, so md re-fetches the block from the corrupt
# member instead of serving a warm stripe (a plain drop_caches would NOT evict a
# warm md stripe).  md must reload the CRC from the region, detect the mismatch,
# and heal from parity.  Proves the thrash's writebacks persisted CRCs and the
# reload detects real corruption (the LOSS direction, complementing T1).
member0="${MEMBERS[0]}"
do_s=$(sudo "$MDADM" --examine "$member0" 2>/dev/null | \
       sed -n 's/.*Data Offset : \([0-9]*\) sectors.*/\1/p')
rk_stop
if [ -z "$do_s" ]; then
	rk_fail "T3: could not read Data Offset from $member0 --examine"
else
	# With the array STOPPED, capture block 0's good bytes and then silently
	# corrupt them on member 0's backing (parity-last -> data slot 0).  Corrupting
	# while stopped and assembling AFTERWARDS guarantees the first array read of
	# block 0 is genuinely cold -- md must re-read the corrupt member (a warm
	# stripe from any earlier read would be served without re-verifying, and a
	# plain drop_caches does not evict md's stripe cache).
	sudo dd if="$member0" of="$RK_TMP/blk0.good" bs=512 skip="$do_s" count=8 \
		iflag=direct status=none 2>/dev/null
	sudo dd if=/dev/urandom of="$member0" bs=512 seek="$do_s" count=8 \
		conv=notrunc status=none 2>/dev/null
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
	rk_dmesg_clear
	if ! rk_assemble "${MEMBERS[@]}"; then
		rk_fail "T3: re-assemble after thrash failed"
	else
		th0=$(healed)
		# cold read: md re-fetches block 0 from the corrupt member, reloads the
		# CRC from the region, detects the mismatch, and heals from parity.
		sudo dd if="$MD" of="$RK_TMP/blk0.rd" bs="$BLK" count=1 iflag=direct status=none 2>/dev/null
		th1=$(healed)
		data_ok=no; cmp -s "$RK_TMP/blk0.good" "$RK_TMP/blk0.rd" && data_ok=yes
		detected=no; ! no_mismatch && detected=yes
		if [ "$data_ok" = yes ] && [ "$detected" = yes ]; then
			rk_pass "T3: real corruption detected + healed after CRC re-faulted from region post-thrash"
		else
			rk_fail "T3: region round-trip heal failed (data_ok=$data_ok detected=$detected)"
			sudo dmesg 2>/dev/null | grep -iE 'native csum|read error|corrected' | tail -6 | sed 's/^/      · /'
		fi
		[ "$th1" -gt "$th0" ] \
			&& rk_log "T3: healed_blocks counted the heal ($th0->$th1)" \
			|| rk_log "T3: healed_blocks $th0->$th1 (best-effort; detection+data are the assertion)"
		rk_dmesg_clean || rk_fail "T3: WARN/BUG in dmesg after region-round-trip heal"
	fi
fi

# ---- T5: ZERO_MARK alias block (genuine CRC == 0xffffffff) ------------------
# 4092 zero bytes + 54 64 1f 64 is a 4 KiB block whose CRC-32C is exactly
# 0xffffffff (zeros leave the CRC register at 0; the 4-byte tail forces the
# target — cross-checked against two independent CRC-32C implementations).
# Unescaped, the store collides with the slot encoding's crc-0 marker and the
# block false-mismatches + heals on EVERY read, forever.  With the fold, both
# sides canonicalise to 0xfffffffe and the block is just a block.
if [ ! -b "$MD" ]; then
	rk_fail "T5: array not assembled (T3 wreckage?) — skipping alias test"
else
	alias_blk="$RK_TMP/alias.blk"
	head -c 4092 /dev/zero > "$alias_blk"
	printf '\x54\x64\x1f\x64' >> "$alias_blk"
	OFFB=$((1024 * 1024 / BLK))		# 1 MiB in, clear of T3's block 0
	rk_dmesg_clear
	a0=$(healed)
	sudo dd if="$alias_blk" of="$MD" bs="$BLK" seek="$OFFB" count=1 \
		oflag=direct conv=notrunc status=none 2>/dev/null
	# Repeated O_DIRECT reads each re-verify via the bypass path (no stripe
	# cache to hide behind); pre-fold every one of these heals.
	t5_ok=yes
	for i in 1 2 3 4; do
		sudo dd if="$MD" of="$RK_TMP/alias.rd" bs="$BLK" skip="$OFFB" count=1 \
			iflag=direct status=none 2>/dev/null
		cmp -s "$alias_blk" "$RK_TMP/alias.rd" || t5_ok=no
	done
	a1=$(healed)
	if [ "$t5_ok" = yes ] && no_mismatch && [ "$a1" = "$a0" ]; then
		rk_pass "T5: CRC==0xffffffff alias block reads clean 4x (no mismatch, healed $a0->$a1)"
	else
		rk_fail "T5: alias block misbehaved (data_ok=$t5_ok healed $a0->$a1) — ZERO_MARK escape broken"
		sudo dmesg 2>/dev/null | grep -iE 'native csum mismatch' | tail -4 | sed 's/^/      · /'
	fi
	# Persistence: the folded slot must round-trip through the on-disk region.
	rk_stop
	rk_dmesg_clear
	if ! rk_assemble "${MEMBERS[@]}"; then
		rk_fail "T5: re-assemble for alias persistence check failed"
	else
		a2=$(healed)
		sudo dd if="$MD" of="$RK_TMP/alias.rd2" bs="$BLK" skip="$OFFB" count=1 \
			iflag=direct status=none 2>/dev/null
		a3=$(healed)
		if cmp -s "$alias_blk" "$RK_TMP/alias.rd2" && no_mismatch && [ "$a3" = "$a2" ]; then
			rk_pass "T5: alias block clean after stop/re-assemble (slot persisted folded)"
		else
			rk_fail "T5: alias block dirty after re-assemble (healed $a2->$a3)"
			sudo dmesg 2>/dev/null | grep -iE 'native csum mismatch' | tail -4 | sed 's/^/      · /'
		fi
	fi
	rk_dmesg_clean || rk_fail "T5: WARN/BUG in dmesg during alias-block test"
fi

# ---- T4 (cont.): final scrub must be clean ---------------------------------
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "T4: final scrub clean (mismatch=0) after thrash" \
	     || rk_fail "T4: final scrub mismatch=$mm after thrash (expected 0)"

rk_stop
rk_summary
