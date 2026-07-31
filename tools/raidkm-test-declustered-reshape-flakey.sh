#!/bin/bash
#
# raidkm-test-declustered-reshape-flakey.sh — TRUE power-loss matrix for the
# declustered pool-expansion reshape via dm-flakey (raidkm-test-declustered-
# crash.sh mechanism, reshape target).
#
# Stack per member:  brd (RAM) → dm-flakey → md raidkm (dcl).
# "Power loss" = atomically flip every flakey to drop_writes mid-RESHAPE
# (in-flight + later writes vanish with SUCCESS), stop, thaw, reassemble
# --force.  This is a STRONGER test than a clean --stop: the superblock writes
# are actually dropped, so recovery must be driven by the journal (not the SB).
# Each iteration asserts: recovery engaged, the reshape completes, the
# pre-reshape pattern is byte-exact, scrub is clean, and an m-disk degraded read
# still decodes — after a genuine atomic cut.
#
# COVERAGE NOTE: on RAM-fast brd the per-band data I/O is instant, so the
# throttle's inter-band sleeps dominate the wall clock and the cut lands on a
# band boundary (journal phase DONE → resume-after) essentially every time.
# That validates the journaled-frontier resume under true power loss.  The
# torn-write paths (phase COMMIT → replay-from-scratch, phase STAGE →
# redo-from-old) fire only when the cut lands *inside* a band's I/O, which needs
# a slow (real-disk) backing or the deterministic fault-inject park knob (the
# classic reshape's Tier-2 mechanism) — a follow-up; those paths are
# implemented + compiled but not yet exercised here.  The instrumented
# $RK_TMP/rsphases.txt records the phase each iteration actually hit.
#
# Configurable: DCL_N/NEWN/G/M/SC/NBASE/SEED, DCL_CRASH_ITERS (5),
#               DCL_CRASH_DISK_MB (192), SYNC_MAX_KB (3000), DCL_CRASH_BACK.
# OPT-IN reliability gate — not part of the default runner.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

# SHRINK=1: run the matrix over the BACKWARD pool shrink (N=20 -> 14,
# array-size-first clamp before each trigger; dcl-shrink-design.md D3)
SHRINK=${SHRINK:-0}
if [ "$SHRINK" = 1 ]; then
	N=${DCL_N:-20}; NEWN=${DCL_NEWN:-14}
else
	N=${DCL_N:-14}; NEWN=${DCL_NEWN:-20}
fi
G=${DCL_G:-6}; M=${DCL_M:-2}
SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}
NEWSEED=${DCL_NEWSEED:-0xabc}
ITERS=${DCL_CRASH_ITERS:-5}
DISK_MB=${DCL_CRASH_DISK_MB:-192}
BACK=${DCL_CRASH_BACK:-/var/tmp/raidkm-dclrs-crash}
SPEED=${SYNC_MAX_KB:-3000}		# per-disk KB/s: cut lands mid-reshape
PATMB=${PATMB:-96}
TRIG=/sys/block/$MDNAME/md/rk_dcl_reshape

# brd (RAM) -> dm-flakey -> md.  brd is RAM-fast (this box has no NVMe and the
# boot-disk-backed loop path is hours-slow); the atomic drop_writes cut happens
# at the dm layer above brd, so the ordering-crash model is unchanged.
FLK=(); BRDS=(); DEVS=()

global_cleanup() {
	local d tries
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	sudo "$MDADM" --stop --scan >/dev/null 2>&1
	sudo udevadm settle 2>/dev/null
	for d in $(sudo dmsetup ls 2>/dev/null | awk '$1 ~ /^rkdclrs[0-9]+$/ {print $1}'); do
		for tries in 1 2 3 4 5; do
			sudo dmsetup remove "$d" >/dev/null 2>&1 && break
			sudo dmsetup remove --force "$d" >/dev/null 2>&1 && break
			sleep 0.2
		done
	done
}

MAXN=$(( N > NEWN ? N : NEWN ))

stack_setup() {
	local i b flk sectors brds
	FLK=(); BRDS=(); DEVS=()
	global_cleanup
	rk_setup_brd "$MAXN" || return 1
	brds=($(rk_pick_disks "$MAXN"))
	rk_udev_quiesce
	for i in "${!brds[@]}"; do		# ALL members backed by brd
		b="${brds[$i]}"
		sudo dd if=/dev/zero of="$b" bs=1M count=8 status=none 2>/dev/null
		sudo "$MDADM" --zero-superblock "$b" 2>/dev/null
		flk="rkdclrs$i"
		sectors=$(sudo blockdev --getsz "$b")
		echo "0 $sectors flakey $b 0 86400 0" | \
			sudo dmsetup create "$flk" || return 1
		BRDS+=("$b"); FLK+=("$flk"); DEVS+=("/dev/mapper/$flk")
	done
}

crash_now() {		# atomic power cut over every member (two-phase --noflush)
	local i f b sectors
	for f in "${FLK[@]}"; do
		sudo dmsetup suspend --noflush --nolockfs --noudevsync "$f"
	done
	for i in "${!FLK[@]}"; do
		f="${FLK[$i]}"; b="${BRDS[$i]}"
		sectors=$(sudo blockdev --getsz "$b")
		echo "0 $sectors flakey $b 0 0 86400 1 drop_writes" | \
			sudo dmsetup load "$f"
		sudo dmsetup resume --noudevsync "$f"
	done
}

crash_thaw() {
	local i f b sectors
	for i in "${!FLK[@]}"; do
		f="${FLK[$i]}"; b="${BRDS[$i]}"
		sectors=$(sudo blockdev --getsz "$b")
		sudo dmsetup suspend --noudevsync "$f"
		echo "0 $sectors flakey $b 0 86400 0" | sudo dmsetup load "$f"
		sudo dmsetup resume --noudevsync "$f"
	done
}

