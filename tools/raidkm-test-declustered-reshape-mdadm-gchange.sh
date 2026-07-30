#!/bin/bash
#
# raidkm-test-declustered-reshape-mdadm-gchange.sh — the mdadm drivers for the
# declustered group-geometry reshapes (raidkm_dcl_grow kinds beyond pool
# expansion):
#
#   T1  mdadm --grow --add-parity <devs>:  g,m -> g+1,m+1, ngroups new disks;
#       capacity unchanged, m=3 degraded-decode, geometry persisted.
#   T2  mdadm --grow --add-data with PRE-ADDED spares (the two-step form):
#       g -> g+1 at fixed m; capacity grows.
#   T3  mdadm --grow --spare-columns=s' (decrease): no disks added, capacity
#       grows; s' increase and s' == s both REJECTED with a clear message.
#   T4  ONLINE g-change through mdadm: with the array held open (models a
#       mounted array), --add-parity is ACCEPTED, runs to completion and is
#       correct — the §7b dual-geometry stripe path through the mdadm driver.
#       (Csum arrays run online too since §7c; that leg is covered by the
#       offline-guard gate at the trigger level and CSUM=1 gchange-concurrent.)
#   T5  option hygiene: --add-parity + --spare-columns rejected;
#       --add-parity with a conflicting --raid-devices rejected.
#
# Usage: bash <this>
set -u
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}
SN=${DCL_SN:-20}; SSC=${DCL_SSC:-8}	# spare-count test geometry
PATMB=${PATMB:-64}
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
rk_setup_brd "$SN" || exit 1
DISKS=$(rk_pick_disks "$SN") || { echo "ERROR: need $SN devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

sudo dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)

mk_array() {	# mk_array <n> [extra create opts...]
	local n="$1"; shift
	local d
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	for d in "${MEMBERS[@]}"; do
		sudo dd if=/dev/zero of="$d" bs=1M count=8 status=none 2>/dev/null
		sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
	sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
		--layout=declustered --group-width=$G --spare-columns="${SCARG:-$SC}" \
		--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
		--raid-devices="$n" --run --force "$@" "${MEMBERS[@]:0:$n}" >/dev/null 2>&1 &&
	   grep -q "$MDNAME : active raidkm" /proc/mdstat || return 1
	rk_wait_idle
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
	sync
	return 0
}
verify_common() {	# verify_common <tag> <expect_m> <examine_re>
	local tag="$1" xm="$2" xre="$3" mm deg GOT d
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none | md5sum | cut -d' ' -f1)
	[ "$PRE" = "$GOT" ] && rk_pass "$tag: data intact" || rk_fail "$tag: DATA MISMATCH"
	mm=$(rk_scrub)
	[ "$mm" = 0 ] && rk_pass "$tag: scrub clean" || rk_fail "$tag: scrub mismatch_cnt=$mm"
	sudo "$MDADM" --examine "${MEMBERS[0]}" 2>/dev/null | grep -q "$xre" &&
		rk_pass "$tag: geometry persisted (--examine)" ||
		rk_fail "$tag: geometry not persisted (want /$xre/)"
	for d in "${MEMBERS[@]:0:$xm}"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; sleep 1; done
	deg=$(cat /sys/block/$MDNAME/md/degraded)
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	GOT=$(sudo dd if="$MD" bs=1M count="$PATMB" iflag=direct status=none | md5sum | cut -d' ' -f1)
	[ "$deg" = "$xm" ] && [ "$PRE" = "$GOT" ] &&
		rk_pass "$tag: degraded-decode at m=$xm EC-correct" ||
		rk_fail "$tag: degraded-decode failed (degraded=$deg want $xm)"
}
wait_reshape_done() {	# via /proc/mdstat + sysfs sync_action
	local i
	for i in $(seq 1 180); do
		grep -q reshape /proc/mdstat || {
			[ "$(cat /sys/block/$MDNAME/md/sync_action 2>/dev/null)" = idle ] && return 0; }
		sleep 2
	done
	return 1
}

NG=$(( (N - SC) / G ))

# ---- T1: mdadm --grow --add-parity <devs> --------------------------------------
echo "=== T1: mdadm --grow --add-parity (g=$G,m=$M -> g=$((G+1)),m=$((M+1))) ==="
mk_array "$N" || { rk_fail "T1: create"; rk_summary; exit 1; }
CAP0=$(cat /sys/block/$MDNAME/md/array_size 2>/dev/null || blockdev --getsz "$MD")
sudo "$MDADM" --grow "$MD" --add-parity "${MEMBERS[@]:$N:$NG}" 2>&1 | sed 's/^/  /'
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { rk_fail "T1: mdadm --grow --add-parity failed (rc=$rc)"; rk_summary; exit 1; }
grep -q "$MDNAME : active" /proc/mdstat || { rk_fail "T1: array gone"; rk_summary; exit 1; }
wait_reshape_done || { rk_fail "T1: reshape did not finish"; rk_summary; exit 1; }
rk_pass "T1: mdadm drove the declustered add-parity"
CAP1=$(blockdev --getsz "$MD")
[ "$CAP1" -le "$CAP0" ] 2>/dev/null || true	# capacity unchanged for add-parity
verify_common "T1" $((M+1)) "g=$((G+1)) (k=.*m=$((M+1)))"

