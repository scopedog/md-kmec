#!/bin/bash
#
# raidkm-test-declustered-shrink-concurrent.sh — ONLINE pool-shrink gate:
# run a throttled declustered pool shrink (N -> N-g, BACKWARD walk) WHILE fio
# hammers the array with random write+verify.  Proves the backward routing:
# I/O BELOW the descending frontier is served by OLD-map (previous=1)
# placement, I/O above it by the new map, and the claimed band stalls+retries
# — all while the frontier moves DOWN.  (dcl-shrink-design.md D3.)
#
# The fio region sits at the LOW end of the (clamped) array — the backward
# walk reaches it LAST, so the race covers ahead-region service for most of
# the run and the frontier crossing at the end.  A deterministic pattern
# above the fio region must be byte-exact after.
#
# CSUM=1: same race on a NATIVE-CHECKSUM array; afterwards a full re-read
# must report ZERO csum mismatches (stale-key-storm detector for the
# backward band re-key).
set -u
CSUM=${CSUM:-0}
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-20}; G=${DCL_G:-6}; M=${DCL_M:-2}; S=${DCL_S:-2}
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}; NEWSEED=${DCL_NEWSEED:-0x77}
SPEED=${SYNC_MAX_KB:-8000}
FIOSEC=${FIOSEC:-45}
PATMB=${PATMB:-32}

NEWN=$(( N - G ))
OLD_NG=$(( (N - S) / G ))
NEW_NG=$(( (NEWN - S) / G ))
TRIG=/sys/block/$MDNAME/md/rk_dcl_reshape
CREATE_CSUM=()
[ "$CSUM" = 1 ] && CREATE_CSUM=(--checksum)

command -v fio >/dev/null || { echo "ERROR: fio required"; exit 1; }
rk_load_modules || exit 1
rk_setup_brd "$N" || exit 1
MEMBERS=($(rk_pick_disks "$N"))

sudo "$MDADM" --stop "$MD" 2>/dev/null
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
	sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
done

echo "=== create declustered N=$N g=$G m=$M s=$S csum=$CSUM ==="
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$S \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	"${CREATE_CSUM[@]}" \
	--raid-devices=$N "${MEMBERS[@]}" --run >/dev/null 2>&1 &&
   grep -q "$MDNAME : active" /proc/mdstat || { rk_fail "create"; rk_summary; exit 1; }
rk_wait_idle
STORM0=$(sudo dmesg | grep -c "native csum mismatch")

# array-size-first BEFORE any data placement: everything below lives in the
# post-shrink capacity by construction
OLD_SIZE=$(cat /sys/block/$MDNAME/size)
CLAMP_SECT=$(( OLD_SIZE * NEW_NG / OLD_NG ))
sudo "$MDADM" --grow "$MD" --array-size="$(( CLAMP_SECT / 2 ))" >/dev/null 2>&1 ||
	{ rk_fail "--array-size clamp failed"; rk_summary; exit 1; }

CAP_KB=$(( CLAMP_SECT / 2 ))
RGN=$(( CAP_KB > 524288 ? 262144 : CAP_KB * 4 / 10 ))	# fio churns [0, RGN)
sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" seek=$(( RGN / 1024 )) \
	oflag=direct status=none
sync; PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)

echo "=== launch fio randwrite+verify (${RGN}KiB low region, ${FIOSEC}s) ==="
sudo fio --name=shrinkio --filename="$MD" --direct=1 --rw=randwrite \
	--bs=64k --iodepth=8 --ioengine=libaio \
	--verify=crc32c --verify_backlog=64 --verify_fatal=1 --do_verify=1 \
	--size="${RGN}k" --runtime="$FIOSEC" --time_based=1 --loops=100000 \
	--output="$RK_TMP/fio-shrink.log" > /dev/null 2>&1 &
FIO_PID=$!
sleep 3

echo "=== ONLINE shrink N=$N->$NEWN (backward, throttled ${SPEED}KB/s) under live fio ==="
echo "$SPEED" | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
if ! echo "$NEWN:$NEWSEED" | sudo tee "$TRIG" >/dev/null 2>&1; then
	rk_fail "ONLINE shrink trigger rejected with the array in active use"
	kill "$FIO_PID" 2>/dev/null; wait "$FIO_PID" 2>/dev/null
	sudo "$MDADM" --stop "$MD" 2>/dev/null; rk_summary; exit 1
