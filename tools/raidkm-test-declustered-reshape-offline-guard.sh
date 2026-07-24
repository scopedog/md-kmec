#!/bin/bash
#
# raidkm-test-declustered-reshape-offline-guard.sh — enforce the OFFLINE-ONLY
# policy for group-geometry-transition declustered reshapes (add-parity,
# add-data, spare-count: every reshape that changes the layout word).
#
# The dcl stripe path is single-geometry, so concurrent I/O to the un-migrated
# region during such a reshape is unsafe (add-parity/add-data would corrupt it).
# The whole layout-changing class is therefore gated offline: the rk_dcl_reshape
# trigger refuses to start one while the array has any open handle (mount / open
# writer) — a single uniform check (`new_layout != layout && openers > 0`), so
# proving it for one variant proves it for all three.  As a fail-safe against a
# mount that slips in AFTER the reshape starts, a g/m-changing reshape errors
# (never mis-encodes) ahead-region I/O.  A pure pool expansion keeps the layout
# word and stays fully online (covered by its own concurrent gate).
#
# This gate proves: (1) an add-parity reshape is rejected while the array is in
# use and no reshape starts; (2) the same reshape succeeds — correctly — once
# the array is idle again.  (notes/declustered-reshape-design.md §7.)
set -u
# The busy-holder below opens $MD directly (a shell fd, not via sudo), so this
# gate needs root — an unprivileged open fails silently and the gate false-fails
# ("reshape STARTED with the array in use").  Re-exec under sudo.
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}; NEWSEED=${DCL_NEWSEED:-0xabc}
PATMB=${PATMB:-48}

NGROUPS=$(( (N - SC) / G ))
NEWN=$(( N + NGROUPS ))				# add-parity: one parity col/group
NEWG=$(( G + 1 )); NEWM=$(( M + 1 ))
AP_LAYOUT=$(printf '%x' $(( NEWM | 0x400 | (NEWG << 16) | (SC << 24) )))
TRIG=/sys/block/$MDNAME/md/rk_dcl_reshape

rk_load_modules || exit 1
rk_setup_brd "$NEWN" || exit 1
MEMBERS=($(rk_pick_disks "$NEWN"))

sudo "$MDADM" --stop "$MD" 2>/dev/null
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
	sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
done

echo "=== create declustered N=$N g=$G m=$M s=$SC (ngroups=$NGROUPS) ==="
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--raid-devices=$N --run "${MEMBERS[@]:0:$N}" >/dev/null 2>&1 &&
   grep -q "$MDNAME : active" /proc/mdstat || { rk_fail "create"; rk_summary; exit 1; }
rk_wait_idle
sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
sync; PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
sudo "$MDADM" --add "$MD" "${MEMBERS[@]:$N:$NGROUPS}" >/dev/null 2>&1

echo "=== hold the array open (models a mounted / in-use array) ==="
# a single persistent O_RDWR open bumps mddev->openers; the sleep keeps it held
( exec 9<>"$MD"; sleep 120 ) &
HOLDER=$!
sleep 1

echo "=== add-parity (layout-changing) MUST be refused while the array is in use ==="
if echo "$NEWN:$NEWSEED:$AP_LAYOUT" | sudo tee "$TRIG" >/dev/null 2>&1; then
	rk_fail "add-parity STARTED with the array in use (offline-only not enforced)"
	for i in $(seq 1 60); do case "$(cat "$TRIG")" in idle*) break;; esac; sleep 2; done
else
	rk_pass "add-parity rejected while array in use (offline-only enforced)"
fi
grep -q reshape /proc/mdstat && rk_fail "a reshape is running despite the busy array" \
	|| rk_pass "no reshape started while the array was busy"

echo "=== release the array, then the same reshape must succeed offline ==="
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; sync; sudo udevadm settle 2>/dev/null; sleep 1
echo "$NEWN:$NEWSEED:$AP_LAYOUT" | sudo tee "$TRIG" >/dev/null 2>&1 &&
	rk_pass "add-parity accepted once the array is idle (offline)" || { rk_fail "add-parity rejected even when idle"; rk_summary; exit 1; }
for i in $(seq 1 120); do case "$(cat "$TRIG")" in idle*) break;; esac; sleep 2; done
case "$(cat "$TRIG")" in idle*) rk_pass "offline add-parity reshape completed";;
	*) rk_fail "reshape did not finish"; sudo dmesg|tail -6; rk_summary; exit 1;; esac

echo "=== verify the offline reshape was correct ==="
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
[ "$PRE" = "$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null|md5sum|cut -d' ' -f1)" ] &&
	rk_pass "data intact across offline add-parity" || rk_fail "DATA MISMATCH"
mm=$(rk_scrub); [ "$mm" = 0 ] && rk_pass "scrub clean (new m=$NEWM parity consistent)" || rk_fail "scrub mismatch_cnt=$mm"
sudo "$MDADM" --examine "${MEMBERS[0]}" | grep -q "g=$NEWG (k=.*m=$NEWM)" &&
	rk_pass "new geometry persisted (--examine g=$NEWG m=$NEWM)" || rk_fail "geometry not persisted"

sudo dmesg | grep -iE "offline-only|WARN|BUG|call trace|gf_invert" | tail -6
sudo "$MDADM" --stop "$MD" 2>/dev/null
sudo udevadm settle 2>/dev/null
for d in "${MEMBERS[@]}"; do sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
sudo udevadm settle 2>/dev/null
rk_summary
