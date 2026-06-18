#!/bin/bash
# raidkm-test-crash.sh — power-loss-mid-reshape harness via dm-flakey.
#
# OPT-IN reliability test, NOT part of the default raidkm-test.sh runner.
# Probabilistic; expect a non-zero failure rate.  Read the model section.
#
# Each member of the array sits on top of:
#       file → loop --direct-io → dm-flakey → md raidkm
# "Power loss" = atomically reload every flakey's table to drop_writes, so any
# write the kernel believed completed but that hadn't reached the backing file
# silently vanishes (the bio returns success, no bytes on platter).  Reload
# back to passthrough and the file now reflects "what was on disk at the
# moment of crash."  Then we --assemble, let the reshape resume, and verify
# data byte-for-byte + scrub mismatch_cnt.
#
# *** Test model is more aggressive than reality. ***
# dm-flakey drops EVERY write, including those tagged FUA/FLUSH that md uses
# for superblock updates.  Real drives honor FUA, so on actual hardware the
# inter-disk superblock landing is more atomic than this test models.  A
# non-zero failure rate here does NOT necessarily mean a corresponding rate
# in production — it characterizes the array's resilience under the worst-
# case write-cache-disabled (or non-battery-backed cache + power-loss) model.
#
# Two different crash models, because the two grows work differently:
#
#   * rotating --add-parity is now an OFFLINE, userspace, windowed relocation
#     (mdadm stops the array, then copies each row's data from its old rotating
#     slots to its new ones, <=64MiB at a time, through --backup-file; then
#     recreates at m+1).  There is no kernel reshape and no reshape_position.
#     "Power loss" here = the relocation PROCESS dies mid-flight (the array is
#     already stopped).  Recovery is deterministic: re-running the SAME
#     `--grow --add-parity --backup-file=<bf>` command detects the sidecar
#     state file <bf>.raidkm-state, rolls the single in-flight batch back from
#     the backup file (committed via tmp+rename BEFORE the batch is
#     overwritten), relocates forward from the recorded frontier, and recreates.
#     The state + backup files live on the host fs, so they survive the member
#     "power loss"; dropping member writes at the crash instant only erases the
#     in-flight batch, which the rollback restores.  (Out of scope, same as any
#     stack: if fsync LIES and an already-synced batch is lost to power loss,
#     no userspace tool can recover it.)
#
#   * --add-data is still an ONLINE kernel reshape, so it keeps the classic
#     model below: crash mid-reshape, --assemble, let the kernel resume.
#
# Known fragility class the ONLINE (--add-data) path exposes (md inheritance,
# not raidkm): when the "crash" hits during a reshape superblock update, some
# member disks' SBs may land at the new reshape_position while others stay at
# the old one.  On --assemble, the kernel picks the highest and kicks the stale
# disk(s).  Reshape continues degraded with EC reconstruction — internally
# consistent (scrub clean) but byte-different from what we wrote.  Bigger
# data_offset shifts narrow the window but don't close it.  This does NOT apply
# to the offline add-parity path (no kernel reshape, no multi-device SB race).
#
# Configurable:
#   CRASH_NDEVS        members + spare to allocate         (default 8)
#   CRASH_DISK_SIZE_MB backing file size per device, MiB   (default 128)
#   CRASH_BACK         dir for backing files               (default /var/tmp/raidkm-crash)
#   CRASH_AT_POS       crash after reshape_position > N    (default 4096 sectors)
#   CRASH_ITERS        iterations of each scenario         (default 3)
#   SZ                 MiB written before crash            (default 24)
#   MDADM,MD,...                                            (see raidkm-test-lib.sh)
#
# Usage:   sudo bash tools/raidkm-test-crash.sh
#          sudo CRASH_ITERS=20 bash tools/raidkm-test-crash.sh
#
# Scenarios implemented:
#   - baseline (no-crash) clean grow     — sanity check that the stack carries
#                                          data correctly when no crash happens
#   - crash_mid_add_parity               — kill the OFFLINE windowed relocation
#                                          mid-flight, then resume by re-running
#                                          the same --grow --add-parity command
#                                          (rollback-from-backup + finish)
#   - crash_mid_grow_data                — power loss during ONLINE rotating
#                                          --add-data, then --assemble + resume
#                                          (k grows; readpos > writepos)
# TODO: crash during rebuild, crash during scrub, double-crash idempotency,
#       deliberate-timing (crash right before a checkpoint) vs random-timing.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

