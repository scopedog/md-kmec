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
run_pass() {	# tag pages(Y|N)
	local tag=$1 pages=$2 spare victim=${MEMBERS[3]} done0 sc0 d sc chunks secs max_pb=0 pb
	spare=${MEMBERS[$N]}

	[ -w $P/debug_row_rebuild_pages ] || { rk_fail "$tag: raidkm lacks debug_row_rebuild_pages"; return; }
	echo "$pages" > $P/debug_row_rebuild_pages
	rk_create 2r "${MEMBERS[@]:0:$N}" || { rk_fail "$tag: create"; return; }
	echo "$(cat "/sys/block/$MDNAME/md/rk_row_rebuild")" | grep -q 1 || { rk_fail "$tag: rk_row_rebuild is off"; return; }
	rk_write "$DATAMB"
	rk_fail_disks "$victim"; rk_remove_disks "$victim"
	echo 2000000 > "/sys/block/$MDNAME/md/sync_speed_min"
	done0=$(stat_of rebuild_done); sc0=$(stat_of rebuild_stripe_chunks); nm0=$(stat_of rebuild_band_nomem)

	# the foreground: sequential 1 MiB reads over the written region, looping
	fio --name=fg --filename="$MD" --rw=read --bs=1M --direct=1 --ioengine=libaio \
		--iodepth=8 --numjobs=2 --size="${DATAMB}M" --time_based --runtime=3600 \
		>/dev/null 2>&1 &
	FIOPID=$!
	sleep 2
	rk_dmesg_clear
	sudo dd if=/dev/zero of="$spare" bs=1M count=4 status=none 2>/dev/null
	rk_add_disks "$spare"
	sleep 1
	secs=0
	while grep -q recovery /proc/mdstat; do
		pb=$(stat_of rebuild_set_page_bufs); [ "${pb:-0}" -gt "$max_pb" ] && max_pb=$pb
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
	elif [ $((d + sc)) -eq "$chunks" ]; then
		rk_pass "$tag T1: counters cover the member: rebuild_done $d + stripe_chunks $sc of $chunks chunks"
	else
		rk_fail "$tag T1: counters do not cover the member: rebuild_done $d + stripe_chunks $sc vs $chunks chunks (band_nomem $(stat_of rebuild_band_nomem))"
	fi
	nm=$(( $(stat_of rebuild_band_nomem) - nm0 ))
	[ "$nm" = 0 ] && rk_pass "$tag T2: no band went without buffers" \
		|| rk_fail "$tag T2: $nm band(s) found no buffer set"
	if [ "$chunks" -gt 0 ] && [ $((d * 100 / chunks)) -ge 75 ]; then
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

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
rk_setup_brd $((N + 1)) || exit 1
DISKS=$(rk_pick_disks $((N + 1))) || { echo "ERROR: need $((N + 1)) devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

echo "== row rebuild under a degraded sequential read (8+2 rotating, ${CHUNK_KB}K chunk)"
run_pass "folio" N
run_pass "pages" Y

rk_summary
