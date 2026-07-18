#!/bin/bash
#
# raidkm-test-declustered-rebalance.sh — Phase 4 gate: copy-from-spare
# rebalance (notes/declustered-rebalance-copy-design.md).  After a disk is
# POPULATED into the distributed spare, adding a replacement COPIES X's
# content from the spare into R (offset-split, per-band quiesce) instead of
# decode-rebuilding — faster and never degraded during the rebuild.
#
# On the pinned N=14 pool (2 groups of g=6 = 4+2, s=2, seed 0x10):
#   1. create + baseline (fio verify region + on-victim pattern chunks);
#   2. fail + POPULATE the victim;
#   3. --add a wiped replacement -> the COPY path arms ("copy-from-spare
#      rebalance armed", NOT the retire-all message), completes ("copy of
#      disk N ... COMPLETE"), degraded reaches 0, assignment retired (none),
#      rkdcl block back to v2/NONE;
#   4. PLACEMENT ORACLE: R's (ram0) raw chunks == the patterns originally
#      written to the on-victim logical chunks (byte-for-byte) — proves the
#      copy moved X's real content, not garbage;
#   5. fio read-verify + scrub clean;
#   6. CONCURRENT WRITES during the copy (throttled — the copy honors the
#      per-array sync_speed_max): a write issued while COPYING reads back
#      correctly after completion;
#   7. no kernel WARN/BUG.
# Crash-mid-copy coverage lives in raidkm-test-declustered-crash.sh with
# DCL_CRASH_COPY=1 (dm-flakey power cut + resume from the journaled mark).
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SIM_SRC="$RK_TREE/tools/declustered-sim.c"
SIM="$RK_TMP/declustered-sim"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}
SEED=${DCL_SEED:-0x10}
CS=$((CHUNK_KB * 2))
NVEC=4096
NROWS=512
FIO_OFF=$((128 * 1024 * 1024))
FIO_SZ=$((64 * 1024 * 1024))
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

F=$(awk '$1 !~ /^#/ && $1 == 0 {print $6}' "$RK_TMP/vec.tsv")
FDEV="${MEMBERS[$F]}"
read -r -a FLCS <<< "$(awk -v F="$F" '$1 !~ /^#/ && $6 == F && $1 < 2048 && !seen[$5]++ {print $1}' \
	"$RK_TMP/vec.tsv" | head -6 | tr '\n' ' ')"
[ "${#FLCS[@]}" -ge 3 ] || { echo "ERROR: too few on-F vectors" >&2; exit 1; }
lc_row() { awk -v lc="$1" '$1 !~ /^#/ && $1 == lc {print $2}' "$RK_TMP/vec.tsv"; }

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
	--output="$RK_TMP/rb-fio-base.log" > /dev/null 2>&1 \
	|| { rk_fail "baseline fio failed"; rk_summary; exit 1; }
for lc in "${FLCS[@]}"; do rk_mkpat DCL "$lc"; rk_wrchunk "$RK_TMP/DCL$lc" "$lc"; done
sync
rk_pass "baseline data laid down (fio + ${#FLCS[@]} on-victim pattern chunks)"

# ---- 2. fail + populate -------------------------------------------------------
rk_fail_disks "$FDEV"
sudo "$MDADM" --remove "$MD" "$FDEV" > /dev/null 2>&1
echo "$F" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 \
	|| { rk_fail "arming failed"; rk_summary; exit 1; }
rk_wait_idle
rk_pop_show | grep -q "^populated" \
	&& rk_pass "victim $F populated into the spare (degraded=$(cat /sys/block/$MDNAME/md/degraded))" \
	|| { rk_fail "population did not complete: $(rk_pop_show)"; rk_summary; exit 1; }

# ---- 3. --add replacement -> COPY path ----------------------------------------
sudo dd if=/dev/zero of="$FDEV" bs=1M status=none 2>/dev/null || true
sudo "$MDADM" --zero-superblock "$FDEV" 2>/dev/null || true
rk_dmesg_window_close; rk_dmesg_clear
rk_add_disks "$FDEV"
# the copy must ARM (not retire-all) — assert the copy-path message
for i in $(seq 1 20); do
	sudo dmesg | grep -q "copy-from-spare rebalance armed for disk $F" && break
	sleep 0.3
done
if sudo dmesg | grep -q "copy-from-spare rebalance armed for disk $F"; then
	rk_pass "replacement took the COPY path (not retire-all)"
else
	rk_fail "copy path NOT taken: $(sudo dmesg | grep -iE 'declustered:.*(copy|retired)' | tail -1)"
