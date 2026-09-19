#!/bin/bash
# raidkm-test-row-csum.sh — native checksum through the ROW layer (phase 4d).
#
# The row layer serves a degraded read, and rebuilds a member, outside the
# stripe cache — so it does not inherit the stripe path's CRC verify
# (raidkm_csum_verify_stripe) or its CRC store (ops_run_io).  Until phase 4d a
# --checksum array simply declined both row paths and lost the chunk-unit I/O
# the whole IU plan is about; letting it in without doing the checksum work in
# the row engine would have been worse — it would have served a decode made
# from unverified survivors.
#
# What this proves:
#   T1  a degraded read on a --checksum array IS served by the row layer
#       (rk_row_stats dread_done moves) and returns the right bytes.
#   T2  fail-closed on read: with one member failed, corrupt a SURVIVOR's 4K
#       block raw.  The row layer must refuse that row (dread_csum_bad moves)
#       instead of serving a decode built from it, and the stripe-cache
#       fallback must still return the original bytes.
#   T3  a row rebuild on a --checksum array rebuilds (rebuild_done moves), the
#       data is right, and — the part that only a stored CRC can show — a
#       healthy read of the whole array afterwards raises no csum mismatch,
#       i.e. the row engine published CRCs for every block it wrote.
#   T4  fail-closed on rebuild: a survivor block corrupted before the rebuild
#       makes the row engine decline that row (rebuild_csum_bad moves) rather
#       than decode rot onto the spare; the data still comes back correct.
#
# Usage: bash <this>     (MEMBERS/geometry via RC_N, RC_M; see raidkm-test-lib.sh)
set -u
# needle location greps the raw members and $RK_TMP is root-owned — run as root.
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

