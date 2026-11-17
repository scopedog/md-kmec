#!/bin/bash
#
# raidkm-test-declustered-create.sh — Phase 1b gate: declustered create/SB
# plumbing end-to-end (design doc §6 / §9 Phase 1b).
#
# What this proves:
#   1. mdadm --create --layout=declustered runs the acceptance search, packs
#      the geometry into the layout word, writes the rkdcl metadata block on
#      every member — and the KERNEL REFUSES ACTIVATION with the documented
#      Phase-1b message (the I/O path lands in 1c), so the create exits
#      non-zero without ever running an array that would misread the layout.
#   2. mdadm's accepted seed is IDENTICAL to the reference simulator's for the
#      same geometry and search defaults (base seed 1, 64 tries) — the mdadm
#      port of the map core + scoring is bit-faithful.
#   3. --examine round-trips the geometry (Layout: declustered + g/k/m/s).
#   4. The on-disk rkdcl metadata block at data_offset + data_size carries the
#      magic and the accepted seed.
#   5. An illegal geometry (C1 violation) is refused by mdadm before any
#      device is touched.
#   6. A declustered pool with --consistency-policy=ppl is refused by the
#      kernel (PPL is refused on every raidkm array since 2026-11-16, see
#      raidkm-test-ppl-refused.sh), and the array never runs.
#   7. Likewise --write-journal: journal replay maps a logged stripe by row
#      sector and slot index only (no group, no permutation map).
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SIM_SRC="$RK_TREE/tools/declustered-sim.c"
SIM="$RK_TMP/declustered-sim"

