#!/bin/bash
#
# raidkm-test-reshape-csum.sh — CLASSIC (non-declustered) reshape × native
# checksum.  The COW band's raw reads bypass the stripe verify path and its
# home writes bypass the stripe store path, and BOTH classic kinds move every
# block to a new (disk, block) CRC key (add-parity rotates slots between
# disks at the same sector; add-data moves rows too).  So the band must
# (a) VERIFY each migrated source block against its stored CRC — fail-closed,
# a rotted source must never be blessed into the new parity — and (b) RE-KEY
# the row's CRCs after the home write (raidkm_reshape_verify_src /
# raidkm_reshape_csum_rekey, shared with the declustered band).
#
#   T1  ONLINE add-parity (m=2->3, rotating) on a --checksum array: data
#       intact, scrub clean, and a full direct re-read reports ZERO csum
#       mismatches (re-key proof — without it every migrated key is stale).
#       Decode oracle at the NEW m.
#   T2  fail-closed proof: corrupt one data block raw on a member BEFORE the
#       reshape (no intervening read) -> the migrate band detects it against
#       the stored CRC ("CRC mismatch on migrate read") and makes no
#       progress; heal it through the array (read -> reconstruct+rewrite);
#       the reshape then completes; data byte-exact, zero further mismatches.
#   T3  ONLINE add-data (k=4->5, rotating) on a --checksum array: capacity
#       grew, data intact, scrub clean, zero mismatches on full re-read.
#   T4  post-reshape detection: corrupt the (relocated) needle block raw at
#       its NEW location -> a direct read detects and heals it (the CRCs
#       really live at the new keys).
#
# Usage: bash <this>
set -u
# needle location greps the raw members and $RK_TMP is root-owned — run as root.
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

