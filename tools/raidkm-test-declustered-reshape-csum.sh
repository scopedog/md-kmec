#!/bin/bash
#
# raidkm-test-declustered-reshape-csum.sh — declustered reshape × native
# checksum.  The band raw-reads bypass the stripe verify path and its home
# writes bypass the stripe store path, so the reshape (a) VERIFIES every
# migrated data block against its stored CRC before re-encoding — fail-closed,
# a rotted source must never be blessed into the new parity — and (b) RE-KEYS
# the row's CRCs after the home write, superseding the old-geometry CRCs the
# same (disk, blk) keys held (raidkm_dcl_reshape_verify_src / _csum_rekey).
#
#   T1  online pool expansion N->N' on a --checksum array: data intact,
#       scrub clean, capacity grew.
#   T2  re-key proof: a full-device read after the reshape reports ZERO csum
#       mismatches (no stale-key storm), and corrupting one migrated block
#       raw at its NEW physical location is detected on the right disk and
#       healed (the CRCs really live at the new keys).
#   T3  fail-closed proof: corrupt a data block raw BEFORE the reshape (no
#       intervening read) -> the migrate band detects it against the stored
#       CRC and fails ("CRC mismatch on migrate read"); heal it through the
#       array (ahead region still serves the OLD geometry), the reshape then
#       resumes and completes; data byte-exact + scrub clean.
#   T4  offline add-parity (g,m -> g+1,m+1) on a --checksum array: the layout
#       word keeps the csum bit; data intact, scrub clean, degraded-decode at
#       the NEW m, post-reshape corrupt/heal detection at the new geometry.
#   T5  the trigger REJECTS a layout word that drops the csum bit (a reshape
#       must not silently disable checksumming).
#
# Usage: bash <this>
set -u
# $RK_TMP is root-owned (gates run under sudo); the sim compile and the
# pattern-slice reads need to write/read there — re-exec as root.
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SIM_SRC="$RK_TREE/tools/declustered-sim.c"
SIM="$RK_TMP/declustered-sim"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}
NEWN=${DCL_NEWN:-20}; NEWSEED=${DCL_NEWSEED:-0xabc}
CS=$((CHUNK_KB * 2))		# chunk in sectors
PATMB=${PATMB:-96}
SPEED=${SYNC_MAX_KB:-3000}
NVEC=4096
NROWS=512
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
rk_setup_brd "$NEWN" || exit 1
DISKS=$(rk_pick_disks "$NEWN") || { echo "ERROR: need $NEWN devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

cc -O2 -o "$SIM" "$SIM_SRC" -lm || { echo "ERROR: cannot build sim" >&2; exit 1; }
# vectors for the OLD geometry (T3 pre-reshape corruption target) and the two
# NEW geometries (T2 pool-expanded, T4 add-parity) — detection targets.
"$SIM" -N $N -g $G -m $M -s $SC -b $NBASE -S $SEED -T 1 \
	--vectors "$RK_TMP/vec-old.tsv" --nvec $NVEC --nrows $NROWS \
	--rowmap "$RK_TMP/rm-old.tsv" > /dev/null || exit 1
"$SIM" -N $NEWN -g $G -m $M -s $SC -b $NBASE -S $NEWSEED -T 1 \
	--vectors "$RK_TMP/vec-new.tsv" --nvec $NVEC --nrows $NROWS \
	--rowmap "$RK_TMP/rm-new.tsv" > /dev/null || exit 1

# an lc must lie inside the base pattern (its expected bytes = a pattern
# slice) and on row >= 1 (row 0 is re-probed by udev/blkid, see the
# declustered-csum gate).  $1=lc $2=row $6=disk in vec.tsv.
MAXLC=$(( PATMB * 1024 / CHUNK_KB ))
pick_lc()   {	# pick_lc <vec.tsv> [not-lc] -> "lc row disk"
	awk -v max="$MAXLC" -v not="${2:--1}" \
	    '$1 !~ /^#/ && $1 < max && $1 != not && $2 >= 1 {print $1, $2, $6; exit}' "$1"
}
slice() {	# slice <lc> <outfile> — expected content of lc from the pattern
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
mk_array() {	# mk_array <n> — fresh --checksum dcl array on the first n members
	local d
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	for d in "${MEMBERS[@]}"; do
		sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
		sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
	sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
		--layout=declustered --group-width=$G --spare-columns=$SC \
		--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" --checksum \
		--raid-devices="$1" --run --force "${MEMBERS[@]:0:$1}" >/dev/null 2>&1 &&
	   grep -q "$MDNAME : active raidkm" /proc/mdstat || return 1
	rk_wait_idle
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
	sync
	return 0
}

sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)

# ---- T1: online pool expansion with --checksum ---------------------------------
echo "=== T1: create N=$N --checksum + write ${PATMB}MiB + expand to N=$NEWN ==="
mk_array "$N" || { rk_fail "create --checksum"; rk_summary; exit 1; }
for d in "${MEMBERS[@]:$N}"; do sudo "$MDADM" --add "$MD" "$d" >/dev/null 2>&1; done
sudo udevadm settle 2>/dev/null; sleep 1
rk_dmesg_clear
echo "$NEWN:$NEWSEED" | sudo tee "$TRIG" >/dev/null 2>&1 ||
	{ rk_fail "T1: trigger rejected"; rk_summary; exit 1; }
wait_trigger_idle 150 || { rk_fail "T1: reshape did not finish"; rk_summary; exit 1; }
rk_pass "T1: pool expansion completed on a --checksum array"
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none | md5sum | cut -d' ' -f1)
[ "$PRE" = "$GOT" ] && rk_pass "T1: data intact across csum pool expansion" \
		    || rk_fail "T1: DATA MISMATCH"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "T1: scrub clean" || rk_fail "T1: scrub mismatch_cnt=$mm"

