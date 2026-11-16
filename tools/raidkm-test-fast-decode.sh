#!/bin/bash
# raidkm-test-fast-decode.sh — the fast decode paths (fast_decode).
#
# A decode or parity re-encode row whose coefficients are all 0 or 1 is a
# plain XOR (xor_blocks) instead of GF(2^8) math.  With the Vandermonde
# generator (m <= 3) P is the XOR of the data, so one lost data block (decoded
# from the other data and P) and a lost P (re-encoded from the data) take it.
# At m = 2 a lost Q is re-encoded with raid6's gen_syndrome.  Two lost blocks,
# a lost R (m = 3) and every Cauchy row (m >= 4) keep GF math.  The raidkm
# module counts blocks done each way (decode_xor, decode_syndrome, decode_gf),
# so every case checks both the data and which path ran.  fast_decode=1 forces
# the fast paths on any CPU (its default, -1, uses them only without GFNI).
#
#   T1  m=2 rotating, one member lost: degraded read and write correct, all
#       read decodes XOR; rebuild onto a fresh member: XOR for the data and P
#       rows, syndrome for the Q rows, no GF; data and parity (scrub) correct
#   T2  m=2 parity-last, rebuild of a data member: XOR only
#   T3  m=2 parity-last, rebuild of P: XOR only; of Q: syndrome only
#   T4  m=2 rotating, two members lost: read correct, GF used
#   T5  m=3 rotating, one member lost: read XOR only, rebuild + scrub correct
#   T6  m=4 rotating (Cauchy), one member lost: read correct, GF only
#   T7  fast_decode=0: one member lost, read correct, GF only
#   T8  declustered 8+2, one member lost: population XOR + syndrome, no GF,
#       data and parity correct
#   T9  m=2 rotating rebuild through the 4 KiB stripe cache
#       (default_row_rebuild=0): XOR + syndrome, no GF; data and parity correct
#   T10 m=2 parity-last, P and Q rebuilt in one recovery: syndrome used,
#       no GF; data and parity correct
#   T11 declustered 1+2 groups (k = 1, group width 3): raid6's P+Q routines
#       need k >= 2, so resync, writes and scrub use ISA-L (async_syndrome_val
#       BUG()ed here once) and the population must not use gen_syndrome;
#       data and parity correct
#
# The counters are in 4 KiB blocks, whichever path (row or stripe) did them.
#
#   sudo bash tools/raidkm-test-fast-decode.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SZ="${SZ:-48}"
P=/sys/module/raidkm/parameters

rk_load_modules || exit 1
rk_setup_brd 12 || exit 1
[ -w $P/fast_decode ] && [ -r $P/decode_syndrome ] ||
	rk_skip "raidkm lacks fast_decode / decode_xor / decode_syndrome / decode_gf"

FD0=$(cat $P/fast_decode)
RRB0=$(cat $P/default_row_rebuild 2>/dev/null)
cleanup() {
	echo "$FD0" | sudo tee $P/fast_decode >/dev/null 2>&1
	[ -n "$RRB0" ] && echo "$RRB0" | sudo tee $P/default_row_rebuild >/dev/null 2>&1
	rk_stop
}
trap cleanup EXIT
# raidkm-test-ci.sh runs suites under timeout (SIGTERM): exit through the EXIT
# trap so fast_decode / default_row_rebuild are restored for later suites
trap 'exit 130' INT
trap 'exit 143' TERM

cnt() { echo "$(cat $P/decode_xor) $(cat $P/decode_syndrome) $(cat $P/decode_gf)"; }
CX=0 CS=0 CG=0
mark() { read -r CX CS CG < <(cnt); }
# delta: sets DX DS DG to the blocks done each way since mark
delta() {
	local x s g
	read -r x s g < <(cnt)
	DX=$((x - CX)); DS=$((s - CS)); DG=$((g - CG))
}

