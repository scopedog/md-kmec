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
#   8. rebalance: SEQUENTIAL MULTI-ASSIGNMENT COPY (§13) — --add of the
#      first replacement arms a chain-sourced COPY while F2's assignment
#      stays live (a second --add mid-copy just queues as a spare; md
#      activates it after the first copy's reap), completion retires ONLY
#      F1's assignment, and R1 raw-holds the spare content it hosts for
#      F2's chains (which now stop at R1); the second --add copies F2
#      with R1 as the chain-row source; degraded=0, content intact, final
#      scrub clean, rkdcl block back to VERSION 2;
#   9. the RETIRE-ALL fallback still works: two members are re-populated
#      (victims substituted so neither is disk 0), disk 0 is failed, and
#      a fresh --add — landing at slot 0, the lowest empty — must retire
#      ALL assignments before stock recovery runs; everything rebuilds to
#      degraded=0 + clean scrub; no kernel WARN/BUG anywhere.
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
for lc in "${ALL_LCS[@]}"; do rk_mkpat DCM "$lc"; rk_wrchunk "$RK_TMP/DCM$lc" "$lc"; done
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
rk_pop_show | grep -q "^populated $F1 " || {
	rk_fail "F1 not POPULATED: $(rk_pop_show)"; rk_summary; exit 1; }
rk_pass "F1 POPULATED"

# ---- 3. arm F2, stop mid-population, v3 resume ---------------------------------
rk_throttle 20000
echo "$F2" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 \
	|| { rk_fail "arming F2 failed"; rk_summary; exit 1; }
rk_pass "population of F2=$F2 armed (spare col 1, second assignment)"
ok=0
for i in $(seq 1 120); do
	mk=$(rk_pop_mark); [ -n "$mk" ] && [ "$mk" -ge $((80 * 1024 * 2)) ] && { ok=1; break; }
	sleep 1
done
[ $ok = 1 ] || rk_fail "F2 population made no progress (mark=$(rk_pop_mark))"
sudo "$MDADM" --stop "$MD" > /dev/null 2>&1 || {
	rk_fail "stop mid-population failed"; rk_summary; exit 1; }
rk_pass "array stopped mid-second-population (mark was ${mk:-?} sectors)"
SURV=()
for d in "${MEMBERS[@]}"; do
	[ "$d" != "$FDEV1" ] && [ "$d" != "$FDEV2" ] && SURV+=("$d")
done
rk_udev_quiesce		# don't let udev md127-steal the members (crash-gate lesson)
rk_dmesg_window_close
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
if rk_pop_show | grep -q "^populated $F2 "; then
	rk_pass "F2 population COMPLETE"
else
	rk_fail "F2 population did not complete: $(rk_pop_show)"; rk_summary; exit 1
fi

# ---- 4. both assignments visible; raw block is v3 ------------------------------
if rk_pop_show | grep -q "^populated $F1 -> spare 0" && \
   rk_pop_show | grep -q "^populated $F2 -> spare 1"; then
	rk_pass "sysfs shows both assignments ($F1->S0, $F2->S1)"
else
	rk_fail "sysfs assignments wrong: $(rk_pop_show)"
fi
bv=$(rk_rkdcl_version "${SURV[0]}")
[ "$bv" = 3 ] && rk_pass "rkdcl block is VERSION 3 with 2 assignments (adaptive)" \
	      || rk_fail "rkdcl block version=$bv (want 3)"

# ---- 5. content + resolved-placement oracle (incl. chain rows) -----------------
do_s=$(rk_data_offset "${SURV[0]}")
ok=1
for lc in "${ALL_LCS[@]}"; do
	rk_rdchunk "$lc" "$RK_TMP/mr$lc"
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
for lc in "${REWR[@]}"; do rk_mkpat DMW "$lc"; rk_wrchunk "$RK_TMP/DMW$lc" "$lc"; done
sync
ok=1
for lc in "${REWR[@]}"; do
	row=$(lc_row "$lc"); rd=$(resolved "$row" "$(lc_lcol "$lc")")
	off=$(( (do_s + row * CS) * 512 ))
	rk_rdchunk "$lc" "$RK_TMP/mw$lc"
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
rk_udev_quiesce		# ditto: settle before re-assembling the survivors
sudo "$MDADM" --assemble --run "$MD" "${SURV[@]}" > /dev/null 2>&1 || {
	rk_fail "double-POPULATED re-assemble failed"; rk_summary; exit 1; }
