#!/bin/bash
# raidkm-test-powercut.sh — crash consistency of ordinary writes: power cut
# during I/O, replayed from a log of every member write, judged by an oracle
# that only demands what was durable at the cut.
#
# OPT-IN reliability test, NOT part of the default raidkm-test.sh runner.
#
# What the older crash harnesses do not cover.  raidkm-test-crash.sh cuts power
# during a reshape, drops even FUA writes, and then demands every byte back
# (hence "probabilistic, expect failures").  raidkm-test-soak.sh never crashes.
# This one asks the question a RAID must answer yes to: after power loss, is
# every write that was acknowledged durable (fdatasync returned) still there,
# and does the array come back consistent -- also with a member missing?
#
# Stack, per member:
#     file -> loop -> dm-log-writes-ord (log: file -> loop) -> md raidkm
# so every member write, flush and FUA lands in that member's log, in
# completion order.  dm-log-writes-ord (tools/dm-log-writes-ord, built here
# for the running kernel) is dm-log-writes changed to log each write when it
# completes: the stock target logs a write only with the flush that covered
# it, and two flushes completing out of order swap writes in the log -- a
# crash state no device produces, which this harness then reported as lost
# data (11-07).  PC_LW_STOCK=1 uses the stock target anyway.
# The workload (raidkm-pc-io.py run) writes self-describing sectors to the
# array and journals each generation once fdatasync() returns.
#
# A CUT: dmsetup-suspend every log-writes device (waits out in-flight I/O, holds
# new I/O), note the journal length, drop a mark into every log, resume.  With
# every member suspended nothing completes, so the marks form a consistent cut
# across all members: no write after one mark can have caused a write before
# another.  PC_CUTS cuts per run, at random times.
#
# Each cut is then replayed onto fresh member copies (raidkm-pc-io.py replay):
#   mark   everything completed before the cut      (write-through drives)
#   flush  only what completed flushes covered + FUA (volatile caches lost)
#   cache  flush + a random subset of the rest      (caches half written back)
# and for every copy set:
#   1. assemble all members, verify the oracle IMMEDIATELY (reads during the
#      post-crash resync), wait for resync, scrub: mismatch_cnt must be 0,
#      verify again
#   2. (PC_DEGRADED=1) assemble without one random member -- the write hole.
#      md refusing to start a dirty degraded array is SAFE and counted as such;
#      then (PC_FORCE_DIRTY) it is forced, as an operator would, and judged.  Without PPL a raid5/6-style
#      array can legitimately fail here (md inheritance; raid6 does too): such
#      failures are reported as "write-hole" and only counted as failures when
#      the array claims PPL (PC_CREATE_EXTRA=--consistency-policy=ppl).
#
# Scenarios (PC_SCENARIOS, space separated):
#   healthy   workload on a clean array
#   rebuild   a member failed and re-added before the workload; the cut lands
#             in the rebuild (recovery_offset / superblock ordering)
#   populate  (declustered) a member failed with rk_dcl_auto=1; the cut lands
#             in the population of the spare columns (journal + mark)
#
# Oracle failure kinds (raidkm-pc-io.py verify):
#   stale / zero   an acknowledged-durable write is gone         -> data loss
#   garbage        a sector that is no generation ever written   -> corruption
#   misplaced      a sector holding another sector's data        -> corruption
#   future         a generation never issued                     -> oracle bug
#   unreadable     a block the array cannot serve (EIO, short)   -> data loss
#
# Environment:
#   PC_LAYOUT        rk layout "2"/"2r" etc.               (default 2r)
#   PC_LEVEL=6       the matched control: stock md raid6 (m=2), same everything
#   PC_DCL="N G SC"  declustered pool instead: N members, group width G (k+m,
#                    m from PC_LAYOUT), SC spare columns; e.g. PC_LAYOUT=3
#                    PC_DCL="16 7 2" = 4+3 groups on 16 disks
#   PC_K             data members                          (default 4)
#   PC_MEMBER_MB     member size MiB                       (default 128)
#   PC_BLOCKS        4 KiB blocks the workload uses        (default: 3/4 of the array)
#   PC_ITER          runs per scenario                     (default 3)
#   PC_CUTS          cuts per run                          (default 4)
#   PC_MODES         replay modes                          (default "mark flush cache")
#   PC_DEGRADED      1 = also assemble without a member    (default 1)
#   PC_FORCE_DIRTY   1 = when md refuses the dirty degraded start, force it
#                    (start_dirty_degraded=1) and judge that too (default 1)
#   PC_SECONDS_MAX   max seconds between cuts              (default 4)
#   PC_SEED          base seed; a run prints its seed      (default: time)
#   PC_CREATE_EXTRA  extra mdadm --create args, e.g. --bitmap=internal
#   PC_DIR           backing files                         (default /var/tmp/raidkm-pc)
#   PC_KEEP=1        keep logs and copies of a failing cut in PC_DIR/fail-*
#   PC_THREADS, PC_SYNC_EVERY  workload shape              (default 8, 16)
#   PC_SNAP=1        native snapshots: the array is created with
#                    --snapshots=PC_SNAP_PCT (default 50), and beside the
#                    workload snapshots are created (and some destroyed) every
#                    PC_SNAP_EVERY seconds (default 1).  Oracle: snapshots never
#                    change, so each one's md5, taken right after its create
#                    returned (the create's commit flushes every member first:
#                    what it holds is durable), must come back after every cut;
#                    one recorded before a cut must exist unless its destroy
#                    had started.  Snapshot rows are never written in place, so
#                    no write hole excuses a snapshot failure.  The workload
#                    is kept to 1/16 of the origin (PC_BLOCKS unset): every
#                    row it touches costs one copy per snapshot, and at most 4
#                    live snapshots then fit the reserve (no ENOSPC).
#   PC_DISCARD=F     the workload also discards whole rows: F is the fraction
#                    of its operations that are discards (e.g. 0.02), 1 to
#                    PC_DISCARD_ROWS rows each (default 4).  The oracle takes
#                    zero for a block discarded after its durable write (see
#                    raidkm-pc-io.py).  With PC_DCL a row is ngroups x k
#                    chunks (a module from before 11-05 refuses discards
#                    on declustered arrays).
#   PC_DISCARD_MEMBERS  1 (default) = devices_handle_discard_safely=Y, so the
#                    members get the discards (dm-log-writes logs them, the
#                    replay zeroes them); 0 = the array alone takes them (row
#                    map: rows go U; without the map md then takes none)
#   PC_LW_STOCK=1    stock dm-log-writes instead of dm-log-writes-ord (its
#                    logs can swap two writes to one sector: false failures)
#   PC_CSUM_NEG=1    negative control for --checksum + member discards:
#                    csum_test_no_discard_drop=Y, the CRCs of trimmed blocks
#                    stay; the stale-CRC check below has to fail
# With --checksum in PC_CREATE_EXTRA every all-members check also counts
# "native csum mismatch" in dmesg: nothing here rots data, so one is a stale
# or missing CRC -- a failure.  (A forced dirty or degraded start is the
# write hole: a mismatch there is the CRC catching it, only reported.)
# That count is blind to most stale CRCs after a cut: the dirty start's
# resync stores the CRCs again, and a block md already gave up on before the
# cut (data + parity both rejected) sits in the members' bad-block lists,
# which reads fail with EIO without verifying anything.  So every
# all-members check also wants those lists empty: the loop members never
# fail a read, so an entry is a block md could not read or rebuild.  And the
# live run is checked the same way (mismatches during the workload, bad
# blocks on the live array): with no crash a stale CRC shows up there first,
# often healed from parity before the workload could see an error.
#
# Needs kernel headers for the running kernel (dm-log-writes-ord; or
# PC_LW_STOCK=1 and dm-log-writes), python3, a raidkm-aware mdadm.  Usage:
#   sudo bash tools/raidkm-test-powercut.sh
. "$(dirname "$0")/raidkm-test-lib.sh"

