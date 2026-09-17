#!/bin/bash
#
# raidkm-ab-benchmark.sh — A/B benchmark raidkm against stock md on the SAME disks
#
# Builds each arm on the same member devices, runs raidkm-standard-benchmark.sh
# against it, tears it down, and finally prints per-workload means and ratios
# against a baseline arm (IOPS, MiB/s, p99 latency, optional rebuild time).
# Arms run in ABBA order — round 1 forward, round 2 reversed, ... — so device
# drift (NVMe GC, thermals, cache warm-up) does not systematically favour one.
# ABBA alone does not cover the FIRST run on the drives: on unconditioned flash
# it is the fast one (fresh NAND, nothing to collect), and the baseline arm
# always holds that slot — on GCP local NVMe (2026-09-13) the baseline's first
# run read 12-26% above every later run of either arm on the write-heavy
# workloads, which alone made stock look 5-9% faster.  So by default one
# untimed warm-up pass of the whole workload set runs first and is discarded
# (--warmup), and --precondition=steady brings every member to steady state
# before that.  The summary lists every run in execution order and flags
# outliers, so a position effect shows instead of hiding in a mean.
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
#   <arm>@<n>      any md arm built on only the FIRST n of --devs, e.g. raid6@10
#                  next to dcl2 on 12 devices: stock 8+2 with two idle disks as
#                  hot spares against declustered 8+2 with two distributed spare
#                  columns — same disks, same usable capacity, one ABBA run.
#                  Every run still wipes all of --devs, so a narrow arm never
#                  inherits a wider arm's superblocks.
#   <arm>+<profile>  the arm with a tuning profile applied after create
#                  (--tune).  The built-in profile "tuned" sets on stock md the
#                  knobs raidkm defaults to, so one run compares
#                  raid6,raid6+tuned,raidkm2: stock out of the box, stock tuned
#                  by hand, and ours.  Combines with @<n>: raid6@10+tuned
#   dcl<M>         raidkm declustered with M parity: stripes of width
#                  --group-width scattered over the whole member pool with
#                  --spare-columns distributed spare columns.  The layout we
#                  recommend on large-IU flash, so it is what a "stock vs our
#                  recommendation" comparison needs; note it uses a WIDER pool
#                  than a matched raid6 arm — a deployment difference, not a
#                  like-for-like geometry
#
# Every md arm is created with the same member list, chunk, bitmap setting and
# --assume-clean (so no initial resync competes with fio, and the post-run
# parity check is skipped: an assume-clean array over dirty disks is not
# parity-consistent).  Tuning knobs are left at each personality's defaults
# unless --gtc / --stripe-cache / --md-attr are given; the values in force are
# recorded per arm, so "out of the box" and "matched knobs" runs are both
# reportable.  --md-attr is best-effort per arm: an attribute an arm does not
# have (the rk_* knobs on a stock raid6 arm, say) is skipped and recorded as
# n/a, which is exactly what "stock keeps its defaults, ours gets our knobs"
# should mean.
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
#   --md-attr=NAME=V    write V to /sys/block/mdX/md/NAME on every md arm after
#                       the create (repeatable).  Best-effort: an arm without
#                       that attribute keeps its own default and the arm record
#                       says "n/a", so one command expresses "stock as it ships
#                       vs ours with our knobs", e.g.
#                       --md-attr=rk_row_rebuild=1 --md-attr=rk_bio_sort=2
#   --group-width=G     dcl<M> arms: stripe width g = k + M (required for dcl)
#   --spare-columns=S   dcl<M> arms: distributed spare columns (default 2)
#   --tune=NAME:ATTR=V[,ATTR=V...]
#                       define tuning profile NAME for <arm>+NAME arms (md sysfs
#                       attributes, applied in order after --gtc/--stripe-cache/
#                       --md-attr; a write that fails stops the run).  Built in:
#                       tuned = group_thread_cnt=max(nproc/(2*numa_nodes),2),
#                       stripe_cache_size=auto (1024, capped near raidkm's
#                       128 MiB budget on very wide arms), skip_copy=1 — raidkm's
#                       own defaults.  --tune=tuned:... replaces it
#   --degraded          per md run, after the healthy workloads: fail the arm's
#                       last member and run --degraded-workloads (default 9,10:
#                       1 MiB sequential read, 4 KiB random read); the summary
#                       adds throughput as % of the same arm's healthy run
#   --degraded-workloads=LIST  workloads for --degraded
#   --rebuild           also time a rebuild of the last member (Test 7) per md run
#                       (from the degraded state when --degraded is given)
#   --rebuild-load=LIST also rebuild it again under each foreground load
#                       (seqread, randread; classic layouts), recording the
#                       rebuild rate and the foreground throughput (Test 7L)
#   --rebuild-floor=KBPS md speed_limit_min during rebuilds (default 500000)
#   --workloads=LIST    workloads passed to raidkm-standard-benchmark.sh
#                       (default 1,2,3,4,5,8,9,10)
#                       (default 1,2,3,4,5,8,9; 8/9 = sequential 1 MiB write/read)
#   --precondition[=seq|steady]
#                       before anything else.  seq (the bare flag): a sequential
#                       full write of every member.  steady: that, then
#                       --precondition-time seconds of 4 KiB random writes over
#                       every member — flash steady state, for write workloads
#   --precondition-time=SEC  length of the steady random-write phase (default 600)
#   --warmup=ARM        one untimed pass of the whole workload set on ARM before
#                       round 1; its results are kept in DIR/warmup/ but never
#                       summarised (default: the baseline arm)
#   --no-warmup         skip the warm-up pass: the first measured run then gets
#                       the drives in whatever state they are in
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
# tuning, module identity), DIR/order.txt (execution order), DIR/warmup/<arm>/
# (the discarded warm-up pass).  Exit status is non-zero if any arm run failed.
#

