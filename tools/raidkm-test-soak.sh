#!/bin/bash
# raidkm-test-soak.sh — long-duration normal-I/O reliability harness.
#
# OPT-IN reliability test, NOT part of the default raidkm-test.sh runner.
# Expect run times measured in hours, not minutes.
#
# Goal: prove that a healthy raidkm array does not silently corrupt bytes,
# leak resources, or accumulate dmesg badness over sustained varied I/O.
# Things this targets that the short functional+benchmark suites can't:
#
#   - latent silent corruption (fio --verify=md5 catches any byte that came
#     back different from what was written -- one mismatch is one bug)
#   - slow degradation (memory leaks, lock-list runaway, fragmentation)
#   - state-machine races in handle_stripe that only fire under sustained
#     load with a hot working set
#   - bugs in the EC compute path that scrub cannot see (scrub checks parity-
#     internal consistency; verify checks output bytes vs input bytes, so
#     a wrong EC result that's "consistent with the wrong parity" is caught
#     by verify but missed by scrub)
#   - kernel WARN/BUG/lockdep splats that only manifest after some warm-up
#
# Things this does NOT cover (separate work):
#   - crash-during-write (write hole)   --> PPL story, already validated
#   - drive-failure-during-I/O          --> degraded soak (memory: fdef6fd)
#   - reshape crash safety              --> tools/raidkm-test-crash.sh
#
# Phases:
#   1. warm-up                    fill+verify a known region (catches gross
#                                 setup problems immediately)
#   2. rotating soak              cycle through 4 workloads with verify on
#                                 ALL of them, for SOAK_HOURS total; scrub
#                                 every SOAK_SCRUB_EVERY seconds in between
#                                 phases; dmesg checked after every phase
#   3. final scrub + dmesg sweep  end-of-soak integrity check
#
# Configurable (all overridable via the environment):
#   SOAK_HOURS         total soak duration, hours          (default 2)
#   SOAK_SECONDS       total soak duration, seconds        (overrides SOAK_HOURS
#                                                           when set; useful for
#                                                           sub-hour smoke runs)
#   SOAK_PHASE_MIN     minutes per soak phase              (default 10)
#   SOAK_VERIFY        fio --verify mode                   (default md5)
#   SOAK_SCRUB_EVERY   seconds between scrubs              (default 1800)
#   SOAK_LAYOUT        rk_create layout, e.g. "2" or "2r"  (default 2)
#   SOAK_K             data-disk count                     (default 4)
#   FILL_MIB           warm-up write size                  (default 512)
#   BRD_NR, BRD_SIZE_KB, MD, MDADM, ...     (see raidkm-test-lib.sh)
#
# Usage:
#   sudo bash tools/raidkm-test-soak.sh
#   sudo SOAK_HOURS=8 bash tools/raidkm-test-soak.sh    # overnight
#   sudo SOAK_SECONDS=240 SOAK_PHASE_MIN=1 bash ...     # ~4 min smoke
#
# Long-run note: the kernel printk ring buffer can fill on multi-hour soaks
# and scroll earlier entries off, so a WARN from early in the run might be
# missed by the final dmesg sweep.  For SOAK_HOURS=8+ consider raising
# /sys/module/printk/parameters/log_buf_len before starting, or capture
# `sudo dmesg --follow` to a file in parallel.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SOAK_HOURS="${SOAK_HOURS:-2}"
SOAK_SECONDS="${SOAK_SECONDS:-}"            # overrides SOAK_HOURS if set
SOAK_PHASE_MIN="${SOAK_PHASE_MIN:-10}"
SOAK_VERIFY="${SOAK_VERIFY:-md5}"
SOAK_SCRUB_EVERY="${SOAK_SCRUB_EVERY:-1800}"
SOAK_LAYOUT="${SOAK_LAYOUT:-2}"
SOAK_K="${SOAK_K:-4}"
FILL_MIB="${FILL_MIB:-512}"

SOAK_M="$(rk_m_of "$SOAK_LAYOUT")"
SOAK_N=$((SOAK_K + SOAK_M))
SOAK_OUTPUT="${SOAK_OUTPUT:-/tmp/raidkm-soak-$$}"
mkdir -p "$SOAK_OUTPUT"

