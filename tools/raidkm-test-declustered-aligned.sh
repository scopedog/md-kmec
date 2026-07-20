#!/bin/bash
#
# raidkm-test-declustered-aligned.sh — chunk-aligned read BYPASS on declustered
# arrays (the last v1 read-path gate, lifted 2026-07-19).
#
# On the pinned N=14 pool (2 groups of g=6 = 4+2, s=2, seed 0x10; DCL_*
# env-overridable like the other dcl gates):
#   1. plain dcl array: create + initial resync clean; fio write+verify (its
#      verify reads already ride the bypass).
#   2. BYPASS-TAKEN PROBE: a large O_DIRECT sequential read with a concurrent
#      stripe_cache_active sampler — every sample must be 0 (aligned reads
#      served by raid5_read_one_chunk, no stripe ever activated).
#   3. content through the bypass: pattern chunks at permutation positions in
#      both groups and several rows read back exactly, plus sub-chunk reads at
#      odd in-chunk offsets (the device-sector offset math).
#   4. PLACEMENT PROOF by corruption visibility: corrupt one 4K block RAW on
#      the member+offset the simulator maps a chunk to (no csum -> nothing
#      may detect it); the bypass read must return EXACTLY those corrupt
#      bytes.  Only a read of the sim's (row, disk, offset) can see them.
#   5. PROBE CONTROL: fail a member (degraded -> bypass off); the same
#      sampler over the same read must now see stripe activity — proves the
#      step-2 probe could have detected stripe-path reads.  Degraded content
#      still exact (on-the-fly decode).
#   6. csum leg (fresh DCL|CSUM array): after a stop/re-assemble, clean
#      aligned reads verify against the region CRCs with ZERO mismatches and
#      zero stripe activity — CRCs are keyed by PHYSICAL disk; a slot-keyed
#      lookup would alias another member's CRC and bounce every read to the
#      stripe-cache recheck (nonzero samples / mismatch storm).
#   7. corrupt a block raw -> the bypass verify DETECTS it (dmesg attributes
#      the mismatch to the expected physical disk), the retry leg heals
#      through the stripe cache, bytes returned exact, raw block rewritten.
#   8. final scrub clean; no kernel WARN/BUG in any dmesg window.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SIM_SRC="$RK_TREE/tools/declustered-sim.c"
SIM="$RK_TMP/declustered-sim"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}
SEED=${DCL_SEED:-0x10}
CS=$((CHUNK_KB * 2))		# chunk in sectors
PROBE_MB=${PROBE_MB:-256}	# sequential-read size under the sampler
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
	--vectors "$RK_TMP/vec.tsv" --nvec 4096 > /dev/null || {
	echo "ERROR: simulator failed" >&2; exit 1; }

# oracle chunks: distinct (row, group) pairs, row >= 1 (row-0 stripes get
# re-cached by udev/blkid head probes — the csum gate's hard-won lesson)
NG=$(( (N - SC) / G )); K=$((G - M))
read -r -a LCS <<< "$(awk -v ng=$NG -v k=$K \
	'$1 !~ /^#/ && $2 >= 1 && $1 < 2048 {
		grp = int(($1 % (ng * k)) / k);
		if (!seen[$2 "-" grp]++) print $1 }' \
	"$RK_TMP/vec.tsv" | head -4 | tr '\n' ' ')"
[ "${#LCS[@]}" -ge 3 ] || { echo "ERROR: too few oracle vectors" >&2; exit 1; }
lc_row()  { awk -v lc="$1" '$1 !~ /^#/ && $1 == lc {print $2}' "$RK_TMP/vec.tsv"; }
lc_disk() { awk -v lc="$1" '$1 !~ /^#/ && $1 == lc {print $6}' "$RK_TMP/vec.tsv"; }

# ---- helpers -----------------------------------------------------------------

