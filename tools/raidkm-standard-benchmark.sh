#!/bin/bash
#
# raidkm-standard-benchmark.sh — fio benchmark suite for an md array or raw device
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
#   --rebuild-victim=DEV  after the fio tests, fail DEV and time the rebuild
#                      (Test 7).  Declustered arrays populate the distributed
#                      spare; classic arrays recover onto the re-added member.
#   --mdadm=PATH       raidkm-aware mdadm for Test 7 (auto-resolved if omitted)
#   --no-check         skip Test 6 (the post-workload parity check) — use it
#                      on --assume-clean arrays over dirty disks, whose parity
#                      was never made consistent
#   --workloads=LIST   comma-separated workload numbers (default 1,2,3,4,5,8,9)
#   -h, --help         show this help
#
# Workloads:  1 random 4K write, 2 mixed 75/25 8K, 3 mixed 70/30 4K x16 jobs,
#             4 OLTP 70/30 16K, 5 random 8K write, 8 sequential 1 MiB write,
#             9 sequential 1 MiB read (QD8, 4 jobs, each in its own region)
#
# Member request size: around every workload the suite snapshots the request
# counters of the devices under the target (md/dm slaves; NVMe multipath heads
# expanded to their paths) and records the average request size and merge
# share that reached them in <test>_run<N>.members.json.  On flash with a
# coarse indirection unit, a write below that unit is rewritten whole by the
# drive, so this is tracked alongside throughput.
#
# On an md target the suite first waits for any running resync to finish (a
# sync competing with fio skews the numbers), and Test 6 runs once after all
# runs, waits for the check to complete and fails the script (exit 3) on a
# non-zero mismatch_cnt.  For raidkm vs stock md comparisons on the same disks
# use tools/raidkm-ab-benchmark.sh, which drives this script per arm.
#
set -euo pipefail

TARGET=/dev/md102
RUNS=1
RUNTIME=30
OUTPUT=
DROP_CACHES=1
CHECK=1
REBUILD_VICTIM=          # member device to fail+rebuild (enables Test 7)
MDADM=                   # raidkm-aware mdadm (auto-resolved if empty)
REBUILD_SECS=
MISMATCH=
WORKLOADS="1 2 3 4 5 8 9"

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
        --rebuild-victim=*) REBUILD_VICTIM="${arg#*=}" ;;
        --mdadm=*)         MDADM="${arg#*=}" ;;
        --no-check)        CHECK=0 ;;
        --workloads=*)     WORKLOADS="$(echo "${arg#*=}" | tr ',' ' ')" ;;
        -h|--help)         usage ;;
        *)                 echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

for n in $WORKLOADS; do
    case "$n" in 1|2|3|4|5|8|9) ;; *) echo "unknown workload: $n" >&2; exit 2 ;; esac
done

# shellcheck source=raidkm-member-stats.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/raidkm-member-stats.sh"

OUTPUT="${OUTPUT:-/tmp/kmec_bench_$$}"
mkdir -p "$OUTPUT"

if ! sudo dd if="$TARGET" of=/dev/null bs=1M count=1 status=none 2>/dev/null; then
    echo "error: $TARGET not accessible" >&2
    exit 1
fi

# md sysfs name of the target ("" when it is not an md array).  Resolve
# symlinks so /dev/md/<name> maps to its mdNNN node.
MDNAME=$(basename "$(readlink -f "$TARGET")")
[ -d "/sys/block/$MDNAME/md" ] || MDNAME=

wait_sync_idle() {
    [ -n "$MDNAME" ] || return 0
    local a
    while a=$(cat "/sys/block/$MDNAME/md/sync_action" 2>/dev/null) && [ "$a" != idle ]; do
        sleep 1
    done
}

# Devices whose request counters see the target's member I/O.
LEAVES=$(rk_leaf_devs "$TARGET" | sort -u | tr '\n' ' ')

