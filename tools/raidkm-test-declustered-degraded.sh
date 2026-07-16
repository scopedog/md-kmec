#!/bin/bash
#
# raidkm-test-declustered-degraded.sh — Phase 2 gate: degraded operation of a
# declustered array (design doc §10, Phase 2).
#
# The declustered twist over the classic degraded gate: the failed MEMBER holds
# a DIFFERENT stripe slot in every row (slot = position of the member in that
# row's permutation), including parity slots and spare columns, so degraded
# reconstruct must pick the failed slot per-stripe instead of per-array.
#
# On the pinned N=14 pool (2 groups of g=6 = 4+2, s=2, seed 0x10):
#   1. create + clean initial resync, healthy baseline data laid down
#      (fio verify region + per-chunk patterns);
#   2. fail the member holding logical chunk 0 -> array stays active,
#      degraded=1;
#   3. DEGRADED-READ ORACLE: pattern chunks whose data slot lives on the
#      failed member — chosen from the simulator vectors so the member is
#      hit at DISTINCT permutation positions (different row/group/lcol) —
#      read back exactly through md (on-the-fly EC reconstruct), and control
#      chunks on surviving members read normally;
#   4. degraded full read-verify over the fio region (every stripe: rows
#      where the failed member holds a parity slot or a spare column too);
#   5. degraded writes: rewrite half the oracle chunks + fio write+verify a
#      fresh region (RMW/RCW with a per-stripe failed slot), read back;
#   6. degraded scrub is clean;
#   7. map stable across a degraded stop/re-assemble;
#   8. re-add the failed member -> rebuild completes, degraded=0, and the
#      REBUILT member's raw bytes carry the reconstructed chunks at exactly
#      the simulator's (row, disk) positions;
#   9. final scrub clean, no kernel WARN/BUG.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SIM_SRC="$RK_TREE/tools/declustered-sim.c"
SIM="$RK_TMP/declustered-sim"

N=14; G=6; M=2; SC=2; NBASE=16
SEED=0x10			# the accepted seed for this geometry (pinned)
CS=$((CHUNK_KB * 2))		# chunk in sectors
NVEC=4096			# vectors cover lcs 0..4095 (256 MiB of lspace)
FIO_OFF=$((128 * 1024 * 1024))	# healthy baseline region: lcs 2048..3071
FIO_SZ=$((64 * 1024 * 1024))
DWR_OFF=$((208 * 1024 * 1024))	# degraded-write region: lcs 3328..3839
DWR_SZ=$((32 * 1024 * 1024))
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
	--vectors "$RK_TMP/vec.tsv" --nvec $NVEC > /dev/null || {
	echo "ERROR: simulator failed" >&2; exit 1; }

# The member to fail: the one holding logical chunk 0 (row 0, lcol 0).  The
# degraded-read oracle then picks chunks that put this member at DISTINCT
# permutation positions (row/group/lcol all vary), plus control chunks that
# don't touch it at all.  vec.tsv: lc row group slot lcol disk.
F=$(awk '$1 !~ /^#/ && $1 == 0 {print $6}' "$RK_TMP/vec.tsv")
FDEV="${MEMBERS[$F]}"
read -r -a FLCS <<< "$(awk -v F="$F" '$1 !~ /^#/ && $6 == F && $1 < 2048 && !seen[$5]++ {print $1}' \
	"$RK_TMP/vec.tsv" | head -6 | tr '\n' ' ')"
read -r -a CLCS <<< "$(awk -v F="$F" '$1 !~ /^#/ && $6 != F && $1 < 2048 {print $1}' \
	"$RK_TMP/vec.tsv" | head -2 | tr '\n' ' ')"
[ "${#FLCS[@]}" -ge 3 ] || { echo "ERROR: too few on-F vectors" >&2; exit 1; }