# No pipefail: raidkm-test-lib.sh tests `lsmod | grep -q`, which under pipefail
# spuriously fails when grep exits early and lsmod takes SIGPIPE.
set -u
# blkid, wipefs, modinfo and friends live in sbin, which a non-root PATH may lack
PATH="$PATH:/usr/sbin:/sbin"

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
REBUILD_LOAD=
REBUILD_FLOOR=
DEGRADED=0
DEG_WORKLOADS=
WORKLOADS=
PRECOND=0
PRECOND_TIME=600
WARMUP=
NO_WARMUP=0
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

MD_ATTRS=()
MD_ATTRS_SET=()
declare -A PROFILES=()
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
	--md-attr=*)      MD_ATTRS+=("${arg#*=}") ;;
	--group-width=*)  DCL_G="${arg#*=}" ;;
	--spare-columns=*) DCL_S="${arg#*=}" ;;
	--rebuild)        REBUILD=1 ;;
	--rebuild-load=*) REBUILD_LOAD="${arg#*=}" ;;
	--rebuild-floor=*) REBUILD_FLOOR="${arg#*=}" ;;
	--degraded)       DEGRADED=1 ;;
	--degraded-workloads=*) DEG_WORKLOADS="${arg#*=}" ;;
	--tune=*)         t="${arg#*=}"
	                  [[ "$t" == *:*=* ]] || die "--tune wants NAME:ATTR=V[,ATTR=V...], got '$t'"
	                  PROFILES["${t%%:*}"]="${t#*:}" ;;
	--precondition|--precondition=seq) PRECOND=1 ;;
	--precondition=steady) PRECOND=2 ;;
	--precondition-time=*) PRECOND_TIME="${arg#*=}" ;;
	--warmup=*)       WARMUP="${arg#*=}" ;;
	--no-warmup)      NO_WARMUP=1 ;;
	--workloads=*)    WORKLOADS="${arg#*=}" ;;
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

# Arm spec: <type>[@<n>][+<profile>].  "@<n>" builds the arm on the first n of
# --devs; "+<profile>" applies a --tune profile after create.
arm_base() { echo "${1%%+*}"; }				# the arm without +<profile>
arm_type() { local a="${1%%+*}"; echo "${a%@*}"; }	# ... and without @<n>
arm_n() { local a="${1%%+*}"; case "$a" in *@*) echo "${a##*@}" ;; *) echo "$N" ;; esac; }
arm_profile() { case "$1" in *+*) echo "${1#*+}" ;; esac; }
arm_select() {					# -> AM (members), AN, ALAST
	AN=$(arm_n "$1")
	AM=("${MEMBERS[@]:0:$AN}")
	ALAST="${AM[$((AN - 1))]}"
}

IFS=, read -r -a ARM_LIST <<< "$ARMS"
[ "${#ARM_LIST[@]}" -ge 1 ] || die "--arms is empty"
DCL_G="${DCL_G:-}"
DCL_S="${DCL_S:-2}"
BASELINE="${BASELINE:-${ARM_LIST[0]}}"
[[ ",$ARMS," == *",$BASELINE,"* ]] || die "--baseline=$BASELINE is not one of --arms"
if [ "$NO_WARMUP" = 1 ]; then
	WARMUP=
else
	WARMUP="${WARMUP:-$BASELINE}"
	[[ ",$ARMS," == *",$WARMUP,"* ]] || die "--warmup=$WARMUP is not one of --arms"
fi
[[ "$PRECOND_TIME" =~ ^[1-9][0-9]*$ ]] || die "--precondition-time must be a positive integer"
[ -z "$REBUILD_LOAD" ] || [ "$REBUILD" = 1 ] || die "--rebuild-load needs --rebuild"
[ -z "$REBUILD_FLOOR" ] || [[ "$REBUILD_FLOOR" =~ ^[1-9][0-9]*$ ]] || die "--rebuild-floor must be a positive integer (KB/s)"
[ -z "$DEG_WORKLOADS" ] || [ "$DEGRADED" = 1 ] || die "--degraded-workloads needs --degraded"

