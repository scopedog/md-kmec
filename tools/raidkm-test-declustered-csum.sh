#!/bin/bash
#
# raidkm-test-declustered-csum.sh — declustered + native checksum gate.
#
# On the pinned N=14 pool (2 groups of g=6 = 4+2, s=2, seed 0x10), created
# WITH --checksum (layout carries DCL|CSUM; the member tail stacks
# [rkdcl chunk][CRC region]):
#   1. create + activate; --examine shows BOTH declustered geometry and the
#      crc32c checksum line; initial resync clean.
#   2. baseline pattern chunks at known permutation positions (sim vec
#      oracle) + full-array fio-style write, all read back exactly.
#   3. HEAL, healthy array: corrupt one 4 KiB block RAW on the member that
#      holds a pinned chunk -> a read through the array returns the ORIGINAL
#      bytes (csum mismatch -> reconstruct from group peers), dmesg names the
#      corrupted PHYSICAL disk, the raw block is rewritten (healed), and a
#      scrub is clean.
#   4. PERSISTENCE: clean stop + re-assemble, corrupt another block raw ->
#      detect + heal again.  Proves the CRC region round-trips from its
#      dcl-shifted on-disk offset (one chunk past dev_sectors).
#   5. POPULATION with csum: fail the victim, arm population (sysfs), wait
#      populated; victim chunks read exactly through the spare redirect; then
#      corrupt the SPARE-hosted copy raw on the spare-column disk -> read
#      heals and dmesg names the SPARE disk index (CRCs are keyed by
#      PHYSICAL disk, not slot).
#   6. --add replacement: with csum the copy-from-spare fast path is
#      REFUSED (raw copy would bypass CRC stores) -> retire + decode-rebuild
#      leg runs, degraded returns to 0, content intact, final scrub clean.
#   7. no kernel WARN/BUG across every dmesg window.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SIM_SRC="$RK_TREE/tools/declustered-sim.c"
SIM="$RK_TMP/declustered-sim"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}
SEED=${DCL_SEED:-0x10}
CS=$((CHUNK_KB * 2))		# chunk in sectors
NVEC=4096
NROWS=512
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

cc -O2 -o "$SIM" "$SIM_SRC" -lm || {
	echo "ERROR: cannot build $SIM_SRC" >&2; exit 1; }
"$SIM" -N $N -g $G -m $M -s $SC -b $NBASE -S $SEED -T 1 \
	--vectors "$RK_TMP/vec.tsv" --nvec $NVEC \
	--rowmap "$RK_TMP/rowmap.tsv" --nrows $NROWS > /dev/null || {
	echo "ERROR: simulator failed" >&2; exit 1; }

# victim F = the member holding logical chunk 0; its on-F oracle chunks
F=$(awk '$1 !~ /^#/ && $1 == 0 {print $6}' "$RK_TMP/vec.tsv")
FDEV="${MEMBERS[$F]}"
# row >= 1 everywhere ($2 is the row): row-0 stripes cover the array head,
# which udev/blkid re-probe on every array event — a background probe
# re-caches those stripes CLEAN and the corrupt-then-read oracle then never
# touches the disk (observed: lc=1/row=0 heal test false-failed exactly so).
read -r -a FLCS <<< "$(awk -v F="$F" '$1 !~ /^#/ && $6 == F && $2 >= 1 && $1 < 2048 && !seen[$5]++ {print $1}' \
	"$RK_TMP/vec.tsv" | head -4 | tr '\n' ' ')"
[ "${#FLCS[@]}" -ge 2 ] || { echo "ERROR: too few on-F vectors" >&2; exit 1; }
# a healthy-heal chunk on a member OTHER than F (steps 3/4 corrupt it live)
HLC=$(awk -v F="$F" '$1 !~ /^#/ && $6 != F && $2 >= 1 && $1 < 2048 {print $1; exit}' "$RK_TMP/vec.tsv")
HD=$(awk -v lc="$HLC" '$1 !~ /^#/ && $1 == lc {print $6}' "$RK_TMP/vec.tsv")
H2LC=$(awk -v F="$F" -v h="$HLC" '$1 !~ /^#/ && $6 != F && $1 != h && $2 >= 1 && $1 < 2048 {print $1; exit}' "$RK_TMP/vec.tsv")
H2D=$(awk -v lc="$H2LC" '$1 !~ /^#/ && $1 == lc {print $6}' "$RK_TMP/vec.tsv")
lc_row()      { awk -v lc="$1" '$1 !~ /^#/ && $1 == lc {print $2}' "$RK_TMP/vec.tsv"; }
spare0_disk() { awk -v r="$1" '$1 !~ /^#/ && $1 == r && $4 == "S0" {print $3}' "$RK_TMP/rowmap.tsv"; }

