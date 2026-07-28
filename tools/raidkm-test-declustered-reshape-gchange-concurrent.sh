#!/bin/bash
#
# raidkm-test-declustered-reshape-gchange-concurrent.sh — ONLINE g-change gate:
# run a throttled declustered group-geometry reshape (KIND=addparity | adddata |
# sparecount) WHILE fio hammers the array with random write+verify.  Proves the
# dual-geometry stripe path: ahead-of-frontier I/O is served by OLD-width
# previous-geometry stripes (init_stripe/stripe_set_idx at prev_dcl->g, EC
# accessors keyed on sh->disks == prev_dcl->g — raidkm_sh_dcl_prev), behind
# I/O by the new geometry, and the migrating band stalls+retries — all while
# the frontier moves.  (notes/declustered-reshape-design.md §7b.)
#
# KIND=addparity : m->m+1, g->g+1, +ngroups disks; capacity fixed.
# KIND=adddata   : k->k+1, g->g+1, +ngroups disks; capacity grows at finalize.
# KIND=sparecount: s->s' (decrease), N/g/m fixed; capacity grows at finalize.
set -u
KIND=${KIND:-addparity}
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

case "$KIND" in
addparity|adddata)
	N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}
	NGROUPS=$(( (N - SC) / G ))
	NEWN=$(( N + NGROUPS ))		# one new column per group
	NEWG=$(( G + 1 ))
	if [ "$KIND" = addparity ]; then NEWM=$(( M + 1 )); else NEWM=$M; fi
	NEWSC=$SC
	;;
sparecount)
	N=${DCL_N:-20}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-8}
	NEWN=$N; NEWG=$G; NEWM=$M; NEWSC=${DCL_NEWSC:-2}	# s 8->2: ngroups 2->3
	;;
*)	echo "ERROR: KIND must be addparity|adddata|sparecount"; exit 1;;
esac
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}; NEWSEED=${DCL_NEWSEED:-0xabc}
NEWLAYOUT=$(printf '%x' $(( NEWM | 0x400 | (NEWG << 16) | (NEWSC << 24) )))
SPEED=${SYNC_MAX_KB:-8000}	# slow the reshape so fio overlaps the whole run
FIOSEC=${FIOSEC:-60}
PATMB=${PATMB:-48}
TRIG=/sys/block/$MDNAME/md/rk_dcl_reshape

command -v fio >/dev/null || { echo "ERROR: fio required"; exit 1; }
rk_load_modules || exit 1
rk_setup_brd "$NEWN" || exit 1
MEMBERS=($(rk_pick_disks "$NEWN"))

sudo "$MDADM" --stop "$MD" 2>/dev/null
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
	sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
done

echo "=== create declustered N=$N g=$G m=$M s=$SC ==="
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--raid-devices=$N --run "${MEMBERS[@]:0:$N}" >/dev/null 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat || { rk_fail "create"; rk_summary; exit 1; }
rk_wait_idle

# a deterministic pattern OUTSIDE the fio region: fio churns [0, RGN), the
# pattern lives above it — byte-exact across the reshape while fio races
CAP_KB=$(( $(cat /sys/block/$MDNAME/size) / 2 ))
RGN=$(( CAP_KB > 524288 ? 262144 : CAP_KB * 4 / 10 ))	# fio: ~256MiB or 40%
sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" seek=$(( RGN / 1024 )) \
	oflag=direct status=none
sync; PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
OLD_SIZE=$(cat /sys/block/$MDNAME/size)

echo "=== launch fio randwrite+verify (${RGN}KiB region, ${FIOSEC}s) in background ==="
sudo fio --name=gchangeio --filename="$MD" --direct=1 --rw=randwrite \
	--bs=64k --iodepth=8 --ioengine=libaio \
	--verify=crc32c --verify_backlog=64 --verify_fatal=1 --do_verify=1 \
	--size="${RGN}k" --runtime="$FIOSEC" --time_based=1 --loops=100000 \
	--output="$RK_TMP/fio-gchange.log" > /dev/null 2>&1 &
FIO_PID=$!
sleep 3		# let fio start issuing before the reshape begins

echo "=== $KIND ONLINE: N=$N->$NEWN g=$G->$NEWG m=$M->$NEWM s=$SC->$NEWSC (layout 0x$NEWLAYOUT), throttled ${SPEED}KB/s ==="
if [ "$NEWN" -gt "$N" ]; then
	sudo "$MDADM" --add "$MD" "${MEMBERS[@]:$N:$((NEWN-N))}" >/dev/null 2>&1
	sudo udevadm settle 2>/dev/null
