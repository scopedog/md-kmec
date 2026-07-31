#!/bin/bash
#
# raidkm-test-declustered-shrink-csum.sh — declustered POOL SHRINK × native
# checksum (dcl-shrink-design.md D4).  The backward band shares the dcl
# verify-src / re-key helpers; this gate proves them on the descending walk:
#
#   S1  shrink N -> N-g on a --checksum array (array-size-first): completes,
#       data byte-exact, settled scrub clean.
#   S2  re-key proof: full-device read after the shrink reports ZERO csum
#       mismatches; corrupting one migrated block raw at its NEW (survivor)
#       location is detected on the right physical disk and healed — the
#       CRCs really live at the new keys.
#   S3  fail-closed proof: corrupt a data block raw BEFORE the shrink (no
#       intervening read) -> the migrate band detects it against the stored
#       CRC and fails ("CRC mismatch on migrate read"); heal it through the
#       array (the un-migrated region below the descending frontier still
#       serves the OLD geometry), the shrink resumes and completes; data
#       byte-exact + settled scrub clean.
#
# (The stale-key-storm-under-racing-writes leg lives in
#  raidkm-test-declustered-shrink-concurrent.sh CSUM=1.)
set -u
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SIM_SRC="$RK_TREE/tools/declustered-sim.c"
SIM="$RK_TMP/declustered-sim"

N=${DCL_N:-20}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}
NEWN=$(( N - G )); NEWSEED=${DCL_NEWSEED:-0x77}
OLD_NG=$(( (N - SC) / G )); NEW_NG=$(( (NEWN - SC) / G ))
CS=$((CHUNK_KB * 2))
PATMB=${PATMB:-96}
SPEED=${SYNC_MAX_KB:-3000}
NVEC=4096
NROWS=1024
TRIG=/sys/block/$MDNAME/md/rk_dcl_reshape
MEMBERS=()

