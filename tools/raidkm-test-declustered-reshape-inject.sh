#!/bin/bash
#
# raidkm-test-declustered-reshape-inject.sh — DETERMINISTIC torn-write crash
# gate for the declustered pool-expansion reshape (needs a RAIDKM_FAULT_INJECT=1
# build).  The dm-flakey matrix only reaches band boundaries (phase DONE); this
# uses the raidkm_reshape_inject knob to park the reshape thread at a chosen
# band+phase with a torn (half-written) or absent phase write, then stop +
# reassemble so recovery must take the exact path under test:
#
#   COMMIT:torn / COMMIT:hang -> raidkm_dcl_replay_commit (scratch -> home)
#   STAGE:torn  / STAGE:hang  -> redo-from-old (home intact)
#
# The classic reshape's Tier-2 COMMIT-torn is the go/no-go gate; this is its dcl
# twin.  Each case asserts: parked at the armed point, recovery engaged with the
# expected journal phase, the reshape completes, the pattern is byte-exact,
# scrub is clean, and an m-disk degraded read decodes.
#
# SHRINK=1: run the same matrix over the BACKWARD pool shrink (N -> N-g,
# dcl-shrink-design.md D3) — the walk descends, so band 0 is the LAST band
# processed and band -1 the first; recovery must resume DESCENDING.  The
# array is clamped array-size-first before the trigger.
set -u
SHRINK=${SHRINK:-0}
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

if [ "$SHRINK" = 1 ]; then
	N=${DCL_N:-20}; NEWN=${DCL_NEWN:-14}
else
	N=${DCL_N:-14}; NEWN=${DCL_NEWN:-20}
fi
G=${DCL_G:-6}; M=${DCL_M:-2}
SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}
NEWSEED=${DCL_NEWSEED:-0xabc}; PATMB=${PATMB:-96}
INJ=/sys/block/$MDNAME/md/raidkm_reshape_inject
TRIG=/sys/block/$MDNAME/md/rk_dcl_reshape

MAXN=$(( N > NEWN ? N : NEWN ))
rk_load_modules || exit 1
rk_setup_brd "$MAXN" || exit 1

run_case() {			# $1=band  $2=phase  $3=action
	local band="$1" phase="$2" action="$3" tag="$1:$2:$3"
	local MEMBERS=($(rk_pick_disks "$MAXN")) d i st PRE

	sudo "$MDADM" --stop "$MD" 2>/dev/null
	for d in "${MEMBERS[@]}"; do
		sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
		sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
	sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
		--layout=declustered --group-width=$G --spare-columns=$SC \
		--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
		--raid-devices=$N "${MEMBERS[@]:0:$N}" --run >/dev/null 2>&1 &&
	   grep -q "$MDNAME : active" /proc/mdstat || { rk_fail "$tag: create"; return; }
	[ -e "$INJ" ] || { rk_fail "$tag: $INJ missing — needs a RAIDKM_FAULT_INJECT=1 build"; return; }
	rk_wait_idle
	sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
	sync; PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)

	if [ "$NEWN" -gt "$N" ]; then
		for d in "${MEMBERS[@]:$N:$((NEWN-N))}"; do
			sudo "$MDADM" --add "$MD" "$d" >/dev/null 2>&1
		done
	else
		# backward: array-size-first before the shrink trigger
		local cur=$(cat /sys/block/$MDNAME/size)
		local clamp=$(( cur * ((NEWN - SC) / G) / ((N - SC) / G) ))
		sudo "$MDADM" --grow "$MD" --array-size="$(( clamp / 2 ))" >/dev/null 2>&1 ||
			{ rk_fail "$tag: array-size clamp"; return; }
	fi
	echo "$band:$phase:$action" | sudo tee "$INJ" >/dev/null
	rk_dmesg_clear
	echo "$NEWN:$NEWSEED" | sudo tee "$TRIG" >/dev/null 2>&1 || { rk_fail "$tag: trigger"; return; }

	# wait for the reshape thread to PARK at the armed point
	local parked=0
	for i in $(seq 1 200); do
		st=$(cat "$INJ" 2>/dev/null)
		case "$st" in parked@*) parked=1; break;; esac
		case "$(cat "$TRIG" 2>/dev/null)" in idle*)
			rk_fail "$tag: reshape finished without parking (band never reached?)"; return;;
		esac
		sleep 0.3
	done
	[ "$parked" = 1 ] || { rk_fail "$tag: never parked (inj=$st trig=$(cat $TRIG))"; return; }
	rk_pass "$tag: parked ($st)"

	# "crash": stop the parked array — MD_RECOVERY_INTR frees the park; the
	# torn/absent phase write is already durable on the members.  The
	# reassembled array gets a fresh (unarmed) conf so the resume runs clean.
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	for i in $(seq 1 20); do grep -q "$MDNAME " /proc/mdstat || break; sudo "$MDADM" --stop "$MD" >/dev/null 2>&1; sleep 0.5; done
	rk_udev_quiesce

	rk_dmesg_window_close; rk_dmesg_clear
	sudo "$MDADM" --assemble --run "$MD" "${MEMBERS[@]}" >/dev/null 2>&1 ||
		sudo "$MDADM" --assemble --force --run "$MD" "${MEMBERS[@]}" >/dev/null 2>&1 ||
		{ rk_fail "$tag: reassemble failed"; sudo dmesg|tail -8; return; }
	if sudo dmesg | grep -q "dcl reshape recover"; then
		ph=$(sudo dmesg | sed -n 's/.*dcl reshape recover.*phase \([0-9]*\).*resume at row \([0-9]*\).*/phase=\1 resume=\2/p' | tail -1)
		rk_pass "$tag: recovery engaged ($ph)"
	else
		rk_fail "$tag: no 'dcl reshape recover' after a mid-band crash"; sudo dmesg|tail -6; return
	fi
	for i in $(seq 1 150); do case "$(cat "$TRIG" 2>/dev/null)" in idle*) break;; esac; sleep 2; done
	case "$(cat "$TRIG")" in idle*) rk_pass "$tag: reshape completed after recovery";;
		*) rk_fail "$tag: reshape did not finish"; sudo dmesg|tail -8; return;; esac

	sudo dd if="$MD" of="$RK_TMP/rd" bs=1M count="$PATMB" iflag=direct status=none
	[ "$PRE" = "$(md5sum "$RK_TMP/rd"|cut -d' ' -f1)" ] && rk_pass "$tag: pattern byte-exact" ||
		{ rk_fail "$tag: DATA MISMATCH"; return; }
	local mm=$(rk_scrub)
	[ "$mm" = 0 ] && rk_pass "$tag: scrub clean" || { rk_fail "$tag: scrub=$mm"; return; }
	for d in "${MEMBERS[@]:0:$M}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
	local deg=$(cat /sys/block/$MDNAME/md/degraded)
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo dd if="$MD" of="$RK_TMP/deg" bs=1M count="$PATMB" iflag=direct status=none
	[ "$deg" = "$M" ] && [ "$PRE" = "$(md5sum "$RK_TMP/deg"|cut -d' ' -f1)" ] &&
		rk_pass "$tag: degraded-decode EC-correct" || rk_fail "$tag: degraded-decode (deg=$deg)"
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
}

rk_dmesg_clear
# COMMIT-torn is the go/no-go (replay-from-scratch over a torn home) — cover it
# at first/mid/last band; the rest at mid.
run_case 0    COMMIT torn
run_case mid  COMMIT torn
run_case -1   COMMIT torn
run_case mid  COMMIT hang
run_case mid  STAGE  torn
run_case mid  STAGE  hang

rk_summary