# ---- T2: re-key proof ----------------------------------------------------------
echo "=== T2: full read == zero mismatches; corrupt a migrated block -> detect+heal ==="
rk_dmesg_clear
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
evict_stripes
sudo dd if="$MD" of=/dev/null bs=1M iflag=direct status=none
storm=$(sudo dmesg | grep -c "native csum mismatch")
[ "$storm" = 0 ] && rk_pass "T2: full-device read, zero csum mismatches (re-key correct)" \
		 || rk_fail "T2: $storm csum mismatches on clean read (stale-key storm)"
read -r LC ROW DSK <<< "$(pick_lc "$RK_TMP/vec-new.tsv")"
[ -n "${LC:-}" ] || { rk_fail "T2: no usable vector"; rk_summary; exit 1; }
slice "$LC" "$RK_TMP/exp$LC"
corrupt_raw "${MEMBERS[$DSK]}" "$ROW"
# fresh assemble so the read faults the corrupt block from disk (stripe-cache
# eviction alone proved unreliable — see the declustered-csum gate)
sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]}" >/dev/null 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat ||
	{ rk_fail "T2: re-assemble failed"; rk_summary; exit 1; }
rk_dmesg_clear
rk_rdchunk "$LC" "$RK_TMP/rb$LC"
cmp -s "$RK_TMP/rb$LC" "$RK_TMP/exp$LC" &&
	rk_pass "T2: corrupted migrated block read back exact (healed)" ||
	rk_fail "T2: read-through returned corrupt bytes (lc=$LC)"
got=$(sudo dmesg | sed -n 's/.*native csum mismatch disk \([0-9]*\) .*/\1/p' | tail -1)
[ "$got" = "$DSK" ] && rk_pass "T2: mismatch attributed to physical disk $DSK (new-key CRC live)" \
		    || rk_fail "T2: mismatch attributed to '$got', expected disk $DSK"

# ---- T3: fail-closed on pre-reshape rot ----------------------------------------
echo "=== T3: corrupt BEFORE reshape -> band fails closed -> heal -> resumes ==="
mk_array "$N" || { rk_fail "T3: create"; rk_summary; exit 1; }
read -r LC ROW DSK <<< "$(pick_lc "$RK_TMP/vec-old.tsv")"
slice "$LC" "$RK_TMP/exp$LC"
corrupt_raw "${MEMBERS[$DSK]}" "$ROW"
for d in "${MEMBERS[@]:$N}"; do sudo "$MDADM" --add "$MD" "$d" >/dev/null 2>&1; done
sudo udevadm settle 2>/dev/null; sleep 1
rk_dmesg_clear
echo "$SPEED" | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
echo "$NEWN:$NEWSEED" | sudo tee "$TRIG" >/dev/null 2>&1 ||
	{ rk_fail "T3: trigger rejected"; rk_summary; exit 1; }
hit=0
for i in $(seq 1 60); do
	sudo dmesg | grep -q "CRC mismatch on migrate read" && { hit=1; break; }
	case "$(cat "$TRIG" 2>/dev/null)" in idle*) break;; esac
	sleep 1
done
[ "$hit" = 1 ] && rk_pass "T3: migrate band failed closed on the rotted source block" \
	       || rk_fail "T3: band never reported the CRC mismatch"
# heal through the array: the un-migrated region still serves the OLD
# geometry, so a read detects + heals from the OLD parity
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
evict_stripes
rk_rdchunk "$LC" "$RK_TMP/rb$LC"
cmp -s "$RK_TMP/rb$LC" "$RK_TMP/exp$LC" &&
	rk_pass "T3: rotted block healed through the ahead (old-geometry) region" ||
	rk_fail "T3: ahead-region read returned corrupt bytes"
