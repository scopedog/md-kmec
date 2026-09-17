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
#   --rebuild-load=LIST   classic arrays: after Test 7, rebuild DEV again while
#                      a foreground workload runs on the degraded array (Test
#                      7L), once per entry: seqread (1 MiB QD8 x4) or randread
#                      (4 KiB QD16 x4).  Records the rebuild rate and the
#                      foreground throughput together
#   --rebuild-floor=KBPS  md's speed_limit_min during Tests 7/7L (default
#                      500000); under a foreground load md throttles the
#                      rebuild down to this floor
#   --degraded-victim=DEV after the healthy workloads, fail and remove DEV and
#                      run --degraded-workloads on the degraded array (results
#                      prefixed deg_).  When DEV is also --rebuild-victim, Test 7
#                      rebuilds from that degraded state
#   --mdadm=PATH       raidkm-aware mdadm for Test 7 (auto-resolved if omitted)
#   --no-check         skip Test 6 (the post-workload parity check) — use it
#                      on --assume-clean arrays over dirty disks, whose parity
#                      was never made consistent
#   --workloads=LIST   comma-separated workload numbers (default 1,2,3,4,5,8,9,10)
#   --degraded-workloads=LIST  workloads for the degraded phase (default 9,10)
#   -h, --help         show this help
#
# Workloads:  1 random 4K write, 2 mixed 75/25 8K, 3 mixed 70/30 4K x16 jobs,
#             4 OLTP 70/30 16K, 5 random 8K write, 8 sequential 1 MiB write,
#             9 sequential 1 MiB read (QD8, 4 jobs, each in its own region),
#             10 random 4K read (QD16 x4 jobs)
#
# Member request size: around every workload the suite snapshots the request
# counters of the devices under the target (md/dm slaves; NVMe multipath heads
# expanded to their paths) and records the average request size and merge
# share that reached them in <test>_run<N>.members.json.  On flash with a
# coarse indirection unit, a write below that unit is rewritten whole by the
# drive, so this is tracked alongside throughput.
#
# CPU: every workload, rebuild and loaded rebuild also records the host's busy
# cores over its window (user + nice + system + irq + softirq + steal, from
# /proc/stat) in <test>_run<N>.cpu.json or test7*_rebuild.json.  On
# device-bound hardware that is where an engine difference shows when the
# throughput cannot.
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
REBUILD_LOAD=            # foreground workloads for Test 7L (classic arrays)
REBUILD_FLOOR=500000     # speed_limit_min during Tests 7/7L, KB/s
DEGRADED_VICTIM=         # member device to fail for the degraded phase
DEGRADED_WORKLOADS="9 10"
DCL_SLOT=                # declustered: RaidDevice slot of a victim failed early
MDADM=                   # raidkm-aware mdadm (auto-resolved if empty)
REBUILD_SECS=
MISMATCH=
WORKLOADS="1 2 3 4 5 8 9 10"

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
        --rebuild-load=*)  REBUILD_LOAD="$(echo "${arg#*=}" | tr ',' ' ')" ;;
        --rebuild-floor=*) REBUILD_FLOOR="${arg#*=}" ;;
        --degraded-victim=*) DEGRADED_VICTIM="${arg#*=}" ;;
        --degraded-workloads=*) DEGRADED_WORKLOADS="$(echo "${arg#*=}" | tr ',' ' ')" ;;
        --mdadm=*)         MDADM="${arg#*=}" ;;
        --no-check)        CHECK=0 ;;
        --workloads=*)     WORKLOADS="$(echo "${arg#*=}" | tr ',' ' ')" ;;
        -h|--help)         usage ;;
        *)                 echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

for n in $WORKLOADS $DEGRADED_WORKLOADS; do
    case "$n" in 1|2|3|4|5|8|9|10) ;; *) echo "unknown workload: $n" >&2; exit 2 ;; esac
done
for l in $REBUILD_LOAD; do
    case "$l" in seqread|randread) ;; *) echo "unknown --rebuild-load: $l (seqread, randread)" >&2; exit 2 ;; esac
done
[[ "$REBUILD_FLOOR" =~ ^[1-9][0-9]*$ ]] || { echo "--rebuild-floor must be a positive integer (KB/s)" >&2; exit 2; }
[ -z "$REBUILD_LOAD" ] || [ -n "$REBUILD_VICTIM" ] || { echo "--rebuild-load needs --rebuild-victim" >&2; exit 2; }
if [ -n "$DEGRADED_VICTIM" ] && [ -n "$REBUILD_VICTIM" ] &&
   [ "$(readlink -f "$DEGRADED_VICTIM")" != "$(readlink -f "$REBUILD_VICTIM")" ]; then
    echo "--degraded-victim and --rebuild-victim must be the same device (the rebuild starts from the degraded state)" >&2
    exit 2