# Built-in "tuned": raidkm's own defaults, for a stock arm tuned by hand.
# group_thread_cnt is per NUMA group, as raidkm's auto-default counts it.
NUMA_NODES=$(python3 -c '
n = 0
for part in open("/sys/devices/system/node/possible").read().strip().split(","):
    a, _, b = part.partition("-")
    n += int(b or a) - int(a) + 1
print(n)' 2>/dev/null || echo 1)
TUNED_GTC=$(( $(nproc) / (2 * NUMA_NODES) ))
[ "$TUNED_GTC" -ge 2 ] || TUNED_GTC=2
[ -n "${PROFILES[tuned]:-}" ] ||
	PROFILES[tuned]="group_thread_cnt=$TUNED_GTC,stripe_cache_size=auto,skip_copy=1"

NEED_RAIDKM=0
NEED_INTREE=0
for arm in "${ARM_LIST[@]}"; do
	t=$(arm_type "$arm"); n=$(arm_n "$arm"); prof=$(arm_profile "$arm")
	if [ -n "$prof" ]; then
		[ "$t" != raw ] || die "$arm: the raw arm takes no +<profile>"
		[ -n "${PROFILES[$prof]:-}" ] || die "$arm: no tuning profile '$prof' (built in: tuned; define one with --tune=$prof:ATTR=V,...)"
	fi
	if [[ "$(arm_base "$arm")" == *@* ]]; then
		[ "$t" != raw ] || die "$arm: the raw arm takes no @<n>"
		[[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 3 ] && [ "$n" -le "$N" ] ||
			die "$arm: @<n> must be 3..$N (the number of --devs)"
	fi
	case "$t" in
	raw) ;;
	raid5|raid5-intree) [ "$n" -ge 3 ] || die "$arm needs >= 3 members" ;;
	raid6|raid6-intree) ;;
	raidkm[0-9]*)
		m="${t#raidkm}"
		[[ "$m" =~ ^[0-9]+$ ]] || die "bad arm '$arm' (want raidkm<M>)"
		[ "$m" -ge 2 ] || die "$arm: raidkm needs M >= 2"
		[ $((n - m)) -ge 2 ] || die "$arm: $n members leave k=$((n - m)) data disks, need >= 2"
		NEED_RAIDKM=1 ;;
	dcl[0-9]*)
		m="${t#dcl}"
		[[ "$m" =~ ^[0-9]+$ ]] || die "bad arm '$arm' (want dcl<M>)"
		[ "$m" -ge 2 ] || die "$arm: declustered needs M >= 2"
		[ -n "$DCL_G" ] || die "$arm: --group-width is required for a dcl arm"
		[ $((DCL_G - m)) -ge 2 ] || die "$arm: group width $DCL_G leaves k=$((DCL_G - m)), need >= 2"
		[ "$n" -gt "$DCL_G" ] || die "$arm: pool ($n) must be WIDER than the group ($DCL_G); equal scatters nothing"
		NEED_RAIDKM=1 ;;
	*) die "unknown arm '$arm' (raw, raid5, raid6, raid5-intree, raid6-intree, raidkm<M>, dcl<M>, each optionally @<n> and +<profile>)" ;;
	esac
	[[ "$t" == *-intree ]] && NEED_INTREE=1
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
ORIG_DM_RAID=0
mod_loaded dm_raid && ORIG_DM_RAID=1
[ "$NEED_INTREE" = 1 ] && [ -z "$INTREE_456" ] &&
	preflight_fail "an -intree arm was requested but $KVER has no kernel/drivers/md/raid456.ko*"

# Which raid456 is loaded.  Kernels built with srcversions let us verify it; on
# kernels without them (e.g. Debian) we track the flavour we loaded ourselves.
# When modprobe already resolves the in-tree file, there is only one flavour.
SV_OK=0
[ -n "$DEFAULT_SV" ] && SV_OK=1
SAME_456=0
[ -n "$INTREE_456" ] && [ "$(readlink -f "$INTREE_456")" = "$(readlink -f "$DEFAULT_456")" ] && SAME_456=1

loaded_456_sv() { cat /sys/module/raid456/srcversion 2>/dev/null; }

# current_456 -> none | default | intree | unknown
current_456() {
	local sv
	mod_loaded raid456 || { echo none; return; }
	if [ "$SV_OK" = 1 ]; then
		sv=$(loaded_456_sv)
		if [ "$SAME_456" = 1 ]; then
			# modprobe resolves to the in-tree file: one flavour, and
			# use_456() normalises every request to "default".  Reporting
			# "intree" here (the srcversions are equal, so the in-tree test
			# below would match first) made the guard fire on every run —
			# on a box with no fork installed, which is exactly the box you
			# benchmark stock on.
			[ "$sv" = "$DEFAULT_SV" ] && echo default || echo unknown
		elif [ -n "$INTREE_SV" ] && [ "$sv" = "$INTREE_SV" ]; then echo intree
		elif [ "$sv" = "$DEFAULT_SV" ]; then echo default
		else echo unknown; fi
	else
		echo "${TRACKED_456:-unknown}"
	fi
}
TRACKED_456=
ORIG_456=$(current_456)

describe_456() {
	case "$(current_456)" in
	none)    echo "raid456 not loaded" ;;
	intree)  echo "in-tree $INTREE_456$( [ "$SV_OK" = 1 ] && echo " (srcversion $(loaded_456_sv))" || echo " (loaded by this script; no srcversion on this kernel)")" ;;
	default) if [ "$SAME_456" = 1 ]; then
			 echo "$DEFAULT_456 (the kernel's only raid456)"
		 else
			 echo "$DEFAULT_456$( [ "$SV_OK" = 1 ] && echo " (srcversion $(loaded_456_sv))" || echo " (loaded by this script; no srcversion on this kernel)")"
		 fi ;;
	*)       echo "raid456 of unknown origin$( [ "$SV_OK" = 1 ] && echo " (srcversion $(loaded_456_sv))")" ;;
	esac
}

unload_456() {
	mod_loaded raid456 || return 0
	rmmod dm_raid 2>/dev/null
	rmmod raid456 || die "cannot unload raid456 (a raid4/5/6 array or dm-raid LV is using it)"
	TRACKED_456=
}

