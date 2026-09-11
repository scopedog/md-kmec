#!/bin/bash
#
# raidkm-ab-benchmark.sh — A/B benchmark raidkm against stock md on the SAME disks
#
# Builds each arm on the same member devices, runs raidkm-standard-benchmark.sh
# against it, tears it down, and finally prints per-workload means and ratios
# against a baseline arm (IOPS, MiB/s, p99 latency, optional rebuild time).
# Arms run in ABBA order — round 1 forward, round 2 reversed, ... — so device
# drift (NVMe GC, thermals, cache warm-up) does not systematically favour one.
#
# Arms (--arms, comma-separated; the first is the baseline unless --baseline):
#   raw            the first member device alone, no md: the device ceiling
#   raid5, raid6   md raid456 as `modprobe raid456` resolves it.  A box with the
#                  mdraid fork's kmods installed resolves the FORK's raid456
#                  (extra/mdraid) — the summary records which one ran
#   raid5-intree, raid6-intree
#                  the distro kernel's own raid456 (kernel/drivers/md), swapped
#                  in for the arm and swapped back at exit
#   raidkm<M>      raidkm with M parity, rotating layout (raidkm2, raidkm3, ...).
#                  raidkm2 stores the same bytes as raid6: the cleanest A/B pair
#
# Every md arm is created with the same member list, chunk, bitmap setting and
# --assume-clean (so no initial resync competes with fio, and the post-run
# parity check is skipped: an assume-clean array over dirty disks is not
# parity-consistent).  Tuning knobs are left at each personality's defaults
# unless --gtc / --stripe-cache are given; the values in force are recorded
# per arm, so "out of the box" and "matched knobs" runs are both reportable.
#
# DESTRUCTIVE: every member device is overwritten.  Run with --dry-run first:
# it validates the arguments and devices and prints every command each arm
# would run, touching nothing.
#
# Usage:
#   sudo bash tools/raidkm-ab-benchmark.sh --devs="/dev/nvme0n1 ... /dev/nvme0n6" [options]
#   bash tools/raidkm-ab-benchmark.sh --devs="..." --arms=... --dry-run
#
# What each arm runs (6 members, defaults; --dry-run prints the exact lines):
#   raid6          modprobe raid456
#   raid6-intree   rmmod dm_raid raid456
#                  insmod /lib/modules/$(uname -r)/kernel/drivers/md/raid456.ko*
#       then:      mdadm --zero-superblock <each member>; wipefs -a <each member>
#                  mdadm --create /dev/md70 --level=6 --raid-devices=6 --chunk=64 \
#                        --bitmap=none --assume-clean --run --force /dev/nvme0n{1..6}
#   raidkm2        modprobe isal_lib; modprobe raidkm   (insmod from the build tree
#                  when km/raidkm.ko exists next to tools/)
#       then:      mdadm --zero-superblock / wipefs as above
#                  mdadm --create /dev/md70 --level=raidkm --parity-count=2 \
#                        --layout=rotating --raid-devices=6 --chunk=64 \
#                        --bitmap=none --assume-clean --run --force /dev/nvme0n{1..6}
#   raw            wipefs -a <each member>; fio runs on the first member directly
#   every md arm, --gtc / --stripe-cache given:
#                  echo N > /sys/block/md70/md/group_thread_cnt
#                  echo N > /sys/block/md70/md/stripe_cache_size
#   every arm:     raidkm-standard-benchmark.sh --target=<md or raw dev> --runs=1 \
#                        --runtime=30 --output=DIR/<arm>/round<R> --no-check
#   teardown:      mdadm --stop /dev/md70; mdadm --zero-superblock + wipefs -a <each member>
#
# Options:
#   --devs="D1 D2 ..."  member devices (required, at least 4)
#   --arms=LIST         arms to compare (default raid6,raidkm2)
#   --baseline=ARM      ratio denominator (default: the first arm)
#   --rounds=N          ABBA rounds; each arm runs N times (default 2)
#   --runtime=SEC       seconds per fio workload (default 30)
#   --quick             --runtime=5 --rounds=1, for a smoke run
#   --chunk=KB          md chunk size for every md arm (default 64)
#   --bitmap=MODE       none | internal (default none)
#   --gtc=N             set group_thread_cnt on every md arm
#   --stripe-cache=N    set stripe_cache_size on every md arm
#   --rebuild           also time a rebuild of the last member (Test 7) per md run
#   --precondition      sequential full write of every member before the first arm
#   --output=DIR        results directory (default /var/tmp/raidkm-ab-<timestamp>)
#   --md=DEV            md node to create the arms on (default /dev/md70)
#   --mdadm=PATH        raidkm-aware mdadm (default: auto-resolved)
#   --force             proceed even if a member carries a filesystem/RAID signature
#   --dry-run           validate and print each arm's commands; change nothing
#                       (no root needed; exit 1 if a pre-flight check would fail)
#   -h, --help          show this help
#
# Output: DIR/summary.md (tables), DIR/summary.csv (one row per arm+workload),
# DIR/<arm>/round<R>/ (fio JSON + log), DIR/<arm>/round<R>/arm.env (geometry,
# tuning, module identity).  Exit status is non-zero if any arm run failed.
#

