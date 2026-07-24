#!/bin/bash
#
# raidkm-test-declustered-bitmap-resize.sh — the two remaining declustered v1
# compose gaps: write-intent bitmap and member resize.
#
#   T1  create with --bitmap=internal: array runs (v1 refusal lifted), the
#       bitmap exists on the members, writes + scrub are clean under it.
#   T2  unclean-shutdown resync is BITMAP-SCOPED: dirty a few chunks inside
#       the bitmap delay window, power-cut every member (dm-flakey
#       drop_writes), re-assemble — the on-disk bitmap shows only a small
#       dirty count before assembly, the resync completes, bits drain back
#       to ~0, data is byte-exact and a scrub is clean.
#   T3  degraded writes + --re-add under the bitmap: fail a member, write,
#       re-add it — the array returns to healthy, data intact, scrub clean.
#   T4  member resize (mdadm --grow --size): dev_sectors grows, the rkdcl
#       block MOVES to the new tail (verified across stop + re-assemble),
#       capacity grows by ngroups*k rows, the new space is resynced, data
#       intact + scrub clean — with the bitmap present (bitmap resize path).
#   T5  resize guards: shrink rejected; csum array rejected (region
#       relocation is a follow-up).
#
# Usage: bash <this>
set -u
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}
PATMB=${PATMB:-48}
SZ1=${SZ1:-49152}		# create-time member size (KiB) — leaves headroom
SZ2=${SZ2:-63488}		# grown member size (KiB); brd must be > SZ2 + chunk
FLK=(); BRDS=(); DEVS=(); MEMBERS=()

global_cleanup() {
	local d tries
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	sudo udevadm settle 2>/dev/null
	for d in $(sudo dmsetup ls 2>/dev/null | awk '$1 ~ /^rkdclbm[0-9]+$/ {print $1}'); do
		for tries in 1 2 3; do
			sudo dmsetup remove "$d" >/dev/null 2>&1 && break
			sudo dmsetup remove --force "$d" >/dev/null 2>&1 && break
			sleep 0.2
		done
	done
	for d in "${BRDS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
}
trap global_cleanup EXIT

stack_setup() {		# brd -> dm-flakey -> md, so T2 can power-cut atomically
	local i b flk sectors brds
	FLK=(); BRDS=(); MEMBERS=()
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	rk_setup_brd "$N" || return 1
	brds=($(rk_pick_disks "$N"))
	for i in "${!brds[@]}"; do
		b="${brds[$i]}"
		sudo dd if=/dev/zero of="$b" bs=1M count=8 status=none 2>/dev/null
		sudo "$MDADM" --zero-superblock "$b" 2>/dev/null
		flk="rkdclbm$i"
		sectors=$(sudo blockdev --getsz "$b")
		sudo dmsetup remove "$flk" >/dev/null 2>&1
		echo "0 $sectors flakey $b 0 86400 0" | \
			sudo dmsetup create "$flk" || return 1
		BRDS+=("$b"); FLK+=("$flk"); MEMBERS+=("/dev/mapper/$flk")
	done
}
crash_now() {
	local i f b sectors
	for f in "${FLK[@]}"; do
		sudo dmsetup suspend --noflush --nolockfs --noudevsync "$f"
	done
	for i in "${!FLK[@]}"; do
		f="${FLK[$i]}"; b="${BRDS[$i]}"
		sectors=$(sudo blockdev --getsz "$b")
		echo "0 $sectors flakey $b 0 0 86400 1 drop_writes" | \
			sudo dmsetup load "$f"
		sudo dmsetup resume --noudevsync "$f"
	done
}
crash_thaw() {
	local i f b sectors
	for i in "${!FLK[@]}"; do
		f="${FLK[$i]}"; b="${BRDS[$i]}"
		sectors=$(sudo blockdev --getsz "$b")
		sudo dmsetup suspend --noudevsync "$f"
		echo "0 $sectors flakey $b 0 86400 0" | sudo dmsetup load "$f"
		sudo dmsetup resume --noudevsync "$f"
	done
}
bitmap_dirty() {	# total "dirty" chunks summed over one member's bitmap
	sudo "$MDADM" -X "${MEMBERS[0]}" 2>/dev/null |
		sed -n 's/.*Bitmap : [0-9]* bits (chunks), \([0-9]*\) dirty.*/\1/p'
}

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
sudo modprobe dm-flakey 2>/dev/null

sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)

# ---- T1: create with an internal bitmap ----------------------------------------
echo "=== T1: create dcl N=$N g=$G m=$M s=$SC --bitmap=internal ==="
stack_setup || { rk_fail "T1: stack"; rk_summary; exit 1; }
rk_dmesg_clear
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--bitmap=internal --size=$SZ1 \
	--raid-devices=$N --run --force "${MEMBERS[@]}" >/dev/null 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat ||
	{ rk_fail "T1: create with --bitmap=internal failed"; sudo dmesg | tail -5; rk_summary; exit 1; }
rk_wait_idle
rk_pass "T1: declustered array runs with an internal write-intent bitmap"
sudo "$MDADM" -X "${MEMBERS[0]}" 2>/dev/null | grep -q "Bitmap :" &&
	rk_pass "T1: bitmap present on the members (-X)" ||
	rk_fail "T1: no bitmap found on member 0"
sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
sync
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "T1: scrub clean under the bitmap" \
	      || rk_fail "T1: scrub mismatch_cnt=$mm"

# ---- T2: unclean shutdown -> bitmap-scoped resync ------------------------------
echo "=== T2: power-cut with dirty bits -> scoped resync ==="
sleep 6		# let the earlier writes' bits drain (default bitmap delay 5s)
for off in 3 9 17 25; do	# dirty 4 chunks, cut inside the delay window
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count=1 seek="$off" skip="$off" \
		oflag=direct conv=notrunc status=none
done
sync	# data + set bits durable; bits have not drained yet
crash_now
sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
crash_thaw
# udev sees the members reappear and incremental-assembles them into an
# inactive array that holds them busy — release before the real assemble
sudo udevadm settle 2>/dev/null
sudo "$MDADM" --stop --scan >/dev/null 2>&1
sudo udevadm settle 2>/dev/null
dirty=$(bitmap_dirty)
[ -n "$dirty" ] && [ "$dirty" -gt 0 ] && [ "$dirty" -le 64 ] &&
	rk_pass "T2: on-disk bitmap shows a small dirty set ($dirty chunks)" ||
	rk_fail "T2: unexpected dirty count '$dirty' (want 1..64)"
rk_dmesg_clear
asmout=$(sudo "$MDADM" --assemble --force "$MD" "${MEMBERS[@]}" 2>&1)
grep -q "$MDNAME : active raidkm" /proc/mdstat ||
	{ rk_fail "T2: re-assemble failed"; echo "  mdadm: $asmout"; sudo dmesg | tail -8; rk_summary; exit 1; }
rk_wait_idle
sleep 6		# post-resync bit drain
d2=$(bitmap_dirty)
[ -n "$d2" ] && [ "$d2" -le 1 ] &&
	rk_pass "T2: bitmap drained after the scoped resync ($d2 dirty)" ||
	rk_fail "T2: bitmap not drained (dirty=$d2)"
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none | md5sum | cut -d' ' -f1)
[ "$PRE" = "$GOT" ] && rk_pass "T2: data byte-exact across the power cut" \
		    || rk_fail "T2: DATA MISMATCH after power cut"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "T2: scrub clean after scoped resync" \
	      || rk_fail "T2: scrub mismatch_cnt=$mm"

# ---- T3: degraded writes + --re-add under the bitmap ---------------------------
echo "=== T3: fail + write + --re-add under the bitmap ==="
FD="${MEMBERS[2]}"
sudo "$MDADM" "$MD" --fail "$FD" >/dev/null 2>&1
sleep 1
sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count=8 seek=12 skip=12 oflag=direct conv=notrunc status=none
sync
sudo "$MDADM" "$MD" --remove "$FD" >/dev/null 2>&1
sudo "$MDADM" "$MD" --re-add "$FD" >/dev/null 2>&1 ||
	sudo "$MDADM" "$MD" --add "$FD" >/dev/null 2>&1
