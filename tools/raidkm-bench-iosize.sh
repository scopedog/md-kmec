#!/bin/bash
#
# raidkm-bench-iosize.sh — request size and merge share reaching the member devices
#
# For each arm (a geometry on a given md personality) and each I/O state, snapshot
# the members' request counters around a workload and report the average request
# size and the share of submitted bios the block layer merged.  On flash with a
# coarse indirection unit (IU: 16 KiB today, growing to 32 and 64 KiB), a write
# below the unit makes the drive rewrite the whole unit, so this is the number to
# watch for endurance — throughput alone hides it.
#
# By default the members are memory-backed null_blk devices created by the tool,
# capped at --max-kb per request to model a fabric/driver limit.  That rig
# reproduces a real NVMe-oF array's request-size table closely (8+2 over QLC:
# writes ~127 KiB, degraded reads ~6 KiB, rebuild spare writes ~7 KiB), at a
# fraction of the cost.  --devs runs on real devices instead (destructive).
#
# Usage:
#   sudo bash tools/raidkm-bench-iosize.sh [options]
#
# Options:
#   --arms=LIST       space- or comma-separated arm specs (default "raid6:8+2,raidkm:8+2"):
#                       raid5:K+1  raid6:K+2   md raid456 as modprobe resolves it
#                       raidkm:K+M             raidkm, rotating layout
#                       dcl:K+M:N:S            raidkm declustered: groups of K+M
#                                              over an N-disk pool, S spare columns
#   --states=LIST     default "healthy_write,healthy_read,degraded_write,degraded_read,rebuild,copyback"
#                       rebuild   classic: recovery onto a spare device
#                                 declustered: population into the distributed spare
#                       copyback  declustered only: copy onto a replacement once populated
#   --runtime=SEC     seconds per state (default 20)
#   --bs=SIZE         fio block size for the sequential states (default 1M)
#   --jobs=N          fio jobs, each in its own row-aligned region (default 4)
#   --region=SIZE     target size of each job's region, rounded down to whole
#                     rows (default 4G)
#   --chunk=KB        md chunk size (default 128)
#   --gtc=N           group_thread_cnt for every arm (default: engine default)
#   --md-attr=NAME=V  write V to /sys/block/mdX/md/NAME on every arm after the
#                     create (repeatable), e.g. --md-attr=rk_row_dread=1
#   --stripe-cache=N  stripe_cache_size for every arm (default: engine default, 256).
#                     That is the cache's minimum: it grows by itself under
#                     pressure, so each state records the peak stripe_cache_active.
#   --devs="D1 ..."   real member devices instead of null_blk (needs --force;
#                     every device is overwritten)
#   --force           allow --devs
#   --nullb-gb=N      null_blk device size in GiB (default 48)
#   --max-kb=N        null_blk max request size in KiB (default 128)
#   --latency-us=N    null_blk completion latency in µs (default 0: softirq)
#   --output=DIR      results directory (default /var/tmp/raidkm-iosize-<timestamp>)
#   --mdadm=PATH      raidkm-aware mdadm (default: auto-resolved)
#   -h, --help        show this help
#
# raidkm itself loads through raidkm-test-lib.sh: RAIDKM_KO / ISAL_KO select a
# build-tree module, otherwise modprobe.  To compare two raidkm builds, run the
# tool once per build with RAIDKM_KO pointing at each.
#
# Output: DIR/results.csv (one row per arm, state, device set and direction),
# DIR/summary.md, DIR/fio-<arm>-<state>.json.  Rebuild and copyback windows end
# after --runtime seconds or when the operation completes, whichever is first.
#

# No pipefail: raidkm-test-lib.sh tests `lsmod | grep -q`.
set -u
# blkid, wipefs, modinfo and friends live in sbin, which a non-root PATH may lack
PATH="$PATH:/usr/sbin:/sbin"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

ARMS="raid6:8+2,raidkm:8+2"
STATES="healthy_write,healthy_read,degraded_write,degraded_read,rebuild,copyback"
RUNTIME=20
BS=1M
JOBS=4
REGION=4G
CHUNK=128
GTC=
SCS=
MD_ATTRS=()
DEVS=
FORCE=0
NULLB_GB=48
MAX_KB=128
LATENCY_US=0
OUTPUT=
MDADM_ARG=