# No pipefail: raidkm-test-lib.sh tests `lsmod | grep -q`, which under pipefail
# spuriously fails when grep exits early and lsmod takes SIGPIPE.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BENCH="$DIR/raidkm-standard-benchmark.sh"

DEVS=
ARMS=raid6,raidkm2
BASELINE=
ROUNDS=2
RUNTIME=30
CHUNK=64
BITMAP=none
GTC=
SCS=
REBUILD=0
PRECOND=0
OUTPUT=
FORCE=0
DRYRUN=0
MD_ARG=
MDADM_ARG=

usage() {
	sed -n '3,/^$/p' "$0" | sed 's/^# \?//'
	exit 0
}

die() { echo "ERROR: $*" >&2; exit 1; }

# A pre-flight problem: fatal for a real run; --dry-run reports every one
# and exits non-zero at the end instead of stopping at the first.
PREFLIGHT_BAD=0
preflight_fail() {
	if [ "$DRYRUN" = 1 ]; then
		echo "PRE-FLIGHT: $*" >&2
		PREFLIGHT_BAD=1
	else
		die "$*"
	fi
}

for arg in "$@"; do
	case "$arg" in
	--devs=*)         DEVS="${arg#*=}" ;;
	--arms=*)         ARMS="${arg#*=}" ;;
	--baseline=*)     BASELINE="${arg#*=}" ;;
	--rounds=*)       ROUNDS="${arg#*=}" ;;
	--runtime=*)      RUNTIME="${arg#*=}" ;;
	--quick)          RUNTIME=5; ROUNDS=1 ;;
	--chunk=*)        CHUNK="${arg#*=}" ;;
	--bitmap=*)       BITMAP="${arg#*=}" ;;
	--gtc=*)          GTC="${arg#*=}" ;;
	--stripe-cache=*) SCS="${arg#*=}" ;;
	--rebuild)        REBUILD=1 ;;
	--precondition)   PRECOND=1 ;;
	--output=*)       OUTPUT="${arg#*=}" ;;
	--md=*)           MD_ARG="${arg#*=}" ;;
	--mdadm=*)        MDADM_ARG="${arg#*=}" ;;
	--force)          FORCE=1 ;;
	--dry-run)        DRYRUN=1 ;;
	-h|--help)        usage ;;
	*)                die "unknown option: $arg (see --help)" ;;
	esac
done

[ "$DRYRUN" = 1 ] || [ "$(id -u)" = 0 ] || die "run as root (sudo)"
[ -n "$DEVS" ] || die "--devs is required"
case "$BITMAP" in none|internal) ;; *) die "--bitmap must be none or internal" ;; esac
for v in ROUNDS RUNTIME CHUNK; do
	[[ "${!v}" =~ ^[1-9][0-9]*$ ]] || die "--${v,,} must be a positive integer"
done
for t in fio python3 blkid wipefs udevadm; do
	command -v "$t" >/dev/null || preflight_fail "$t not found"
