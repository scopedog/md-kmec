#!/bin/bash
# raidkm-test-xfstests.sh — xfstests on ext4 over raidkm, healthy and degraded.
#
# xfstests is the Linux filesystem maintainers' own regression suite; here it
# is the independent judge of whether ext4 on a raidkm array behaves like ext4
# on any block device.  Two 8+2 rotating arrays at 128 KiB chunk: $MD is
# xfstests' TEST_DEV and $XT_SCRATCH_MD its SCRATCH_DEV, ext4 aligned to the
# 1 MiB row.  The tests run once with both arrays healthy and once with one
# member failed and removed on each.
#
#   fsx         generic/075 091 112 127 263
#   fsstress    generic/013 070 083 117
#   crash replay (dm-log-writes)   generic/455 482   (457 needs reflink: not on ext4)
#   power fail  (dm-flakey)        generic/311 321 322 325
#
# Passes when, in each state, at least one test ran and xfstests reports no
# failure, and the kernel log holds no KASAN / lockdep / WARNING report (known
# platform artifacts excluded).  Tests xfstests itself declares "not run" (a
# missing dm target, for example) are logged, not failed.
#
# Skipped (exit 77, with the reason) when the kernel has no ext4 or xfstests,
# mkfs.ext4 or xfs_io is missing.
#
# Devices: 24 ramdisks of XT_MEMBER_MB — ten per array, and the last four
# concatenated (dm-linear) as the dm-log-writes device — or RK_DEVS with at
# least 20 real devices (XT_LOGWRITES_DEV then names a log device, if any).
#
# Environment:
#   XFSTESTS_DIR      a built xfstests checkout (default: searched in the usual places)
#   XT_TESTS          tests to run (default: the list above)
#   XT_MEMBER_MB      ramdisk size in MiB (default 384: ~9 GiB of RAM)
#   XT_SCRATCH_MD     the scratch array (default /dev/md71)
#   XT_LOGWRITES_DEV  dm-log-writes device for RK_DEVS runs (default: none)
#   XT_CONTROL=1      run the same on stock raid6 first, as the control for
#                     triage; its failures are reported, not counted
#   XT_KEEP=DIR       results, check output and kernel logs (default $RK_TMP/xfstests)
#
# Usage: sudo bash tools/raidkm-test-xfstests.sh
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=10
CHUNK=128
MEMBER_MB=${XT_MEMBER_MB:-384}
TESTS=${XT_TESTS:-generic/075 generic/091 generic/112 generic/127 generic/263 generic/013 generic/070 generic/083 generic/117 generic/455 generic/482 generic/311 generic/321 generic/322 generic/325}
SMD=${XT_SCRATCH_MD:-/dev/md71}
OUT=${XT_KEEP:-$RK_TMP/xfstests}
TMNT=$RK_TMP/xt-test
SMNT=$RK_TMP/xt-scratch
LOGDM=rk-xt-logwrites
LOGDEV=${XT_LOGWRITES_DEV:-}
COUNTED=1
DEVS=()

# ---- capabilities ------------------------------------------------------------

modprobe ext4 2>/dev/null
grep -qw ext4 /proc/filesystems || rk_skip "kernel has no ext4"
for t in mkfs.ext4 xfs_io udevadm; do
	command -v $t >/dev/null || rk_skip "$t not installed (xfstests needs it)"
done
if [ -z "${XFSTESTS_DIR:-}" ]; then
	for d in "$RK_TREE/../xfstests-dev" "${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)/xfstests-dev}" \
		 /usr/lib/xfstests /var/lib/xfstests /opt/xfstests; do
		[ -n "$d" ] && [ -x "$d/check" ] && [ -x "$d/ltp/fsx" ] && { XFSTESTS_DIR=$d; break; }
	done
fi
[ -x "${XFSTESTS_DIR:-}/check" ] && [ -x "$XFSTESTS_DIR/ltp/fsx" ] ||
	rk_skip "no built xfstests (check, ltp/fsx): set XFSTESTS_DIR"

