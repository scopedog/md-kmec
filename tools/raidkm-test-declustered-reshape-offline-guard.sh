#!/bin/bash
#
# raidkm-test-declustered-reshape-offline-guard.sh — online acceptance guard
# for group-geometry reshapes (notes/declustered-reshape-design.md §7b/§7c).
#
# Since the ONLINE dual-geometry stripe path landed (§7b), layout-word-changing
# reshapes (add-parity / add-data / spare-count) run ONLINE: the un-migrated
# region is served by previous-geometry stripes.  §7c lifted the last v1
# exception — NATIVE-CSUM arrays run online too (stripe-path CRC keying is
# sh-geometry-keyed; the band's CRC re-key runs inside the row's claim/quiesce
# bracket, so an open writer can never observe a stale key).
#
# This gate proves BOTH array flavours are ACCEPTED and complete correctly
# while the array is held open: (1) add-parity on a PLAIN array; (2) the same
# reshape on a --checksum array, plus a zero-mismatch (no stale-key storm)
# assertion after a full re-read.
set -u
# The busy-holder below opens $MD directly (a shell fd, not via sudo), so this
# gate needs root — an unprivileged open fails silently and the held-open legs
# prove nothing.  Re-exec under sudo.
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}; NEWSEED=${DCL_NEWSEED:-0xabc}
PATMB=${PATMB:-48}

NGROUPS=$(( (N - SC) / G ))
NEWN=$(( N + NGROUPS ))				# add-parity: one parity col/group
NEWG=$(( G + 1 )); NEWM=$(( M + 1 ))
AP_LAYOUT=$(printf '%x' $(( NEWM | 0x400 | (NEWG << 16) | (SC << 24) )))
CSUM_BIT=$(( 0x200 ))
AP_LAYOUT_CSUM=$(printf '%x' $(( NEWM | 0x400 | CSUM_BIT | (NEWG << 16) | (SC << 24) )))
TRIG=/sys/block/$MDNAME/md/rk_dcl_reshape

rk_load_modules || exit 1
rk_setup_brd "$NEWN" || exit 1
MEMBERS=($(rk_pick_disks "$NEWN"))

mk_array() {	# mk_array [--checksum] — fresh dcl array + pattern on members 0..N-1
	local extra=${1:-}
	local d
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	for d in "${MEMBERS[@]}"; do
		sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
		sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
	sudo udevadm settle 2>/dev/null
	sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
		--layout=declustered --group-width=$G --spare-columns=$SC \
		--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" $extra \
		--raid-devices=$N --run --force "${MEMBERS[@]:0:$N}" >/dev/null 2>&1 &&
	   grep -q "$MDNAME : active raidkm" /proc/mdstat || return 1
	rk_wait_idle
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
	sync
	sudo "$MDADM" --add "$MD" "${MEMBERS[@]:$N:$NGROUPS}" >/dev/null 2>&1
	sudo udevadm settle 2>/dev/null; sleep 1
	return 0
}

sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)

# ---- Leg 1: PLAIN array — add-parity must run ONLINE while held open --------
echo "=== leg 1: plain array, add-parity WHILE the array is held open (online path) ==="
mk_array || { rk_fail "create (plain)"; rk_summary; exit 1; }
( exec 9<>"$MD"; sleep 180 ) &
HOLDER=$!
sleep 1
if echo "$NEWN:$NEWSEED:$AP_LAYOUT" | sudo tee "$TRIG" >/dev/null 2>&1; then
	rk_pass "plain add-parity ACCEPTED with the array in use (online g-change)"
else
	rk_fail "plain add-parity rejected while open (online path not engaged)"
	kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
	rk_summary; exit 1
fi
for i in $(seq 1 120); do case "$(cat "$TRIG")" in idle*) break;; esac; sleep 2; done
case "$(cat "$TRIG")" in idle*) rk_pass "online add-parity completed with an open handle";;
	*) rk_fail "reshape did not finish"; sudo dmesg|tail -6; rk_summary; exit 1;; esac
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
[ "$PRE" = "$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null|md5sum|cut -d' ' -f1)" ] &&
	rk_pass "data intact across online add-parity" || rk_fail "DATA MISMATCH (online leg)"
mm=$(rk_scrub); [ "$mm" = 0 ] && rk_pass "scrub clean (online leg)" || rk_fail "scrub mismatch_cnt=$mm (online leg)"
sudo "$MDADM" --examine "${MEMBERS[0]}" | grep -q "g=$NEWG (k=.*m=$NEWM)" &&
	rk_pass "new geometry persisted (--examine g=$NEWG m=$NEWM)" || rk_fail "geometry not persisted (online leg)"

# ---- Leg 2: CSUM array — add-parity must run ONLINE while held open (§7c) ---
echo "=== leg 2: --checksum array, add-parity WHILE the array is held open (online path) ==="
mk_array --checksum || { rk_fail "create (--checksum)"; rk_summary; exit 1; }
STORM0=$(sudo dmesg | grep -c "native csum mismatch")
( exec 9<>"$MD"; sleep 180 ) &
HOLDER=$!
sleep 1
if echo "$NEWN:$NEWSEED:$AP_LAYOUT_CSUM" | sudo tee "$TRIG" >/dev/null 2>&1; then
	rk_pass "csum add-parity ACCEPTED with the array in use (online g-change, §7c)"
else
	rk_fail "csum add-parity rejected while open (§7c online lift not engaged)"
	kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
	rk_summary; exit 1
fi
for i in $(seq 1 120); do case "$(cat "$TRIG")" in idle*) break;; esac; sleep 2; done
case "$(cat "$TRIG")" in idle*) rk_pass "online csum add-parity completed with an open handle";;
	*) rk_fail "reshape did not finish"; sudo dmesg|tail -6; rk_summary; exit 1;; esac
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
[ "$PRE" = "$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none 2>/dev/null|md5sum|cut -d' ' -f1)" ] &&
	rk_pass "data intact across online csum add-parity" || rk_fail "DATA MISMATCH (csum leg)"
mm=$(rk_scrub); [ "$mm" = 0 ] && rk_pass "scrub clean (csum leg)" || rk_fail "scrub mismatch_cnt=$mm (csum leg)"
# full re-read through the verify path: every block must match its (re-keyed) CRC
sudo dd if="$MD" of=/dev/null bs=1M iflag=direct status=none 2>/dev/null
storm=$(( $(sudo dmesg | grep -c "native csum mismatch") - STORM0 ))
[ "$storm" = 0 ] && rk_pass "zero csum mismatches after online csum add-parity (re-key correct)" \
		 || rk_fail "$storm csum mismatches (stale-key storm)"
sudo "$MDADM" --examine "${MEMBERS[0]}" | grep -q "g=$NEWG (k=.*m=$NEWM)" &&
	rk_pass "csum-leg geometry persisted (--examine g=$NEWG m=$NEWM)" || rk_fail "geometry not persisted (csum leg)"

sudo dmesg | grep -iE "WARN|BUG|call trace|gf_invert" | tail -6
sudo "$MDADM" --stop "$MD" 2>/dev/null
sudo udevadm settle 2>/dev/null
for d in "${MEMBERS[@]}"; do sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
sudo udevadm settle 2>/dev/null
rk_summary