done
[ -r "$BENCH" ] || die "$BENCH not found"

# MD / MDADM feed raidkm-test-lib.sh (module loading, mdadm resolution).
MD="${MD_ARG:-/dev/md70}"
MDADM="$MDADM_ARG"
# shellcheck source=raidkm-test-lib.sh
. "$DIR/raidkm-test-lib.sh"
if ! rk_resolve_mdadm; then
	[ "$DRYRUN" = 1 ] || exit 1
	PREFLIGHT_BAD=1
	MDADM=mdadm
fi

read -r -a MEMBERS <<< "$DEVS"
N=${#MEMBERS[@]}
[ "$N" -ge 4 ] || die "need at least 4 member devices, got $N"
LAST_MEMBER="${MEMBERS[$((N - 1))]}"

IFS=, read -r -a ARM_LIST <<< "$ARMS"
[ "${#ARM_LIST[@]}" -ge 1 ] || die "--arms is empty"
BASELINE="${BASELINE:-${ARM_LIST[0]}}"
[[ ",$ARMS," == *",$BASELINE,"* ]] || die "--baseline=$BASELINE is not one of --arms"

NEED_RAIDKM=0
NEED_INTREE=0
for arm in "${ARM_LIST[@]}"; do
	case "$arm" in
	raw) ;;
	raid5|raid5-intree) [ "$N" -ge 3 ] || die "$arm needs >= 3 members" ;;
	raid6|raid6-intree) ;;
	raidkm[0-9]*)
		m="${arm#raidkm}"
		[[ "$m" =~ ^[0-9]+$ ]] || die "bad arm '$arm' (want raidkm<M>)"
		[ "$m" -ge 2 ] || die "$arm: raidkm needs M >= 2"
		[ $((N - m)) -ge 2 ] || die "$arm: $N members leave k=$((N - m)) data disks, need >= 2"
		NEED_RAIDKM=1 ;;
	*) die "unknown arm '$arm' (raw, raid5, raid6, raid5-intree, raid6-intree, raidkm<M>)" ;;
	esac
	[[ "$arm" == *-intree ]] && NEED_INTREE=1
done

# ---- member pre-flight ------------------------------------------------------

for d in "${MEMBERS[@]}"; do
	[ -b "$d" ] || { preflight_fail "$d is not a block device"; continue; }
	real=$(readlink -f "$d")
	b=$(basename "$real")
	if [ -n "$(ls -A "/sys/class/block/$b/holders" 2>/dev/null)" ]; then
		preflight_fail "$d is in use by $(ls "/sys/class/block/$b/holders" | tr '\n' ' ')"
	fi
	findmnt -rn -S "$real" >/dev/null 2>&1 && preflight_fail "$d is mounted"
	if [ "$FORCE" != 1 ] && [ -n "$(blkid -p -o value -s TYPE "$real" 2>/dev/null)" ]; then
		preflight_fail "$d carries a $(blkid -p -o value -s TYPE "$real") signature — re-run with --force to overwrite it"
	elif [ "$DRYRUN" = 1 ] && [ "$(id -u)" != 0 ] && [ ! -r "$real" ]; then
		echo "NOTE: $d is not readable without root — its signature check was skipped" >&2
	fi
done
[ -e "$MD" ] && [ -d "/sys/block/$(basename "$(readlink -f "$MD")")/md" ] &&
	[ "$(cat "/sys/block/$(basename "$(readlink -f "$MD")")/md/array_state" 2>/dev/null)" != clear ] &&
	preflight_fail "$MD is an active array — stop it or pass --md=/dev/mdNN"

# ---- module identity + raid456 flavour switching ----------------------------

