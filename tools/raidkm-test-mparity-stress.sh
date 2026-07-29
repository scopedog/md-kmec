#!/bin/bash
# raidkm-test-mparity-stress.sh — many-parity CONCURRENCY stress: sustained
# verified I/O while members fail, rebuild, and fail again.
#
# WHY THIS EXISTS (item #4 of the many-parity hardening plan) — the gap left
# after the exhaustive erasure sweep:
#   * raidkm-test-mparity-exhaustive.sh drives every erasure PATTERN, but each
#     one is QUIESCENT: fail, then read, then write.  No I/O is in flight when
#     the failure lands, and no rebuild is running while the array is written.
#   * raidkm-test-degraded.sh / -replace.sh cover the state machine one
#     transition at a time.
#   * raidkm-test-soak.sh sustains verified I/O for hours but on a HEALTHY
#     array — its own header says drive-failure-during-I/O is out of scope.
#   This closes it: fio randwrite+verify AND full-stripe write+verify run
#   continuously WHILE the fault scheduler fails members, lets recovery start,
#   fails a SECOND member mid-rebuild, and re-adds — at m=6 and m=8.
#
# The corners it targets (all listed UNTESTED in the degraded-failure hardening
# notes, and all m>2 residue of raid5.c's inherited "<=2 failures" model):
#   1. degraded WRITE while a rebuild is running  (handle_stripe_dirtying /
#      schedule_reconstruction choosing RMW vs RCW with j>2 slots down, while
#      the sync thread is concurrently writing the rebuilding slot)
#   2. double-fault-DURING-rebuild (fail a second member while the first is
#      recovering — analyse_stripe's high-slot-first failed_num ordering and
#      need_this_block's survivor selection under a moving in-sync set)
#   3. sub-stripe degraded RMW at high m — the explicit RMW GAP left open at
#      the bottom of the exhaustive sweep; randwrite at bs<stripe is exactly it
#   4. races/UAF that only a debug kernel sees: run this under KASAN + lockdep
#      (KASAN_GENERIC, PROVE_LOCKING, PROVE_RCU, DEBUG_OBJECTS_RCU_HEAD).
#
# WHY fio --verify AND a final scrub (they catch different bugs): scrub only
# proves parity is self-consistent, so a wrong-but-consistently-wrong EC result
# passes it (the grow-data lesson).  verify compares returned bytes against
# what was written, which is the property that actually matters.  Both run.
#
# FAULT BUDGET — the one rule that keeps this a test and not a crash:
# md takes the array DOWN once more than m slots are out of sync, and a slot
# that is REBUILDING is out of sync too.  So the scheduler only ever injects a
# fault while (degraded < FAULT_BUDGET), with FAULT_BUDGET defaulting to m-1 —
# leaving one slot of headroom so a rebuild starting concurrently can never
# tip the array over.  An array that goes offline here is a harness bug, not a
# kernel finding, and would false-fail every subsequent check.
#
# Knobs (env):
#   MRANGE          parity counts to stress        (default "6 8")
#   KDATA           data disks k                   (default 6 -> n=12 / n=14)
#   LAYOUTS         "last" and/or "rot"            (default "last rot")
#   STRESS_SECONDS  fio runtime per (m,layout)     (default 600)
#   FAULT_BUDGET    max slots out of sync          (default m-1)
#   SYNC_MAX_KB     rebuild throttle, KiB/s        (default 20000 = ~20 MB/s,
#                                                   so a rebuild lasts long
#                                                   enough to overlap faults)
#   REGION_MB       per-fio-job region size        (default 512)
#   BRD_SIZE_KB     member size (lib)              (default here 1048576 = 1 GiB)
#   SKIP_SCRUB      1 = skip the final scrub       (default 0)
#
# Usage:
#   sudo bash tools/raidkm-test-mparity-stress.sh
#   sudo MRANGE=8 LAYOUTS=rot STRESS_SECONDS=1800 bash tools/raidkm-test-mparity-stress.sh
#   sudo STRESS_SECONDS=120 bash tools/raidkm-test-mparity-stress.sh   # smoke
set -u

