#!/bin/bash
#
# raidkm-test-declustered-io.sh — Phase 1c step 3 gate: first real I/O through
# the declustered map (design doc §9, Phase 1c).
#
# Proves, on a live declustered array (N=14 pool, 2 groups of g=6 = 4+2,
# 2 spare columns, pinned seed so the layout is reproducible):
#   1. create ACTIVATES and the initial resync (the group-looped sync path)
#      completes clean;
#   2. fio write+verify across the whole array — data integrity through the
#      map, RMW/RCW and parity encode on the g-wide stripes;
#   3. THE PLACEMENT ORACLE: known per-chunk patterns written at chosen
#      logical chunks land, on the RAW member disks, exactly where the
#      reference simulator says (disk = PERM[row][lcol], offset = data_offset
#      + row*chunk) — byte-for-byte, for chunks spanning both groups and
#      several rows;
#   4. the map is stable across stop/re-assemble (md read-back == pattern);
#   5. a full scrub reports mismatch_cnt == 0 (parity was encoded on the
#      right g-wide slot sets);
#   6. spare columns are untouched by data I/O (still zeroed).
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SIM_SRC="$RK_TREE/tools/declustered-sim.c"
SIM="$RK_TMP/declustered-sim"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}
SEED=${DCL_SEED:-0x10}		# the accepted seed for this geometry (pinned)
CS=$((CHUNK_KB * 2))		# chunk in sectors
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
DISKS=$(rk_pick_disks "$N") || { echo "ERROR: need $N ramdisks" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

cc -O2 -o "$SIM" "$SIM_SRC" -lm || {
	echo "ERROR: cannot build $SIM_SRC" >&2; exit 1; }
"$SIM" -N $N -g $G -m $M -s $SC -b $NBASE -S $SEED -T 1 \
	--vectors "$RK_TMP/vec.tsv" --nvec 64 > /dev/null || {
	echo "ERROR: simulator failed" >&2; exit 1; }

# ---- 1. create + initial resync ---------------------------------------------
# Full member wipe: the mismatch_cnt=0 and spare-column assertions below are
# only sound on pristine members (stale bytes from earlier runs otherwise
# read as resync repairs / phantom spare writes).
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M status=none 2>/dev/null || true
done
rk_dmesg_clear
if sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--raid-devices=$N "${MEMBERS[@]}" --run --force > /dev/null 2>&1 &&
   grep -q "md70 : active raidkm" /proc/mdstat; then
	rk_pass "declustered array active (N=$N g=$G m=$M s=$SC seed=$SEED)"
else
	rk_fail "create/activate failed"; rk_summary; exit 1
fi
rk_wait_idle
mm=$(cat /sys/block/$(basename $MD)/md/mismatch_cnt 2>/dev/null || echo -1)
[ "$mm" = 0 ] && rk_pass "initial resync clean (mismatch_cnt=0)" \
	      || rk_fail "initial resync mismatch_cnt=$mm"

# ---- 2. fio write+verify through the map -------------------------------------
if sudo fio --name=dclwv --filename="$MD" --direct=1 --bs=64k --rw=write \
	--size=64M --ioengine=libaio --iodepth=8 --verify=crc32c \
	--do_verify=1 --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/dcl-fio.log" > /dev/null 2>&1; then
	rk_pass "fio 64M write+verify clean through the declustered map"
else
	rk_fail "fio write+verify FAILED — see $RK_TMP/dcl-fio.log"
fi

# ---- 3. the placement oracle --------------------------------------------------
# Overwrite chosen logical chunks with distinct patterns, then compare the RAW
# member bytes against the simulator's (row, disk) for those chunks.
# lc 0 = row0/group0, lc 4 = row0/group1, lc 8 = row1/group0, lc 20 = row2/group1.
ORACLE_LCS="0 4 8 20"
for lc in $ORACLE_LCS; do
	# an exactly-chunk-sized file of a repeated 8-byte tag ("DCL0020\n").
	# NB the tag must be EXACTLY the repeat unit: an earlier 7-byte tag
	# produced a 57344-byte file and every cmp failed on LENGTH, falsely
	# implicating the (correct) kernel placement.
	yes "DCL$(printf '%04d' $lc)" | head -c $((CHUNK_KB * 1024)) | \
		sudo tee "$RK_TMP/chunk$lc" > /dev/null
	sudo dd if="$RK_TMP/chunk$lc" of="$MD" bs="${CHUNK_KB}k" seek=$lc \
		count=1 oflag=direct conv=notrunc,fsync status=none
done
sync
sudo "$MDADM" --stop "$MD" || { rk_fail "stop failed"; rk_summary; exit 1; }

do_s=$(rk_data_offset "${MEMBERS[0]}")
for lc in $ORACLE_LCS; do
	read -r row disk <<< "$(awk -v lc=$lc '$1 == lc {print $2, $6}' "$RK_TMP/vec.tsv")"
	off=$(( (do_s + row * CS) * 512 ))
	sudo dd if="${MEMBERS[$disk]}" of="$RK_TMP/raw$lc" bs="${CHUNK_KB}k" \
		count=1 iflag=skip_bytes,direct skip=$off status=none
	if cmp -s "$RK_TMP/chunk$lc" "$RK_TMP/raw$lc"; then
		rk_pass "placement oracle: lc=$lc -> row=$row disk=$disk (raw bytes match sim)"
	else
		rk_fail "placement oracle: lc=$lc NOT at sim's (row=$row, disk=$disk)"
	fi
done

# ---- 6. spare columns untouched ----------------------------------------------
# Data + parity occupy ngroups*g = 12 of the 14 columns of each row; the two
# spare columns must still be all-zero after every write above.  Count row-0
# members whose first data chunk carries any nonzero byte.
nz=0
for d in $(seq 0 $((N - 1))); do
	sudo dd if="${MEMBERS[$d]}" of="$RK_TMP/r0c" bs="${CHUNK_KB}k" count=1 \
		iflag=skip_bytes,direct skip=$(( do_s * 512 )) status=none
	[ "$(tr -d '\0' < "$RK_TMP/r0c" | wc -c)" -gt 0 ] && nz=$((nz + 1))
done
if [ "$nz" -le $(( N - SC )) ]; then
	rk_pass "row-0 spare columns untouched ($nz/$N members carry row-0 bytes)"
else
	rk_fail "row 0 has $nz non-zero members — a spare column was written"
fi

# ---- 4. map stable across re-assemble ----------------------------------------
rk_assemble "${MEMBERS[@]}" || { rk_fail "re-assemble failed"; rk_summary; exit 1; }
ok=1
for lc in $ORACLE_LCS; do
	sudo dd if="$MD" of="$RK_TMP/rd$lc" bs="${CHUNK_KB}k" skip=$lc count=1 \
		iflag=direct status=none
	cmp -s "$RK_TMP/chunk$lc" "$RK_TMP/rd$lc" || ok=0
done
[ $ok = 1 ] && rk_pass "patterns read back through md after re-assemble" \
	    || rk_fail "read-back mismatch after re-assemble"

# ---- 5. scrub ------------------------------------------------------------------
echo check | sudo tee /sys/block/$(basename $MD)/md/sync_action > /dev/null
rk_wait_idle
mm=$(cat /sys/block/$(basename $MD)/md/mismatch_cnt 2>/dev/null || echo -1)
[ "$mm" = 0 ] && rk_pass "full scrub clean (mismatch_cnt=0)" \
	      || rk_fail "scrub mismatch_cnt=$mm"

rk_summary