cleanup() {
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	local d
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
}
trap cleanup EXIT

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
rk_setup_brd "$N" || exit 1
DISKS=$(rk_pick_disks "$N") || { echo "ERROR: need $N devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

cc -O2 -o "$SIM" "$SIM_SRC" -lm || { echo "ERROR: cannot build sim" >&2; exit 1; }
# OLD (create) geometry = S3's pre-shrink corruption target; NEW (shrunk)
# geometry = S2's post-shrink detection target.
"$SIM" -N $N -g $G -m $M -s $SC -b $NBASE -S $SEED -T 1 \
	--vectors "$RK_TMP/vec-old.tsv" --nvec $NVEC --nrows $NROWS \
	--rowmap "$RK_TMP/rm-old.tsv" > /dev/null || exit 1
"$SIM" -N $NEWN -g $G -m $M -s $SC -b $NBASE -S $NEWSEED -T 1 \
	--vectors "$RK_TMP/vec-new.tsv" --nvec $NVEC --nrows $NROWS \
	--rowmap "$RK_TMP/rm-new.tsv" > /dev/null || exit 1

MAXLC=$(( PATMB * 1024 / CHUNK_KB ))
pick_lc()   {	# pick_lc <vec.tsv> [not-lc] -> "lc row disk"
	awk -v max="$MAXLC" -v not="${2:--1}" \
	    '$1 !~ /^#/ && $1 < max && $1 != not && $2 >= 1 {print $1, $2, $6; exit}' "$1"
}
slice() {
	dd if="$RK_TMP/pat" bs=$((CHUNK_KB * 1024)) skip="$1" count=1 \
		of="$2" status=none
}
evict_stripes() {
	local scs
	scs=$(cat "/sys/block/$MDNAME/md/stripe_cache_size" 2>/dev/null)
	echo 17 | sudo tee "/sys/block/$MDNAME/md/stripe_cache_size" >/dev/null 2>&1
	[ -n "$scs" ] && echo "$scs" | sudo tee "/sys/block/$MDNAME/md/stripe_cache_size" >/dev/null 2>&1
}
corrupt_raw() {	# corrupt_raw <memberdev> <row>
	local dev="$1" row="$2" do_s off
	do_s=$(rk_data_offset "$dev")
	off=$(( (do_s + row * CS) * 512 ))
	sudo dd if=/dev/urandom of="$dev" bs=4096 count=1 \
		seek=$((off / 4096)) conv=notrunc oflag=direct status=none 2>/dev/null
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	evict_stripes
}
raw_matches() {	# raw_matches <memberdev> <row> <patfile> (first 4K)
	local do_s off
	do_s=$(rk_data_offset "$1")
	off=$(( (do_s + $2 * CS) * 512 ))
	sudo dd if="$1" bs=4096 count=1 skip=$((off / 4096)) \
		of="$RK_TMP/rawblk" iflag=direct status=none 2>/dev/null
	cmp -s -n 4096 "$RK_TMP/rawblk" "$3"
}
wait_trigger_idle() {	# wait_trigger_idle <tries> [kick]
	local i
	for i in $(seq 1 "$1"); do
		case "$(cat "$TRIG" 2>/dev/null)" in idle*) return 0;; esac
		[ "${2:-}" = kick ] && [ $((i % 10)) = 0 ] &&
			echo reshape | sudo tee /sys/block/$MDNAME/md/sync_action >/dev/null 2>&1
		sleep 2
	done
	return 1
}
scrub_settled() {
	local d0 i
	d0=$(sudo dmesg | grep -c "check done")
	echo check | sudo tee "/sys/block/$MDNAME/md/sync_action" >/dev/null
	for i in $(seq 1 600); do
		[ "$(sudo dmesg | grep -c 'check done')" -gt "$d0" ] && {
			cat "/sys/block/$MDNAME/md/mismatch_cnt"; return 0
		}
		sleep 0.5
	done
	echo "check-never-completed"
}
mk_array() {	# fresh --checksum dcl array on all N members + clamp
	local d cur clamp
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	for d in "${MEMBERS[@]}"; do
		sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
		sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
	sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
		--layout=declustered --group-width=$G --spare-columns=$SC \
		--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" --checksum \
		--raid-devices="$N" --run --force "${MEMBERS[@]}" >/dev/null 2>&1 &&
	   grep -q "$MDNAME : active raidkm" /proc/mdstat || return 1
	rk_wait_idle
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
	sync
	cur=$(cat /sys/block/$MDNAME/size)
	clamp=$(( cur * NEW_NG / OLD_NG ))
	sudo "$MDADM" --grow "$MD" --array-size="$(( clamp / 2 ))" >/dev/null 2>&1
	return 0
}

sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)

# ---- S1: backward shrink with --checksum ------------------------------------
echo "=== S1: create N=$N --checksum + clamp + shrink to N=$NEWN ==="
mk_array || { rk_fail "S1: create --checksum"; rk_summary; exit 1; }
rk_dmesg_clear
echo "$NEWN:$NEWSEED" | sudo tee "$TRIG" >/dev/null 2>&1 ||
	{ rk_fail "S1: trigger rejected"; rk_summary; exit 1; }
wait_trigger_idle 150 || { rk_fail "S1: shrink did not finish"; rk_summary; exit 1; }
rk_pass "S1: pool shrink completed on a --checksum array"
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none | md5sum | cut -d' ' -f1)
[ "$PRE" = "$GOT" ] && rk_pass "S1: data intact across csum shrink" \
		    || rk_fail "S1: DATA MISMATCH"
mm=$(scrub_settled)
[ "$mm" = 0 ] && rk_pass "S1: settled scrub clean" || rk_fail "S1: scrub mismatch_cnt=$mm"

# ---- S2: re-key proof --------------------------------------------------------
echo "=== S2: full read == zero mismatches; corrupt a migrated block -> detect+heal ==="
rk_dmesg_clear
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
evict_stripes
sudo dd if="$MD" of=/dev/null bs=1M iflag=direct status=none
storm=$(sudo dmesg | grep -c "native csum mismatch")
[ "$storm" = 0 ] && rk_pass "S2: full-device read, zero csum mismatches (backward re-key correct)" \
		 || rk_fail "S2: $storm csum mismatches on clean read (stale-key storm)"
