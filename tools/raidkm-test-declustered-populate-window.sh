#!/bin/bash
#
# raidkm-test-declustered-populate-window.sh — population backpressure gate.
#
# Declustered population used to DROP any completion more than the window
# (RKDCL_REB_WINDOW, 64 MiB) past the oldest unfinished address.  One slow
# stripe then stopped the population mark for the rest of the pass and md
# re-scanned the device forever.  Reaching that naturally takes a large, fast
# member — at 600 MiB/s the window is a tenth of a second — so ramdisk gates
# never saw it.  raidkm_dcl_pop_window shrinks the window when an array is
# loaded, which makes the sync thread wait in raidkm_dcl_pop_admit() almost
# constantly even on brd: the path the fix added, exercised on every run.
#
# For rk_bio_sort 0 and 2 (2 parks sync bios in the ordered-submission queue,
# the amplifier that made the original stall near-certain):
#   T1  population completes ("populated") within POP_TIMEOUT;
#   T2  everything written before the failure reads back byte-exact;
#   T3  a full check scrub afterwards is clean (mismatch_cnt 0);
#   T4  no WARN from raidkm_dcl_pop_done (the invariant check) or anywhere;
#   T6  the backpressure wait actually ran (rk_dcl_populate "waits N") — a
#       pass that never waited would prove nothing about the fix.  Hard for
#       mode 2, where the ordered-submission queue makes waiting all but
#       certain; reported for mode 0, where brd may simply be too fast.
# Then T5: with population throttled and in progress, `mdadm --stop` returns
# promptly and a re-assemble resumes population and completes it, data intact.
# T7: a pass that starts ABOVE the mark (a leftover sync_min; md also resumes an
#     interrupted repair at curr_resync_completed) must not wait forever for
#     addresses it will never issue — population still completes.
# T8: an address population cannot reconstruct (bad blocks on every other
#     member) must PAUSE it with an error: the pass ends, raid5d does not
#     re-request it in a loop, a manual repair retries once and pauses again,
#     and stop stays prompt.  Before this, the same array waited forever.
#     T8b repeats it at the default window, where the sync thread is still
#     issuing past the failed address when the failure lands.
# T9: a failure that goes away.  Once the retried address reconstructs, the
#     pause must be LIFTED: interrupt the retry past that address and raid5d
#     must pick population up again by itself and finish it.
#
# Usage: bash <this>   (POP_WINDOW, POP_TIMEOUT, DCL_N/G/M/SC to override)
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-12}; G=${DCL_G:-10}; M=${DCL_M:-2}; SC=${DCL_SC:-2}
WIN=${POP_WINDOW:-128}			# granules = 512 KiB: tiny on purpose
POP_TIMEOUT=${POP_TIMEOUT:-300}
STOP_BOUND=${STOP_BOUND:-20}		# seconds mdadm --stop may take
PATMB=${PATMB:-48}
PARAM=/sys/module/raidkm/parameters/raidkm_dcl_pop_window
OLDWIN=""
MEMBERS=()

cleanup() {
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	[ -n "$OLDWIN" ] && echo "$OLDWIN" | sudo tee "$PARAM" >/dev/null 2>&1
	local d
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" >/dev/null 2>&1
	done
}
trap cleanup EXIT