# --- setup ------------------------------------------------------------------

rk_load_modules || exit 1
rk_setup_brd "$SOAK_N" || exit 1

disks=$(rk_pick_disks "$SOAK_N") || { rk_fail "not enough ramdisks"; exit 1; }
rk_create "$SOAK_LAYOUT" $disks || { rk_fail "create failed"; exit 1; }

# Clear dmesg AFTER setup so create-time messages don't sit in the buffer
# being scanned for WARN/BUG.  Any "expected" output that happens to grow a
# matching keyword in a future kernel/raidkm version would otherwise look
# like a false positive on phase 1.
rk_dmesg_clear

echo
if [ -n "$SOAK_SECONDS" ]; then
	soak_total_label="${SOAK_SECONDS}s (SOAK_SECONDS override)"
else
	soak_total_label="${SOAK_HOURS} hours"
fi

echo "raidkm-test-soak.sh"
echo "  target:        $MD ($(rk_geom))"
echo "  layout/m/k:    $SOAK_LAYOUT / $SOAK_M / $SOAK_K"
echo "  verify mode:   $SOAK_VERIFY"
echo "  total soak:    $soak_total_label"
echo "  phase length:  ${SOAK_PHASE_MIN} min"
echo "  scrub every:   ${SOAK_SCRUB_EVERY}s"
echo "  warm-up size:  ${FILL_MIB} MiB"
echo "  fio output:    $SOAK_OUTPUT"
echo "  date:          $(date -Iseconds)"
echo

# Workload definitions: fio arg strings (no --filename/--verify/--runtime here)
#
# numjobs=1 throughout: fio's --verify state is per-job, and with multiple jobs
# on a shared device the verify bookkeeping races when two jobs write the same
# offset (one job's "I just wrote X here" record gets stale when the other
# overwrites it).  iodepth is the parallelism knob here -- still exercises the
# stripe cache and worker groups, without the verify-ambiguity.
WL_NAMES=(seq_write rand_write_4k mixed_8k_rw rand_64k_rw)
declare -A WL_ARGS
WL_ARGS[seq_write]="--rw=write --bs=1m --numjobs=1 --iodepth=16"
WL_ARGS[rand_write_4k]="--rw=randwrite --bs=4k --numjobs=1 --iodepth=128"
WL_ARGS[mixed_8k_rw]="--rw=randrw --rwmixread=50 --bs=8k --numjobs=1 --iodepth=64"
WL_ARGS[rand_64k_rw]="--rw=randrw --rwmixread=70 --bs=64k --numjobs=1 --iodepth=32"

# Has any WARN/BUG/lockdep/OOM landed in dmesg since rk_dmesg_clear?
soak_dmesg_clean() {
	! sudo dmesg 2>/dev/null | grep -qiE 'WARN|BUG|lockdep|Out of memory|call trace|gf_invert'
}

soak_dmesg_dump_tail() {
	echo "    --- dmesg tail ---"
	sudo dmesg 2>/dev/null | tail -20 | sed 's/^/    /'
}

# fio with verify enabled.  Verify is the load-bearing oracle here -- any
# byte mismatch means real silent corruption.  --verify_fatal=1 stops fio
# on the first error so the JSON output captures the spot.
#
# --serialize_overlap=1 is required for verify correctness on the randrw
# phases: at iodepth>1 fio can have two in-flight I/Os to the same block, so a
# verify-read can race a later overwrite of that block and report a SPURIOUS
# mismatch (expected != received) that is a fio bookkeeping artifact, not real
# corruption.  serialize_overlap makes fio hold off overlapping I/Os so the
# verify oracle stays trustworthy.  (numjobs=1 above only avoids the cross-job
# variant; this handles the within-job one.)
soak_fio() {
	local name="$1" runtime="$2"; shift 2
	local out="$SOAK_OUTPUT/${name}.json"
	sudo fio --output-format=json --output="$out" \
		--filename="$MD" --direct=1 --ioengine=libaio \
		--time_based --runtime="$runtime" --group_reporting \
		--verify="$SOAK_VERIFY" --verify_fatal=1 --verify_backlog=1024 \
		--serialize_overlap=1 \
		--name="$name" "$@" > /dev/null
}