CRASH_NDEVS="${CRASH_NDEVS:-8}"
CRASH_DISK_SIZE_MB="${CRASH_DISK_SIZE_MB:-128}"
CRASH_BACK="${CRASH_BACK:-/var/tmp/raidkm-crash}"
CRASH_AT_POS="${CRASH_AT_POS:-4096}"
CRASH_ITERS="${CRASH_ITERS:-3}"
SZ="${SZ:-24}"

CRASH_LOOPS=()
CRASH_FLK=()
CRASH_DEVS=()

# Sweep any leftover state from a previous (interrupted) run, or from a
# teardown that lost a race with udev re-assemble.
crash_global_cleanup() {
	local d l tries
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	sudo "$MDADM" --stop --scan >/dev/null 2>&1
	sudo udevadm settle 2>/dev/null
	for d in $(sudo dmsetup ls 2>/dev/null | awk '$1 ~ /^rkcrash[0-9]+$/ {print $1}'); do
		for tries in 1 2 3 4 5; do
			sudo dmsetup remove "$d" >/dev/null 2>&1 && break
			sudo dmsetup remove --force "$d" >/dev/null 2>&1 && break
			sleep 0.2
		done
	done
	for l in $(sudo losetup -l 2>/dev/null | awk '/raidkm-crash/ {print $1}'); do
		sudo losetup -d "$l" >/dev/null 2>&1
	done
}

# Build N member devices (loop + flakey) from fresh backing files.
crash_setup() {
	local n="${1:-$CRASH_NDEVS}" i loop f flkname sectors
	mkdir -p "$CRASH_BACK"
	# Sweep stale state from a previous iteration that wasn't cleaned up.
	crash_global_cleanup
	for i in $(seq 1 "$n"); do
		f="$CRASH_BACK/disk$i.img"
		# Always start each iteration from a fresh, zeroed backing file so
		# stale superblocks from a previous run can't make assemble pick
		# a doomed reshape.
		sudo rm -f "$f"
		sudo dd if=/dev/zero of="$f" bs=1M count="$CRASH_DISK_SIZE_MB" status=none
		loop=$(sudo losetup --show -f --direct-io=on "$f") || {
			echo "losetup failed for $f" >&2; return 1
		}
		flkname="rkcrash$i"
		sectors=$(sudo blockdev --getsz "$loop")
		# always-up table: up=86400, down=0 → never enters down state.
		echo "0 $sectors flakey $loop 0 86400 0" | sudo dmsetup create "$flkname" || {
			echo "dmsetup create $flkname failed" >&2; return 1
		}
		CRASH_LOOPS+=("$loop")
		CRASH_FLK+=("$flkname")
		CRASH_DEVS+=("/dev/mapper/$flkname")
	done
}

# Flip every flakey into permanent drop_writes mode (the "crash").
crash_now() {
	local i f loop sectors
	for i in "${!CRASH_FLK[@]}"; do
		f="${CRASH_FLK[$i]}"
		loop="${CRASH_LOOPS[$i]}"
		sectors=$(sudo blockdev --getsz "$loop")
		sudo dmsetup suspend "$f"
		echo "0 $sectors flakey $loop 0 0 86400 1 drop_writes" \
			| sudo dmsetup load "$f"
		sudo dmsetup resume "$f"
	done
}

# Flip every flakey back to passthrough (post-crash; writes that were dropped
# stay dropped, future writes hit the file again).
crash_thaw() {
	local i f loop sectors
	for i in "${!CRASH_FLK[@]}"; do
		f="${CRASH_FLK[$i]}"
		loop="${CRASH_LOOPS[$i]}"
		sectors=$(sudo blockdev --getsz "$loop")
		sudo dmsetup suspend "$f"
		echo "0 $sectors flakey $loop 0 86400 0" | sudo dmsetup load "$f"
		sudo dmsetup resume "$f"
	done
}

crash_teardown() {
	local f loop tries
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	sudo "$MDADM" --stop --scan >/dev/null 2>&1
	# udev may try to auto-assemble; settle it before yanking dm-flakey out.
	sudo udevadm settle 2>/dev/null
	for f in "${CRASH_FLK[@]}"; do
		for tries in 1 2 3 4 5 6 7 8; do
			sudo dmsetup remove "$f" >/dev/null 2>&1 && break
			# Try a force remove after a few normal attempts.
			[ "$tries" -ge 4 ] && sudo dmsetup remove --force "$f" >/dev/null 2>&1 && break
			sleep 0.3
		done
	done
	for loop in "${CRASH_LOOPS[@]}"; do
		for tries in 1 2 3; do
			sudo losetup -d "$loop" >/dev/null 2>&1 && break
			sleep 0.2
		done
	done
	CRASH_LOOPS=(); CRASH_FLK=(); CRASH_DEVS=()
}

