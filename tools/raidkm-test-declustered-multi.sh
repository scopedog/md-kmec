#!/bin/bash
#
# raidkm-test-declustered-multi.sh — Phase 3b gate: SEQUENTIAL multi-
# assignment population (s >= 2 spare assignments active at once) with
# CHAINED redirects and the adaptive rkdcl v2/v3 journal.
#
# On the pinned N=14 pool (2 groups of g=6 = 4+2, s=2, seed 0x10):
#   1. create + baseline (fio verify region + pattern chunks whose data lives
#      on victim F1 and victim F2, including CHAIN ROWS — rows where the
#      other victim holds this victim's spare column, so the redirect must
#      chain through BOTH assignments to reach the live endpoint);
#   2. fail F1 + arm; while POPULATING, arming F2 is refused (-EBUSY:
#      populations are sequential) and re-arming F1 is refused (-EEXIST);
#   3. F1 POPULATED; fail F2 + arm (second assignment) — STOP the array
#      mid-population: the v3 journal restores BOTH assignments and the
#      mark, population resumes and completes;
#   4. sysfs shows both assignments; the raw rkdcl block is VERSION 3
#      (adaptive versioning: >= 2 active assignments);
#   5. content oracle: every pattern chunk reads back exactly through md;
#      raw placement oracle: bytes sit at the sim rowmap-v2 RESOLVED disk
#      (chain rows resolve through two hops — verified byte-for-byte);
#   6. writes while double-POPULATED land at the resolved endpoints (raw)
#      and a full scrub is clean;
#   7. clean stop/re-assemble: both assignments persist (v3 round-trip);
#   8. rebalance: --add of the first replacement retires ALL assignments
#      (all-or-nothing is the 3b correctness rule), stock recovery + a
#      re-population rebuild everything; degraded=0, content intact, final
#      scrub clean, rkdcl block back to VERSION 2, no kernel WARN/BUG.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SIM_SRC="$RK_TREE/tools/declustered-sim.c"
SIM="$RK_TMP/declustered-sim"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}
SEED=${DCL_SEED:-0x10}
CS=$((CHUNK_KB * 2))		# chunk in sectors
NVEC=4096
NROWS=512
FIO_OFF=$((128 * 1024 * 1024))
FIO_SZ=$((64 * 1024 * 1024))
MEMBERS=()

[ "$SC" -ge 2 ] || { echo "ERROR: multi gate needs s >= 2" >&2; exit 1; }

pop_show() { cat "/sys/block/$MDNAME/md/rk_dcl_populate" 2>/dev/null; }
pop_mark() { pop_show | sed -n 's/.*mark \([0-9]*\)\/.*/\1/p'; }
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
	--vectors "$RK_TMP/vec.tsv" --nvec $NVEC > /dev/null || {
	echo "ERROR: simulator failed" >&2; exit 1; }

# victims: F1 = disk of logical chunk 0; F2 = disk of the first chunk on a
# different disk.  Arming order F1 then F2 gives spares S0 then S1 — the
# rowmap-v2 oracle below is generated for exactly that assignment set.
F1=$(awk '$1 !~ /^#/ && $1 == 0 {print $6}' "$RK_TMP/vec.tsv")
F2=$(awk -v f="$F1" '$1 !~ /^#/ && $6 != f {print $6; exit}' "$RK_TMP/vec.tsv")
FDEV1="${MEMBERS[$F1]}"; FDEV2="${MEMBERS[$F2]}"

"$SIM" -N $N -g $G -m $M -s $SC -b $NBASE -S $SEED -T 1 \
	--assign "$F1:0" --assign "$F2:1" \
	--rowmap "$RK_TMP/rowmap2.tsv" --nrows $NROWS > /dev/null || {
	echo "ERROR: simulator rowmap-v2 run failed" >&2; exit 1; }
grep -q "rowmap v2" "$RK_TMP/rowmap2.tsv" || {
	echo "ERROR: rowmap is not v2" >&2; exit 1; }