fi

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
[ -n "$DEGRADED_VICTIM" ] && echo "  degraded:  $DEGRADED_WORKLOADS with $DEGRADED_VICTIM failed"
[ -n "$REBUILD_VICTIM" ] && echo "  rebuild:   $REBUILD_VICTIM, floor ${REBUILD_FLOOR} KB/s${REBUILD_LOAD:+, then under: $REBUILD_LOAD}"
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

# Busy jiffies and a timestamp, for busy_cores between two snapshots.
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
cpu_snap() {
    awk -v now="$(date +%s.%N)" '$1 == "cpu" {print $2 + $3 + $4 + $7 + $8 + $9, now; exit}' /proc/stat
}
busy_cores() {	# busy_cores "<before>" "<after>" -> cores, 2 decimals
    python3 -c "
b, bt = map(float, '$1'.split()); a, at = map(float, '$2'.split())
print(f'{(a - b) / $CLK_TCK / max(at - bt, 1e-6):.2f}')"
}

# Run fio with a workload config, parse IOPS from JSON output.
# args: <test-name> <run-idx> <fio-args...>
run_test() {
    local name="$1" run="$2"; shift 2
    local out="$OUTPUT/${name}_run${run}.json"
    local before after c0 c1
    drop_caches
    # shellcheck disable=SC2086  # LEAVES is a word list
    before=$(rk_stat_snap $LEAVES)
    c0=$(cpu_snap)
    sudo fio --output-format=json --output="$out" \
        --filename="$TARGET" --direct=1 --ioengine=libaio \
        --time_based --runtime="$RUNTIME" --group_reporting \
        --name="$name" "$@" > /dev/null
    c1=$(cpu_snap)
    # shellcheck disable=SC2086
    after=$(rk_stat_snap $LEAVES)
    rk_stat_report "$before" "$after" > "$OUTPUT/${name}_run${run}.members.json"
    echo "{\"busy_cores\": $(busy_cores "$c0" "$c1")}" > "$OUTPUT/${name}_run${run}.cpu.json"
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
WORKLOAD_DESC[10]="Random 4K Read QD16 (4 jobs)"
declare -A WORKLOAD_NAME=([1]=test1_rand4kw [2]=test2_dbmixed [3]=test3_highconc
                          [4]=test4_oltp [5]=test5_partial_stripe
                          [8]=test8_seqwrite1m [9]=test9_seqread1m [10]=test10_randread4k)

run_workload() {	# <n> <run> [name prefix]
    local n="$1" run="$2" p="${3:-}"
    case "$n" in
        1) run_test "${p}test1_rand4kw"            "$run" --rw=randwrite --bs=4k  --numjobs=4  --iodepth=32 ;;
        2) run_test "${p}test2_dbmixed"            "$run" --rw=randrw --rwmixread=75 --bs=8k  --numjobs=8  --iodepth=16 ;;
        3) run_test "${p}test3_highconc"           "$run" --rw=randrw --rwmixread=70 --bs=4k  --numjobs=16 --iodepth=8  ;;
        4) run_test "${p}test4_oltp"               "$run" --rw=randrw --rwmixread=70 --bs=16k --numjobs=6  --iodepth=16 ;;
        5) run_test "${p}test5_partial_stripe"     "$run" --rw=randwrite --bs=8k  --numjobs=4  --iodepth=32 ;;
        8) run_test "${p}test8_seqwrite1m"         "$run" --rw=write --bs=1M --numjobs=4 --iodepth=8 \
               --size="$SEQ_SPAN" --offset_increment="$SEQ_SPAN" ;;
        9) run_test "${p}test9_seqread1m"          "$run" --rw=read  --bs=1M --numjobs=4 --iodepth=8 \
               --size="$SEQ_SPAN" --offset_increment="$SEQ_SPAN" ;;
        10) run_test "${p}test10_randread4k"        "$run" --rw=randread --bs=4k --numjobs=4 --iodepth=16 ;;
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

# member_slot <dev>: the RaidDevice slot of a current member (empty if not one)
member_slot() {
    sudo "$MDADM" --detail "$TARGET" 2>/dev/null | awk -v v="$(readlink -f "$1")" \
        '$NF == v && $1 ~ /^[0-9]+$/ {print $4; exit}'
}
is_member() { [ -e "/sys/block/$MDNAME/md/dev-$(basename "$(readlink -f "$1")")" ]; }
is_dcl() {
    local lw; lw=$(cat "/sys/block/$MDNAME/md/layout" 2>/dev/null)
    [ -n "$lw" ] && [ $(( lw & 0x400 )) -ne 0 ]
}
fail_remove() {	# fail and remove a member; remember a declustered victim's slot
    is_dcl && DCL_SLOT=$(member_slot "$1")
    sudo "$MDADM" --fail   "$TARGET" "$1" >/dev/null
    sudo "$MDADM" --remove "$TARGET" "$1" >/dev/null
}