rk_wait_idle
# the dcl rescue/population machinery may hold state briefly; give it a window
for i in $(seq 1 30); do
	deg=$(cat /sys/block/$MDNAME/md/degraded)
	nreb=$(sudo "$MDADM" --examine "${BRDS[0]}" 2>/dev/null | grep -c COPYING)
	[ "$deg" = 0 ] && break
	sleep 2
done
deg=$(cat /sys/block/$MDNAME/md/degraded)
[ "$deg" = 0 ] && rk_pass "T3: array healthy again after re-add" \
	       || rk_fail "T3: still degraded=$deg after re-add"
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none | md5sum | cut -d' ' -f1)
[ "$PRE" = "$GOT" ] && rk_pass "T3: data intact across fail/write/re-add" \
		    || rk_fail "T3: DATA MISMATCH after re-add"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "T3: scrub clean after re-add" \
	      || rk_fail "T3: scrub mismatch_cnt=$mm"

# ---- T4: member resize (grow) with the bitmap present --------------------------
echo "=== T4: mdadm --grow --size=$SZ2 (member grow $SZ1 -> $SZ2 KiB) ==="
CAP0=$(sudo blockdev --getsz "$MD")
rk_dmesg_clear
sudo "$MDADM" --grow "$MD" --size=$SZ2 2>&1 | sed 's/^/  /'
sleep 3			# let the async resync of the new rows actually start
rk_wait_idle		# ... then drain it
CAP1=$(sudo blockdev --getsz "$MD")
[ "$CAP1" -gt "$CAP0" ] && rk_pass "T4: capacity grew ($CAP0 -> $CAP1 sectors)" \
			|| rk_fail "T4: capacity did not grow ($CAP0 -> $CAP1)"
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none | md5sum | cut -d' ' -f1)
[ "$PRE" = "$GOT" ] && rk_pass "T4: data intact across the member grow" \
		    || rk_fail "T4: DATA MISMATCH after member grow"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "T4: scrub clean (new rows parity-initialized)" \
	      || rk_fail "T4: scrub mismatch_cnt=$mm"
# the rkdcl block moved to the new tail: a full stop + re-assemble must find it
sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]}" >/dev/null 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat &&
	rk_pass "T4: re-assembles at the new size (rkdcl block found at the moved tail)" ||
	{ rk_fail "T4: re-assemble after resize failed"; sudo dmesg | tail -8; }
rk_wait_idle
GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none | md5sum | cut -d' ' -f1)
[ "$PRE" = "$GOT" ] && rk_pass "T4: data intact after re-assemble" \
		    || rk_fail "T4: DATA MISMATCH after re-assemble"

# ---- T5: resize guards ---------------------------------------------------------
echo "=== T5: shrink rejected; csum resize rejected ==="
sudo "$MDADM" --grow "$MD" --size=$SZ1 2>&1 | grep -qi "" # capture below
sz_now=$(sudo "$MDADM" --detail "$MD" 2>/dev/null | sed -n 's/.*Used Dev Size : \([0-9]*\).*/\1/p')
[ -n "$sz_now" ] && [ "$sz_now" -ge "$SZ2" ] &&
	rk_pass "T5: shrink rejected (size still $sz_now KiB)" ||
	rk_fail "T5: shrink was not rejected (size now $sz_now)"
sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" --checksum \
	--size=$SZ1 --raid-devices=$N --run --force "${MEMBERS[@]}" >/dev/null 2>&1
rk_wait_idle
sudo "$MDADM" --grow "$MD" --size=$SZ2 >/dev/null 2>&1
sz_now=$(sudo "$MDADM" --detail "$MD" 2>/dev/null | sed -n 's/.*Used Dev Size : \([0-9]*\).*/\1/p')
[ -n "$sz_now" ] && [ "$sz_now" -le "$SZ1" ] &&
	rk_pass "T5: csum-array resize rejected (region relocation is a follow-up)" ||
	rk_fail "T5: csum-array resize was not rejected (size now $sz_now)"

sudo dmesg | grep -iE "WARN|BUG|call trace|gf_invert" | tail -5
rk_summary
