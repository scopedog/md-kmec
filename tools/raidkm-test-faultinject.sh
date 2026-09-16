#!/bin/bash
# raidkm-test-faultinject.sh — the kernel's own fault injection under a
# filesystem workload.
#
# The other suites fail members by hand (mdadm --fail, bad-block entries).
# This one lets the block layer fail the I/O instead — fail_make_request on a
# member, fail_page_alloc for the row layer's chunk-sized buffers,
# fail_io_timeout on a scsi_debug disk — while fsx and fsstress (xfstests,
# written by the filesystem maintainers) run on ext4 over the array, and a
# checksummed file sits beside them.  md, not the test, decides what to do
# with each error.  Meant for a debug kernel: KASAN and lockdep see the error
# paths while they run.
#
# Array: 8+2 rotating at 128 KiB chunk, resynced (not --assume-clean), on
# 11 ramdisks of FI_MEMBER_MB (or RK_DEVS: 11 real devices), ext4 aligned to
# the 1 MiB row.
#
#   S1  fail_make_request on one member (1%, FI_INJECT failures) under fsx and
#       fsstress; md fails the member or records bad blocks
#   S2  then a second member (the m=2 limit), the same way
#   S3  full redundancy restored, one member failed and re-added, and read
#       errors injected on a survivor while it rebuilds (singly degraded)
#   S4  fail_page_alloc for order >= 5 (the row layer's 128 KiB buffers) during
#       a degraded read and a rebuild onto a spare: the rebuild completes and
#       rebuild_done + rebuild_stripe_chunks accounts for every chunk
#   S5  fail_io_timeout on a scsi_debug-backed 8+2 array under fsx and fsstress
#
# Each scenario passes when: the injection really fired, fsx exits 0 and
# fsstress completes, the checksummed file is unchanged after recovery, and
# the kernel log holds no KASAN / lockdep / WARNING report (known platform
# artifacts excluded, see RK_DMESG_KNOWN).  The final state also needs a scrub
# with mismatch_cnt 0 and a clean e2fsck -fn.
#
# Skipped (exit 77, with the reason) when the kernel has no
# CONFIG_FAIL_MAKE_REQUEST / CONFIG_FAULT_INJECTION_DEBUG_FS or no ext4, or when
# fsx/fsstress, fio or e2fsprogs are missing.  S4 needs CONFIG_FAIL_PAGE_ALLOC and
# S5 needs CONFIG_FAIL_IO_TIMEOUT plus the scsi_debug module; each is skipped
# on its own (logged, not counted) when absent.
#
# Environment:
#   XFSTESTS_DIR     a built xfstests checkout (ltp/fsx, ltp/fsstress); default:
#                    searched in the usual places
#   FI_MEMBER_MB     ramdisk member size in MiB (default 768: ~8.5 GiB of RAM)
#   FI_INJECT        failures injected per member in S1/S2 (default 400)
#   FI_FSX_OPS       fsx operations per scenario (default 100000)
#   FI_FSSTRESS_OPS  fsstress operations per process, 8 processes (default 4000)
#   FI_CONTROL=1     run the same scenarios on stock raid6 (raid456) first, as
#                    the control for triage; its failures are reported, not counted
#   FI_KEEP=DIR      keep per-scenario logs and kernel logs here
#                    (default $RK_TMP/faultinject)
#
# Usage: sudo bash tools/raidkm-test-faultinject.sh
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=10
CHUNK=128
MEMBER_MB=${FI_MEMBER_MB:-768}
INJECT=${FI_INJECT:-400}
FSX_OPS=${FI_FSX_OPS:-100000}
FSSTRESS_OPS=${FI_FSSTRESS_OPS:-4000}
OUT=${FI_KEEP:-$RK_TMP/faultinject}
MNT=$RK_TMP/faultinject-mnt
DBG=/sys/kernel/debug
DEVS=()
ENG=
TAG=
SUM=
COUNTED=1		# 0 while the stock raid6 control runs
PIDS=()

# ---- capabilities ------------------------------------------------------------

mountpoint -q $DBG || mount -t debugfs none $DBG 2>/dev/null
[ -d $DBG/fail_make_request ] ||
	rk_skip "kernel has no fail_make_request (CONFIG_FAIL_MAKE_REQUEST, CONFIG_FAULT_INJECTION_DEBUG_FS)"