usage() {
	sed -n '3,/^$/p' "$0" | sed 's/^# \?//'
	exit 0
}
die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date +%T)] $*"; }

for arg in "$@"; do
	case "$arg" in
	--arms=*)       ARMS="${arg#*=}" ;;
	--states=*)     STATES="${arg#*=}" ;;
	--runtime=*)    RUNTIME="${arg#*=}" ;;
	--bs=*)         BS="${arg#*=}" ;;
	--jobs=*)       JOBS="${arg#*=}" ;;
	--region=*)     REGION="${arg#*=}" ;;
	--chunk=*)      CHUNK="${arg#*=}" ;;
	--gtc=*)        GTC="${arg#*=}" ;;
	--stripe-cache=*) SCS="${arg#*=}" ;;
	--md-attr=*)    MD_ATTRS+=("${arg#*=}") ;;
	--devs=*)       DEVS="${arg#*=}" ;;
	--force)        FORCE=1 ;;
	--nullb-gb=*)   NULLB_GB="${arg#*=}" ;;
	--max-kb=*)     MAX_KB="${arg#*=}" ;;
	--latency-us=*) LATENCY_US="${arg#*=}" ;;
	--output=*)     OUTPUT="${arg#*=}" ;;
	--mdadm=*)      MDADM_ARG="${arg#*=}" ;;
	-h|--help)      usage ;;
	*)              die "unknown option: $arg (see --help)" ;;
	esac
done

[ "$(id -u)" = 0 ] || die "run as root (sudo)"
for t in fio python3 udevadm numfmt; do command -v "$t" >/dev/null || die "$t not found"; done
[ -z "$DEVS" ] || [ "$FORCE" = 1 ] || die "--devs overwrites every device; add --force"

MD=/dev/md70
MDADM="$MDADM_ARG"
# shellcheck source=raidkm-test-lib.sh
. "$DIR/raidkm-test-lib.sh"
# shellcheck source=raidkm-member-stats.sh
. "$DIR/raidkm-member-stats.sh"
rk_resolve_mdadm || exit 1

ARMS=$(echo "$ARMS" | tr ',' ' ')
STATES=$(echo "$STATES" | tr ',' ' ')
REGION_BYTES=$(numfmt --from=iec "$REGION") || die "bad --region"
BS_BYTES=$(numfmt --from=iec "$BS") || die "bad --bs"
OUTPUT="${OUTPUT:-/var/tmp/raidkm-iosize-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTPUT" || die "cannot create $OUTPUT"
CSV="$OUTPUT/results.csv"
echo "arm,state,devset,dir,devices,requests,merges,sectors,avg_kib,merged_pct,fio_mibps,set_mibps,window_s,busy_cores,scache_peak_active,scache_min" > "$CSV"

# ---- arm parsing --------------------------------------------------------------

# parse_arm SPEC -> ENG K M N S (N = pool width, S = spare columns; classic N = K+M)
parse_arm() {
	local eng geo pool sc k m
	IFS=: read -r eng geo pool sc <<< "$1"
	[[ "$geo" =~ ^([0-9]+)\+([0-9]+)$ ]] || die "bad arm '$1' (want e.g. raidkm:8+2)"
	k=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}
	case "$eng" in
	raid5)  [ "$m" = 1 ] || die "$1: raid5 has one parity" ;;
	raid6)  [ "$m" = 2 ] || die "$1: raid6 has two parities" ;;
	raidkm) [ "$m" -ge 2 ] || die "$1: raidkm needs m >= 2" ;;
	dcl)    [ "$m" -ge 2 ] || die "$1: raidkm needs m >= 2"
		[[ "$pool" =~ ^[0-9]+$ && "$sc" =~ ^[0-9]+$ ]] || die "bad arm '$1' (want dcl:K+M:N:S)"
		[ "$sc" -ge 1 ] && [ $(( (pool - sc) % (k + m) )) = 0 ] ||
			die "$1: need S >= 1 and (N - S) a multiple of K+M" ;;
	*)      die "unknown engine in '$1' (raid5, raid6, raidkm, dcl)" ;;
	esac
	[ "$k" -ge 2 ] || die "$1: need at least 2 data disks"
	[ "$eng" = dcl ] || { pool=$((k + m)); sc=0; }
	echo "$eng $k $m $pool $sc"
}