# use_456 default|intree : make the requested raid456 the loaded one
use_456() {
	local want=$1 m
	[ "$SAME_456" = 1 ] && want=default
	if [ "$(current_456)" = "$want" ]; then
		return 0
	fi
	unload_456
	if [ "$want" = intree ]; then
		for m in md_mod libcrc32c xor raid6_pq async_tx async_memcpy async_xor \
			 async_pq async_raid6_recov; do
			modprobe "$m" 2>/dev/null
		done
		insmod "$INTREE_456" || die "insmod $INTREE_456 failed"
	else
		modprobe raid456 || die "modprobe raid456 failed"
	fi
	TRACKED_456=$want
	[ "$SV_OK" = 0 ] || [ "$(current_456)" = "$want" ] ||
		die "loaded raid456 srcversion $(loaded_456_sv) is not the requested $want"
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
	if [ "$(current_456)" != "$ORIG_456" ]; then
		case "$ORIG_456" in
		none)   unload_456 ;;
		intree) use_456 intree ;;
		*)      use_456 default ;;
		esac
	fi
	[ "$ORIG_DM_RAID" = 1 ] && modprobe dm_raid 2>/dev/null
	return 0
}
md_attr() { cat "/sys/block/$(basename "$(readlink -f "$MD")")/md/$1" 2>/dev/null; }

# arm_create_cmd <arm> : set CREATE_CMD to the arm's mdadm --create (empty for raw)
arm_create_cmd() {
	local arm="$1" t lvl
	t=$(arm_type "$arm")
	arm_select "$arm"
	CREATE_CMD=()
	case "$t" in
	raw) ;;
	raidkm*)
		CREATE_CMD=("$MDADM" --create "$MD" --level=raidkm --parity-count="${t#raidkm}"
			--layout=rotating --raid-devices="$AN" --chunk="$CHUNK"
			--bitmap="$BITMAP" --assume-clean --run --force "${AM[@]}") ;;
	dcl*)
		CREATE_CMD=("$MDADM" --create "$MD" --level=raidkm --parity-count="${t#dcl}"
			--layout=declustered --group-width="$DCL_G" --spare-columns="$DCL_S"
			--raid-devices="$AN" --chunk="$CHUNK"
			--bitmap="$BITMAP" --assume-clean --run --force "${AM[@]}") ;;
	*)
		lvl="${t#raid}"; lvl="${lvl%-intree}"
		CREATE_CMD=("$MDADM" --create "$MD" --level="$lvl"
			--raid-devices="$AN" --chunk="$CHUNK"
			--bitmap="$BITMAP" --assume-clean --run --force "${AM[@]}") ;;
	esac
}

# arm_bench_args <arm> <dir> <target> : set BENCH_ARGS for raidkm-standard-benchmark.sh
arm_bench_args() {
	BENCH_ARGS=(--target="$3" --runs=1 --runtime="$RUNTIME" --output="$2" --no-check)
	[ -n "$WORKLOADS" ] && BENCH_ARGS+=(--workloads="$WORKLOADS")
	[ "$(arm_type "$1")" = raw ] && return 0
	arm_select "$1"	# the last member OF THIS ARM, not of --devs
	if [ "$DEGRADED" = 1 ]; then
		BENCH_ARGS+=(--degraded-victim="$ALAST" --mdadm="$MDADM")
		[ -n "$DEG_WORKLOADS" ] && BENCH_ARGS+=(--degraded-workloads="$DEG_WORKLOADS")
	fi
	if [ "$REBUILD" = 1 ]; then
		BENCH_ARGS+=(--rebuild-victim="$ALAST")
		[ "$DEGRADED" = 1 ] || BENCH_ARGS+=(--mdadm="$MDADM")
		[ -n "$REBUILD_LOAD" ] && BENCH_ARGS+=(--rebuild-load="$REBUILD_LOAD")
		[ -n "$REBUILD_FLOOR" ] && BENCH_ARGS+=(--rebuild-floor="$REBUILD_FLOOR")
	fi
	return 0
}

# profile_value <arm> <attr> <value>: resolve "auto" for the arm's geometry.
# stripe_cache_size=auto follows raidkm's start: 1024 stripes, capped by a
# 128 MiB cache (about 4.2 KiB per member per stripe), never below 256.
profile_value() {
	if [ "$2" = stripe_cache_size ] && [ "$3" = auto ]; then
		arm_select "$1"
		local v=$(( 131072 * 10 / (AN * 42 + 10) ))
		[ "$v" -gt 1024 ] && v=1024
		[ "$v" -lt 256 ] && v=256
		echo "$v"
	else
		echo "$3"
	fi
}

# apply_profile <arm> <md sysfs dir>: the arm's +<profile> settings, in order
PROFILE_SET=
apply_profile() {
	local prof a name val pa
	PROFILE_SET=
	prof=$(arm_profile "$1")
	[ -n "$prof" ] || return 0
	IFS=, read -r -a pa <<< "${PROFILES[$prof]}"
	for a in "${pa[@]}"; do
		name="${a%%=*}"; val=$(profile_value "$1" "$name" "${a#*=}")
		echo "$val" > "$2/$name" 2>/dev/null ||
			die "$1: profile $prof cannot set $name=$val"
		PROFILE_SET+="${PROFILE_SET:+ }$name=$(cat "$2/$name" 2>/dev/null)"
	done
}

# create_arm <arm> : build the arm; sets TARGET
create_arm() {
	local arm="$1"
	MD_ATTRS_SET=()			# per arm; the raw arm returns before the knobs
	case "$(arm_type "$arm")" in
	raw)
		wipe_members
		TARGET="${MEMBERS[0]}"
		return 0 ;;
	raid5|raid6)               use_456 default ;;
	raid5-intree|raid6-intree) use_456 intree ;;
	raidkm*|dcl*)              rk_load_modules || die "raidkm module not loadable" ;;
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
	# Best-effort extra knobs.  An arm that has no such attribute (rk_* on a
	# stock raid6 arm) keeps its default rather than failing the run — that
	# asymmetry IS the comparison.  What actually took is recorded per arm.
	local a name val mdd="/sys/block/$(basename "$(readlink -f "$MD")")/md"
	for a in ${MD_ATTRS[@]+"${MD_ATTRS[@]}"}; do
		name="${a%%=*}"; val="${a#*=}"
		if [ -w "$mdd/$name" ] && echo "$val" > "$mdd/$name" 2>/dev/null; then
			MD_ATTRS_SET+=("$name=$(cat "$mdd/$name" 2>/dev/null)")
		else
			MD_ATTRS_SET+=("$name=n/a")
		fi
	done
	apply_profile "$arm" "$mdd"
	TARGET="$MD"
}