KVER=$(uname -r)
INTREE_456=$(ls "/lib/modules/$KVER/kernel/drivers/md/raid456.ko"* 2>/dev/null | head -1)
INTREE_SV=
[ -n "$INTREE_456" ] && INTREE_SV=$(modinfo -F srcversion "$INTREE_456" 2>/dev/null)
DEFAULT_456=$(modinfo -n raid456 2>/dev/null)
DEFAULT_SV=$(modinfo -F srcversion raid456 2>/dev/null)
mod_loaded() { [ -e "/sys/module/$1/initstate" ]; }   # loadable module present
ORIG_456_SV=$(cat /sys/module/raid456/srcversion 2>/dev/null)
ORIG_DM_RAID=0
mod_loaded dm_raid && ORIG_DM_RAID=1
[ "$NEED_INTREE" = 1 ] && [ -z "$INTREE_456" ] &&
	preflight_fail "an -intree arm was requested but $KVER has no kernel/drivers/md/raid456.ko*"

loaded_456_sv() { cat /sys/module/raid456/srcversion 2>/dev/null; }

describe_456() {
	local sv; sv=$(loaded_456_sv)
	if [ -z "$sv" ]; then
		echo "raid456 not loaded"
	elif [ -n "$INTREE_SV" ] && [ "$sv" = "$INTREE_SV" ]; then
		echo "in-tree $INTREE_456 (srcversion $sv)"
	elif [ "$sv" = "$DEFAULT_SV" ]; then
		echo "$DEFAULT_456 (srcversion $sv)"
	else
		echo "unknown raid456 (srcversion $sv)"
	fi
}

unload_456() {
	mod_loaded raid456 || return 0
	rmmod dm_raid 2>/dev/null
	rmmod raid456 || die "cannot unload raid456 (a raid4/5/6 array or dm-raid LV is using it)"
}

# use_456 default|intree : make the requested raid456 the loaded one
use_456() {
	local want_sv m
	[ "$1" = intree ] && want_sv="$INTREE_SV" || want_sv="$DEFAULT_SV"
	[ -n "$(loaded_456_sv)" ] && [ "$(loaded_456_sv)" = "$want_sv" ] && return 0
	unload_456
	if [ "$1" = intree ]; then
		for m in md_mod libcrc32c xor raid6_pq async_tx async_memcpy async_xor \
			 async_pq async_raid6_recov; do
			modprobe "$m" 2>/dev/null
		done
		insmod "$INTREE_456" || die "insmod $INTREE_456 failed"
	else
		modprobe raid456 || die "modprobe raid456 failed"
	fi
	[ "$(loaded_456_sv)" = "$want_sv" ] ||
		die "loaded raid456 srcversion $(loaded_456_sv) is not the requested $1 ($want_sv)"
}

# ---- arm lifecycle ----------------------------------------------------------

ARM_UP=0

wipe_members() {
	local d
	for d in "${MEMBERS[@]}"; do
		"$MDADM" --zero-superblock "$d" >/dev/null 2>&1
		wipefs -a -q "$d" >/dev/null 2>&1
	done
}

teardown_arm() {
	[ "$ARM_UP" = 1 ] || return 0
	local d b h
	"$MDADM" --stop "$MD" >/dev/null 2>&1
	udevadm settle
	wipe_members
	udevadm settle
	# udev incremental assembly can grab members into an mdNNN of its own after
	# the stop; stop exactly those arrays (never --stop --scan: other arrays on
	# this box are not ours)
	for d in "${MEMBERS[@]}"; do
		b=$(basename "$(readlink -f "$d")")
		for h in $(ls "/sys/class/block/$b/holders" 2>/dev/null); do
			[[ "$h" == md* ]] && "$MDADM" --stop "/dev/$h" >/dev/null 2>&1
		done
	done
	wipe_members
	ARM_UP=0
}

cleanup() {
	teardown_arm
	# put raid456 (and a dm_raid we unloaded to swap it) back the way we found it
	if [ "$(loaded_456_sv)" != "$ORIG_456_SV" ]; then
		if [ -z "$ORIG_456_SV" ]; then
			unload_456
		elif [ -n "$INTREE_SV" ] && [ "$ORIG_456_SV" = "$INTREE_SV" ]; then
			use_456 intree
		else
			use_456 default
		fi
	fi
	[ "$ORIG_DM_RAID" = 1 ] && modprobe dm_raid 2>/dev/null
	return 0
}
md_attr() { cat "/sys/block/$(basename "$(readlink -f "$MD")")/md/$1" 2>/dev/null; }

