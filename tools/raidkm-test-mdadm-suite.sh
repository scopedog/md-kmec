#!/bin/bash
# raidkm-test-mdadm-suite.sh — mdadm's own regression tests, adapted to raidkm.
#
# mdadm ships a test suite written by the md/mdadm maintainers (tests/ and
# ./test in the mdadm tree).  Its raid6 tests are run here against raidkm m=2
# as copies with only the array definition rewritten, so the checks
# themselves stay upstream's:
#
#   90rk-00raid6            create / assemble / data checks across chunk sizes
#   90rk-01raid6integ       fail every one- and two-member combination and verify
#   90rk-02r6grow           grow the member count and size
#   90rk-24raid456deadlock  a known raid456 deadlock scenario under I/O
#
#   rewrites: the raid6 level -> --level=raidkm --parity-count=2; layouts ->
#   rotating (01: rotating parity-last); -e0.90 -> -e1.2 (raidkm needs v1
#   metadata); "check raid6" -> "check raidkm".  The 19raid6* tests are not
#   copied: they drive raid6check, which accepts only level 6 arrays.
#
# Passes when every 90rk-* test succeeds.
#
# WARNING: mdadm's harness refuses to start while any RAID device exists, stops
# every md array (mdadm -Ss) and detaches every loop device on the host.  Run
# it on a disposable machine only (raidkm-test-ci.sh requires --allow-stop-all).
#
# Skipped (exit 77, with the reason) when no mdadm source tree with its tests
# is found next to $MDADM (or at MDADM_SRC), or python3 is missing.
#
# Environment:
#   MDADM_SRC      a built mdadm tree (./mdadm, ./test, tests/); default: the
#                  directory of $MDADM
#   MS_CONTROL=1   also run the original raid6 tests (and the 25raid456-*
#                  conversions) on stock raid456, as the control for triage;
#                  reported, not counted.  19raid6repair is marked broken
#                  upstream, so its control failure is expected.
#   MS_KEEP=DIR    logs (default $RK_TMP/mdadm-suite)
#
# Usage: sudo bash tools/raidkm-test-mdadm-suite.sh
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

RK_TESTS="00raid6 01raid6integ 02r6grow 24raid456deadlock"
CONTROL_TESTS="00raid6 01raid6integ 02r6grow 19raid6check 19raid6repair 19raid6auto-repair 19repair-does-not-destroy 24raid456deadlock 25raid456-recovery-while-reshape 25raid456-reshape-corrupt-data 25raid456-reshape-deadlock 25raid456-reshape-while-recovery"
OUT=${MS_KEEP:-$RK_TMP/mdadm-suite}
WORK=$RK_TMP/mdadm-suite-tree

command -v python3 >/dev/null || rk_skip "python3 not installed (it adapts the tests)"
rk_resolve_mdadm || exit 1
SRC=${MDADM_SRC:-$(dirname "$(readlink -f "$MDADM")")}
[ -x "$SRC/test" ] && [ -d "$SRC/tests" ] && [ -x "$SRC/mdadm" ] ||
	rk_skip "no built mdadm tree with its tests at $SRC (set MDADM_SRC)"
rk_load_modules || exit 1

rm -rf "$WORK" "$OUT"
mkdir -p "$OUT"
cp -a "$SRC" "$WORK" || { rk_fail "cannot copy $SRC"; rk_summary; exit 1; }
cd "$WORK" || exit 1

# the raidkm copies: same checks, raidkm array definition
python3 - $RK_TESTS > "$OUT/adapt.log" <<'PY' || { rk_fail "adapting the tests failed"; rk_summary; exit 1; }
import re, sys
level = re.compile(r'(?<![\w-])(?:-l ?6|-l ?raid6|--level[= ](?:6|raid6))(?![\w.])')
meta = re.compile(r'-e ?0\.90')
lay = re.compile(r'^([ \t]*)layouts=(["\'])(?:\\\n|(?!\2).)*\2', re.M)
for n in sys.argv[1:]:
    s = open(f"tests/{n}").read()
    s, nl = level.subn("--level=raidkm --parity-count=2", s)
    s = meta.sub("-e1.2", s)
    s = s.replace("check raid6", "check raidkm")
    want = "rotating parity-last" if n == "01raid6integ" else "rotating"
    s, nlay = lay.subn(lambda m: f"{m.group(1)}layouts='{want}'", s)
    if nl == 0:
        sys.exit(f"tests/{n}: no raid6 level to rewrite (upstream test changed?)")
    open(f"tests/90rk-{n}", "w").write(
        f"# ADAPTED for raidkm m=2 from tests/{n} (level/layout/metadata rewritten)\n" + s)
    print(f"90rk-{n}: {nl} level rewrite(s), {nlay} layout rewrite(s)")
PY
sed 's/^/    /' "$OUT/adapt.log"

{
	echo "kernel $(uname -r)"
	echo "raidkm $(cat /sys/module/raidkm/srcversion)"
	echo "mdadm $("$WORK/mdadm" --version 2>&1) from $SRC ($(git -C "$SRC" log --oneline -1 2>/dev/null))"
} | tee "$OUT/env.txt" | sed 's/^/    /'

run_set() {	# <name> <comma-separated tests>
	rk_log "$1: mdadm ./test --tests=$2"
	# the harness runs `which mdadm`: the build under test must come first
	PATH="$WORK:$PATH" ./test --tests="$2" --keep-going --save-logs --logdir="$OUT/$1" --dev=loop \
		> "$OUT/$1.out" 2>&1
	# one line per test: "<path>/tests/<name>... [Execution time ...] succeeded|FAILED|skipping"
	sed 's/\x1b\[[0-9;]*m//g' "$OUT/$1.out" | grep -E '(^|/)tests/[^ /]+\.\.\. ' > "$OUT/$1.summary"
	./test cleanup > /dev/null 2>&1
}

if [ "${MS_CONTROL:-0}" = 1 ]; then
	if modprobe raid456 2>/dev/null; then
		run_set raid456 "$(tr ' ' ',' <<< "$CONTROL_TESTS")"
		while read -r line; do rk_log "control: $line"; done < "$OUT/raid456.summary"
	else
		rk_log "control SKIPPED: no raid456 module"
	fi
fi

run_set raidkm "$(for t in $RK_TESTS; do printf '90rk-%s,' "$t"; done | sed 's/,$//')"
for t in $RK_TESTS; do
	line=$(grep -F "tests/90rk-$t... " "$OUT/raidkm.summary" | tail -1)
	case "$line" in
	*succeeded*) rk_pass "90rk-$t ($(grep -o 'Execution time (seconds): [0-9]*' <<< "$line" | grep -o '[0-9]*$') s)" ;;
	"")          rk_fail "90rk-$t did not run (see $OUT/raidkm.out)" ;;
	*)           rk_fail "90rk-$t: ${line#*... } (see $OUT/raidkm/)" ;;
	esac
done

rk_log "logs: $OUT"
rk_summary