modprobe ext4 2>/dev/null
grep -qw ext4 /proc/filesystems || rk_skip "kernel has no ext4"
for t in fio mkfs.ext4 e2fsck sha256sum udevadm; do
	command -v $t >/dev/null || rk_skip "$t not installed"
done
if [ -z "${XFSTESTS_DIR:-}" ]; then
	for d in "$RK_TREE/../xfstests-dev" "${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)/xfstests-dev}" \
		 /usr/lib/xfstests /var/lib/xfstests /opt/xfstests; do
		[ -n "$d" ] && [ -x "$d/ltp/fsx" ] && [ -x "$d/ltp/fsstress" ] && { XFSTESTS_DIR=$d; break; }
	done
fi
[ -x "${XFSTESTS_DIR:-}/ltp/fsx" ] && [ -x "$XFSTESTS_DIR/ltp/fsstress" ] ||
	rk_skip "no built xfstests (ltp/fsx, ltp/fsstress): set XFSTESTS_DIR"
HAVE_PAGE_ALLOC=0; [ -d $DBG/fail_page_alloc ] && HAVE_PAGE_ALLOC=1
HAVE_IO_TIMEOUT=0; [ -d $DBG/fail_io_timeout ] && modinfo scsi_debug >/dev/null 2>&1 && HAVE_IO_TIMEOUT=1

rk_resolve_mdadm || exit 1
rk_load_modules || exit 1
if [ -z "$RK_DEVS" ]; then
	# ramdisks an earlier suite left loaded (at another size) still hold memory
	lsmod | grep -q '^brd ' && rmmod brd 2>/dev/null
	avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
	need=$(( (N + 1) * MEMBER_MB * 1024 + 2 * 1048576 ))
	[ "$avail" -ge "$need" ] || {
		echo "ERROR: $((need / 1048576)) GiB of free memory needed for $((N + 1)) x $MEMBER_MB MiB ramdisks, $((avail / 1048576)) GiB available (lower FI_MEMBER_MB)" >&2
		exit 1
	}
	BRD_SIZE_KB=$((MEMBER_MB * 1024))
fi
rk_setup_brd $((N + 1)) || exit 1
read -r -a DEVS <<< "$(rk_pick_disks $((N + 1)))"
mkdir -p "$OUT" "$MNT"

# ---- helpers ------------------------------------------------------------------

ok()  { if [ "$COUNTED" = 1 ]; then rk_pass "$*"; else rk_log "control PASS: $*"; fi; }
bad() { if [ "$COUNTED" = 1 ]; then rk_fail "$*"; else rk_log "control FAIL: $*"; fi; }
mdsys() { echo "/sys/block/$MDNAME/md/$1"; }

inject_off() {
	local f
	for f in fail_make_request fail_page_alloc fail_io_timeout; do
		[ -d $DBG/$f ] || continue
		echo 0 > $DBG/$f/probability
		echo 0 > $DBG/$f/times 2>/dev/null
	done
	for f in /sys/class/block/*/make-it-fail /sys/block/*/io-timeout-fail; do
		[ -w "$f" ] && echo 0 > "$f"
	done
}

# fail_make_request on one device: <dev> <percent> <failures>
inject_member() {
	local sysf
	sysf=/sys/class/block/$(basename "$(readlink -f "$1")")/make-it-fail
	[ -w "$sysf" ] || { bad "$TAG: no make-it-fail for $1"; return 1; }
	echo 0 > $DBG/fail_make_request/verbose
	echo 1 > $DBG/fail_make_request/interval
	echo 0 > $DBG/fail_make_request/space
	echo "$3" > $DBG/fail_make_request/times
	echo "$2" > $DBG/fail_make_request/probability
	echo 1 > "$sysf"
}

# failures consumed since <initial times>: <fault> <initial>
injected() { echo $(( $2 - $(cat $DBG/$1/times) )); }