fi
echo "$SPEED" | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
if ! echo "$NEWN:$NEWSEED:$NEWLAYOUT" | sudo tee "$TRIG" >/dev/null 2>&1; then
	rk_fail "ONLINE $KIND trigger rejected (fio holds the array open — the online path should accept)"
	kill "$FIO_PID" 2>/dev/null; wait "$FIO_PID" 2>/dev/null
	sudo "$MDADM" --stop "$MD" 2>/dev/null; rk_summary; exit 1
fi
rk_pass "ONLINE $KIND accepted with the array in active use"

# watch the reshape run WHILE fio is active
OVERLAP=no
for i in $(seq 1 150); do
	st=$(cat "$TRIG" 2>/dev/null)
	fioalive=$(kill -0 "$FIO_PID" 2>/dev/null && echo yes || echo no)
	case "$st" in reshaping*) [ "$fioalive" = yes ] && OVERLAP=yes;; esac
	[ $((i % 5)) = 1 ] && echo "  [$i] $st | fio=$fioalive"
	case "$st" in idle*) break;; esac
	sleep 2
done
case "$(cat "$TRIG")" in idle*) rk_pass "$KIND reshape completed under live I/O";;
	*) rk_fail "reshape did not finish"; sudo dmesg|tail -8; rk_summary; exit 1;; esac
[ "$OVERLAP" = yes ] && rk_pass "reshape genuinely overlapped live fio (ahead region served online)" \
		     || rk_fail "no observed overlap (reshape too fast / fio died early — inconclusive run)"

echo "=== wait for fio to finish + check verify ==="
if wait "$FIO_PID"; then
	rk_pass "fio randwrite+verify concurrent with $KIND (all blocks verified)"
else
	rk_fail "fio verify FAILED during $KIND (dual-geometry stripe path corrupted racing I/O)"
	grep -iE "verify|error|bad" "$RK_TMP/fio-gchange.log" | head -6 | sed 's/^/      · /'
fi

echo "=== verify: pattern, capacity, scrub, decode oracle, geometry ==="
echo 2000000 | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" skip=$(( RGN / 1024 )) iflag=direct status=none 2>/dev/null | md5sum | cut -d' ' -f1)
[ "$PRE" = "$GOT" ] && rk_pass "untouched data intact across online $KIND" || rk_fail "DATA MISMATCH outside fio region"
NEW_SIZE=$(cat /sys/block/$MDNAME/size)
case "$KIND" in
addparity)	[ "$NEW_SIZE" = "$OLD_SIZE" ] && rk_pass "capacity unchanged (k fixed)" \
					     || rk_fail "capacity changed ($OLD_SIZE -> $NEW_SIZE)";;
adddata|sparecount) [ "$NEW_SIZE" -gt "$OLD_SIZE" ] && rk_pass "capacity grew ($OLD_SIZE -> $NEW_SIZE)" \
						    || rk_fail "capacity did not grow ($OLD_SIZE -> $NEW_SIZE)";;
esac
mm=$(rk_scrub); [ "$mm" = 0 ] && rk_pass "scrub clean after concurrent $KIND" || rk_fail "scrub mismatch_cnt=$mm"

# THE decode oracle: fail the new m disks ONE AT A TIME -> the fio region and
# the pattern must still read back correctly (parity written by BOTH the racing
# user writes and the migration is genuinely EC-correct at the new geometry)
for d in "${MEMBERS[@]:0:$NEWM}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
deg=$(cat /sys/block/$MDNAME/md/degraded)
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
DEG=$(sudo dd if="$MD" bs=1M count="$PATMB" skip=$(( RGN / 1024 )) iflag=direct status=none 2>/dev/null | md5sum | cut -d' ' -f1)
if [ "$deg" = "$NEWM" ] && [ "$PRE" = "$DEG" ] &&
   sudo dd if="$MD" of=/dev/null bs=1M count=$((RGN/1024)) iflag=direct status=none 2>/dev/null; then
	rk_pass "degraded-decode at m=$NEWM EC-correct after concurrent $KIND"
else
	rk_fail "degraded-decode failed (deg=$deg want $NEWM)"
fi
sudo "$MDADM" --examine "${MEMBERS[$((NEWM))]}" | grep -q "g=$NEWG (k=.*m=$NEWM)" &&
	rk_pass "new geometry persisted (--examine g=$NEWG m=$NEWM)" || rk_fail "geometry not persisted"

sudo dmesg | grep -iE "WARN|BUG|call trace|gf_invert" | tail -5 || true
sudo "$MDADM" --stop "$MD" 2>/dev/null
sudo udevadm settle 2>/dev/null
for d in "${MEMBERS[@]}"; do sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
sudo udevadm settle 2>/dev/null
rk_summary
