#!/bin/bash
#
# raidkm-test-declustered-reshape-mdadm.sh — productized declustered pool
# expansion through the real `mdadm --grow` (not the debug rk_dcl_reshape
# trigger).  Validates the mdadm-side driver: acceptance search for the new
# pool's permutation seed, add the new pool disks as spares, and
# `mdadm --grow --raid-devices=N'` -> in-kernel COW reshape.  (Grow.c
# raidkm_dcl_grow; notes/declustered-reshape-design.md.)
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-14}; NEWN=${DCL_NEWN:-20}; G=${DCL_G:-6}; M=${DCL_M:-2}
SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}
PATMB=${PATMB:-96}

rk_load_modules || exit 1
rk_setup_brd "$NEWN" || exit 1
MEMBERS=($(rk_pick_disks "$NEWN"))

sudo "$MDADM" --stop "$MD" 2>/dev/null
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
	sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
done

echo "=== create declustered N=$N ==="
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

echo "=== add $((NEWN-N)) new pool disks as spares ==="
sudo "$MDADM" --add "$MD" "${MEMBERS[@]:$N:$((NEWN-N))}" >/dev/null 2>&1 || { rk_fail "--add spares"; rk_summary; exit 1; }
rk_pass "spares added"

echo "=== mdadm --grow --raid-devices=$NEWN ==="
out=$(sudo "$MDADM" --grow "$MD" --raid-devices=$NEWN 2>&1)
echo "$out" | sed 's/^/  /'
echo "$out" | grep -q "pool expansion N=$N->$NEWN" && rk_pass "mdadm drove the pool expansion + acceptance search" ||
	{ rk_fail "mdadm --grow did not start the expansion"; rk_summary; exit 1; }

echo "=== wait for the reshape to complete ==="
for i in $(seq 1 120); do case "$(cat /sys/block/$MDNAME/md/rk_dcl_reshape 2>/dev/null)" in idle*) break;; esac; sleep 2; done
case "$(cat /sys/block/$MDNAME/md/rk_dcl_reshape)" in idle*) rk_pass "reshape completed";;
	*) rk_fail "reshape did not finish"; rk_summary; exit 1;; esac

echo "=== verify: data + capacity + scrub + degraded-decode + geometry ==="
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
POST=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null | md5sum | cut -d' ' -f1)
[ "$PRE" = "$POST" ] && rk_pass "data intact across the mdadm grow" || rk_fail "DATA MISMATCH"
NEW_SIZE=$(cat /sys/block/$MDNAME/size)
[ "$NEW_SIZE" -gt "$OLD_SIZE" ] && rk_pass "capacity grew ($OLD_SIZE -> $NEW_SIZE sectors)" || rk_fail "capacity did not grow"
mm=$(rk_scrub); [ "$mm" = 0 ] && rk_pass "scrub clean" || rk_fail "scrub mismatch_cnt=$mm"
for d in "${MEMBERS[@]:0:$M}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
deg=$(cat /sys/block/$MDNAME/md/degraded)
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
DEG=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null | md5sum | cut -d' ' -f1)
[ "$deg" = "$M" ] && [ "$PRE" = "$DEG" ] && rk_pass "degraded-decode EC-correct (m=$M)" || rk_fail "degraded-decode (deg=$deg)"
sudo "$MDADM" --examine "${MEMBERS[0]}" | grep -q "Layout : declustered" && rk_pass "declustered geometry persisted (--examine)" || rk_fail "geometry not persisted"

sudo "$MDADM" --stop "$MD" 2>/dev/null
sudo dmesg | grep -iE "WARN|BUG|call trace|gf_invert" | tail -3 || true
rk_summary