trap 'crash_teardown' EXIT INT TERM

# Scenario 1: crash during the OFFLINE windowed rotating add-parity relocation.
#
# The grow stops the array and relocates data in userspace through --backup-file
# (sidecar state at <bf>.raidkm-state, each <=64MiB batch's old content committed
# to the backup before it is overwritten).  We launch it in the background, wait
# until the relocation is provably underway (sidecar present + array stopped),
# advance a randomized amount so the crash frontier varies, then POWER LOSS: kill
# the relocation process.  Recovery = re-running the identical command, which
# detects the sidecar, rolls the in-flight batch back from the backup, relocates
# from the frontier, and recreates at m+1.
#
# *** We KILL, we do NOT dm-flakey-drop here. ***  Power loss for an offline
# userspace op = the CPU HALTS: execution stops at some instruction, everything
# fsync'd before is durable, the one in-flight batch is rolled back from the
# (host-fs, survives) backup file.  A `drop_writes` crash is unfaithful here: it
# lets the process keep RUNNING with its writes silently vanishing, so it can
# finish a batch (lost), advance `bf` to the next batch, and strand the lost
# batch beyond the recoverable frontier — a corruption no real power loss can
# produce (the CPU would have stopped).  The write-drop models the ONLINE
# reshape's async SB landing (see crash_mid_grow_data), which the offline path
# does not have.  Members still sit on flakey for harness uniformity.
crash_mid_add_parity() {
	local old_m="${1:-2}" k=3 i
	local new_m=$((old_m + 1))
	local newn=$((k + new_m))
	local tag="crash mid add-parity (offline) m=$old_m->$new_m k=$k"
	local bf="$CRASH_BACK/addparity.backup"

	crash_setup "$newn" || { rk_fail "$tag: setup failed"; return; }
	local base; base="${CRASH_DEVS[*]:0:$((k+old_m))}"
	local add;  add="${CRASH_DEVS[$((newn-1))]}"
	sudo rm -f "$bf" "$bf.raidkm-state" "$bf.tmp"

	if ! rk_create "${old_m}r" $base; then
		rk_fail "$tag: create failed"; crash_teardown; return
	fi
	rk_write "$SZ"
	rk_wait_idle	# clean, idle source before we relocate it

	# Launch the offline windowed grow in the background.
	sudo "$MDADM" --grow "$MD" --add-parity --backup-file="$bf" "$add" \
		>/dev/null 2>&1 &
	local gpid=$!

	# Wait until the relocation is provably underway: the sidecar state file
	# exists and the array has been stopped (mdadm stops it before relocating).
	local underway=0
	for _ in $(seq 1 1000); do
		if [ -e "$bf.raidkm-state" ] && ! grep -q "$MDNAME" /proc/mdstat; then
			underway=1; break
		fi
		kill -0 "$gpid" 2>/dev/null || break	# grow already exited
		sleep 0.02
	done

	if [ "$underway" -ne 1 ]; then
		wait "$gpid" 2>/dev/null
		if [ -e "$bf.raidkm-state" ]; then
			rk_fail "$tag: grow exited leaving state but no array (could not catch reloc)"
		elif grep -q "$MDNAME" /proc/mdstat; then
			rk_wait_idle
			[ "$(rk_geom)" = "[$newn/$newn]" ] && rk_readback "$SZ" \
				&& rk_pass "$tag: completed too fast to interrupt; data intact" \
				|| rk_fail "$tag: fast-completed but geom/data wrong"
		else
			rk_fail "$tag: grow exited with no array and no state"
		fi
		crash_teardown; return
	fi

	# Advance a small randomized amount into the relocation (keep it short so we
	# stay inside the ~1-2s relocation), then POWER LOSS: halt the relocation by
	# killing it (see the function header for why we kill rather than drop).
	sleep "0.$((RANDOM % 5))"
	sudo pkill -9 -x mdadm >/dev/null 2>&1
	wait "$gpid" 2>/dev/null
	sleep 0.1
	local md_after_kill; md_after_kill=$(grep -q "$MDNAME" /proc/mdstat && echo UP || echo down)

	if [ ! -e "$bf.raidkm-state" ]; then
		rk_fail "$tag: no sidecar state after crash (nothing to resume)"
		crash_teardown; return
	fi

	# Make sure no udev auto-assembly is holding the (old-SB) members before we
	# resume on the raw devices.
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	sudo "$MDADM" --stop --scan >/dev/null 2>&1
	sudo udevadm settle 2>/dev/null
	sleep 0.2

	# RESUME: re-run the identical command.  mdadm detects the sidecar, rolls
	# the in-flight batch back from the backup, relocates from the frontier,
	# and recreates at m+1.
	local res_out res_rc
	res_out=$(sudo "$MDADM" --grow "$MD" --add-parity --backup-file="$bf" "$add" 2>&1)
	res_rc=$?
	if [ "$res_rc" -ne 0 ]; then
		rk_fail "$tag: resume failed rc=$res_rc"
		rk_log "$tag: $res_out"
		crash_teardown; return
	fi
	rk_wait_idle

	if [ "$(rk_geom)" != "[$newn/$newn]" ]; then
		rk_fail "$tag: wrong geometry after resume ($(rk_geom), want [$newn/$newn])"
		crash_teardown; return
	fi
	if rk_readback "$SZ"; then
		rk_pass "$tag: data intact across crash + resume"
	else
		rk_fail "$tag: DATA LOST across crash + resume"
		if [ -n "${RK_CRASH_DEBUG:-}" ]; then
			rk_log "DEBUG md-after-kill=$md_after_kill geom=$(rk_geom)"
			rk_log "DEBUG resume: $(echo "$res_out" | grep -E 'rolled back|from row 0|resume complete' | tr '\n' ';')"
			local n=$((SZ * 1024 / CHUNK_KB)) c bad=""
			for c in $(seq 0 $((n - 1))); do
				[ "$(dd if="$RK_TMP/src" bs=${CHUNK_KB}K skip=$c count=1 2>/dev/null | md5sum)" \
				  != "$(dd if="$RK_TMP/rd" bs=${CHUNK_KB}K skip=$c count=1 2>/dev/null | md5sum)" ] \
					&& bad="$bad $c"
			done
			rk_log "DEBUG bad ${CHUNK_KB}K chunks (of $n):$bad"
			# Re-read after a fuller settle: matches now => transient read/resync
			# race; still differs => persistent on-disk corruption.
			rk_wait_idle; sleep 1
			if rk_readback "$SZ"; then
				rk_log "DEBUG re-read MATCHES => TRANSIENT (read/resync race, not on-disk corruption)"
			else
				rk_log "DEBUG re-read STILL DIFFERS => PERSISTENT on-disk corruption"
			fi
		fi
		rk_log "$tag: dmesg tail:"
		sudo dmesg | tail -15 | sed 's/^/      /'
	fi
	local mm; mm=$(rk_scrub)
	[ "$mm" = 0 ] && rk_pass "$tag: scrub clean after resume" \
		      || rk_fail "$tag: scrub mismatch_cnt=$mm after resume"

	# state + backup must be cleaned up by a successful resume.
	[ ! -e "$bf.raidkm-state" ] && [ ! -e "$bf" ] \
		&& rk_pass "$tag: state/backup files cleaned after resume" \
		|| rk_fail "$tag: leftover state/backup files after resume"

	crash_teardown
}

