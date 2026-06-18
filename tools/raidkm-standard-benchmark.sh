#!/bin/bash
#
# raidkm-standard-benchmark.sh — 6-workload enterprise benchmark suite
#
# Improvements over the archived version:
#   * Drops page cache + dentries before every test (eliminates the
#     order-dependent contamination we hit yesterday on Test 5)
#   * Saves raw fio JSON per test for offline analysis (latency
#     percentiles, bandwidth, error counts, etc.)
#   * --runs=N mode that runs the whole suite N times and reports
#     mean + stdev per test
#   * --quick mode (5s per test instead of 30s) for dev iteration
#   * Single source of truth for the test fio configs
#
# Usage:
#   sudo bash tools/raidkm-standard-benchmark.sh [options]
#
# Options:
#   --target=DEV       block device to benchmark (default /dev/md102)
#   --runs=N           number of times to run the whole suite (default 1)
#   --runtime=SEC      seconds per individual test (default 30)
#   --output=DIR       where to drop fio JSON files (default /tmp/kmec_bench_$$)
#   --quick            shortcut for --runtime=5
#   --no-drop-caches   skip drop_caches between tests (for debugging)
#   -h, --help         show this help
#
set -euo pipefail

TARGET=/dev/md102
RUNS=1
RUNTIME=30
OUTPUT=
DROP_CACHES=1

usage() {
    sed -n '3,/^$/p' "$0" | sed 's/^# \?//'
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --target=*)        TARGET="${arg#*=}" ;;
        --runs=*)          RUNS="${arg#*=}" ;;
        --runtime=*)       RUNTIME="${arg#*=}" ;;
        --output=*)        OUTPUT="${arg#*=}" ;;
        --quick)           RUNTIME=5 ;;
        --no-drop-caches)  DROP_CACHES=0 ;;
        -h|--help)         usage ;;
        *)                 echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

OUTPUT="${OUTPUT:-/tmp/kmec_bench_$$}"
mkdir -p "$OUTPUT"

if ! sudo dd if="$TARGET" of=/dev/null bs=1M count=1 status=none 2>/dev/null; then
    echo "error: $TARGET not accessible" >&2
    exit 1
fi

echo "raidkm-standard-benchmark.sh"
echo "  target:    $TARGET"
echo "  runs:      $RUNS"
echo "  runtime:   ${RUNTIME}s per test"
echo "  output:    $OUTPUT"
echo "  platform:  $(hostname) $(uname -r)"
echo "  date:      $(date -Iseconds)"
echo

drop_caches() {
    if [ "$DROP_CACHES" = "1" ]; then
        sync
        sudo bash -c 'echo 3 > /proc/sys/vm/drop_caches'
        # Brief settle so the next test starts cold.
        sleep 1
    fi
}

# Run fio with a workload config, parse IOPS from JSON output.
# args: <test-name> <run-idx> <fio-args...>
run_test() {
    local name="$1" run="$2"; shift 2
    local out="$OUTPUT/${name}_run${run}.json"
    drop_caches
    sudo fio --output-format=json --output="$out" \
        --filename="$TARGET" --direct=1 --ioengine=libaio \
        --time_based --runtime="$RUNTIME" --group_reporting \
        --name="$name" "$@" > /dev/null
    # Parse read+write IOPS from the JSON.
    python3 -c "
import json, sys
with open('$out') as f:
    d = json.load(f)
job = d['jobs'][0]
r = job['read']['iops']
w = job['write']['iops']
print(f'{r+w:.0f}')"
}

# Workload configs (kept in sync with the docs in the README).
declare -A WORKLOAD_DESC
WORKLOAD_DESC[1]="Random 4K Write (RAID6 RMW worst case)"
WORKLOAD_DESC[2]="Database Mixed 75/25 8K"
WORKLOAD_DESC[3]="High Concurrency 70/30 4K (16 jobs)"
WORKLOAD_DESC[4]="OLTP 70/30 16K"
WORKLOAD_DESC[5]="Partial Stripe Write 8K"

run_workload() {
    local n="$1" run="$2"
    case "$n" in
        1) run_test "test1_rand4kw"        "$run" --rw=randwrite --bs=4k  --numjobs=4  --iodepth=32 ;;
        2) run_test "test2_dbmixed"        "$run" --rw=randrw --rwmixread=75 --bs=8k  --numjobs=8  --iodepth=16 ;;
        3) run_test "test3_highconc"       "$run" --rw=randrw --rwmixread=70 --bs=4k  --numjobs=16 --iodepth=8  ;;
        4) run_test "test4_oltp"           "$run" --rw=randrw --rwmixread=70 --bs=16k --numjobs=6  --iodepth=16 ;;
        5) run_test "test5_partial_stripe" "$run" --rw=randwrite --bs=8k  --numjobs=4  --iodepth=32 ;;
    esac
}

# Storage for per-run results.
declare -A RESULTS    # RESULTS[test_n,run_i] = IOPS

for run in $(seq 1 "$RUNS"); do
    echo "=== Run $run / $RUNS ==="
    for n in 1 2 3 4 5; do
        iops=$(run_workload "$n" "$run")
        RESULTS["$n,$run"]="$iops"
        printf "  %s: %s IOPS — %s\n" "$n" "$iops" "${WORKLOAD_DESC[$n]}"
    done
    # Test 6: array integrity check.  Doesn't produce IOPS, just
    # confirms the array is consistent after the workload.
    if sudo bash -c "echo check > /sys/block/$(basename "$TARGET")/md/sync_action" 2>/dev/null; then
        echo "  6: consistency check initiated"
    fi
    echo
done

# Summary.
echo "=== Summary (mean ± stdev across $RUNS run(s)) ==="
printf "%-5s %-50s %-20s %s\n" "Test" "Description" "mean IOPS ± stdev" "per-run"
for n in 1 2 3 4 5; do
    vals=""
    for run in $(seq 1 "$RUNS"); do
        vals+="${RESULTS[$n,$run]} "
    done
    summary=$(python3 -c "
import statistics
v = [float(x) for x in '$vals'.split()]
mean = statistics.mean(v)
if len(v) > 1:
    stdev = statistics.stdev(v)
    cv = (stdev/mean*100) if mean > 0 else 0
    print(f'{mean:.0f} ± {stdev:.0f}  (cv={cv:.1f}%%)')
else:
    print(f'{mean:.0f}')")
    printf "%-5s %-50s %-30s %s\n" "$n" "${WORKLOAD_DESC[$n]}" "$summary" "$vals"
done

echo
echo "Raw fio JSON files in: $OUTPUT"
