#!/bin/bash
# raidkm-test-row-rebuild-load.sh — row rebuild under a degraded-read load.
#
# HRT's X4000 runs rebuilt a spare while fio read the degraded array
# sequentially, and ~80% of the rebuild reached the spare as 4 KiB stripe-path
# writes with rebuild_declined almost unchanged.  The row rebuild allocated its
# chunk-sized buffers per band; a band that could not get them returned no
# progress without counting anything, and md then walked that whole chunk
# through the stripe cache.  The buffers now live for the recovery pass (a
# folio each, or order-0 pages mapped contiguously when no folio is
# available), and every chunk that leaves the row path is counted.
#
# What this proves (8+2 rotating, 128 KiB chunk, a sequential read running on
# the degraded array for the whole rebuild):
#   T1  the rebuild completes and rk_row_stats accounts for every whole chunk
#       of the member: rebuild_done + rebuild_stripe_chunks == member chunks
#   T2  no band went without buffers (rebuild_band_nomem unchanged), and at
#       least 75% of the chunks were rebuilt as whole rows (a row busy with
#       foreground I/O is correctly left to the stripe cache)
#   T3  the rebuilt member holds the data: a different member failed, the
#       array reads back byte for byte; scrub reports 0 mismatches
#   T4  T1-T3 again with the rebuild buffers forced into page form
#       (debug_row_rebuild_pages=Y), and the set really used page buffers
#   T5  no kernel report in either pass
#   T7  rk_row_rebuild_workers is live: a pass at 16 rebuild rows in flight
#       reports 16 in rk_row_stats (rebuild_set_workers) and rebuilds the
#       member correctly; out-of-range values are refused
#   T8  rk_row_rebuild_pace caps the rebuild at its own KB/s rate while the
#       array carries foreground I/O.  md's rate control cannot: it slows a
#       sync down by waiting for recovery_active to drain, and a band reports
#       its progress before sync_request returns, so there is never anything
#       in flight for md to wait on.  With the knob set, a rebuild under a
#       foreground load stays near that rate; with it 0 the same pass runs
#       several times faster
#   T9  pacing to a rate the array cannot reach does not slow it down: the
#       budget runs from when a band started, not from when it finished, so a
#       band already slower than the cap sleeps not at all (adding the budget
#       to the completion time instead cut a 34 MiB/s rebuild to 22.6 under an
#       unreachable 50 MB/s cap on 8+2 NVMe)
#   T6  a third pass turns rk_row_rebuild off for a second at a quarter of a
#       throttled rebuild while the foreground reads through the stripe cache
#       (rk_row_dread=0), so the stripe path's windows are cut short and md's
#       cursor leaves the chunk grid.  Once the knob is back, at least half of
#       the chunks still to go must be rebuilt as rows.  Before the stripe
#       window stopped at the chunk boundary, a cursor off the grid stayed off
#       and no row was rebuilt for the rest of the pass (0 rows after the
#       toggle; the same one-way switch an 8+2 QLC array showed after its
#       first declined row under a 37 GB/s degraded read)
#
# Usage: bash <this>     (MDADM etc. via raidkm-test-lib.sh)
set -u
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=10
CHUNK_KB=128
DATAMB=${DATAMB:-192}
MEMBERS=()
FIOPID=
P=/sys/module/raidkm/parameters

cleanup() {
	[ -n "$FIOPID" ] && kill "$FIOPID" 2>/dev/null
	[ -w $P/debug_row_rebuild_pages ] && echo N > $P/debug_row_rebuild_pages
	[ -w "/sys/block/$MDNAME/md/rk_row_rebuild_pace" ] &&
		echo 0 > "/sys/block/$MDNAME/md/rk_row_rebuild_pace"
	[ -w "/sys/block/$MDNAME/md/rk_row_rebuild_workers" ] &&
		echo 8 > "/sys/block/$MDNAME/md/rk_row_rebuild_workers"
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	local d
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
}
trap cleanup EXIT

