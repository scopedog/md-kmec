#!/bin/bash
#
# raidkm-test-ppl-refused.sh — PPL (--consistency-policy=ppl) is refused on
# raidkm (2026-11-16).
#
# The m-parity PPL failed power-cut testing (acknowledged writes lost with
# every member present), costs 43-72% of write throughput and excludes the
# write-intent bitmap, which is the supported policy.  The kernel refuses it
# in ppl_init_log for level 71; this suite checks every way in:
#   P1. create with --consistency-policy=ppl: refused, array not active.
#   P2. members that carry the PPL flag (left by P1's create, like an array
#       made by an older module) are recovered with
#       "mdadm --assemble --update=no-ppl": active, data intact, and a
#       write-intent bitmap can be added.
#   P3. a running array switched through md/consistency_policy: the write
#       fails (raid5_change_consistency_policy allows ppl on raid5 only), the
#       policy is unchanged and the array keeps running.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

K=4; M=2; N=$((K + M))
MEMBERS=()
MSG="PPL is not supported on raidkm"

cleanup() {
	rk_stop
	local d
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
	rm -f "$RK_TMP"/ppl-*
}
trap cleanup EXIT

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
rk_setup_brd "$N" || exit 1
read -r -a MEMBERS <<< "$(rk_pick_disks "$N")"
sudo "$MDADM" --zero-superblock "${MEMBERS[@]}" 2>/dev/null
active() { grep -q "^$MDNAME : active" /proc/mdstat; }

# ---- P1: create with PPL refused ---------------------------------------------
rk_stop
rk_dmesg_window_close
rk_dmesg_clear
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M --layout=rotating \
	--chunk="$CHUNK_KB" --raid-devices=$N --consistency-policy=ppl \
	"${MEMBERS[@]}" --run --force >/dev/null 2>&1
if active; then
	rk_fail "P1: create with --consistency-policy=ppl is ACTIVE (must be refused)"
elif sudo dmesg | grep -q "$MSG"; then
	rk_pass "P1: create with --consistency-policy=ppl refused by the kernel"
else
	rk_fail "P1: PPL create not active, but no refusal message"
	sudo dmesg | tail -4 | sed 's/^/      · /'
fi
rk_stop

# ---- P2: members with the PPL flag: --update=no-ppl ----------------------------
if ! sudo "$MDADM" --examine "${MEMBERS[0]}" 2>/dev/null | grep -qi "ppl"; then
	rk_skip_check "P2: the refused create left no PPL superblock to recover"
else
	rk_dmesg_window_close
	rk_dmesg_clear
	sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]}" --run >/dev/null 2>&1
	if active; then
		rk_fail "P2: plain assemble of PPL members is ACTIVE (must be refused)"
	elif sudo dmesg | grep -q "$MSG"; then
		rk_pass "P2: plain assemble of PPL members refused"
	else
		rk_fail "P2: plain assemble not active, but no refusal message"
		sudo dmesg | tail -4 | sed 's/^/      · /'
	fi
	rk_stop
	if sudo "$MDADM" --assemble "$MD" "${MEMBERS[@]}" --update=no-ppl --run >/dev/null 2>&1 && active; then
		rk_pass "P2: --assemble --update=no-ppl brings the array up"
		rk_wait_idle
		pol=$(cat "/sys/block/$MDNAME/md/consistency_policy" 2>/dev/null)
		[ "$pol" != ppl ] && rk_pass "P2: consistency_policy now '$pol'" \
				  || rk_fail "P2: consistency_policy still ppl"
		A="$RK_TMP/ppl-a"; G="$RK_TMP/ppl-g"
		head -c 4M /dev/urandom > "$A"
		sudo dd if="$A" of="$MD" bs=1M oflag=direct status=none
		sudo dd if="$MD" of="$G" bs=1M count=4 iflag=direct status=none
		cmp -s "$A" "$G" && rk_pass "P2: write + read back after recovery (4 MiB)" \
				  || rk_fail "P2: read back differs after recovery"
		if sudo "$MDADM" --grow "$MD" --bitmap=internal >/dev/null 2>&1 &&
		   [ "$(cat "/sys/block/$MDNAME/md/consistency_policy")" = bitmap ]; then
			rk_pass "P2: write-intent bitmap added"
		else
			rk_fail "P2: --grow --bitmap=internal failed"
		fi
	else
		rk_fail "P2: --assemble --update=no-ppl failed"
		sudo dmesg | tail -4 | sed 's/^/      · /'
	fi
	rk_stop
fi

# ---- P3: runtime switch to ppl refused -----------------------------------------
sudo "$MDADM" --zero-superblock "${MEMBERS[@]}" 2>/dev/null
if sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M --layout=rotating \
	--chunk="$CHUNK_KB" --raid-devices=$N --bitmap=none --assume-clean \
	"${MEMBERS[@]}" --run --force >/dev/null 2>&1 && active; then
	echo ppl | sudo tee "/sys/block/$MDNAME/md/consistency_policy" >/dev/null 2>&1
	wrc=$?
	pol=$(cat "/sys/block/$MDNAME/md/consistency_policy")
	if [ "$pol" = ppl ]; then
		rk_fail "P3: consistency_policy switched to ppl (must be refused)"
	elif [ $wrc -ne 0 ]; then
		rk_pass "P3: switch to ppl refused (write failed), policy stays '$pol'"
	else
		rk_fail "P3: policy stays '$pol', but the write reported success"
	fi
	active && rk_pass "P3: array still running" || rk_fail "P3: array stopped"
else
	rk_fail "P3: create without a bitmap failed"
fi
rk_stop

rk_dmesg_window_close
[ "$RK_DMESG_BAD" = 0 ] && rk_pass "no kernel WARN/BUG during the run (all windows)" \
			|| rk_fail "kernel WARN/BUG in a window the suite cleared"
rk_summary