rk_wait_idle
if rk_pop_show | grep -q "^populated $F1 " && rk_pop_show | grep -q "^populated $F2 "; then
	rk_pass "both assignments persisted across stop/re-assemble"
else
	rk_fail "assignments lost across re-assemble: $(rk_pop_show)"
fi

# ---- 8. rebalance: SEQUENTIAL MULTI-ASSIGNMENT COPY (§13) ----------------------
# --add of F1's replacement arms a COPY whose per-row source is the CHAIN
# endpoint (F2's assignment stays live; its chain rows resolve through F1's
# slot), and completion retires ONLY F1's assignment.  R1 must inherit F1's
# whole ROLE — its own columns AND the spare content it hosts for F2's
# chains (after the partial retire, F2's chains STOP at the now-live R1).
# A second --add while the copy runs is refused (sequential rule).
sudo dd if=/dev/zero of="$FDEV1" bs=1M status=none 2>/dev/null || true
sudo dd if=/dev/zero of="$FDEV2" bs=1M status=none 2>/dev/null || true
rk_dmesg_window_close
rk_dmesg_clear
rk_add_disks "$FDEV1"
for i in $(seq 1 20); do
	sudo dmesg | grep -q "rebalance armed for disk $F1" && break
	sleep 0.3
done
sudo dmesg | grep -q "rebalance armed for disk $F1" \
	&& rk_pass "first --add took the COPY path for F1 (F2's assignment live)" \
	|| rk_fail "F1 add did not arm a copy: $(sudo dmesg | grep -i declustered | tail -1)"
# NB a second --add HERE would not be refused: md binds it as a spare and
# activates it only after this copy's reap, whereupon raid5_add_disk arms
# the second copy — sequential composition is automatic.  The gate adds
# sequentially instead so it can assert the intermediate state.
#
# Poll on the RETIRE MESSAGE, not the sysfs state: the copying line
# vanishes at reb[] compaction, milliseconds BEFORE the journal write
# completes and the messages print — a state-based poll can assert into
# that window and false-fail a correct kernel.  The "(copy complete"
# prefix also matches the legit deferred-retire path ("copy complete
# (deferred retire)") which prints no "COMPLETE" line of its own.
for i in $(seq 1 120); do
	sudo dmesg | grep -q "retired for disk $F1 (copy complete" && break
	sleep 1
done
if sudo dmesg | grep -q "retired for disk $F1 (copy complete" &&
   sudo dmesg | grep -q "; 1 assignment(s) remain" &&
   rk_pop_show | grep -q "^populated $F2 " &&
   ! rk_pop_show | grep -qE "^(populated|copying|populating) $F1 "; then
	rk_pass "F1 copy complete: ONLY F1's assignment retired, F2's persists"
else
	rk_fail "partial retire wrong: $(rk_pop_show | tr '\n' ';') | $(sudo dmesg | grep -i declustered | tail -2 | tr '\n' '|')"
fi
# HOSTED-CONTENT oracle: pick a VERIFIED chain row from F2's chunks (F2's
# content hosted at the two-hop endpoint); the copy must have materialised
# it on R1 (the copy source walks the chain), because F2's live chain now
# STOPS at R1.  pick_chunks guarantees chain rows only globally, so verify
# per-victim and skip with a note if this seed gave F2 none.
hlc=""
for lc in "${LCS2[@]}"; do
	if [ "$(hops_of "$(lc_row "$lc")" "$(lc_lcol "$lc")" "$F2")" -ge 2 ]; then
		hlc="$lc"; break
	fi
done
if [ -z "$hlc" ]; then
	rk_log "no F2 chain row among picked chunks (seed-dependent) — hosted oracle skipped"
