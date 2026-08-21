#!/bin/bash
#
# raidkm-test-kcsan-stress.sh — data-race stress gate for md-kmec.
#
# Runs on a KCSAN kernel (build with tools/kcsan.config; see that file).  Drives
# raidkm's LOCK-ELIDED / lock-free fast paths hard while a "chaos" driver churns
# the array's live state, then scrapes the kernel ring buffer for KCSAN
# data-race splats.  KCSAN is sampling-based, so the whole point is VOLUME +
# CONCURRENCY + STATE CHURN over a long window — a single pass rarely trips a
# rare race; DURATION should be minutes, and CI should run it repeatedly.
#
# Fast paths targeted (each has a matching chaos loop below):
#   * skip_copy page aliasing        <- SKIP_COPY toggle 0/1 under full-stripe writes
#   * stripe-head recycling / hash   <- STRIPE_CACHE_SIZE grow/shrink under 4k-random
#   * worker_groups live swap        <- GROUP_THREAD_CNT churn incl 0<->N (the known
#                                        live-gtc UAF/deadlock site)
#   * scrub vs I/O (check_state,     <- SYNC_ACTION check/idle churn
#     mismatch/healed counters)
#   * degraded read/write + rebuild  <- FAIL + re-add churn on a spare member
#   * declustered redirect map       <- LAYOUT=declustered: populate + rebalance churn
#
# Env knobs (all optional):
#   NDISK=8            members in the array (data+parity)
#   MSET="2 4"         parity counts to sweep (rotating layouts)
#   LAYOUT=rotating    rotating | parity-last | declustered
#   CHUNK_KB=64        chunk size
#   DURATION=180       seconds of stress per (m,layout) cell
#   RK_DEVS="..."      real block devices (NVMe) instead of brd — STRONGLY
#                      preferred: NVMe timing widens the store-vs-worker windows
#                      a ramdisk's ~us latency hides.  Needs NDISK+1 devices.
#   KCSAN_FOCUS=1      switch KCSAN to whitelist mode on md/raid symbols (less
#                      noise from unrelated kernel activity); default 0 = global
#   DCL_N/DCL_G/...    declustered geometry (see raidkm-test-declustered-*.sh)
#
# Verdict: PASS iff zero KCSAN splats whose stack touches raid/r5/md/dcl/kmec.
# Every splat (relevant AND global) is saved under $RK_TMP/kcsan/ for review.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

NDISK=${NDISK:-8}
MSET=${MSET:-"2 4"}
LAYOUT=${LAYOUT:-rotating}
DURATION=${DURATION:-180}
KCSAN_FOCUS=${KCSAN_FOCUS:-0}
KCSAN_DBG=/sys/kernel/debug/kcsan
KLOG_DIR="$RK_TMP/kcsan"
MEMBERS=(); SPARE=""; CHAOS_PIDS=(); LOAD_PIDS=()

# raidkm/raid5/md/declustered symbol fragments that mark a splat as "ours".
RELEVANT_RE='raid_km|raidkm|raid5|raid6|r5c_|r5l_|md_|ops_run|handle_stripe|get_active_stripe|analyse_stripe|async_(copy|memcpy|xor|pq)|dcl|skip_copy|worker_group|stripe_head|km_(encode|decode)|km_dcl'

# ---------------------------------------------------------------------------
say()   { echo "  $*"; }
have()  { command -v "$1" >/dev/null 2>&1; }

kcsan_present() {
	[ -f "$KLOG_DIR/.checked" ] && return 0
	if [ ! -e "$KCSAN_DBG" ]; then
		echo "ERROR: $KCSAN_DBG missing — this is not a KCSAN kernel." >&2
		echo "       Build with: scripts/kconfig/merge_config.sh -m .config tools/kcsan.config" >&2
		return 1
	fi
	mkdir -p "$KLOG_DIR"; touch "$KLOG_DIR/.checked"
	return 0
}