# Evict the md stripe cache: a stripe still cached clean from the baseline
# write serves reads WITHOUT touching the disk (O_DIRECT bypasses the page
# cache, not the stripe cache), hiding raw corruption from the verify.
# Same shrink-and-restore recipe as raidkm-test-selfheal.sh si_repair.
evict_stripes() {
	local scs
	scs=$(cat "/sys/block/$MDNAME/md/stripe_cache_size" 2>/dev/null)
	echo 17 | sudo tee "/sys/block/$MDNAME/md/stripe_cache_size" >/dev/null 2>&1
	[ -n "$scs" ] && echo "$scs" | sudo tee "/sys/block/$MDNAME/md/stripe_cache_size" >/dev/null 2>&1
}
# corrupt_raw <memberdev> <row> : overwrite the first 4K of that row's chunk.
# Opens a fresh dmesg window so the following heal_read's attribution grep
# can't match a stale line from an earlier corruption.
corrupt_raw() {
	local dev="$1" row="$2" do_s off
	rk_dmesg_window_close
	rk_dmesg_clear
	do_s=$(rk_data_offset "$dev")
	off=$(( (do_s + row * CS) * 512 ))
	# direct I/O both ways: the member's bdev page cache would otherwise
	# serve stale bytes (md's bio writes don't invalidate it)
	sudo dd if=/dev/urandom of="$dev" bs=4096 count=1 \
		seek=$((off / 4096)) conv=notrunc oflag=direct status=none 2>/dev/null
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	evict_stripes
}
# raw_healed <memberdev> <row> <patfile> : retry-loop until the raw first-4K
# matches the pattern again (the heal rewrite is asynchronous)
raw_healed() {
	local dev="$1" row="$2" pat="$3" do_s off i
	do_s=$(rk_data_offset "$dev")
	off=$(( (do_s + row * CS) * 512 ))
	for i in $(seq 1 40); do
		sync
		sudo dd if="$dev" bs=4096 count=1 skip=$((off / 4096)) \
			of="$RK_TMP/rawblk" iflag=direct status=none 2>/dev/null
		cmp -s -n 4096 "$RK_TMP/rawblk" "$pat" && return 0
		sleep 0.5
	done
	return 1
}
# heal_read <lc> <patfile> <expect_disk> <tag> : read the chunk through the
# array; PASS iff bytes are exact AND dmesg reports the mismatch on the
# expected PHYSICAL disk.
heal_read() {
	local lc="$1" pat="$2" xdisk="$3" tag="$4" got
	rk_rdchunk "$lc" "$RK_TMP/heal$lc"
	if ! cmp -s "$RK_TMP/heal$lc" "$pat"; then
		rk_fail "$tag: read-through returned corrupt bytes (lc=$lc)"
		return 1
	fi
	got=$(sudo dmesg | sed -n 's/.*native csum mismatch disk \([0-9]*\) .*/\1/p' | tail -1)
	if [ "$got" != "$xdisk" ]; then
		rk_fail "$tag: mismatch attributed to disk '$got', expected physical disk $xdisk"
		return 1
	fi
	rk_pass "$tag: corrupt block detected on physical disk $xdisk, healed bytes exact"
}

# ---- 1. create with --checksum -------------------------------------------------
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M status=none 2>/dev/null || true
done
rk_dmesg_clear
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" --checksum \
	--raid-devices=$N "${MEMBERS[@]}" --run --force > /dev/null 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat ||
	{ rk_fail "create with --checksum failed"; rk_summary; exit 1; }
rk_wait_idle
ex=$(sudo "$MDADM" --examine "${MEMBERS[1]}" 2>/dev/null)
echo "$ex" | grep -q "declustered" && echo "$ex" | grep -q "crc32c" \
	&& rk_pass "examine shows declustered + crc32c checksum" \
	|| rk_fail "examine missing declustered/crc32c: $(echo "$ex" | grep -E 'Layout|Checksum')"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "created; initial resync + scrub clean" \
	      || rk_fail "initial scrub mismatch_cnt=$mm"

# ---- 2. baseline ---------------------------------------------------------------
for lc in "${FLCS[@]}" "$HLC" "$H2LC"; do
	rk_mkpat CSM "$lc"; rk_wrchunk "$RK_TMP/CSM$lc" "$lc"
done
sync
ok=1
for lc in "${FLCS[@]}" "$HLC" "$H2LC"; do
	rk_rdchunk "$lc" "$RK_TMP/rb$lc"
	cmp -s "$RK_TMP/CSM$lc" "$RK_TMP/rb$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "baseline pattern chunks read back exactly" \
	    || rk_fail "baseline mismatch at lc=$lc"