# Scenario 2: power loss during rotating grow-data (--add-data).
#
# Contrast with add-parity: here the data-disk count k changes, so
# new_data_disks > data_disks and readpos > writepos naturally and grows
# as the reshape progresses (free slack, no data_offset shift needed).
# Expectation: data should survive crashes here that the add-parity case
# can't.  A non-zero failure rate would point at the same md-layer multi-
# device SB landing issue (orthogonal to the shift fix).
crash_mid_grow_data() {
	local old_m="${1:-2}" old_k="${2:-3}" pos
	local new_k=$((old_k + 1))
	local oldn=$((old_k + old_m))
	local newn=$((new_k + old_m))
	local tag="crash mid grow-data m=$old_m k=$old_k->$new_k"

	crash_setup "$newn" || { rk_fail "$tag: setup failed"; return; }
	local base; base="${CRASH_DEVS[*]:0:$oldn}"
	local add;  add="${CRASH_DEVS[$((newn-1))]}"

	if ! rk_create "${old_m}r" $base; then
		rk_fail "$tag: create failed"; crash_teardown; return
	fi
	rk_write "$SZ"

	echo 3000 | sudo tee "/sys/block/$MDNAME/md/sync_speed_max" >/dev/null
	if ! sudo "$MDADM" --grow "$MD" --add-data "$add" >/dev/null 2>&1; then
		rk_fail "$tag: --add-data failed"; crash_teardown; return
	fi

	pos=0
	for _ in $(seq 1 400); do
		pos=$(cat "/sys/block/$MDNAME/md/reshape_position" 2>/dev/null)
		[ "$pos" != "none" ] && [ "${pos:-0}" -gt "$CRASH_AT_POS" ] && break
		sleep 0.1
	done
	if [ "$pos" = none ] || [ "${pos:-0}" -le 0 ]; then
		rk_fail "$tag: reshape did not reach $CRASH_AT_POS (pos=$pos)"
		crash_teardown; return
	fi

	crash_now
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	crash_thaw
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	sudo "$MDADM" --stop --scan >/dev/null 2>&1
	sleep 0.2

	local asm_out asm_rc
	asm_out=$(sudo "$MDADM" --assemble "$MD" "${CRASH_DEVS[@]}" --run 2>&1)
	asm_rc=$?
	if [ "$asm_rc" -ne 0 ]; then
		rk_log "$tag: assemble rc=$asm_rc: $asm_out"
		rk_pass "$tag: refused-to-resume (no silent corruption, pos=$pos)"
		crash_teardown; return
	fi
	echo 200000 | sudo tee "/sys/block/$MDNAME/md/sync_speed_max" >/dev/null 2>&1
	rk_wait_idle

	if rk_readback "$SZ"; then
		rk_pass "$tag: data intact across crash (pos=$pos)"
	else
		rk_fail "$tag: DATA LOST across crash (pos=$pos)"
		rk_log "$tag: dmesg tail:"
		sudo dmesg | tail -15 | sed 's/^/      /'
	fi
	local mm; mm=$(rk_scrub)
	[ "$mm" = 0 ] && rk_pass "$tag: scrub clean after crash" \
		      || rk_fail "$tag: scrub mismatch_cnt=$mm after crash"

	crash_teardown
}