# oracle helpers, all off rowmap v2: row lcol disk role resolved dead
lc_row()   { awk -v lc="$1" '$1 !~ /^#/ && $1 == lc {print $2}' "$RK_TMP/vec.tsv"; }
lc_lcol()  { awk -v lc="$1" '$1 !~ /^#/ && $1 == lc {print $5}' "$RK_TMP/vec.tsv"; }
resolved() {	# resolved <row> <lcol> -> resolved physical disk (read map)
	awk -v r="$1" -v c="$2" '$1 !~ /^#/ && $1 == r && $2 == c {print $5}' \
		"$RK_TMP/rowmap2.tsv"
}
# a chunk's chain length: 0 hops = untouched, 1 = plain redirect, 2 = chained
hops_of() {	# hops_of <row> <lcol> <direct-disk>
	local rd; rd=$(resolved "$1" "$2")
	if [ "$rd" = "$3" ]; then echo 0
	elif [ "$rd" = "$(awk -v r="$1" -v d="$3" \
		'$1 !~ /^#/ && $1 == r && $4 == "S0" && d == '"$F1"' {print $3} \
		 $1 !~ /^#/ && $1 == r && $4 == "S1" && d == '"$F2"' {print $3}' \
		"$RK_TMP/rowmap2.tsv")" ]; then echo 1
	else echo 2; fi
}

# pattern chunks: for each victim, up to 4 on-victim data chunks, of which
# AT LEAST ONE must be a chain row (resolved via two hops) — otherwise the
# gate would not exercise the 3b mechanism at all.
pick_chunks() {	# pick_chunks <victim-disk> -> list of lcs (chain rows first)
	local f="$1" lc row lcol rd chain=() plain=()
	while read -r lc; do
		row=$(lc_row "$lc"); lcol=$(lc_lcol "$lc")
		rd=$(resolved "$row" "$lcol")
		[ -n "$rd" ] || continue
		if [ "$(hops_of "$row" "$lcol" "$f")" -ge 2 ]; then
			chain+=("$lc")
		else
			plain+=("$lc")
		fi
		[ "${#chain[@]}" -ge 2 ] && [ "${#plain[@]}" -ge 2 ] && break
	done < <(awk -v F="$f" '$1 !~ /^#/ && $6 == F && $1 < 2048 {print $1}' \
			"$RK_TMP/vec.tsv")
	echo "${chain[@]:0:2} ${plain[@]:0:2}"
}
read -r -a LCS1 <<< "$(pick_chunks "$F1")"
read -r -a LCS2 <<< "$(pick_chunks "$F2")"
ALL_LCS=("${LCS1[@]}" "${LCS2[@]}")
nchain=0
for lc in "${ALL_LCS[@]}"; do
	[ "$(hops_of "$(lc_row "$lc")" "$(lc_lcol "$lc")" \
		"$(awk -v l="$lc" '$1 !~ /^#/ && $1 == l {print $6}' "$RK_TMP/vec.tsv")")" -ge 2 ] \
		&& nchain=$((nchain + 1))
done
[ "$nchain" -ge 1 ] || {
	echo "ERROR: no chain rows among the picked chunks (seed/geometry?)" >&2
	exit 1; }

mkpat() { yes "$1$(printf '%04d' "$2")" | head -c $((CHUNK_KB * 1024)) | \
		sudo tee "$RK_TMP/$1$2" > /dev/null; }
wrchunk() { sudo dd if="$1" of="$MD" bs="${CHUNK_KB}k" seek="$2" count=1 \
		oflag=direct conv=notrunc,fsync status=none; }
rdchunk() { sudo dd if="$MD" of="$2" bs="${CHUNK_KB}k" skip="$1" count=1 \
		iflag=direct status=none; }
# rkdcl block version of a member (block at data_offset + data_size)
blk_version() {	# blk_version <dev>
	local do_s av_s
	do_s=$(sudo "$MDADM" --examine "$1" 2>/dev/null | \
		sed -n 's/.*Data Offset : \([0-9]*\) sectors.*/\1/p')
	av_s=$(sudo "$MDADM" --examine "$1" 2>/dev/null | \
		sed -n 's/.*Avail Dev Size : \([0-9]*\) sectors.*/\1/p')
	[ -n "$do_s" ] && [ -n "$av_s" ] || { echo -1; return; }
	sudo dd if="$1" bs=1 skip=$(( (do_s + av_s) * 512 + 8 )) count=4 \
		status=none 2>/dev/null | od -An -tu4 | tr -d ' '
}

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
sudo fio --name=base --filename="$MD" --direct=1 --bs=64k --rw=write \
	--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=8 \
	--verify=crc32c --do_verify=1 --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/multi-fio-base.log" > /dev/null 2>&1 \
	|| { rk_fail "baseline fio failed"; rk_summary; exit 1; }
for lc in "${ALL_LCS[@]}"; do mkpat DCM "$lc"; wrchunk "$RK_TMP/DCM$lc" "$lc"; done
sync
rk_pass "baseline laid down (${#ALL_LCS[@]} on-victim chunks, $nchain chain-row(s))"