fi
rk_wait_full
deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
if [ "$deg" = 0 ] && sudo dmesg | grep -qE "copy of disk $F( .*)? COMPLETE" \
   && rk_pop_show | grep -q "^none"; then
	rk_pass "copy complete: degraded=0, assignment retired"
else
	rk_fail "copy did not finish clean (degraded=$deg, $(rk_pop_show))"
fi
bv=$(rk_rkdcl_version "${MEMBERS[$((F == 0 ? 1 : 0))]}")
[ "$bv" = 2 ] && rk_pass "rkdcl block back to VERSION 2 after copy-retire" \
	      || rk_fail "rkdcl block version=$bv after copy (want 2)"

# ---- 4. placement oracle: R's raw chunks == original patterns -----------------
do_s=$(rk_data_offset "${MEMBERS[$((F == 0 ? 1 : 0))]}")
ok=1
for lc in "${FLCS[@]}"; do
	row=$(lc_row "$lc")
	off=$(( (do_s + row * CS) * 512 ))
	sudo dd if="$FDEV" of="$RK_TMP/rr$lc" bs="${CHUNK_KB}k" \
		count=1 iflag=skip_bytes,direct skip=$off status=none
	cmp -s "$RK_TMP/DCL$lc" "$RK_TMP/rr$lc" || { ok=0; break; }
done
[ $ok = 1 ] && rk_pass "replacement raw chunks == original victim content (copy oracle)" \
	    || rk_fail "copy placement wrong at lc=$lc (row=$row)"

# ---- 5. fio verify + scrub ----------------------------------------------------
ok=1
for lc in "${FLCS[@]}"; do
	rk_rdchunk "$lc" "$RK_TMP/mr$lc"
	cmp -s "$RK_TMP/DCL$lc" "$RK_TMP/mr$lc" || { ok=0; break; }
done
sudo fio --name=basev --filename="$MD" --direct=1 --bs=64k --rw=read \
	--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=8 \
	--verify=crc32c --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/rb-fio-verify.log" > /dev/null 2>&1 || ok=0
[ $ok = 1 ] && rk_pass "content reads back exactly after copy (chunks + fio)" \
	    || rk_fail "post-copy read mismatch"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "post-copy scrub clean (mismatch_cnt=0)" \
	      || rk_fail "post-copy scrub mismatch_cnt=$mm"

# ---- 6. concurrent write during the copy --------------------------------------
# re-populate a fresh victim, then --add with the copy throttled so a write
# lands mid-COPYING; verify it reads back after completion.
F2=$(awk -v f="$F" '$1 !~ /^#/ && $6 != f {print $6; exit}' "$RK_TMP/vec.tsv")
FDEV2="${MEMBERS[$F2]}"
read -r -a F2LCS <<< "$(awk -v F="$F2" '$1 !~ /^#/ && $6 == F && $1 < 2048 && !seen[$5]++ {print $1}' \
	"$RK_TMP/vec.tsv" | head -3 | tr '\n' ' ')"
rk_fail_disks "$FDEV2"; sudo "$MDADM" --remove "$MD" "$FDEV2" > /dev/null 2>&1
echo "$F2" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1
rk_wait_idle
sudo dd if=/dev/zero of="$FDEV2" bs=1M status=none 2>/dev/null || true
sudo "$MDADM" --zero-superblock "$FDEV2" 2>/dev/null || true
rk_throttle 8192
rk_add_disks "$FDEV2"
# write a fresh pattern to an on-F2 chunk WHILE the copy is running
for lc in "${F2LCS[@]}"; do rk_mkpat CCW "$lc"; rk_wrchunk "$RK_TMP/CCW$lc" "$lc"; done
sync
rk_unthrottle
rk_wait_full
ok=1
for lc in "${F2LCS[@]}"; do
	rk_rdchunk "$lc" "$RK_TMP/cw$lc"
	cmp -s "$RK_TMP/CCW$lc" "$RK_TMP/cw$lc" || { ok=0; break; }
done
deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
[ $ok = 1 ] && [ "$deg" = 0 ] \
	&& rk_pass "concurrent writes during the copy read back correctly (degraded=0)" \
	|| rk_fail "concurrent-write-during-copy wrong (ok=$ok degraded=$deg at lc=${lc:-?})"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "scrub clean after concurrent-write copy" \
	      || rk_fail "scrub mismatch_cnt=$mm after concurrent-write copy"

rk_dmesg_window_close
[ "$RK_DMESG_BAD" = 0 ] && rk_pass "no kernel WARN/BUG during the run" \
		       || rk_fail "kernel log had WARN/BUG — check dmesg"

rk_summary