PCIO="$RK_LIB_DIR/raidkm-pc-io.py"
PC_LAYOUT="${PC_LAYOUT:-2r}"
PC_K="${PC_K:-4}"
PC_MEMBER_MB="${PC_MEMBER_MB:-128}"
PC_ITER="${PC_ITER:-3}"
PC_CUTS="${PC_CUTS:-4}"
PC_MODES="${PC_MODES:-mark flush cache}"
PC_DEGRADED="${PC_DEGRADED:-1}"
PC_SECONDS_MAX="${PC_SECONDS_MAX:-4}"
PC_SEED="${PC_SEED:-$(date +%s)}"
PC_SCENARIOS="${PC_SCENARIOS:-healthy rebuild}"
PC_DIR="${PC_DIR:-/var/tmp/raidkm-pc}"
PC_THREADS="${PC_THREADS:-8}"
PC_SYNC_EVERY="${PC_SYNC_EVERY:-16}"
PC_M=$(rk_m_of "$PC_LAYOUT")
PC_N=$((PC_K + PC_M))
if [ -n "${PC_DCL:-}" ]; then	# PC_DCL="N G SC": declustered pool
	read -r PC_N PC_DCL_G PC_DCL_SC <<< "$PC_DCL"
	PC_LAYOUT="dcl${PC_M} N=$PC_N g=$PC_DCL_G s=$PC_DCL_SC"
	PC_K=$((PC_DCL_G - PC_M))
fi
PC_PPL=0; [[ "${PC_CREATE_EXTRA:-}" == *ppl* ]] && PC_PPL=1
PC_WRITEHOLE=0
PC_REFUSED=0
PC_FORCED=0
PC_FORCE_DIRTY="${PC_FORCE_DIRTY:-1}"
PC_SNAP="${PC_SNAP:-0}"
PC_SNAP_PCT="${PC_SNAP_PCT:-50}"
PC_SNAP_EVERY="${PC_SNAP_EVERY:-1}"
SDD=/sys/module/md_mod/parameters/start_dirty_degraded
PC_DISCARD="${PC_DISCARD:-0}"
PC_DISCARD_ROWS="${PC_DISCARD_ROWS:-4}"
PC_DISCARD_MEMBERS="${PC_DISCARD_MEMBERS:-1}"
PC_CSUM_NEG="${PC_CSUM_NEG:-0}"
PC_CSUM=0; [[ "${PC_CREATE_EXTRA:-}" == *--checksum* ]] && PC_CSUM=1
PC_CSUM_MM=0	# csum mismatches in all-members checks (failures)
PC_CSUM_MM_WH=0	# ... in forced / degraded checks (reported only)
PC_BB=0		# bad-block ranges after all-members checks (failures)
PC_BB_WH=0	# ... after forced starts (reported only)
# data chunks per row: k, or ngroups x k on a declustered pool
PC_ROWCOLS=$PC_K
[ -n "${PC_DCL:-}" ] && PC_ROWCOLS=$(( (PC_N - PC_DCL_SC) / PC_DCL_G * PC_K ))
if [ "$PC_DISCARD" != 0 ] && [ "$PC_DISCARD_MEMBERS" != 1 ] && [ "$PC_SNAP" != 1 ] &&
   [[ "${PC_CREATE_EXTRA:-}" != *--row-map* ]]; then
	echo "PC_DISCARD with PC_DISCARD_MEMBERS=0 needs the row map: without it md takes no discards"; exit 2
fi
if [ "$PC_DISCARD" != 0 ] && [ "$PC_PPL" = 1 ]; then
	# a replayed cut can hold a row's discard on some members and not on
	# others; a degraded read of it is then garbage, which PPL does not excuse
	echo "PC_DISCARD: not with PPL (a torn discard is not a write PPL covers)"; exit 2