# Members must be big enough that a throttled rebuild outlives a fault cycle;
# the lib default (256 MiB) rebuilds too fast to overlap.  Set before sourcing.
BRD_SIZE_KB="${BRD_SIZE_KB:-1048576}"
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

MRANGE="${MRANGE:-6 8}"
KDATA="${KDATA:-6}"
LAYOUTS="${LAYOUTS:-last rot}"
STRESS_SECONDS="${STRESS_SECONDS:-600}"
SYNC_MAX_KB="${SYNC_MAX_KB:-20000}"
REGION_MB="${REGION_MB:-512}"
SKIP_SCRUB="${SKIP_SCRUB:-0}"

FSB=$((KDATA * CHUNK_KB * 1024))                # full-stripe DATA bytes
STRESS_LOG="${STRESS_LOG:-$RK_TMP/mstress}"

command -v fio >/dev/null 2>&1 || { echo "ERROR: fio is required" >&2; exit 1; }

# ---------------------------------------------------------------------------
# fault scheduler
# ---------------------------------------------------------------------------

# Slots currently out of sync (failed OR rebuilding).  This is the number the
# fault budget is measured against.
st_degraded() { cat "/sys/block/$MDNAME/md/degraded" 2>/dev/null || echo 0; }

st_array_live() { grep -q "^$MDNAME :" /proc/mdstat 2>/dev/null; }

# st_inject <budget> <dev...> : one fault cycle over the given member list.
# Rotates through three deterministic modes so coverage is reproducible rather
# than luck-of-the-draw:
#   A  single fail -> rebuild starts -> re-add            (baseline churn)
#   B  fail, wait for recovery to be ACTIVE, fail a 2nd   (the double-fault-
#      during-rebuild corner) -> re-add both
#   C  fail up to the budget back-to-back                 (m-failure under load)
# Each returns having re-added everything it failed; the caller waits for sync.
STRESS_MODE=0
st_inject() {
	local budget="$1"; shift
	local devs=("$@") n=$# mode victim v2 v extra i
	mode=$((STRESS_MODE % 3)); STRESS_MODE=$((STRESS_MODE + 1))

	# pick victims that are currently in-sync members, newest rotation first
	victim="${devs[$((STRESS_MODE % n))]}"
	v2="${devs[$(((STRESS_MODE + n / 2) % n))]}"
	[ "$v2" = "$victim" ] && v2="${devs[$(((STRESS_MODE + 1) % n))]}"

	[ "$(st_degraded)" -ge "$budget" ] && return 0

	case "$mode" in
	0)	rk_log "  fault A: fail $victim"
		rk_fail_disks "$victim"
		rk_remove_disks "$victim"
		rk_add_disks "$victim"
		rk_wait_recovery_active || rk_log "  (recovery did not appear for $victim)"
		;;
	1)	rk_log "  fault B: fail $victim, then $v2 MID-REBUILD"
		rk_fail_disks "$victim"
		rk_remove_disks "$victim"
		rk_add_disks "$victim"
		if rk_wait_recovery_active; then
			# the corner: a second member dies while the first rebuilds
			if [ "$(st_degraded)" -lt "$budget" ]; then
				rk_fail_disks "$v2"
				rk_remove_disks "$v2"
				sleep 3
				rk_add_disks "$v2"
			else
				rk_log "  (budget reached, skipped 2nd fault)"
			fi
		else
			rk_log "  (no recovery seen; skipped 2nd fault)"
		fi
		;;
	2)	rk_log "  fault C: fail up to budget=$budget back-to-back"
		extra=()
		for ((i = 0; i < budget; i++)); do
			v="${devs[$(((STRESS_MODE + i) % n))]}"
			[[ " ${extra[*]:-} " == *" $v "* ]] && continue
			[ "$(st_degraded)" -ge "$budget" ] && break
			rk_fail_disks "$v"
			rk_remove_disks "$v"
			extra+=("$v")
		done
		sleep 5
		[ "${#extra[@]}" -gt 0 ] && rk_add_disks "${extra[@]}"
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# fio load
# ---------------------------------------------------------------------------