# load_fio <seqread|randread> <json>: start a foreground workload that runs
# until signalled; LOAD_PID is the fio process
load_fio() {
    local args
    case "$1" in
        seqread)  args=(--rw=read --bs=1M --numjobs=4 --iodepth=8 --size="$SEQ_SPAN" --offset_increment="$SEQ_SPAN") ;;
        randread) args=(--rw=randread --bs=4k --numjobs=4 --iodepth=16) ;;
    esac
    fio --output-format=json --output="$2" --filename="$TARGET" --direct=1 --ioengine=libaio \
        --time_based --runtime=864000 --group_reporting --name="load_$1" "${args[@]}" > /dev/null 2>&1 &
    LOAD_PID=$!
}

# rebuild_test [load]: Test 7 (no load) or Test 7L (under a foreground load).
# Fails the victim unless it is already out of the array, then times FULL
# reconstruction of its content; under a load, the foreground starts as soon
# as recovery is running and stops when it ends.  A declustered array populates the
# distributed spare (rk_dcl_populate); a classic array recovers onto the
# re-added member.  Writes test7_rebuild.json or test7L_<load>_rebuild.json.
rebuild_test() {
    local load="${1:-}"
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
    local dcl=0
    is_dcl && dcl=1
    if [ "$dcl" = 1 ] && [ -n "$load" ]; then
        echo "  7L: skipped for $load — a declustered array populates once; a loaded populate needs its own run"
        return 0
    fi

    # wait out any in-flight sync (e.g. the Test-6 consistency check)
    while [ "$(cat "/sys/block/$md/md/sync_action" 2>/dev/null)" != idle ]; do sleep 0.5; done

    local vmib; vmib=$(( $(sudo blockdev --getsize64 "$victim") / 1048576 ))

    # run the rebuild at full speed down to the floor (restore limits afterwards)
    local omax omin
    omax=$(cat /proc/sys/dev/raid/speed_limit_max)
    omin=$(cat /proc/sys/dev/raid/speed_limit_min)
    echo 8000000 | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
    echo "$REBUILD_FLOOR" | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null

    local t0 t1 c0 c1 json
    if [ -n "$load" ]; then
        json="$OUTPUT/test7L_${load}_rebuild.json"
    else
        json="$OUTPUT/test7_rebuild.json"
    fi
    is_member "$victim" && fail_remove "$victim"
    LOAD_PID=
    if [ "$dcl" = 1 ]; then
        [ -n "$DCL_SLOT" ] || { echo "warning: declustered victim slot unknown — skipping rebuild test" >&2; return 1; }
        t0=$(date +%s.%N); c0=$(cpu_snap)
        echo "$DCL_SLOT" | sudo tee "/sys/block/$md/md/rk_dcl_populate" >/dev/null
        while :; do
            case "$(cat "/sys/block/$md/md/rk_dcl_populate" 2>/dev/null)" in
                populated*) break ;;
            esac
            sleep 0.3
        done
        t1=$(date +%s.%N); c1=$(cpu_snap)
    else
        sudo "$MDADM" --zero-superblock "$victim" 2>/dev/null || true
        sudo dd if=/dev/zero of="$victim" bs=1M count=64 status=none
        t0=$(date +%s.%N); c0=$(cpu_snap)
        sudo "$MDADM" --add "$TARGET" "$victim" >/dev/null
        local saw=0 a deg i
        if [ -n "$load" ]; then
            # Start the foreground once recovery runs, as an operator would:
            # with a heavy degraded read already in flight, stock raid456
            # (6.12, 256 stripes) was seen not to start recovery onto an
            # added spare at all until the load stopped.
            for i in $(seq 600); do
                [ "$(cat "/sys/block/$md/md/sync_action" 2>/dev/null)" = recover ] && { saw=1; break; }
                [ "$(cat "/sys/block/$md/md/degraded" 2>/dev/null)" = 0 ] && break
                sleep 0.1
            done
            load_fio "$load" "$OUTPUT/test7L_${load}_load.json"
        fi
        while :; do
            a=$(cat "/sys/block/$md/md/sync_action" 2>/dev/null) || break
            [ "$a" = recover ] && saw=1
            if [ "$a" = idle ]; then
                deg=$(cat "/sys/block/$md/md/degraded" 2>/dev/null)
                { [ "$saw" = 1 ] || [ "$deg" = 0 ]; } && break
            fi
            sleep 0.3
        done
        t1=$(date +%s.%N); c1=$(cpu_snap)
    fi
    if [ -n "$LOAD_PID" ]; then
        kill -INT "$LOAD_PID" 2>/dev/null || true	# fio writes its JSON on SIGINT
        wait "$LOAD_PID" 2>/dev/null || true
    fi

    echo "$omax" | sudo tee /proc/sys/dev/raid/speed_limit_max >/dev/null
    echo "$omin" | sudo tee /proc/sys/dev/raid/speed_limit_min >/dev/null

    local secs mibps cores kind lmib liops label
    secs=$(python3 -c "print(f'{$t1-$t0:.1f}')")
    mibps=$(python3 -c "print(f'{$vmib/($t1-$t0):.0f}')" 2>/dev/null || echo '?')
    cores=$(busy_cores "$c0" "$c1")
    [ "$dcl" = 1 ] && kind="declustered populate" || kind="classic recover"
    if [ -n "$load" ]; then
        read -r lmib liops < <(python3 -c '
import json, sys
try:
    t = open(sys.argv[1]).read()           # fio prefixes "terminating on signal 2"
    j = json.loads(t[t.index("{"):])["jobs"][0]
    print(f"{(j["read"]["bw"] + j["write"]["bw"]) / 1024:.0f} {j["read"]["iops"] + j["write"]["iops"]:.0f}")
except Exception:
    print("? ?")' "$OUTPUT/test7L_${load}_load.json")
        label="7L $load"
        printf "  %s: %ss  (%s of %d MiB member, %s MiB/s, %s busy cores; foreground %s MiB/s, %s IOPS)\n" \
            "$label" "$secs" "$kind" "$vmib" "$mibps" "$cores" "$lmib" "$liops"
        REBUILD_LOAD_SUMMARY+="$load ${secs}s ${mibps} MiB/s, fg ${lmib} MiB/s; "
    else
        printf "  7: %ss  (%s of %d MiB member, %s MiB/s, %s busy cores)\n" "$secs" "$kind" "$vmib" "$mibps" "$cores"
        REBUILD_SECS=$secs
    fi
    printf '{"kind": "%s", "load": "%s", "member_mib": %d, "secs": %s, "mibps": %s, "busy_cores": %s, "load_mibps": %s, "load_iops": %s}\n' \
        "$kind" "${load:-none}" "$vmib" "$secs" "${mibps/\?/null}" "$cores" "${lmib:-null}" "${liops:-null}" \
        | sed 's/: ?,/: null,/g; s/: ?}/: null}/' > "$json"
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

# Degraded phase: one member failed, the degraded workloads run once.
declare -A DEG_RESULTS
if [ -n "$DEGRADED_VICTIM" ]; then
    echo "=== Degraded: $DEGRADED_VICTIM failed and removed ==="
    if [ -z "$MDNAME" ]; then
        echo "  skipped: $TARGET is not an md array" >&2
    else
        resolve_mdadm || exit 1
        wait_sync_idle
        fail_remove "$DEGRADED_VICTIM"
        for n in $DEGRADED_WORKLOADS; do
            iops=$(run_workload "$n" 1 deg_)
            DEG_RESULTS[$n]="$iops"
            printf "  %s: %s IOPS — degraded %s\n" "$n" "$iops" "${WORKLOAD_DESC[$n]}"
            printf "     members: %s\n" "$(member_line "deg_${WORKLOAD_NAME[$n]}" 1)"
        done
    fi
    echo
fi

# Test 7: rebuild / populate wall-clock (only if a victim was named), then
# Test 7L: the same rebuild under each foreground load.
REBUILD_LOAD_SUMMARY=
if [ -n "$REBUILD_VICTIM" ]; then
    echo "=== Test 7: rebuild wall-clock (victim $REBUILD_VICTIM) ==="
    rebuild_test || echo "  7: rebuild test skipped/failed"
    for l in $REBUILD_LOAD; do
        rebuild_test "$l" || echo "  7L: rebuild under $l skipped/failed"
    done
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
for n in "${!DEG_RESULTS[@]}"; do
    printf "%-5s %-50s %s IOPS\n" "d$n" "Degraded ${WORKLOAD_DESC[$n]}" "${DEG_RESULTS[$n]}"
done
if [ -n "$REBUILD_SECS" ]; then
    printf "%-5s %-50s %s\n" "7" "Rebuild / populate wall-clock" "${REBUILD_SECS}s"
fi
if [ -n "$REBUILD_LOAD_SUMMARY" ]; then
    printf "%-5s %-50s %s\n" "7L" "Rebuild under foreground load" "$REBUILD_LOAD_SUMMARY"
fi

echo
echo "Raw fio JSON files in: $OUTPUT"

if [ -n "$MISMATCH" ] && [ "$MISMATCH" != 0 ]; then
    echo "FAIL: parity check found mismatch_cnt=$MISMATCH" >&2
    exit 3
fi
