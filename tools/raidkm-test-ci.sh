#!/bin/bash
#
# raidkm-test-ci.sh — one CI entry point for the raidkm (md level 71) test suites
#
# Runs a named tier of the suites in tools/, each against its own ramdisks and
# /dev/md70, and reports the result the way CI systems consume it: one exit
# status, a per-suite summary, JUnit XML, and a kernel-log scan that fails a
# suite on any WARNING / BUG / KASAN / lockdep report even when the suite itself
# passed.  The tier contents are owned here, so a CI job that calls this script
# picks up new gates by updating the checkout — no job change.
#
# Usage:
#   sudo bash tools/raidkm-test-ci.sh [--tier=smoke|quick|full|nightly] [options]
#   bash tools/raidkm-test-ci.sh --list [--tier=...]
#
# Tiers:
#   smoke   ~25 min.  The row layer (degraded read once per row, native
#           checksum through the row paths), declustered population to
#           completion, rebuild onto a spare and hot-replace (through the row
#           layer, the default), plus the functional and degraded smoke.  Meant
#           for every CI run.
#   quick   smoke + the same rebuilds on the 4 KiB stripe path
#           (replace@default_row_rebuild=0) and declustered population (~40 min).
#   full    quick + the core regression (grow, reshape) and the declustered
#           crash / multi-assignment suites.  Several of those stop EVERY md array
#           on the host (mdadm --stop --scan): refused without --allow-stop-all.
#           Run it only on a disposable machine.
#   nightly quick + three suites built on independent mechanisms: the kernel's
#           own fault injection under fsx/fsstress (faultinject), xfstests on
#           ext4 over raidkm healthy and degraded (xfstests), and mdadm's own
#           regression tests adapted to raidkm (mdadm-suite).  Meant for a
#           debug kernel (KASAN, lockdep, CONFIG_FAULT_INJECTION,
#           CONFIG_DMA_API_DEBUG) on a disposable machine with ~16 GiB of
#           memory; several hours.  mdadm's harness stops every md array, so
#           it needs --allow-stop-all.  A suite whose kernel or host lacks what
#           it needs (fault injection, ext4, a built xfstests) is reported as
#           skipped, with the reason, instead of passing.
#
# Options:
#   --tier=NAME            smoke (default), quick, full or nightly
#   --suites=LIST          run exactly these suites instead (comma-separated
#                          names as in tools/raidkm-test-<name>.sh)
#   --output=DIR           results directory (default /var/tmp/raidkm-test-ci-<timestamp>)
#   --suite-timeout=SEC    per-suite wall-clock limit (default 2400).  The
#                          nightly suites declare their own, longer limits and
#                          keep them when they exceed this.
#   --allow-stop-all       permit suites that stop every md array (tier full)
#   --allow-existing-arrays  run even though other md arrays are active.  The
#                          smoke/quick suites only use $MD (/dev/md70) and their
#                          own ramdisks, so this is safe for those tiers only.
#   --keep-brd             leave the brd ramdisks loaded at the end
#   --list                 print the suites of the tier and exit
#   -h, --help             show this help
#
# Environment (passed to every suite; see raidkm-test-lib.sh):
#   MDADM        raidkm-aware mdadm (default: resolved like the suites do)
#   BRD_NR=16 BRD_SIZE_KB=131072 NATIVE=1 RK_RELOAD=0 — the settings the release
#   gates pass with; override any of them in the environment.
#
# Needs: root, bash, the raidkm and isal_lib modules (build tree or packaged),
# the brd module, and about 2 GiB of free memory for the ramdisks.
#
# Output (DIR): <suite>.log and <suite>.dmesg per suite, summary.txt, results.xml
# (JUnit), env.txt.  Exit status: 0 only when every suite passed or was skipped
# with a clean kernel log; 1 on any failure; 2 on a pre-flight refusal.
#
# Kernel log: known platform artifacts (RK_DMESG_KNOWN in raidkm-test-lib.sh,
# today the dma-debug cacheline EEXIST false positive) are left out of the
# verdict and counted in the suite's note instead.
#