healed=0
# The heal rewrite is asynchronous.  The window has to cover an INSTRUMENTED
# kernel too: on KASAN+lockdep everything runs several times slower and 15s
# expired here while the heal was still in flight (the data-correctness
# assertions above had already passed).  Poll up to 60s; a genuine failure to
# heal still fails, it just is not raced by a slow kernel.
for i in $(seq 1 ${HEAL_POLL_TRIES:-120}); do
	raw_matches "${MEMBERS[$DSK]}" "$ROW" "$RK_TMP/exp$LC" && { healed=1; break; }
	sleep 0.5
done
[ "$healed" = 1 ] && rk_pass "T3: raw block rewritten on disk $DSK" \
		  || rk_fail "T3: raw block not healed"
echo 500000 | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
wait_trigger_idle 150 kick || { rk_fail "T3: reshape did not resume/finish after heal"; rk_summary; exit 1; }
rk_pass "T3: reshape resumed and completed after the heal"
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none | md5sum | cut -d' ' -f1)
[ "$PRE" = "$GOT" ] && rk_pass "T3: data intact (incl. the healed block)" \
		    || rk_fail "T3: DATA MISMATCH after heal+reshape"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "T3: scrub clean" || rk_fail "T3: scrub mismatch_cnt=$mm"

# ---- T4 + T5: offline add-parity with csum; csum-bit-drop rejected -------------
echo "=== T4/T5: offline add-parity g=$G,m=$M -> g=$((G+1)),m=$((M+1)) with csum ==="
mk_array "$N" || { rk_fail "T4: create"; rk_summary; exit 1; }
NG=$(( (N - SC) / G )); APN=$((N + NG)); APG=$((G + 1)); APM=$((M + 1))
APSEED=0xdef
BADLAY=$(printf '%x' $(( APM | 0x400 | (APG<<16) | (SC<<24) )))          # csum bit DROPPED
APLAY=$(printf '%x'  $(( APM | 0x400 | 0x200 | (APG<<16) | (SC<<24) )))  # csum bit kept
for d in "${MEMBERS[@]:$N:$NG}"; do sudo "$MDADM" --add "$MD" "$d" >/dev/null 2>&1; done
sudo udevadm settle 2>/dev/null; sleep 1
echo "$APN:$APSEED:$BADLAY" | sudo tee "$TRIG" >/dev/null 2>&1 &&
	rk_fail "T5: trigger ACCEPTED a layout word that drops the csum bit" ||
	rk_pass "T5: csum-bit-dropping layout word rejected"
echo "$APN:$APSEED:$APLAY" | sudo tee "$TRIG" >/dev/null 2>&1 ||
	{ rk_fail "T4: add-parity trigger rejected"; rk_summary; exit 1; }
wait_trigger_idle 150 || { rk_fail "T4: add-parity did not finish"; rk_summary; exit 1; }
rk_pass "T4: offline add-parity completed on a --checksum array"
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none | md5sum | cut -d' ' -f1)
[ "$PRE" = "$GOT" ] && rk_pass "T4: data intact" || rk_fail "T4: DATA MISMATCH"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "T4: scrub clean" || rk_fail "T4: scrub mismatch_cnt=$mm"
sudo "$MDADM" --examine "${MEMBERS[0]}" 2>/dev/null | grep -q "crc32c" &&
	rk_pass "T4: checksum survived the reshape (--examine crc32c)" ||
	rk_fail "T4: checksum flag lost across the reshape"
# detection at the new geometry
"$SIM" -N $APN -g $APG -m $APM -s $SC -b $NBASE -S $APSEED -T 1 \
	--vectors "$RK_TMP/vec-ap.tsv" --nvec $NVEC --nrows $NROWS \
	--rowmap "$RK_TMP/rm-ap.tsv" > /dev/null || exit 1
read -r LC ROW DSK <<< "$(pick_lc "$RK_TMP/vec-ap.tsv")"
slice "$LC" "$RK_TMP/exp$LC"
corrupt_raw "${MEMBERS[$DSK]}" "$ROW"
sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]:0:$APN}" >/dev/null 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat ||
	{ rk_fail "T4: re-assemble failed"; rk_summary; exit 1; }
rk_dmesg_clear
rk_rdchunk "$LC" "$RK_TMP/rb$LC"
cmp -s "$RK_TMP/rb$LC" "$RK_TMP/exp$LC" &&
	rk_pass "T4: corrupt block at the new geometry detected + healed" ||
	rk_fail "T4: read-through corrupt at new geometry (lc=$LC)"
# degraded-decode at the NEW m
for d in "${MEMBERS[@]:0:$APM}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
deg=$(cat /sys/block/$MDNAME/md/degraded)
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none | md5sum | cut -d' ' -f1)
[ "$deg" = "$APM" ] && [ "$PRE" = "$GOT" ] &&
	rk_pass "T4: degraded-decode at m=$APM EC-correct" ||
	rk_fail "T4: degraded-decode failed (degraded=$deg)"

sudo dmesg | grep -iE "WARN|BUG|call trace|gf_invert" | tail -5
rk_summary