RK_CREATE_EXTRA="--checksum"
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${RC_N:-6}; M=${RC_M:-2}			# k=4 m=2 rotating
PATMB=${PATMB:-32}
NEEDLE=''
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
rk_setup_brd $((N + 1)) || exit 1		# +1 rebuild spare
DISKS=$(rk_pick_disks $((N + 1))) || { echo "ERROR: need $((N+1)) devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

# ---- helpers ---------------------------------------------------------------
row_stat() {	# row_stat <field> -> counter value (0 if absent, never empty:
		# an empty string would make every [ -gt ] below a syntax error
		# and turn a missing counter into a green run)
	local v
	v=$(sed -n "s/^$1 //p" "/sys/block/$MDNAME/md/rk_row_stats" 2>/dev/null)
	echo "${v:-0}"
}
row_knob() { echo "$2" | sudo tee "/sys/block/$MDNAME/md/$1" >/dev/null 2>&1; }
storms()   { sudo dmesg | grep -c "native csum mismatch"; }

mk_pattern() {	# one greppable needle at CHUNK/2 of row 0; unique per test
	NEEDLE="RKRCSUM-NDL-$1-"
	dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
	printf '%s' "$NEEDLE" | dd of="$RK_TMP/pat" bs=1 \
		seek=$(( CHUNK_KB * 1024 / 2 )) conv=notrunc status=none
	PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
}
write_pattern() {
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
	sync
}
read_md5() {
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null |
		md5sum | cut -d' ' -f1
}
locate_needle() {	# -> ND_DEV, ND_OFF on a raw member; skips $1 if given
	local d hit skip="${1:-}"
	ND_DEV=""; ND_OFF=""
	for d in "${MEMBERS[@]:0:$N}"; do
		[ "$d" = "$skip" ] && continue
		hit=$(sudo grep -a -b -o -m1 "$NEEDLE" "$d" 2>/dev/null | head -1)
		[ -n "$hit" ] && { ND_DEV="$d"; ND_OFF="${hit%%:*}"; return 0; }
	done
	return 1
}
K=$((N - M))				# data chunks in a row
TOKDEV=(); TOKOFF=()
mk_chunk_tokens() {	# pattern with a unique token at the head of each row-0
			# data chunk, so each LOGICAL chunk can be mapped to the
			# member holding it by grep alone (layout-agnostic)
	local c
	dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
	for c in $(seq 0 $((K - 1))); do
		printf '%s' "RKRCSUM-C$1-$c-" | dd of="$RK_TMP/pat" bs=1 \
			seek=$(( c * CHUNK_KB * 1024 + 64 )) conv=notrunc status=none
	done
	PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
}
map_chunk_tokens() {	# -> TOKDEV[c], TOKOFF[c] for every row-0 data chunk
	local c d hit
	TOKDEV=(); TOKOFF=()
	for c in $(seq 0 $((K - 1))); do
		TOKDEV[$c]=""; TOKOFF[$c]=""
		for d in "${MEMBERS[@]:0:$N}"; do
			hit=$(sudo grep -a -b -o -m1 "RKRCSUM-C$1-$c-" "$d" 2>/dev/null | head -1)
			[ -n "$hit" ] && { TOKDEV[$c]="$d"; TOKOFF[$c]="${hit%%:*}"; break; }
		done
		[ -n "${TOKDEV[$c]}" ] || return 1
	done
	return 0
}
pick_fail_dev() {	# -> FAILDEV: a member to fail that is NOT ND_DEV, so the
			# needle stays on a SURVIVOR and the decode has to read
			# it.  Which member holds row 0's needle depends on the
			# layout, so choosing before locating is a coin flip.
	local d
	FAILDEV=""
	for d in "${MEMBERS[@]:0:$N}"; do
		[ "$d" = "$ND_DEV" ] && continue
		FAILDEV="$d"; return 0
	done
	return 1
}
poison_needle() {	# corrupt the needle's 4K block raw, page-aligned
	local blk=$(( ND_OFF / 4096 ))
	sudo dd if=/dev/urandom of="$ND_DEV" bs=4096 count=1 seek="$blk" \
		conv=notrunc oflag=direct status=none 2>/dev/null
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
}

# ---- T1: degraded read served by the row layer on a --checksum array -------
echo "=== T1: degraded read through the row layer, --checksum array ==="
mk_pattern t1
rk_create "${M}r" "${MEMBERS[@]:0:$N}" || { rk_fail "T1: create --checksum"; rk_summary; exit 1; }
row_knob rk_row_dread 1
[ "$(cat "/sys/block/$MDNAME/md/rk_row_dread" 2>/dev/null)" = 1 ] \
	|| { rk_fail "T1: rk_row_dread did not take"; rk_summary; exit 1; }
write_pattern
D0=$(row_stat dread_done)
rk_fail_disks "${MEMBERS[0]}"
POST=$(read_md5)
D1=$(row_stat dread_done)
[ "$POST" = "$PRE" ] && rk_pass "T1: degraded read returned the original bytes" \
			|| rk_fail "T1: degraded read corrupted ($PRE -> $POST)"
[ "$D1" -gt "$D0" ] && rk_pass "T1: the row layer served it (dread_done $D0 -> $D1)" \
		    || rk_fail "T1: row layer never ran on a --checksum array (dread_done $D0 -> $D1)"

# ---- T2: a corrupted survivor must not be decoded from ---------------------
# Read ONLY the failed member's chunk, so the decode is FORCED to consume the
# poisoned survivor.  Reading the whole device instead is a coin flip: the
# poisoned member is healthy, so its OWN logical chunk is served by the aligned
# bypass, where verify_abio catches the rot and heals it — if that logical
# offset happens to come first, the decode later reads an already-clean
# survivor and the row layer legitimately sees nothing.  (That is how this test
# first failed: needle on ram1, failed ram0, whole-device read.)
echo "=== T2: corrupt a survivor while degraded -> row layer must fail closed ==="
mk_chunk_tokens t2
rk_create "${M}r" "${MEMBERS[@]:0:$N}" || { rk_fail "T2: create"; rk_summary; exit 1; }
row_knob rk_row_dread 1
write_pattern
map_chunk_tokens t2 || { rk_fail "T2: could not map row-0 chunks to members"; rk_summary; exit 1; }
FAILDEV="${TOKDEV[0]}"			# logical chunk 0 is the one we will decode
POISON_C=""
for c in $(seq 1 $((K - 1))); do
	[ "${TOKDEV[$c]}" = "$FAILDEV" ] && continue
	POISON_C=$c; break
done
[ -n "$POISON_C" ] || { rk_fail "T2: no survivor chunk to poison"; rk_summary; exit 1; }
ND_DEV="${TOKDEV[$POISON_C]}"; ND_OFF="${TOKOFF[$POISON_C]}"
rk_log "decoding logical chunk 0 (on $FAILDEV); poisoning chunk $POISON_C on survivor $ND_DEV"
rk_fail_disks "$FAILDEV"
poison_needle
C0=$(row_stat dread_csum_bad)
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
dd if="$RK_TMP/pat" of="$RK_TMP/t2-want" bs="${CHUNK_KB}k" count=1 status=none
sudo dd if="$MD" of="$RK_TMP/t2-got" bs="${CHUNK_KB}k" count=1 iflag=direct status=none 2>/dev/null
C1=$(row_stat dread_csum_bad)
cmp -s "$RK_TMP/t2-want" "$RK_TMP/t2-got" \
	&& rk_pass "T2: original bytes still returned (stripe-cache heal)" \
	|| rk_fail "T2: CORRUPT BYTES SERVED from a poisoned survivor"
[ "$C1" -gt "$C0" ] && rk_pass "T2: the row layer refused the row (dread_csum_bad $C0 -> $C1)" \
		    || rk_fail "T2: row layer did not notice the poisoned survivor (dread_csum_bad $C0 -> $C1; dread_done $(row_stat dread_done), raced $(row_stat dread_raced))"

# ---- T3: row rebuild publishes CRCs for what it writes ---------------------
echo "=== T3: row rebuild on a --checksum array + clean healthy read after ==="
mk_pattern t3
rk_create "${M}r" "${MEMBERS[@]:0:$N}" || { rk_fail "T3: create"; rk_summary; exit 1; }
row_knob rk_row_dread 1
row_knob rk_row_rebuild 1
[ "$(cat "/sys/block/$MDNAME/md/rk_row_rebuild" 2>/dev/null)" = 1 ] \
	|| { rk_fail "T3: rk_row_rebuild did not take"; rk_summary; exit 1; }
write_pattern
R0=$(row_stat rebuild_done)
rk_fail_disks "${MEMBERS[0]}"
rk_remove_disks "${MEMBERS[0]}"
sudo dmesg -C >/dev/null 2>&1
rk_add_disks "${MEMBERS[$N]}"		# the spare
rk_wait_full
R1=$(row_stat rebuild_done)
[ "$R1" -gt "$R0" ] && rk_pass "T3: the row engine rebuilt rows (rebuild_done $R0 -> $R1)" \
		    || rk_fail "T3: row rebuild never ran on a --checksum array (rebuild_done $R0 -> $R1)"
POST=$(read_md5)
[ "$POST" = "$PRE" ] && rk_pass "T3: data correct after the row rebuild" \
			|| rk_fail "T3: data wrong after the row rebuild ($PRE -> $POST)"
# healthy reads verify inline against the STORED CRCs: a storm here means the
# row engine wrote blocks it never published a CRC for.
S=$(storms)
[ "$S" = 0 ] && rk_pass "T3: no csum mismatch on a healthy read — CRCs were published" \
	     || rk_fail "T3: $S csum mismatches after the row rebuild (CRCs not stored for what it wrote)"

# ---- T4: a rebuild must not decode rot onto the spare ----------------------
echo "=== T4: corrupt a survivor before the rebuild -> row engine declines ==="
mk_pattern t4
rk_create "${M}r" "${MEMBERS[@]:0:$N}" || { rk_fail "T4: create"; rk_summary; exit 1; }
row_knob rk_row_dread 1
row_knob rk_row_rebuild 1
write_pattern
locate_needle || { rk_fail "T4: needle not found on any member"; rk_summary; exit 1; }
pick_fail_dev || { rk_fail "T4: no member to fail"; rk_summary; exit 1; }
rk_log "needle on $ND_DEV at byte $ND_OFF; failing $FAILDEV"
rk_fail_disks "$FAILDEV"
rk_remove_disks "$FAILDEV"
poison_needle
B0=$(row_stat rebuild_csum_bad)
rk_add_disks "${MEMBERS[$N]}"
rk_wait_full
B1=$(row_stat rebuild_csum_bad)
POST=$(read_md5)
[ "$B1" -gt "$B0" ] && rk_pass "T4: the row engine declined the rotted row (rebuild_csum_bad $B0 -> $B1)" \
		    || rk_fail "T4: row engine rebuilt from a poisoned survivor (rebuild_csum_bad $B0 -> $B1)"
[ "$POST" = "$PRE" ] && rk_pass "T4: data correct after a rebuild over rot" \
			|| rk_fail "T4: data wrong after a rebuild over rot ($PRE -> $POST)"

# ---- T5: a sub-block read on a degraded csum array must still be verified ---
# Regression test for a hole found in review, not by this suite: letting csum
# arrays into raidkm_row_read() also let them reach raid5_read_one_chunk(),
# whose completion verify (raidkm_csum_verify_abio) can only check WHOLE
# blocks -- the healthy path guards it with raidkm_csum_bio_verifiable() for
# exactly that reason.  Unguarded, a 512 B O_DIRECT read of a healthy member
# on a degraded array completes with no verification at all: the CRC loop
# never accumulates a full block, so it never reaches a compare and returns
# "clean".  Poison the block underneath it and the corruption is served.
echo "=== T5: sub-block read of a poisoned HEALTHY member, array degraded ==="
mk_pattern t5
rk_create "${M}r" "${MEMBERS[@]:0:$N}" || { rk_fail "T5: create"; rk_summary; exit 1; }
row_knob rk_row_dread 1
write_pattern
locate_needle || { rk_fail "T5: needle not found on any member"; rk_summary; exit 1; }
pick_fail_dev || { rk_fail "T5: no member to fail"; rk_summary; exit 1; }
rk_log "needle on $ND_DEV at byte $ND_OFF; failing $FAILDEV"
rk_fail_disks "$FAILDEV"		# degraded: reads now enter raidkm_row_read()
poison_needle
# the needle sits at CHUNK/2 of row 0, i.e. that logical offset on $MD, and it
# is held by the member we just poisoned -- a HEALTHY one, so this read takes
# the aligned-read bypass rather than the decode path.
NOFF=$(( CHUNK_KB * 1024 / 2 ))
# The read has to be SMALLER than one CRC block, and O_DIRECT cannot go below
# the array's logical block -- which is the widest logical block among the
# members.  On 4 KiB-logical drives the smallest read md will accept is already
# a whole CRC block, so the hole this test covers cannot be reached from
# userspace there at all.  Say so rather than fail: the premise is denied by
# the hardware, which is not the same as the guard being gone.
SUB=$(cat "/sys/block/$MDNAME/queue/logical_block_size" 2>/dev/null || echo 512)
BLK=$(cat "/sys/block/$MDNAME/md/stripe_size" 2>/dev/null || echo 4096)
if [ "$SUB" -ge "$BLK" ]; then
	rk_skip_check "T5: logical block $SUB >= CRC block $BLK, a sub-block read cannot be issued on these members"
else
	dd if="$RK_TMP/pat" of="$RK_TMP/t5-want" bs="$SUB" count=1 skip=$(( NOFF / SUB )) status=none
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo dd if="$MD" of="$RK_TMP/t5-got" bs="$SUB" count=1 skip=$(( NOFF / SUB )) \
		iflag=direct status=none 2>/dev/null
	if cmp -s "$RK_TMP/t5-want" "$RK_TMP/t5-got"; then
		rk_pass "T5: sub-block read ($SUB B) returned the original bytes (verified, then healed)"
	else
		rk_fail "T5: SUB-BLOCK READ SERVED UNVERIFIED DATA from a poisoned member"
	fi
fi

rk_summary