set -u
PATH="$PATH:/usr/sbin:/sbin"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

SMOKE=(functional degraded row-dread-wide row-csum declustered-populate-window declustered-degraded replace
       scrub-badblocks degraded-trust-disk row-rebuild-load)
# <suite>@<param>=<value>: run the suite with a raidkm module parameter set for
# new arrays, restored afterwards.  replace@default_row_rebuild=0 covers the
# 4 KiB stripe-cache rebuild that row rebuild falls back to.
QUICK=("${SMOKE[@]}" replace@default_row_rebuild=0 declustered-populate)
FULL=("${QUICK[@]}" grow grow-traditional reshape-concurrent declustered-create declustered-io
      declustered-rebalance declustered-csum declustered-autoarm declustered-multi declustered-crash)
NIGHTLY=("${QUICK[@]}" faultinject xfstests mdadm-suite)
# suites that run `mdadm --stop --scan` (directly, via rk_udev_quiesce, or in
# mdadm's own test harness)
STOP_ALL=(declustered-multi declustered-crash mdadm-suite)
# per-suite wall-clock limits for suites longer than --suite-timeout's default
declare -A SUITE_TIMEOUTS=([faultinject]=7200 [xfstests]=10800 [mdadm-suite]=7200)

TIER=smoke
SUITES_ARG=
OUTPUT=
SUITE_TIMEOUT=
ALLOW_STOP_ALL=0
ALLOW_EXISTING=0
KEEP_BRD=0
LIST=0

usage() { sed -n '3,/^$/p' "$0" | sed 's/^# \?//'; exit 0; }
die()   { echo "ERROR: $*" >&2; exit 2; }

for arg in "$@"; do
	case "$arg" in
	--tier=*)                TIER="${arg#*=}" ;;
	--suites=*)              SUITES_ARG="${arg#*=}" ;;
	--output=*)              OUTPUT="${arg#*=}" ;;
	--suite-timeout=*)       SUITE_TIMEOUT="${arg#*=}" ;;
	--allow-stop-all)        ALLOW_STOP_ALL=1 ;;
	--allow-existing-arrays) ALLOW_EXISTING=1 ;;
	--keep-brd)              KEEP_BRD=1 ;;
	--list)                  LIST=1 ;;
	-h|--help)               usage ;;
	*)                       die "unknown option: $arg (see --help)" ;;
	esac
done

case "$TIER" in
smoke) SUITES=("${SMOKE[@]}") ;;
quick) SUITES=("${QUICK[@]}") ;;
full)  SUITES=("${FULL[@]}") ;;
nightly) SUITES=("${NIGHTLY[@]}") ;;
*)     die "--tier must be smoke, quick, full or nightly" ;;
esac
[ -n "$SUITES_ARG" ] && IFS=, read -r -a SUITES <<< "$SUITES_ARG"
[ -z "$SUITE_TIMEOUT" ] || [[ "$SUITE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--suite-timeout must be a positive integer"

for s in "${SUITES[@]}"; do
	[ -f "$DIR/raidkm-test-${s%%@*}.sh" ] || die "no such suite: tools/raidkm-test-${s%%@*}.sh"
	case "$s" in
	*@*=*) [[ "${s#*@}" =~ ^[a-z_]+=[A-Za-z0-9_-]+$ ]] || die "bad suite parameter: $s (want suite@param=value)" ;;
	*@*)   die "bad suite parameter: $s (want suite@param=value)" ;;
	esac
done

if [ "$LIST" = 1 ]; then
	printf '%s\n' "${SUITES[@]}"
	exit 0
fi

# ---- pre-flight ----------------------------------------------------------------

for t in timeout dmesg lsmod modprobe; do
	command -v "$t" >/dev/null || die "$t not found"
done

needs_stop_all=0
for s in "${SUITES[@]}"; do
	for x in "${STOP_ALL[@]}"; do [ "$s" = "$x" ] && needs_stop_all=1; done