# probe_read: O_DIRECT sequential read of PROBE_MB from the array head while
# sampling stripe_cache_active; prints "<max> <nonzero-samples>/<samples>".
probe_read() {
	local max=0 nz=0 n=0 v
	rm -f "$RK_TMP/probe.done"
	( while [ ! -f "$RK_TMP/probe.done" ]; do
		cat "/sys/block/$MDNAME/md/stripe_cache_active" 2>/dev/null
		sleep 0.002
	  done ) > "$RK_TMP/probe.samples" &
	local pid=$!
	sudo dd if="$MD" of=/dev/null bs=1M count="$PROBE_MB" \
		iflag=direct status=none
	touch "$RK_TMP/probe.done"
	wait $pid 2>/dev/null
	while read -r v; do
		[ -z "$v" ] && continue
		n=$((n + 1))
		[ "$v" -gt 0 ] 2>/dev/null && { nz=$((nz + 1));
			[ "$v" -gt "$max" ] && max=$v; }
	done < "$RK_TMP/probe.samples"
	echo "$max $nz/$n"
}

# corrupt_raw <memberdev> <row>: overwrite the first 4K of that row's chunk
# with saved random bytes ($RK_TMP/junk); direct I/O both ways + cache drops
# (same recipe as the dcl csum gate).
corrupt_raw() {
	local dev="$1" row="$2" do_s off
	rk_dmesg_window_close
	rk_dmesg_clear
	sudo dd if=/dev/urandom of="$RK_TMP/junk" bs=4096 count=1 status=none
	do_s=$(rk_data_offset "$dev")
	off=$(( (do_s + row * CS) * 512 ))
	sudo dd if="$RK_TMP/junk" of="$dev" bs=4096 count=1 \
		seek=$((off / 4096)) conv=notrunc oflag=direct status=none
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
}

# raw_healed <memberdev> <row> <patfile>: retry until the raw first-4K matches
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

# NB rk_udev_quiesce runs `mdadm --stop --scan` — it may only run at the
# seams (no array of ours alive), never on the active array.
reassemble() {
	sudo "$MDADM" --stop "$MD" > /dev/null 2>&1 || return 1
	rk_udev_quiesce
	sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]}" > /dev/null 2>&1 &&
		grep -q "$MDNAME : active raidkm" /proc/mdstat || return 1
	rk_wait_idle
	sudo udevadm settle 2>/dev/null
}

dcl_create() {	# dcl_create [extra mdadm flags...]
	local d
	for d in "${MEMBERS[@]}"; do
		sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
		sudo dd if=/dev/zero of="$d" bs=1M status=none 2>/dev/null || true
	done
	rk_udev_quiesce
	rk_dmesg_clear
	sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
		--layout=declustered --group-width=$G --spare-columns=$SC \
		--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" "$@" \
		--raid-devices=$N "${MEMBERS[@]}" --run --force > /dev/null 2>&1 &&
	grep -q "$MDNAME : active raidkm" /proc/mdstat || return 1
	rk_wait_idle
	sudo udevadm settle 2>/dev/null
}

# ---- 1. plain dcl array: create + fio ----------------------------------------
if dcl_create; then
	rk_pass "declustered array active (N=$N g=$G m=$M s=$SC seed=$SEED)"
else
	rk_fail "create/activate failed"; rk_summary; exit 1
fi
mm=$(cat /sys/block/$MDNAME/md/mismatch_cnt 2>/dev/null || echo -1)
[ "$mm" = 0 ] && rk_pass "initial resync clean (mismatch_cnt=0)" \
	      || rk_fail "initial resync mismatch_cnt=$mm"

# clamp the probe span to the array (env-overridden geometries can be small)
ASZ_MB=$(( $(sudo blockdev --getsize64 "$MD") / 1048576 ))
[ "$PROBE_MB" -gt $((ASZ_MB - 8)) ] && PROBE_MB=$((ASZ_MB - 8))

if sudo fio --name=dclav --filename="$MD" --direct=1 --bs=64k --rw=write \
	--size=64M --ioengine=libaio --iodepth=8 --verify=crc32c \
	--do_verify=1 --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/dcl-fio.log" > /dev/null 2>&1; then
	rk_pass "fio 64M write+verify clean (verify reads ride the bypass)"
else
	rk_fail "fio write+verify FAILED — see $RK_TMP/dcl-fio.log"