# Sequential workloads: 4 jobs, each in its own region.  Regions are a quarter
# of the device rounded down to 16 MiB, so any power-of-two row up to 16 MiB
# starts every job on a row boundary.
SEQ_SPAN=$(( $(sudo blockdev --getsize64 "$TARGET") / 4 / (16 << 20) * (16 << 20) ))

echo "raidkm-standard-benchmark.sh"
echo "  target:    $TARGET"
echo "  members:   $LEAVES"
echo "  workloads: $WORKLOADS"
echo "  runs:      $RUNS"
echo "  runtime:   ${RUNTIME}s per test"
echo "  output:    $OUTPUT"
echo "  platform:  $(hostname) $(uname -r)"
echo "  date:      $(date -Iseconds)"
echo

if [ -n "$MDNAME" ] && [ "$(cat "/sys/block/$MDNAME/md/sync_action")" != idle ]; then
    echo "waiting for $(cat "/sys/block/$MDNAME/md/sync_action") on $MDNAME to finish before benchmarking..."
    wait_sync_idle
    echo
fi

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
    local before after
    drop_caches
    # shellcheck disable=SC2086  # LEAVES is a word list
    before=$(rk_stat_snap $LEAVES)
    sudo fio --output-format=json --output="$out" \
        --filename="$TARGET" --direct=1 --ioengine=libaio \
        --time_based --runtime="$RUNTIME" --group_reporting \
        --name="$name" "$@" > /dev/null
    # shellcheck disable=SC2086
    after=$(rk_stat_snap $LEAVES)
    rk_stat_report "$before" "$after" > "$OUTPUT/${name}_run${run}.members.json"
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
WORKLOAD_DESC[8]="Sequential 1 MiB Write QD8"
WORKLOAD_DESC[9]="Sequential 1 MiB Read QD8"
declare -A WORKLOAD_NAME=([1]=test1_rand4kw [2]=test2_dbmixed [3]=test3_highconc
                          [4]=test4_oltp [5]=test5_partial_stripe
                          [8]=test8_seqwrite1m [9]=test9_seqread1m)

run_workload() {
    local n="$1" run="$2"
    case "$n" in
        1) run_test "test1_rand4kw"        "$run" --rw=randwrite --bs=4k  --numjobs=4  --iodepth=32 ;;
        2) run_test "test2_dbmixed"        "$run" --rw=randrw --rwmixread=75 --bs=8k  --numjobs=8  --iodepth=16 ;;
        3) run_test "test3_highconc"       "$run" --rw=randrw --rwmixread=70 --bs=4k  --numjobs=16 --iodepth=8  ;;
        4) run_test "test4_oltp"           "$run" --rw=randrw --rwmixread=70 --bs=16k --numjobs=6  --iodepth=16 ;;
        5) run_test "test5_partial_stripe" "$run" --rw=randwrite --bs=8k  --numjobs=4  --iodepth=32 ;;
        8) run_test "test8_seqwrite1m"     "$run" --rw=write --bs=1M --numjobs=4 --iodepth=8 \
               --size="$SEQ_SPAN" --offset_increment="$SEQ_SPAN" ;;
        9) run_test "test9_seqread1m"      "$run" --rw=read  --bs=1M --numjobs=4 --iodepth=8 \
               --size="$SEQ_SPAN" --offset_increment="$SEQ_SPAN" ;;
    esac
}

# member_line <test-name> <run>: "w 123.4 KiB (97% merged)  r 128.0 KiB (0% merged)"
member_line() {
    python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
parts = []
for side, tag in (("write", "w"), ("read", "r")):
    s = m[side]
    if s["requests"]:
        parts.append("%s %.1f KiB (%.0f%% merged)" % (tag, s["avg_kib"], s["merged_pct"]))
print("  ".join(parts) or "no member I/O")
' "$OUTPUT/${1}_run${2}.members.json"
}