# --- phase 1: warm-up -------------------------------------------------------

phase_warmup() {
	echo "==== Phase 1: warm-up (write+verify ${FILL_MIB} MiB) ===="
	if sudo fio --filename="$MD" --direct=1 --ioengine=libaio \
		--rw=write --bs=1m --size="${FILL_MIB}M" --numjobs=1 --iodepth=4 \
		--verify="$SOAK_VERIFY" --verify_fatal=1 --serialize_overlap=1 \
		--name=soak_warmup \
		> "$SOAK_OUTPUT/warmup.log" 2>&1; then
		rk_pass "warm-up: ${FILL_MIB} MiB write+verify"
	else
		rk_fail "warm-up: fio verify FAILED (see $SOAK_OUTPUT/warmup.log)"
		return 1
	fi
	soak_dmesg_clean || { rk_fail "warm-up: WARN/BUG in dmesg"; soak_dmesg_dump_tail; return 1; }
}

# --- phase 2: rotating soak -------------------------------------------------

phase_soak() {
	local total
	if [ -n "$SOAK_SECONDS" ]; then
		total="$SOAK_SECONDS"
	else
		total=$((SOAK_HOURS * 3600))
	fi
	local phase=$((SOAK_PHASE_MIN * 60))
	local elapsed=0 idx=0
	local last_scrub_at=0

	echo
	echo "==== Phase 2: rotating soak ===="
	while [ "$elapsed" -lt "$total" ]; do
		local remaining=$((total - elapsed))
		local this_phase=$(( phase < remaining ? phase : remaining ))
		local wl="${WL_NAMES[$(( idx % ${#WL_NAMES[@]} ))]}"
		local label="phase-${idx}-${wl}"

		echo "[+${elapsed}s] $label  for ${this_phase}s"
		# Intentional unquoted expansion: WL_ARGS[$wl] is a flat string of
		# multiple fio args ("--rw=write --bs=1m ...") that must word-split
		# into separate arguments.  Quoting would pass them as one arg.
		if ! soak_fio "$label" "$this_phase" ${WL_ARGS[$wl]}; then
			rk_fail "$label: fio verify FAILED"
			return 1
		fi
		if ! soak_dmesg_clean; then
			rk_fail "$label: WARN/BUG in dmesg after fio"
			soak_dmesg_dump_tail
			return 1
		fi
		rk_pass "$label: ${this_phase}s clean"

		elapsed=$((elapsed + this_phase))

		# Periodic scrub between phases.
		if [ $((elapsed - last_scrub_at)) -ge "$SOAK_SCRUB_EVERY" ] \
		   && [ "$elapsed" -lt "$total" ]; then
			local mm; mm=$(rk_scrub)
			if [ "$mm" = 0 ]; then
				rk_pass "scrub at +${elapsed}s: clean"
			else
				rk_fail "scrub at +${elapsed}s: mismatch_cnt=$mm"
				return 1
			fi
			last_scrub_at="$elapsed"
		fi
		idx=$((idx + 1))
	done
	echo
}

# --- phase 3: end-of-soak ---------------------------------------------------

phase_finish() {
	echo "==== Phase 3: final integrity ===="
	local mm; mm=$(rk_scrub)
	if [ "$mm" = 0 ]; then
		rk_pass "final scrub: clean (mismatch_cnt=0)"
	else
		rk_fail "final scrub: mismatch_cnt=$mm"
	fi
	if soak_dmesg_clean; then
		rk_pass "no WARN/BUG/lockdep over the full soak"
	else
		rk_fail "WARN/BUG/lockdep detected at some point"
		soak_dmesg_dump_tail
	fi
}

# --- main -------------------------------------------------------------------

trap 'rk_stop' EXIT INT TERM

phase_warmup || { rk_stop; rk_summary "raidkm-test-soak.sh"; exit 1; }
phase_soak   || { rk_stop; rk_summary "raidkm-test-soak.sh"; exit 1; }
phase_finish

rk_summary "raidkm-test-soak.sh"