RK_CREATE_EXTRA="--checksum"
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${RC_N:-6}; M=${RC_M:-2}			# k=4 m=2 rotating
PATMB=${PATMB:-32}
NEEDLE=''	# set per test by mk_pattern — a reused token would ghost-match
		# stale copies on the raw members (head-only wipe at re-create;
		# add-data leaves the vacated old rows unscrubbed)
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
rk_setup_brd $((N + 2)) || exit 1		# +1 add-parity, +1 add-data
DISKS=$(rk_pick_disks $((N + 2))) || { echo "ERROR: need $((N+2)) devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

storms()   { sudo dmesg | grep -c "native csum mismatch"; }
migrerrs() { sudo dmesg | grep -c "CRC mismatch on migrate read"; }

# pattern with one needle at logical offset CHUNK/2 of row 0 (unique per test,
# greppable on exactly one member's raw device — layout-agnostic, no placement
# math).  $1 = tag making this test's token unique.
mk_pattern() {
	NEEDLE="RKRC-NDL-$1-"
	dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
	printf '%s' "$NEEDLE" | dd of="$RK_TMP/pat" bs=1 \
		seek=$(( CHUNK_KB * 1024 / 2 )) conv=notrunc status=none
}
write_pattern() {
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
	sync
	PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
}
read_md5() {
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null |
		md5sum | cut -d' ' -f1
}
locate_needle() {	# -> ND_DEV, ND_OFF (byte offset on the raw member)
	local d hit
	ND_DEV=""; ND_OFF=""
	for d in "${MEMBERS[@]}"; do
		hit=$(sudo grep -a -b -o -m1 "$NEEDLE" "$d" 2>/dev/null | head -1)
		[ -n "$hit" ] && { ND_DEV="$d"; ND_OFF="${hit%%:*}"; return 0; }
	done
	return 1
}
poison_needle() {	# corrupt the needle's 4K block raw, page-aligned
	local blk=$(( ND_OFF / 4096 ))
	sudo dd if=/dev/urandom of="$ND_DEV" bs=4096 count=1 seek="$blk" \
		conv=notrunc oflag=direct status=none 2>/dev/null
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
}

# ---- T1: online add-parity (rotating) with --checksum -----------------------
echo "=== T1: create k=$((N-M)) m=$M rotating --checksum + add-parity -> m=$((M+1)) ==="
mk_pattern t1
rk_create "${M}r" "${MEMBERS[@]:0:$N}" || { rk_fail "T1: create --checksum"; rk_summary; exit 1; }
write_pattern
S0=$(storms)
rk_grow_parity "${MEMBERS[$N]}" || { rk_fail "T1: add-parity failed"; rk_summary; exit 1; }
rk_pass "T1: online add-parity completed on a --checksum array"
[ "$PRE" = "$(read_md5)" ] && rk_pass "T1: data intact" || rk_fail "T1: DATA MISMATCH"
sudo dd if="$MD" of=/dev/null bs=1M iflag=direct status=none 2>/dev/null
storm=$(( $(storms) - S0 ))
[ "$storm" = 0 ] && rk_pass "T1: zero csum mismatches on full re-read (re-key correct)" \
		 || rk_fail "T1: $storm csum mismatches (stale-key storm — re-key broken)"
mm=$(rk_scrub); [ "$mm" = 0 ] && rk_pass "T1: scrub clean" || rk_fail "T1: scrub mismatch_cnt=$mm"
for d in "${MEMBERS[@]:0:$((M+1))}"; do
	sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1
done
[ "$PRE" = "$(read_md5)" ] && rk_pass "T1: degraded-decode at m=$((M+1)) EC-correct" \
			   || rk_fail "T1: degraded read wrong at new m"

# ---- T2: pre-reshape corruption -> band fails closed -> heal -> completes ---
echo "=== T2: poison BEFORE add-parity -> fail-closed -> heal -> resume ==="
mk_pattern t2
rk_create "${M}r" "${MEMBERS[@]:0:$N}" || { rk_fail "T2: create"; rk_summary; exit 1; }
write_pattern
locate_needle || { rk_fail "T2: needle not found on raw members"; rk_summary; exit 1; }
poison_needle
E0=$(migrerrs); S0=$(storms)
# throttle so the failing band is observable before we heal
echo 2000 | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
sudo "$MDADM" --grow "$MD" --add-parity --backup-file="$RK_BACKUP" \
	"${MEMBERS[$N]}" >/dev/null 2>&1 || { rk_fail "T2: add-parity trigger failed"; rk_summary; exit 1; }
fc=0
for i in $(seq 1 60); do
	[ "$(migrerrs)" -gt "$E0" ] && { fc=1; break; }
	sleep 1
done
[ "$fc" = 1 ] && rk_pass "T2: migrate band failed closed on the rotted source" \
	      || rk_fail "T2: no 'CRC mismatch on migrate read' (verify-src not engaged)"
grep -q "reshape" /proc/mdstat && rk_pass "T2: reshape held (no progress past the rotted band)" \
			       || rk_fail "T2: reshape not running/already done despite rot"
# heal: read the needle's logical block through the array (recheck-then-heal)
sudo dd if="$MD" of=/dev/null bs=1M count=1 iflag=direct status=none 2>/dev/null
echo 2000000 | sudo tee /sys/block/$MDNAME/md/sync_speed_max >/dev/null
rk_wait_idle
grep -q "reshape" /proc/mdstat && { rk_fail "T2: reshape did not complete after the heal"; rk_summary; exit 1; }
rk_pass "T2: reshape resumed and completed after the heal"
[ "$PRE" = "$(read_md5)" ] && rk_pass "T2: data intact (incl. the healed block)" \
			   || rk_fail "T2: DATA MISMATCH after heal+reshape"
sudo dd if="$MD" of=/dev/null bs=1M iflag=direct status=none 2>/dev/null
mm=$(rk_scrub); [ "$mm" = 0 ] && rk_pass "T2: scrub clean" || rk_fail "T2: scrub mismatch_cnt=$mm"

# ---- T3: online add-data (rotating) with --checksum --------------------------
echo "=== T3: add-data k=$((N-M)) -> $((N-M+1)) on --checksum (rows relocate) ==="
mk_pattern t3
rk_create "${M}r" "${MEMBERS[@]:0:$N}" || { rk_fail "T3: create"; rk_summary; exit 1; }
write_pattern
OLD_SIZE=$(cat /sys/block/$MDNAME/size)
S0=$(storms)
rk_grow_data "${MEMBERS[$((N+1))]}" || { rk_fail "T3: add-data failed"; rk_summary; exit 1; }
rk_pass "T3: online add-data completed on a --checksum array"
NEW_SIZE=$(cat /sys/block/$MDNAME/size)
[ "$NEW_SIZE" -gt "$OLD_SIZE" ] && rk_pass "T3: capacity grew ($OLD_SIZE -> $NEW_SIZE)" \
				|| rk_fail "T3: capacity did not grow"
[ "$PRE" = "$(read_md5)" ] && rk_pass "T3: data intact" || rk_fail "T3: DATA MISMATCH"
sudo dd if="$MD" of=/dev/null bs=1M iflag=direct status=none 2>/dev/null
storm=$(( $(storms) - S0 ))
[ "$storm" = 0 ] && rk_pass "T3: zero csum mismatches on full re-read (re-key correct)" \
		 || rk_fail "T3: $storm csum mismatches (stale-key storm)"
mm=$(rk_scrub); [ "$mm" = 0 ] && rk_pass "T3: scrub clean" || rk_fail "T3: scrub mismatch_cnt=$mm"

# ---- T4: post-reshape detection at the NEW keys ------------------------------
# T3's add-data left the vacated old rows unscrubbed, so the t3 token exists at
# BOTH its live (new) and stale (old) raw locations — grep can't tell them
# apart.  Write a FRESH token through the array instead: it exists only at the
# live post-reshape placement, and the write stores its CRC at the new key.
echo "=== T4: poison the relocated needle -> detect + heal at the new key ==="
NEEDLE="RKRC-NDL-t4-"
printf '%s' "$NEEDLE" | dd of="$RK_TMP/pat" bs=1 \
	seek=$(( CHUNK_KB * 1024 / 2 )) conv=notrunc status=none
PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
sudo dd if="$RK_TMP/pat" of="$MD" bs=$(( CHUNK_KB * 1024 )) count=1 \
	oflag=direct conv=notrunc status=none
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
locate_needle || { rk_fail "T4: fresh needle not found post-reshape"; rk_summary; exit 1; }
S0=$(storms)
poison_needle
# evict the stripe cache so the next read hits the disk, not a cached page
scs=$(cat /sys/block/$MDNAME/md/stripe_cache_size 2>/dev/null)
echo 17 | sudo tee /sys/block/$MDNAME/md/stripe_cache_size >/dev/null 2>&1
[ -n "$scs" ] && echo "$scs" | sudo tee /sys/block/$MDNAME/md/stripe_cache_size >/dev/null 2>&1
[ "$PRE" = "$(read_md5)" ] && rk_pass "T4: poisoned block read back exact (detected + healed)" \
			   || rk_fail "T4: corrupt bytes served (detection at new key broken)"
[ "$(storms)" -gt "$S0" ] && rk_pass "T4: mismatch was DETECTED (not silently served)" \
			  || rk_fail "T4: no csum mismatch logged for a genuinely rotted block"

sudo dmesg | grep -iE "WARN|BUG|call trace|gf_invert" | tail -5 || true
rk_summary