done
[ "$needs_stop_all" = 1 ] && [ "$ALLOW_STOP_ALL" = 0 ] &&
	die "the selected suites stop EVERY md array on this host; pass --allow-stop-all on a disposable machine"

export MD="${MD:-/dev/md70}"
active=$(awk '/^md[0-9]+ : active/ {print $1}' /proc/mdstat 2>/dev/null | grep -v -x "$(basename "$MD")" | tr '\n' ' ')
if [ -n "$active" ] && [ "$ALLOW_EXISTING" = 0 ]; then
	die "active md arrays on this host: ${active}— run on a dedicated test machine, or pass --allow-existing-arrays (smoke/quick only)"
fi
[ -n "$active" ] && [ "$needs_stop_all" = 1 ] &&
	die "--allow-existing-arrays cannot be combined with suites that stop every array (active: $active)"

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
modinfo brd >/dev/null 2>&1 || [ -e /sys/module/brd ] || [ -e /dev/ram0 ] ||
	die "no brd (RAM disk) module: install the kernel's modules package (CONFIG_BLK_DEV_RAM=m)"

# The gate settings, set BEFORE sourcing the library: it fills in its own
# defaults (12 x 256 MiB ramdisks) for anything still unset.
export BRD_NR="${BRD_NR:-16}" BRD_SIZE_KB="${BRD_SIZE_KB:-131072}"
export NATIVE="${NATIVE:-1}" RK_RELOAD="${RK_RELOAD:-0}"

# shellcheck source=raidkm-test-lib.sh
. "$DIR/raidkm-test-lib.sh"
rk_resolve_mdadm || exit 2
export MDADM
rk_load_modules || die "raidkm / isal_lib could not be loaded"

free_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
need_kb=$(( BRD_NR * BRD_SIZE_KB + 524288 ))
[ -n "$free_kb" ] && [ "$free_kb" -lt "$need_kb" ] &&
	die "about $((need_kb / 1024)) MiB of free memory needed for $BRD_NR x $((BRD_SIZE_KB / 1024)) MiB ramdisks, $((free_kb / 1024)) MiB available"

OUTPUT="${OUTPUT:-/var/tmp/raidkm-test-ci-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTPUT" || die "cannot create $OUTPUT"

{
	echo "date=$(date -Iseconds)"
	echo "host=$(hostname)"
	echo "kernel=$(uname -r)"
	echo "tier=$TIER"
	echo "suites=${SUITES[*]}"
	echo "raidkm_srcversion=$(cat /sys/module/raidkm/srcversion 2>/dev/null)"
	echo "raidkm_module=$([ -f "$RAIDKM_KO" ] && echo "$RAIDKM_KO" || modinfo -n raidkm 2>/dev/null)"
	echo "isal_lib_srcversion=$(cat /sys/module/isal_lib/srcversion 2>/dev/null)"
	echo "mdadm=$MDADM ($("$MDADM" --version 2>&1 | head -1))"
	echo "tree=$(git -C "$RK_TREE" describe --always --dirty 2>/dev/null || echo "not a git checkout")"
	command -v rpm >/dev/null && echo "packages=$(rpm -qa 'kmod-tlc-*' 'mdadm-tlc-*' 2>/dev/null | sort | tr '\n' ' ')"
	echo "env=BRD_NR=$BRD_NR BRD_SIZE_KB=$BRD_SIZE_KB NATIVE=$NATIVE RK_RELOAD=$RK_RELOAD MD=$MD"
	# On real disks the members decide how long the tier takes and which
	# premises hold (a 4 KiB-logical member cannot serve a sub-block read),
	# so a result has to say what it ran on.
	if [ -n "${RK_DEVS:-}" ]; then
		echo "rk_devs=$RK_DEVS"
		for d in $RK_DEVS; do
			[ -b "$d" ] || continue
			echo "member=$d size_mb=$(( $(blockdev --getsize64 "$d" 2>/dev/null || echo 0) / 1048576 )) logical=$(blockdev --getss "$d" 2>/dev/null) physical=$(blockdev --getpbsz "$d" 2>/dev/null)"
		done
	fi
} > "$OUTPUT/env.txt"
sed 's/^/  /' "$OUTPUT/env.txt"
echo