fi
if [ "$PC_CSUM_NEG" = 1 ] && { [ "$PC_CSUM" != 1 ] || [ "$PC_DISCARD" = 0 ] || [ "$PC_DISCARD_MEMBERS" != 1 ]; }; then
	echo "PC_CSUM_NEG needs --checksum, PC_DISCARD and PC_DISCARD_MEMBERS=1 (else no CRC is left stale)"; exit 2
fi

command -v python3 >/dev/null || rk_skip "python3 missing"
# The log target: dm-log-writes-ord, built from tools/dm-log-writes-ord for the
# running kernel every run (in $PC_DIR: the tools tree may not be writable),
# and loaded unless the module loaded already is this very build (srcversion).
# A host that cannot build or load it FAILS the suite: a skip would quietly
# drop the power-cut matrix from a gate.  PC_LW_STOCK=1 runs on the stock one.
PC_LW_STOCK="${PC_LW_STOCK:-0}"
if [ "$PC_LW_STOCK" = 1 ]; then
	LW_TARGET=log-writes
	sudo modprobe dm-log-writes 2>/dev/null || rk_skip "no dm-log-writes module"
	echo "PC_LW_STOCK=1: stock dm-log-writes, whose logs can swap two writes to one sector"
else
	LW_TARGET=log-writes-ord
	lwsrc="$RK_LIB_DIR/dm-log-writes-ord"
	lwbuild="${PC_DIR:-/var/tmp/raidkm-pc}/dm-log-writes-ord"
	lwfail() { echo "FAIL: dm-log-writes-ord: $1 (PC_LW_STOCK=1 runs on the stock target)"; exit 1; }
	[ -f "$lwsrc/dm-log-writes-ord.c" ] || lwfail "no $lwsrc"
	sudo rm -rf "$lwbuild"; sudo mkdir -p "$lwbuild"
	sudo cp "$lwsrc"/dm-log-writes-ord.c "$lwsrc"/Kbuild "$lwsrc"/Makefile "$lwbuild"/
	sudo make -C "$lwbuild" >/dev/null 2>"$lwbuild/build.err" ||
		lwfail "build failed (kernel headers for $(uname -r)?): $(tail -3 "$lwbuild/build.err")"
	lwsv=$(modinfo -F srcversion "$lwbuild/dm-log-writes-ord.ko")
	if [ "$(cat /sys/module/dm_log_writes_ord/srcversion 2>/dev/null)" != "$lwsv" ]; then
		if [ -d /sys/module/dm_log_writes_ord ]; then
			sudo rmmod dm_log_writes_ord || lwfail "another build is loaded and in use"
		fi
		sudo modprobe dm-mod 2>/dev/null
		sudo insmod "$lwbuild/dm-log-writes-ord.ko" || lwfail "insmod failed (Secure Boot / lockdown?)"
	fi
fi
rk_load_modules || exit 1
sudo modprobe md_mod 2>/dev/null