# ---- 2. fail F1 + arm; sequential + duplicate arming refused -------------------
rk_fail_disks "$FDEV1"
sudo "$MDADM" --remove "$MD" "$FDEV1" > /dev/null 2>&1
rk_throttle 20000
echo "$F1" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 \
	|| { rk_fail "arming F1 failed"; rk_summary; exit 1; }
rk_pass "population of F1=$F1 armed (spare col 0)"
rk_fail_disks "$FDEV2"
sudo "$MDADM" --remove "$MD" "$FDEV2" > /dev/null 2>&1
if echo "$F2" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1; then
	rk_fail "arming F2 accepted while F1 is POPULATING (sequential rule)"
else
	rk_pass "arming F2 refused while F1 is POPULATING (sequential rule)"
fi
if echo "$F1" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1; then
	rk_fail "re-arming F1 accepted while already assigned"
else
	rk_pass "re-arming F1 refused while already assigned"
fi
rk_unthrottle
rk_wait_idle
pop_show | grep -q "^populated $F1 " || {
	rk_fail "F1 not POPULATED: $(pop_show)"; rk_summary; exit 1; }
rk_pass "F1 POPULATED"

# ---- 3. arm F2, stop mid-population, v3 resume ---------------------------------
rk_throttle 20000
echo "$F2" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 \
	|| { rk_fail "arming F2 failed"; rk_summary; exit 1; }
rk_pass "population of F2=$F2 armed (spare col 1, second assignment)"
ok=0
for i in $(seq 1 120); do
	mk=$(pop_mark); [ -n "$mk" ] && [ "$mk" -ge $((80 * 1024 * 2)) ] && { ok=1; break; }
	sleep 1
done
[ $ok = 1 ] || rk_fail "F2 population made no progress (mark=$(pop_mark))"
sudo "$MDADM" --stop "$MD" > /dev/null 2>&1 || {
	rk_fail "stop mid-population failed"; rk_summary; exit 1; }
rk_pass "array stopped mid-second-population (mark was ${mk:-?} sectors)"
SURV=()
for d in "${MEMBERS[@]}"; do
	[ "$d" != "$FDEV1" ] && [ "$d" != "$FDEV2" ] && SURV+=("$d")
done
dmesg_window_close
rk_dmesg_clear
sudo "$MDADM" --assemble --run "$MD" "${SURV[@]}" > /dev/null 2>&1 || {
	rk_fail "double-degraded re-assemble failed"; rk_summary; exit 1; }
rmark=$(sudo dmesg | sed -n "s/.*resuming population of disk $F2 from mark \([0-9]*\).*/\1/p" | tail -1)
if [ -n "$rmark" ] && [ "$rmark" -gt 0 ]; then
	rk_pass "F2 population resumed from journaled mark $rmark (v3 restore)"
else
	rk_fail "no v3 resume-from-mark line for F2 (got '$rmark')"
fi
rk_unthrottle
rk_wait_idle
if pop_show | grep -q "^populated $F2 "; then
	rk_pass "F2 population COMPLETE"
else
	rk_fail "F2 population did not complete: $(pop_show)"; rk_summary; exit 1
fi

# ---- 4. both assignments visible; raw block is v3 ------------------------------
if pop_show | grep -q "^populated $F1 -> spare 0" && \
   pop_show | grep -q "^populated $F2 -> spare 1"; then
	rk_pass "sysfs shows both assignments ($F1->S0, $F2->S1)"
else
	rk_fail "sysfs assignments wrong: $(pop_show)"
fi
bv=$(blk_version "${SURV[0]}")
[ "$bv" = 3 ] && rk_pass "rkdcl block is VERSION 3 with 2 assignments (adaptive)" \
	      || rk_fail "rkdcl block version=$bv (want 3)"

# ---- 5. content + resolved-placement oracle (incl. chain rows) -----------------
do_s=$(sudo "$MDADM" --examine "${SURV[0]}" 2>/dev/null | \
	sed -n 's/.*Data Offset : \([0-9]*\) sectors.*/\1/p')
ok=1
for lc in "${ALL_LCS[@]}"; do
	rdchunk "$lc" "$RK_TMP/mr$lc"
	cmp -s "$RK_TMP/DCM$lc" "$RK_TMP/mr$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "all on-victim chunks read back exactly (double-POPULATED)" \
	    || rk_fail "read mismatch at lc=$lc"