fi

for lc in "${LCS[@]}"; do
	rk_mkpat ALN "$lc"; rk_wrchunk "$RK_TMP/ALN$lc" "$lc"
done
sync; rk_wait_idle

# ---- 2. bypass-taken probe ---------------------------------------------------
sudo udevadm settle 2>/dev/null
read -r max frac <<< "$(probe_read)"
if [ "$max" = 0 ]; then
	rk_pass "aligned ${PROBE_MB}M O_DIRECT read is stripe-quiet (active=0 in $frac samples)"
else
	rk_fail "stripe cache ACTIVE during aligned read (max=$max, nonzero $frac) — bypass not taken"
fi

# ---- 3. content through the bypass -------------------------------------------
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
ok=1
for lc in "${LCS[@]}"; do
	rk_rdchunk "$lc" "$RK_TMP/rb$lc"
	cmp -s "$RK_TMP/ALN$lc" "$RK_TMP/rb$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "pattern chunks exact through the bypass (groups+rows: lcs ${LCS[*]})" \
	    || rk_fail "bypass read mismatch at lc=$lc"

# sub-chunk reads at odd in-chunk offsets (sector-size units; 4K-logical NVMe
# needs blockdev --getss, the old T3 lesson)
SS=$(sudo blockdev --getss "$MD")
SPB=$((4096 / SS)); [ "$SPB" -ge 1 ] || SPB=1
ok=1
for lc in "${LCS[@]:0:3}"; do
	off_u=$((3 * SPB))		# 12K into the chunk, in ss units
	cnt_u=$((5 * SPB))		# 20K long
	sudo dd if="$MD" of="$RK_TMP/sub$lc" bs=$SS \
		skip=$((lc * (CHUNK_KB * 1024 / SS) + off_u)) count=$cnt_u \
		iflag=direct status=none
	tail -c +$((off_u * SS + 1)) "$RK_TMP/ALN$lc" | head -c $((cnt_u * SS)) \
		> "$RK_TMP/subx$lc"
	cmp -s "$RK_TMP/sub$lc" "$RK_TMP/subx$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "sub-chunk odd-offset reads exact (in-chunk device-sector math)" \
	    || rk_fail "sub-chunk read mismatch at lc=$lc"

# ---- 4. placement proof: corruption visibility (no csum) ---------------------
plc="${LCS[1]}"; prow=$(lc_row "$plc"); pdisk=$(lc_disk "$plc")
corrupt_raw "${MEMBERS[$pdisk]}" "$prow"
reassemble || { rk_fail "stop/re-assemble failed"; rk_summary; exit 1; }
rk_rdchunk "$plc" "$RK_TMP/cv$plc"
if cmp -s -n 4096 "$RK_TMP/cv$plc" "$RK_TMP/junk"; then
	rk_pass "bypass read returns the RAW bytes of sim's (row=$prow, disk=$pdisk) — placement proven"
else
	rk_fail "bypass read did not surface the corruption injected at (row=$prow, disk=$pdisk)"
fi
# repair: rewrite the chunk through md, then a repair pass — an RMW of the
# rewrite folds the CORRUPT old data into parity (parity described the
# original bytes), so parity must be recomputed before the clean-check
rk_wrchunk "$RK_TMP/ALN$plc" "$plc"; sync
echo repair | sudo tee "/sys/block/$MDNAME/md/sync_action" >/dev/null
rk_wait_idle
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "chunk rewritten + repaired; scrub clean (mismatch_cnt=0)" \
	      || rk_fail "post-rewrite scrub mismatch_cnt=$mm"

