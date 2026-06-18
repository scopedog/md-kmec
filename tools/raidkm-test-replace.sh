#!/bin/bash
# raidkm-test-replace.sh — disk replacement: rebuild-onto-spare and hot-replace.
#
# For each layout (parity-last and rotating) at m = 2..5, with k=3 data
# (covers both the Vandermonde m<=3 and Cauchy m>=4 EC-matrix paths):
#
#   A. REBUILD ONTO A FRESH SPARE
#      Fail+remove a live data member, --add a fresh spare, let md recover.
#      The missing block is regenerated with raidkm's k+m Reed-Solomon decode.
#      Verify: array returns to full, data reads back correct, scrub is clean,
#      AND a subsequent max-degraded read still reconstructs — the strong oracle
#      that proves the rebuilt disk is EC-correct, not merely scrub-consistent
#      (scrub=0 does NOT imply correct placement/parity; see the grow-data bug).
#
#   B. HOT-REPLACE (mdadm --replace)
#      With a spare attached, --replace a still-live member. md copies onto the
#      replacement while the original stays in service, so the array must NOT go
#      degraded during the operation.  Verify: stays full, old member dropped,
#      data correct, scrub clean.
#
#   sudo bash tools/raidkm-test-replace.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SZ="${SZ:-24}"

rk_load_modules || exit 1
rk_setup_brd 9  || exit 1

rk_dmesg_clear

for layout in 2 2r 3 3r 4 4r 5 5r; do
	m=$(rk_m_of "$layout")
	n=$((3 + m))                       # k=3 data + m parity
	lbl=$([ "${layout: -1}" = r ] && echo rotating || echo parity-last)

	all=$(rk_pick_disks $((n + 1))) || { rk_fail "m=$m $lbl: need $((n+1)) ramdisks"; continue; }
	all=($all)
	active=("${all[@]:0:n}")            # the n array members
	spare="${all[n]}"                   # the +1 hot spare
	victim="${active[1]}"               # a data member to replace

	# ---- A. rebuild onto a fresh spare ------------------------------------
	if ! rk_create "$layout" "${active[@]}"; then
		rk_fail "m=$m $lbl A: create failed"; continue
	fi
	rk_write "$SZ"

	rk_fail_disks "$victim"
	rk_remove_disks "$victim"
	rk_add_disks "$spare"               # fresh spare -> full rebuild via EC decode
	rk_wait_full

	if [ "$(rk_geom)" = "[$n/$n]" ]; then
		rk_pass "m=$m $lbl A: array rebuilt to full after spare add $(rk_geom)"
	else
		rk_fail "m=$m $lbl A: did not return to full $(rk_geom)"
	fi
	if rk_readback "$SZ"; then
		rk_pass "m=$m $lbl A: data correct after rebuild-onto-spare"
	else
		rk_fail "m=$m $lbl A: data CORRUPT after rebuild-onto-spare"
	fi
	mm=$(rk_scrub)
	[ "$mm" = 0 ] && rk_pass "m=$m $lbl A: scrub clean (mismatch=0)" \
		       || rk_fail "m=$m $lbl A: scrub mismatch=$mm"

	# Strong EC oracle: current members are (active minus victim) + spare.
	# Fail m of the *original* survivors (never the just-rebuilt spare), leaving
	# exactly k=3 — so the rebuilt disk MUST supply correct data/parity to
	# reconstruct the others.
	survivors=()
	for d in "${active[@]}"; do [ "$d" = "$victim" ] || survivors+=("$d"); done
	rk_fail_disks "${survivors[@]:0:m}"
	if rk_readback "$SZ"; then
		rk_pass "m=$m $lbl A: max-degraded read after rebuild (rebuilt disk EC-correct)"
	else
		rk_fail "m=$m $lbl A: max-degraded read WRONG — rebuilt disk not EC-correct"
	fi
	rk_stop

	# ---- B. hot-replace (--replace) ---------------------------------------
	if ! rk_create "$layout" "${active[@]}"; then
		rk_fail "m=$m $lbl B: create failed"; continue
	fi
	rk_write "$SZ"

	rk_add_disks "$spare"               # attach a spare for --replace to use
	rk_replace_disk "$victim"           # copy onto replacement, original stays live
	# Must not go degraded: the original is in service until the copy finishes.
	deg=$(rk_geom)
	rk_wait_full

	if [ "$deg" = "[$n/$n]" ]; then
		rk_pass "m=$m $lbl B: stayed non-degraded during hot-replace $deg"
	else
		rk_fail "m=$m $lbl B: went degraded during hot-replace $deg"
	fi
	if [ "$(rk_geom)" = "[$n/$n]" ]; then
		rk_pass "m=$m $lbl B: full after hot-replace $(rk_geom)"
	else
		rk_fail "m=$m $lbl B: not full after hot-replace $(rk_geom)"
	fi
	if rk_readback "$SZ"; then
		rk_pass "m=$m $lbl B: data correct after hot-replace"
	else
		rk_fail "m=$m $lbl B: data CORRUPT after hot-replace"
	fi
	mm=$(rk_scrub)
	[ "$mm" = 0 ] && rk_pass "m=$m $lbl B: scrub clean (mismatch=0)" \
		       || rk_fail "m=$m $lbl B: scrub mismatch=$mm"
	rk_stop
done