# Test 7: rebuild / populate wall-clock (opt-in via --rebuild-victim).
# Fails the victim and times FULL reconstruction of its content.  A declustered
# array populates the distributed spare (arm rk_dcl_populate); a classic array
# recovers onto the re-added member (mdadm --add).  Auto-detects which from the
# presence of the rk_dcl_populate sysfs knob.  Reports wall-clock and MiB/s.
resolve_mdadm() {
    [ -n "$MDADM" ] && [ -x "$MDADM" ] && return 0
    local c
    for c in "$HOME/mdraid-super/mdadm/mdadm" "$MDADM" mdadm; do
        [ -n "$c" ] && command -v "$c" >/dev/null 2>&1 && MDADM="$c" && return 0
    done
    echo "warning: no mdadm found for rebuild test (set --mdadm=PATH)" >&2
    return 1
}

rebuild_test() {
    local md="$MDNAME"
    local victim="$REBUILD_VICTIM"
    resolve_mdadm || return 1
    if [ -z "$md" ] || [ ! -e "/sys/block/$md/md/sync_action" ]; then
        echo "warning: $TARGET is not an md array — skipping rebuild test" >&2
        return 1
    fi
    # Declustered arrays carry the 0x400 bit in the md layout word; classic
    # raidkm does not.  (The rk_dcl_populate knob is present on BOTH classic and
    # declustered raidkm arrays, so it is not a reliable discriminator.)
    local dcl=0 lw
    lw=$(cat "/sys/block/$md/md/layout" 2>/dev/null)
    [ -n "$lw" ] && [ $(( lw & 0x400 )) -ne 0 ] && dcl=1

    # wait out any in-flight sync (e.g. the Test-6 consistency check)
    while [ "$(cat "/sys/block/$md/md/sync_action" 2>/dev/null)" != idle ]; do sleep 0.5; done

    local vmib; vmib=$(( $(sudo blockdev --getsize64 "$victim") / 1048576 ))

    # run the rebuild at full speed (restore caller's limits afterwards)
    local omax omin
    omax=$(cat /proc/sys/dev/raid/speed_limit_max)
    omin=$(cat /proc/sys/dev/raid/speed_limit_min)
    echo 8000000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
    echo 500000  | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null

    local t0 t1
    if [ "$dcl" = 1 ]; then
        # RaidDevice slot of the victim (read while it is still a member)
        local slot
        slot=$(sudo "$MDADM" --detail "$TARGET" | awk -v v="$victim" \
            '$0 ~ v && $1 ~ /^[0-9]+$/ {print $4; exit}')
        sudo "$MDADM" --fail   "$TARGET" "$victim" >/dev/null
        sudo "$MDADM" --remove "$TARGET" "$victim" >/dev/null
        t0=$(date +%s.%N)
        echo "$slot" | sudo tee "/sys/block/$md/md/rk_dcl_populate" >/dev/null
        while :; do
            case "$(cat "/sys/block/$md/md/rk_dcl_populate" 2>/dev/null)" in
                populated*) break ;;
            esac
            sleep 0.3
        done
        t1=$(date +%s.%N)
    else
        sudo "$MDADM" --fail   "$TARGET" "$victim" >/dev/null
        sudo "$MDADM" --remove "$TARGET" "$victim" >/dev/null
        sudo "$MDADM" --zero-superblock "$victim" 2>/dev/null || true
        sudo dd if=/dev/zero of="$victim" bs=1M count=64 status=none
        t0=$(date +%s.%N)
        sudo "$MDADM" --add "$TARGET" "$victim" >/dev/null
        local saw=0 a deg
        while :; do
            a=$(cat "/sys/block/$md/md/sync_action" 2>/dev/null) || break
            [ "$a" = recover ] && saw=1
            if [ "$a" = idle ]; then
                deg=$(cat "/sys/block/$md/md/degraded" 2>/dev/null)
                { [ "$saw" = 1 ] || [ "$deg" = 0 ]; } && break
            fi
            sleep 0.3
        done
        t1=$(date +%s.%N)
    fi

    echo "$omax" | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
    echo "$omin" | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null

    REBUILD_SECS=$(python3 -c "print(f'{$t1-$t0:.1f}')")
    local mibps; mibps=$(python3 -c "print(f'{$vmib/($t1-$t0):.0f}')" 2>/dev/null || echo '?')
    local kind; [ "$dcl" = 1 ] && kind="declustered populate" || kind="classic recover"
    printf "  7: %ss  (%s of %d MiB member, %s MiB/s)\n" "$REBUILD_SECS" "$kind" "$vmib" "$mibps"
}