command -v fio >/dev/null || { echo "ERROR: fio not installed" >&2; exit 1; }

stat_of() { awk -v k="$1" '$1 == k {print $2}' "/sys/block/$MDNAME/md/rk_row_stats"; }

# one pass: fail member 3, rebuild onto the spare under a sequential read
run_pass() {	# tag pages(Y|N) toggle(0|1)
	local tag=$1 pages=$2 toggle=${3:-0} spare victim=${MEMBERS[3]} done0 sc0 d sc chunks secs max_pb=0 pb
	local tog_done= tog_pct= pct
	spare=${MEMBERS[$N]}

	[ -w $P/debug_row_rebuild_pages ] || { rk_fail "$tag: raidkm lacks debug_row_rebuild_pages"; return; }
	echo "$pages" > $P/debug_row_rebuild_pages
	rk_create 2r "${MEMBERS[@]:0:$N}" || { rk_fail "$tag: create"; return; }
	echo "$(cat "/sys/block/$MDNAME/md/rk_row_rebuild")" | grep -q 1 || { rk_fail "$tag: rk_row_rebuild is off"; return; }
	rk_write "$DATAMB"
	rk_fail_disks "$victim"; rk_remove_disks "$victim"
	if [ "$toggle" = 1 ]; then
		# slow enough to switch the knob mid-pass; reads through the stripe
		# cache, so the stripe path's windows are cut short
		echo 1000 > "/sys/block/$MDNAME/md/sync_speed_min"
		echo 10000 > "/sys/block/$MDNAME/md/sync_speed_max"
		echo 0 > "/sys/block/$MDNAME/md/rk_row_dread"
	else
		echo 2000000 > "/sys/block/$MDNAME/md/sync_speed_min"
	fi
	done0=$(stat_of rebuild_done); sc0=$(stat_of rebuild_stripe_chunks); nm0=$(stat_of rebuild_band_nomem)

	# the foreground: sequential 1 MiB reads over the written region, looping
	fio --name=fg --filename="$MD" --rw=read --bs=1M --direct=1 --ioengine=libaio \
		--iodepth=8 --numjobs=2 --size="${DATAMB}M" --time_based --runtime=3600 \
		$([ "$toggle" = 1 ] && echo --rate=40m) >/dev/null 2>&1 &
	FIOPID=$!
	sleep 2
	rk_dmesg_clear
	sudo dd if=/dev/zero of="$spare" bs=1M count=4 status=none 2>/dev/null
	rk_add_disks "$spare"
	# wait for the recovery to start, then for the array to be whole: a
	# "no recovery line yet" read as "finished" let T3 fail a member into a
	# rebuild that had not begun
	for secs in $(seq 100); do
		grep -q recovery /proc/mdstat && break
		[ "$(cat "/sys/block/$MDNAME/md/degraded")" = 0 ] && break
		sleep 0.1
	done
	secs=0
	while [ "$(cat "/sys/block/$MDNAME/md/degraded")" != 0 ]; do
		pb=$(stat_of rebuild_set_page_bufs); [ "${pb:-0}" -gt "$max_pb" ] && max_pb=$pb
		if [ "$toggle" = 1 ] && [ -z "$tog_done" ]; then
			pct=$(grep -o 'recovery = *[0-9]*' /proc/mdstat | grep -o '[0-9]*$')
			if [ "${pct:-0}" -ge 25 ]; then
				echo 0 > "/sys/block/$MDNAME/md/rk_row_rebuild"
				sleep 1
				echo 1 > "/sys/block/$MDNAME/md/rk_row_rebuild"
				tog_done=$(stat_of rebuild_done)
				tog_pct=$(grep -o 'recovery = *[0-9]*' /proc/mdstat | grep -o '[0-9]*$')
			fi
		fi
		sleep 0.2; secs=$((secs + 1))
		[ "$secs" -gt 6000 ] && break
	done
	kill "$FIOPID" 2>/dev/null; wait "$FIOPID" 2>/dev/null; FIOPID=
	# the gauge keeps describing the last set built, so a rebuild that ends
	# before the first poll still shows it
	pb=$(stat_of rebuild_set_page_bufs); [ "${pb:-0}" -gt "$max_pb" ] && max_pb=$pb

	d=$(( $(stat_of rebuild_done) - done0 ))
	sc=$(( $(stat_of rebuild_stripe_chunks) - sc0 ))
	# md rebuilds component_size (KiB), which it keeps a multiple of the chunk
	chunks=$(( $(cat "/sys/block/$MDNAME/md/component_size") / CHUNK_KB ))
	if grep -q "recovery" /proc/mdstat || [ "$(rk_geom)" != "[$N/$N]" ]; then
		rk_fail "$tag T1: rebuild did not complete ($(rk_geom))"
	elif [ "$toggle" = 1 ]; then
		# chunks rebuilt while the knob was off are counted nowhere, by design
		rk_log "$tag T1: not applicable (rk_row_rebuild was off for part of the pass): rebuild_done $d + stripe_chunks $sc of $chunks"
	elif [ $((d + sc)) -eq "$chunks" ]; then
		rk_pass "$tag T1: counters cover the member: rebuild_done $d + stripe_chunks $sc of $chunks chunks"
	else
		rk_fail "$tag T1: counters do not cover the member: rebuild_done $d + stripe_chunks $sc vs $chunks chunks (band_nomem $(stat_of rebuild_band_nomem))"
	fi
	nm=$(( $(stat_of rebuild_band_nomem) - nm0 ))
	[ "$nm" = 0 ] && rk_pass "$tag T2: no band went without buffers" \
		|| rk_fail "$tag T2: $nm band(s) found no buffer set"
	if [ "$toggle" = 1 ]; then
		local after left
		after=$(( $(stat_of rebuild_done) - ${tog_done:-0} ))
		left=$(( chunks * (100 - ${tog_pct:-100}) / 100 ))
		if [ -z "$tog_done" ]; then
			rk_fail "$tag T6: the rebuild finished before the knob could be switched"
		elif [ $((after * 2)) -ge "$left" ]; then
			rk_pass "$tag T6: $after of ~$left remaining chunks rebuilt as rows after rk_row_rebuild came back (switched at ${tog_pct}%)"
		else
			rk_fail "$tag T6: only $after of ~$left remaining chunks rebuilt as rows after rk_row_rebuild came back (switched at ${tog_pct}%)"
		fi
	elif [ "$chunks" -gt 0 ] && [ $((d * 100 / chunks)) -ge 75 ]; then
		rk_pass "$tag T2: $((d * 100 / chunks))% of chunks rebuilt as whole rows"
	else
		rk_fail "$tag T2: only $d of $chunks chunks rebuilt as whole rows"
	fi
	if [ "$pages" = Y ]; then
		[ "$max_pb" -gt 0 ] && rk_pass "$tag T4: rebuild set used $max_pb page-form buffers" \
			|| rk_fail "$tag T4: forced page form, but the set reported no page buffers"
	fi

	# the rebuilt member must hold the data: fail a different one, read back
	rk_fail_disks "${MEMBERS[5]}"
	rk_readback "$DATAMB" && rk_pass "$tag T3: data reads back through the rebuilt member" \
		|| rk_fail "$tag T3: data differs with the rebuilt member serving"
	rk_remove_disks "${MEMBERS[5]}"
	sudo dd if=/dev/zero of="${MEMBERS[5]}" bs=1M count=4 status=none 2>/dev/null
	rk_add_disks "${MEMBERS[5]}"
	sleep 1; rk_wait_idle
	mm=$(rk_scrub)
	[ "$mm" = 0 ] && rk_pass "$tag T3: scrub mismatch_cnt 0" || rk_fail "$tag T3: scrub mismatch_cnt $mm"
	rk_dmesg_clean && rk_pass "$tag T5: no kernel report" || rk_fail "$tag T5: kernel report"
	echo N > $P/debug_row_rebuild_pages
	rk_stop
	local x
	for x in "${MEMBERS[@]}"; do sudo "$MDADM" --zero-superblock "$x" 2>/dev/null; done
	# the victim comes back as the next pass's spare
	MEMBERS=("${MEMBERS[@]:0:3}" "$spare" "${MEMBERS[@]:4:$((N - 4))}" "$victim")
}


