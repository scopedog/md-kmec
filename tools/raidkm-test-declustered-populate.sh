#!/bin/bash
#
# raidkm-test-declustered-populate.sh — Phase 3 gate: distributed-spare
# population + rebalance (notes/declustered-population-design.md §7).
#
# On the pinned N=14 pool (2 groups of g=6 = 4+2, s=2, seed 0x10):
#   1. create + baseline (fio verify region + pattern chunks whose data lives
#      on the victim member, at distinct permutation positions);
#   2. arming is refused while the target member is alive;
#   3. fail the victim, ARM population (sysfs rk_dcl_populate), then STOP the
#      array mid-population (throttled) — the journaled assignment + mark
#      survive: re-assemble RESUMES from a non-zero mark and completes;
#   4. POPULATED: reads of the victim's chunks come back exactly (served by
#      the spare columns, no decode), and the RAW spare-column bytes sit at
#      the simulator's per-row spare disk (rowmap oracle);
#   5. POPULATED writes land on the spare columns (raw oracle) and a full
#      scrub is clean (parity consistent through the redirect);
#   6. the assignment survives a clean stop/re-assemble;
#   7. rebalance: --add of a replacement retires the assignment (journal
#      first), stock recovery rebuilds it by decode, degraded=0, all content
#      intact, final scrub clean, no kernel WARN/BUG.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SIM_SRC="$RK_TREE/tools/declustered-sim.c"
SIM="$RK_TMP/declustered-sim"

N=14; G=6; M=2; SC=2; NBASE=16
SEED=0x10
CS=$((CHUNK_KB * 2))		# chunk in sectors
NVEC=4096
NROWS=512			# rowmap rows (oracle rows all < 256)
FIO_OFF=$((128 * 1024 * 1024))	# baseline region: lcs 2048..3071
FIO_SZ=$((64 * 1024 * 1024))
MEMBERS=()

pop_show() { cat "/sys/block/$MDNAME/md/rk_dcl_populate" 2>/dev/null; }
pop_mark() { pop_show | sed -n 's/.*mark \([0-9]*\)\/.*/\1/p'; }
# dmesg is cleared mid-test (resume/retire line matching); accumulate the
# WARN/BUG verdict across every window so nothing escapes the final check
DMESG_BAD=0
dmesg_window_close() { rk_dmesg_clean || DMESG_BAD=1; }

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

# victim = the member holding logical chunk 0; oracle chunks put it at
# distinct permutation positions (row/group/lcol all vary)
F=$(awk '$1 !~ /^#/ && $1 == 0 {print $6}' "$RK_TMP/vec.tsv")
FDEV="${MEMBERS[$F]}"
read -r -a FLCS <<< "$(awk -v F="$F" '$1 !~ /^#/ && $6 == F && $1 < 2048 && !seen[$5]++ {print $1}' \
	"$RK_TMP/vec.tsv" | head -6 | tr '\n' ' ')"
[ "${#FLCS[@]}" -ge 3 ] || { echo "ERROR: too few on-F vectors" >&2; exit 1; }
# spare column 0's physical disk for a row, from the rowmap
spare0_disk() { awk -v r="$1" '$1 !~ /^#/ && $1 == r && $4 == "S0" {print $3}' "$RK_TMP/rowmap.tsv"; }
lc_row()      { awk -v lc="$1" '$1 !~ /^#/ && $1 == lc {print $2}' "$RK_TMP/vec.tsv"; }

mkpat() {	# mkpat <tag3> <lc> — exactly-chunk-sized 8-byte-tag file
	yes "$1$(printf '%04d' "$2")" | head -c $((CHUNK_KB * 1024)) | \
		sudo tee "$RK_TMP/$1$2" > /dev/null
}
wrchunk() { sudo dd if="$1" of="$MD" bs="${CHUNK_KB}k" seek="$2" count=1 \
		oflag=direct conv=notrunc,fsync status=none; }
rdchunk() { sudo dd if="$MD" of="$2" bs="${CHUNK_KB}k" skip="$1" count=1 \
		iflag=direct status=none; }