workload_start() {
	mkdir -p "$MNT/fsx" "$MNT/fss"
	( "$XFSTESTS_DIR/ltp/fsx" -q -N "$FSX_OPS" -S 1234 "$MNT/fsx/file" > "$OUT/$TAG.fsx.log" 2>&1
	  echo "fsx exit $?" >> "$OUT/$TAG.fsx.log" ) &
	PIDS=($!)
	( "$XFSTESTS_DIR/ltp/fsstress" -d "$MNT/fss" -n "$FSSTRESS_OPS" -p 8 -s 5678 > "$OUT/$TAG.fsstress.log" 2>&1
	  echo "fsstress exit $?" >> "$OUT/$TAG.fsstress.log" ) &
	PIDS+=($!)
}
workload_wait() {
	wait "${PIDS[@]}" 2>/dev/null
	PIDS=()
	grep -q "^fsx exit 0$" "$OUT/$TAG.fsx.log" && ok "$TAG: fsx clean" ||
		bad "$TAG: fsx $(tail -1 "$OUT/$TAG.fsx.log") (see $OUT/$TAG.fsx.log)"
	grep -q "^fsstress exit 0$" "$OUT/$TAG.fsstress.log" && ok "$TAG: fsstress ran to completion" ||
		bad "$TAG: fsstress $(tail -1 "$OUT/$TAG.fsstress.log")"
}

data_write() {	# <size>
	fio --name=d --filename="$MNT/data.bin" --rw=write --bs=1M --size="$1" --direct=1 \
	    --ioengine=libaio --refill_buffers > /dev/null 2>&1
	sync
	SUM=$(sha256sum "$MNT/data.bin" | cut -c1-64)
}
data_check() {
	local s
	echo 3 > /proc/sys/vm/drop_caches
	s=$(sha256sum "$MNT/data.bin" 2>/dev/null | cut -c1-64)
	[ -n "$s" ] && [ "$s" = "$SUM" ] && ok "$TAG: checksummed file unchanged" ||
		bad "$TAG: checksummed file CHANGED or unreadable"
}

wait_sync() {	# until no resync/recovery/check is running
	local t=0
	sleep 2
	while [ "$(cat "$(mdsys sync_action)" 2>/dev/null)" != idle ] ||
	      grep -q 'recovery\|resync\|check' <(grep -A3 "^$MDNAME " /proc/mdstat); do
		sleep 2; t=$((t + 2))
		[ $t -ge 3600 ] && { bad "$TAG: array still syncing after an hour"; return 1; }
	done
	return 0	# the loop's status is its last test's, not the sync's
}
scrub_check() {
	echo check > "$(mdsys sync_action)"
	wait_sync
	local mm; mm=$(cat "$(mdsys mismatch_cnt)")
	[ "$mm" = 0 ] && ok "$TAG: scrub mismatch_cnt 0" || bad "$TAG: scrub mismatch_cnt $mm"
}
fsck_check() {
	umount "$MNT"
	e2fsck -fn "$MD" > "$OUT/$TAG.fsck.log" 2>&1 && ok "$TAG: e2fsck -fn clean" ||
		bad "$TAG: e2fsck reported problems (see $OUT/$TAG.fsck.log)"
	mount "$MD" "$MNT"
}
dmesg_window() {	# judge the kernel log since the last window, then start a new one
	dmesg > "$OUT/$TAG.dmesg"
	dmesg -C
	local n known
	n=$(rk_dmesg_splats "$OUT/$TAG.dmesg" "$OUT/$TAG.known")
	known=$(cat "$OUT/$TAG.known"); rm -f "$OUT/$TAG.known"
	[ "$n" = 0 ] && ok "$TAG: no KASAN / lockdep / WARNING report$([ "${known:-0}" != 0 ] && echo " ($known known artifact(s) ignored)")" ||
		bad "$TAG: $n kernel report line(s) (see $OUT/$TAG.dmesg)"
}
state() { grep -A1 "^$MDNAME " /proc/mdstat | tr -s ' \n' ' '; echo; }
failed_members() {	# members md marked (F)
	awk -v m="$MDNAME" '$1 == m { for (i = 5; i <= NF; i++) if ($i ~ /\(F\)/) { sub(/\[.*$/, "", $i); print "/dev/" $i } }' /proc/mdstat
}
bad_block_ranges() {	# <dev>
	grep -c . "$(mdsys "dev-$(basename "$(readlink -f "$1")")/bad_blocks")" 2>/dev/null || echo 0
}