NEED=0
for spec in $ARMS; do
	parsed=$(parse_arm "$spec") || exit 1
	read -r _ _ _ pool _ <<< "$parsed"
	[ $((pool + 1)) -gt "$NEED" ] && NEED=$((pool + 1))	# +1: spare / replacement
done

# ---- devices ------------------------------------------------------------------

DEVLIST=()
setup_devices() {
	if [ -n "$DEVS" ]; then
		read -r -a DEVLIST <<< "$DEVS"
		[ "${#DEVLIST[@]}" -ge "$NEED" ] || die "--devs has ${#DEVLIST[@]} devices, the arms need $NEED"
		return
	fi
	[ -e /sys/module/null_blk ] && { rmmod null_blk || die "null_blk is busy"; }
	local extra=""
	[ "$LATENCY_US" -gt 0 ] && extra="irqmode=2 completion_nsec=$((LATENCY_US * 1000))"
	# shellcheck disable=SC2086
	modprobe null_blk nr_devices="$NEED" gb="$NULLB_GB" bs=4096 queue_mode=2 \
		memory_backed=1 submit_queues="$(nproc)" hw_queue_depth=128 \
		max_sectors=$((MAX_KB * 2)) $extra || die "modprobe null_blk failed"
	DEVLIST=()
	local i
	for i in $(seq 0 $((NEED - 1))); do
		DEVLIST+=("/dev/nullb$i")
		echo none > "/sys/block/nullb$i/queue/scheduler" 2>/dev/null
	done
}

wipe_devs() {
	local d
	for d in "$@"; do
		"$MDADM" --zero-superblock "$d" >/dev/null 2>&1
		wipefs -a -q "$d" >/dev/null 2>&1
	done
}

stop_md() {
	"$MDADM" --stop "$MD" >/dev/null 2>&1
	udevadm settle
}

# leaves DEV... -> request-counter device names under them
leaves() { local d; for d in "$@"; do rk_leaf_devs "$d"; done | sort -u | tr '\n' ' '; }

# ---- measurement --------------------------------------------------------------

# record ARM STATE FIO_MIBPS WINDOW_S "SET:DIR:DEVS"...
# Sums the BEFORE/AFTER snapshots over each device set.  set_mibps is that set's
# own throughput in the given direction over the window (for a rebuild: the
# spare-write rate), so it does not depend on md's sync_speed, which reads
# "none" as soon as a sync ends.
BEFORE=
AFTER=
WINDOW=0
record() {
	local arm=$1 state=$2 fio=$3 win=$4; shift 4
	local item set dir devs lv js pat
	for item in "$@"; do
		IFS=: read -r set dir devs <<< "$item"
		# shellcheck disable=SC2086
		lv=$(leaves $devs)
		# shellcheck disable=SC2086
		pat=$(echo $lv | tr ' ' '|')
		js=$(rk_stat_report "$(grep -wE "$pat" <<< "$BEFORE")" "$(grep -wE "$pat" <<< "$AFTER")")
		python3 -c '
import json, sys
j = json.loads(sys.argv[1]); s = j["read" if sys.argv[2] == "r" else "write"]
win = float(sys.argv[5])
rate = s["sectors"] * 512 / 1048576 / win if win > 0 else 0
print("%s,%d,%d,%d,%d,%.1f,%.1f,%s,%.0f,%.1f,%s" % (sys.argv[3], j["devices"], s["requests"],
      s["merges"], s["sectors"], s["avg_kib"], s["merged_pct"], sys.argv[4], rate, win, sys.argv[6]))
' "$js" "$dir" "$arm,$state,$set,$dir" "$fio" "$win" "$BUSY,$SCACHE_PEAK,$SCACHE_SIZE" >> "$CSV"
		tail -1 "$CSV" | awk -F, '{printf "    %-15s %-13s %s  requests=%-10s merged=%5s%%  avg=%7s KiB  %6s MiB/s\n", $2, $3, $4, $6, $10, $9, $12}'
	done
	[ "$fio" != 0 ] && echo "      fio ${fio} MiB/s"
	echo "      busy ${BUSY} cores; stripe cache peak active ${SCACHE_PEAK} (configured minimum ${SCACHE_SIZE})"
	return 0
}