fi
if [ -n "$hlc" ]; then
	hrow=$(lc_row "$hlc")
	do_s=$(rk_data_offset "$FDEV1")
	sudo dd if="$FDEV1" of="$RK_TMP/host$hlc" bs="${CHUNK_KB}k" count=1 \
		iflag=skip_bytes,direct skip=$(( (do_s + hrow * CS) * 512 )) status=none
	hexp="$RK_TMP/DCM$hlc"
	for r in "${REWR[@]}"; do [ "$r" = "$hlc" ] && hexp="$RK_TMP/DMW$hlc"; done
	cmp -s "$RK_TMP/host$hlc" "$hexp" \
		&& rk_pass "R1 raw holds F2's HOSTED chain content at row $hrow (chain-sourced copy)" \
		|| rk_fail "R1 missing F2's hosted content at row $hrow (lc=$hlc)"
fi
ok=1
for lc in "${LCS2[@]}"; do
	exp="$RK_TMP/DCM$lc"
	for r in "${REWR[@]}"; do [ "$r" = "$lc" ] && exp="$RK_TMP/DMW$lc"; done
	rk_rdchunk "$lc" "$RK_TMP/h2$lc"
	cmp -s "$exp" "$RK_TMP/h2$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "F2 content exact through chains ending at R1" \
	    || rk_fail "F2 content mismatch at lc=$lc after F1's copy"
# now the second replacement: a plain single-assignment copy, whose chain
# rows READ BACK from R1 (the previously-copied replacement is the source)
rk_dmesg_window_close
rk_dmesg_clear
rk_add_disks "$FDEV2"
rk_wait_full
# degraded hits 0 at the reap; a deferred retire can trail it — poll the
# message rather than asserting into the window
for i in $(seq 1 60); do
	sudo dmesg | grep -q "retired for disk $F2 (copy complete" && break
	sleep 0.5
done
deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
if [ "$deg" = 0 ] && sudo dmesg | grep -q "rebalance armed for disk $F2" &&
   sudo dmesg | grep -q "retired for disk $F2 (copy complete"; then
	rk_pass "second --add copied F2 (degraded=0; chain rows sourced from R1)"
else
	rk_fail "F2 copy failed (degraded=$deg): $(sudo dmesg | grep -i declustered | tail -2 | tr '\n' '|')"
fi
rk_pop_show | grep -q "^none" && rk_pass "assignments show none after rebalance" \
			   || rk_fail "assignments not cleared: $(rk_pop_show)"
# Check a SURVIVOR: the retire journal deterministically covers live
# members, while a freshly ADDED member may keep mdadm's verbatim clone of
# the pre-retire v3 block (the async retire journal races mdadm's clone
# write).  That stale copy is harmless — it loses the gen election, and the
# published v2 module skips invalid blocks per-member — and the next
# journal write converges it.
# retry: a deferred retire's v2 write can trail the degraded=0 reap
for i in $(seq 1 30); do
	bv=$(rk_rkdcl_version "${SURV[0]}")
	[ "$bv" = 2 ] && break
	sleep 0.5
done
[ "$bv" = 2 ] && rk_pass "rkdcl block back to VERSION 2 after retire (adaptive)" \
	      || rk_fail "rkdcl block version=$bv after retire (want 2)"
ok=1
for lc in "${ALL_LCS[@]}"; do
	exp="$RK_TMP/DCM$lc"
	for r in "${REWR[@]}"; do [ "$r" = "$lc" ] && exp="$RK_TMP/DMW$lc"; done
	rk_rdchunk "$lc" "$RK_TMP/rb$lc"
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

