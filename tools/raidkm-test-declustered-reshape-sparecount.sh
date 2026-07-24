#!/bin/bash
#
# raidkm-test-declustered-reshape-sparecount.sh — declustered SPARE-COUNT reshape
# (change the number of distributed spare columns per row: s -> s') via the
# general geometry-transition engine.  N, g and m are all fixed, so no disk is
# added or removed (delta_disks == 0); only the layout word's s field moves,
# which changes ngroups = (N - s) / g and therefore the array capacity.
#
# A spare-count DECREASE frees spare columns into usable data columns, so
# ngroups (and capacity) grow — a forward, non-destructive reshape, tested here
# end to end.  A spare-count INCREASE shrinks capacity, which needs the
# array-size-first + backup ordering of a pool shrink and is deferred; this gate
# asserts the kernel rejects it cleanly rather than migrating over live data.
# (notes/declustered-reshape-design.md §7.)
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-20}; G=${DCL_G:-6}; M=${DCL_M:-2}
START_S=${DCL_START_S:-8}; END_S=${DCL_END_S:-2}
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}; NEWSEED=${DCL_NEWSEED:-0xdef}
PATMB=${PATMB:-64}

OLD_NG=$(( (N - START_S) / G ))
NEW_NG=$(( (N - END_S) / G ))			# s shrinks -> more groups/row
# layout word: m | DCL(0x400) | g<<16 | s<<24
NEWLAYOUT=$(printf '%x' $(( M | 0x400 | (G << 16) | (END_S << 24) )))
OLDLAYOUT=$(printf '%x' $(( M | 0x400 | (G << 16) | (START_S << 24) )))
TRIG=/sys/block/$MDNAME/md/rk_dcl_reshape

rk_load_modules || exit 1
rk_setup_brd "$N" || exit 1
MEMBERS=($(rk_pick_disks "$N"))

sudo "$MDADM" --stop "$MD" 2>/dev/null
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
	sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
done

echo "=== create declustered N=$N g=$G m=$M s=$START_S (ngroups=$OLD_NG, k=$((G-M))) ==="
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$START_S \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--raid-devices=$N "${MEMBERS[@]}" --run >/dev/null 2>&1 &&
   grep -q "$MDNAME : active" /proc/mdstat || { rk_fail "create"; rk_summary; exit 1; }
rk_wait_idle
sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
sync; PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
OLD_SIZE=$(cat /sys/block/$MDNAME/size)

echo "=== spare-count decrease: s=$START_S->$END_S (ngroups $OLD_NG->$NEW_NG), N=$N fixed (layout 0x$NEWLAYOUT) ==="
echo "$N:$NEWSEED:$NEWLAYOUT" | sudo tee "$TRIG" >/dev/null 2>&1 || { rk_fail "trigger rejected"; rk_summary; exit 1; }
for i in $(seq 1 120); do case "$(cat "$TRIG" 2>/dev/null)" in idle*) break;; esac; sleep 2; done
case "$(cat "$TRIG")" in idle*) rk_pass "spare-count reshape completed";;
	*) rk_fail "reshape did not finish"; sudo dmesg|tail -8; rk_summary; exit 1;; esac

echo "=== verify ==="
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
[ "$PRE" = "$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null|md5sum|cut -d' ' -f1)" ] &&
	rk_pass "data intact across spare-count change" || rk_fail "DATA MISMATCH"
NEW_SIZE=$(cat /sys/block/$MDNAME/size)
[ "$NEW_SIZE" -gt "$OLD_SIZE" ] &&
	rk_pass "capacity grew live ($OLD_SIZE -> $NEW_SIZE sectors, freed spares reclaimed)" ||
	rk_fail "capacity did not grow ($OLD_SIZE -> $NEW_SIZE)"
mm=$(rk_scrub); [ "$mm" = 0 ] && rk_pass "scrub clean (parity consistent over denser packing)" || rk_fail "scrub mismatch_cnt=$mm"
# decode oracle: m and k are unchanged, so failing m disks must still reconstruct
for d in "${MEMBERS[@]:0:$M}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
deg=$(cat /sys/block/$MDNAME/md/degraded)
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
DEG=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null|md5sum|cut -d' ' -f1)
[ "$deg" = "$M" ] && [ "$PRE" = "$DEG" ] &&
	rk_pass "degraded-decode m=$M EC-correct over the re-laid rows" ||
	rk_fail "degraded-decode failed (deg=$deg want $M)"
for d in "${MEMBERS[@]:0:$M}"; do sudo "$MDADM" --re-add "$MD" "$d" >/dev/null 2>&1; done
rk_wait_idle
sudo "$MDADM" --examine "${MEMBERS[0]}" | grep -q "$END_S spare column" &&
	rk_pass "new geometry persisted (--examine s=$END_S)" || rk_fail "geometry not persisted"

echo "=== reassemble: new capacity + data must persist ==="
sudo "$MDADM" --stop "$MD" 2>/dev/null; sudo udevadm settle 2>/dev/null
sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]}" >/dev/null 2>&1
[ "$(cat /sys/block/$MDNAME/size)" = "$NEW_SIZE" ] &&
	rk_pass "capacity persists across re-assemble" || rk_fail "capacity not persisted on re-assemble"
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
[ "$PRE" = "$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null|md5sum|cut -d' ' -f1)" ] &&
	rk_pass "data persists across re-assemble" || rk_fail "data lost on re-assemble"

echo "=== spare-count increase (s=$END_S->$START_S) must be rejected (capacity shrink deferred with pool shrink) ==="
if echo "$N:$NEWSEED:$OLDLAYOUT" | sudo tee "$TRIG" >/dev/null 2>&1; then
	rk_fail "capacity-shrinking spare-count increase was accepted (should be rejected)"
	for i in $(seq 1 60); do case "$(cat "$TRIG" 2>/dev/null)" in idle*) break;; esac; sleep 2; done
else
	rk_pass "spare-count increase cleanly rejected (deferred shrink path)"
fi

sudo "$MDADM" --stop "$MD" 2>/dev/null
sudo udevadm settle 2>/dev/null
for d in "${MEMBERS[@]}"; do sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
sudo udevadm settle 2>/dev/null
sudo dmesg | grep -iE "WARN|BUG|gf_invert" | tail -3 || true
rk_summary