# rk_module_id : path + srcversion of the raidkm module actually loaded
rk_module_id() {
	local ko sv
	ko=$([ -f "$RAIDKM_KO" ] && echo "$RAIDKM_KO" || modinfo -n raidkm 2>/dev/null)
	sv=$(cat /sys/module/raidkm/srcversion 2>/dev/null)
	echo "$ko${sv:+ (srcversion $sv)}"
}

# record_arm <arm> <dir> : geometry, tuning and module identity actually in force
record_arm() {
	local arm="$1" out="$2/arm.env"
	{
		echo "arm=$arm"
		echo "date=$(date -Iseconds)"
		echo "host=$(hostname)"
		echo "kernel=$KVER"
		arm_select "$arm"
		echo "members=${AM[*]}"
		echo "target=$TARGET"
		if [ "$(arm_type "$arm")" != raw ]; then
			echo "level=$(md_attr level)"
			echo "raid_disks=$(md_attr raid_disks)"
			echo "chunk_size=$(md_attr chunk_size)"
			echo "layout=$(md_attr layout)"
			echo "bitmap=$BITMAP"
			echo "group_thread_cnt=$(md_attr group_thread_cnt)"
			echo "stripe_cache_size=$(md_attr stripe_cache_size)"
			echo "skip_copy=$(md_attr skip_copy)"
			[ ${#MD_ATTRS_SET[@]} -gt 0 ] &&
				echo "md_attrs=${MD_ATTRS_SET[*]}"
			[ -n "$(arm_profile "$arm")" ] &&
				echo "profile=$(arm_profile "$arm") ($PROFILE_SET)"
			echo "preread_bypass_threshold=$(md_attr preread_bypass_threshold)"
			echo "mdadm=$MDADM ($("$MDADM" --version 2>&1 | head -1))"
		fi
		case "$(arm_type "$arm")" in
		raid*-*|raid5|raid6) echo "module=$(describe_456)" ;;
		dcl*) echo "group_width=$DCL_G spare_columns=$DCL_S"
		      echo "module=raidkm $(rk_module_id)" ;;
		raidkm*) echo "module=raidkm $(rk_module_id)" ;;
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
case "$PRECOND" in
0) PRECOND_DESC=none ;;
1) PRECOND_DESC="sequential fill" ;;
*) PRECOND_DESC="sequential fill + ${PRECOND_TIME}s random 4K writes" ;;
esac
echo "  prepare:   precondition=$PRECOND_DESC  warm-up=${WARMUP:-none}${WARMUP:+ (one pass, discarded)}"
echo "  chunk:     ${CHUNK}K  bitmap=$BITMAP  gtc=${GTC:-default}  stripe_cache=${SCS:-default}"
[ ${#MD_ATTRS[@]} -gt 0 ] && echo "  md-attr:   ${MD_ATTRS[*]}  (best-effort per arm)"
for arm in "${ARM_LIST[@]}"; do
	p=$(arm_profile "$arm")
	[ -n "$p" ] && echo "  profile:   $arm -> ${PROFILES[$p]}"
done
[ "$DEGRADED" = 1 ] && echo "  degraded:  last member of each md arm failed, workloads ${DEG_WORKLOADS:-9,10}"
[ "$REBUILD" = 1 ] && echo "  rebuild:   last member, floor ${REBUILD_FLOOR:-500000} KB/s${REBUILD_LOAD:+, then under $REBUILD_LOAD}"
[[ ",$ARMS," == *",dcl"* ]] && echo "  dcl:       group-width=$DCL_G spare-columns=$DCL_S"
NWL=$(echo "${WORKLOADS:-1,2,3,4,5,8,9,10}" | tr ',' ' ' | wc -w)
echo "  runtime:   ${RUNTIME}s x $NWL workloads per arm run  (~$(( ${#ORDER[@]} * NWL * (RUNTIME + 3) / 60 )) min of fio)"
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
	if [ "$PRECOND" != 0 ]; then
		echo "== preconditioning (once) =="
		printf '  '; q fio --direct=1 --ioengine=libaio --rw=write --bs=1M --iodepth=8 \
			$(for i in "${!MEMBERS[@]}"; do echo "--name=precond$i --filename=${MEMBERS[$i]}"; done)
		[ "$PRECOND" = 2 ] && { printf '  '; q fio --direct=1 --ioengine=libaio --rw=randwrite --bs=4k \
			--iodepth=32 --norandommap --randrepeat=0 --time_based --runtime="$PRECOND_TIME" \
			$(for i in "${!MEMBERS[@]}"; do echo "--name=steady$i --filename=${MEMBERS[$i]}"; done); }
		echo
	fi
	if [ -n "$WARMUP" ]; then
		echo "== warm-up (once, discarded): arm $WARMUP, every workload, output $OUTPUT/warmup/$WARMUP =="
		echo
	fi
	for arm in "${ARM_LIST[@]}"; do
		echo "== arm $arm =="
		case "$(arm_type "$arm")" in
		raid5|raid6|raid5-intree|raid6-intree)
			if [ "$SAME_456" = 1 ]; then
				echo "  modprobe raid456             # -> ${DEFAULT_456:-?} (the kernel's only raid456; no swap)"
			elif [[ "$(arm_type "$arm")" == *-intree ]]; then
				echo "  rmmod dm_raid raid456"
				echo "  insmod ${INTREE_456:-<no in-tree raid456.ko>}   # distro raid456; the original is restored at exit"
			else
				[ "$SV_OK" = 1 ] && [ "$(current_456)" = intree ] &&
					echo "  rmmod dm_raid raid456        # the in-tree raid456 is loaded; swap to the modprobe default"
				echo "  modprobe raid456             # -> ${DEFAULT_456:-?}"
			fi ;;
		raidkm*|dcl*)
			if [ -f "$ISAL_KO" ]; then echo "  insmod $ISAL_KO"; else echo "  modprobe isal_lib"; fi
			if [ -f "$RAIDKM_KO" ]; then
				echo "  insmod $RAIDKM_KO"
			else
				echo "  modprobe raidkm              # -> $(modinfo -n raidkm 2>/dev/null || echo '? (not installed)')"
			fi ;;
		esac
		for d in "${MEMBERS[@]}"; do
			[ "$(arm_type "$arm")" = raw ] || { printf '  '; q "$MDADM" --zero-superblock "$d"; }
			printf '  '; q wipefs -a "$d"
		done
		arm_create_cmd "$arm"
		if [ "${#CREATE_CMD[@]}" -gt 0 ]; then
			printf '  '; q "${CREATE_CMD[@]}"
			[ -n "$GTC" ] && echo "  echo $GTC > $mdsys/group_thread_cnt"
			[ -n "$SCS" ] && echo "  echo $SCS > $mdsys/stripe_cache_size"
			for a in ${MD_ATTRS[@]+"${MD_ATTRS[@]}"}; do
				echo "  echo ${a#*=} > $mdsys/${a%%=*}   # skipped, recorded n/a, if this arm has no such attribute"
			done
			if [ -n "$(arm_profile "$arm")" ]; then
				IFS=, read -r -a pa <<< "${PROFILES[$(arm_profile "$arm")]}"
				for a in "${pa[@]}"; do
					echo "  echo $(profile_value "$arm" "${a%%=*}" "${a#*=}") > $mdsys/${a%%=*}   # profile $(arm_profile "$arm")"
				done
			fi
			arm_bench_args "$arm" "$OUTPUT/$arm/round<R>" "$MD"
		else
			arm_bench_args "$arm" "$OUTPUT/$arm/round<R>" "${MEMBERS[0]}"
		fi
		printf '  '; q bash "$BENCH" "${BENCH_ARGS[@]}"
		if [ "$(arm_type "$arm")" != raw ]; then
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

if [ "$PRECOND" != 0 ]; then
	echo "=== preconditioning: sequential fill of every member ==="
	wipe_members
	args=(--direct=1 --ioengine=libaio --rw=write --bs=1M --iodepth=8)
	for i in "${!MEMBERS[@]}"; do args+=(--name="precond$i" --filename="${MEMBERS[$i]}"); done
	fio "${args[@]}" >"$OUTPUT/precondition.log" 2>&1 || die "preconditioning failed (see $OUTPUT/precondition.log)"
	if [ "$PRECOND" = 2 ]; then
		echo "=== preconditioning: ${PRECOND_TIME}s of 4 KiB random writes over every member ==="
		args=(--direct=1 --ioengine=libaio --rw=randwrite --bs=4k --iodepth=32 --norandommap
		      --randrepeat=0 --time_based --runtime="$PRECOND_TIME")
		for i in "${!MEMBERS[@]}"; do args+=(--name="steady$i" --filename="${MEMBERS[$i]}"); done
		fio "${args[@]}" >"$OUTPUT/precondition-steady.log" 2>&1 ||
			die "steady-state preconditioning failed (see $OUTPUT/precondition-steady.log)"
	fi
	echo
fi

# The warm-up pass takes the first-run-on-the-drives slot so no measured arm
# does.  Same workloads and runtime; no degraded phase or rebuild (they would
# only cost time).
if [ -n "$WARMUP" ]; then
	dir="$OUTPUT/warmup/$WARMUP"
	mkdir -p "$dir"
	echo "=== warm-up (discarded): $WARMUP ==="
	create_arm "$WARMUP"
	record_arm "$WARMUP" "$dir"
	saved_rebuild=$REBUILD saved_degraded=$DEGRADED; REBUILD=0 DEGRADED=0
	arm_bench_args "$WARMUP" "$dir" "$TARGET"
	REBUILD=$saved_rebuild DEGRADED=$saved_degraded
	bash "$BENCH" "${BENCH_ARGS[@]}" > "$dir/bench.log" 2>&1 ||
		echo "  NOTE: the warm-up run reported a failure (see $dir/bench.log); measured runs continue" >&2
	teardown_arm
	echo
fi

FAILED=0
: > "$OUTPUT/order.txt"
for entry in "${ORDER[@]}"; do
	r="${entry%%:*}"
	arm="${entry#*:}"
	dir="$OUTPUT/$arm/round$r"
	mkdir -p "$dir"
	echo "$r:$arm" >> "$OUTPUT/order.txt"
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
    "test8_seqwrite1m": "sequential 1 MiB write",
    "test9_seqread1m": "sequential 1 MiB read",
    "test10_randread4k": "random 4K read",
}
for t in list(DESC):     # the degraded phase runs the same workloads as deg_<test>
    DESC["deg_" + t] = "degraded: " + DESC[t]
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
perrun = {}     # (arm, "round<R>", test) -> IOPS of that one run
rebuild = {}    # arm -> [secs]
rebuild_x = {}  # arm -> [test7_rebuild.json]
loaded = {}     # (arm, load) -> [test7L_<load>_rebuild.json]
env = {}
for arm in arms:
    for rdir in sorted(glob.glob(os.path.join(out, arm, "round*"))):
        for t in tests:
            f = os.path.join(rdir, f"{t}_run1.json")
            if not os.path.exists(f):
                continue
            iops, bw, p99 = load(f)
            d = data.setdefault((arm, t), {"iops": [], "bw": [], "p99": [], "cpu": [],
                                           "mw": [], "mwp": [], "mr": [], "mrp": []})
            d["iops"].append(iops); d["bw"].append(bw); d["p99"].append(p99)
            perrun[(arm, os.path.basename(rdir), t)] = iops
            cf = os.path.join(rdir, f"{t}_run1.cpu.json")
            if os.path.exists(cf):
                d["cpu"].append(json.load(open(cf))["busy_cores"])
            mf = os.path.join(rdir, f"{t}_run1.members.json")
            if os.path.exists(mf):
                mj = json.load(open(mf))
                for side, k in (("write", "mw"), ("read", "mr")):
                    if mj[side]["requests"]:
                        d[k].append(mj[side]["avg_kib"])
                        d[k + "p"].append(mj[side]["merged_pct"])
        rj = os.path.join(rdir, "test7_rebuild.json")
        log = os.path.join(rdir, "bench.log")
        if os.path.exists(rj):
            j = json.load(open(rj))
            rebuild.setdefault(arm, []).append(j["secs"])
            rebuild_x.setdefault(arm, []).append(j)
        elif os.path.exists(log):     # results from before test7_rebuild.json
            m = re.search(r"^\s+7: ([0-9.]+)s", open(log).read(), re.M)
            if m:
                rebuild.setdefault(arm, []).append(float(m.group(1)))
        for lj in sorted(glob.glob(os.path.join(rdir, "test7L_*_rebuild.json"))):
            j = json.load(open(lj))
            loaded.setdefault((arm, j["load"]), []).append(j)
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
emit("| arm | level | disks | chunk | group_thread_cnt | stripe_cache_size | skip_copy | profile | module |")
emit("|---|---|---|---|---|---|---|---|---|")
for arm in arms:
    e = env.get(arm, {})
    emit(f"| {arm} | {e.get('level','-')} | {e.get('raid_disks','-')} | {e.get('chunk_size','-')} "
         f"| {e.get('group_thread_cnt','-')} | {e.get('stripe_cache_size','-')} | {e.get('skip_copy','-')} "
         f"| {e.get('profile','-')} | {e.get('module','-')} |")

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
        if not any((a, t) in data for a in arms):
            continue
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

