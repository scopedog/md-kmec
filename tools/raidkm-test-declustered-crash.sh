#!/bin/bash
#
# raidkm-test-declustered-crash.sh — power-loss-mid-POPULATION matrix via
# dm-flakey (raidkm-test-crash.sh mechanism, declustered Phase 3 target).
#
# Stack per member:  file → loop --direct-io → dm-flakey → md raidkm (dcl).
# "Power loss" = atomically flip every flakey to drop_writes mid-population
# (in-flight and later writes vanish with SUCCESS status), stop, thaw,
# re-assemble.  The §2 journal invariant under test: the rkdcl v2 checkpoint
# (PREFLUSH+FUA, every 16MiB) is only written AFTER the spare-column writes
# below its mark completed, so after any crash the highest-gen elected mark
# M is safe: rows below M are served from the spare columns permanently and
# must be byte-correct; rows above M re-decode (write-redirect-ALL-rows
# makes the pass idempotent).  A crash before the arming journal landed
# legitimately loses the assignment ("none" after assemble) — that cell
# re-arms and must still complete.
#
# Model note (same as raidkm-test-crash.sh): loop --direct-io acks == on
# the backing file, so device-cache/FUA distinctions are not modelled; the
# matrix validates ORDERING (mark never ahead of durable spare writes), not
# drive-cache behavior.
#
# DCL_CRASH_MULTI=1 (needs s >= 2): Phase-3b variant — first population runs
# to POPULATED, then a second member fails and the power cut lands mid-
# SECOND-population, i.e. on the v3 two-assignment journal; the resume must
# restore BOTH assignments and finish.  DCL_CRASH_DELAY pins the cut delay.
# Configurable: DCL_N/G/M/SC/NBASE/SEED (geometry), DCL_CRASH_ITERS (4),
#               DCL_CRASH_DISK_MB (192), DCL_CRASH_BACK dir.
# OPT-IN reliability gate — not part of the default raidkm-test.sh runner.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}
SEED=${DCL_SEED:-0x10}
ITERS=${DCL_CRASH_ITERS:-4}
DISK_MB=${DCL_CRASH_DISK_MB:-192}
BACK=${DCL_CRASH_BACK:-/var/tmp/raidkm-dcl-crash}
CS=$((CHUNK_KB * 2))
NVEC=4096
FIO_OFF=$((96 * 1024 * 1024))
FIO_SZ=$((32 * 1024 * 1024))

SIM_SRC="$RK_TREE/tools/declustered-sim.c"
SIM="$RK_TMP/declustered-sim"

FLK=(); LOOPS=(); DEVS=()

pop_show() { cat "/sys/block/$MDNAME/md/rk_dcl_populate" 2>/dev/null; }
DMESG_BAD=0
dmesg_window_close() { rk_dmesg_clean || DMESG_BAD=1; }

global_cleanup() {
	local d l tries
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	sudo "$MDADM" --stop --scan >/dev/null 2>&1
	sudo udevadm settle 2>/dev/null
	for d in $(sudo dmsetup ls 2>/dev/null | awk '$1 ~ /^rkdclcr[0-9]+$/ {print $1}'); do
		for tries in 1 2 3 4 5; do
			sudo dmsetup remove "$d" >/dev/null 2>&1 && break
			sudo dmsetup remove --force "$d" >/dev/null 2>&1 && break
			sleep 0.2
		done
	done
	for l in $(sudo losetup -l 2>/dev/null | awk '/raidkm-dcl-crash/ {print $1}'); do
		sudo losetup -d "$l" >/dev/null 2>&1
	done
}

stack_setup() {
	local i loop f flk sectors
	FLK=(); LOOPS=(); DEVS=()
	mkdir -p "$BACK"
	global_cleanup
	# Iteration boundary needs the same udev discipline as the post-crash
	# assemble: teardown/creation events can trigger an incremental md127
	# assembly of the previous iteration's members, which then holds the
	# dm devices busy (observed: 7-member inactive md127 wedging iter4's
	# create).  Settle, tear down anything udev built, settle again.
	sudo udevadm settle 2>/dev/null
	sudo "$MDADM" --stop --scan > /dev/null 2>&1
	sudo udevadm settle 2>/dev/null
	for i in $(seq 1 "$N"); do
		f="$BACK/disk$i.img"
		sudo rm -f "$f"
		sudo dd if=/dev/zero of="$f" bs=1M count="$DISK_MB" status=none
		loop=$(sudo losetup --show -f --direct-io=on "$f") || return 1
		flk="rkdclcr$i"
		sectors=$(sudo blockdev --getsz "$loop")
		echo "0 $sectors flakey $loop 0 86400 0" | \
			sudo dmsetup create "$flk" || return 1
		LOOPS+=("$loop"); FLK+=("$flk"); DEVS+=("/dev/mapper/$flk")
	done
}