# arm_create_cmd <arm> : set CREATE_CMD to the arm's mdadm --create (empty for raw)
arm_create_cmd() {
	local arm="$1" lvl
	CREATE_CMD=()
	case "$arm" in
	raw) ;;
	raidkm*)
		CREATE_CMD=("$MDADM" --create "$MD" --level=raidkm --parity-count="${arm#raidkm}"
			--layout=rotating --raid-devices="$N" --chunk="$CHUNK"
			--bitmap="$BITMAP" --assume-clean --run --force "${MEMBERS[@]}") ;;
	*)
		lvl="${arm#raid}"; lvl="${lvl%-intree}"
		CREATE_CMD=("$MDADM" --create "$MD" --level="$lvl"
			--raid-devices="$N" --chunk="$CHUNK"
			--bitmap="$BITMAP" --assume-clean --run --force "${MEMBERS[@]}") ;;
	esac
}

# arm_bench_args <arm> <dir> <target> : set BENCH_ARGS for raidkm-standard-benchmark.sh
arm_bench_args() {
	BENCH_ARGS=(--target="$3" --runs=1 --runtime="$RUNTIME" --output="$2" --no-check)
	if [ "$REBUILD" = 1 ] && [ "$1" != raw ]; then
		BENCH_ARGS+=(--rebuild-victim="$LAST_MEMBER" --mdadm="$MDADM")
	fi
}

# create_arm <arm> : build the arm; sets TARGET
create_arm() {
	local arm="$1"
	case "$arm" in
	raw)
		wipe_members
		TARGET="${MEMBERS[0]}"
		return 0 ;;
	raid5|raid6)               use_456 default ;;
	raid5-intree|raid6-intree) use_456 intree ;;
	raidkm*)                   rk_load_modules || die "raidkm module not loadable" ;;
	esac
	wipe_members
	udevadm settle
	ARM_UP=1
	arm_create_cmd "$arm"
	printf 'y\n' | "${CREATE_CMD[@]}" || die "$arm: mdadm --create failed"
	udevadm settle
	[ -n "$GTC" ] && { echo "$GTC" > "/sys/block/$(basename "$(readlink -f "$MD")")/md/group_thread_cnt" ||
		die "$arm: cannot set group_thread_cnt=$GTC"; }
	[ -n "$SCS" ] && { echo "$SCS" > "/sys/block/$(basename "$(readlink -f "$MD")")/md/stripe_cache_size" ||
		die "$arm: cannot set stripe_cache_size=$SCS"; }
	TARGET="$MD"
}

# record_arm <arm> <dir> : geometry, tuning and module identity actually in force
record_arm() {
	local arm="$1" out="$2/arm.env"
	{
		echo "arm=$arm"
		echo "date=$(date -Iseconds)"
		echo "host=$(hostname)"
		echo "kernel=$KVER"
		echo "members=${MEMBERS[*]}"
		echo "target=$TARGET"
		if [ "$arm" != raw ]; then
			echo "level=$(md_attr level)"
			echo "raid_disks=$(md_attr raid_disks)"
			echo "chunk_size=$(md_attr chunk_size)"
			echo "layout=$(md_attr layout)"
			echo "bitmap=$BITMAP"
			echo "group_thread_cnt=$(md_attr group_thread_cnt)"
			echo "stripe_cache_size=$(md_attr stripe_cache_size)"
			echo "skip_copy=$(md_attr skip_copy)"
			echo "preread_bypass_threshold=$(md_attr preread_bypass_threshold)"
			echo "mdadm=$MDADM ($("$MDADM" --version 2>&1 | head -1))"
		fi
		case "$arm" in
		raid*-*|raid5|raid6) echo "module=$(describe_456)" ;;
		raidkm*) echo "module=raidkm $([ -f "$RAIDKM_KO" ] && echo "$RAIDKM_KO" || modinfo -n raidkm 2>/dev/null) (srcversion $(cat /sys/module/raidkm/srcversion 2>/dev/null))" ;;
		esac
	} > "$out"
}

# ---- run --------------------------------------------------------------------