# Two disjoint regions, two write shapes, both verified:
#   rmw   4K randwrite  -> sub-stripe read-modify-write (the degraded RMW gap)
#   full  full-stripe   -> reconstruct-write path (all m parities recomputed)
# verify_fatal=1 stops fio at the FIRST bad byte so the failing offset is the
# last thing in the log rather than being buried under later noise.
st_fio_job() {
	cat <<EOF
[global]
filename=$MD
direct=1
ioengine=libaio
iodepth=16
time_based=1
runtime=$STRESS_SECONDS
verify=crc32c
verify_backlog=128
verify_fatal=1
verify_dump=1
randrepeat=0
continue_on_error=none
group_reporting=1

[rmw]
rw=randwrite
bs=4k
offset=0
size=${REGION_MB}m

[full]
rw=write
bs=$FSB
offset=${REGION_MB}m
size=${REGION_MB}m
EOF
}

# ---------------------------------------------------------------------------
# one (m, layout) stress round
# ---------------------------------------------------------------------------

st_round() {
	local m="$1" L="$2"
	local layout n members budget lbl fpid rc=0 cycles=0
	[ "$L" = rot ] && layout="${m}r" || layout="$m"
	n=$((KDATA + m))
	lbl="m=$m k=$KDATA $L"
	budget="${FAULT_BUDGET:-$((m - 1))}"
	[ "$budget" -lt 1 ] && budget=1

	members=("${DISKS[@]:0:n}")
	mkdir -p "$STRESS_LOG"

	echo
	echo "==== stress round: $lbl  (n=$n, budget=$budget, ${STRESS_SECONDS}s) ===="

	if ! rk_create "$layout" "${members[@]}"; then
		rk_fail "$lbl: create failed"
		return 1
	fi
	# Bisection knob: STRESS_SKIPCOPY=0 disables zero-copy writes for the
	# round (md-kmec defaults skip_copy on), isolating skip_copy-dependent
	# corruption from the rest of the degraded write path.
	if [ -n "${STRESS_SKIPCOPY:-}" ]; then
		echo "$STRESS_SKIPCOPY" | sudo tee "/sys/block/$MDNAME/md/skip_copy" >/dev/null
		rk_log "skip_copy=$(cat "/sys/block/$MDNAME/md/skip_copy")"
	fi
	rk_throttle "$SYNC_MAX_KB"

	# Lay the region down once cleanly so the very first verify pass has
	# known-good parity underneath it (fio writes before it verifies, but a
	# fault landing in the first seconds would otherwise hit never-written
	# stripes and read reconstructed zeroes — correct, yet not what we mean
	# to be measuring).
	rk_log "priming ${REGION_MB}MiB x2 ..."
	sudo dd if=/dev/zero of="$MD" bs="$FSB" count=$((REGION_MB * 1024 * 1024 * 2 / FSB)) \
		oflag=direct status=none 2>/dev/null

	st_fio_job > "$STRESS_LOG/job.fio"
	sudo fio "$STRESS_LOG/job.fio" --output="$STRESS_LOG/fio-$m-$L.log" >/dev/null 2>&1 &
	fpid=$!
	rk_log "fio running (pid $fpid), injecting faults ..."

	# Fault loop: keep cycling until fio exits.  Each cycle waits for the
	# array to come back fully in sync before the next one, so the modes stay
	# distinguishable (a rebuild always starts from a known state).
	while kill -0 "$fpid" 2>/dev/null; do
		st_array_live || { rk_log "  ARRAY WENT OFFLINE — stopping fault loop"; break; }
		st_inject "$budget" "${members[@]}"
		cycles=$((cycles + 1))
		# let the rebuild run under load for a while, then settle
		sleep 10
		kill -0 "$fpid" 2>/dev/null || break
		rk_unthrottle
		rk_wait_full
		rk_throttle "$SYNC_MAX_KB"
	done

	wait "$fpid"; rc=$?
	rk_unthrottle

	if [ "$rc" -eq 0 ]; then
		rk_pass "$lbl: fio verify clean across $cycles fault cycles"
	else
		rk_fail "$lbl: fio FAILED (rc=$rc) — see $STRESS_LOG/fio-$m-$L.log"
		grep -iE 'verify|error|bad' "$STRESS_LOG/fio-$m-$L.log" 2>/dev/null | head -10 | sed 's/^/      /'
	fi

	# Post-run state must converge: everything back in sync, no lost members.
	rk_wait_full
	if [ "$(st_degraded)" = "0" ] && st_array_live; then
		rk_pass "$lbl: array fully in sync after stress $(rk_geom)"
	else
		rk_fail "$lbl: array not fully in sync after stress $(rk_geom) degraded=$(st_degraded)"
	fi

	# Parity self-consistency on top of fio's byte-level verify.
	if [ "$SKIP_SCRUB" != 1 ]; then
		local mm; mm=$(rk_scrub)
		if [ "${mm:-1}" = "0" ]; then
			rk_pass "$lbl: scrub mismatch_cnt=0"
		else
			rk_fail "$lbl: scrub mismatch_cnt=$mm (parity inconsistent after stress)"
		fi
	fi

	rk_stop
	rk_udev_quiesce
	return 0
}