# ---- run -----------------------------------------------------------------------

SPLAT="$RK_SPLAT"			# raidkm-test-lib.sh

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

declare -a R_NAME R_STATUS R_PASSED R_FAILED R_SECS R_NOTE
dmesg -C 2>/dev/null
total_start=$(date +%s)
nfail=0
nskip=0

for s in "${SUITES[@]}"; do
	echo "==== $s ===="
	f="${s//[@=]/_}"			# file-name form of the suite spec
	pfile= pold=
	if [[ "$s" == *@* ]]; then
		pfile="/sys/module/raidkm/parameters/${s#*@}"; pfile="${pfile%%=*}"
		pold=$(cat "$pfile" 2>/dev/null) || die "$s: raidkm has no module parameter ${pfile##*/}"
		echo "${s##*=}" > "$pfile" || die "$s: cannot set ${pfile##*/}=${s##*=}"
	fi
	# --suite-timeout sets the budget for suites that do not declare one.  A
	# suite that DOES declare one keeps it when it is longer: the entries in
	# SUITE_TIMEOUTS exist because those suites genuinely need hours, and a
	# flag meant to bound the smoke tier silently cutting xfstests to the
	# same number just turns a long suite into a timed-out one.
	limit=${SUITE_TIMEOUT:-2400}
	declared=${SUITE_TIMEOUTS[${s%%@*}]:-0}
	[ "$declared" -gt "$limit" ] && limit=$declared
	start=$(date +%s)
	timeout --foreground --kill-after=60 "$limit" \
		bash "$DIR/raidkm-test-${s%%@*}.sh" > "$OUTPUT/$f.log" 2>&1
	rc=$?
	secs=$(( $(date +%s) - start ))
	[ -n "$pfile" ] && echo "$pold" > "$pfile"
	dmesg > "$OUTPUT/$f.dmesg" 2>/dev/null
	dmesg -C 2>/dev/null
	line=$(grep -E "==== .*: [0-9]+ passed, [0-9]+ failed(, [0-9]+ skipped)? ====" "$OUTPUT/$f.log" | tail -1)
	passed=$(sed -n 's/.*: \([0-9]*\) passed.*/\1/p' <<< "$line")
	failed=$(sed -n 's/.*[^0-9]\([0-9]*\) failed.*/\1/p' <<< "$line")
	# checks the environment could not express (rk_skip_check): reported so a
	# green tier still says what it did not get to try
	cskip=$(sed -n 's/.*[^0-9]\([0-9]*\) skipped.*/\1/p' <<< "$line")
	splats=$(rk_dmesg_splats "$OUTPUT/$f.dmesg" "$OUTPUT/$f.known")
	known=$(cat "$OUTPUT/$f.known" 2>/dev/null); rm -f "$OUTPUT/$f.known"
	note=""
	status=pass
	if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
		status=fail; note="timed out after ${limit}s"
	elif [ "$rc" = "$RK_SKIP" ]; then
		status=skip; note=$(sed -n 's/^SKIP: //p' "$OUTPUT/$f.log" | head -1)
		note=${note:-skipped}
	elif [ "$rc" != 0 ]; then
		status=fail; note="exit $rc"
	elif [ -z "$line" ]; then
		status=fail; note="no pass/fail summary line in the log"
	elif [ "${failed:-0}" != 0 ]; then
		status=fail; note="$failed failed"
	fi
	if [ "${splats:-0}" != 0 ]; then
		status=fail; note="${note:+$note; }$splats kernel warning line(s) in $f.dmesg"
	fi
	[ "${known:-0}" != 0 ] && note="${note:+$note; }$known known artifact report(s) ignored"
	[ "${cskip:-0}" != 0 ] && note="${note:+$note; }${cskip} check(s) skipped"
	[ "$status" = fail ] && nfail=$((nfail + 1))
	[ "$status" = skip ] && nskip=$((nskip + 1))
	R_NAME+=("$s"); R_STATUS+=("$status"); R_PASSED+=("${passed:-0}")
	R_FAILED+=("${failed:-0}"); R_SECS+=("$secs"); R_NOTE+=("$note")
	printf '  %s  %s passed, %s failed, %ss%s\n' "${status^^}" "${passed:-?}" "${failed:-?}" "$secs" "${note:+  ($note)}"