snap_all() {
	# shellcheck disable=SC2046
	rk_stat_snap $(leaves "${DEVLIST[@]}")
}

run_fio() {	# rw -> MiB/s
	local j="$OUTPUT/fio-$ARMNAME-$STATE.json"
	fio --name=w --filename="$MD" --rw="$1" --bs="$BS" --iodepth=8 --numjobs="$JOBS" \
	    --size="$SPAN" --offset_increment="$SPAN" --direct=1 --ioengine=libaio \
	    --time_based --runtime="$RUNTIME" --group_reporting \
	    --output-format=json --output="$j" >/dev/null 2>&1
	python3 -c "import json,sys;j=json.load(open(sys.argv[1]))['jobs'][0];print(round((j['read']['bw']+j['write']['bw'])/1024))" "$j" 2>/dev/null || echo 0
}

# watch_window DONE-TEST: wait up to RUNTIME seconds, returning early once the
# test succeeds; sets WINDOW to the elapsed seconds and DONE to 1 if it did
watch_window() {
	local t0 t1 i
	DONE=0
	t0=$(date +%s.%N)
	for i in $(seq 1 $((RUNTIME * 5))); do
		if eval "$1"; then DONE=1; break; fi
		sleep 0.2
	done
	t1=$(date +%s.%N)
	WINDOW=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", b - a }')
}

md_attr() { cat "/sys/block/$MDNAME/md/$1" 2>/dev/null; }

# cpu_ticks -> "total idle" (idle includes iowait) from /proc/stat
cpu_ticks() { awk '/^cpu / { print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6 }' /proc/stat; }

# window_start / window_stop bracket a measurement window: busy cores over the
# window (BUSY) and the stripe cache's peak active count and final size
BUSY=0
SCACHE_PEAK=0
SCACHE_SIZE=0
window_start() {
	CPU_T0=$(cpu_ticks)
	SAMPLER_FILE="$OUTPUT/.scache-peak"
	echo 0 > "$SAMPLER_FILE"
	(
		peak=0
		while :; do
			a=$(md_attr stripe_cache_active)
			if [ -n "$a" ] && [ "$a" -gt "$peak" ]; then
				peak=$a
				echo "$peak" > "$SAMPLER_FILE"
			fi
			sleep 0.2
		done
	) &
	SAMPLER_PID=$!
}
window_stop() {
	kill "$SAMPLER_PID" 2>/dev/null
	wait "$SAMPLER_PID" 2>/dev/null
	SCACHE_PEAK=$(cat "$SAMPLER_FILE" 2>/dev/null || echo 0)
	rm -f "$SAMPLER_FILE"
	SCACHE_SIZE=$(md_attr stripe_cache_size)	# the configured minimum; the cache grows past it
	BUSY=$(awk -v a="$CPU_T0" -v b="$(cpu_ticks)" -v n="$(nproc)" 'BEGIN {
		split(a, x, " "); split(b, y, " "); dt = y[1] - x[1]; di = y[2] - x[2]
		printf "%.1f", (dt > 0 ? (dt - di) / dt * n : 0) }')
}
recover_done() { [ "$(md_attr degraded)" = 0 ] && [ "$(md_attr sync_action)" = idle ]; }
populate_done() { rk_pop_show | grep -q '^populated'; }
copyback_done() { rk_pop_show | grep -q '^none' && [ "$(md_attr sync_action)" = idle ]; }

fail_victim() {
	if [ "$(md_attr degraded)" = 0 ]; then
		"$MDADM" --fail "$MD" "$victim" >/dev/null 2>&1
		"$MDADM" --remove "$MD" "$victim" >/dev/null 2>&1
		sleep 1
	fi
}

echo 2000000 > /proc/sys/dev/raid/speed_limit_min
echo 4000000 > /proc/sys/dev/raid/speed_limit_max