rk_load_modules || exit 1
[ -w "$PARAM" ] || { echo "ERROR: loaded raidkm has no raidkm_dcl_pop_window (a pre-fix module?)" >&2; exit 1; }
OLDWIN=$(cat "$PARAM")
echo "$WIN" | sudo tee "$PARAM" >/dev/null
rk_setup_brd "$N" || exit 1
DISKS=$(rk_pick_disks "$N") || { echo "ERROR: need $N devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"
VICTIM="${MEMBERS[$((N - 1))]}"
mdsys() { echo "/sys/block/$MDNAME/md/$1"; }

create_dcl() {		# fresh declustered array, initial resync allowed to finish
	rk_stop
	[ -e "$MD" ] && [ ! -b "$MD" ] && sudo rm -f "$MD"
	local d
	for d in "${MEMBERS[@]}"; do
		sudo dd if=/dev/zero of="$d" bs=1M count=4 status=none 2>/dev/null
	done
	printf 'y\n' | sudo "$MDADM" --create "$MD" --level=raidkm --parity-count="$M" \
		--layout=declustered --group-width="$G" --spare-columns="$SC" \
		--raid-devices="$N" --chunk="$CHUNK_KB" --bitmap=none --run --force \
		"${MEMBERS[@]}" >/dev/null 2>&1 || return 1
	rk_wait_idle
}
write_pattern() {
	dd if=/dev/urandom of="$RK_TMP/popwin-pat" bs=1M count="$PATMB" status=none
	sudo dd if="$RK_TMP/popwin-pat" of="$MD" bs=1M oflag=direct status=none
	sync
	PRE=$(md5sum "$RK_TMP/popwin-pat" | cut -d' ' -f1)
}
read_md5() {
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null |
		md5sum | cut -d' ' -f1
}
arm_population() {	# the Test-7 sequence: a bare --fail does NOT arm it
	local slot
	slot=$(sudo "$MDADM" --detail "$MD" | awk -v v="$VICTIM" \
		'$0 ~ v && $1 ~ /^[0-9]+$/ {print $4; exit}')
	[ -n "$slot" ] || return 1
	sudo "$MDADM" --fail "$MD" "$VICTIM" >/dev/null 2>&1
	sudo "$MDADM" --remove "$MD" "$VICTIM" >/dev/null 2>&1
	echo "$slot" | sudo tee "$(mdsys rk_dcl_populate)" >/dev/null 2>&1
	case "$(cat "$(mdsys rk_dcl_populate)" 2>/dev/null)" in
		populating*|populated*) return 0 ;;
	esac
	return 1
}
wait_populated() {	# 0 once "populated" within POP_TIMEOUT
	local i
	for i in $(seq 1 $((POP_TIMEOUT * 2))); do
		case "$(cat "$(mdsys rk_dcl_populate)" 2>/dev/null)" in
			populated*) return 0 ;;
		esac
		sleep 0.5
	done
	return 1
}
warns() { sudo dmesg | grep -cE "raidkm_dcl_pop_done|WARNING:|BUG:|blocked for more than"; }

echo "  window: raidkm_dcl_pop_window=$(cat "$PARAM") granules (chunk ${CHUNK_KB} KiB, N=$N g=$G m=$M s=$SC)"

for mode in 0 2; do
	echo "=== rk_bio_sort=$mode: population under constant backpressure ==="
	create_dcl || { rk_fail "mode $mode: create declustered array"; continue; }
	echo "$mode" | sudo tee "$(mdsys rk_bio_sort)" >/dev/null
	write_pattern
	sudo dmesg -C
	arm_population || { rk_fail "mode $mode: population did not arm"; continue; }
	t0=$(date +%s)
	if wait_populated; then
		rk_pass "T1 mode $mode: population completed in $(( $(date +%s) - t0 ))s"
	else
		rk_fail "T1 mode $mode: population did not complete in ${POP_TIMEOUT}s ($(cat "$(mdsys rk_dcl_populate)" 2>&1))"
		continue
	fi
	POST=$(read_md5)
	[ "$POST" = "$PRE" ] && rk_pass "T2 mode $mode: data intact after population" \
			     || rk_fail "T2 mode $mode: data changed ($PRE -> $POST)"
	echo check | sudo tee "$(mdsys sync_action)" >/dev/null
	sleep 1; rk_wait_idle
	mm=$(cat "$(mdsys mismatch_cnt)" 2>/dev/null)
	[ "$mm" = 0 ] && rk_pass "T3 mode $mode: scrub clean after population" \
		      || rk_fail "T3 mode $mode: scrub mismatch_cnt=$mm"
	w=$(warns)
	[ "$w" = 0 ] && rk_pass "T4 mode $mode: no WARN/BUG/hung task" \
		     || rk_fail "T4 mode $mode: $w WARN/BUG/hung-task line(s) in dmesg"
	waits=$(sed -n 's/.*waits \([0-9][0-9]*\).*/\1/p' "$(mdsys rk_dcl_populate)" 2>/dev/null)
	rows=$(sed -n 's/^row rows \([0-9][0-9]*\).*/\1/p' "$(mdsys rk_dcl_populate)" 2>/dev/null)
	if [ -z "$waits" ]; then
		rk_fail "T6 mode $mode: rk_dcl_populate reports no backpressure wait count"
	elif [ -n "${rows:-}" ] && [ "$rows" -gt 0 ]; then
		# rk_dcl_row_rebuild: the row engine completes each row before
		# the next is admitted, so the pop window is never short and
		# the backpressure path this check exists for is not the one in
		# use.  It still gates the stripe arm, which is where the
		# mark-stall fix lives.
		rk_skip_check "T6 mode $mode: population ran on the row engine ($rows rows), which cannot outrun its own completions"
	elif [ "$mode" = 2 ]; then
		[ "$waits" -gt 0 ] \
			&& rk_pass "T6 mode $mode: backpressure wait exercised ($waits waits)" \
			|| rk_fail "T6 mode $mode: backpressure never engaged (0 waits) — not exercising the fix"
	else
		rk_log "mode $mode: $waits backpressure waits (informational)"
	fi
done