# ---- 9. RETIRE-ALL fallback: --add landing at a NON-assigned slot --------------
# The §13 copy path must not erode the all-or-nothing rule: with BOTH
# assignments live again, a fresh replacement that lands at a non-assigned
# empty slot retires ALL assignments before stock recovery runs (stock
# RECOVER never rebuilds hosted spare content).  The fresh add lands at the
# LOWEST empty slot, so the leg needs an empty slot below both victims:
# disk 0 plays that role, and a victim that IS disk 0 is substituted by
# another live disk (any member works as a population victim).
#
# This leg fails a THIRD disk on top of the two POPULATED assignments, so the
# array must tolerate degraded = assignments + 1.  At m=2 with both spare
# columns populated, degraded already == max_degraded and the kernel correctly
# refuses the third --fail (the disk stays a live member), so the non-assigned-
# slot scenario cannot be set up.  Run it only where redundancy is left to
# spare (m > 2); at m=2 proceeding would dd-zero a still-live member and
# corrupt the array.
if [ "$M" -gt 2 ]; then
V1=$F1; V2=$F2
[ "$V1" = 0 ] && { V1=1; [ "$V2" = 1 ] && V1=2; }
[ "$V2" = 0 ] && { V2=1; [ "$V1" = 1 ] && V2=2; }
VDEV1="${MEMBERS[$V1]}"; VDEV2="${MEMBERS[$V2]}"
F3=0; FDEV3="${MEMBERS[0]}"
rk_dmesg_window_close
rk_dmesg_clear
rk_fail_disks "$VDEV1"
sudo "$MDADM" --remove "$MD" "$VDEV1" > /dev/null 2>&1
echo "$V1" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1
rk_wait_populated || rk_fail "step9: V1=$V1 re-population stalled: $(rk_pop_show)"
rk_fail_disks "$VDEV2"
sudo "$MDADM" --remove "$MD" "$VDEV2" > /dev/null 2>&1
echo "$V2" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1
rk_wait_populated || rk_fail "step9: V2=$V2 re-population stalled: $(rk_pop_show)"
rk_fail_disks "$FDEV3"
sudo "$MDADM" --remove "$MD" "$FDEV3" > /dev/null 2>&1
# DEFENSIVE: never dd-zero a device the kernel did not actually release.  If the
# --fail/--remove did not take (device still a live array member), zeroing it
# would silently corrupt the array — the fault this leg is guarded against.
F3H="/sys/block/$(basename "$FDEV3")/holders"
for _w in 1 2 3 4; do [ -z "$(ls "$F3H" 2>/dev/null)" ] && break; sleep 0.5; done
if [ -n "$(ls "$F3H" 2>/dev/null)" ]; then
	rk_fail "step9: $FDEV3 still an array member after --fail/--remove (kernel refused the 3rd fail) — refusing to dd-zero a live disk"
else
	sudo dd if=/dev/zero of="$FDEV3" bs=1M status=none 2>/dev/null || true
	sudo "$MDADM" --zero-superblock "$FDEV3" 2>/dev/null || true
	rk_add_disks "$FDEV3"
fi
for i in $(seq 1 60); do
	sudo dmesg | grep -q "spare assignment(s) retired (replacement filled a different slot)" && break
	sleep 0.5
done
sudo dmesg | grep -q "2 spare assignment(s) retired (replacement filled a different slot)" \
	&& rk_pass "step9: non-assigned-slot --add retired ALL assignments (fallback intact)" \
	|| rk_fail "step9: retire-all fallback not taken: $(sudo dmesg | grep -i declustered | tail -2 | tr '\n' '|')"
sudo dd if=/dev/zero of="$VDEV1" bs=1M status=none 2>/dev/null || true
sudo dd if=/dev/zero of="$VDEV2" bs=1M status=none 2>/dev/null || true
sudo "$MDADM" --zero-superblock "$VDEV1" 2>/dev/null || true
sudo "$MDADM" --zero-superblock "$VDEV2" 2>/dev/null || true
rk_add_disks "$VDEV1" "$VDEV2"
rk_wait_full
deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
[ "$deg" = 0 ] && rk_pass "step9: all members rebuilt by decode (degraded=0)" \
	       || rk_fail "step9: rebuild incomplete (degraded=$deg)"
ok=1
for lc in "${ALL_LCS[@]}"; do
	exp="$RK_TMP/DCM$lc"
	for r in "${REWR[@]}"; do [ "$r" = "$lc" ] && exp="$RK_TMP/DMW$lc"; done
	rk_rdchunk "$lc" "$RK_TMP/s9$lc"
	cmp -s "$exp" "$RK_TMP/s9$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "step9: content intact through retire-all + decode rebuilds" \
	    || rk_fail "step9: content mismatch at lc=$lc"
else
	echo "  SKIP: step9 retire-all-fallback leg — needs m>2 (at m=$M/s=$SC a 3rd concurrent failure is beyond tolerance; the kernel correctly refuses it, so the non-assigned-slot scenario cannot be set up)"
fi
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "final scrub clean (mismatch_cnt=0)" \
	      || rk_fail "final scrub mismatch_cnt=$mm"
rk_dmesg_window_close
[ "$RK_DMESG_BAD" = 0 ] && rk_pass "no kernel WARN/BUG during the run (all windows)" \
		     || rk_fail "kernel log had WARN/BUG — check dmesg"

rk_summary