N=14; G=6; M=2; SC=2; NBASE=16
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
# +1 ram disk for case 7's journal; a real-device rig (RK_DEVS) only needs N,
# and case 7 skips itself when there is no spare device
if [ -n "${RK_DEVS:-}" ]; then rk_setup_brd "$N"; else rk_setup_brd $((N + 1)); fi || exit 1
DISKS=$(rk_pick_disks "$N") || { echo "ERROR: need $N ramdisks" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

cc -O2 -o "$SIM" "$SIM_SRC" -lm || {
	echo "ERROR: cannot build $SIM_SRC" >&2; exit 1; }

# ---- 1. create: search runs, SBs written, kernel refuses activation --------
rk_dmesg_clear
out=$(sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --chunk="$CHUNK_KB" --raid-devices=$N \
	"${MEMBERS[@]}" --run --force 2>&1)
rc=$?
# 1c step 3: the declustered I/O path is live — create ACTIVATES now.
if [ $rc -eq 0 ] && grep -q "md70 : active raidkm" /proc/mdstat; then
	rk_pass "declustered array created and ACTIVE"
else
	rk_fail "create failed or array not active (rc=$rc)"
	sudo dmesg | tail -5 | sed 's/^/      · /'
fi
# array capacity must be rows * ngroups * k data columns
ud0=$(sudo "$MDADM" --examine "${MEMBERS[0]}" 2>/dev/null | sed -n 's/.*Avail Dev Size : \([0-9]*\) sectors.*/\1/p')
exp_bytes=$(( (ud0 / (CHUNK_KB * 2)) * (CHUNK_KB * 2) * 512 * ((N - SC) / G) * (G - M) ))
got_bytes=$(sudo blockdev --getsize64 "$MD")
if [ "$got_bytes" = "$exp_bytes" ]; then
	rk_pass "array size = rows * ngroups * k ($got_bytes bytes)"
else
	rk_fail "array size $got_bytes != expected $exp_bytes"
fi
rk_wait_idle	# let the initial resync (group-looped sync path) finish
sudo "$MDADM" --stop "$MD" 2>/dev/null
# Phase 1c step 1: the kernel must have LOADED the rkdcl block before the
# refuse — dmesg carries the loaded seed + regenerated PERM crc.
kload=$(sudo dmesg | sed -n 's/.*declustered geometry loaded: \(.*\)/\1/p' | tail -1)
kseed=$(sed -n 's/.*seed=\(0x[0-9a-f]*\).*/\1/p' <<< "$kload")
kcrc=$(sed -n 's/.*perm_crc=\(0x[0-9a-f]*\).*/\1/p' <<< "$kload")
if [ -n "$kseed" ]; then
	rk_pass "kernel loaded the rkdcl block (seed $kseed, perm_crc $kcrc)"
else
	rk_fail "kernel did not log a loaded declustered geometry"
fi

mdseed=$(sed -n 's/.*acceptance search: seed \(0x[0-9a-f]*\).*/\1/p' <<< "$out")
if [ -n "$mdseed" ]; then
	rk_pass "mdadm ran the acceptance search (seed $mdseed)"
else
	rk_fail "mdadm did not report an accepted seed"
	sed 's/^/      · /' <<< "$out" | head -6
fi

# ---- 2. seed parity with the reference simulator ----------------------------
simout=$("$SIM" -N $N -g $G -m $M -s $SC -b $NBASE -S 1 -T 64)
simseed=$(sed -n 's/.*accepted seed \(0x[0-9a-f]*\) .*/\1/p' <<< "$simout")
simcrc=$(sed -n 's/.*PERM crc32 \(0x[0-9a-f]*\)).*/\1/p' <<< "$simout")
if [ -n "$simseed" ] && [ "$((mdseed))" = "$((simseed))" ]; then
	rk_pass "mdadm seed == simulator seed ($simseed)"
else
	rk_fail "seed mismatch: mdadm=$mdseed sim=$simseed"
fi
# three-way pin: the kernel regenerated the SAME permutation set from the
# on-disk seed as the simulator did (and mdadm searched) — seed AND crc.
if [ -n "$kseed" ] && [ "$((kseed))" = "$((simseed))" ] && \
   [ -n "$kcrc" ] && [ "$((kcrc))" = "$((simcrc))" ]; then
	rk_pass "kernel-loaded seed+perm_crc == simulator ($simcrc)"
else
	rk_fail "kernel/sim mismatch: kseed=$kseed kcrc=$kcrc simcrc=$simcrc"
fi

# ---- 3. --examine geometry round-trip ---------------------------------------
ex=$(sudo "$MDADM" --examine "${MEMBERS[0]}" 2>/dev/null)
grep -q "Layout : declustered" <<< "$ex" \
	&& rk_pass "examine: Layout : declustered" \
	|| rk_fail "examine: missing declustered layout line"
grep -q "Declustered : g=$G (k=$((G-M))+m=$M), $SC spare column(s)/row" <<< "$ex" \
	&& rk_pass "examine: geometry line g=$G k=$((G-M)) m=$M s=$SC" \
	|| { rk_fail "examine: geometry line wrong/missing"; \
	     grep -i declustered <<< "$ex" | sed 's/^/      · /'; }

# ---- 4. on-disk rkdcl metadata block ----------------------------------------
do_s=$(sed -n 's/.*Data Offset : \([0-9]*\) sectors.*/\1/p' <<< "$ex")
# The block sits at data_offset + sb->data_size.  examine prints data_size as
# "Avail Dev Size"; "Used Dev Size" (sb->size) appears only when it differs —
# on identical members they coincide and the Used line is omitted entirely.
ud_s=$(sed -n 's/.*Used Dev Size : \([0-9]*\) sectors.*/\1/p' <<< "$ex")
[ -z "$ud_s" ] && ud_s=$(sed -n 's/.*Avail Dev Size : \([0-9]*\) sectors.*/\1/p' <<< "$ex")
if [ -n "$do_s" ] && [ -n "$ud_s" ]; then
	off=$(( (do_s + ud_s) * 512 ))
	magic=$(sudo dd if="${MEMBERS[0]}" bs=1 skip=$off count=8 status=none | tr -d '\0')
	[ "$magic" = "RKDCLMD1" ] \
		&& rk_pass "rkdcl metadata block magic at data_offset+data_size" \
		|| rk_fail "rkdcl metadata magic missing (got '$magic' at $off)"
	blkseed=0x$(sudo od -A n -t x8 -j $((off + 40)) -N 8 "${MEMBERS[0]}" | tr -d ' ')
	[ "$((blkseed))" = "$((mdseed))" ] \
		&& rk_pass "metadata block seed matches accepted seed" \
		|| rk_fail "metadata block seed $blkseed != accepted $mdseed"
else
	rk_fail "could not parse Data Offset / Used Dev Size from examine"
fi

# ---- 5. illegal geometry refused by mdadm before touching disks -------------
sudo "$MDADM" --zero-superblock "${MEMBERS[@]}" 2>/dev/null
bad=$(sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=3 \
	--chunk="$CHUNK_KB" --raid-devices=$N "${MEMBERS[@]}" --run --force 2>&1)
if [ $? -ne 0 ] && grep -q "(N - s) % g" <<< "$bad"; then
	rk_pass "C1-violating geometry refused with the diagnostic + suggestion"
else
	rk_fail "C1 violation not refused cleanly"
	sed 's/^/      · /' <<< "$bad" | head -4
fi
if sudo "$MDADM" --examine "${MEMBERS[0]}" 2>/dev/null | grep -q declustered; then
	rk_fail "illegal create still wrote a superblock"
else
	rk_pass "illegal create left no superblock behind"
fi

# ---- 6. PPL on a declustered pool refused by the kernel ---------------------
sudo "$MDADM" --zero-superblock "${MEMBERS[@]}" 2>/dev/null
rk_dmesg_window_close
rk_dmesg_clear
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --chunk="$CHUNK_KB" --raid-devices=$N \
	--consistency-policy=ppl "${MEMBERS[@]}" --run --force >/dev/null 2>&1
if grep -q "^$MDNAME : active" /proc/mdstat; then
	rk_fail "declustered pool with PPL is ACTIVE (must be refused)"
	sudo "$MDADM" --stop "$MD" 2>/dev/null
elif sudo dmesg | grep -q "PPL is not supported on raidkm"; then
	rk_pass "declustered pool with --consistency-policy=ppl refused by the kernel"
else
	rk_fail "declustered PPL create not active, but no refusal message"
	sudo dmesg | tail -4 | sed 's/^/      · /'
fi
sudo "$MDADM" --stop "$MD" 2>/dev/null
sudo "$MDADM" --zero-superblock "${MEMBERS[@]}" 2>/dev/null

# ---- 7. write journal on a declustered pool refused by the kernel -----------
JDEV=$(rk_pick_disks $((N + 1)) 2>/dev/null | awk '{print $NF}')
if [ -z "$JDEV" ]; then
	rk_skip_check "no spare device for a journal (need $((N + 1)))"
else
	rk_dmesg_window_close
	rk_dmesg_clear
	sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
		--layout=declustered --group-width=$G --spare-columns=$SC \
		--dcl-nbase=$NBASE --chunk="$CHUNK_KB" --raid-devices=$N \
		--write-journal="$JDEV" "${MEMBERS[@]}" --run --force >/dev/null 2>&1
	if grep -q "^$MDNAME : active" /proc/mdstat; then
		rk_fail "declustered pool with a write journal is ACTIVE (must be refused)"
	elif sudo dmesg | grep -q "write journal is not compatible with a declustered layout"; then
		rk_pass "declustered pool with --write-journal refused by the kernel"
	else
		rk_fail "declustered journal create not active, but no refusal message"
		sudo dmesg | tail -4 | sed 's/^/      · /'
	fi
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	sudo "$MDADM" --zero-superblock "${MEMBERS[@]}" "$JDEV" 2>/dev/null
fi

rk_dmesg_window_close
[ "$RK_DMESG_BAD" = 0 ] && rk_pass "no kernel WARN/BUG during the run (all windows)" \
			|| rk_fail "kernel WARN/BUG in a window the suite cleared"
rk_summary