crash_now() {
	local i f loop sectors
	# Two-phase, --noflush: a default (flushing) suspend waits behind the
	# population's in-flight I/O — observed to stall MINUTES against a
	# live sync, letting population finish "successfully" before any
	# device dropped a write.  Suspend everything first (in-flight bios
	# park), then swap in drop_writes and resume: the parked writes and
	# everything after vanish with success status — an atomic power cut.
	# --noudevsync everywhere in the flip: a synced resume waits on a udev
	# cookie semaphore, and udevd on a distro image is busy coredumping a
	# stock mdadm per event (map_num_s assert storm) — a stranded cookie
	# blocked a resume in semtimedop for 40+ min (dmsetup udevcomplete_all
	# is the manual escape).  The flip must not depend on udev at all.
	for f in "${FLK[@]}"; do
		sudo dmsetup suspend --noflush --nolockfs --noudevsync "$f"
	done
	for i in "${!FLK[@]}"; do
		f="${FLK[$i]}"; loop="${LOOPS[$i]}"
		sectors=$(sudo blockdev --getsz "$loop")
		echo "0 $sectors flakey $loop 0 0 86400 1 drop_writes" | \
			sudo dmsetup load "$f"
		sudo dmsetup resume --noudevsync "$f"
	done
}

crash_thaw() {
	local i f loop sectors
	for i in "${!FLK[@]}"; do
		f="${FLK[$i]}"; loop="${LOOPS[$i]}"
		sectors=$(sudo blockdev --getsz "$loop")
		sudo dmsetup suspend --noudevsync "$f"
		echo "0 $sectors flakey $loop 0 86400 0" | sudo dmsetup load "$f"
		sudo dmsetup resume --noudevsync "$f"
	done
}

cleanup() { global_cleanup; }
trap cleanup EXIT

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
sudo modprobe dm-flakey 2>/dev/null

cc -O2 -o "$SIM" "$SIM_SRC" -lm || {
	echo "ERROR: cannot build $SIM_SRC" >&2; exit 1; }
"$SIM" -N $N -g $G -m $M -s $SC -b $NBASE -S $SEED -T 1 \
	--vectors "$RK_TMP/vec.tsv" --nvec $NVEC > /dev/null || {
	echo "ERROR: simulator failed" >&2; exit 1; }
F=$(awk '$1 !~ /^#/ && $1 == 0 {print $6}' "$RK_TMP/vec.tsv")
read -r -a FLCS <<< "$(awk -v F="$F" '$1 !~ /^#/ && $6 == F && $1 < 1536 && !seen[$5]++ {print $1}' \
	"$RK_TMP/vec.tsv" | head -6 | tr '\n' ' ')"
[ "${#FLCS[@]}" -ge 3 ] || { echo "ERROR: too few on-F vectors" >&2; exit 1; }
# multi-assignment variant (DCL_CRASH_MULTI=1, needs s >= 2): populate F to
# POPULATED first, then fail F2 and CRASH mid-SECOND-population — the power
# cut lands on the v3 (two-assignment) journal and the resume must restore
# BOTH assignments and finish the second population.
MULTI=${DCL_CRASH_MULTI:-0}
if [ "$MULTI" = 1 ]; then
	[ "$SC" -ge 2 ] || { echo "ERROR: DCL_CRASH_MULTI needs s >= 2" >&2; exit 1; }
	F2=$(awk -v f="$F" '$1 !~ /^#/ && $6 != f {print $6; exit}' "$RK_TMP/vec.tsv")
fi