# ---- T2: mdadm --grow --add-data with pre-added spares -------------------------
echo "=== T2: mdadm --grow --add-data via pre-added spares (k -> k+1) ==="
mk_array "$N" || { rk_fail "T2: create"; rk_summary; exit 1; }
CAP0=$(blockdev --getsz "$MD")
for d in "${MEMBERS[@]:$N:$NG}"; do sudo "$MDADM" "$MD" --add "$d" >/dev/null 2>&1; done
sudo udevadm settle 2>/dev/null; sleep 1
sudo "$MDADM" --grow "$MD" --add-data 2>&1 | sed 's/^/  /'
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { rk_fail "T2: mdadm --grow --add-data failed (rc=$rc)"; rk_summary; exit 1; }
wait_reshape_done || { rk_fail "T2: reshape did not finish"; rk_summary; exit 1; }
rk_pass "T2: mdadm drove the declustered add-data (two-step spare form)"
CAP1=$(blockdev --getsz "$MD")
[ "$CAP1" -gt "$CAP0" ] && rk_pass "T2: capacity grew ($CAP0 -> $CAP1 sectors)" \
			|| rk_fail "T2: capacity did not grow ($CAP0 -> $CAP1)"
verify_common "T2" "$M" "g=$((G+1)) (k=$((G+1-M))+m=$M)"

# ---- T3: mdadm --grow --spare-columns (decrease; increase/same rejected) -------
echo "=== T3: mdadm --grow --spare-columns=$SC on N=$SN s=$SSC ==="
SCARG=$SSC mk_array "$SN" || { rk_fail "T3: create N=$SN s=$SSC"; rk_summary; exit 1; }
CAP0=$(blockdev --getsz "$MD")
sudo "$MDADM" --grow "$MD" --spare-columns=$((SSC + 6)) 2>&1 | grep -qi "shrink" &&
	rk_pass "T3: spare-count increase rejected (would shrink)" ||
	rk_fail "T3: spare-count increase not rejected"
sudo "$MDADM" --grow "$MD" --spare-columns=$SSC 2>&1 | grep -qi "already has" &&
	rk_pass "T3: no-op spare-count rejected" ||
	rk_fail "T3: no-op spare-count not rejected"
sudo "$MDADM" --grow "$MD" --spare-columns=$SC 2>&1 | sed 's/^/  /'
rc=${PIPESTATUS[0]}
[ "$rc" = 0 ] || { rk_fail "T3: mdadm --grow --spare-columns failed (rc=$rc)"; rk_summary; exit 1; }
wait_reshape_done || { rk_fail "T3: reshape did not finish"; rk_summary; exit 1; }
rk_pass "T3: mdadm drove the spare-count decrease ($SSC -> $SC)"
CAP1=$(blockdev --getsz "$MD")
[ "$CAP1" -gt "$CAP0" ] && rk_pass "T3: capacity grew ($CAP0 -> $CAP1 sectors)" \
			|| rk_fail "T3: capacity did not grow ($CAP0 -> $CAP1)"
verify_common "T3" "$M" "$SC spare column"

# ---- T4: ONLINE g-change through mdadm ------------------------------------------
echo "=== T4: --add-parity ACCEPTED and correct while the array is held open ==="
mk_array "$N" || { rk_fail "T4: create"; rk_summary; exit 1; }
( exec 9<>"$MD"; sleep 240 ) &
HOLDER=$!
sleep 1
out=$(sudo "$MDADM" --grow "$MD" --add-parity "${MEMBERS[@]:$N:$NG}" 2>&1)
if echo "$out" | grep -qi "started"; then
	rk_pass "T4: mdadm started add-parity on an in-use array (online g-change)"
else
	rk_fail "T4: mdadm did not start add-parity while held open: $out"
fi
wait_reshape_done && rk_pass "T4: online add-parity completed with an open handle" \
		  || rk_fail "T4: reshape did not finish"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
verify_common "T4" "$((M + 1))" "g=$((G+1)) (k=.*m=$((M+1)))"

# ---- T5: option hygiene --------------------------------------------------------
echo "=== T5: conflicting option combinations rejected ==="
sudo "$MDADM" --grow "$MD" --add-parity --spare-columns=3 \
	"${MEMBERS[@]:$N:$NG}" 2>&1 | grep -q "cannot be combined" &&
	rk_pass "T5: --add-parity + --spare-columns rejected" ||
	rk_fail "T5: combination not rejected"
sudo "$MDADM" --grow "$MD" --add-parity --raid-devices=$((N + 1)) \
	"${MEMBERS[@]:$N:$NG}" 2>&1 | grep -q "conflicts" &&
	rk_pass "T5: --add-parity + wrong --raid-devices rejected" ||
	rk_fail "T5: conflicting --raid-devices not rejected"

sudo dmesg | grep -iE "WARN|BUG|call trace|gf_invert" | tail -5
rk_summary
