#!/bin/bash
#
# raidkm-test-declustered-shrink-crash.sh — crash tier for the declustered
# POOL SHRINK (dcl-shrink-design.md D3): interrupt the BACKWARD walk
# mid-flight (--stop), reassemble, and verify it RESUMES DESCENDING from the
# journaled frontier and completes with data intact.  Two rounds — the
# second stop lands lower in the walk than the first, proving the resume
# math is direction-correct (jseq counts COMPLETED bands; the rkdcl block
# still holds the OLD, larger N until finalize).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-20}; G=${DCL_G:-6}; M=${DCL_M:-2}; S=${DCL_S:-2}
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}; NEWSEED=${DCL_NEWSEED:-0x77}
SPEED=${SYNC_MAX_KB:-3000}
PATMB=${PATMB:-96}

NEWN=$(( N - G ))
OLD_NG=$(( (N - S) / G ))
NEW_NG=$(( (NEWN - S) / G ))
TRIG=/sys/block/$MDNAME/md/rk_dcl_reshape

rk_load_modules || exit 1
rk_setup_brd "$N" || exit 1
MEMBERS=($(rk_pick_disks "$N"))

sudo "$MDADM" --stop "$MD" 2>/dev/null
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
	sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
done

echo "=== create N=$N + clamp + write ${PATMB}MiB pattern ==="
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$S \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--raid-devices=$N --run "${MEMBERS[@]}" >/dev/null 2>&1 ||
	{ rk_fail "create"; rk_summary; exit 1; }
rk_wait_idle
OLD_SIZE=$(cat /sys/block/$MDNAME/size)
CLAMP_SECT=$(( OLD_SIZE * NEW_NG / OLD_NG ))
sudo "$MDADM" --grow "$MD" --array-size="$(( CLAMP_SECT / 2 ))" >/dev/null 2>&1 ||
	{ rk_fail "clamp"; rk_summary; exit 1; }
sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
sync; PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)

TOTROWS=$(( $(cat /sys/block/${MEMBERS[0]##*/}/size 2>/dev/null || echo 0) / (CHUNK_KB*2) ))
[ "$TOTROWS" -lt 100 ] && TOTROWS=4096

echo "=== throttled shrink N=$N->$NEWN (frontier descends from ~$TOTROWS) ==="
echo "$SPEED" | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
echo "$NEWN:$NEWSEED" | sudo tee "$TRIG" >/dev/null 2>&1 ||
	{ rk_fail "shrink trigger rejected"; rk_summary; exit 1; }

# stop_in_window <low-pct-done> <high-pct-done>  — pct of the DESCENDING walk
stop_in_window() {
	local lo=$1 hi=$2 i st row pct
	for i in $(seq 1 120); do
		st=$(cat "$TRIG" 2>/dev/null)
		case "$st" in idle*) echo "finished-early"; return 1;; esac
		row=$(sed -n 's/.*frontier_row=\([0-9]*\).*/\1/p' <<< "$st")
		[ -z "$row" ] && { sleep 1; continue; }
		pct=$(( (TOTROWS - row) * 100 / TOTROWS ))
		[ $((i % 5)) = 1 ] && echo "  [$i] frontier_row=$row (~${pct}% done, descending)"
		if [ "$pct" -ge "$lo" ] && [ "$pct" -le "$hi" ]; then
			echo "  --stop at frontier_row=$row (~${pct}% done)"
			sudo "$MDADM" --stop "$MD" 2>&1 | sed 's/^/    /'
			echo "$row"; return 0
		fi
		sleep 1
	done
	return 1
}

resume_round() {	# $1 = round label
	rk_dmesg_clear
	sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]}" 2>&1 | sed 's/^/  /'
	grep -q "$MDNAME : active" /proc/mdstat ||
		{ rk_fail "$1: reassemble failed"; sudo dmesg | tail -10; return 1; }
	if sudo dmesg | grep -q "dcl reshape recover"; then
		rk_pass "$1: recovery engaged on reassemble (resumed from journal)"
		sudo dmesg | grep "dcl reshape recover" | tail -1 | sed 's/^/  · /'
	else
		rk_fail "$1: no 'dcl reshape recover' in dmesg"
	fi
	echo "$SPEED" | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
	return 0
}

echo "=== round 1: stop at 25-55% done, reassemble, resume ==="
R1=$(stop_in_window 25 55 | tail -1)
case "$R1" in ''|*[!0-9]*)
	rk_fail "round 1: could not stop mid-walk ($R1)"; rk_summary; exit 1;;
esac
resume_round "round 1" || { rk_summary; exit 1; }

echo "=== round 2: stop again lower (60-90% done), reassemble, resume ==="
R2=$(stop_in_window 60 90 | tail -1)
if case "$R2" in ''|*[!0-9]*) false;; *) true;; esac; then
	[ "$R2" -lt "$R1" ] && rk_pass "round 2: frontier descended between stops ($R1 -> $R2)" \
			    || rk_fail "round 2: frontier did not descend ($R1 -> $R2)"
	resume_round "round 2" || { rk_summary; exit 1; }
else
	echo "  (walk finished before a second stop — round 2 resume skipped)"
fi

echo "=== let the resumed walk complete ==="
echo 2000000 | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
done=0
for i in $(seq 1 240); do
	case "$(cat "$TRIG" 2>/dev/null)" in idle*) done=1; break;; esac
	sleep 2
done
[ "$done" = 1 ] && rk_pass "resumed shrink completed" ||
	{ rk_fail "resumed shrink did not finish"; sudo dmesg | tail -12; rk_summary; exit 1; }

echo "=== verify: data, capacity, settled scrub, decode oracle ==="
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
POST=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null | md5sum | cut -d' ' -f1)
[ "$PRE" = "$POST" ] && rk_pass "data intact across crash+resume (backward)" \
		     || rk_fail "DATA MISMATCH"
[ "$(cat /sys/block/$MDNAME/size)" = "$CLAMP_SECT" ] &&
	rk_pass "capacity at new geometry after crash+resume" ||
	rk_fail "capacity $(cat /sys/block/$MDNAME/size) (want $CLAMP_SECT)"
d0=$(sudo dmesg | grep -c "check done")
echo check | sudo tee /sys/block/$MDNAME/md/sync_action >/dev/null
for i in $(seq 1 600); do
	[ "$(sudo dmesg | grep -c 'check done')" -gt "$d0" ] && break; sleep 0.5
done
mm=$(cat /sys/block/$MDNAME/md/mismatch_cnt)
[ "$mm" = 0 ] && rk_pass "settled scrub clean after crash+resume" \
	      || rk_fail "scrub mismatch_cnt=$mm"
for d in "${MEMBERS[@]:$NEWN}"; do
	for i in $(seq 1 30); do
		sudo "$MDADM" --remove "$MD" "$d" >/dev/null 2>&1 && break; sleep 1
	done
done
for d in "${MEMBERS[@]:0:$M}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
DEG=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null | md5sum | cut -d' ' -f1)
[ "$PRE" = "$DEG" ] && rk_pass "degraded-decode m=$M EC-correct after crash+resume" \
		    || rk_fail "degraded-decode failed"

sudo "$MDADM" --stop "$MD" 2>/dev/null
sudo udevadm settle 2>/dev/null
for d in "${MEMBERS[@]}"; do sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
sudo dmesg | grep -iE "WARN|BUG|gf_invert" | tail -3 || true
rk_summary