# ---- main ----
sudo modprobe dm-flakey 2>/dev/null
rk_load_modules || exit 1
crash_global_cleanup

# Baseline: same setup, no crash — does the loop/flakey stack carry our data
# through a clean reshape?  If this fails, the crash failures aren't crashes,
# they're harness bugs.
crash_baseline_no_crash() {
	local old_m=2 k=3
	local new_m=$((old_m + 1))
	local newn=$((k + new_m))
	local tag="baseline NO-CRASH m=$old_m->$new_m k=$k"
	local bf="$CRASH_BACK/addparity.backup"

	crash_setup "$newn" || { rk_fail "$tag: setup failed"; return; }
	local base; base="${CRASH_DEVS[*]:0:$((k+old_m))}"
	local add;  add="${CRASH_DEVS[$((newn-1))]}"
	sudo rm -f "$bf" "$bf.raidkm-state" "$bf.tmp"

	rk_create "${old_m}r" $base || { rk_fail "$tag: create failed"; crash_teardown; return; }
	rk_write "$SZ"
	rk_wait_idle	# clean, idle source before we grow

	local out
	if ! out=$(sudo "$MDADM" --grow "$MD" --add-parity --backup-file="$bf" "$add" 2>&1); then
		rk_fail "$tag: --add-parity failed"; rk_log "$tag: $out"; crash_teardown; return
	fi
	rk_wait_idle
	rk_readback "$SZ" && rk_pass "$tag: data intact (no-crash baseline)" \
			  || rk_fail "$tag: data MISMATCH (no-crash baseline)"
	crash_teardown
}

echo "==== baseline ===="
crash_baseline_no_crash

for iter in $(seq 1 "$CRASH_ITERS"); do
	echo
	echo "==== add-parity crash iter $iter / $CRASH_ITERS ===="
	crash_mid_add_parity 2
done

for iter in $(seq 1 "$CRASH_ITERS"); do
	echo
	echo "==== grow-data crash iter $iter / $CRASH_ITERS ===="
	crash_mid_grow_data 2 3
done

rk_summary "raidkm-test-crash.sh"