# ---- 1. create + baseline -----------------------------------------------------
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M status=none 2>/dev/null || true
done
rk_dmesg_clear
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--raid-devices=$N "${MEMBERS[@]}" --run --force > /dev/null 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat ||
	{ rk_fail "create/activate failed"; rk_summary; exit 1; }
rk_wait_idle
mm=$(cat /sys/block/$MDNAME/md/mismatch_cnt 2>/dev/null || echo -1)
[ "$mm" = 0 ] && rk_pass "created; initial resync clean" \
	      || rk_fail "initial resync mismatch_cnt=$mm"
sudo fio --name=base --filename="$MD" --direct=1 --bs=64k --rw=write \
	--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=8 \
	--verify=crc32c --do_verify=1 --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/pop-fio-base.log" > /dev/null 2>&1 \
	|| { rk_fail "baseline fio failed"; rk_summary; exit 1; }
for lc in "${FLCS[@]}"; do mkpat DCL "$lc"; wrchunk "$RK_TMP/DCL$lc" "$lc"; done
sync
rk_pass "baseline data laid down (fio + ${#FLCS[@]} on-victim pattern chunks)"

# ---- 2. arming a live member is refused ---------------------------------------
if echo "$F" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1; then
	rk_fail "arming accepted while member $F is alive"
else
	rk_pass "arming refused while member $F is alive"
fi

# ---- 3. fail + arm + stop mid-population + resume ------------------------------
rk_fail_disks "$FDEV"
sudo "$MDADM" --remove "$MD" "$FDEV" > /dev/null 2>&1
rk_throttle 20000		# ~20 MB/s so the stop lands mid-pass
if echo "$F" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1; then
	rk_pass "population armed for failed member $F"
else
	rk_fail "arming failed for failed member $F"; rk_summary; exit 1
fi
# wait until at least two 16MiB checkpoints have plausibly landed
ok=0
for i in $(seq 1 120); do
	mk=$(pop_mark); [ -n "$mk" ] && [ "$mk" -ge $((80 * 1024 * 2)) ] && { ok=1; break; }
	sleep 1
done
[ $ok = 1 ] || rk_fail "population made no progress (mark=$(pop_mark))"
sudo "$MDADM" --stop "$MD" > /dev/null 2>&1 || {
	rk_fail "stop mid-population failed"; rk_summary; exit 1; }
rk_pass "array stopped mid-population (mark was ${mk:-?} sectors)"
SURV=()
for d in "${MEMBERS[@]}"; do [ "$d" != "$FDEV" ] && SURV+=("$d"); done
dmesg_window_close
rk_dmesg_clear
sudo "$MDADM" --assemble --run "$MD" "${SURV[@]}" > /dev/null 2>&1 || {
	rk_fail "degraded re-assemble failed"; rk_summary; exit 1; }
rmark=$(sudo dmesg | sed -n 's/.*resuming population of disk [0-9]* from mark \([0-9]*\).*/\1/p' | tail -1)
if [ -n "$rmark" ] && [ "$rmark" -gt 0 ]; then
	rk_pass "population resumed from journaled mark $rmark (>0)"
else
	rk_fail "no resume-from-mark line (got '$rmark')"
fi
rk_unthrottle
rk_wait_idle
if pop_show | grep -q "^populated"; then
	rk_pass "population COMPLETE ($(pop_show))"
else
	rk_fail "population did not complete: $(pop_show)"; rk_summary; exit 1
fi

# ---- 4. POPULATED reads + raw spare placement oracle ---------------------------
ok=1
for lc in "${FLCS[@]}"; do
	rdchunk "$lc" "$RK_TMP/pr$lc"
	cmp -s "$RK_TMP/DCL$lc" "$RK_TMP/pr$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "victim's chunks read back exactly while POPULATED" \
	    || rk_fail "POPULATED read mismatch at lc=$lc"
do_s=$(sudo "$MDADM" --examine "${MEMBERS[$((F == 0 ? 1 : 0))]}" 2>/dev/null | \
	sed -n 's/.*Data Offset : \([0-9]*\) sectors.*/\1/p')