# ---- 3. corrupt + heal on the healthy array ------------------------------------
# The stop/re-assemble between corrupting and reading is NOT optional: a
# stripe cached clean from the baseline (or re-cached by background probes)
# serves reads without touching the disk, and stripe_cache_size shrink
# eviction proved unreliable for recently-touched stripes (observed live:
# reads kept returning cached bytes through shrink + LRU displacement).
# A fresh assemble guarantees the read faults the corrupt block from disk,
# and also exercises the CRC-region round-trip on the way.
row=$(lc_row "$HLC")
corrupt_raw "${MEMBERS[$HD]}" "$row"
sudo "$MDADM" --stop "$MD" > /dev/null 2>&1 || { rk_fail "stop failed"; rk_summary; exit 1; }
sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]}" > /dev/null 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat ||
	{ rk_fail "re-assemble failed"; rk_summary; exit 1; }
rk_wait_idle
heal_read "$HLC" "$RK_TMP/CSM$HLC" "$HD" "healthy-array heal"
raw_healed "${MEMBERS[$HD]}" "$row" "$RK_TMP/CSM$HLC" \
	&& rk_pass "corrupt raw block rewritten (healed) on disk $HD" \
	|| rk_fail "raw block not healed on disk $HD"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "scrub clean after heal" || rk_fail "post-heal scrub mismatch_cnt=$mm"

# ---- 4. CRC region persists across stop/re-assemble ----------------------------
rk_dmesg_window_close
sudo "$MDADM" --stop "$MD" > /dev/null 2>&1 || { rk_fail "clean stop failed"; rk_summary; exit 1; }
rk_dmesg_clear
sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]}" > /dev/null 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat ||
	{ rk_fail "re-assemble failed"; rk_summary; exit 1; }
rk_wait_idle
row=$(lc_row "$H2LC")
corrupt_raw "${MEMBERS[$H2D]}" "$row"
heal_read "$H2LC" "$RK_TMP/CSM$H2LC" "$H2D" "post-assemble heal (region round-trip)"

# ---- 5. population with csum + spare-copy heal ---------------------------------
rk_dmesg_window_close
rk_dmesg_clear
rk_fail_disks "$FDEV"
sudo "$MDADM" --remove "$MD" "$FDEV" > /dev/null 2>&1
if echo "$F" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1; then
	rk_pass "population armed for failed member $F"
else
	rk_fail "arming failed"; rk_summary; exit 1
fi
rk_unthrottle
if rk_wait_populated; then
	rk_pass "population COMPLETE with csum ($(rk_pop_show))"
else
	rk_fail "population stalled: $(rk_pop_show)"; rk_summary; exit 1
fi
ok=1
for lc in "${FLCS[@]}"; do
	rk_rdchunk "$lc" "$RK_TMP/pr$lc"
	cmp -s "$RK_TMP/CSM$lc" "$RK_TMP/pr$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "victim chunks exact through the spare redirect" \
	    || rk_fail "POPULATED read mismatch at lc=$lc"
# corrupt the spare-hosted copy raw; the heal must attribute the mismatch to
# the SPARE-COLUMN disk (physical keying) and decode the block back
plc="${FLCS[0]}"; prow=$(lc_row "$plc"); sd=$(spare0_disk "$prow")
corrupt_raw "${MEMBERS[$sd]}" "$prow"
heal_read "$plc" "$RK_TMP/CSM$plc" "$sd" "spare-hosted heal (physical-disk keying)"

# ---- 6. --add replacement takes the DECODE leg, not raw copy -------------------
rk_dmesg_window_close
rk_dmesg_clear
sudo "$MDADM" --zero-superblock "$FDEV" 2>/dev/null
sudo dd if=/dev/zero of="$FDEV" bs=1M status=none 2>/dev/null || true
rk_add_disks "$FDEV"
rk_wait_full
[ "$(cat "/sys/block/$MDNAME/md/degraded" 2>/dev/null)" = 0 ] \
	&& rk_pass "replacement rebuilt to degraded=0" \
	|| rk_fail "degraded=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null) after rebuild"
if sudo dmesg | grep -q "resuming copy of disk\|declustered: copy of disk"; then
	rk_fail "csum array took the raw copy-from-spare path (CRCs would be lost)"
else
	rk_pass "csum array took the retire+decode rebuild leg (no raw copy)"
fi
ok=1
for lc in "${FLCS[@]}" "$HLC" "$H2LC"; do
	rk_rdchunk "$lc" "$RK_TMP/fr$lc"
	cmp -s "$RK_TMP/CSM$lc" "$RK_TMP/fr$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "all content intact after rebalance" \
	    || rk_fail "post-rebalance mismatch at lc=$lc"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "final scrub clean (mismatch_cnt=0)" \
	      || rk_fail "final scrub mismatch_cnt=$mm"

# ---- 7. kernel health ----------------------------------------------------------
rk_dmesg_window_close
[ "${RK_DMESG_BAD:-0}" = 0 ] && rk_pass "no kernel WARN/BUG during the run (all windows)" \
			     || rk_fail "kernel WARN/BUG seen — check dmesg"

rk_summary