fi
rk_pass "ONLINE shrink accepted with the array in active use"

OVERLAP=no
for i in $(seq 1 150); do
	st=$(cat "$TRIG" 2>/dev/null)
	fioalive=$(kill -0 "$FIO_PID" 2>/dev/null && echo yes || echo no)
	case "$st" in reshaping*) [ "$fioalive" = yes ] && OVERLAP=yes;; esac
	[ $((i % 5)) = 1 ] && echo "  [$i] $st | fio=$fioalive"
	case "$st" in idle*) break;; esac
	sleep 2
done
case "$(cat "$TRIG")" in idle*) rk_pass "shrink completed under live I/O";;
	*) rk_fail "shrink did not finish"; sudo dmesg|tail -8; rk_summary; exit 1;; esac
[ "$OVERLAP" = yes ] && rk_pass "shrink genuinely overlapped live fio (backward frontier under I/O)" \
		     || rk_fail "no observed overlap (too fast / fio died — inconclusive)"

echo "=== fio verify verdict ==="
if wait "$FIO_PID"; then
	rk_pass "fio randwrite+verify concurrent with the backward walk (all blocks verified)"
else
	rk_fail "fio verify FAILED during the shrink (backward routing corrupted racing I/O)"
	grep -iE "verify|error|bad" "$RK_TMP/fio-shrink.log" | head -6 | sed 's/^/      · /'
fi

echo "=== verify: pattern, capacity, settled scrub, decode oracle ==="
echo 2000000 | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" skip=$(( RGN / 1024 )) iflag=direct status=none 2>/dev/null | md5sum | cut -d' ' -f1)
[ "$PRE" = "$GOT" ] && rk_pass "untouched data intact across online shrink" \
		    || rk_fail "DATA MISMATCH outside fio region"
NEW_SIZE=$(cat /sys/block/$MDNAME/size)
[ "$NEW_SIZE" = "$CLAMP_SECT" ] && rk_pass "capacity at the new geometry ($OLD_SIZE -> $NEW_SIZE)" \
				|| rk_fail "capacity $NEW_SIZE (want $CLAMP_SECT)"

d0=$(sudo dmesg | grep -c "check done")
echo check | sudo tee /sys/block/$MDNAME/md/sync_action >/dev/null
for i in $(seq 1 600); do
	[ "$(sudo dmesg | grep -c 'check done')" -gt "$d0" ] && break; sleep 0.5
done
mm=$(cat /sys/block/$MDNAME/md/mismatch_cnt)
[ "$mm" = 0 ] && rk_pass "settled scrub clean after concurrent shrink" \
	      || rk_fail "scrub mismatch_cnt=$mm"

if [ "$CSUM" = 1 ]; then
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo dd if="$MD" of=/dev/null bs=1M iflag=direct status=none 2>/dev/null
	storm=$(( $(sudo dmesg | grep -c "native csum mismatch") - STORM0 ))
	[ "$storm" = 0 ] && rk_pass "zero csum mismatches on full re-read (backward re-key coherent)" \
			 || rk_fail "$storm csum mismatches (stale-key storm on the backward walk)"
fi

# decode oracle: fail m survivors (freed spares are still attached — remove
# them first so md cannot pull them in as rebuild targets)
for d in "${MEMBERS[@]:$NEWN}"; do
	for i in $(seq 1 30); do
		sudo "$MDADM" --remove "$MD" "$d" >/dev/null 2>&1 && break; sleep 1
	done
done
for d in "${MEMBERS[@]:0:$M}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" skip=$(( RGN / 1024 )) iflag=direct status=none 2>/dev/null | md5sum | cut -d' ' -f1)
[ "$PRE" = "$GOT" ] && rk_pass "degraded-decode m=$M EC-correct after concurrent shrink" \
		    || rk_fail "degraded-decode failed"

sudo "$MDADM" --stop "$MD" 2>/dev/null
sudo udevadm settle 2>/dev/null
for d in "${MEMBERS[@]}"; do sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
sudo dmesg | grep -iE "WARN|BUG|gf_invert" | tail -3 || true
rk_summary