OUTPUT="${OUTPUT:-/var/tmp/raidkm-ab-$(date +%Y%m%d-%H%M%S)}"

ORDER=()
for r in $(seq 1 "$ROUNDS"); do
	if [ $((r % 2)) = 1 ]; then
		for arm in "${ARM_LIST[@]}"; do ORDER+=("$r:$arm"); done
	else
		for ((i = ${#ARM_LIST[@]} - 1; i >= 0; i--)); do ORDER+=("$r:${ARM_LIST[$i]}"); done
	fi
done

echo "raidkm-ab-benchmark.sh"
echo "  members:   ${MEMBERS[*]} (N=$N)"
echo "  arms:      ${ARM_LIST[*]}  (baseline $BASELINE)"
echo "  order:     ${ORDER[*]}"
echo "  chunk:     ${CHUNK}K  bitmap=$BITMAP  gtc=${GTC:-default}  stripe_cache=${SCS:-default}"
echo "  runtime:   ${RUNTIME}s x 5 workloads per arm run  (~$(( ${#ORDER[@]} * 5 * (RUNTIME + 3) / 60 )) min of fio)"
echo "  raid456:   modprobe -> ${DEFAULT_456:-none}${INTREE_456:+;  in-tree -> $INTREE_456}"
echo "  output:    $OUTPUT"
if [ "$DRYRUN" = 1 ]; then
	echo "  DRY RUN:   nothing below is executed"
else
	echo "  WARNING:   all member devices will be overwritten"
fi
echo

# --dry-run: print the commands of each distinct arm, then stop.
if [ "$DRYRUN" = 1 ]; then
	q() { printf '%q ' "$@"; echo; }
	mdsys="/sys/block/$(basename "$MD")/md"
	if [ "$PRECOND" = 1 ]; then
		echo "== preconditioning (once) =="
		printf '  '; q fio --direct=1 --ioengine=libaio --rw=write --bs=1M --iodepth=8 \
			$(for i in "${!MEMBERS[@]}"; do echo "--name=precond$i --filename=${MEMBERS[$i]}"; done)
		echo
	fi
	for arm in "${ARM_LIST[@]}"; do
		echo "== arm $arm =="
		case "$arm" in
		raid5|raid6)
			[ -n "$(loaded_456_sv)" ] && [ "$(loaded_456_sv)" != "$DEFAULT_SV" ] &&
				echo "  rmmod dm_raid raid456        # the loaded raid456 is not the modprobe default"
			echo "  modprobe raid456             # -> ${DEFAULT_456:-?}" ;;
		raid5-intree|raid6-intree)
			echo "  rmmod dm_raid raid456"
			echo "  insmod ${INTREE_456:-<no in-tree raid456.ko>}   # distro raid456; the original is restored at exit" ;;
		raidkm*)
			if [ -f "$ISAL_KO" ]; then echo "  insmod $ISAL_KO"; else echo "  modprobe isal_lib"; fi
			if [ -f "$RAIDKM_KO" ]; then
				echo "  insmod $RAIDKM_KO"
			else
				echo "  modprobe raidkm              # -> $(modinfo -n raidkm 2>/dev/null || echo '? (not installed)')"
			fi ;;
		esac
		for d in "${MEMBERS[@]}"; do
			[ "$arm" = raw ] || { printf '  '; q "$MDADM" --zero-superblock "$d"; }
			printf '  '; q wipefs -a "$d"
		done
		arm_create_cmd "$arm"
		if [ "${#CREATE_CMD[@]}" -gt 0 ]; then
			printf '  '; q "${CREATE_CMD[@]}"
			[ -n "$GTC" ] && echo "  echo $GTC > $mdsys/group_thread_cnt"
			[ -n "$SCS" ] && echo "  echo $SCS > $mdsys/stripe_cache_size"
			arm_bench_args "$arm" "$OUTPUT/$arm/round<R>" "$MD"
		else
			arm_bench_args "$arm" "$OUTPUT/$arm/round<R>" "${MEMBERS[0]}"
		fi
		printf '  '; q bash "$BENCH" "${BENCH_ARGS[@]}"
		if [ "$arm" != raw ]; then
			printf '  '; q "$MDADM" --stop "$MD"
			echo "  (then --zero-superblock + wipefs -a on each member again)"
		fi
		echo
	done
	echo "then: summary tables in $OUTPUT/summary.md, ratios vs $BASELINE"
	[ "$PREFLIGHT_BAD" = 0 ] || { echo "PRE-FLIGHT problems above: a real run would stop" >&2; exit 1; }
	exit 0