# Degraded throughput as a share of the same arm's healthy run of that workload.
deg = [t for t in tests if t.startswith("deg_") and any((a, t) in data for a in arms)]
if deg:
    emit()
    emit("## Degraded (one member failed): throughput and % of the same arm healthy")
    emit()
    emit("MiB/s for sequential workloads, IOPS otherwise.")
    emit()
    emit("| workload | " + " | ".join(arms) + " | " +
         " | ".join(f"{a}/{baseline}" for a in arms if a != baseline) + " |")
    emit("|" + "---|" * (1 + len(arms) + len(arms) - 1))
    for t in deg:
        metric = "bw" if "seq" in t else "iops"
        base = mean_cv(data.get((baseline, t), {}).get(metric, []))[0]
        cells, ratios = [], []
        for arm in arms:
            m = mean_cv(data.get((arm, t), {}).get(metric, []))[0]
            h = mean_cv(data.get((arm, t[4:]), {}).get(metric, []))[0]
            if m is None:
                cells.append("-")
            else:
                cells.append(f"{m:.0f}" + (f" ({100 * m / h:.0f}%)" if h else ""))
                rows.append({"arm": arm, "workload": t, "metric": "pct_of_healthy",
                             "mean": round(100 * m / h, 2) if h else "", "cv_pct": "",
                             "ratio_vs_baseline": ""})
            if arm != baseline:
                ratios.append(f"{m / base:.2f}x" if m is not None and base else "-")
        emit(f"| {t} ({DESC[t]}) | " + " | ".join(cells) + " | " + " | ".join(ratios) + " |")

