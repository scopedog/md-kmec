#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# raidkm-test-nowait.sh — fio io_uring 1 MiB O_DIRECT reads must not fall far
# behind 2 MiB reads or libaio when the members' max transfer is below the
# chunk ("1vs2MiB": 7x slower on a 4-member RHEL 9.8 rig, 36x on 4 NVMe).
# io_uring sent a 1 MiB read as one REQ_NOWAIT bio; the aligned-read bypass
# cloned it per chunk with the flag; a member had to split its clone and the
# block layer refused (BLK_STS_AGAIN); raid5_align_endio took that for a read
# error and redid the read through the stripe cache.  raidkm no longer
# advertises NOWAIT (upstream 3fe5b7c9).
#
# What this proves (4 members, k=2 m=2 rotating, chunk 512 KiB = stripe
# width 1 MiB; loop devices on tmpfs, NOWAIT-capable, whose max_sectors_kb is
# lowered to 128 AFTER the create -- before it, md would stack the limit and
# split the bios itself):
#   N1  the array does not advertise nowait (queue/nowait 0, where the
#       kernel has the attribute; RHEL 9.8 has not)
#   N2  io_uring 1 MiB reads reach at least NW_RATIO (default 0.5) of io_uring
#       2 MiB and of libaio 1 MiB
# Skipped (exit 77) without fio, python3, or fio's io_uring or libaio engine.  RHEL 9 ships
# kernel.io_uring_disabled=2: the suite enables io_uring for its run and
# restores the setting.
#
# Usage: bash <this>     (see raidkm-test-lib.sh for configuration)
#   NW_MEMSZ=512 (MiB per member)  NW_RATIO=0.5  NW_SECS=10 (per fio run)
set -u
[ "$(id -u)" = 0 ] || exec sudo -E bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

command -v fio >/dev/null || rk_skip "fio not installed"
command -v python3 >/dev/null || rk_skip "python3 not installed (parses fio's JSON)"
fio --enghelp 2>/dev/null | grep -qw io_uring || rk_skip "fio has no io_uring engine"
fio --enghelp 2>/dev/null | grep -qw libaio || rk_skip "fio has no libaio engine (N2 compares against it)"

NMEM=4; MEMSZ=${NW_MEMSZ:-512}; RATIO=${NW_RATIO:-0.5}; SECS=${NW_SECS:-10}
MEM=$RK_TMP/nowait-mem; M=()
URD=$(sysctl -n kernel.io_uring_disabled 2>/dev/null)

cleanup() {
	[ -n "$URD" ] && sysctl -q kernel.io_uring_disabled="$URD"
	rk_stop
	local l t
	for l in "${M[@]:-}"; do [ -n "$l" ] && losetup -d "$l" 2>/dev/null; done
	# loop detach is asynchronous: wait for it, never stack tmpfs mounts
	for t in $(seq 50); do mountpoint -q "$MEM" || return 0; umount "$MEM" 2>/dev/null; sleep 0.2; done
	umount -l "$MEM"
}
trap cleanup EXIT
# raidkm-test-ci.sh ends a suite past its time limit with SIGTERM, which skips
# an EXIT trap unless it is turned into an exit: kernel.io_uring_disabled is a
# security setting, restore it on every way out
trap 'exit 130' INT
trap 'exit 143' TERM

[ -n "$URD" ] && [ "$URD" != 0 ] && { sysctl -q kernel.io_uring_disabled=0 ||
	rk_skip "cannot enable io_uring (kernel.io_uring_disabled=$URD)"; }
rk_load_modules || exit 1

mkdir -p "$MEM"
mount -t tmpfs -o size=$(( NMEM * MEMSZ + 64 ))m tmpfs "$MEM" || { rk_fail "tmpfs"; rk_summary; exit 1; }
for i in $(seq 0 $((NMEM - 1))); do
	truncate -s "${MEMSZ}M" "$MEM/m$i"; M+=("$(losetup -f --show "$MEM/m$i")")
done
"$MDADM" --create "$MD" --level=raidkm --parity-count=2 --layout=rotating \
	--raid-devices=$NMEM --chunk=512 --bitmap=none --assume-clean --run --force \
	"${M[@]}" > "$RK_TMP/nowait-create.out" 2>&1 ||
	{ rk_fail "create: $(tail -1 "$RK_TMP/nowait-create.out")"; rk_summary; exit 1; }
dd if=/dev/urandom of="$MD" bs=1M count=$(( (NMEM - 2) * MEMSZ * 3 / 4 )) oflag=direct status=none
for l in "${M[@]}"; do echo 128 > "/sys/block/${l#/dev/}/queue/max_sectors_kb"; done
rk_log "md max_sectors_kb $(cat /sys/block/$MDNAME/queue/max_sectors_kb), member $(cat /sys/block/${M[0]#/dev/}/queue/max_sectors_kb)"

# ---- N1 ------------------------------------------------------------------------
if [ -r /sys/block/$MDNAME/queue/nowait ]; then
	nw=$(cat /sys/block/$MDNAME/queue/nowait)
	[ "$nw" = 0 ] && rk_pass "N1: queue/nowait 0" || rk_fail "N1: queue/nowait $nw"
else
	rk_skip_check "N1: the kernel has no queue/nowait attribute"
fi

# ---- N2 ------------------------------------------------------------------------
bw() {	# bw <engine> <bs>: MiB/s of a sequential O_DIRECT read; exits on no number
	local out v
	out=$(fio --name=nw --filename="$MD" --rw=read --direct=1 --ioengine="$1" --bs="$2" \
		--iodepth=16 --numjobs=1 --size=$(( (NMEM - 2) * MEMSZ / 2 ))M \
		--time_based --runtime="$SECS" --output-format=json 2>"$RK_TMP/nowait-fio.err")
	v=$(python3 -c 'import json,sys; print(int(json.load(sys.stdin)["jobs"][0]["read"]["bw"] / 1024))' \
		<<< "$out" 2>/dev/null)
	if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" = 0 ]; then
		echo "ERROR: fio $1 bs=$2 gave no bandwidth: $(head -2 "$RK_TMP/nowait-fio.err")" >&2
		exit 2
	fi
	echo "$v"
}
u1=$(bw io_uring 1M) || exit 2
u2=$(bw io_uring 2M) || exit 2
a1=$(bw libaio 1M) || exit 2
rk_log "io_uring 1M $u1 MiB/s, io_uring 2M $u2 MiB/s, libaio 1M $a1 MiB/s"
ok() { python3 -c "import sys; sys.exit(0 if $1 >= $RATIO * $2 else 1)"; }
ok "$u1" "$u2" && rk_pass "N2: io_uring 1M >= $RATIO x io_uring 2M" ||
	rk_fail "N2: io_uring 1M $u1 < $RATIO x io_uring 2M $u2"
ok "$u1" "$a1" && rk_pass "N2: io_uring 1M >= $RATIO x libaio 1M" ||
	rk_fail "N2: io_uring 1M $u1 < $RATIO x libaio 1M $a1"

rk_summary