fi

trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir -p "$OUTPUT" || die "cannot create $OUTPUT"

if [ "$PRECOND" = 1 ]; then
	echo "=== preconditioning: sequential fill of every member ==="
	wipe_members
	args=(--direct=1 --ioengine=libaio --rw=write --bs=1M --iodepth=8)
	for i in "${!MEMBERS[@]}"; do args+=(--name="precond$i" --filename="${MEMBERS[$i]}"); done
	fio "${args[@]}" >"$OUTPUT/precondition.log" 2>&1 || die "preconditioning failed (see $OUTPUT/precondition.log)"
	echo
fi

FAILED=0
for entry in "${ORDER[@]}"; do
	r="${entry%%:*}"
	arm="${entry#*:}"
	dir="$OUTPUT/$arm/round$r"
	mkdir -p "$dir"
	echo "=== round $r: $arm ==="
	create_arm "$arm"
	record_arm "$arm" "$dir"
	grep -E '^(level|raid_disks|chunk_size|group_thread_cnt|stripe_cache_size|module)=' "$dir/arm.env" | sed 's/^/  /'
	arm_bench_args "$arm" "$dir" "$TARGET"
	bash "$BENCH" "${BENCH_ARGS[@]}" 2>&1 | tee "$dir/bench.log"
	if [ "${PIPESTATUS[0]}" != 0 ]; then
		echo "  FAIL: benchmark of $arm (round $r) failed — see $dir/bench.log" >&2
		FAILED=1
	fi
	teardown_arm
	echo
done

# ---- summary ----------------------------------------------------------------

python3 - "$OUTPUT" "$BASELINE" "${ARM_LIST[@]}" <<'PY'
import csv, glob, json, os, re, statistics, sys

out, baseline, arms = sys.argv[1], sys.argv[2], sys.argv[3:]
DESC = {
    "test1_rand4kw": "rand 4K write",
    "test2_dbmixed": "DB 75/25 8K",
    "test3_highconc": "70/30 4K x16 jobs",
    "test4_oltp": "OLTP 70/30 16K",
    "test5_partial_stripe": "partial-stripe 8K write",
}
tests = list(DESC)

def load(path):
    job = json.load(open(path))["jobs"][0]
    iops = bw = 0.0
    p99 = 0.0
    for d in ("read", "write"):
        s = job[d]
        iops += s["iops"]
        bw += s["bw"] / 1024.0          # KiB/s -> MiB/s
        if s["iops"] > 0:
            pct = s.get("clat_ns", {}).get("percentile", {})
            p99 = max(p99, pct.get("99.000000", 0) / 1e6)
    return iops, bw, p99

data = {}       # (arm, test) -> {"iops": [...], "bw": [...], "p99": [...]}
rebuild = {}    # arm -> [secs]
env = {}
for arm in arms:
    for rdir in sorted(glob.glob(os.path.join(out, arm, "round*"))):
        for t in tests:
            f = os.path.join(rdir, f"{t}_run1.json")
            if not os.path.exists(f):
                continue
            iops, bw, p99 = load(f)
            d = data.setdefault((arm, t), {"iops": [], "bw": [], "p99": []})
            d["iops"].append(iops); d["bw"].append(bw); d["p99"].append(p99)
        log = os.path.join(rdir, "bench.log")
        if os.path.exists(log):
            m = re.search(r"^\s+7: ([0-9.]+)s", open(log).read(), re.M)
            if m:
                rebuild.setdefault(arm, []).append(float(m.group(1)))
        e = os.path.join(rdir, "arm.env")
        if os.path.exists(e) and arm not in env:
            env[arm] = dict(l.rstrip("\n").split("=", 1) for l in open(e) if "=" in l)

