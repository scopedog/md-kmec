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
# DCL_CRASH_COPY=1: Phase-4 variant — populate F, re-add its wiped device as
# the replacement, and cut the power mid-COPY (or just after; both cells are
# legit).  The re-assemble (INCLUDING the replacement) must resume the copy
# from the strict-journaled band mark — R's above-mark garbage is fenced by
# the offset-split — and finish to degraded=0 with byte-exact content.
# DCL_CRASH_MCOPY=1 (needs s >= 2): §13 multi-assignment-copy variant —
# BOTH populations complete, F's wiped device is re-added, the cut lands
# mid-COPY on the v3 COPYING@F+POPULATED@F2 journal; the resume must keep
# F2's assignment, finish F's copy, and PARTIAL-retire to degraded=1.
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
	# detach every loop backing a file under $BACK — matching the
	# literal $BACK path, NOT a hardcoded substring (a DCL_CRASH_BACK
	# override otherwise leaks a loop + its 192MB image every iteration
	# until the backing fs fills)
	for l in $(sudo losetup -l 2>/dev/null | awk -v b="$BACK/" 'index($0,b){print $1}'); do
		sudo losetup -d "$l" >/dev/null 2>&1
	done
}

stack_setup() {
	local i loop f flk sectors
	FLK=(); LOOPS=(); DEVS=()
	mkdir -p "$BACK"
	global_cleanup
	sudo rm -f "$BACK"/disk*.img	# purge any leaked backing files
	# Iteration boundary needs the same udev discipline as the post-crash
	# assemble (observed: 7-member inactive md127 wedging iter4's create).
	rk_udev_quiesce
	for i in $(seq 1 "$N"); do
		f="$BACK/disk$i.img"
		sudo rm -f "$f"
		# dd failure (ENOSPC on an undersized DCL_CRASH_BACK) must fail
		# HERE — a short file makes a zero-size loop and a confusing
		# "zero-length target" dm error much later
		sudo dd if=/dev/zero of="$f" bs=1M count="$DISK_MB" status=none || {
			echo "ERROR: backing file $f short — is $BACK large enough for $N x ${DISK_MB}MB?" >&2
			return 1; }
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
COPY=${DCL_CRASH_COPY:-0}
# DCL_CRASH_MCOPY=1 (needs s >= 2): §13 multi-assignment-copy variant —
# populate F AND F2 to POPULATED, re-add F's wiped device, cut mid-COPY.
# The v3 journal carries COPYING@F + POPULATED@F2 across the crash; the
# resume must keep F2's assignment intact, finish F's copy from the
# journaled band mark, and the completion's PARTIAL retire leaves exactly
# F2's assignment active (degraded back to 1, not 0).
MCOPY=${DCL_CRASH_MCOPY:-0}
if [ $((MULTI + COPY + MCOPY)) -gt 1 ]; then
	echo "ERROR: DCL_CRASH_MULTI/_COPY/_MCOPY are exclusive" >&2; exit 1
fi
if [ "$MULTI" = 1 ] || [ "$MCOPY" = 1 ]; then
	[ "$SC" -ge 2 ] || { echo "ERROR: this variant needs s >= 2" >&2; exit 1; }
	F2=$(awk -v f="$F" '$1 !~ /^#/ && $6 != f {print $6; exit}' "$RK_TMP/vec.tsv")
fi


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
	for lc in "${FLCS[@]}"; do rk_mkpat CRA "$lc"; rk_wrchunk "$RK_TMP/CRA$lc" "$lc"; done
	sync
	rk_pass "$tag: stack + create + baseline"

	FDEV="${DEVS[$F]}"
	rk_fail_disks "$FDEV"
	sudo "$MDADM" --remove "$MD" "$FDEV" > /dev/null 2>&1
	if [ "$COPY" = 1 ]; then
		# populate at FULL speed to POPULATED, then re-add the wiped
		# device as the replacement — the cut targets the COPY
		echo "$F" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 || {
			rk_fail "$tag: arming failed"; break; }
		rk_wait_idle
		rk_pop_show | grep -q "^populated $F " || {
			rk_fail "$tag: population did not complete"; break; }
		sudo dd if=/dev/zero of="$FDEV" bs=1M count=8 status=none 2>/dev/null
		sudo "$MDADM" --zero-superblock "$FDEV" 2>/dev/null
		rk_add_disks "$FDEV"
		# catch the copy mid-flight: poll for COPYING (or completion —
		# the crash-after-complete cell is legit too), then cut NOW.
		# One capture per iteration (repeated sudo forks would widen
		# the poll period well past the copy window).
		for i in $(seq 1 300); do
			precopy=$(rk_pop_show)
			case "$precopy" in copying*|none*) break;; esac
			sleep 0.02
		done
		precopy=$(echo "$precopy" | tr '\n' ';')
	elif [ "$MCOPY" = 1 ]; then
		# BOTH populations run to POPULATED at full speed; the cut
		# targets the multi-assignment COPY of F (F2's stays live)
		echo "$F" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 || {
			rk_fail "$tag: arming F failed"; break; }
		rk_wait_idle
		rk_pop_show | grep -q "^populated $F " || {
			rk_fail "$tag: first population did not complete"; break; }
		FDEV2="${DEVS[$F2]}"
		rk_fail_disks "$FDEV2"
		sudo "$MDADM" --remove "$MD" "$FDEV2" > /dev/null 2>&1
		echo "$F2" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 || {
			rk_fail "$tag: arming F2 failed"; break; }
		rk_wait_idle
		rk_pop_show | grep -q "^populated $F2 " || {
			rk_fail "$tag: second population did not complete"; break; }
		sudo dd if=/dev/zero of="$FDEV" bs=1M count=8 status=none 2>/dev/null
		sudo "$MDADM" --zero-superblock "$FDEV" 2>/dev/null
		# throttle so the cut deterministically lands MID-copy (the copy
		# honors sync_speed_max per band); the post-crash assemble is a
		# fresh array at default speed, so the resume completes fast.
		# Without this a fast box finishes the copy inside crash_now's
		# suspend loop and every cell degenerates to complete-at-cut.
		rk_throttle 8192
		rk_add_disks "$FDEV"
		for i in $(seq 1 300); do
			precopy=$(rk_pop_show | grep -v "^populated $F2 ")
			case "$precopy" in copying*|""|none*) break;; esac
			sleep 0.02
		done
		# random extra delay so some iterations cut MID-band (bands
		# journal every ~8s at the 8192 KB/s throttle): mixes mark-0
		# and deeper-mark resume cells instead of always cutting at
		# the first sight of COPYING
		case "$precopy" in copying*)
			sleep "${DCL_CRASH_DELAY:-$(( RANDOM % 12 ))}"
			precopy=$(rk_pop_show | grep -v "^populated $F2 ");; esac
		precopy=$(echo "$precopy" | tr '\n' ';')
	elif [ "$MULTI" = 1 ]; then
		# first population runs to POPULATED at full speed; the crash
		# targets the SECOND population (v3 journal on disk)
		echo "$F" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 || {
			rk_fail "$tag: arming F failed"; break; }
		rk_wait_idle
		rk_pop_show | grep -q "^populated $F " || {
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
	if [ "$COPY" = 1 ] || [ "$MCOPY" = 1 ]; then
		delay=0		# the poll above IS the timing; cut immediately
	else
		delay=${DCL_CRASH_DELAY:-$(( (RANDOM % 9) + 1 ))}	# 1..9s: pre-checkpoint AND mid-pass cells
		sleep "$delay"
	fi
	premark=$(rk_pop_mark)
	crash_now
	sudo "$MDADM" --stop "$MD" > /dev/null 2>&1
	crash_thaw
	sudo "$MDADM" --stop "$MD" > /dev/null 2>&1
	# The thaw's dm resume events can trigger udev INCREMENTAL assembly of
	# the survivors into md127, stealing the members from the assemble
	# below (observed: population resumed fine — on md127; our pop_show on
	# $MDNAME read '').
	rk_udev_quiesce
	sleep 0.2

	SURV=()
	for d in "${DEVS[@]}"; do
		# COPY/MCOPY re-assemble WITH R (F's device); MCOPY and MULTI
		# leave F2's device out (its assignment must survive the crash)
		if [ "$COPY" != 1 ] && [ "$MCOPY" != 1 ]; then
			[ "$d" = "$FDEV" ] && continue
		fi
		if [ "$MULTI" = 1 ] || [ "$MCOPY" = 1 ]; then
			[ "$d" = "${FDEV2:-}" ] && continue
		fi
		SURV+=("$d")
	done
	rk_dmesg_window_close; rk_dmesg_clear
	# --force: the dropped stop leaves DIRTY superblocks and the pool is
	# degraded — md (correctly) refuses dirty+degraded without it.
	sudo "$MDADM" --assemble --force --run "$MD" "${SURV[@]}" > /dev/null 2>&1 || {
		rk_fail "$tag: post-crash assemble failed (crash at ${delay}s, premark=$premark)"
		break; }
	# multi: F's assignment completed (and was journaled) BEFORE F2 failed,
	# so every election outcome preserves it — assert that first.
	if [ "$MULTI" = 1 ] && ! rk_pop_show | grep -q "^populated $F "; then
		echo "  DIAG: state: $(rk_pop_show | tr '\n' '|')"
		rk_fail "$tag: first assignment lost across the crash"; break
	fi
	# mcopy: F2's POPULATED assignment was strict-journaled long before
	# the cut — every election outcome must preserve it.
	if [ "$MCOPY" = 1 ] && ! rk_pop_show | grep -q "^populated $F2 "; then
		echo "  DIAG: state: $(rk_pop_show | tr '\n' '|')"
		rk_fail "$tag: second assignment lost across the crash"; break
	fi
	if [ "$COPY" = 1 ] || [ "$MCOPY" = 1 ]; then
		# Copy cells: COPYING resumed from the strict-journaled band
		# mark, or the copy had completed before the cut (state none;
		# for mcopy "none" means F's entry gone, F2's line remains).
		# POPULATED@F is the pre-arm cell (cut beat the arm journal):
		# the kernel's unarmed-recovery guard must take the decode leg.
		if [ "$MCOPY" = 1 ]; then
			state=$(rk_pop_show | grep -v "^populated $F2 ")
		else
			state=$(rk_pop_show)
		fi
		case "$state" in
		copying*)
			rmark=$(sudo dmesg | sed -n 's/.*resuming copy of disk [0-9]* from mark \([0-9]*\).*/\1/p' | tail -1)
			rk_pass "$tag: copy resumed from journaled mark ${rmark:-?} (pre-cut: ${precopy:-?})"
			;;
		""|none*)
			rk_pass "$tag: copy complete at the cut (pre-cut: ${precopy:-?})"
			;;
		populated*)
			# pre-arm cell: the cut beat the COPYING arm journal but
			# R's slot-assigning SB (written by --add) survived.  The
			# kernel's unarmed-recovery guard must retire the
			# assignment(s) and let the decode leg rebuild R — the
			# end-state asserts below (copy: degraded=0+none; mcopy:
			# the fallback branch) cover it.
			rk_pass "$tag: cut landed before the copy armed (pre-arm cell; guard takes the decode leg)"
			;;
		*)
			echo "  DIAG: state: $state  dmesg: $(sudo dmesg | tail -6 | tr '\n' '|')"
			rk_fail "$tag: unexpected copy state '$state' after crash"; break;;
		esac
		if [ "$MCOPY" = 1 ]; then
			# F's copy finishes; degraded 2 -> 1 lands at the reap
			# (spare_active), which can trail the sysfs state change
			# — poll it rather than read once
			for i in $(seq 1 240); do
				rk_pop_show | grep -q "^copying" || break
				sleep 0.5
			done
			for i in $(seq 1 120); do
				deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
				[ "$deg" = 1 ] && break
				sleep 0.5
			done
			if sudo dmesg | grep -qE "[0-9]+ spare assignment\(s\) retired"; then
				# FALLBACK cell: a copy abort (band failure, or
				# the unarmed-recovery guard on a pre-arm cut)
				# retired ALL assignments and the decode leg
				# rebuilt R — legit, distinct from the
				# partial-retire happy path.  Content + scrub
				# below still gate correctness (the scrub reads
				# every row through the read map, so hosted-row
				# garbage on R cannot hide).
				if [ "$deg" = 1 ] && rk_pop_show | grep -q "^none"; then
					rk_pass "$tag: copy fell back to retire-all + decode (legit fallback cell)"
				else
					rk_fail "$tag: fallback end-state wrong (degraded=$deg, $(rk_pop_show | tr '\n' ';'))"
					break
				fi
			elif [ "$deg" = 1 ] &&
			   rk_pop_show | grep -q "^populated $F2 " &&
			   ! rk_pop_show | grep -qE "^(populated|copying|populating) $F "; then
				rk_pass "$tag: copy finished after crash (partial retire; F2's assignment intact)"
			else
				rk_fail "$tag: mcopy end-state wrong (degraded=$deg, $(rk_pop_show | tr '\n' ';'))"
				break
			fi
		else
		rk_wait_full
		deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
		if [ "$deg" = 0 ] && rk_pop_show | grep -q "^none"; then
			rk_pass "$tag: copy finished after crash (degraded=0, retired)"
		else
			rk_fail "$tag: copy did not finish (degraded=$deg, $(rk_pop_show | tr '\n' ';'))"
			break
		fi
		fi
	else
	if [ "$MULTI" = 1 ]; then
		state=$(rk_pop_show | grep -v "^populated $F ")
		rearm="$F2"
	else
		state=$(rk_pop_show)
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
		rk_pop_show | grep -q "^populated $F " && rk_pop_show | grep -q "^populated $F2 " \
			&& rk_pass "$tag: BOTH populations COMPLETE after crash ($(rk_pop_show | tr '\n' ';'))" \
			|| { rk_fail "$tag: populations did not complete: $(rk_pop_show | tr '\n' ';')"; break; }
	else
		rk_pop_show | grep -q "^populated" \
			&& rk_pass "$tag: population COMPLETE after crash ($(rk_pop_show))" \
			|| { rk_fail "$tag: population did not complete: $(rk_pop_show)"; break; }
	fi
	fi	# !COPY

	ok=1
	for lc in "${FLCS[@]}"; do
		rk_rdchunk "$lc" "$RK_TMP/cr$lc"
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
rk_dmesg_window_close
[ "$RK_DMESG_BAD" = 0 ] && rk_pass "no kernel WARN/BUG during the matrix (all windows)" \
		     || rk_fail "kernel log had WARN/BUG — check dmesg"

rk_summary