# rebuild <dev>: fail, remove, wipe and re-add a member; full recovery
rebuild() {
	rk_fail_disks "$1"; rk_remove_disks "$1"
	sudo "$MDADM" --zero-superblock "$1" >/dev/null 2>&1
	mark
	rk_add_disks "$1"
	rk_wait_full
	delta
}

scrub_ok() { local mm; mm=$(rk_scrub); [ "$mm" = 0 ]; }

echo 1 | sudo tee $P/fast_decode >/dev/null

# ---- T1 ---------------------------------------------------------------------
disks=$(rk_pick_disks 8)
if rk_create 2r $disks; then
	set -- $disks
	rk_write "$SZ"
	rk_fail_disks "$3"; mark
	if rk_readback "$SZ"; then rk_pass "T1 m=2 rotating: degraded read correct"
	else rk_fail "T1 m=2 rotating: degraded read CORRUPT"; fi
	delta
	if [ "$DX" -gt 0 ] && [ "$DS" = 0 ] && [ "$DG" = 0 ]; then
		rk_pass "T1 degraded read decodes by XOR only (xor $DX)"
	else
		rk_fail "T1 degraded read: expected XOR only, got xor $DX syn $DS gf $DG"
	fi
	rk_write "$SZ"
	if rk_readback "$SZ"; then rk_pass "T1 degraded write + read-back"
	else rk_fail "T1 degraded write MISMATCH"; fi
	rk_remove_disks "$3"; sudo "$MDADM" --zero-superblock "$3" >/dev/null 2>&1
	mark; rk_add_disks "$3"; rk_wait_full; delta
	if [ "$DX" -gt 0 ] && [ "$DS" -gt 0 ] && [ "$DG" = 0 ] && [ "$DX" -gt "$DS" ]; then
		rk_pass "T1 rebuild: XOR for data and P rows, syndrome for Q rows, no GF (xor $DX, syn $DS)"
	else
		rk_fail "T1 rebuild: expected mostly XOR plus some syndrome and no GF, got xor $DX syn $DS gf $DG"
	fi
	if rk_readback "$SZ" && scrub_ok; then rk_pass "T1 rebuilt array: data and parity correct"
	else rk_fail "T1 rebuilt array: data or parity WRONG"; fi
	rk_stop
else
	rk_fail "T1: create failed"
fi

# ---- T2 / T3 ----------------------------------------------------------------
disks=$(rk_pick_disks 8)
if rk_create 2 $disks; then
	set -- $disks		# parity-last: data $1..$6, P $7, Q $8
	rk_write "$SZ"
	rebuild "$2"
	if [ "$DX" -gt 0 ] && [ "$DS" = 0 ] && [ "$DG" = 0 ] && rk_readback "$SZ" && scrub_ok; then
		rk_pass "T2 m=2 parity-last, data member rebuilt by XOR only (xor $DX)"
	else
		rk_fail "T2 data member rebuild: xor $DX syn $DS gf $DG (want XOR only), or data/parity wrong"
	fi
	rebuild "$7"
	if [ "$DX" -gt 0 ] && [ "$DS" = 0 ] && [ "$DG" = 0 ] && rk_readback "$SZ" && scrub_ok; then
		rk_pass "T3 P rebuilt by XOR only (xor $DX)"
	else
		rk_fail "T3 P rebuild: xor $DX syn $DS gf $DG (want XOR only), or data/parity wrong"
	fi
	rebuild "$8"
	if [ "$DX" = 0 ] && [ "$DS" -gt 0 ] && [ "$DG" = 0 ] && rk_readback "$SZ" && scrub_ok; then
		rk_pass "T3 Q rebuilt by syndrome only (syn $DS)"
	else
		rk_fail "T3 Q rebuild: xor $DX syn $DS gf $DG (want syndrome only), or data/parity wrong"
	fi
	rk_stop
else
	rk_fail "T2: create failed"
fi