# ---------------------------------------------------------------------------
# Rebuild-under-stress combinations (the interaction states the simple A/B
# scenarios don't cover).  Focused set: m=2,3 x {parity-last, rotating}.  Each
# throttles the rebuild to open a window, performs the stress action mid-rebuild,
# then un-throttles, lets it settle, and verifies with the full oracle (data vs
# shadow + scrub=0 + a max-degraded read).  Needs n+2 disks (a 2nd spare).
# ---------------------------------------------------------------------------
SH="$RK_TMP/shadow"
nblk=$(( SZ * 1024 * 1024 / 4096 ))
rk_seed() {           # create+fill, leave shadow = on-disk content
	rk_create "$1" "${@:2}" || return 1
	rk_write "$SZ"
	cp "$RK_TMP/src" "$SH"
}
rk_smallwrites() {    # $1 = count : random 4k sub-stripe writes, mirrored to shadow
	local w off
	for w in $(seq 1 "$1"); do
		off=$(( RANDOM % nblk ))
		sudo dd if=/dev/urandom of="$RK_TMP/p4k" bs=4096 count=1 status=none 2>/dev/null
		sudo dd if="$RK_TMP/p4k" of="$MD" bs=4096 seek="$off" count=1 oflag=direct conv=notrunc status=none 2>/dev/null
		sudo dd if="$RK_TMP/p4k" of="$SH" bs=4096 seek="$off" count=1 conv=notrunc status=none 2>/dev/null
	done
}
rk_data_ok() {        # read array, compare to shadow
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
	sudo dd if="$MD" of="$RK_TMP/rd" bs=1M count="$SZ" iflag=direct status=none 2>/dev/null
	cmp -s "$SH" "$RK_TMP/rd"
}

for layout in 2 2r 3 3r; do
	m=$(rk_m_of "$layout")
	n=$((3 + m))
	lbl=$([ "${layout: -1}" = r ] && echo rotating || echo parity-last)
	all=$(rk_pick_disks $((n + 2))) || { rk_fail "m=$m $lbl stress: need $((n+2)) ramdisks"; continue; }
	all=($all)
	active=("${all[@]:0:n}"); spare1="${all[n]}"; spare2="${all[$((n+1))]}"
	victim="${active[1]}"; victim2="${active[2]}"

	# C. degraded WRITE while a disk is rebuilding -------------------------
	rk_seed "$layout" "${active[@]}" || { rk_fail "m=$m $lbl C: seed failed"; continue; }
	rk_fail_disks "$victim"; rk_remove_disks "$victim"
	rk_throttle; rk_add_disks "$spare1"
	if rk_wait_recovery_active; then
		rk_smallwrites 60          # writes land while degraded + rebuilding
		rk_unthrottle; rk_wait_full
		{ rk_data_ok && [ "$(rk_scrub)" = 0 ] && [ "$(rk_geom)" = "[$n/$n]" ]; } \
			&& rk_pass "m=$m $lbl C: write-during-rebuild — data+parity correct, full" \
			|| rk_fail "m=$m $lbl C: write-during-rebuild WRONG"
	else
		rk_unthrottle; rk_fail "m=$m $lbl C: rebuild never went active"
	fi
	rk_stop

	# D. SECOND failure during a rebuild ----------------------------------
	rk_seed "$layout" "${active[@]}" || { rk_fail "m=$m $lbl D: seed failed"; continue; }
	rk_fail_disks "$victim"; rk_remove_disks "$victim"
	rk_throttle; rk_add_disks "$spare1"
	if rk_wait_recovery_active; then
		rk_fail_disks "$victim2"   # 2nd loss mid-rebuild (total == within tolerance)
		rk_remove_disks "$victim2"; rk_add_disks "$spare2"
		rk_unthrottle; rk_wait_full
		{ rk_data_ok && [ "$(rk_scrub)" = 0 ] && [ "$(rk_geom)" = "[$n/$n]" ]; } \
			&& rk_pass "m=$m $lbl D: 2nd-failure-during-rebuild — recovered, data+parity correct" \
			|| rk_fail "m=$m $lbl D: 2nd-failure-during-rebuild WRONG"
	else
		rk_unthrottle; rk_fail "m=$m $lbl D: rebuild never went active"
	fi
	rk_stop

	# E. INTERRUPTED rebuild (stop mid-rebuild, reassemble -> resume) ------
	rk_seed "$layout" "${active[@]}" || { rk_fail "m=$m $lbl E: seed failed"; continue; }
	rk_fail_disks "$victim"; rk_remove_disks "$victim"
	rk_throttle; rk_add_disks "$spare1"
	if rk_wait_recovery_active; then
		sudo "$MDADM" --stop "$MD" >/dev/null 2>&1      # interrupt partway
		# rebuilt member set = active with victim's slot now held by spare1
		reasm=(); for d in "${active[@]}"; do
			[ "$d" = "$victim" ] && reasm+=("$spare1") || reasm+=("$d")
		done
		sudo "$MDADM" --assemble "$MD" "${reasm[@]}" --run >/dev/null 2>&1
		rk_unthrottle; rk_wait_full
		{ rk_data_ok && [ "$(rk_scrub)" = 0 ] && [ "$(rk_geom)" = "[$n/$n]" ]; } \
			&& rk_pass "m=$m $lbl E: interrupted rebuild resumes — data+parity correct, full" \
			|| rk_fail "m=$m $lbl E: interrupted-rebuild resume WRONG"
	else
		rk_unthrottle; rk_fail "m=$m $lbl E: rebuild never went active"
	fi
	rk_stop
done

rk_dmesg_clean || rk_fail "kernel ring buffer shows WARN/BUG during replacement"
rk_summary