mkpat() {
	yes "$1$(printf '%04d' "$2")" | head -c $((CHUNK_KB * 1024)) | \
		sudo tee "$RK_TMP/$1$2" > /dev/null
}
wrchunk() { sudo dd if="$1" of="$MD" bs="${CHUNK_KB}k" seek="$2" count=1 \
		oflag=direct conv=notrunc,fsync status=none; }
rdchunk() { sudo dd if="$MD" of="$2" bs="${CHUNK_KB}k" skip="$1" count=1 \
		iflag=direct status=none; }

rk_dmesg_clear
for it in $(seq 1 "$ITERS"); do
	tag="iter$it"
	stack_setup || { rk_fail "$tag: stack setup failed"; break; }
	sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
		--layout=declustered --group-width=$G --spare-columns=$SC \
		--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
		--raid-devices=$N "${DEVS[@]}" --run --force > /dev/null 2>&1 &&
	   grep -q "$MDNAME : active raidkm" /proc/mdstat ||
		{ rk_fail "$tag: create failed"; break; }
	rk_wait_idle
	sudo fio --name=base --filename="$MD" --direct=1 --bs=64k --rw=write \
		--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=8 \
		--verify=crc32c --do_verify=1 --verify_fatal=1 --group_reporting \
		--output="$RK_TMP/cr-fio-$it.log" > /dev/null 2>&1 \
		|| { rk_fail "$tag: baseline fio failed"; break; }
	for lc in "${FLCS[@]}"; do mkpat CRA "$lc"; wrchunk "$RK_TMP/CRA$lc" "$lc"; done
	sync
	rk_pass "$tag: stack + create + baseline"

	FDEV="${DEVS[$F]}"
	rk_fail_disks "$FDEV"
	sudo "$MDADM" --remove "$MD" "$FDEV" > /dev/null 2>&1
	if [ "$MULTI" = 1 ]; then
		# first population runs to POPULATED at full speed; the crash
		# targets the SECOND population (v3 journal on disk)
		echo "$F" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 || {
			rk_fail "$tag: arming F failed"; break; }
		rk_wait_idle
		pop_show | grep -q "^populated $F " || {
			rk_fail "$tag: first population did not complete"; break; }
		FDEV2="${DEVS[$F2]}"
		rk_fail_disks "$FDEV2"
		sudo "$MDADM" --remove "$MD" "$FDEV2" > /dev/null 2>&1
		rk_throttle 8192
		echo "$F2" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 || {
			rk_fail "$tag: arming F2 failed"; break; }
	else
		rk_throttle 8192
		echo "$F" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 || {
			rk_fail "$tag: arming failed"; break; }
	fi
	delay=${DCL_CRASH_DELAY:-$(( (RANDOM % 9) + 1 ))}	# 1..9s: pre-checkpoint AND mid-pass cells
	sleep "$delay"
	premark=$(pop_show | sed -n 's/.*mark \([0-9]*\)\/.*/\1/p')
	crash_now
	sudo "$MDADM" --stop "$MD" > /dev/null 2>&1
	crash_thaw
	sudo "$MDADM" --stop "$MD" > /dev/null 2>&1
	# The thaw's dm resume events can trigger udev INCREMENTAL assembly of
	# the survivors into md127, stealing the members from the assemble
	# below (observed: population resumed fine — on md127; our pop_show on
	# $MDNAME read '').  Settle udev FIRST so its assembly (if any) is
	# complete, THEN tear every scanned array down, then settle again so
	# the teardown events are drained before we assemble.
	sudo udevadm settle 2>/dev/null
	sudo "$MDADM" --stop --scan > /dev/null 2>&1
	sudo udevadm settle 2>/dev/null
	sleep 0.2

	SURV=()
	for d in "${DEVS[@]}"; do
		[ "$d" = "$FDEV" ] && continue
		[ "$MULTI" = 1 ] && [ "$d" = "${FDEV2:-}" ] && continue
		SURV+=("$d")
	done
	dmesg_window_close; rk_dmesg_clear
	# --force: the dropped stop leaves DIRTY superblocks and the pool is
	# degraded — md (correctly) refuses dirty+degraded without it.
	sudo "$MDADM" --assemble --force --run "$MD" "${SURV[@]}" > /dev/null 2>&1 || {
		rk_fail "$tag: post-crash assemble failed (crash at ${delay}s, premark=$premark)"
		break; }
	# multi: F's assignment completed (and was journaled) BEFORE F2 failed,
	# so every election outcome preserves it — assert that first.
	if [ "$MULTI" = 1 ] && ! pop_show | grep -q "^populated $F "; then
		echo "  DIAG: state: $(pop_show | tr '\n' '|')"
		rk_fail "$tag: first assignment lost across the crash"; break
	fi
	if [ "$MULTI" = 1 ]; then
		state=$(pop_show | grep -v "^populated $F ")
		rearm="$F2"
	else
		state=$(pop_show)
		rearm="$F"
	fi
	case "$state" in
	populating*)
		rmark=$(sudo dmesg | sed -n 's/.*resuming population of disk [0-9]* from mark \([0-9]*\).*/\1/p' | tail -1)
		rk_pass "$tag: resumed POPULATING from journaled mark ${rmark:-?} (crash at ${delay}s, premark=${premark:-0})"
		;;
	populated*)
		rk_pass "$tag: assignment already POPULATED at assemble (crash at ${delay}s)"
		;;
	""|none*)
		# crash beat the arming journal — legit cell; arm again
		# (multi: only F2's arming can be lost; F was asserted above)
		echo "$rearm" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 \
			&& rk_pass "$tag: assignment lost to the crash (pre-journal cell) — re-armed" \
			|| { rk_fail "$tag: state none and re-arm failed"; break; }
		;;
	*)
		echo "  DIAG: mdstat: $(grep -A1 "$MDNAME" /proc/mdstat | tr '\n' ' ')"
		echo "  DIAG: attr exists: $(ls -la /sys/block/$MDNAME/md/rk_dcl_populate 2>&1)"
		echo "  DIAG: array_state: $(cat /sys/block/$MDNAME/md/array_state 2>&1)"
		echo "  DIAG: dmesg tail: $(sudo dmesg | tail -8 | tr '\n' '|')"
		rk_fail "$tag: unexpected state '$state' after crash"; break;;
	esac
	rk_unthrottle
	rk_wait_idle
	if [ "$MULTI" = 1 ]; then
		pop_show | grep -q "^populated $F " && pop_show | grep -q "^populated $F2 " \
			&& rk_pass "$tag: BOTH populations COMPLETE after crash ($(pop_show | tr '\n' ';'))" \
			|| { rk_fail "$tag: populations did not complete: $(pop_show | tr '\n' ';')"; break; }
	else
		pop_show | grep -q "^populated" \
			&& rk_pass "$tag: population COMPLETE after crash ($(pop_show))" \
			|| { rk_fail "$tag: population did not complete: $(pop_show)"; break; }
	fi

	ok=1
	for lc in "${FLCS[@]}"; do
		rdchunk "$lc" "$RK_TMP/cr$lc"
		cmp -s "$RK_TMP/CRA$lc" "$RK_TMP/cr$lc" || { ok=0; break; }
	done
	sudo fio --name=basev --filename="$MD" --direct=1 --bs=64k --rw=read \
		--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=8 \
		--verify=crc32c --verify_fatal=1 --group_reporting \
		--output="$RK_TMP/cr-fiov-$it.log" > /dev/null 2>&1 || ok=0
	[ $ok = 1 ] && rk_pass "$tag: content byte-exact after crash+populate (chunks + fio)" \
		    || rk_fail "$tag: content mismatch at lc=${lc:-?}"
	mm=$(rk_scrub)
	[ "$mm" = 0 ] && rk_pass "$tag: scrub clean (mismatch_cnt=0)" \
		      || rk_fail "$tag: scrub mismatch_cnt=$mm"
	sudo "$MDADM" --stop "$MD" > /dev/null 2>&1
	# Kill the superblocks NOW or udev auto-assembles an md127 from the
	# members and holds the dm devices busy against the next iteration.
	sudo udevadm settle 2>/dev/null
	for d in "${DEVS[@]}"; do
		sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
	sudo udevadm settle 2>/dev/null
done
dmesg_window_close
[ "$DMESG_BAD" = 0 ] && rk_pass "no kernel WARN/BUG during the matrix (all windows)" \
		     || rk_fail "kernel log had WARN/BUG — check dmesg"

rk_summary