# ---- T4 ---------------------------------------------------------------------
disks=$(rk_pick_disks 8)
if rk_create 2r $disks; then
	set -- $disks
	rk_write "$SZ"
	rk_fail_disks "$2" "$5"; mark
	if rk_readback "$SZ"; then
		delta
		if [ "$DG" -gt 0 ]; then rk_pass "T4 two members lost: read correct, GF used (xor $DX, gf $DG)"
		else rk_fail "T4 two members lost: no GF decode counted (xor $DX syn $DS gf $DG)"; fi
	else
		rk_fail "T4 two members lost: read CORRUPT"
	fi
	rk_stop
else
	rk_fail "T4: create failed"
fi

# ---- T5 ---------------------------------------------------------------------
disks=$(rk_pick_disks 9)
if rk_create 3r $disks; then
	set -- $disks
	rk_write "$SZ"
	rk_fail_disks "$4"; mark
	if rk_readback "$SZ"; then
		delta
		if [ "$DX" -gt 0 ] && [ "$DS" = 0 ] && [ "$DG" = 0 ]; then
			rk_pass "T5 m=3 rotating: degraded read correct, XOR only (xor $DX)"
		else
			rk_fail "T5 m=3 degraded read: expected XOR only, got xor $DX syn $DS gf $DG"
		fi
	else
		rk_fail "T5 m=3 degraded read CORRUPT"
	fi
	rk_remove_disks "$4"; sudo "$MDADM" --zero-superblock "$4" >/dev/null 2>&1
	rk_add_disks "$4"; rk_wait_full
	if rk_readback "$SZ" && scrub_ok; then rk_pass "T5 m=3 rebuilt: data and parity correct"
	else rk_fail "T5 m=3 rebuilt: data or parity WRONG"; fi
	rk_stop
else
	rk_fail "T5: create failed"
fi

# ---- T6 ---------------------------------------------------------------------
disks=$(rk_pick_disks 10)
if rk_create 4r $disks; then
	set -- $disks
	rk_write "$SZ"
	rk_fail_disks "$1"; mark
	if rk_readback "$SZ"; then
		delta
		if [ "$DX" = 0 ] && [ "$DS" = 0 ] && [ "$DG" -gt 0 ]; then
			rk_pass "T6 m=4 (Cauchy): degraded read correct, GF only (gf $DG)"
		else
			rk_fail "T6 m=4 degraded read: expected GF only, got xor $DX syn $DS gf $DG"
		fi
	else
		rk_fail "T6 m=4 degraded read CORRUPT"
	fi
	rk_stop
else
	rk_fail "T6: create failed"
fi

# ---- T7 ---------------------------------------------------------------------
echo 0 | sudo tee $P/fast_decode >/dev/null
disks=$(rk_pick_disks 8)
if rk_create 2r $disks; then
	set -- $disks
	rk_write "$SZ"
	rk_fail_disks "$3"; mark
	if rk_readback "$SZ"; then
		delta
		if [ "$DX" = 0 ] && [ "$DS" = 0 ] && [ "$DG" -gt 0 ]; then
			rk_pass "T7 fast_decode=0: degraded read correct, GF only (gf $DG)"
		else
			rk_fail "T7 fast_decode=0: expected GF only, got xor $DX syn $DS gf $DG"
		fi
	else
		rk_fail "T7 fast_decode=0: degraded read CORRUPT"
	fi
	rk_stop
else
	rk_fail "T7: create failed"
fi
echo 1 | sudo tee $P/fast_decode >/dev/null

# ---- T8 ---------------------------------------------------------------------
disks=$(rk_pick_disks 12)
set -- $disks
rk_stop
for d in "$@"; do sudo dd if=/dev/zero of="$d" bs=1M count=4 status=none 2>/dev/null; done
if sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=2 --layout=declustered \
	--group-width=10 --spare-columns=2 --raid-devices=12 --chunk="$CHUNK_KB" \
	"$@" --run --force >/dev/null 2>&1 && rk_wait_idle; then
	rk_write "$SZ"
	rk_fail_disks "${12}"; mark
	echo 11 | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" >/dev/null 2>&1
	if rk_wait_populated; then
		delta
		if [ "$DX" -gt 0 ] && [ "$DS" -gt 0 ] && [ "$DG" = 0 ] &&
		   rk_readback "$SZ" && scrub_ok; then
			rk_pass "T8 declustered population by XOR + syndrome, no GF (xor $DX, syn $DS); data and parity correct"
		else
			rk_fail "T8 declustered population: xor $DX syn $DS gf $DG (want XOR + syndrome, no GF), or data/parity wrong"
		fi
	else
		rk_fail "T8 declustered population did not finish: $(rk_pop_show)"
	fi
	rk_stop
