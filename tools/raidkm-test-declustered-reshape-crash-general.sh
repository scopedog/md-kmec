#!/bin/bash
#
# raidkm-test-declustered-reshape-crash-general.sh — crash tier for the general
# geometry-transition reshapes.  Interrupt an OFFLINE add-parity / add-data /
# spare-count reshape mid-flight (--stop), reassemble, and verify it RESUMES from
# the journaled frontier and completes with data intact + parity EC-correct.
#
# These exercise the parts of raidkm_dcl_reshape_recover that pool expansion does
# not: the journal now carries BOTH geometries (dcl_old_g/s + old_m alongside the
# new), recover rebuilds the group EC tables when (k,m) change (add-parity/
# add-data), and the recover gate + finalized-detection cope with a spare-count
# change that keeps N (delta_disks == 0).  (notes/declustered-reshape-design.md §7a.)
#
# Usage: KIND=addparity|adddata|sparecount  bash <this>
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

KIND=${KIND:-addparity}
G=${DCL_G:-6}; M=${DCL_M:-2}
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}; NEWSEED=${DCL_NEWSEED:-0xabc}
SPEED=${SYNC_MAX_KB:-3000}
PATMB=${PATMB:-96}
TRIG=/sys/block/$MDNAME/md/rk_dcl_reshape

# per-KIND geometry: create params, added disks, new layout word, decode-target m
case "$KIND" in
addparity)  N=14; SC=2; NG=$(( (N-SC)/G )); NEWN=$((N+NG)); NEWG=$((G+1)); NEWM=$((M+1))
	    NEWLAYOUT=$(printf '%x' $(( NEWM | 0x400 | (NEWG<<16) | (SC<<24) )))
	    DECM=$NEWM; EXAMINE="g=$NEWG (k=.*m=$NEWM)";;
adddata)    N=14; SC=2; NG=$(( (N-SC)/G )); NEWN=$((N+NG)); NEWG=$((G+1)); NEWM=$M
	    NEWLAYOUT=$(printf '%x' $(( NEWM | 0x400 | (NEWG<<16) | (SC<<24) )))
	    DECM=$M; EXAMINE="g=$NEWG (k=$((NEWG-NEWM))+m=$NEWM)";;
sparecount) N=20; SC=8; ENDSC=2; NG=$(( (N-SC)/G )); NEWN=$N; NEWG=$G; NEWM=$M
	    NEWLAYOUT=$(printf '%x' $(( NEWM | 0x400 | (NEWG<<16) | (ENDSC<<24) )))
	    DECM=$M; EXAMINE="$ENDSC spare column";;
*) echo "unknown KIND=$KIND"; exit 1;;
esac
ADDN=$(( NEWN - N ))

rk_load_modules || exit 1
rk_setup_brd "$NEWN" || exit 1
MEMBERS=($(rk_pick_disks "$NEWN"))

sudo "$MDADM" --stop "$MD" 2>/dev/null
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
	sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
done

echo "=== [$KIND] create N=$N g=$G m=$M s=$SC + write ${PATMB}MiB ==="
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--raid-devices=$N --run "${MEMBERS[@]:0:$N}" >/dev/null 2>&1 &&
   grep -q "$MDNAME : active" /proc/mdstat || { rk_fail "create"; rk_summary; exit 1; }
rk_wait_idle
sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
sync; PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)

TOTROWS=$(( $(cat /sys/block/${MEMBERS[0]##*/}/size 2>/dev/null || echo 0) / (CHUNK_KB*2) ))
[ "$TOTROWS" -lt 100 ] && TOTROWS=4096
echo "=== [$KIND] add $ADDN disk(s) + throttle + trigger (N=$N->$NEWN g=$G->$NEWG m=$M->$NEWM, layout 0x$NEWLAYOUT) ==="
[ "$ADDN" -gt 0 ] && for d in "${MEMBERS[@]:$N:$ADDN}"; do sudo "$MDADM" --add "$MD" "$d" >/dev/null 2>&1; done
sudo udevadm settle 2>/dev/null; sleep 1
echo "$SPEED" | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
echo "$NEWN:$NEWSEED:$NEWLAYOUT" | sudo tee "$TRIG" >/dev/null 2>&1 || { rk_fail "trigger rejected"; rk_summary; exit 1; }

echo "=== wait for a mid-flight frontier, then --stop ==="
stopped=0
for i in $(seq 1 120); do
	st=$(cat "$TRIG" 2>/dev/null)
	case "$st" in idle*) echo "  reshape finished before stop (lower SPEED)"; break;; esac
	row=$(sed -n 's/.*frontier_row=\([0-9]*\).*/\1/p' <<< "$st")
	[ -z "$row" ] && { sleep 1; continue; }
	pct=$(( row * 100 / TOTROWS ))
	[ $((i % 4)) = 1 ] && echo "  [$i] frontier_row=$row (~${pct}%)"
	if [ "$pct" -ge 30 ] && [ "$pct" -le 70 ]; then
		echo "  --stop at frontier_row=$row (~${pct}%)"
		sudo "$MDADM" --stop "$MD" 2>&1 | sed 's/^/    /'
		stopped=1; break
	fi
	sleep 1
done
[ "$stopped" = 1 ] || { rk_fail "could not stop mid-reshape"; rk_summary; exit 1; }

echo "=== reassemble -> must RESUME from the journal ==="
rk_dmesg_clear
sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]}" 2>&1 | sed 's/^/  /'
grep -q "$MDNAME : active" /proc/mdstat || { rk_fail "reassemble failed"; sudo dmesg|tail -12; rk_summary; exit 1; }
sudo dmesg | grep -iE "dcl reshape recover" | tail -2 | sed 's/^/  · /'
sudo dmesg | grep -q "dcl reshape recover" &&
	rk_pass "[$KIND] recovery engaged on reassemble" || rk_fail "recovery did not engage"

echo "=== wait for the resumed reshape to complete ==="
done=0
for i in $(seq 1 150); do case "$(cat "$TRIG" 2>/dev/null)" in idle*) done=1; break;; esac; sleep 2; done
[ "$done" = 1 ] && rk_pass "[$KIND] resumed reshape completed" || { rk_fail "resumed reshape did not finish"; sudo dmesg|tail -15; rk_summary; exit 1; }

echo "=== verify integrity + scrub + degraded-decode + geometry ==="
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
[ "$PRE" = "$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null|md5sum|cut -d' ' -f1)" ] &&
	rk_pass "data intact across crash+resume" || rk_fail "DATA MISMATCH"
mm=$(rk_scrub); [ "$mm" = 0 ] && rk_pass "scrub clean after crash+resume" || rk_fail "scrub mismatch_cnt=$mm"
for d in "${MEMBERS[@]:0:$DECM}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
deg=$(cat /sys/block/$MDNAME/md/degraded)
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
[ "$deg" = "$DECM" ] && [ "$PRE" = "$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null|md5sum|cut -d' ' -f1)" ] &&
	rk_pass "degraded-decode at m=$DECM after crash+resume (parity EC-correct)" ||
	rk_fail "degraded-decode failed (degraded=$deg want $DECM)"
sudo "$MDADM" --examine "${MEMBERS[0]}" | grep -q "$EXAMINE" &&
	rk_pass "[$KIND] new geometry persisted (--examine)" || rk_fail "geometry not persisted"

sudo dmesg | grep -iE "WARN|BUG|call trace|gf_invert" | tail -6
sudo "$MDADM" --stop "$MD" 2>/dev/null
sudo udevadm settle 2>/dev/null
for d in "${MEMBERS[@]}"; do sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
sudo udevadm settle 2>/dev/null
rk_summary