ok=1
for lc in "${ALL_LCS[@]}"; do
	row=$(lc_row "$lc"); rd=$(resolved "$row" "$(lc_lcol "$lc")")
	off=$(( (do_s + row * CS) * 512 ))
	sudo dd if="${MEMBERS[$rd]}" of="$RK_TMP/ms$lc" bs="${CHUNK_KB}k" \
		count=1 iflag=skip_bytes,direct skip=$off status=none
	cmp -s "$RK_TMP/DCM$lc" "$RK_TMP/ms$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "raw bytes at rowmap-v2 RESOLVED disks (chain oracle)" \
	    || rk_fail "resolved placement wrong at lc=$lc (row=$row resolved=$rd)"

# ---- 6. writes land at resolved endpoints + scrub ------------------------------
REWR=("${LCS1[0]}" "${LCS2[0]}")	# one chain row per victim
for lc in "${REWR[@]}"; do mkpat DMW "$lc"; wrchunk "$RK_TMP/DMW$lc" "$lc"; done
sync
ok=1
for lc in "${REWR[@]}"; do
	row=$(lc_row "$lc"); rd=$(resolved "$row" "$(lc_lcol "$lc")")
	off=$(( (do_s + row * CS) * 512 ))
	rdchunk "$lc" "$RK_TMP/mw$lc"
	cmp -s "$RK_TMP/DMW$lc" "$RK_TMP/mw$lc" || { ok=0; break; }
	sudo dd if="${MEMBERS[$rd]}" of="$RK_TMP/mx$lc" bs="${CHUNK_KB}k" \
		count=1 iflag=skip_bytes,direct skip=$off status=none
	cmp -s "$RK_TMP/DMW$lc" "$RK_TMP/mx$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "double-POPULATED rewrites hit the resolved endpoints raw" \
	    || rk_fail "chained write path wrong at lc=$lc"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "double-POPULATED scrub clean (mismatch_cnt=0)" \
	      || rk_fail "double-POPULATED scrub mismatch_cnt=$mm"

# ---- 7. both assignments survive stop/re-assemble ------------------------------
sudo "$MDADM" --stop "$MD" > /dev/null 2>&1
sudo "$MDADM" --assemble --run "$MD" "${SURV[@]}" > /dev/null 2>&1 || {
	rk_fail "double-POPULATED re-assemble failed"; rk_summary; exit 1; }
rk_wait_idle
if pop_show | grep -q "^populated $F1 " && pop_show | grep -q "^populated $F2 "; then
	rk_pass "both assignments persisted across stop/re-assemble"
else
	rk_fail "assignments lost across re-assemble: $(pop_show)"
fi

# ---- 8. rebalance: first --add retires ALL; rebuilds + re-population -----------
sudo dd if=/dev/zero of="$FDEV1" bs=1M status=none 2>/dev/null || true
sudo dd if=/dev/zero of="$FDEV2" bs=1M status=none 2>/dev/null || true
dmesg_window_close
rk_dmesg_clear
rk_add_disks "$FDEV1" "$FDEV2"
rk_wait_full
deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
if [ "$deg" = 0 ] && sudo dmesg | grep -q "2 spare assignment(s) retired"; then
	rk_pass "replacements added: ALL assignments retired + rebuilds complete"
else
	rk_fail "rebalance failed (degraded=$deg)"
fi
pop_show | grep -q "^none" && rk_pass "assignments show none after rebalance" \
			   || rk_fail "assignments not cleared: $(pop_show)"
# Check a SURVIVOR: the retire journal deterministically covers live
# members, while a freshly ADDED member may keep mdadm's verbatim clone of
# the pre-retire v3 block (the async retire journal races mdadm's clone
# write).  That stale copy is harmless — it loses the gen election, and the
# published v2 module skips invalid blocks per-member — and the next
# journal write converges it.
bv=$(blk_version "${SURV[0]}")
[ "$bv" = 2 ] && rk_pass "rkdcl block back to VERSION 2 after retire (adaptive)" \
	      || rk_fail "rkdcl block version=$bv after retire (want 2)"
ok=1
for lc in "${ALL_LCS[@]}"; do
	exp="$RK_TMP/DCM$lc"
	for r in "${REWR[@]}"; do [ "$r" = "$lc" ] && exp="$RK_TMP/DMW$lc"; done
	rdchunk "$lc" "$RK_TMP/rb$lc"
	cmp -s "$exp" "$RK_TMP/rb$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "all content intact after rebalance" \
	    || rk_fail "content mismatch after rebalance at lc=$lc"
if sudo fio --name=basev --filename="$MD" --direct=1 --bs=64k --rw=read \
	--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=8 \
	--verify=crc32c --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/multi-fio-verify.log" > /dev/null 2>&1; then
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
