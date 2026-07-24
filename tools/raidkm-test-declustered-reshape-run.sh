#!/bin/bash
#
# raidkm-test-declustered-reshape-run.sh — P1 smoke: run a real declustered
# pool-expansion reshape (N -> N') via the rk_dcl_reshape debug trigger and
# verify data integrity + scrub + geometry.  (notes/declustered-reshape-design.md
# §8 Phase P1.)  brd-backed; no crash/concurrent-I/O yet — this isolates the
# migrate-band correctness.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-14}; NEWN=${DCL_NEWN:-20}; G=${DCL_G:-6}; M=${DCL_M:-2}
SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}
NEWSEED=${DCL_NEWSEED:-0xabc}
PATMB=${PATMB:-128}
TRIG=/sys/block/md70/md/rk_dcl_reshape

rk_load_modules || exit 1
rk_setup_brd "$NEWN" || exit 1
MEMBERS=($(rk_pick_disks "$NEWN"))
echo "members: ${MEMBERS[*]}"

# clean slate
sudo mdadm --stop "$MD" 2>/dev/null
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
	sudo mdadm --zero-superblock "$d" 2>/dev/null
done

echo "=== create declustered N=$N g=$G m=$M s=$SC seed=$SEED ==="
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--raid-devices=$N --run "${MEMBERS[@]:0:$N}" || { echo "CREATE_FAIL"; exit 1; }
grep -q "md70 : active raidkm" /proc/mdstat || { echo "NOT_ACTIVE"; exit 1; }
# let the initial group-looped resync settle
for i in $(seq 1 60); do grep -qE "resync|recovery" /proc/mdstat || break; sleep 2; done
echo "initial size (sectors): $(cat /sys/block/md70/size)"

echo "=== write ${PATMB} MiB pattern (within old capacity) ==="
sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
echo "pre-reshape trigger state: $(cat $TRIG)"

echo "=== add $((NEWN-N)) new pool disks as spares ==="
for d in "${MEMBERS[@]:$N:$((NEWN-N))}"; do
	sudo "$MDADM" --add "$MD" "$d" 2>&1 | sed 's/^/  /' || echo "  ADD FAIL $d"
done
sudo "$MDADM" --detail "$MD" | grep -E "Raid Devices|Total Devices|Spare|Working"

echo "=== TRIGGER reshape -> N=$NEWN newseed=$NEWSEED ==="
echo "$NEWN:$NEWSEED" | sudo tee "$TRIG"; echo "trigger write rc=$?"

echo "=== poll reshape completion (bounded) ==="
done=0
for i in $(seq 1 100); do
	st=$(cat "$TRIG" 2>/dev/null)
	ms=$(grep -A2 '^md70' /proc/mdstat | grep -oE 'reshape =[^)]*\)|resync=[^ ]*' | head -1)
	echo "  [$i] $st ${ms:+| $ms}"
	case "$st" in idle*) done=1; break;; esac
	sleep 3
done
[ "$done" = 1 ] || { echo "RESHAPE DID NOT COMPLETE (possible wedge)"; sudo dmesg | tail -20; exit 2; }

echo "=== verify data integrity ==="
sudo dd if="$MD" of="$RK_TMP/rd" bs=1M count="$PATMB" iflag=direct status=none
POST=$(md5sum "$RK_TMP/rd" | cut -d' ' -f1)
echo "PRE=$PRE POST=$POST"
[ "$PRE" = "$POST" ] && rk_pass "data integrity across reshape" || rk_fail "DATA MISMATCH across reshape"

echo "=== scrub ==="
echo check | sudo tee /sys/block/md70/md/sync_action >/dev/null
for i in $(seq 1 90); do grep -qE "check" /proc/mdstat || break; sleep 2; done
mm=$(cat /sys/block/md70/md/mismatch_cnt)
[ "$mm" = 0 ] && rk_pass "scrub clean (mismatch_cnt=0)" || rk_fail "scrub mismatch_cnt=$mm"

echo "=== degraded-decode oracle: fail m disks (one at a time), read via reconstruct ==="
# scrub=0 does NOT prove EC-correct — only the DECODE does (project rule).
FAILN=0
for d in "${MEMBERS[@]:0:$M}"; do
	sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1 && FAILN=$((FAILN+1))
	sleep 1
done
deg=$(cat /sys/block/md70/md/degraded)
echo "failed $FAILN of $M, degraded=$deg"
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
sudo dd if="$MD" of="$RK_TMP/deg" bs=1M count="$PATMB" iflag=direct status=none
DEG=$(md5sum "$RK_TMP/deg" | cut -d' ' -f1)
if [ "$deg" = "$M" ] && [ "$PRE" = "$DEG" ]; then
	rk_pass "degraded-decode across reshape (new-geometry parity is genuinely EC-correct)"
else
	rk_fail "degraded-decode: degraded=$deg (want $M), md5 $([ "$PRE" = "$DEG" ] && echo match || echo MISMATCH)"
fi

echo "=== final geometry ==="
sudo "$MDADM" --detail "$MD" | grep -E "Raid Devices|Array Size|State :"
echo "final size (sectors): $(cat /sys/block/md70/size) (was pre-grow)"
echo "trigger state: $(cat $TRIG)"
sudo dmesg | grep -iE "declustered pool expansion|WARN|BUG|call trace|gf_invert" | tail -10

rk_summary