else
	rk_fail "T8: declustered create failed"
fi

# ---- T9 ---------------------------------------------------------------------
if [ -n "$RRB0" ]; then
	echo N | sudo tee $P/default_row_rebuild >/dev/null
	disks=$(rk_pick_disks 8)
	if rk_create 2r $disks; then
		set -- $disks
		rk_write "$SZ"
		rebuild "$4"
		if [ "$DX" -gt 0 ] && [ "$DS" -gt 0 ] && [ "$DG" = 0 ] &&
		   rk_readback "$SZ" && scrub_ok; then
			rk_pass "T9 stripe-cache rebuild: XOR + syndrome, no GF (xor $DX, syn $DS); data and parity correct"
		else
			rk_fail "T9 stripe-cache rebuild: xor $DX syn $DS gf $DG (want XOR + syndrome, no GF), or data/parity wrong"
		fi
		rk_stop
	else
		rk_fail "T9: create failed"
	fi
	echo "$RRB0" | sudo tee $P/default_row_rebuild >/dev/null
else
	rk_skip_check "T9: raidkm lacks default_row_rebuild"
fi

# ---- T10 --------------------------------------------------------------------
disks=$(rk_pick_disks 8)
if rk_create 2 $disks; then
	set -- $disks		# parity-last: P $7, Q $8
	rk_write "$SZ"
	rk_fail_disks "$7" "$8"; rk_remove_disks "$7" "$8"
	sudo "$MDADM" --zero-superblock "$7" "$8" >/dev/null 2>&1
	mark; rk_freeze_sync; rk_add_disks "$7" "$8"; rk_thaw_sync
	rk_wait_full; delta
	if [ "$DS" -gt 0 ] && [ "$DG" = 0 ] && rk_readback "$SZ" && scrub_ok; then
		rk_pass "T10 P and Q rebuilt without GF (xor $DX, syn $DS); data and parity correct"
	else
		rk_fail "T10 P+Q rebuild: xor $DX syn $DS gf $DG (want syndrome, no GF), or data/parity wrong"
	fi
	rk_stop
else
	rk_fail "T10: create failed"
fi

# ---- T11 --------------------------------------------------------------------
disks=$(rk_pick_disks 8)
set -- $disks
rk_stop
for d in "$@"; do sudo dd if=/dev/zero of="$d" bs=1M count=4 status=none 2>/dev/null; done
if sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=2 --layout=declustered \
	--group-width=3 --spare-columns=2 --raid-devices=8 --chunk="$CHUNK_KB" \
	"$@" --run --force >/dev/null 2>&1 && rk_wait_idle; then
	rk_write 16
	SZ0=$SZ; SZ=16
	if scrub_ok; then rk_pass "T11 k=1 healthy: resync, writes and scrub through ISA-L"
	else rk_fail "T11 k=1 healthy scrub found mismatches"; fi
	rk_fail_disks "$8"; mark
	echo 7 | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" >/dev/null 2>&1
	if rk_wait_populated; then
		delta
		if [ "$DS" = 0 ] && rk_readback 16 && scrub_ok; then
			rk_pass "T11 k=1 population without gen_syndrome (xor $DX, gf $DG); data and parity correct"
		else
			rk_fail "T11 k=1 population: xor $DX syn $DS gf $DG (want no syndrome), or data/parity wrong"
		fi
	else
		rk_fail "T11 k=1 population did not finish: $(rk_pop_show)"
	fi
	SZ=$SZ0
	rk_stop
else
	rk_skip_check "T11: mdadm refused a declustered group of width 3"
fi

rk_summary