# Storage for per-run results.
declare -A RESULTS    # RESULTS[test_n,run_i] = IOPS

for run in $(seq 1 "$RUNS"); do
    echo "=== Run $run / $RUNS ==="
    for n in $WORKLOADS; do
        iops=$(run_workload "$n" "$run")
        RESULTS["$n,$run"]="$iops"
        printf "  %s: %s IOPS — %s\n" "$n" "$iops" "${WORKLOAD_DESC[$n]}"
        printf "     members: %s\n" "$(member_line "${WORKLOAD_NAME[$n]}" "$run")"
    done
    echo
done

# Test 6: parity consistency check after all the workloads.  Doesn't produce
# IOPS.  Runs once, after the last run (a check left running into the next
# run's fio would compete with it and skew that run), and waits for completion.
if [ "$CHECK" = 1 ] && [ -n "$MDNAME" ] && [ -e "/sys/block/$MDNAME/md/sync_action" ]; then
    echo "=== Test 6: parity check ==="
    wait_sync_idle
    echo check | sudo tee "/sys/block/$MDNAME/md/sync_action" >/dev/null
    sleep 1
    wait_sync_idle
    MISMATCH=$(cat "/sys/block/$MDNAME/md/mismatch_cnt")
    printf "  6: mismatch_cnt=%s%s\n" "$MISMATCH" "$([ "$MISMATCH" = 0 ] || echo '  <-- FAIL')"
    echo
fi

# Test 7: rebuild / populate wall-clock (only if a victim was named).
if [ -n "$REBUILD_VICTIM" ]; then
    echo "=== Test 7: rebuild wall-clock (victim $REBUILD_VICTIM) ==="
    rebuild_test || echo "  7: rebuild test skipped/failed"
    echo
fi

# Summary.
echo "=== Summary (mean ± stdev across $RUNS run(s)) ==="
printf "%-5s %-50s %-20s %s\n" "Test" "Description" "mean IOPS ± stdev" "per-run"
for n in $WORKLOADS; do
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

# Member request size, mean across runs, per workload.
echo
echo "=== Member request size (mean across $RUNS run(s)) ==="
printf "%-5s %-50s %s\n" "Test" "Description" "at the members"
for n in $WORKLOADS; do
    msum=$(python3 -c '
import glob, json, statistics, sys
files = sorted(glob.glob(sys.argv[1]))
out = []
for side, tag in (("write", "w"), ("read", "r")):
    runs = [json.load(open(f))[side] for f in files]
    runs = [r for r in runs if r["requests"]]
    if runs:
        out.append("%s %.1f KiB (%.0f%% merged)" % (tag,
            statistics.mean(r["avg_kib"] for r in runs),
            statistics.mean(r["merged_pct"] for r in runs)))
print("  ".join(out) or "no member I/O")
' "$OUTPUT/${WORKLOAD_NAME[$n]}_run*.members.json")
    printf "%-5s %-50s %s\n" "$n" "${WORKLOAD_DESC[$n]}" "$msum"
done

if [ -n "$MISMATCH" ]; then
    printf "%-5s %-50s %s\n" "6" "Parity check mismatch_cnt" "$MISMATCH"
fi
if [ -n "$REBUILD_SECS" ]; then
    printf "%-5s %-50s %s\n" "7" "Rebuild / populate wall-clock" "${REBUILD_SECS}s"
fi

echo
echo "Raw fio JSON files in: $OUTPUT"

if [ -n "$MISMATCH" ] && [ "$MISMATCH" != 0 ]; then
    echo "FAIL: parity check found mismatch_cnt=$MISMATCH" >&2
    exit 3
fi