# ---- 5. probe control: degraded turns the bypass off -------------------------
rk_dmesg_window_close		# the fail below logs expected md noise
FD=$(lc_disk "${LCS[0]}")
rk_fail_disks "${MEMBERS[$FD]}"
rk_dmesg_clear
read -r max frac <<< "$(probe_read)"
nzn=${frac%%/*}
if [ "$nzn" -gt 0 ] 2>/dev/null; then
	rk_pass "degraded control: sampler sees stripe-path reads (max=$max, nonzero $frac)"
else
	rk_fail "degraded control saw NO stripe activity ($frac) — probe is not sensitive"
fi
ok=1
for lc in "${LCS[@]}"; do
	rk_rdchunk "$lc" "$RK_TMP/dg$lc"
	cmp -s "$RK_TMP/ALN$lc" "$RK_TMP/dg$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "degraded content exact (on-the-fly decode)" \
	    || rk_fail "degraded read mismatch at lc=$lc"

# ---- 6. csum leg: clean bypass reads verify quietly --------------------------
sudo "$MDADM" --stop "$MD" > /dev/null 2>&1
if dcl_create --checksum; then
	rk_pass "DCL|CSUM array active"
else
	rk_fail "create with --checksum failed"; rk_summary; exit 1
fi
# RANDOM fill over the whole probe span FIRST (distinct bytes per block: an
# all-same fill would give every member identical CRCs and a wrong-keyed
# lookup would still match), THEN the oracle patterns on top.
sudo dd if=/dev/urandom of="$MD" bs=1M count=$PROBE_MB oflag=direct \
	conv=notrunc,fsync status=none
for lc in "${LCS[@]}"; do
	rk_mkpat ACS "$lc"; rk_wrchunk "$RK_TMP/ACS$lc" "$lc"
done
sync
# stop/re-assemble: CRCs round-trip the region; reads fault them back in
reassemble || { rk_fail "csum stop/re-assemble failed"; rk_summary; exit 1; }
rk_dmesg_window_close
rk_dmesg_clear
read -r max frac <<< "$(probe_read)"
mmc=$(sudo dmesg | grep -c "native csum mismatch")
if [ "$max" = 0 ] && [ "$mmc" = 0 ]; then
	rk_pass "csum aligned reads verified quietly (active=0, 0 mismatches — physical-disk keying)"
else
	rk_fail "csum aligned reads noisy: max_active=$max, $mmc mismatches (wrong CRC keying?)"
fi
ok=1
for lc in "${LCS[@]}"; do
	rk_rdchunk "$lc" "$RK_TMP/cb$lc"
	cmp -s "$RK_TMP/ACS$lc" "$RK_TMP/cb$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "csum pattern chunks exact through the verified bypass" \
	    || rk_fail "csum bypass read mismatch at lc=$lc"

# ---- 7. csum detect + heal through the bypass --------------------------------
clc="${LCS[2]}"; crow=$(lc_row "$clc"); cdisk=$(lc_disk "$clc")
corrupt_raw "${MEMBERS[$cdisk]}" "$crow"
reassemble || { rk_fail "stop/re-assemble failed"; rk_summary; exit 1; }
rk_rdchunk "$clc" "$RK_TMP/hl$clc"
if cmp -s "$RK_TMP/hl$clc" "$RK_TMP/ACS$clc"; then
	got=$(sudo dmesg | sed -n 's/.*native csum mismatch disk \([0-9]*\) .*/\1/p' | tail -1)
	if [ "$got" = "$cdisk" ]; then
		rk_pass "bypass verify DETECTED the corruption on physical disk $cdisk, healed bytes exact"
	else
		rk_fail "mismatch attributed to disk '$got', expected $cdisk"
	fi
else
	rk_fail "csum bypass read returned corrupt bytes (lc=$clc) — verify missed it"
fi
raw_healed "${MEMBERS[$cdisk]}" "$crow" "$RK_TMP/ACS$clc" \
	&& rk_pass "corrupt raw block rewritten (healed) on disk $cdisk" \
	|| rk_fail "raw block not healed on disk $cdisk"

# ---- 8. final health ---------------------------------------------------------
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "final scrub clean (mismatch_cnt=0)" \
	      || rk_fail "final scrub mismatch_cnt=$mm"
rk_dmesg_window_close
[ "${RK_DMESG_BAD:-0}" = 0 ] && rk_pass "no kernel WARN/BUG during the run (all windows)" \
			     || rk_fail "kernel WARN/BUG seen — check dmesg"

rk_summary