# CPU: busy cores over each workload's window, and per GiB/s moved.
if any(data[k]["cpu"] for k in data):
    emit()
    emit("## Host busy cores during each workload (cores per GiB/s in brackets)")
    emit()
    emit("Busy = user + nice + system + irq + softirq + steal over the whole host, "
         "load generator included.")
    emit()
    emit("| workload | " + " | ".join(arms) + " |")
    emit("|" + "---|" * (1 + len(arms)))
    for t in tests:
        if not any(data.get((a, t), {}).get("cpu") for a in arms):
            continue
        cells = []
        for arm in arms:
            d = data.get((arm, t), {})
            if not d.get("cpu"):
                cells.append("-")
                continue
            c = statistics.mean(d["cpu"])
            bw = statistics.mean(d["bw"]) if d["bw"] else 0
            cells.append(f"{c:.1f}" + (f" ({c / (bw / 1024):.2f})" if bw >= 64 else ""))
            rows.append({"arm": arm, "workload": t, "metric": "busy_cores",
                         "mean": round(c, 3), "cv_pct": "", "ratio_vs_baseline": ""})
        emit(f"| {t} ({DESC[t]}) | " + " | ".join(cells) + " |")

# Request size at the members: what the devices under each arm received.
if any(data[k]["mw"] or data[k]["mr"] for k in data):
    emit()
    emit("## Request size at the members, KiB (merged share)")
    emit()
    emit("| workload | " + " | ".join(arms) + " |")
    emit("|" + "---|" * (1 + len(arms)))
    for t in tests:
        if not any((a, t) in data for a in arms):
            continue
        cells = []
        for arm in arms:
            d = data.get((arm, t), {})
            parts = []
            for k, tag in (("mw", "w"), ("mr", "r")):
                if d.get(k):
                    parts.append(f"{tag} {statistics.mean(d[k]):.1f} ({statistics.mean(d[k + 'p']):.0f}%)")
                    rows.append({"arm": arm, "workload": t,
                                 "metric": "member_write_kib" if k == "mw" else "member_read_kib",
                                 "mean": round(statistics.mean(d[k]), 3), "cv_pct": "",
                                 "ratio_vs_baseline": ""})
            cells.append(" · ".join(parts) or "-")
        emit(f"| {t} ({DESC[t]}) | " + " | ".join(cells) + " |")