ok=1
for lc in "${FLCS[@]}"; do
	row=$(lc_row "$lc"); sd=$(spare0_disk "$row")
	off=$(( (do_s + row * CS) * 512 ))
	sudo dd if="${MEMBERS[$sd]}" of="$RK_TMP/sp$lc" bs="${CHUNK_KB}k" \
		count=1 iflag=skip_bytes,direct skip=$off status=none
	cmp -s "$RK_TMP/DCL$lc" "$RK_TMP/sp$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "spare-column raw bytes at sim's per-row spare disk (rowmap oracle)" \
	    || rk_fail "spare placement wrong at lc=$lc (row=$row spare_disk=$sd)"

# ---- 5. POPULATED writes land on the spare + scrub -----------------------------
half=$(( ${#FLCS[@]} / 2 )); REWR=("${FLCS[@]:0:half}")
for lc in "${REWR[@]}"; do mkpat DGW "$lc"; wrchunk "$RK_TMP/DGW$lc" "$lc"; done
sync
ok=1
for lc in "${REWR[@]}"; do
	row=$(lc_row "$lc"); sd=$(spare0_disk "$row")
	off=$(( (do_s + row * CS) * 512 ))
	rdchunk "$lc" "$RK_TMP/pw$lc"
	cmp -s "$RK_TMP/DGW$lc" "$RK_TMP/pw$lc" || { ok=0; break; }
	sudo dd if="${MEMBERS[$sd]}" of="$RK_TMP/sw$lc" bs="${CHUNK_KB}k" \
		count=1 iflag=skip_bytes,direct skip=$off status=none
	cmp -s "$RK_TMP/DGW$lc" "$RK_TMP/sw$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "POPULATED rewrites read back AND hit the spare column raw" \
	    || rk_fail "POPULATED write path wrong at lc=$lc"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "POPULATED scrub clean (mismatch_cnt=0)" \
	      || rk_fail "POPULATED scrub mismatch_cnt=$mm"

# ---- 6. assignment survives a clean stop/re-assemble ---------------------------
sudo "$MDADM" --stop "$MD" > /dev/null 2>&1
sudo "$MDADM" --assemble --run "$MD" "${SURV[@]}" > /dev/null 2>&1 || {
	rk_fail "POPULATED re-assemble failed"; rk_summary; exit 1; }
rk_wait_idle
if pop_show | grep -q "^populated"; then
	rk_pass "assignment persisted across stop/re-assemble"
else
	rk_fail "assignment lost across re-assemble: $(pop_show)"
fi

# ---- 7. rebalance: --add retires the assignment, stock recovery rebuilds -------
sudo dd if=/dev/zero of="$FDEV" bs=1M status=none 2>/dev/null || true
dmesg_window_close
rk_dmesg_clear
rk_add_disks "$FDEV"
rk_wait_full
deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
if [ "$deg" = 0 ] && sudo dmesg | grep -q "spare assignment for disk $F retired"; then
	rk_pass "replacement added: assignment retired + rebuild complete (degraded=0)"
else
	rk_fail "rebalance failed (degraded=$deg)"
fi
pop_show | grep -q "^none" && rk_pass "assignment shows none after rebalance" \
			   || rk_fail "assignment not cleared: $(pop_show)"
ok=1
for lc in "${FLCS[@]}"; do
	exp="$RK_TMP/DCL$lc"
	for r in "${REWR[@]}"; do [ "$r" = "$lc" ] && exp="$RK_TMP/DGW$lc"; done
	rdchunk "$lc" "$RK_TMP/rb$lc"
	cmp -s "$exp" "$RK_TMP/rb$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "all content intact after rebalance" \
	    || rk_fail "content mismatch after rebalance at lc=$lc"
if sudo fio --name=basev --filename="$MD" --direct=1 --bs=64k --rw=read \
	--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=8 \
	--verify=crc32c --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/pop-fio-verify.log" > /dev/null 2>&1; then
	rk_pass "fio read-verify of the baseline region after rebalance"
else
	rk_fail "fio read-verify FAILED after rebalance"
fi
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "final scrub clean (mismatch_cnt=0)" \
	      || rk_fail "final scrub mismatch_cnt=$mm"
dmesg_window_close
[ "$DMESG_BAD" = 0 ] && rk_pass "no kernel WARN/BUG during the run (all windows)" \
		     || rk_fail "kernel log had WARN/BUG — check dmesg"

rk_summary