log "raidkm-bench-iosize: arms=[$ARMS] states=[$STATES] bs=$BS jobs=$JOBS chunk=${CHUNK}K"
[ -n "$DEVS" ] && log "devices: ${DEVS} (destructive)" ||
	log "devices: $NEED null_blk, ${NULLB_GB} GiB, max ${MAX_KB} KiB/request, latency ${LATENCY_US} µs"

for spec in $ARMS; do
	parsed=$(parse_arm "$spec") || exit 1
	read -r eng k m pool sc <<< "$parsed"
	ARMNAME=$(echo "$spec" | tr ':+' '-p')
	stop_md
	setup_devices
	members=("${DEVLIST[@]:0:$pool}")
	extra_dev=${DEVLIST[$pool]}
	victim_slot=$((pool - 1))
	victim=${members[$victim_slot]}
	survivors=("${members[@]:0:$victim_slot}")
	wipe_devs "${DEVLIST[@]:0:$((pool + 1))}"

	ROW=$((k * CHUNK * 1024))
	SPAN=$(( REGION_BYTES / ROW * ROW ))
	[ "$SPAN" -gt 0 ] || die "$spec: --region smaller than one row ($ROW bytes)"
	align="aligned"
	[ $(( BS_BYTES % ROW )) = 0 ] || [ $(( ROW % BS_BYTES )) = 0 ] ||
		align="NOT aligned: bs $BS vs row $((ROW / 1024)) KiB"

	case "$eng" in
	raid5|raid6)
		modprobe raid456 || die "modprobe raid456 failed"
		printf 'y\n' | "$MDADM" --create "$MD" --level="${eng#raid}" --raid-devices="$pool" \
			--chunk="$CHUNK" --bitmap=none --assume-clean --run --force "${members[@]}" \
			> "$OUTPUT/create-$ARMNAME.log" 2>&1 ;;
	raidkm)
		rk_load_modules || die "raidkm not loadable"
		printf 'y\n' | "$MDADM" --create "$MD" --level=raidkm --parity-count="$m" \
			--layout=rotating --raid-devices="$pool" --chunk="$CHUNK" --bitmap=none \
			--assume-clean --run --force "${members[@]}" > "$OUTPUT/create-$ARMNAME.log" 2>&1 ;;
	dcl)
		rk_load_modules || die "raidkm not loadable"
		printf 'y\n' | "$MDADM" --create "$MD" --level=raidkm --parity-count="$m" \
			--layout=declustered --group-width=$((k + m)) --spare-columns="$sc" \
			--raid-devices="$pool" --chunk="$CHUNK" --bitmap=none --assume-clean --run --force \
			"${members[@]}" > "$OUTPUT/create-$ARMNAME.log" 2>&1 ;;
	esac || { log "create $ARMNAME failed: $(tail -2 "$OUTPUT/create-$ARMNAME.log" | tr '\n' ' ')"; continue; }
	udevadm settle
	MDNAME=$(basename "$(readlink -f "$MD")")
	[ -n "$GTC" ] && echo "$GTC" > "/sys/block/$MDNAME/md/group_thread_cnt"
	[ -n "$SCS" ] && { echo "$SCS" > "/sys/block/$MDNAME/md/stripe_cache_size" ||
		log "$spec: could not set stripe_cache_size=$SCS"; }
	# guarded: under set -u an empty array expansion aborts on bash < 4.4
	for attr in ${MD_ATTRS[@]+"${MD_ATTRS[@]}"}; do
		echo "${attr#*=}" > "/sys/block/$MDNAME/md/${attr%%=*}" ||
			die "$spec: could not set ${attr%%=*}=${attr#*=}"
	done
	module=$( [ "$eng" = raid5 ] || [ "$eng" = raid6 ] && modinfo -n raid456 ||
		  { [ -f "$RAIDKM_KO" ] && echo "$RAIDKM_KO" || modinfo -n raidkm; } )
	log "arm $spec: level=$(cat /sys/block/$MDNAME/md/level) disks=$pool row=$((ROW / 1024)) KiB ($align)" \
	    "gtc=$(cat /sys/block/$MDNAME/md/group_thread_cnt) skip_copy=$(cat /sys/block/$MDNAME/md/skip_copy 2>/dev/null) module=$module"

	for STATE in $STATES; do
		fio=0
		case "$STATE" in
		healthy_write|healthy_read)
			BEFORE=$(snap_all)
			window_start
			fio=$(run_fio "${STATE#healthy_}")
			window_stop
			AFTER=$(snap_all)
			d=w; [ "$STATE" = healthy_read ] && d=r
			record "$spec" "$STATE" "$fio" "$RUNTIME" "members:$d:${members[*]}" ;;
		degraded_write|degraded_read)
			fail_victim
			BEFORE=$(snap_all)
			window_start
			fio=$(run_fio "${STATE#degraded_}")
			window_stop
			AFTER=$(snap_all)
			d=w; [ "$STATE" = degraded_read ] && d=r
			record "$spec" "$STATE" "$fio" "$RUNTIME" "survivors:$d:${survivors[*]}" ;;
		rebuild)
			fail_victim
			BEFORE=$(snap_all)
			window_start
			if [ "$eng" = dcl ]; then
				echo "$victim_slot" > "/sys/block/$MDNAME/md/rk_dcl_populate" ||
					{ window_stop; log "$spec: arming population failed"; continue; }
				watch_window populate_done
			else
				wipe_devs "$extra_dev"
				"$MDADM" --add "$MD" "$extra_dev" >/dev/null 2>&1
				watch_window recover_done
			fi
			window_stop
			AFTER=$(snap_all)
			[ "$DONE" = 1 ] && echo "      (completed in ${WINDOW}s)"
			if [ "$eng" = dcl ]; then
				# the distributed spare lives on the survivors: with no
				# foreground I/O, every survivor write is a spare write
				record "$spec" rebuild 0 "$WINDOW" \
					"survivors:r:${survivors[*]}" "spare-columns:w:${survivors[*]}"
			else
				record "$spec" rebuild 0 "$WINDOW" \
					"survivors:r:${survivors[*]}" "spare:w:$extra_dev"
			fi ;;
		copyback)
			[ "$eng" = dcl ] || continue
			rk_pop_show | grep -qE '^(populating|populated)' ||
				{ log "$spec: no population armed (run the rebuild state first); skipping copyback"; continue; }
			if ! populate_done; then
				log "$spec: waiting for population to finish before copyback"
				rk_wait_populated || { log "$spec: population did not finish; skipping copyback"; continue; }
			fi
			wipe_devs "$victim"
			BEFORE=$(snap_all)
			window_start
			"$MDADM" --add "$MD" "$victim" >/dev/null 2>&1
			sleep 1
			watch_window copyback_done
			window_stop
			AFTER=$(snap_all)
			[ "$DONE" = 1 ] && echo "      (completed in ${WINDOW}s)"
			record "$spec" copyback 0 "$WINDOW" \
				"pool:r:${survivors[*]}" "replacement:w:$victim" ;;
		*) die "unknown state: $STATE" ;;
		esac
	done
	stop_md
	wipe_devs "${DEVLIST[@]:0:$((pool + 1))}"
done

[ -z "$DEVS" ] && { stop_md; rmmod null_blk 2>/dev/null; }

python3 - "$CSV" > "$OUTPUT/summary.md" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
arms = list(dict.fromkeys(r["arm"] for r in rows))
print("# Request size at the members\n")
print("Average request size in KiB (merged share). Writes below the drive's IU are rewritten whole by the drive.\n")
print("| arm | state | device set | dir | avg KiB | merged | device-set MiB/s | fio MiB/s | busy cores | stripe cache peak / min |")
print("|---|---|---|---|---|---|---|---|---|---|")
for r in rows:
    print("| %s | %s | %s | %s | %s | %s%% | %s | %s | %s | %s / %s |" % (r["arm"], r["state"], r["devset"], r["dir"],
          r["avg_kib"], r["merged_pct"], r["set_mibps"],
          r["fio_mibps"] if r["fio_mibps"] != "0" else "-", r["busy_cores"],
          r["scache_peak_active"], r["scache_min"]))
PY
dmesg | grep -E 'WARNING:|BUG:|Call Trace' | tail -5
cat "$OUTPUT/summary.md"
log "results: $CSV  $OUTPUT/summary.md"