rk_resolve_mdadm || exit 1
rk_load_modules || exit 1
NDEV=$((2 * N))
if [ -z "$RK_DEVS" ]; then
	# ramdisks an earlier suite left loaded (at another size) still hold memory
	lsmod | grep -q '^brd ' && rmmod brd 2>/dev/null
	NDEV=$((2 * N + 4))
	avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
	need=$(( NDEV * MEMBER_MB * 1024 + 2 * 1048576 ))
	[ "$avail" -ge "$need" ] || {
		echo "ERROR: $((need / 1048576)) GiB of free memory needed for $NDEV x $MEMBER_MB MiB ramdisks, $((avail / 1048576)) GiB available (lower XT_MEMBER_MB)" >&2
		exit 1
	}
	BRD_SIZE_KB=$((MEMBER_MB * 1024))
fi
rk_setup_brd $NDEV || exit 1
read -r -a DEVS <<< "$(rk_pick_disks $NDEV)"
mkdir -p "$OUT" "$TMNT" "$SMNT"

ok()  { if [ "$COUNTED" = 1 ]; then rk_pass "$*"; else rk_log "control PASS: $*"; fi; }
bad() { if [ "$COUNTED" = 1 ]; then rk_fail "$*"; else rk_log "control FAIL: $*"; fi; }

# ---- arrays --------------------------------------------------------------------

stop_all() {
	umount "$TMNT" "$SMNT" 2>/dev/null
	"$MDADM" --stop "$MD" "$SMD" >/dev/null 2>&1
	udevadm settle
}
cleanup() {
	stop_all
	[ -e /dev/mapper/$LOGDM ] && dmsetup remove $LOGDM 2>/dev/null
}
trap cleanup EXIT

wait_sync() {	# <md>
	local name t=0
	name=$(basename "$1")
	sleep 2
	while [ "$(cat "/sys/block/$name/md/sync_action" 2>/dev/null)" != idle ]; do
		sleep 2; t=$((t + 2))
		[ $t -ge 3600 ] && { bad "$name still syncing after an hour"; return 1; }
	done
	return 0	# the loop's status is its last test's, not the sync's
}

create() {	# <engine> <md> <devices...>
	local eng=$1 md=$2 d; shift 2
	for d in "$@"; do
		"$MDADM" --zero-superblock --force "$d" >/dev/null 2>&1
		wipefs -a -q "$d" 2>/dev/null
	done
	if [ "$eng" = raid6 ]; then
		"$MDADM" --create "$md" --level=6 --raid-devices=$N --chunk=$CHUNK --bitmap=none \
			--run --force "$@" >> "$OUT/create.log" 2>&1
	else
		"$MDADM" --create "$md" --level=raidkm --parity-count=2 --layout=rotating \
			--raid-devices=$N --chunk=$CHUNK --bitmap=none --run --force "$@" >> "$OUT/create.log" 2>&1
	fi || return 1
	udevadm settle
	echo 2000000 > "/sys/block/$(basename "$md")/md/sync_speed_min"
	wait_sync "$md"
}

degrade() {	# one member failed and removed on each array
	"$MDADM" "$MD" --fail "${DEVS[3]}" >/dev/null 2>&1; sleep 1
	"$MDADM" "$MD" --remove "${DEVS[3]}" >/dev/null 2>&1
	"$MDADM" "$SMD" --fail "${DEVS[$((N + 6))]}" >/dev/null 2>&1; sleep 1
	"$MDADM" "$SMD" --remove "${DEVS[$((N + 6))]}" >/dev/null 2>&1
	[ "$(cat "/sys/block/$MDNAME/md/degraded")" = 1 ] &&
	[ "$(cat "/sys/block/$(basename "$SMD")/md/degraded")" = 1 ]
}

# ---- xfstests ----------------------------------------------------------------