if rebuild:
    emit()
    emit("## Rebuild wall-clock, seconds (lower is better)")
    emit()
    if rebuild_x:
        emit("| arm | kind | seconds | MiB/s | busy cores | cores per GiB/s |")
        emit("|---|---|---|---|---|---|")
        for arm in arms:
            js = rebuild_x.get(arm)
            if not js:
                continue
            mb = [j["mibps"] for j in js if j["mibps"] is not None]
            cores = statistics.mean(j["busy_cores"] for j in js)
            mbm = statistics.mean(mb) if mb else None
            emit(f"| {arm} | {js[0]['kind']} | {statistics.mean(j['secs'] for j in js):.1f} "
                 f"| {mbm:.0f} | {cores:.1f} | " + (f"{cores / (mbm / 1024):.2f}" if mbm else "-") + " |"
                 if mbm is not None else
                 f"| {arm} | {js[0]['kind']} | {statistics.mean(j['secs'] for j in js):.1f} | - | {cores:.1f} | - |")
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

if loaded:
    emit()
    emit("## Rebuild under a foreground load (classic layouts)")
    emit()
    emit("| arm | load | rebuild MiB/s | rebuild seconds | foreground MiB/s | foreground IOPS | busy cores |")
    emit("|---|---|---|---|---|---|---|")
    for arm in arms:
        for (a, load), js in sorted(loaded.items()):
            if a != arm:
                continue
            def avg(k):
                v = [j[k] for j in js if j.get(k) is not None]
                return statistics.mean(v) if v else None
            f = lambda v, fmt: fmt.format(v) if v is not None else "-"
            emit(f"| {arm} | {load} | {f(avg('mibps'), '{:.0f}')} | {f(avg('secs'), '{:.1f}')} "
                 f"| {f(avg('load_mibps'), '{:.0f}')} | {f(avg('load_iops'), '{:.0f}')} "
                 f"| {f(avg('busy_cores'), '{:.1f}')} |")
            for k in ("mibps", "load_mibps", "busy_cores"):
                if avg(k) is not None:
                    rows.append({"arm": arm, "workload": f"rebuild_under_{load}", "metric": k,
                                 "mean": round(avg(k), 3), "cv_pct": "", "ratio_vs_baseline": ""})

# Every run in the order it ran.  A mean hides a position effect (the first run
# on fresh flash, a GC stall); this table shows it.
order_file = os.path.join(out, "order.txt")
order = []
if os.path.exists(order_file):
    order = [l.strip().split(":", 1) for l in open(order_file) if ":" in l]
else:   # results from before order.txt existed: reconstruct ABBA
    rounds = sorted({int(k[1][5:]) for k in perrun if k[1][5:].isdigit()})
    for r in rounds:
        seq = arms if r % 2 else list(reversed(arms))
        order += [[str(r), a] for a in seq]
outliers = []
if len(order) > 2:
    emit()
    emit("## IOPS per run, in execution order")
    emit()
    emit("`*` = more than 10% away from the median of the other runs of that workload "
         "(all arms). A flag on the first column is the classic sign of fresh-drive bias; "
         "use --warmup / --precondition=steady.")
    emit()
    emit("| workload | " + " | ".join(f"{i + 1}. {a} r{r}" for i, (r, a) in enumerate(order)) + " |")
    emit("|" + "---|" * (1 + len(order)))
    for t in tests:
        vals = [perrun.get((a, f"round{r}", t)) for r, a in order]
        if not any(v is not None for v in vals):
            continue
        cells = []
        for i, v in enumerate(vals):
            if v is None:
                cells.append("-")
                continue
            others = [x for j, x in enumerate(vals) if j != i and x is not None]
            flag = ""
            if others and statistics.median(others) and \
               abs(v / statistics.median(others) - 1) > 0.10:
                flag = "*"
                outliers.append(f"{t} run {i + 1} ({order[i][1]} r{order[i][0]})")
            cells.append(f"{v:.0f}{flag}")
        emit(f"| {t} ({DESC[t]}) | " + " | ".join(cells) + " |")

if outliers:
    emit()
    emit(f"**{len(outliers)} run(s) sit more than 10% from the other runs of the same workload — "
         "check the per-run table before trusting a ratio:** " + ", ".join(outliers))

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