# an exactly-chunk-sized file of a repeated 8-byte tag ("DCL0020\n" — the tag
# must be EXACTLY the repeat unit, see the io gate's 7-byte-tag trap)
mkpat() {	# mkpat <tag3> <lc> -> $RK_TMP/<tag3><lc>
	yes "$1$(printf '%04d' "$2")" | head -c $((CHUNK_KB * 1024)) | \
		sudo tee "$RK_TMP/$1$2" > /dev/null
}
wrchunk() {	# wrchunk <patfile> <lc> : write one chunk through md
	sudo dd if="$1" of="$MD" bs="${CHUNK_KB}k" seek="$2" count=1 \
		oflag=direct conv=notrunc,fsync status=none
}
rdchunk() {	# rdchunk <lc> <out> : read one chunk through md
	sudo dd if="$MD" of="$2" bs="${CHUNK_KB}k" skip="$1" count=1 \
		iflag=direct status=none
}

# ---- 1. create + resync + healthy baseline ----------------------------------
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M status=none 2>/dev/null || true
done
rk_dmesg_clear
if sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--raid-devices=$N "${MEMBERS[@]}" --run --force > /dev/null 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat; then
	rk_pass "declustered array active (N=$N g=$G m=$M s=$SC seed=$SEED)"
else
	rk_fail "create/activate failed"; rk_summary; exit 1
fi
rk_wait_idle
mm=$(cat /sys/block/$MDNAME/md/mismatch_cnt 2>/dev/null || echo -1)
[ "$mm" = 0 ] && rk_pass "initial resync clean (mismatch_cnt=0)" \
	      || rk_fail "initial resync mismatch_cnt=$mm"

sudo fio --name=dclbase --filename="$MD" --direct=1 --bs=64k --rw=write \
	--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=8 \
	--verify=crc32c --do_verify=1 --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/dcl-fio-base.log" > /dev/null 2>&1 \
	|| { rk_fail "healthy baseline fio failed"; rk_summary; exit 1; }
for lc in "${FLCS[@]}" "${CLCS[@]}"; do
	mkpat DCL "$lc"; wrchunk "$RK_TMP/DCL$lc" "$lc"
done
sync

# ---- 2. fail the chosen member -----------------------------------------------
rk_fail_disks "$FDEV"
deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
if [ "$deg" = 1 ] && grep -q "$MDNAME : active raidkm" /proc/mdstat; then
	rk_pass "member $F ($FDEV) failed, array active degraded=1"
else
	rk_fail "array not active/degraded=1 after fail (degraded=$deg)"
	rk_summary; exit 1
fi

# ---- 3. degraded-read oracle across permutation positions --------------------
for lc in "${FLCS[@]}"; do
	read -r row grp lcol <<< "$(awk -v lc="$lc" \
		'$1 !~ /^#/ && $1 == lc {print $2, $3, $5}' "$RK_TMP/vec.tsv")"
	rdchunk "$lc" "$RK_TMP/dr$lc"
	if cmp -s "$RK_TMP/DCL$lc" "$RK_TMP/dr$lc"; then
		rk_pass "degraded reconstruct-read: lc=$lc (row=$row grp=$grp lcol=$lcol on failed disk)"
	else
		rk_fail "degraded reconstruct-read WRONG: lc=$lc (row=$row grp=$grp lcol=$lcol)"
	fi
done
ok=1
for lc in "${CLCS[@]}"; do
	rdchunk "$lc" "$RK_TMP/dr$lc"
	cmp -s "$RK_TMP/DCL$lc" "$RK_TMP/dr$lc" || ok=0
done
[ $ok = 1 ] && rk_pass "degraded control reads (surviving members) intact" \
	    || rk_fail "control read mismatch while degraded"

# ---- 4. degraded full read-verify over the baseline region -------------------
if sudo fio --name=dclrv --filename="$MD" --direct=1 --bs=64k --rw=read \
	--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=8 \
	--verify=crc32c --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/dcl-fio-degread.log" > /dev/null 2>&1; then
	rk_pass "degraded fio read-verify over $((FIO_SZ / 1048576))M baseline region"
else
	rk_fail "degraded fio read-verify FAILED — see $RK_TMP/dcl-fio-degread.log"
fi