run_check() {	# <tag>
	local tag=$1 cfg=$OUT/$1.config n ran failures notrun known
	mkfs.ext4 -q -F -E stride=32,stripe_width=256 "$MD" || { bad "$tag: mkfs.ext4 on $MD"; return; }
	{
		echo "export FSTYP=ext4"
		echo "export TEST_DEV=$MD"
		echo "export TEST_DIR=$TMNT"
		echo "export SCRATCH_DEV=$SMD"
		echo "export SCRATCH_MNT=$SMNT"
		echo "export MKFS_OPTIONS=\"-E stride=32,stripe_width=256\""
		[ -n "$LOGDEV" ] && echo "export LOGWRITES_DEV=$LOGDEV"
		echo "export RESULT_BASE=$OUT/$tag.results"
	} > "$cfg"
	[ -n "$LOGDEV" ] && wipefs -a -q "$LOGDEV" 2>/dev/null
	rk_log "$tag: xfstests $TESTS"
	dmesg -C
	# shellcheck disable=SC2086
	( cd "$XFSTESTS_DIR" && HOST_OPTIONS=$cfg ./check $TESTS ) > "$OUT/$tag.check.out" 2>&1
	dmesg > "$OUT/$tag.dmesg"
	umount "$TMNT" "$SMNT" 2>/dev/null

	# "Ran:" lists the not-run tests too
	notrun=$(sed -n 's/^Not run: //p' "$OUT/$tag.check.out" | tail -1)
	ran=$(( $(sed -n 's/^Ran: //p' "$OUT/$tag.check.out" | tail -1 | wc -w) - $(wc -w <<< "$notrun") ))
	failures=$(sed -n 's/^Failures: //p' "$OUT/$tag.check.out" | tail -1)
	[ -n "$notrun" ] && rk_log "$tag: not run: $notrun"
	if [ "$ran" -eq 0 ]; then
		bad "$tag: xfstests ran no test (see $OUT/$tag.check.out)"
	elif [ -n "$failures" ]; then
		bad "$tag: xfstests failures: $failures (see $OUT/$tag.results)"
	else
		ok "$tag: $ran test(s) passed"
	fi
	n=$(rk_dmesg_splats "$OUT/$tag.dmesg" "$OUT/$tag.known")
	known=$(cat "$OUT/$tag.known"); rm -f "$OUT/$tag.known"
	[ "$n" = 0 ] && ok "$tag: no KASAN / lockdep / WARNING report$([ "${known:-0}" != 0 ] && echo " ($known known artifact(s) ignored)")" ||
		bad "$tag: $n kernel report line(s) (see $OUT/$tag.dmesg)"
}

run_engine() {	# <engine>
	local eng=$1
	echo "=== $eng: two 8+2 rotating arrays, ${CHUNK} KiB chunk, ext4 ==="
	stop_all
	if ! create "$eng" "$MD" "${DEVS[@]:0:$N}" || ! create "$eng" "$SMD" "${DEVS[@]:$N:$N}"; then
		bad "$eng: create failed (see $OUT/create.log)"
		return
	fi
	run_check "$eng-healthy"
	if degrade; then
		run_check "$eng-degraded"
	else
		bad "$eng: could not degrade both arrays by one member"
	fi
	stop_all
}

# ---- run ---------------------------------------------------------------------

if [ -z "$RK_DEVS" ] && [ -z "$LOGDEV" ] && command -v dmsetup >/dev/null; then
	# concatenate the last four ramdisks into one dm-log-writes device
	sectors=$(blockdev --getsz "${DEVS[20]}")
	for i in 0 1 2 3; do
		echo "$((i * sectors)) $sectors linear ${DEVS[$((20 + i))]} 0"
	done | dmsetup create $LOGDM && LOGDEV=/dev/mapper/$LOGDM
fi

{
	echo "kernel $(uname -r)"
	echo "raidkm $(cat /sys/module/raidkm/srcversion)"
	echo "xfstests $XFSTESTS_DIR $(git -C "$XFSTESTS_DIR" log --oneline -1 2>/dev/null)"
	echo "devices ${DEVS[*]:0:$((2 * N))}"
	echo "log-writes device ${LOGDEV:-none}"
} | tee "$OUT/env.txt" | sed 's/^/    /'

if [ "${XT_CONTROL:-0}" = 1 ]; then
	if modprobe raid456 2>/dev/null; then
		COUNTED=0; run_engine raid6; COUNTED=1
	else
		rk_log "control SKIPPED: no raid456 module"
	fi
fi
run_engine raidkm

rk_log "results: $OUT"
rk_summary
