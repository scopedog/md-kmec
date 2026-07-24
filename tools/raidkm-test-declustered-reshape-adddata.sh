#!/bin/bash
#
# raidkm-test-declustered-reshape-adddata.sh — declustered ADD-DATA reshape
# (raise k within each group: k -> k+1, g -> g+1) via the general geometry-
# transition engine.  Adds ngroups disks (one new DATA column per group), so m
# and ngroups stay fixed while capacity grows by one column per group; the group
# EC tables are rebuilt for the new k.  Driven through the rk_dcl_reshape trigger
# with an explicit new layout word (the mdadm --add-data driver is a follow-up).
# (notes/declustered-reshape-design.md §7.)
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}; NEWSEED=${DCL_NEWSEED:-0xdef}
PATMB=${PATMB:-64}

NGROUPS=$(( (N - SC) / G ))
NEWN=$(( N + NGROUPS ))				# one new data column per group
NEWG=$(( G + 1 ))				# m unchanged -> k rises by 1
NEWLAYOUT=$(printf '%x' $(( M | 0x400 | (NEWG << 16) | (SC << 24) )))
TRIG=/sys/block/$MDNAME/md/rk_dcl_reshape

rk_load_modules || exit 1
rk_setup_brd "$NEWN" || exit 1
MEMBERS=($(rk_pick_disks "$NEWN"))

sudo "$MDADM" --stop "$MD" 2>/dev/null
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
	sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
done

echo "=== create declustered N=$N g=$G m=$M s=$SC (ngroups=$NGROUPS, k=$((G-M))) ==="
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--raid-devices=$N "${MEMBERS[@]:0:$N}" --run >/dev/null 2>&1 &&
   grep -q "$MDNAME : active" /proc/mdstat || { rk_fail "create"; rk_summary; exit 1; }
rk_wait_idle
sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
sync; PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
OLD_SIZE=$(cat /sys/block/$MDNAME/size)

echo "=== add-data: +$NGROUPS disks, k=$((G-M))->$((NEWG-M)) g=$G->$NEWG m=$M N=$N->$NEWN (layout 0x$NEWLAYOUT) ==="
sudo "$MDADM" --add "$MD" "${MEMBERS[@]:$N:$NGROUPS}" >/dev/null 2>&1
# settle udev's scan of the freshly-added members so the offline-only trigger
# check does not see a transient blkid open (and no stale-SB auto-assemble race)
sudo udevadm settle 2>/dev/null; sleep 1
echo "$NEWN:$NEWSEED:$NEWLAYOUT" | sudo tee "$TRIG" >/dev/null 2>&1 || { rk_fail "trigger rejected"; rk_summary; exit 1; }
for i in $(seq 1 120); do case "$(cat "$TRIG" 2>/dev/null)" in idle*) break;; esac; sleep 2; done
case "$(cat "$TRIG")" in idle*) rk_pass "add-data reshape completed";;
	*) rk_fail "reshape did not finish"; sudo dmesg|tail -8; rk_summary; exit 1;; esac

echo "=== verify ==="
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
[ "$PRE" = "$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null|md5sum|cut -d' ' -f1)" ] &&
	rk_pass "data intact across add-data" || rk_fail "DATA MISMATCH"
[ "$(cat /sys/block/$MDNAME/size)" -gt "$OLD_SIZE" ] &&
	rk_pass "capacity grew ($OLD_SIZE -> $(cat /sys/block/$MDNAME/size) sectors)" || rk_fail "capacity did not grow"
mm=$(rk_scrub); [ "$mm" = 0 ] && rk_pass "scrub clean (new k parity consistent)" || rk_fail "scrub mismatch_cnt=$mm"
for d in "${MEMBERS[@]:0:$M}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
deg=$(cat /sys/block/$MDNAME/md/degraded)
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
DEG=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null|md5sum|cut -d' ' -f1)
[ "$deg" = "$M" ] && [ "$PRE" = "$DEG" ] &&
	rk_pass "degraded-decode m=$M EC-correct over the widened groups" ||
	rk_fail "degraded-decode failed (deg=$deg want $M)"
sudo "$MDADM" --examine "${MEMBERS[0]}" | grep -q "g=$NEWG (k=$((NEWG-M))+m=$M)" &&
	rk_pass "new geometry persisted (--examine g=$NEWG k=$((NEWG-M)))" || rk_fail "geometry not persisted"

sudo "$MDADM" --stop "$MD" 2>/dev/null
sudo udevadm settle 2>/dev/null
for d in "${MEMBERS[@]}"; do sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
sudo udevadm settle 2>/dev/null
sudo dmesg | grep -iE "WARN|BUG|gf_invert" | tail -3 || true
rk_summary