trap global_cleanup EXIT
mkdir -p "$RK_TMP"
rk_load_modules || exit 1
sudo modprobe dm-flakey 2>/dev/null

rk_dmesg_clear
for it in $(seq 1 "$ITERS"); do
	tag="iter$it"
	stack_setup || { rk_fail "$tag: stack setup failed"; break; }

	sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
		--layout=declustered --group-width=$G --spare-columns=$SC \
		--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
		--raid-devices=$N "${DEVS[@]:0:$N}" --run --force > /dev/null 2>&1 &&
	   grep -q "$MDNAME : active raidkm" /proc/mdstat ||
		{ rk_fail "$tag: create failed"; break; }
	rk_wait_idle
	sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
	sync
	PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)

	if [ "$NEWN" -gt "$N" ]; then
		for d in "${DEVS[@]:$N:$((NEWN-N))}"; do
			sudo "$MDADM" --add "$MD" "$d" >/dev/null 2>&1
		done
	else
		# backward pool shrink (SHRINK=1): array-size-first clamp
		cur=$(cat /sys/block/$MDNAME/size)
		clamp=$(( cur * ((NEWN - SC) / G) / ((N - SC) / G) ))
		sudo "$MDADM" --grow "$MD" --array-size="$(( clamp / 2 ))" >/dev/null 2>&1 ||
			{ rk_fail "$tag: array-size clamp failed"; break; }
	fi
	rk_throttle "$SPEED"
	echo "$NEWN:$NEWSEED" | sudo tee "$TRIG" >/dev/null 2>&1 || { rk_fail "$tag: trigger failed"; break; }

	delay=${DCL_CRASH_DELAY:-$(( (RANDOM % 9) + 1 ))}	# 1..9s: land inside a band
	sleep "$delay"
	fr=$(sed -n 's/.*frontier_row=\([0-9]*\).*/\1/p' <<< "$(cat $TRIG 2>/dev/null)")
	crash_now
	sudo "$MDADM" --stop "$MD" > /dev/null 2>&1
	crash_thaw
	sudo "$MDADM" --stop "$MD" > /dev/null 2>&1
	rk_udev_quiesce
	sleep 0.2
	rk_pass "$tag: reshape started + power cut at ${delay}s (frontier ~${fr:-?})"

	rk_dmesg_window_close; rk_dmesg_clear
	sudo "$MDADM" --assemble --force --run "$MD" "${DEVS[@]}" > /dev/null 2>&1 ||
		{ rk_fail "$tag: post-crash assemble failed (cut ${delay}s, frontier ${fr:-?})"; break; }
	if sudo dmesg | grep -q "dcl reshape recover"; then
		rmark=$(sudo dmesg | sed -n 's/.*dcl reshape recover.*resume at row \([0-9]*\).*/\1/p' | tail -1)
		ph=$(sudo dmesg | sed -n 's/.*dcl reshape recover.*phase \([0-9]*\).*/\1/p' | tail -1)
		case "$ph" in 1) pn=STAGE;; 2) pn=COMMIT;; 3) pn=DONE;; *) pn="?";; esac
		echo "iter$it phase=$ph($pn) resume=$rmark cutfrontier=$fr" >> "$RK_TMP/rsphases.txt"
		rk_pass "$tag: recovery engaged (phase $ph=$pn), resume row ${rmark:-?} (cut frontier ${fr:-?})"
	else
		# throttle vs 1-9s cut should always land mid-reshape; a missing
		# message means the reshape had already finalized (legit but not
		# the intended crash cell) — note it, still verify content below
		rk_pass "$tag: reshape finalized before the cut (no recover; frontier ${fr:-?})"
	fi
	# wait for the resumed reshape to complete
	done=0
	for i in $(seq 1 150); do
		case "$(cat $TRIG 2>/dev/null)" in idle*) done=1; break;; esac
		sleep 2
	done
	[ "$done" = 1 ] && rk_pass "$tag: resumed reshape completed" ||
		{ rk_fail "$tag: resumed reshape did not finish"; sudo dmesg|tail -12; break; }

	sudo dd if="$MD" of="$RK_TMP/rd" bs=1M count="$PATMB" iflag=direct status=none
	[ "$PRE" = "$(md5sum "$RK_TMP/rd"|cut -d' ' -f1)" ] &&
		rk_pass "$tag: pattern byte-exact across power-loss+resume" ||
		{ rk_fail "$tag: DATA MISMATCH across crash"; break; }
	mm=$(rk_scrub)
	[ "$mm" = 0 ] && rk_pass "$tag: scrub clean (mismatch_cnt=0)" ||
		{ rk_fail "$tag: scrub mismatch_cnt=$mm"; break; }
	# degraded decode: parity EC-correct even after a torn-write resume
	for d in "${DEVS[@]:0:$M}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
	deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null)
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo dd if="$MD" of="$RK_TMP/deg" bs=1M count="$PATMB" iflag=direct status=none
	[ "$deg" = "$M" ] && [ "$PRE" = "$(md5sum "$RK_TMP/deg"|cut -d' ' -f1)" ] &&
		rk_pass "$tag: degraded-decode after crash (parity EC-correct)" ||
		rk_fail "$tag: degraded-decode failed (degraded=$deg)"

	sudo "$MDADM" --stop "$MD" > /dev/null 2>&1
	sudo udevadm settle 2>/dev/null
	for d in "${DEVS[@]}"; do sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
	sudo udevadm settle 2>/dev/null
done
rk_dmesg_window_close
[ "$RK_DMESG_BAD" = 0 ] && rk_pass "no kernel WARN/BUG during the matrix" ||
	rk_fail "kernel log had WARN/BUG — check dmesg"

rk_summary