done
total_secs=$(( $(date +%s) - total_start ))

# ---- cleanup -------------------------------------------------------------------

"$MDADM" --stop "$MD" >/dev/null 2>&1
if [ "$KEEP_BRD" = 0 ] && lsmod | grep -q '^brd '; then
	rmmod brd 2>/dev/null || echo "  NOTE: brd is still in use and stays loaded"
fi

# ---- report --------------------------------------------------------------------

{
	echo "raidkm-test-ci: tier $TIER, ${#SUITES[@]} suites, $nfail failed, $nskip skipped, ${total_secs}s"
	printf '%-36s %-5s %7s %7s %7s  %s\n' suite status passed failed seconds note
	for i in "${!R_NAME[@]}"; do
		printf '%-36s %-5s %7s %7s %7s  %s\n' "${R_NAME[$i]}" "${R_STATUS[$i]}" \
			"${R_PASSED[$i]}" "${R_FAILED[$i]}" "${R_SECS[$i]}" "${R_NOTE[$i]}"
	done
} > "$OUTPUT/summary.txt"

{
	echo '<?xml version="1.0" encoding="UTF-8"?>'
	echo "<testsuites name=\"raidkm-test-ci\" tests=\"${#SUITES[@]}\" failures=\"$nfail\" time=\"$total_secs\">"
	echo "  <testsuite name=\"raidkm-$TIER\" tests=\"${#SUITES[@]}\" failures=\"$nfail\" skipped=\"$nskip\" time=\"$total_secs\" hostname=\"$(hostname | xml_escape)\">"
	for i in "${!R_NAME[@]}"; do
		n="${R_NAME[$i]//[@=]/_}"
		echo "    <testcase classname=\"raidkm.$TIER\" name=\"$(printf '%s' "${R_NAME[$i]}" | xml_escape)\" time=\"${R_SECS[$i]}\">"
		if [ "${R_STATUS[$i]}" = skip ]; then
			echo "      <skipped message=\"$(printf '%s' "${R_NOTE[$i]}" | xml_escape)\"/>"
		fi
		if [ "${R_STATUS[$i]}" = fail ]; then
			echo "      <failure message=\"$(printf '%s' "${R_NOTE[$i]}" | xml_escape)\">"
			{ grep -E "FAIL|ERROR" "$OUTPUT/$n.log" | head -20
			  echo "---- last 40 lines of $n.log ----"
			  tail -40 "$OUTPUT/$n.log"
			  echo "---- kernel warnings ----"
			  rk_dmesg_filter_known < "$OUTPUT/$n.dmesg" | grep -E "$SPLAT" | head -20; } | xml_escape
			echo "      </failure>"
		fi
		echo "      <system-out>${R_PASSED[$i]} passed, ${R_FAILED[$i]} failed; log $OUTPUT/$n.log</system-out>"
		echo "    </testcase>"
	done
	echo "  </testsuite>"
	echo "</testsuites>"
} > "$OUTPUT/results.xml"

echo
cat "$OUTPUT/summary.txt"
echo "Results: $OUTPUT (summary.txt, results.xml, <suite>.log, <suite>.dmesg)"
# A tier where every suite skipped exits 0 on the letter of "nothing failed",
# which is exactly how a mis-specified rig (too few RK_DEVS, a module that will
# not load) passes CI without running a line of raidkm.  Say so and fail.
if [ "$nskip" = "${#SUITES[@]}" ]; then
	echo "raidkm-test-ci: every suite skipped -- nothing was tested" >&2
	exit 1
fi
[ "$nfail" = 0 ]