def mean_cv(v):
    if not v:
        return None, None
    m = statistics.mean(v)
    cv = statistics.stdev(v) / m * 100 if len(v) > 1 and m else 0.0
    return m, cv

lines = []
def emit(s=""):
    lines.append(s)

emit(f"# raidkm A/B benchmark — baseline `{baseline}`")
emit()
emit("| arm | level | disks | chunk | group_thread_cnt | stripe_cache_size | module |")
emit("|---|---|---|---|---|---|---|")
for arm in arms:
    e = env.get(arm, {})
    emit(f"| {arm} | {e.get('level','-')} | {e.get('raid_disks','-')} | {e.get('chunk_size','-')} "
         f"| {e.get('group_thread_cnt','-')} | {e.get('stripe_cache_size','-')} | {e.get('module','-')} |")

noisy = []
rows = []
for metric, label, fmt, higher in (("iops", "IOPS", "{:.0f}", True),
                                   ("bw", "MiB/s", "{:.1f}", True),
                                   ("p99", "p99 latency ms (lower is better)", "{:.2f}", False)):
    emit()
    emit(f"## {label}")
    emit()
    hdr = "| workload | " + " | ".join(arms) + " | " + \
          " | ".join(f"{a}/{baseline}" for a in arms if a != baseline) + " |"
    emit(hdr)
    emit("|" + "---|" * (1 + len(arms) + len(arms) - 1))
    for t in tests:
        base_m, _ = mean_cv(data.get((baseline, t), {}).get(metric, []))
        cells, ratios = [], []
        for arm in arms:
            m, cv = mean_cv(data.get((arm, t), {}).get(metric, []))
            if m is None:
                cells.append("-")
                if arm != baseline:
                    ratios.append("-")
                continue
            cells.append(fmt.format(m) + (f" (cv {cv:.1f}%)" if cv else ""))
            if cv and cv > 5 and metric == "iops":
                noisy.append(f"{arm}/{t} {cv:.0f}%")
            if arm != baseline:
                ratios.append(f"{m / base_m:.2f}x" if base_m else "-")
            rows.append({"arm": arm, "workload": t, "metric": metric, "mean": round(m, 3),
                         "cv_pct": round(cv, 2),
                         "ratio_vs_baseline": round(m / base_m, 4) if base_m else ""})
        emit(f"| {t} ({DESC[t]}) | " + " | ".join(cells) + " | " + " | ".join(ratios) + " |")

if rebuild:
    emit()
    emit("## Rebuild wall-clock, seconds (lower is better)")
    emit()
    b, _ = mean_cv(rebuild.get(baseline, []))
    for arm in arms:
        m, cv = mean_cv(rebuild.get(arm, []))
        if m is None:
            continue
        ratio = ""
        if b and arm != baseline:
            ratio = (f"  ({b / m:.2f}x faster than {baseline})" if m <= b
                     else f"  ({m / b:.2f}x slower than {baseline})")
        emit(f"- {arm}: {m:.1f}s{ratio}")
        rows.append({"arm": arm, "workload": "rebuild", "metric": "seconds", "mean": round(m, 3),
                     "cv_pct": round(cv, 2), "ratio_vs_baseline": round(m / b, 4) if b else ""})

if noisy:
    emit()
    emit(f"**{len(noisy)} arm/workload IOPS means have cv > 5% — a ratio within that "
         "spread is noise; add --rounds or --runtime:** " + ", ".join(noisy))

text = "\n".join(lines) + "\n"
open(os.path.join(out, "summary.md"), "w").write(text)
with open(os.path.join(out, "summary.csv"), "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["arm", "workload", "metric", "mean", "cv_pct", "ratio_vs_baseline"])
    w.writeheader()
    w.writerows(rows)
print(text)
PY

echo "Results: $OUTPUT/summary.md  $OUTPUT/summary.csv"
[ "$FAILED" = 0 ] || { echo "FAIL: at least one arm run failed" >&2; exit 1; }
