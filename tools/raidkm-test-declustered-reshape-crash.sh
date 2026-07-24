#!/bin/bash
#
# raidkm-test-declustered-reshape-crash.sh — P2 crash tier: interrupt a
# declustered pool-expansion reshape mid-flight (--stop), reassemble, and verify
# it RESUMES from the journaled frontier and completes with data intact.
# Exercises the journal-v2 geometry record + raidkm_dcl_reshape_recover (rebuild
# both maps from the journal; the rkdcl block still holds the OLD geometry until
# finalize).  (notes/declustered-reshape-design.md §3.5/§3.6 / §8 P2.)
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-14}; NEWN=${DCL_NEWN:-20}; G=${DCL_G:-6}; M=${DCL_M:-2}
SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}
NEWSEED=${DCL_NEWSEED:-0xabc}
SPEED=${SYNC_MAX_KB:-3000}	# per-disk KB/s: slow enough to stop mid-flight
PATMB=${PATMB:-128}
TRIG=/sys/block/md70/md/rk_dcl_reshape

rk_load_modules || exit 1
rk_setup_brd "$NEWN" || exit 1
MEMBERS=($(rk_pick_disks "$NEWN"))

sudo mdadm --stop "$MD" 2>/dev/null
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
	sudo mdadm --zero-superblock "$d" 2>/dev/null
done

echo "=== create N=$N + write ${PATMB}MiB pattern ==="
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--raid-devices=$N --run "${MEMBERS[@]:0:$N}" || { echo CREATE_FAIL; exit 1; }
for i in $(seq 1 60); do grep -qE "resync|recovery" /proc/mdstat || break; sleep 2; done
sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)

TOTROWS=$(( $(cat /sys/block/${MEMBERS[0]##*/}/size 2>/dev/null || echo 0) / (CHUNK_KB*2) ))
[ "$TOTROWS" -lt 100 ] && TOTROWS=4096	# brd member size / chunk fallback
echo "=== add disks + throttle + trigger (total rows ~$TOTROWS) ==="
for d in "${MEMBERS[@]:$N:$((NEWN-N))}"; do sudo "$MDADM" --add "$MD" "$d" >/dev/null 2>&1; done
echo "$SPEED" | sudo tee /sys/block/md70/md/sync_speed_max >/dev/null
echo "$NEWN:$NEWSEED" | sudo tee "$TRIG" >/dev/null

echo "=== wait for a mid-flight frontier, then --stop ==="
stopped=0
for i in $(seq 1 90); do
	st=$(cat "$TRIG" 2>/dev/null)
	case "$st" in
	idle*) echo "  reshape finished before we could stop (raise members / lower SPEED)"; break;;
	esac
	row=$(sed -n 's/.*frontier_row=\([0-9]*\).*/\1/p' <<< "$st")
	[ -z "$row" ] && { sleep 1; continue; }
	pct=$(( row * 100 / TOTROWS ))
	[ $((i % 4)) = 1 ] && echo "  [$i] frontier_row=$row (~${pct}%)"
	if [ "$pct" -ge 30 ] && [ "$pct" -le 70 ]; then
		echo "  --stop at frontier_row=$row (~${pct}%)"
		sudo mdadm --stop "$MD" 2>&1 | sed 's/^/    /'
		stopped=1; STOPROW=$row; break
	fi
	sleep 1
done
[ "$stopped" = 1 ] || { rk_fail "could not stop mid-reshape"; rk_summary; exit 1; }

echo "=== reassemble -> must RESUME from the journal ==="
rk_dmesg_clear
sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]}" 2>&1 | sed 's/^/  /'
grep -q "md70 : active" /proc/mdstat || { rk_fail "reassemble failed"; sudo dmesg | tail -12; rk_summary; exit 1; }
sudo dmesg | grep -iE "dcl reshape recover" | tail -2 | sed 's/^/  · /'
if sudo dmesg | grep -q "dcl reshape recover"; then
	rk_pass "reshape recovery ran on reassemble (resumed from journal)"
else
	rk_fail "no 'dcl reshape recover' — recovery did not engage"
fi

echo "=== wait for the resumed reshape to complete ==="
done=0
for i in $(seq 1 120); do
	st=$(cat "$TRIG" 2>/dev/null)
	case "$st" in idle*) done=1; break;; esac
	sleep 2
done
[ "$done" = 1 ] && rk_pass "resumed reshape completed" || { rk_fail "resumed reshape did not finish"; sudo dmesg|tail -15; }

echo "=== verify integrity + scrub + degraded-decode ==="
sudo dd if="$MD" of="$RK_TMP/rd" bs=1M count="$PATMB" iflag=direct status=none
POST=$(md5sum "$RK_TMP/rd" | cut -d' ' -f1)
[ "$PRE" = "$POST" ] && rk_pass "data intact across crash+resume" || rk_fail "DATA MISMATCH ($PRE vs $POST)"
echo check | sudo tee /sys/block/md70/md/sync_action >/dev/null
for i in $(seq 1 90); do grep -qE "check" /proc/mdstat || break; sleep 2; done
mm=$(cat /sys/block/md70/md/mismatch_cnt)
[ "$mm" = 0 ] && rk_pass "scrub clean after crash+resume" || rk_fail "scrub mismatch_cnt=$mm"
for d in "${MEMBERS[@]:0:$M}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
deg=$(cat /sys/block/md70/md/degraded)
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
sudo dd if="$MD" of="$RK_TMP/deg" bs=1M count="$PATMB" iflag=direct status=none
[ "$deg" = "$M" ] && [ "$PRE" = "$(md5sum "$RK_TMP/deg"|cut -d' ' -f1)" ] && \
	rk_pass "degraded-decode after crash+resume (parity EC-correct)" || \
	rk_fail "degraded-decode failed (degraded=$deg)"

sudo "$MDADM" --detail "$MD" | grep -E "Raid Devices|Array Size|State :"
sudo dmesg | grep -iE "pool expansion|WARN|BUG|call trace|gf_invert" | tail -8
sudo mdadm --stop "$MD" 2>/dev/null
rk_summary