# Optionally focus KCSAN on md/raid functions to cut unrelated noise.  Whitelist
# mode reports a race ONLY if a whitelisted function is on the access stack.
kcsan_focus() {
	[ "$KCSAN_FOCUS" = 1 ] || return 0
	local f
	echo whitelist | sudo tee "$KCSAN_DBG" >/dev/null 2>&1 || {
		say "note: cannot set KCSAN whitelist mode (skipping focus)"; return 0; }
	for f in raid_km_make_request handle_stripe handle_stripe_dirtying \
		 ops_run_biodrain ops_run_io async_copy_data raid5_get_active_stripe \
		 do_release_stripe raid5_wakeup_stripe_thread raid5_unplug \
		 analyse_stripe handle_parity_checks6 km_dcl_resolve; do
		echo "$f" | sudo tee "$KCSAN_DBG" >/dev/null 2>&1 || true
	done
	say "KCSAN focused on md/raid symbols (whitelist mode)"
}

cleanup() {
	local p
	for p in "${LOAD_PIDS[@]:-}" "${CHAOS_PIDS[@]:-}"; do
		[ -n "$p" ] && kill "$p" 2>/dev/null
	done
	wait 2>/dev/null
	sudo pkill -f 'fio.*raidkm-kcsan' 2>/dev/null || true
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	local d
	for d in "${MEMBERS[@]:-}" "$SPARE"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Load generators — run for the whole window, writing raw to $MD (no fs, to
# stress the raid layer purely).  Device split so the full-stripe job keeps its
# alignment instead of being contended into RMW by the random job.
# ---------------------------------------------------------------------------
start_load() {
	local k="$1" dev_bytes half fs_bs
	dev_bytes=$(sudo blockdev --getsize64 "$MD")
	half=$(( dev_bytes / 2 / 4096 * 4096 ))
	fs_bs=$(( k * CHUNK_KB ))              # full-stripe width in KiB (rcw=0 target)

	if ! have fio; then
		echo "ERROR: fio not installed (dnf install fio)" >&2; return 1
	fi

	# Job 1: 4k random RW on the first half — stripe recycling, get_active_stripe/
	#        wait_for_stripe, device_lock, RMW prexor, self-heal counters.
	sudo fio --name=raidkm-kcsan-rand --filename="$MD" --offset=0 --size="$half" \
		--rw=randrw --bs=4k --direct=1 --ioengine=libaio --iodepth=32 \
		--numjobs=8 --group_reporting --time_based --runtime="$DURATION" \
		--norandommap --randrepeat=0 --output=/dev/null >/dev/null 2>&1 &
	LOAD_PIDS+=("$!")

	# Job 2: full-stripe aligned sequential write on the second half — this is the
	#        skip_copy alias path (bs == k*chunk, ba == bs → full-page-aligned,
	#        rcw=0).  numjobs>1 makes several aliasing writers race the same cache.
	sudo fio --name=raidkm-kcsan-fullstripe --filename="$MD" --offset="$half" \
		--size="$half" --rw=write --bs="${fs_bs}k" --ba="${fs_bs}k" --direct=1 \
		--ioengine=libaio --iodepth=8 --numjobs=4 --group_reporting \
		--time_based --runtime="$DURATION" --output=/dev/null >/dev/null 2>&1 &
	LOAD_PIDS+=("$!")

	# Job 3: whole-device random reads — biofill, degraded-read decode when a
	#        chaos loop has a member failed.
	sudo fio --name=raidkm-kcsan-read --filename="$MD" --rw=randread --bs=16k \
		--direct=1 --ioengine=libaio --iodepth=16 --numjobs=4 --group_reporting \
		--time_based --runtime="$DURATION" --output=/dev/null >/dev/null 2>&1 &
	LOAD_PIDS+=("$!")
}

# ---------------------------------------------------------------------------
# Chaos loops — each mutates one live-state axis until the sentinel file clears.
# All sysfs writes are best-effort (2>/dev/null): a transiently-busy array
# rejecting a write is expected, not a failure.
# ---------------------------------------------------------------------------
STOP="$RK_TMP/kcsan.stop"

chaos_gtc() {           # the live worker_groups swap — highest-value race site
	local v
	while [ ! -e "$STOP" ]; do
		for v in 2 8 0 4 1; do
			echo "$v" | sudo tee "/sys/block/$MDNAME/md/group_thread_cnt" >/dev/null 2>&1
			sleep 0.3
		done
	done
}
chaos_cache() {         # grow/shrink the stripe cache under load
	local v
	while [ ! -e "$STOP" ]; do
		for v in 256 4096 1024 16384 512; do
			echo "$v" | sudo tee "/sys/block/$MDNAME/md/stripe_cache_size" >/dev/null 2>&1
			sleep 0.4
		done
	done
}
chaos_skipcopy() {      # flip alias path + STABLE_WRITES mid-flight
	while [ ! -e "$STOP" ]; do
		echo 0 | sudo tee "/sys/block/$MDNAME/md/skip_copy" >/dev/null 2>&1; sleep 0.7
		echo 1 | sudo tee "/sys/block/$MDNAME/md/skip_copy" >/dev/null 2>&1; sleep 0.7
	done
}
chaos_scrub() {         # scrub racing I/O — check_state, mismatch/healed counters
	while [ ! -e "$STOP" ]; do
		echo check | sudo tee "/sys/block/$MDNAME/md/sync_action" >/dev/null 2>&1
		sleep 3
		echo idle  | sudo tee "/sys/block/$MDNAME/md/sync_action" >/dev/null 2>&1
		sleep 1
	done
}
chaos_rebuild() {       # degraded read/write + recovery thread, needs a spare
	# OFF by default: under KCSAN's per-access udelay a degraded-mode resync
	# collapses to ~KiB/s and backs up ALL fio I/O, wedging the run before the
	# window closes. The lock-free races we hunt (skip_copy alias, worker_groups
	# swap, stripe recycling) live on the NON-degraded fast paths that the other
	# chaos loops already exercise. Opt in with CHAOS_REBUILD=1 (and expect a
	# much longer window). When on, cap resync speed so it can't starve I/O.
	[ "${CHAOS_REBUILD:-0}" = 1 ] || return 0
	[ -n "$SPARE" ] || return 0
	local victim
	while [ ! -e "$STOP" ]; do
		echo 5000 | sudo tee "/sys/block/$MDNAME/md/sync_speed_max" >/dev/null 2>&1
		victim="${MEMBERS[0]}"
		sudo "$MDADM" --fail "$MD" "$victim" >/dev/null 2>&1; sleep 2
		sudo "$MDADM" --remove "$MD" "$victim" >/dev/null 2>&1
		sudo "$MDADM" --add "$MD" "$victim" >/dev/null 2>&1   # triggers rebuild
		sleep 8
	done
}

start_chaos() {
	rm -f "$STOP"
	chaos_gtc &        CHAOS_PIDS+=("$!")
	chaos_cache &      CHAOS_PIDS+=("$!")
	chaos_skipcopy &   CHAOS_PIDS+=("$!")
	chaos_scrub &      CHAOS_PIDS+=("$!")
	chaos_rebuild &    CHAOS_PIDS+=("$!")
}
stop_chaos() {
	touch "$STOP"
	local p; for p in "${CHAOS_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	CHAOS_PIDS=(); wait 2>/dev/null
}

# ---------------------------------------------------------------------------
# Splat scraping.  KCSAN emits blocks delimited by lines of '='; the BUG line is
# "BUG: KCSAN: data-race in FUNC1 / FUNC2".  We save the full ring buffer, split
# out each KCSAN block, and classify by whether any md/raid symbol appears.
# ---------------------------------------------------------------------------
scrape_splats() {       # scrape_splats <label> -> echoes "relevant total"
	local label="$1" raw="$KLOG_DIR/dmesg-$label.txt"
	sudo dmesg > "$raw" 2>/dev/null || true
	# awk: emit each KCSAN splat block to a per-index file; tag relevant ones.
	awk -v dir="$KLOG_DIR" -v label="$label" -v rel="$RELEVANT_RE" '
		/BUG: KCSAN:/ { inblk=1; n++; blk=""; hit=0 }
		inblk { blk=blk $0 "\n"; if ($0 ~ rel) hit=1 }
		inblk && /^={10,}/ && blk ~ /BUG: KCSAN/ && length(blk) > 200 {
			# a block closes on the trailing ==== after content
			f = dir "/splat-" label "-" n (hit?".relevant":".global") ".txt"
			printf "%s", blk > f; close(f)
			if (hit) relc++
			inblk=0
		}
		END { printf "%d %d\n", relc+0, n+0 }
	' "$raw"
}

# ---------------------------------------------------------------------------
# Build one array for the given (m, layout) and run a stress window against it.
# ---------------------------------------------------------------------------
run_cell() {
	local m="$1" k label
	label="${LAYOUT}-m${m}"
	rk_dmesg_clear

	if [ "$LAYOUT" = declustered ]; then
		# geometry from DCL_* (defaults mirror the declustered gates)
		local N=${DCL_N:-14} G=${DCL_G:-6} SC=${DCL_SC:-2} \
		      NBASE=${DCL_NBASE:-16} SEED=${DCL_SEED:-0x10}
		k=$(( G - m ))
		sudo "$MDADM" --create "$MD" --level=raidkm --parity-count="$m" \
			--layout=declustered --group-width="$G" --spare-columns="$SC" \
			--dcl-nbase="$NBASE" --dcl-seed="$SEED" --chunk="$CHUNK_KB" \
			--raid-devices="$N" "${MEMBERS[@]}" --run --force >/dev/null 2>&1 \
			|| { rk_fail "[$label] create failed"; return; }
	else
		local lay="$m"; [ "$LAYOUT" = parity-last ] || lay="${m}r"
		k=$(( NDISK - m ))
		rk_create "$lay" "${MEMBERS[@]}" >/dev/null 2>&1 \
			|| { rk_fail "[$label] create failed"; return; }
	fi
	grep -q "$MDNAME : active raidkm" /proc/mdstat \
		|| { rk_fail "[$label] array not active"; return; }
	rk_wait_idle 2>/dev/null || true      # let initial resync settle before churn

	say "[$label] k=$k stripe=$((k*CHUNK_KB))K — ${DURATION}s stress"
	start_load "$k" || { rk_fail "[$label] load failed to start"; return; }
	start_chaos
	sleep "$DURATION"
	stop_chaos
	# stop I/O
	local p; for p in "${LOAD_PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
	LOAD_PIDS=(); wait 2>/dev/null

	local res rel tot; res=$(scrape_splats "$label"); rel=${res% *}; tot=${res#* }
	if [ "${rel:-0}" -eq 0 ]; then
		rk_pass "[$label] no md/raid KCSAN data-races (${tot:-0} unrelated global splats)"
	else
		rk_fail "[$label] $rel md/raid KCSAN data-race splat(s) — see $KLOG_DIR/splat-$label-*.relevant.txt"
	fi
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
main() {
	kcsan_present || exit 1
	rk_load_modules || exit 1
	kcsan_focus

	local need=$(( NDISK + 1 ))           # +1 spare for the fail/rebuild chaos
	[ "$LAYOUT" = declustered ] && need=$(( ${DCL_N:-14} ))   # dcl has its own spare cols
	rk_setup_brd "$need" || exit 1
	local disks; disks=$(rk_pick_disks "$need") || exit 1
	read -r -a MEMBERS <<< "$disks"
	if [ "$LAYOUT" != declustered ]; then
		SPARE="${MEMBERS[$NDISK]}"          # last device reserved as churn spare
		MEMBERS=("${MEMBERS[@]:0:$NDISK}")
	fi

	echo "== raidkm KCSAN stress =="
	echo "   layout=$LAYOUT  ndisk=$NDISK  m={$MSET}  chunk=${CHUNK_KB}K  dur=${DURATION}s"
	echo "   devs=$([ -n "$RK_DEVS" ] && echo NVMe || echo brd)  focus=$KCSAN_FOCUS"
	echo "   kcsan sampling: verify boot cmdline has kcsan.skip_watch=250 for sensitivity"
	echo

	if [ "$LAYOUT" = declustered ]; then
		run_cell "${DCL_M:-2}"
	else
		local m; for m in $MSET; do run_cell "$m"; done
	fi

	rk_summary
}
main "$@"