# ---------------------------------------------------------------------------
# debug-kernel splat sweep
# ---------------------------------------------------------------------------

# Wider than rk_dmesg_clean: this suite is meant to run on a KASAN+lockdep
# kernel, so the report signatures that kernel emits are failures here even
# when they carry no WARN/BUG banner (e.g. the lockdep circular-locking and
# RCU-stall headers).
st_splat_check() {
	local hits
	hits=$(sudo dmesg 2>/dev/null | grep -iE \
		'KASAN|use-after-free|out-of-bounds|WARNING:|BUG:|possible circular locking|possible recursive locking|inconsistent lock state|suspicious RCU usage|RCU stall|ODEBUG|sleeping function called|hung task|Call Trace|gf_invert' |
		grep -civ 'appears to be on the same physical disk')
	[ "${hits:-0}" -eq 0 ]
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

MAXM=0; for m in $MRANGE; do [ "$m" -gt "$MAXM" ] && MAXM=$m; done
MAXN=$((KDATA + MAXM))

echo "==== raidkm many-parity CONCURRENCY stress ===="
echo "  m range   : $MRANGE   (k=$KDATA data, n up to $MAXN)"
echo "  layouts   : $LAYOUTS"
echo "  load      : fio 4K randwrite + ${FSB}B full-stripe write, verify=crc32c"
echo "  runtime   : ${STRESS_SECONDS}s per (m,layout)"
echo "  faults    : modes A/B/C, budget default m-1, rebuild throttled ${SYNC_MAX_KB} KiB/s"
echo "  members   : $MAXN x $((BRD_SIZE_KB / 1024)) MiB, chunk ${CHUNK_KB} KiB"
echo "  kernel    : $(uname -r)"
echo "  debug cfg : KASAN=$(grep -c '^CONFIG_KASAN=y' "/boot/config-$(uname -r)" 2>/dev/null || echo '?')" \
     "LOCKDEP=$(grep -c '^CONFIG_PROVE_LOCKING=y' "/boot/config-$(uname -r)" 2>/dev/null || echo '?')"
echo

rk_load_modules || exit 1
rk_setup_brd "$MAXN" || exit 1
DISKS=($(rk_pick_disks "$MAXN")) || exit 1
rk_dmesg_clear

for m in $MRANGE; do
	for L in $LAYOUTS; do
		st_round "$m" "$L"
		if st_splat_check; then
			rk_pass "m=$m $L: no KASAN/lockdep/RCU/WARN splat"
		else
			rk_fail "m=$m $L: DEBUG-KERNEL SPLAT in dmesg (inspect ring buffer)"
			sudo dmesg | grep -iE 'KASAN|WARNING:|BUG:|circular locking|suspicious RCU|ODEBUG' |
				head -5 | sed 's/^/      /'
		fi
		rk_dmesg_window_close
		rk_dmesg_clear
	done
done

[ "$RK_DMESG_BAD" = 1 ] && rk_log "NOTE: at least one dmesg window was dirty (see above)"
rk_summary