read -r LC ROW DSK <<< "$(pick_lc "$RK_TMP/vec-new.tsv")"
[ -n "${LC:-}" ] || { rk_fail "S2: no usable vector"; rk_summary; exit 1; }
slice "$LC" "$RK_TMP/exp$LC"
corrupt_raw "${MEMBERS[$DSK]}" "$ROW"
# clear BEFORE the assemble: udev's own array reads during assembly can be
# what detects+heals the block — the attribution line must not be erased
rk_dmesg_clear
sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
sudo udevadm settle 2>/dev/null
sudo "$MDADM" --stop --scan 2>/dev/null; sudo udevadm settle 2>/dev/null
sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]:0:$NEWN}" >/dev/null 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat ||
	{ rk_fail "S2: survivors re-assemble failed"; rk_summary; exit 1; }
rk_rdchunk "$LC" "$RK_TMP/rb$LC"
cmp -s "$RK_TMP/rb$LC" "$RK_TMP/exp$LC" &&
	rk_pass "S2: corrupted migrated block read back exact (healed)" ||
	rk_fail "S2: read-through returned corrupt bytes (lc=$LC)"
got=$(sudo dmesg | sed -n 's/.*native csum mismatch disk \([0-9]*\) .*/\1/p' | tail -1)
[ "$got" = "$DSK" ] && rk_pass "S2: mismatch attributed to physical disk $DSK (new-key CRC live)" \
		    || rk_fail "S2: mismatch attributed to '$got', expected disk $DSK"

# ---- S3: fail-closed on pre-shrink rot ---------------------------------------
echo "=== S3: corrupt BEFORE the shrink -> band fails closed -> heal -> resumes ==="
mk_array || { rk_fail "S3: create"; rk_summary; exit 1; }
read -r LC ROW DSK <<< "$(pick_lc "$RK_TMP/vec-old.tsv")"
slice "$LC" "$RK_TMP/exp$LC"
corrupt_raw "${MEMBERS[$DSK]}" "$ROW"
rk_dmesg_clear
# NO throttle: the backward walk starts at the TOP rows and reaches the
# (low-row) poisoned chunk near the END — throttled, that takes many
# minutes.  The band cannot pass the rot (it fails closed and retries), so
# full speed converges on the mismatch in seconds.
echo "$NEWN:$NEWSEED" | sudo tee "$TRIG" >/dev/null 2>&1 ||
	{ rk_fail "S3: trigger rejected"; rk_summary; exit 1; }
hit=0
for i in $(seq 1 300); do
	sudo dmesg | grep -q "CRC mismatch on migrate read" && { hit=1; break; }
	case "$(cat "$TRIG" 2>/dev/null)" in idle*) break;; esac
	sleep 1
done
[ "$hit" = 1 ] && rk_pass "S3: migrate band failed closed on the rotted source block" \
	       || rk_fail "S3: band never reported the CRC mismatch"
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
evict_stripes
rk_rdchunk "$LC" "$RK_TMP/rb$LC"
cmp -s "$RK_TMP/rb$LC" "$RK_TMP/exp$LC" &&
	rk_pass "S3: rotted block healed through the un-migrated (old-geometry) region" ||
	rk_fail "S3: old-geometry read returned corrupt bytes"
healed=0
# async heal; budget for instrumented kernels (see the forward gate's note)
for i in $(seq 1 ${HEAL_POLL_TRIES:-480}); do
	raw_matches "${MEMBERS[$DSK]}" "$ROW" "$RK_TMP/exp$LC" && { healed=1; break; }
	sleep 0.5
done
[ "$healed" = 1 ] && rk_pass "S3: raw block rewritten on disk $DSK" \
		  || rk_fail "S3: raw block not healed"
echo 500000 | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
wait_trigger_idle 150 kick || { rk_fail "S3: shrink did not resume/finish after heal"; rk_summary; exit 1; }
rk_pass "S3: shrink resumed and completed after the heal"
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none | md5sum | cut -d' ' -f1)
[ "$PRE" = "$GOT" ] && rk_pass "S3: data intact (incl. the healed block)" \
		    || rk_fail "S3: DATA MISMATCH after heal+shrink"
mm=$(scrub_settled)
[ "$mm" = 0 ] && rk_pass "S3: settled scrub clean" || rk_fail "S3: scrub mismatch_cnt=$mm"

rk_summary