# ---- 5. degraded writes -------------------------------------------------------
half=$(( ${#FLCS[@]} / 2 )); REWR=("${FLCS[@]:0:half}")
for lc in "${REWR[@]}"; do
	mkpat DGW "$lc"; wrchunk "$RK_TMP/DGW$lc" "$lc"
done
sync
ok=1
for lc in "${REWR[@]}"; do
	rdchunk "$lc" "$RK_TMP/dw$lc"
	cmp -s "$RK_TMP/DGW$lc" "$RK_TMP/dw$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "degraded rewrite of on-F chunks reads back (${REWR[*]})" \
	    || rk_fail "degraded rewrite read-back mismatch (lc=$lc)"
if sudo fio --name=dclwv --filename="$MD" --direct=1 --bs=64k --rw=write \
	--offset=$DWR_OFF --size=$DWR_SZ --ioengine=libaio --iodepth=8 \
	--verify=crc32c --do_verify=1 --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/dcl-fio-degwrite.log" > /dev/null 2>&1; then
	rk_pass "degraded fio write+verify over fresh $((DWR_SZ / 1048576))M region"
else
	rk_fail "degraded fio write+verify FAILED — see $RK_TMP/dcl-fio-degwrite.log"
fi

# ---- 6. degraded scrub --------------------------------------------------------
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "degraded scrub clean (mismatch_cnt=0)" \
	      || rk_fail "degraded scrub mismatch_cnt=$mm"

# ---- 7. degraded stop/re-assemble --------------------------------------------
SURV=()
for d in "${MEMBERS[@]}"; do [ "$d" != "$FDEV" ] && SURV+=("$d"); done
sudo "$MDADM" --stop "$MD" > /dev/null 2>&1 || {
	rk_fail "degraded stop failed"; rk_summary; exit 1; }
if sudo "$MDADM" --assemble --run "$MD" "${SURV[@]}" > /dev/null 2>&1; then
	rk_wait_idle
	ok=1
	for lc in "${REWR[@]}"; do
		rdchunk "$lc" "$RK_TMP/ra$lc"
		cmp -s "$RK_TMP/DGW$lc" "$RK_TMP/ra$lc" || ok=0
	done
	[ $ok = 1 ] && rk_pass "degraded re-assemble: map stable, patterns intact" \
		    || rk_fail "read-back mismatch after degraded re-assemble"
else
	rk_fail "degraded re-assemble failed"; rk_summary; exit 1
fi

# ---- 8. re-add -> rebuild -> placement of reconstructed bytes ----------------
# Full wipe first: every byte the raw-placement check finds on the rebuilt
# member below is then PROVEN to come from the EC reconstruction, not from
# stale pre-fail content.
sudo dd if=/dev/zero of="$FDEV" bs=1M status=none 2>/dev/null || true
rk_add_disks "$FDEV"
rk_wait_full
deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
[ "$deg" = 0 ] && rk_pass "rebuild onto re-added member complete (degraded=0)" \
	       || rk_fail "rebuild did not complete (degraded=$deg)"

# the rebuilt member must carry the reconstructed chunks at exactly the
# simulator's (row, disk) positions — expected content is the DGW rewrite for
# rewritten chunks, the original DCL pattern for the rest.
do_s=$(sudo "$MDADM" --examine "${MEMBERS[0]}" 2>/dev/null | \
	sed -n 's/.*Data Offset : \([0-9]*\) sectors.*/\1/p')
ok=1
for lc in "${FLCS[@]}"; do
	row=$(awk -v lc="$lc" '$1 !~ /^#/ && $1 == lc {print $2}' "$RK_TMP/vec.tsv")
	exp="$RK_TMP/DCL$lc"
	for r in "${REWR[@]}"; do [ "$r" = "$lc" ] && exp="$RK_TMP/DGW$lc"; done
	off=$(( (do_s + row * CS) * 512 ))
	sudo dd if="$FDEV" of="$RK_TMP/rb$lc" bs="${CHUNK_KB}k" count=1 \
		iflag=skip_bytes,direct skip=$off status=none
	cmp -s "$exp" "$RK_TMP/rb$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "rebuilt member carries reconstructed chunks at sim's (row,disk)" \
	    || rk_fail "rebuilt member raw bytes wrong at lc=$lc"

# ---- 9. final scrub + kernel log ----------------------------------------------
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "post-rebuild scrub clean (mismatch_cnt=0)" \
	      || rk_fail "post-rebuild scrub mismatch_cnt=$mm"
rk_dmesg_clean && rk_pass "no kernel WARN/BUG during the run" \
	       || rk_fail "kernel log has WARN/BUG — check dmesg"

rk_summary