echo "=== T5: stop mid-population, re-assemble, resume ==="
if create_dcl; then
	echo 2 | sudo tee "$(mdsys rk_bio_sort)" >/dev/null
	write_pattern
	sudo dmesg -C
	echo 2000 | sudo tee "$(mdsys sync_speed_max)" >/dev/null
	if arm_population; then
		sleep 3
		st=$(cat "$(mdsys rk_dcl_populate)" 2>/dev/null)
		case "$st" in
			populating*) rk_log "stopping during: $st" ;;
			*) rk_log "note: population state before stop was '$st' (not mid-flight)" ;;
		esac
		t0=$(date +%s)
		sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
		el=$(( $(date +%s) - t0 ))
		[ ! -e "/sys/block/$MDNAME/md" ] && [ "$el" -le "$STOP_BOUND" ] \
			&& rk_pass "T5: mdadm --stop returned in ${el}s during population" \
			|| rk_fail "T5: mdadm --stop took ${el}s or did not stop the array"
		if rk_assemble "${MEMBERS[@]:0:$((N - 1))}"; then
			if wait_populated; then
				rk_pass "T5: re-assembled population resumed and completed"
				POST=$(read_md5)
				[ "$POST" = "$PRE" ] && rk_pass "T5: data intact after resume" \
						     || rk_fail "T5: data changed after resume ($PRE -> $POST)"
			else
				rk_fail "T5: resumed population did not complete ($(cat "$(mdsys rk_dcl_populate)" 2>&1))"
			fi
		else
			rk_fail "T5: re-assemble failed"
		fi
		w=$(warns)
		[ "$w" = 0 ] && rk_pass "T5: no WARN/BUG/hung task" \
			     || rk_fail "T5: $w WARN/BUG/hung-task line(s) in dmesg"
	else
		rk_fail "T5: population did not arm"
	fi
else
	rk_fail "T5: create declustered array"
fi

cs=$((CHUNK_KB * 2))			# chunk in sectors

echo "=== T7: a pass that starts above the mark (leftover sync_min) ==="
if create_dcl; then
	write_pattern
	sudo dmesg -C
	comp=$(cat "$(mdsys component_size)")			# KiB = half the member in sectors
	sm=$(( comp / cs * cs ))				# sync_min must be chunk-aligned
	echo "$sm" | sudo tee "$(mdsys sync_min)" >/dev/null
	rk_log "sync_min=$(cat "$(mdsys sync_min)") of $((comp * 2)) sectors"
	if arm_population && wait_populated; then
		rk_pass "T7: population completed although the pass started past the mark"
	else
		rk_fail "T7: population did not complete with sync_min set ($(cat "$(mdsys rk_dcl_populate)" 2>&1 | tr '\n' ' '))"
	fi
	POST=$(read_md5)
	[ "$POST" = "$PRE" ] && rk_pass "T7: data intact" || rk_fail "T7: data changed ($PRE -> $POST)"
	w=$(warns)
	[ "$w" = 0 ] && rk_pass "T7: no WARN/BUG/hung task" || rk_fail "T7: $w WARN/BUG/hung-task line(s)"
else
	rk_fail "T7: create declustered array"
fi