create_array() {	# <engine> <devices...>
	local eng=$1 d; shift
	rk_stop
	udevadm settle
	for d in "$@"; do
		"$MDADM" --zero-superblock --force "$d" >/dev/null 2>&1
		wipefs -a -q "$d" 2>/dev/null
	done
	if [ "$eng" = raid6 ]; then
		"$MDADM" --create "$MD" --level=6 --raid-devices=$N --chunk=$CHUNK --bitmap=none \
			--run --force "$@" > "$OUT/$eng.create.log" 2>&1 || return 1
	else
		"$MDADM" --create "$MD" --level=raidkm --parity-count=2 --layout=rotating \
			--raid-devices=$N --chunk=$CHUNK --bitmap=none --run --force "$@" \
			> "$OUT/$eng.create.log" 2>&1 || return 1
	fi
	udevadm settle
	echo 2000000 > "$(mdsys sync_speed_min)"
	wait_sync
	mkfs.ext4 -q -F -E stride=32,stripe_width=256 "$MD" && mount "$MD" "$MNT"
}
teardown() {
	[ ${#PIDS[@]} -gt 0 ] && kill "${PIDS[@]}" 2>/dev/null && wait "${PIDS[@]}" 2>/dev/null
	PIDS=()
	inject_off
	umount "$MNT" 2>/dev/null
	rk_stop
	udevadm settle
}
trap 'teardown; lsmod | grep -q "^scsi_debug " && modprobe -r scsi_debug' EXIT

# ---- scenarios -----------------------------------------------------------------

run_engine() {	# <engine>
	ENG=$1
	local spare=${DEVS[$N]} n dev
	echo "=== $ENG: 8+2 rotating, ${CHUNK} KiB chunk, ext4 ==="
	inject_off
	TAG=$ENG-create
	create_array "$ENG" "${DEVS[@]:0:$N}" || { bad "$ENG: create failed (see $OUT/$ENG.create.log)"; return; }
	data_write 1G
	dmesg_window

	TAG=$ENG-S1
	rk_log "$TAG: fail_make_request on ${DEVS[3]} (1%, $INJECT failures) under fsx + fsstress"
	workload_start; sleep 10
	inject_member "${DEVS[3]}" 1 "$INJECT"
	workload_wait
	n=$(injected fail_make_request "$INJECT"); inject_off
	[ "$n" -gt 0 ] && ok "$TAG: $n failures injected" || bad "$TAG: no failure was injected"
	rk_log "$TAG: $(state)"
	data_check; dmesg_window

	TAG=$ENG-S2
	rk_log "$TAG: second member ${DEVS[6]} (1%, $INJECT failures)"
	workload_start; sleep 10
	inject_member "${DEVS[6]}" 1 "$INJECT"
	workload_wait
	n=$(injected fail_make_request "$INJECT"); inject_off
	[ "$n" -gt 0 ] && ok "$TAG: $n failures injected" || bad "$TAG: no failure was injected"
	rk_log "$TAG: $(state)"
	# md records a write error in the member's bad-block log instead of failing
	# the member when it can: either outcome handles the error
	if failed_members | grep -qx "${DEVS[6]}"; then
		ok "$TAG: member failed"
	elif [ "$(bad_block_ranges "${DEVS[6]}")" -gt 0 ]; then
		ok "$TAG: member kept, $(bad_block_ranges "${DEVS[6]}") bad-block range(s) recorded"
	else
		bad "$TAG: the errors neither failed the member nor recorded bad blocks"
	fi
	data_check; dmesg_window

	# restore full redundancy, so the survivor read errors below hit a singly
	# degraded array (within m=2) instead of a third failure
	TAG=$ENG-S3
	rk_log "$TAG: rebuild from [10/9] with read errors injected on survivor ${DEVS[1]}"
	for dev in $(failed_members); do
		"$MDADM" "$MD" --remove "$dev" >/dev/null 2>&1
		wipefs -a -q "$dev"; "$MDADM" --zero-superblock --force "$dev" >/dev/null 2>&1
	done
	wipefs -a -q "$spare"; "$MDADM" "$MD" --add "$spare" >/dev/null 2>&1
	[ "$(cat "$(mdsys degraded)")" -ge 2 ] && "$MDADM" "$MD" --add "${DEVS[3]}" >/dev/null 2>&1
	[ "$(cat "$(mdsys degraded)")" -ge 1 ] && "$MDADM" "$MD" --add "${DEVS[6]}" >/dev/null 2>&1
	wait_sync
	if [ "$(cat "$(mdsys degraded)")" != 0 ]; then
		bad "$TAG: could not restore full redundancy: $(state)"
	else
		"$MDADM" "$MD" --fail "${DEVS[8]}" >/dev/null 2>&1; sleep 1
		"$MDADM" "$MD" --remove "${DEVS[8]}" >/dev/null 2>&1
		wipefs -a -q "${DEVS[8]}"
		inject_member "${DEVS[1]}" 1 50
		"$MDADM" "$MD" --add "${DEVS[8]}" >/dev/null 2>&1
		wait_sync
		n=$(injected fail_make_request 50); inject_off
		[ "$n" -gt 0 ] && ok "$TAG: $n failures injected during the rebuild" || bad "$TAG: no failure was injected"
		rk_log "$TAG: $(state)"
		[ "$(cat "$(mdsys degraded)")" -le 1 ] && ok "$TAG: array survived (degraded $(cat "$(mdsys degraded)"))" ||
			bad "$TAG: array lost more than one member: $(state)"
	fi
	data_check; fsck_check; dmesg_window

	if [ "$ENG" = raidkm ]; then
		TAG=$ENG-S4
		if [ "$HAVE_PAGE_ALLOC" = 0 ]; then
			rk_log "$TAG SKIPPED: kernel has no fail_page_alloc (CONFIG_FAIL_PAGE_ALLOC)"
		else
			scenario_s4
		fi
	fi

	TAG=$ENG-final
	for dev in $(failed_members); do
		"$MDADM" "$MD" --remove "$dev" >/dev/null 2>&1; wipefs -a -q "$dev"
		"$MDADM" "$MD" --add "$dev" >/dev/null 2>&1
	done
	wait_sync
	scrub_check; fsck_check; data_check; dmesg_window
	teardown
}

# fail_page_alloc order >= 5 while a degraded read and a rebuild onto a spare run
scenario_s4() {
	local victim=${DEVS[5]} before after chunks d0 s0 d1 s1 times=100000 n spare=0
	rk_log "$TAG: fail_page_alloc order>=5 (20%) under degraded read + rebuild onto a spare"
	# S3 can leave a hot spare: md then starts rebuilding the moment the victim
	# fails, so the counters and the injection must be in place before that
	grep -A1 "^$MDNAME " /proc/mdstat | grep -q '(S)' && spare=1
	before=$(cat "$(mdsys rk_row_stats)")
	echo 5 > $DBG/fail_page_alloc/min-order
	# the row buffers are GFP_NOIO (may sleep): ignoring sleeping allocations
	# would skip exactly them
	echo 0 > $DBG/fail_page_alloc/ignore-gfp-wait
	echo 0 > $DBG/fail_page_alloc/ignore-gfp-highmem
	echo 0 > $DBG/fail_page_alloc/verbose
	echo 1 > $DBG/fail_page_alloc/interval
	echo $times > $DBG/fail_page_alloc/times
	echo 20 > $DBG/fail_page_alloc/probability
	echo 3 > /proc/sys/vm/drop_caches
	"$MDADM" "$MD" --fail "$victim" >/dev/null 2>&1; sleep 1
	"$MDADM" "$MD" --remove "$victim" >/dev/null 2>&1
	wipefs -a -q "$victim"
	dd if="$MNT/data.bin" of=/dev/null bs=4M iflag=direct status=none &
	PIDS=($!)
	[ "$spare" = 0 ] && "$MDADM" "$MD" --add "$victim" >/dev/null 2>&1
	wait "${PIDS[@]}"; PIDS=()
	wait_sync
	[ "$spare" = 1 ] && "$MDADM" "$MD" --add "$victim" >/dev/null 2>&1	# the next hot spare
	n=$(injected fail_page_alloc $times); inject_off
	after=$(cat "$(mdsys rk_row_stats)")
	rs() { awk -v k="$2" '$1 == k {print $2}' <<< "$1"; }
	[ "$n" -gt 0 ] && ok "$TAG: $n allocation failures injected" || bad "$TAG: no allocation failure was injected"
	[ "$(cat "$(mdsys degraded)")" = 0 ] && ok "$TAG: rebuild completed" || bad "$TAG: rebuild did not complete: $(state)"
	chunks=$(( $(cat "$(mdsys component_size)") / CHUNK ))
	d0=$(rs "$before" rebuild_done); s0=$(rs "$before" rebuild_stripe_chunks)
	d1=$(rs "$after" rebuild_done);  s1=$(rs "$after" rebuild_stripe_chunks)
	if [ -z "$s1" ]; then
		bad "$TAG: raidkm has no rebuild_stripe_chunks counter"
	elif [ $(( d1 - d0 + s1 - s0 )) = "$chunks" ]; then
		ok "$TAG: every chunk accounted: $((d1 - d0)) row + $((s1 - s0)) stripe = $chunks"
	else
		bad "$TAG: rebuild_done + rebuild_stripe_chunks = $((d1 - d0 + s1 - s0)), member has $chunks chunks"
	fi
	rk_log "$TAG: band_nomem +$(( $(rs "$after" rebuild_band_nomem) - $(rs "$before" rebuild_band_nomem) )), set workers $(rs "$after" rebuild_set_workers), page buffers $(rs "$after" rebuild_set_page_bufs), dread_declined +$(( $(rs "$after" dread_declined) - $(rs "$before" dread_declined) ))"
	data_check; dmesg_window
}

# fail_io_timeout needs a request-based disk: scsi_debug, one store per host
run_scsi_debug() {	# <engine>
	ENG=$1-scsi_debug
	TAG=$ENG-S5
	local sds=() victim n d
	rk_log "$TAG: fail_io_timeout on a scsi_debug disk under fsx + fsstress"
	teardown
	modprobe -r scsi_debug 2>/dev/null
	lsmod | grep -q '^scsi_debug ' && { bad "$TAG: scsi_debug is in use"; return; }
	# a shared store (the default) shows every disk with the same superblock and
	# mdadm's ADD_NEW_DISK gets EBUSY: one host and one store per disk
	modprobe scsi_debug add_host=$N num_tgts=1 max_luns=1 dev_size_mb=384 per_host_store=1 ||
		{ bad "$TAG: modprobe scsi_debug failed"; return; }
	udevadm settle; sleep 2
	for d in /sys/block/sd*; do
		grep -q scsi_debug "$d/device/model" 2>/dev/null && sds+=("/dev/$(basename "$d")")
	done
	[ ${#sds[@]} = $N ] || { bad "$TAG: expected $N scsi_debug disks, found ${#sds[@]}"; return; }
	for d in "${sds[@]}"; do echo 8 > "/sys/block/$(basename "$d")/device/timeout"; done
	create_array "$1" "${sds[@]}" || { bad "$TAG: create failed"; modprobe -r scsi_debug; return; }
	data_write 256M
	victim=${sds[3]}
	workload_start; sleep 10
	echo 0 > $DBG/fail_io_timeout/verbose
	echo 1 > $DBG/fail_io_timeout/interval
	echo 20 > $DBG/fail_io_timeout/times
	echo 2 > $DBG/fail_io_timeout/probability
	echo 1 > "/sys/block/$(basename "$victim")/io-timeout-fail"
	workload_wait
	n=$(injected fail_io_timeout 20); inject_off
	[ "$n" -gt 0 ] && ok "$TAG: $n timeouts injected" || bad "$TAG: no timeout was injected"
	rk_log "$TAG: $(state)"
	data_check; scrub_check; fsck_check; dmesg_window
	teardown
	modprobe -r scsi_debug
}

# ---- run ---------------------------------------------------------------------

{
	echo "kernel $(uname -r)"
	echo "raidkm $(cat /sys/module/raidkm/srcversion) default_row_rebuild=$(cat /sys/module/raidkm/parameters/default_row_rebuild)"
	echo "devices ${DEVS[*]}"
	echo "xfstests $XFSTESTS_DIR"
	echo "fault injection: $(ls -d $DBG/fail_* 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
} | tee "$OUT/env.txt" | sed 's/^/    /'
rk_dmesg_clear

if [ "${FI_CONTROL:-0}" = 1 ]; then
	if modprobe raid456 2>/dev/null; then
		COUNTED=0; run_engine raid6; COUNTED=1
	else
		rk_log "control SKIPPED: no raid456 module"
	fi
fi
run_engine raidkm

if [ "$HAVE_IO_TIMEOUT" = 0 ]; then
	rk_log "S5 SKIPPED: needs fail_io_timeout (CONFIG_FAIL_IO_TIMEOUT) and the scsi_debug module"
else
	if [ "${FI_CONTROL:-0}" = 1 ] && lsmod | grep -q '^raid456 '; then
		COUNTED=0; run_scsi_debug raid6; COUNTED=1
	fi
	run_scsi_debug raidkm
fi

rk_log "logs: $OUT"
rk_summary