# T7/T8: the rebuild-concurrency knob and our own sync_speed_min pacing.
# One pass each, timed, under the same sequential read load.  PACE_RATE carries
# the measured MiB/s out to the caller.
PACE_RATE=
run_knob_pass() {	# tag workers pace_kb
	local tag=$1 workers=$2 pace=$3
	local spare victim=${MEMBERS[3]} secs elapsed chunks kib rate setw
	spare=${MEMBERS[$N]}

	rk_create 2r "${MEMBERS[@]:0:$N}" || { rk_fail "$tag: create"; return; }
	local knob="/sys/block/$MDNAME/md/rk_row_rebuild_workers"
	local pknob="/sys/block/$MDNAME/md/rk_row_rebuild_pace"
	[ -w "$knob" ] && [ -w "$pknob" ] || { rk_fail "$tag: raidkm lacks the rebuild knobs"; rk_stop; return; }
	if [ "$pace" != 0 ]; then
		# only what a store refuses proves the range check, so test it once
		if echo 0 > "$knob" 2>/dev/null || echo 65 > "$knob" 2>/dev/null; then
			rk_fail "$tag T7: rk_row_rebuild_workers accepted an out-of-range value"
		else
			rk_pass "$tag T7: rk_row_rebuild_workers refuses 0 and 65"
		fi
	fi
	echo "$workers" > "$knob" || { rk_fail "$tag: cannot set $workers workers"; rk_stop; return; }
	echo "$pace" > "$pknob"
	rk_write "$DATAMB"
	rk_fail_disks "$victim"; rk_remove_disks "$victim"
	# md's own limits stay out of the way: this tests our own rate
	echo 2000000 > "/sys/block/$MDNAME/md/sync_speed_min"
	echo 2000000 > "/sys/block/$MDNAME/md/sync_speed_max"

	fio --name=fg --filename="$MD" --rw=read --bs=1M --direct=1 --ioengine=libaio \
		--iodepth=8 --numjobs=2 --size="${DATAMB}M" --time_based --runtime=3600 \
		>/dev/null 2>&1 &
	FIOPID=$!
	sleep 2
	rk_dmesg_clear
	sudo dd if=/dev/zero of="$spare" bs=1M count=4 status=none 2>/dev/null
	rk_add_disks "$spare"
	for secs in $(seq 100); do
		grep -q recovery /proc/mdstat && break
		[ "$(cat "/sys/block/$MDNAME/md/degraded")" = 0 ] && break
		sleep 0.1
	done
	local t0=$(date +%s%N)
	secs=0
	setw=0
	while [ "$(cat "/sys/block/$MDNAME/md/degraded")" != 0 ]; do
		[ "$setw" = 0 ] && setw=$(stat_of rebuild_set_workers)
		sleep 0.2; secs=$((secs + 1))
		[ "$secs" -gt 6000 ] && break
	done
	elapsed=$(( ($(date +%s%N) - t0) / 1000000 ))	# ms
	[ "$elapsed" -lt 1 ] && elapsed=1
	kill "$FIOPID" 2>/dev/null; wait "$FIOPID" 2>/dev/null; FIOPID=
	[ "${setw:-0}" = 0 ] && setw=$(stat_of rebuild_set_workers)

	kib=$(cat "/sys/block/$MDNAME/md/component_size")
	chunks=$((kib / CHUNK_KB))
	# MiB/s from milliseconds, so a sub-second pass is still measured
	rate=$(awk -v k="$kib" -v ms="$elapsed" 'BEGIN{printf "%d", k * 1000 / 1024 / ms}')
	PACE_RATE=$rate
	if grep -q recovery /proc/mdstat || [ "$(rk_geom)" != "[$N/$N]" ]; then
		rk_fail "$tag T7: rebuild did not complete ($(rk_geom))"
	elif [ "$pace" != 0 ]; then
		[ "${setw:-0}" = "$workers" ] &&
			rk_pass "$tag T7: rebuild_set_workers $setw with rk_row_rebuild_workers $workers ($chunks chunks in ${elapsed}ms)" ||
			rk_fail "$tag T7: rebuild_set_workers $setw with rk_row_rebuild_workers $workers"
	fi

	# the rebuilt member must hold the data at this worker count too
	rk_fail_disks "${MEMBERS[5]}"
	rk_readback "$DATAMB" && rk_pass "$tag T7: data reads back through the rebuilt member" \
		|| rk_fail "$tag T7: data differs with the rebuilt member serving"
	rk_remove_disks "${MEMBERS[5]}"
	sudo dd if=/dev/zero of="${MEMBERS[5]}" bs=1M count=4 status=none 2>/dev/null
	rk_add_disks "${MEMBERS[5]}"
	sleep 1; rk_wait_idle
	local mm
	mm=$(rk_scrub)
	[ "$mm" = 0 ] && rk_pass "$tag T7: scrub mismatch_cnt 0" || rk_fail "$tag T7: scrub mismatch_cnt $mm"
	rk_dmesg_clean && rk_pass "$tag T7: no kernel report" || rk_fail "$tag T7: kernel report"
	echo 0 > "$pknob"
	echo 8 > "$knob"
	rk_stop
	local x
	for x in "${MEMBERS[@]}"; do sudo "$MDADM" --zero-superblock "$x" 2>/dev/null; done
	MEMBERS=("${MEMBERS[@]:0:3}" "$spare" "${MEMBERS[@]:4:$((N - 4))}" "$victim")
}

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
rk_setup_brd $((N + 1)) || exit 1
DISKS=$(rk_pick_disks $((N + 1))) || { echo "ERROR: need $((N + 1)) devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

echo "== row rebuild under a degraded sequential read (8+2 rotating, ${CHUNK_KB}K chunk)"
run_pass "folio" N 0
run_pass "pages" Y 0
run_pass "toggle" N 1

# T7/T8: 16 rebuild rows in flight, capped at 8 MiB/s, then the same pass
# uncapped.  This rate is what md's own knobs cannot enforce here.
PACE_KB=8000
run_knob_pass "paced" 16 "$PACE_KB"
paced=$PACE_RATE
run_knob_pass "unpaced" 16 0
unpaced=$PACE_RATE
# a rate far above what the array can do must cost nothing
run_knob_pass "pace-highrate" 16 2000000
highfloor=$PACE_RATE
floor_mb=$((PACE_KB / 1024))
if [ -z "$highfloor" ] || [ -z "$unpaced" ]; then
	rk_fail "T9: a pass did not report a rate (unpaced '${unpaced:-}', high rate '${highfloor:-}')"
elif [ "$highfloor" -ge $((unpaced * 3 / 4)) ]; then
	rk_pass "T9: pacing to an unreachable rate left it alone: $highfloor vs $unpaced MiB/s uncapped"
else
	rk_fail "T9: pacing to an unreachable rate slowed the rebuild: $highfloor vs $unpaced MiB/s uncapped"
fi
if [ -z "$paced" ] || [ -z "$unpaced" ]; then
	rk_fail "T8: a pass did not report a rate (paced '${paced:-}', unpaced '${unpaced:-}')"
elif [ "$paced" -le $((floor_mb * 3)) ] && [ "$unpaced" -ge $((paced * 2)) ]; then
	rk_pass "T8: paced $paced MiB/s against a ${floor_mb} MiB/s cap, uncapped $unpaced MiB/s"
else
	rk_fail "T8: pacing did not hold the cap: paced $paced MiB/s, uncapped $unpaced MiB/s, cap ${floor_mb} MiB/s"
fi

rk_summary