t8_unreconstructable() {	# $1 = label, $2 = bad-block sector; the window in force at create applies
echo "=== $1: an address population cannot reconstruct (window $(cat "$PARAM") granules) ==="
if create_dcl; then
	write_pattern
	sudo dmesg -C
	BADS=${2:-$((cs * 32))}				# chunk-aligned bad-block sector
	BADLEN=$cs
	if [ "$BADS" = end ]; then
		# The last rows before the device end, the last one two chunks
		# short of it.  One row is not enough: population skips a row
		# where the victim holds a spare column (nothing of it lives
		# there), and which row that is depends on the member size — at
		# 256 MiB members the single row two chunks from the end is such
		# a row.  In this suite's geometry (12 disks, g=10, s=2, mdadm's
		# seed search) no disk holds a spare column more than 2 rows in a
		# row (tools/declustered-sim.c --rowmap), so population meets the
		# failure in one of these eight.
		BADLEN=$((cs * 8))
		BADS=$(( ($(cat "$(mdsys component_size)") * 2 / cs - 9) * cs ))
	fi
	for d in "${MEMBERS[@]:0:$((N - 1))}"; do		# every member but the victim
		echo "$BADS $BADLEN" | sudo tee "$(mdsys "dev-$(basename "$d")/bad_blocks")" >/dev/null 2>&1
	done
	rk_log "bad block '$(cat "$(mdsys "dev-$(basename "${MEMBERS[0]}")/bad_blocks")" 2>&1 | head -1)' on $((N - 1)) members"
	if arm_population; then
		paused=0
		for i in $(seq 1 $((POP_TIMEOUT * 2))); do
			grep -q "^paused" "$(mdsys rk_dcl_populate)" 2>/dev/null && { paused=1; break; }
			grep -q "^populated" "$(mdsys rk_dcl_populate)" 2>/dev/null && break
			sleep 0.5
		done
		[ $paused = 1 ] && rk_pass "$1: population paused at the unreconstructable address" \
				|| rk_fail "$1: population did not pause ($(cat "$(mdsys rk_dcl_populate)" 2>&1 | tr '\n' ' '))"
		sleep 5
		a1=$(cat "$(mdsys sync_action)"); c1=$(sudo dmesg | grep -c "cannot reconstruct")
		sleep 10
		a2=$(cat "$(mdsys sync_action)"); c2=$(sudo dmesg | grep -c "cannot reconstruct")
		if [ "$a1" = idle ] && [ "$a2" = idle ] && [ "$c2" = "$c1" ]; then
			rk_pass "$1: the pass ended and was not re-requested ($c2 error line(s))"
		else
			rk_fail "$1: sync_action $a1 -> $a2, error lines $c1 -> $c2 (a hang or a re-scan loop)"
		fi
		c3=$(sudo dmesg | grep -c "cannot reconstruct")
		echo repair | sudo tee "$(mdsys sync_action)" >/dev/null
		ok=0
		for i in $(seq 1 120); do
			sleep 0.5
			[ "$(sudo dmesg | grep -c "cannot reconstruct")" -gt "$c3" ] && \
			[ "$(cat "$(mdsys sync_action)")" = idle ] && \
				grep -q "^paused" "$(mdsys rk_dcl_populate)" 2>/dev/null && { ok=1; break; }
		done
		[ $ok = 1 ] && rk_pass "$1: the FIRST manual repair really retried the address, paused again, no hang" \
			    || rk_fail "$1: one manual repair: error lines $c3 -> $(sudo dmesg | grep -c "cannot reconstruct"), sync_action=$(cat "$(mdsys sync_action)"), $(cat "$(mdsys rk_dcl_populate)" 2>&1 | tr '\n' ' ')"
		t0=$(date +%s)
		sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
		el=$(( $(date +%s) - t0 ))
		[ ! -e "/sys/block/$MDNAME/md" ] && [ "$el" -le "$STOP_BOUND" ] \
			&& rk_pass "$1: stop returned in ${el}s" || rk_fail "$1: stop took ${el}s or did not stop"
		w=$(sudo dmesg | grep -cE "raidkm_dcl_pop_done|WARNING:|BUG:|blocked for more than")
		[ "$w" = 0 ] && rk_pass "$1: no WARN/BUG/hung task" || rk_fail "$1: $w WARN/BUG/hung-task line(s)"
	else
		rk_fail "$1: population did not arm"
	fi
else
	rk_fail "$1: create declustered array"
fi
}
t8_unreconstructable T8
# T8b — the production race: at the default window the sync thread is still
# issuing past the failed address when the failure lands (not parked in the
# admit wait as it is with the tiny window), which is where a mid-pass gap
# check once lifted the pause and looped.
echo 16384 | sudo tee "$PARAM" >/dev/null
t8_unreconstructable T8b
echo "$WIN" | sudo tee "$PARAM" >/dev/null
# T8c — the failure sits two chunks before the end of the device: the failing
# pass can run to the end before the abort lands, md then resumes a repair AT
# the end so its loop never runs, and the first repair used to change nothing.
t8_unreconstructable T8c end

echo "=== T9: a transient failure: the reconstruct lifts the pause ==="
# SKIPPED — no working transient-failure mechanism on this rig yet.
#
# What it must prove: once a paused population's unreconstructable address
# later DOES reconstruct, the pause lifts (raidkm_dcl_pop_resolve), and a pass
# interrupted right after that is picked up again by raid5d by itself
# (raidkm_dcl_pop_paused derives "paused" from state instead of the flag).
#
# Why md bad blocks cannot drive it: they cannot be cleared on a running array.
# badblocks_store() only SETS (a non-positive length is -EINVAL),
# rdev_clear_badblocks() runs only after a successful write (R5_MadeGood), and
# with acknowledged bad blocks on more columns than parity covers,
# analyse_stripe() counts those devices failed for writes too, so the rewrite
# fails at that address and never clears them (seen: all 11 kept).  A
# stop/assemble (mdadm --update=force-no-bbl) would clear them but also resets
# the in-memory pause this test exists to examine.
#
# Workable mechanisms, not built: dm-dust under the members (bad blocks on
# reads, `dmsetup message <dev> 0 disable` makes them good at runtime), or a
# population fault-injection parameter that fails a chosen address N times.
rk_log "T9 SKIPPED: needs a transient-failure mechanism (md bad blocks cannot be cleared online) — see the comment in this test"

rk_summary