# The discard knobs are module parameters: set for this run, put back on exit.
PC_PARAMS=()
pc_param() {	# pc_param <module> <name> <value>
	local f=/sys/module/$1/parameters/$2
	sudo test -w "$f" || { echo "no writable $f"; return 1; }
	PC_PARAMS+=("$f=$(cat "$f")")
	echo "$3" | sudo tee "$f" >/dev/null
}
pc_params_restore() {	# newest first: a parameter set twice gets its original back
	local i e
	for ((i = ${#PC_PARAMS[@]} - 1; i >= 0; i--)); do
		e=${PC_PARAMS[$i]}; echo "${e#*=}" | sudo tee "${e%%=*}" >/dev/null
	done
	PC_PARAMS=()
}
trap pc_params_restore EXIT	# until the full trap below: an early exit restores too
if [ "$PC_DISCARD" != 0 ] && [ "$PC_DISCARD_MEMBERS" = 1 ]; then
	if [ "${PC_LEVEL:-raidkm}" = 6 ]; then
		sudo modprobe raid456
		pc_param raid456 devices_handle_discard_safely Y || exit 2
	else
		pc_param raidkm devices_handle_discard_safely Y || exit 2
	fi
fi
if [ "$PC_CSUM_NEG" = 1 ]; then
	pc_param raidkm csum_test_no_discard_drop Y || exit 2
fi

# A cut is "<journal bytes>:<snapshot log bytes>:<discard log bytes>".
cut_j() { echo "${1%%:*}"; }
cut_s() { local r="${1#*:}"; echo "${r%%:*}"; }
cut_d() { echo "${1##*:}"; }

# The kernel log is followed into a file for the whole run: a check that
# fails reads by the thousand fills the ring buffer, and a marker that has
# scrolled out of it would count as "no mismatch since".
PC_KLOG=
KL_PID=
pc_klog_start() {
	[ "$PC_CSUM" = 1 ] || return 0
	PC_KLOG="$PC_DIR/klog"
	sudo rm -f "$PC_KLOG"
	sudo dmesg -w > >(sudo tee "$PC_KLOG" >/dev/null) 2>/dev/null &
	KL_PID=$!
}
pc_klog_stop() {
	[ -n "$KL_PID" ] || return 0
	# KL_PID is the sudo: end its dmesg (only ours, not another run's)
	sudo pkill -P "$KL_PID" -x dmesg 2>/dev/null; sudo kill "$KL_PID" 2>/dev/null
	wait "$KL_PID" 2>/dev/null; KL_PID=
}
pc_kmsg_mark() {	# pc_kmsg_mark: prints a fresh marker, written to the log
	local mk="raidkm-pc mark $$.$(date +%s%N)" t=0
	echo "$mk" | sudo tee /dev/kmsg >/dev/null
	# wait until the follower has it, or a count could start nowhere
	while [ -n "$PC_KLOG" ] && ! sudo grep -qF "$mk" "$PC_KLOG" && [ $t -lt 50 ]; do
		sleep 0.1; t=$((t + 1))
	done
	echo "$mk"
}
# md's bad-block log: nothing here is ever unreadable, so a range recorded on
# a member is a read the array could not serve -- with --checksum, a block
# whose stored CRC no other copy matched (a stale CRC is the usual cause).
# It persists in the superblock, so later reads of the block fail with EIO
# and no CRC check: count it, or the mismatch that caused it goes unseen.
pc_badblocks() {	# pc_badblocks: recorded bad-block ranges on the running array
	cat /sys/block/"$MDNAME"/md/dev-*/bad_blocks 2>/dev/null | grep -c .
}
pc_csum_mm() {	# pc_csum_mm <marker>: native csum mismatches since it
	local end
	# a closing marker the follower has written: everything before it in
	# the kernel log is in the file, however far the follower lagged
	end=$(pc_kmsg_mark)
	if ! sudo grep -qF "$1" "$PC_KLOG" || ! sudo grep -qF "$end" "$PC_KLOG"; then
		echo "marker-lost"; return
	fi
	sudo sed -n "/$1/,/$end/p" "$PC_KLOG" | grep -c "native csum mismatch"
}

lw_name() { echo "rkpc-lw$1"; }

pc_losetup() {	# pc_losetup <file> -> prints the loop device
	sudo losetup -f --show "$1"
}

# Detach every loop device backed by a file under <dir>.  (By backing file,
# not a list: pc_losetup runs in command substitutions.)
pc_detach_loops() {	# pc_detach_loops <dir>
	local l
	for l in $(sudo losetup -l -n -O NAME,BACK-FILE | awk -v d="$1/" 'index($2, d) == 1 {print $1}'); do
		sudo losetup -d "$l" 2>/dev/null
	done
}

pc_detach_all() {
	local i
	rk_stop
	for i in $(seq 0 $((PC_N - 1))); do
		sudo dmsetup remove "$(lw_name "$i")" 2>/dev/null
	done
	pc_detach_loops "$PC_DIR"
}
trap 'pc_kill_workload; pc_detach_all; pc_params_restore; pc_klog_stop' EXIT

WL_PID=
SN_PID=
pc_kill_workload() {
	if [ -n "$SN_PID" ]; then
		kill -TERM "$SN_PID" 2>/dev/null
		wait "$SN_PID" 2>/dev/null
		SN_PID=
	fi
	[ -n "$WL_PID" ] || return 0
	sudo kill -TERM "$WL_PID" 2>/dev/null
	wait "$WL_PID" 2>/dev/null
	WL_PID=
}

# ---- PC_SNAP: snapshots beside the workload, and their oracle ----
pc_snap() { sudo "$MDADM" --snapshot "$MD" "$@"; }
pc_snap_dev() {	# the device of snapshot <name>, or nothing
	pc_snap --list "$1" 2>/dev/null | grep -o 'dev=[^ ]*' | cut -d= -f2
}
pc_snap_md5() {	# pc_snap_md5 <name>: waits for udev's node
	local d t=0
	while :; do
		d=$(pc_snap_dev "$1")
		[ -n "$d" ] && [ "$d" != - ] && [ -b "$d" ] && break
		[ $t -ge 50 ] && { echo nodev; return; }
		sleep 0.2; t=$((t + 1))
	done
	sudo dd if="$d" bs=1M iflag=direct status=none | md5sum | cut -c1-32
}
# the loop: "create <n> <md5>" once create returned and the md5 is read,
# "destroy <n>" before a destroy is tried
pc_snap_loop() {
	local n=0 live=() h
	trap 'exit 0' TERM
	while :; do
		sleep "$PC_SNAP_EVERY"
		n=$((n + 1))
		pc_snap --create "p$n" >/dev/null 2>&1 || continue
		h=$(pc_snap_md5 "p$n")
		echo "create p$n $h" | sudo tee -a "$PC_DIR/run/snaps" >/dev/null; sync "$PC_DIR/run/snaps"
		live+=("p$n")
		if [ ${#live[@]} -ge 4 ]; then	# keep a few; drop one, not always the oldest
			local i=$(( RANDOM % ${#live[@]} ))
			echo "destroy ${live[$i]}" | sudo tee -a "$PC_DIR/run/snaps" >/dev/null; sync "$PC_DIR/run/snaps"
			pc_snap --destroy "${live[$i]}" >/dev/null 2>&1
			live=("${live[@]:0:$i}" "${live[@]:$((i + 1))}")
		fi
	done
}
# judge the snapshots of a replayed, running array against the log up to
# <bytes> (its length at the cut); 0 = all good
pc_snap_verify() {	# pc_snap_verify <bytes> <label>
	local bad=0 op name h got n=0
	declare -A want gone
	while read -r op name h; do
		case "$op" in
		create)  want[$name]=$h ;;
		destroy) gone[$name]=1 ;;
		esac
	done < <(head -c "$1" "$PC_DIR/run/snaps" 2>/dev/null)
	for name in "${!want[@]}"; do
		got=$(pc_snap_md5 "$name")
		if [ "$got" = nodev ]; then
			[ -n "${gone[$name]:-}" ] && continue
			echo "      snap $name: missing (create returned before the cut)"
			bad=1
		elif [ "$got" != "${want[$name]}" ]; then
			echo "      snap $name: md5 $got, recorded ${want[$name]}"
			bad=1
		else
			n=$((n + 1))
		fi
	done
	echo "      snapshots: $n checked of ${#want[@]} recorded, $(pc_snap --list 2>/dev/null | wc -l) present"
	return $bad
}

# Fresh zeroed member + log files, log-writes devices over them.
pc_setup_members() {
	local i data log sz
	sudo rm -rf "$PC_DIR/run"; sudo mkdir -p "$PC_DIR/run"
	sz=$((PC_MEMBER_MB * 1024 * 1024))
	LW_DEVS=()
	for i in $(seq 0 $((PC_N - 1))); do
		sudo truncate -s "$sz" "$PC_DIR/run/m$i"
		sudo truncate -s 4G "$PC_DIR/run/log$i"
		data=$(pc_losetup "$PC_DIR/run/m$i") || return 1
		log=$(pc_losetup "$PC_DIR/run/log$i") || return 1
		sudo dd if=/dev/zero of="$log" bs=4k count=1 status=none
		echo "0 $((sz / 512)) $LW_TARGET $data $log" |
			sudo dmsetup create "$(lw_name "$i")" || return 1
		LW_DEVS+=("/dev/mapper/$(lw_name "$i")")
		# member discards need a backing filesystem that punches holes:
		# neither log target makes up discards a member cannot take
		if [ "$PC_DISCARD" != 0 ] && [ "$PC_DISCARD_MEMBERS" = 1 ] &&
		   [ "$(cat "/sys/block/$(basename "$(readlink -f "${LW_DEVS[-1]}")")/queue/discard_max_bytes")" = 0 ]; then
			echo "member $i takes no discards (PC_DIR $PC_DIR: no hole punching?)" >&2
			return 1
		fi
	done
}

pc_create() {
	rk_stop
	local m place
	m=$PC_M
	[ "${PC_LAYOUT: -1}" = r ] && place=rotating || place=parity-last
	# --assume-clean: the members are all zero, and zero parity is the right
	# parity of zero data, so no resync has to go through the logs.  (The row
	# map that snapshots need refuses it, and needs no initial sync anyway.)
	local clean=--assume-clean snapopt=
	[ "$PC_SNAP" = 1 ] && { clean=; snapopt=--snapshots=$PC_SNAP_PCT; }
	[[ "${PC_CREATE_EXTRA:-}" == *--row-map* ]] && clean=
	local lvl=(--level=raidkm --parity-count="$m" --layout="$place")
	# PC_LEVEL=6: the matched control, stock md raid6 (raid456) -- run it
	# before calling any raidkm result "md-inherited".
	[ "${PC_LEVEL:-raidkm}" = 6 ] && lvl=(--level=6)
	[ -n "${PC_DCL:-}" ] && lvl=(--level=raidkm --parity-count="$m" --layout=declustered
		--group-width="$PC_DCL_G" --spare-columns="$PC_DCL_SC")
	sudo "$MDADM" --create "$MD" "${lvl[@]}" --raid-devices="$PC_N" --chunk="$CHUNK_KB" \
		$clean $snapopt ${PC_CREATE_EXTRA:-} "${LW_DEVS[@]}" --run --force \
		>/dev/null 2>&1 || return 1
	rk_wait_idle
}

# The cut: see the header.  Echoes the lengths of the journal, the snapshot
# log and the discard log at the cut (cut_j, cut_s, cut_d).
pc_cut() {	# pc_cut <name>
	local d len
	for d in "${LW_DEVS[@]}"; do sudo dmsetup suspend "$d" || return 1; done
	len="$(stat -c %s "$PC_DIR/run/journal"):$(stat -c %s "$PC_DIR/run/snaps"):$(stat -c %s "$PC_DIR/run/dlog")"
	for d in "${LW_DEVS[@]}"; do sudo dmsetup message "$d" 0 mark "$1" || return 1; done
	for d in "${LW_DEVS[@]}"; do sudo dmsetup resume "$d" || return 1; done
	# a log that stopped (log device full, an allocation failed) has a hole:
	# its replays would judge a state that never existed
	for d in "${LW_DEVS[@]}"; do
		sudo dmsetup status "$d" | grep -q logging_disabled &&
			{ echo "$d: logging stopped (log full or ENOMEM)" >&2; return 1; }
	done
	echo "$len"
}

# Replay cut <mark> in <mode> onto fresh copies; echoes the copy devices.
pc_replay() {	# pc_replay <mark> <mode> <seed>
	local i f devs=()
	sudo mkdir -p "$PC_DIR/copy"
	for i in $(seq 0 $((PC_N - 1))); do
		f="$PC_DIR/copy/m$i"
		sudo rm -f "$f"; sudo truncate -s $((PC_MEMBER_MB * 1024 * 1024)) "$f"
		sudo python3 "$PCIO" replay --log "$PC_DIR/run/log$i" --dev "$f" \
			--mark "$1" --mode "$2" --seed "$(($3 + i))" >/dev/null || return 1
		devs+=("$(pc_losetup "$f")") || return 1
	done
	echo "${devs[@]}"
}

pc_verify() {	# pc_verify <cut> <label>
	local out rc
	out=$(sudo python3 "$PCIO" verify --dev "$MD" --blocks "$PC_BLOCKS" \
		--journal "$PC_DIR/run/journal" --journal-bytes "$(cut_j "$1")" \
		--dlog "$PC_DIR/run/dlog" --dlog-bytes "$(cut_d "$1")" \
		--gens "$PC_DIR/run/gens" 2>&1); rc=$?
	echo "$out" | sed 's/^/      /' | tail -8
	return $rc
}

# PC_SNAP: the snapshot oracle, a failure in any mode (no write hole)
pc_snap_check() {	# pc_snap_check <cut> <tag>
	[ "$PC_SNAP" = 1 ] || return 0
	if pc_snap_verify "$(cut_s "$1")" "$2"; then
		rk_pass "$2: snapshots intact"
	else
		rk_fail "$2: SNAPSHOT oracle failed"
		pc_keep "$2-snap"
	fi
}

pc_assemble_degraded() {	# pc_assemble_degraded <dev...>: 0 = running
	sudo "$MDADM" --assemble "$MD" --run "$@" >/dev/null 2>&1 &&
	  grep -q "^$MDNAME : active" /proc/mdstat
}

pc_keep() {	# pc_keep <label>
	[ "${PC_KEEP:-0}" = 1 ] || return 0
	local k="$PC_DIR/fail-$1"
	sudo mkdir -p "$k"; sudo cp -a "$PC_DIR/run/." "$PC_DIR/copy/." "$k/" 2>/dev/null
	[ -n "$PC_KLOG" ] && sudo cp "$PC_KLOG" "$k/klog" 2>/dev/null
	rk_log "kept $k"
}

pc_detach_copies() {
	rk_stop
	pc_detach_loops "$PC_DIR/copy"
}

# Judge one replayed cut.
pc_check_cut() {	# pc_check_cut <tag> <mark> <mode> <cut> <seed>
	local tag="$1" devs miss rc mm i sub mk n
	devs=($(pc_replay "$2" "$3" "$5")) || { rk_fail "$tag: replay"; return; }
	[ "$PC_CSUM" = 1 ] && mk=$(pc_kmsg_mark)
	if ! pc_assemble_degraded "${devs[@]}"; then
		# A cut during a rebuild: the rebuilding member is not in sync, so
		# this is a dirty degraded array too -- md refuses it (safe).
		PC_REFUSED=$((PC_REFUSED + 1))
		rk_pass "$tag: all members: md refused the dirty start (safe)"
		[ "$PC_FORCE_DIRTY" = 1 ] || { pc_detach_copies; return; }
		rk_stop
		echo 1 | sudo tee "$SDD" >/dev/null
		pc_assemble_degraded "${devs[@]}"; rc=$?
		echo 0 | sudo tee "$SDD" >/dev/null
		if [ "$rc" != 0 ]; then
			rk_fail "$tag: all members: forced start failed"
			pc_keep "$tag"; pc_detach_copies; return
		fi
		PC_FORCED=$((PC_FORCED + 1))
		tag="$tag (forced dirty)"
	fi
	rc=0
	pc_verify "$4" || rc=1
	pc_snap_check "$4" "$tag"
	rk_wait_idle
	mm=$(rk_scrub)
	pc_verify "$4" || rc=1
	if [ "$rc" = 0 ] && [ "${mm:-x}" = 0 ]; then
		rk_pass "$tag: all members, oracle + scrub clean"
	elif [[ "$tag" == *forced* ]] && [ "$PC_PPL" = 0 ]; then
		# md refused this start because the array was degraded at the cut
		# (a member mid-rebuild): the same write hole as a lost member.
		PC_WRITEHOLE=$((PC_WRITEHOLE + 1))
		rk_log "WRITE-HOLE $tag: all members, degraded at the cut (no PPL: not counted; oracle rc $rc, mismatch_cnt ${mm:-?})"
	else
		rk_fail "$tag: all members (oracle rc $rc, mismatch_cnt ${mm:-?})"
		pc_keep "$tag"
	fi
	if [ "$PC_CSUM" = 1 ]; then
		n=$(pc_csum_mm "$mk")
		if [ "$n" = marker-lost ]; then
			rk_fail "$tag: csum check: marker not in the kernel log"
		elif [ "$n" = 0 ]; then
			rk_pass "$tag: all members, no csum mismatch"
		elif [[ "$tag" == *forced* ]]; then
			PC_CSUM_MM_WH=$((PC_CSUM_MM_WH + n))
			rk_log "$tag: all members, $n csum mismatch(es) (degraded at the cut: reported only)"
		else
			PC_CSUM_MM=$((PC_CSUM_MM + n))
			rk_fail "$tag: all members, $n csum mismatch(es): stale or missing CRCs"
			pc_keep "$tag-csum"
		fi
	fi
	n=$(pc_badblocks)
	if [ "$n" = 0 ]; then
		rk_pass "$tag: all members, bad-block lists empty"
	elif [[ "$tag" == *forced* ]]; then
		PC_BB_WH=$((PC_BB_WH + n))
		rk_log "$tag: all members, $n bad-block range(s) (degraded at the cut: reported only)"
	else
		PC_BB=$((PC_BB + n))
		rk_fail "$tag: all members, $n bad-block range(s): md lost blocks it could not read or rebuild"
		pc_keep "$tag-bb"
	fi
	pc_detach_copies
	[ "$PC_DEGRADED" = 1 ] || return
	[ "$PC_CSUM" = 1 ] && mk=$(pc_kmsg_mark)
	# The write hole: the same crash image, one member lost with it.
	tag="$1"
	devs=($(pc_replay "$2" "$3" "$5")) || { rk_fail "$tag: replay"; return; }
	miss=$(( RANDOM % PC_N ))
	sub=(); for i in "${!devs[@]}"; do [ "$i" = "$miss" ] || sub+=("${devs[$i]}"); done
	if ! pc_assemble_degraded "${sub[@]}"; then
		PC_REFUSED=$((PC_REFUSED + 1))
		rk_pass "$tag: without member $miss: md refused the dirty degraded start (safe)"
		[ "$PC_FORCE_DIRTY" = 1 ] || { pc_detach_copies; return; }
		# What an operator forcing it gets: md_mod.start_dirty_degraded=1.
		rk_stop
		echo 1 | sudo tee "$SDD" >/dev/null
		pc_assemble_degraded "${sub[@]}"; i=$?
		echo 0 | sudo tee "$SDD" >/dev/null
		[ "$i" = 0 ] || { rk_fail "$tag: forced dirty degraded start failed"; pc_detach_copies; return; }
		PC_FORCED=$((PC_FORCED + 1))
		tag="$tag (forced dirty)"
	fi
	pc_snap_check "$4" "$tag: without member $miss"
	if pc_verify "$4"; then
		rk_pass "$tag: without member $miss, oracle clean"
	elif [ "$PC_PPL" = 1 ]; then
		rk_fail "$tag: without member $miss, oracle FAILED with PPL"
		pc_keep "$tag-degraded"
	else
		PC_WRITEHOLE=$((PC_WRITEHOLE + 1))
		rk_log "WRITE-HOLE $tag: without member $miss (no PPL: md-inherited, not counted)"
	fi
	if [ "$PC_CSUM" = 1 ]; then
		n=$(pc_csum_mm "$mk")
		[ "$n" = marker-lost ] && n=0
		PC_CSUM_MM_WH=$((PC_CSUM_MM_WH + n))
		[ "$n" = 0 ] || rk_log "$tag: without member $miss, $n csum mismatch(es) (reported only)"
	fi
	pc_detach_copies
}

pc_run() {	# pc_run <scenario> <iter>
	local sc="$1" it="$2" seed cut jl marks=() jlens=() i mode tag
	seed=$((PC_SEED + it * 1000))
	RANDOM=$seed
	pc_detach_all
	pc_setup_members || { rk_fail "$sc#$it: member setup"; return; }
	pc_create || { rk_fail "$sc#$it: create"; return; }
	# declustered capacity is not k x member: size the workload from the array
	PC_BLOCKS="${PC_BLOCKS_SET:-$(( $(sudo blockdev --getsize64 "$MD") / 4096 * 3 / 4 ))}"
	[ "$PC_SNAP" = 1 ] && [ -z "$PC_BLOCKS_SET" ] &&
		PC_BLOCKS=$(( $(sudo blockdev --getsize64 "$MD") / 4096 / 16 ))
	sudo rm -f "$PC_DIR/run/journal" "$PC_DIR/run/gens" "$PC_DIR/run/snaps" "$PC_DIR/run/dlog"
	sudo touch "$PC_DIR/run/journal" "$PC_DIR/run/snaps" "$PC_DIR/run/dlog"
	local dopt=()
	if [ "$PC_DISCARD" != 0 ]; then
		dopt=(--discard "$PC_DISCARD" --discard-rows "$PC_DISCARD_ROWS"
		      --discard-align $((CHUNK_KB * PC_ROWCOLS / 4)) --dlog "$PC_DIR/run/dlog")
		rk_log "$sc#$it discards: md discard_max_bytes $(cat /sys/block/$MDNAME/queue/discard_max_bytes)$(grep -s member_discard /sys/block/$MDNAME/md/rk_rowmap | sed 's/^/, row map /')"
	fi
	if [ "$sc" = rebuild ]; then
		rk_throttle 2000
		rk_fail_disks "${LW_DEVS[1]}"; rk_remove_disks "${LW_DEVS[1]}"
		rk_add_disks "${LW_DEVS[1]}"
		rk_wait_recovery_active || rk_log "$sc#$it: recovery not seen running"
	fi
	if [ "$sc" = populate ]; then
		# declustered: the failure arms population into the spare columns
		# (rk_dcl_auto), throttled so the cuts land inside it
		echo 1 | sudo tee "/sys/block/$MDNAME/md/rk_dcl_auto" >/dev/null
		rk_throttle 2000
		rk_fail_disks "${LW_DEVS[1]}"
		sleep 1
		rk_log "$sc#$it: $(rk_pop_show | head -1)"
	fi
	local lmk=
	[ "$PC_CSUM" = 1 ] && lmk=$(pc_kmsg_mark)
	sudo python3 "$PCIO" run --dev "$MD" --blocks "$PC_BLOCKS" \
		--threads "$PC_THREADS" --sync-every "$PC_SYNC_EVERY" --seed "$seed" \
		--journal "$PC_DIR/run/journal" --gens "$PC_DIR/run/gens" "${dopt[@]}" \
		> "$PC_DIR/run/workload.log" 2>&1 &
	WL_PID=$!
	if [ "$PC_SNAP" = 1 ]; then
		pc_snap_loop &
		SN_PID=$!
	fi
	for cut in $(seq 1 "$PC_CUTS"); do
		sleep "$(awk -v r=$RANDOM -v m="$PC_SECONDS_MAX" 'BEGIN{printf "%.2f", 0.2 + (r/32768)*m}')"
		jl=$(pc_cut "cut$cut") || { rk_fail "$sc#$it: cut $cut"; pc_kill_workload; return; }
		marks+=("cut$cut"); jlens+=("$jl")
	done
	pc_kill_workload
	rk_log "$sc#$it seed $seed: $(tail -1 "$PC_DIR/run/workload.log"), rebuild: $(grep -o 'recovery = [0-9.]*%' /proc/mdstat || echo none)"
	[ "$PC_SNAP" = 1 ] && rk_log "$sc#$it snapshots: $(grep -c '^create' "$PC_DIR/run/snaps") created, $(grep -c '^destroy' "$PC_DIR/run/snaps") destroyed; $(grep -E 'cow_|commits|checkpoints' /sys/block/$MDNAME/md/rk_snap 2>/dev/null | tr '\n' ' ')"
	rk_unthrottle
	grep -q VERIFY-FAIL "$PC_DIR/run/workload.log" &&
		rk_fail "$sc#$it: the live workload saw an I/O error"
	[ "$PC_DISCARD" != 0 ] && grep -q "discards 0 " "$PC_DIR/run/workload.log" &&
		rk_fail "$sc#$it: PC_DISCARD set but no discard issued (no whole row in a thread's slice?)"
	# The live array: no crash, no rot -- a CRC mismatch is a stale CRC even
	# when a heal from parity hid it from the workload (rate limited: the
	# count is a lower bound), and a recorded bad block is a failed read.
	local lbb n
	lbb=$(pc_badblocks)
	if [ "$lbb" = 0 ]; then
		rk_pass "$sc#$it: live array, bad-block lists empty"
	else
		PC_BB=$((PC_BB + lbb))
		rk_fail "$sc#$it: live array, $lbb bad-block range(s): reads it could not serve"
	fi
	if [ "$PC_CSUM" = 1 ]; then
		n=$(pc_csum_mm "$lmk")
		if [ "$n" = 0 ]; then
			rk_pass "$sc#$it: live run, no csum mismatch"
		else
			[ "$n" = marker-lost ] || PC_CSUM_MM=$((PC_CSUM_MM + n))
			rk_fail "$sc#$it: live run, csum mismatch(es): $n (at least)"
		fi
	fi
	# Finish the logs: stop md, remove the log-writes devices (flushes them).
	pc_detach_all
	# Negative control: the oracle must SEE a lost durable write.  Cut 1's
	# image judged against a later cut's journal claims writes the image
	# cannot hold -- verify has to fail with "stale"/"zero", or a green run
	# means nothing.
	if [ "${#marks[@]}" -ge 2 ] && [ "$(cut_j "${jlens[-1]}")" -gt "$(cut_j "${jlens[0]}")" ]; then
		local cdevs cout
		cdevs=($(pc_replay "${marks[0]}" mark "$seed"))
		pc_assemble_degraded "${cdevs[@]}" || {
			rk_stop; echo 1 | sudo tee "$SDD" >/dev/null
			pc_assemble_degraded "${cdevs[@]}"
			echo 0 | sudo tee "$SDD" >/dev/null; }
		if grep -q "^$MDNAME : active" /proc/mdstat; then
			cout=$(sudo python3 "$PCIO" verify --dev "$MD" --blocks "$PC_BLOCKS" \
				--journal "$PC_DIR/run/journal" --journal-bytes "$(cut_j "${jlens[-1]}")" \
				--dlog "$PC_DIR/run/dlog" --dlog-bytes "$(cut_d "${jlens[-1]}")" \
				--gens "$PC_DIR/run/gens" --show 0 2>&1)
			# unreadable: blocks the cut-1 image cannot serve (the
			# CSUM_NEG control's arrays) also fail the oracle.
			if [[ "$cout" == *"verify FAIL"*stale* || "$cout" == *"verify FAIL"*zero* ||
			      "$cout" == *"verify FAIL"*unreadable* ]]; then
				rk_pass "$sc#$it: control: oracle catches lost durable writes (${cout#verify FAIL: })"
			else
				rk_fail "$sc#$it: control: oracle MISSED lost durable writes: $cout"
			fi
			# the same for snapshots: the later cut's log names snapshots
			# cut 1's image cannot have
			if [ "$PC_SNAP" = 1 ]; then
				local c1 cl
				c1=$(head -c "$(cut_s "${jlens[0]}")" "$PC_DIR/run/snaps" | grep -c '^create')
				cl=$(head -c "$(cut_s "${jlens[-1]}")" "$PC_DIR/run/snaps" | grep -c '^create')
				if [ "$cl" -gt "$c1" ]; then
					if pc_snap_verify "$(cut_s "${jlens[-1]}")" control >/dev/null; then
						rk_fail "$sc#$it: control: snapshot oracle MISSED $((cl - c1)) snapshot(s) created after cut 1"
					else
						rk_pass "$sc#$it: control: snapshot oracle catches snapshots the image cannot have"
					fi
				else
					rk_log "$sc#$it: control: no snapshot created between the cuts, snapshot control skipped"
				fi
			fi
		else
			rk_fail "$sc#$it: control: assemble"
		fi
		pc_detach_copies
	fi
	for i in "${!marks[@]}"; do
		for mode in $PC_MODES; do
			tag="$sc#$it/${marks[$i]}/$mode"
			pc_check_cut "$tag" "${marks[$i]}" "$mode" "${jlens[$i]}" "$((seed + i * 17))"
		done
	done
}

[ "${PC_LEVEL:-raidkm}" = 6 ] && { PC_M=2; PC_N=$((PC_K + 2)); PC_LAYOUT="stock raid6"; sudo modprobe raid456; }
echo "==== raidkm power-cut: $PC_K+$PC_M ($PC_LAYOUT) chunk ${CHUNK_KB}K, ${PC_MEMBER_MB} MiB members, seed $PC_SEED ${PC_CREATE_EXTRA:+($PC_CREATE_EXTRA)}$([ "$PC_DISCARD" != 0 ] && echo " discards $PC_DISCARD (members $PC_DISCARD_MEMBERS)")$([ "$PC_CSUM_NEG" = 1 ] && echo " CSUM NEG CONTROL") ===="
sudo mkdir -p "$PC_DIR"
PC_BLOCKS_SET="${PC_BLOCKS:-}"
rk_dmesg_clear
pc_klog_start
for sc in $PC_SCENARIOS; do
	for it in $(seq 1 "$PC_ITER"); do
		echo "--- $sc run $it"
		pc_run "$sc" "$it"
	done
done
pc_detach_all
rk_dmesg_clean && rk_pass "no kernel WARN/BUG" || rk_fail "kernel WARN/BUG in dmesg"
echo "  dirty degraded starts refused (safe): $PC_REFUSED, then forced: $PC_FORCED; write-hole losses without PPL (not counted): $PC_WRITEHOLE"
[ "$PC_CSUM" = 1 ] && echo "  csum mismatches: all members $PC_CSUM_MM (failures), forced/degraded $PC_CSUM_MM_WH (reported only)"
echo "  bad-block ranges: all members $PC_BB (failures), forced $PC_BB_WH (reported only)"
if [ "$PC_CSUM_NEG" = 1 ]; then	# the control has to catch the CRCs it left stale
	[ $((PC_CSUM_MM + PC_BB)) -gt 0 ] &&
		rk_pass "CSUM NEG control: stale CRCs caught ($PC_CSUM_MM mismatches, $PC_BB bad-block ranges)" ||
		rk_fail "CSUM NEG control MISSED: no mismatch and no bad block with the CRC drop off"
fi
rk_summary
