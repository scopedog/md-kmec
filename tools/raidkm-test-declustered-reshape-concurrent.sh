#!/bin/bash
#
# raidkm-test-declustered-reshape-concurrent.sh — P1 online-path gate: run a
# throttled declustered pool-expansion reshape WHILE fio hammers the array with
# random write+verify, proving make_request routes concurrent I/O correctly
# across the moving frontier (below -> new map, above -> old map, on the
# migrating band -> stalled+retried) and the migration preserves writes that
# race it.  (notes/declustered-reshape-design.md §3.2 / §8 P1.)
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-14}; NEWN=${DCL_NEWN:-20}; G=${DCL_G:-6}; M=${DCL_M:-2}
SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}
NEWSEED=${DCL_NEWSEED:-0xabc}
SPEED=${SYNC_MAX_KB:-8000}	# per-disk KB/s cap: slow the reshape to overlap fio
FIOSEC=${FIOSEC:-60}
TRIG=/sys/block/md70/md/rk_dcl_reshape

command -v fio >/dev/null || { echo "ERROR: fio required"; exit 1; }
rk_load_modules || exit 1
rk_setup_brd "$NEWN" || exit 1
MEMBERS=($(rk_pick_disks "$NEWN"))

sudo mdadm --stop "$MD" 2>/dev/null
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
	sudo mdadm --zero-superblock "$d" 2>/dev/null
done

echo "=== create declustered N=$N g=$G m=$M s=$SC ==="
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--raid-devices=$N --run "${MEMBERS[@]:0:$N}" || { echo "CREATE_FAIL"; exit 1; }
grep -q "md70 : active raidkm" /proc/mdstat || { echo "NOT_ACTIVE"; exit 1; }
for i in $(seq 1 60); do grep -qE "resync|recovery" /proc/mdstat || break; sleep 2; done

# size the fio region to the OLD capacity (device does not grow until finalize)
CAP_KB=$(( $(cat /sys/block/md70/size) / 2 ))
RGN=$(( CAP_KB > 524288 ? 262144 : CAP_KB * 4 / 10 ))	# ~256 MiB or 40% of small caps
echo "=== launch fio randwrite+verify (${RGN}KiB region, ${FIOSEC}s) in background ==="
sudo fio --name=reshapeio --filename="$MD" --direct=1 --rw=randwrite \
	--bs=64k --iodepth=8 --ioengine=libaio \
	--verify=crc32c --verify_backlog=64 --verify_fatal=1 --do_verify=1 \
	--size="${RGN}k" --runtime="$FIOSEC" --time_based=1 --loops=100000 \
	--output="$RK_TMP/fio-concurrent.log" > /dev/null 2>&1 &
FIO_PID=$!
sleep 3	# let fio start issuing before the reshape begins

echo "=== add $((NEWN-N)) disks + throttle (${SPEED}KB/s) + TRIGGER reshape ==="
for d in "${MEMBERS[@]:$N:$((NEWN-N))}"; do sudo "$MDADM" --add "$MD" "$d" >/dev/null 2>&1; done
echo "$SPEED" | sudo tee /sys/block/md70/md/sync_speed_max >/dev/null
echo "$NEWN:$NEWSEED" | sudo tee "$TRIG" >/dev/null

# watch the reshape run WHILE fio is active
for i in $(seq 1 100); do
	st=$(cat "$TRIG" 2>/dev/null)
	fioalive=$(kill -0 "$FIO_PID" 2>/dev/null && echo yes || echo no)
	[ $((i % 5)) = 1 ] && echo "  [$i] $st | fio=$fioalive"
	case "$st" in idle*) break;; esac
	sleep 2
done
echo "reshape final: $(cat $TRIG) ; fio still running: $(kill -0 "$FIO_PID" 2>/dev/null && echo yes || echo no)"

echo "=== wait for fio to finish + check verify ==="
if wait "$FIO_PID"; then
	rk_pass "fio randwrite+verify concurrent with reshape (all blocks verified)"
else
	rk_fail "fio verify FAILED during reshape (data raced the migration)"
	grep -iE "verify|error|bad" "$RK_TMP/fio-concurrent.log" | head -6 | sed 's/^/      · /'
fi

echo "=== post: scrub + degraded-decode ==="
echo check | sudo tee /sys/block/md70/md/sync_action >/dev/null
for i in $(seq 1 90); do grep -qE "check" /proc/mdstat || break; sleep 2; done
mm=$(cat /sys/block/md70/md/mismatch_cnt)
[ "$mm" = 0 ] && rk_pass "scrub clean after concurrent reshape" || rk_fail "scrub mismatch_cnt=$mm"

# degraded decode: parity must be EC-correct even after the concurrent churn
for d in "${MEMBERS[@]:0:$M}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
deg=$(cat /sys/block/md70/md/degraded)
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
# a quick scrub-style read of the whole (old) region must not EIO
if [ "$deg" = "$M" ] && sudo dd if="$MD" of=/dev/null bs=1M count=$((RGN/1024)) iflag=direct status=none 2>/dev/null; then
	rk_pass "degraded read after concurrent reshape (m=$M, decode clean)"
else
	rk_fail "degraded read failed (degraded=$deg want $M)"
fi

sudo "$MDADM" --detail "$MD" | grep -E "Raid Devices|Array Size|State :"
sudo dmesg | grep -iE "declustered pool expansion|WARN|BUG|call trace|gf_invert" | tail -8
sudo mdadm --stop "$MD" 2>/dev/null
rk_summary
