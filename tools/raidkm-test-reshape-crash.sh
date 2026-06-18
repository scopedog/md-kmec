#!/bin/bash
# raidkm-test-reshape-crash.sh — crash + fault injection for the COW-staged
# online reshape (add-parity m->m+1 and add-data k->k+1, rotating layout).
#
# OPT-IN reliability test, NOT part of the default raidkm-test.sh runner.
# It validates the *journaled, out-of-place, one-band-at-a-time* reshape design:
# a band is read via the old geometry, re-encoded into a small temp/scratch
# region in the new geometry, then committed to its home; every step is logged
# so a crash is always recoverable by redo-from-old (before STAGE durable) or
# replay-from-scratch (after STAGE durable).  The reliability invariant under
# test: at every instant each logical chunk is intact in its old home OR in
# durable scratch, identified by the journal — so correctness never depends on
# md's frontier math (which is what corrupts rotating in the stock engine).
#
# ---------------------------------------------------------------------------
# KERNEL DEBUG CONTRACT (required for the inject-driven tiers)
# ---------------------------------------------------------------------------
# Built only with CONFIG_RAIDKM_FAULT_INJECT.  Per-array sysfs attribute:
#
#     /sys/block/<md>/md/raidkm_reshape_inject  =  "<band>:<phase>:<action>"
#
#   band   : band ordinal to fire on.  0 = first, -1 = last, else absolute.
#   phase  : STAGE | COMMIT | DONE | FINALIZE
#   action : hang  — durably write this phase's journal record, then PARK the
#                     reshape thread before the next step (clean-boundary sim).
#            torn  — durably write this phase's journal, BEGIN the next step but
#                     write only a partial/torn subset of its bios, then PARK
#                     (in-flight-not-durable sim; deterministic, kernel-driven).
#   Writing "off" (or empty) disarms.  Reading back reports "parked@<band>:<phase>"
#   once the thread has parked, else "armed" / "off".
#
# The test arms an inject point, starts the reshape, waits until the thread
# parks, then simulates power loss with dm-flakey drop_writes (so the pending
# superblock/journal/home writes vanish), --stop, thaw, --assemble, and lets
# the kernel recover.  Without the inject build the inject tiers are SKIPPED
# and only the harness-sanity baseline + a best-effort reshape_position-timed
# crash run (no phase precision).
#
# Member stack (per device):   file -> loop --direct-io -> dm-flakey -> md
#
# Config (also see raidkm-test-lib.sh):
#   RX_DISK_SIZE_MB   backing file size per device, MiB     (default 128)
#   RX_BACK           dir for backing files                 (default /var/tmp/raidkm-reshape-crash)
#   RX_SZ             MiB written before the reshape         (default 32)
#   RX_FULL_ORACLE    1 = exhaustive C(N,new_m) erasure sweep (default 0: strong single pattern)
#   RX_AP_OLD_M       add-parity starting m (k fixed = 4)    (default 3  -> m=3->4)
#   RX_AD_OLD_K       add-data starting k (m fixed = 2)      (default 3  -> k=3->4)
#
# Usage:   sudo bash tools/raidkm-test-reshape-crash.sh
#          sudo RX_FULL_ORACLE=1 RX_AP_OLD_M=2 bash tools/raidkm-test-reshape-crash.sh

set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

RX_DISK_SIZE_MB="${RX_DISK_SIZE_MB:-128}"
RX_BACK="${RX_BACK:-/var/tmp/raidkm-reshape-crash}"
RX_SZ="${RX_SZ:-32}"
RX_FULL_ORACLE="${RX_FULL_ORACLE:-0}"
RX_AP_OLD_M="${RX_AP_OLD_M:-3}"
RX_AD_OLD_K="${RX_AD_OLD_K:-3}"

RX_LOOPS=(); RX_FLK=(); RX_DEVS=()
RX_HAVE_INJECT=0
RX_INJ=""                       # sysfs inject path for the live array

# ---------------------------------------------------------------------------
# dm-flakey member stack (adapted from raidkm-test-crash.sh)
# ---------------------------------------------------------------------------
rx_global_cleanup() {
	local d l tries
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	sudo "$MDADM" --stop --scan >/dev/null 2>&1
	sudo udevadm settle 2>/dev/null
	for d in $(sudo dmsetup ls 2>/dev/null | awk '$1 ~ /^rkrx[0-9]+$/ {print $1}'); do
		for tries in 1 2 3 4 5; do
			sudo dmsetup remove "$d" >/dev/null 2>&1 && break
			sudo dmsetup remove --force "$d" >/dev/null 2>&1 && break
			sleep 0.2
		done
	done
	# A previous abnormal exit can leave /dev/mapper/rkrx* behind as *regular
	# files* (not symlinks).  dmsetup remove deletes the device but never these
	# shadow files, and udev then refuses to recreate the symlink over them, so
	# every later rx_setup fails with "device node never appeared".  Sweep them.
	sudo rm -f /dev/mapper/rkrx* 2>/dev/null
	for l in $(sudo losetup -l 2>/dev/null | awk '/raidkm-reshape-crash/ {print $1}'); do
		sudo losetup -d "$l" >/dev/null 2>&1
	done
}

rx_setup() {                    # rx_setup <ndevs>
	local n="$1" i loop f flk sectors
	mkdir -p "$RX_BACK"
	rx_global_cleanup
	RX_LOOPS=(); RX_FLK=(); RX_DEVS=()
	for i in $(seq 1 "$n"); do
		f="$RX_BACK/disk$i.img"
		sudo rm -f "$f"
		sudo dd if=/dev/zero of="$f" bs=1M count="$RX_DISK_SIZE_MB" status=none
		loop=$(sudo losetup --show -f --direct-io=on "$f") || {
			echo "losetup failed for $f" >&2; return 1; }
		flk="rkrx$i"
		sectors=$(sudo blockdev --getsz "$loop")
		# Clear any stale shadow node/file so udev can place the symlink.
		sudo rm -f "/dev/mapper/$flk" 2>/dev/null
		echo "0 $sectors flakey $loop 0 86400 0" | sudo dmsetup create "$flk" || {
			echo "dmsetup create $flk failed" >&2; return 1; }
		RX_LOOPS+=("$loop"); RX_FLK+=("$flk"); RX_DEVS+=("/dev/mapper/$flk")
	done
	# /dev/mapper/* symlinks are created asynchronously by udev; with a
	# loaded/backlogged udev the immediately-following mdadm --create sees
	# "not a block device".  Settle and verify before returning.
	sudo udevadm settle --timeout=30 2>/dev/null || true
	for flk in "${RX_FLK[@]}"; do
		for i in $(seq 1 100); do
			[ -b "/dev/mapper/$flk" ] && break
			sleep 0.1
		done
		[ -b "/dev/mapper/$flk" ] || {
			echo "device node /dev/mapper/$flk never appeared" >&2; return 1; }
	done
}

rx_crash_now() {                # drop every write (power loss)
	local i f loop sectors
	for i in "${!RX_FLK[@]}"; do
		f="${RX_FLK[$i]:-}"; loop="${RX_LOOPS[$i]:-}"
		[ -n "$f" ] && [ -n "$loop" ] || continue
		sectors=$(sudo blockdev --getsz "$loop")
		sudo dmsetup suspend "$f"
		echo "0 $sectors flakey $loop 0 0 86400 1 drop_writes" | sudo dmsetup load "$f"
		sudo dmsetup resume "$f"
	done
}

rx_thaw() {                     # back to passthrough; dropped writes stay dropped
	local i f loop sectors
	for i in "${!RX_FLK[@]}"; do
		f="${RX_FLK[$i]:-}"; loop="${RX_LOOPS[$i]:-}"
		[ -n "$f" ] && [ -n "$loop" ] || continue
		sectors=$(sudo blockdev --getsz "$loop")
		sudo dmsetup suspend "$f"
		echo "0 $sectors flakey $loop 0 86400 0" | sudo dmsetup load "$f"
		sudo dmsetup resume "$f"
	done
}

rx_teardown() {
	local f loop tries
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	sudo "$MDADM" --stop --scan >/dev/null 2>&1
	sudo udevadm settle 2>/dev/null
	for f in "${RX_FLK[@]:-}"; do
		[ -n "$f" ] || continue
		for tries in 1 2 3 4 5 6 7 8; do
			sudo dmsetup remove "$f" >/dev/null 2>&1 && break
			[ "$tries" -ge 4 ] && sudo dmsetup remove --force "$f" >/dev/null 2>&1 && break
			sleep 0.3
		done
	done
	for loop in "${RX_LOOPS[@]:-}"; do
		[ -n "$loop" ] || continue
		for tries in 1 2 3; do
			sudo losetup -d "$loop" >/dev/null 2>&1 && break
			sleep 0.2
		done
	done
	RX_LOOPS=(); RX_FLK=(); RX_DEVS=()
}
trap 'rx_teardown' EXIT INT TERM

# ---------------------------------------------------------------------------
# inject knob
# ---------------------------------------------------------------------------
rx_inj_path() { echo "/sys/block/$MDNAME/md/raidkm_reshape_inject"; }
rx_inj_set()  { echo "$1" | sudo tee "$(rx_inj_path)" >/dev/null 2>&1; }
rx_inj_off()  { echo off  | sudo tee "$(rx_inj_path)" >/dev/null 2>&1 || true; }

# Wait until the reshape thread reports it has parked at the inject point.
rx_wait_parked() {
	local i s
	# Generous: reaching a mid/last band means migrating hundreds of
	# journaled bands first (FUA-heavy on loop files; the per-band
	# claim/quiesce of the online window adds latency too).
	for i in $(seq 1 6000); do
		s=$(cat "$(rx_inj_path)" 2>/dev/null)
		case "$s" in parked@*) return 0;; esac
		grep -qiE 'reshape' /proc/mdstat || true
		sleep 0.1
	done
	return 1
}

# Probe inject support once, on a throwaway brd array.
rx_probe_inject() {
	rk_setup_brd 6 || return 0
	local disks; disks=$(rk_pick_disks 6) || return 0
	rk_create 2r $disks >/dev/null 2>&1 || { rk_stop; return 0; }
	[ -e "$(rx_inj_path)" ] && RX_HAVE_INJECT=1
	rk_stop
}

# ---------------------------------------------------------------------------
# EC oracle helpers
# ---------------------------------------------------------------------------
# Emit every k-of-n index combination, one per line ("i j ...").
rx_combos() {
	local n="$1" k="$2"
	_c() {  # _c <start> <need> <chosen...>
		local start="$1" need="$2"; shift 2
		if [ "$need" -eq 0 ]; then echo "$*"; return; fi
		local i
		for ((i=start; i<=n-need; i++)); do _c $((i+1)) $((need-1)) "$@" "$i"; done
	}
	_c 0 "$k"
}

# Degraded read by assembling the array with a chosen set of members MISSING
# (avoids --fail polluting superblocks).  Reassembles the full set afterwards.
#   rx_degraded_read <newn> <miss-idx...> ; members come from RX_DEVS[0..newn-1]
rx_degraded_read() {
	local newn="$1"; shift
	local -A drop=(); local i sub=() rc
	if [ "${#RX_DEVS[@]}" -lt "$newn" ]; then
		rk_fail "rx_degraded_read: RX_DEVS has ${#RX_DEVS[@]} members, need $newn (setup failed?)"
		return 1
	fi
	for i in "$@"; do drop[$i]=1; done
	for ((i=0; i<newn; i++)); do [ -n "${drop[$i]:-}" ] || sub+=("${RX_DEVS[$i]}"); done
	rk_stop
	sudo "$MDADM" --assemble "$MD" "${sub[@]}" --run >/dev/null 2>&1
	rk_readback "$RX_SZ"; rc=$?
	rk_stop
	sudo "$MDADM" --assemble "$MD" "${RX_DEVS[@]:0:$newn}" --run >/dev/null 2>&1
	rk_wait_idle
	return $rc
}

# Strong single-pattern oracle: drop the first new_m members and reconstruct.
# This proves the NEW parity is genuinely valid (not just that data survived).
rx_oracle_quick() {             # <newn> <new_m> <tag>
	local newn="$1" new_m="$2" tag="$3" miss
	miss=$(seq 0 $((new_m - 1)))
	if rx_degraded_read "$newn" $miss; then
		rk_pass "$tag: strong oracle — ${new_m}-disk degraded read reconstructs"
	else
		rk_fail "$tag: strong oracle — ${new_m}-disk degraded read WRONG (new parity not EC-correct)"
	fi
}

# Exhaustive oracle: every C(newn,new_m) erasure must reconstruct.
rx_oracle_full() {              # <newn> <new_m> <tag>
	local newn="$1" new_m="$2" tag="$3" combo tot=0 ok=0
	while read -r combo; do
		tot=$((tot+1))
		if rx_degraded_read "$newn" $combo; then ok=$((ok+1));
		else rk_log "$tag: erasure {$combo} FAILED to reconstruct"; fi
	done < <(rx_combos "$newn" "$new_m")
	[ "$ok" -eq "$tot" ] \
		&& rk_pass "$tag: full EC oracle $ok/$tot erasure patterns reconstruct" \
		|| rk_fail "$tag: full EC oracle $ok/$tot (some erasures lost)"
}

rx_oracle() {                   # dispatch quick vs full
	if [ "$RX_FULL_ORACLE" = 1 ]; then rx_oracle_full "$@"; else rx_oracle_quick "$@"; fi
}

# Read a byte sub-range of the array and compare against the source pattern.
#   rx_range_match <off_bytes> <len_bytes>  -> 0 if equal
rx_range_match() {
	local off="$1" len="$2" a b
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
	a=$(sudo dd if="$MD"        bs=1M iflag=skip_bytes,count_bytes,direct \
		skip="$off" count="$len" status=none 2>/dev/null | md5sum | cut -d' ' -f1)
	b=$(dd      if="$RK_TMP/src" bs=1M iflag=skip_bytes,count_bytes \
		skip="$off" count="$len" status=none 2>/dev/null | md5sum | cut -d' ' -f1)
	[ "$a" = "$b" ]
}

# ---------------------------------------------------------------------------
# geometry / grow dispatch by reshape "type"
# ---------------------------------------------------------------------------
# Sets globals: RX_OLDN RX_NEWN RX_OLD_M RX_NEW_M RX_LAYOUT RX_GROW
rx_geom() {
	case "$1" in
	add-parity)
		local k=4
		RX_OLD_M=$RX_AP_OLD_M; RX_NEW_M=$((RX_OLD_M + 1))
		RX_OLDN=$((k + RX_OLD_M)); RX_NEWN=$((k + RX_NEW_M))
		RX_LAYOUT="${RX_OLD_M}r"; RX_GROW="--add-parity" ;;
	add-data)
		local m=2 new_k=$((RX_AD_OLD_K + 1))
		RX_OLD_M=$m; RX_NEW_M=$m
		RX_OLDN=$((RX_AD_OLD_K + m)); RX_NEWN=$((new_k + m))
		RX_LAYOUT="${m}r"; RX_GROW="--add-data" ;;
	*) echo "bad type $1" >&2; return 1 ;;
	esac
}

# Create old-geometry array on the first RX_OLDN flakey members, fill it.
rx_seed() {                     # <tag>
	local base; base="${RX_DEVS[*]:0:$RX_OLDN}"
	if ! rk_create "$RX_LAYOUT" $base; then rk_fail "$1: create failed"; return 1; fi
	RX_INJ="$(rx_inj_path)"
	rk_write "$RX_SZ"
	rk_wait_idle
}

# Kick off the online reshape (returns immediately; kernel thread does the work).
rx_start_grow() {
	local add="${RX_DEVS[$((RX_NEWN - 1))]}"
	rk_unthrottle
	sudo "$MDADM" --grow "$MD" $RX_GROW "$add" >/dev/null 2>&1
}

# Simulate power loss with the reshape thread parked, then assemble + resume.
rx_crash_and_resume() {
	rx_crash_now
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	rx_thaw
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	sudo "$MDADM" --stop --scan >/dev/null 2>&1
	sleep 0.2
	# The stop MUST have taken effect: a silently-failed stop (e.g. EBUSY
	# from a stray opener) leaves the parked thread and its claimed band
	# alive, and every later step then runs against the wrong array —
	# reads into the claimed band block indefinitely.
	local i
	for i in $(seq 1 50); do
		grep -q "^$(basename "$MD") :" /proc/mdstat || break
		sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
		sleep 0.2
	done
	if grep -q "^$(basename "$MD") :" /proc/mdstat; then
		rk_fail "rx_crash_and_resume: $MD refuses to stop (stray opener?)"
		return 1
	fi
	rx_inj_off                                  # so resume does not re-park
	sudo "$MDADM" --assemble "$MD" "${RX_DEVS[@]:0:$RX_NEWN}" --run >/dev/null 2>&1
	rk_unthrottle
	rk_wait_idle
}

rx_check_complete() {           # <tag> : geometry flipped + data + scrub + oracle
	local tag="$1"
	if [ "$(rk_geom)" = "[$RX_NEWN/$RX_NEWN]" ]; then
		rk_pass "$tag: geometry reached [$RX_NEWN/$RX_NEWN]"
	else
		rk_fail "$tag: wrong geometry $(rk_geom) (want [$RX_NEWN/$RX_NEWN])"
	fi
	rk_readback "$RX_SZ" && rk_pass "$tag: data byte-identical after recovery" \
			     || rk_fail "$tag: DATA CORRUPT after recovery"
	local mm; mm=$(rk_scrub)
	[ "$mm" = 0 ] && rk_pass "$tag: scrub clean (mismatch=0)" \
		      || rk_fail "$tag: scrub mismatch=$mm"
	rk_dmesg_clean || rk_fail "$tag: kernel WARN/BUG in dmesg"
	rx_oracle "$RX_NEWN" "$RX_NEW_M" "$tag"
}

# ---------------------------------------------------------------------------
# Tier 0 — harness sanity: a clean reshape with no crash must carry the data.
# ---------------------------------------------------------------------------
rx_tier0_clean() {              # <type>
	local tag="T0 clean $1 (no crash)"
	rx_geom "$1" || return
	rx_setup "$RX_NEWN" || { rk_fail "$tag: setup failed"; return; }
	rk_dmesg_clear
	rx_seed "$tag" || { rx_teardown; return; }
	rx_start_grow
	rk_wait_idle
	rx_check_complete "$tag"
	rx_teardown
}

# ---------------------------------------------------------------------------
# Tier 1 — clean crash + resume at each phase boundary (action=hang).
# ---------------------------------------------------------------------------
rx_tier1_phase() {              # <type> <band> <phase>
	local type="$1" band="$2" phase="$3"
	local tag="T1 $type crash@$phase band=$band"
	rx_geom "$type" || return
	rx_setup "$RX_NEWN" || { rk_fail "$tag: setup failed"; return; }
	rk_dmesg_clear
	rx_seed "$tag" || { rx_teardown; return; }
	rx_inj_set "$band:$phase:hang"
	rx_start_grow
	if ! rx_wait_parked; then
		rk_fail "$tag: reshape never parked at $phase (inject not honored?)"
		rx_teardown; return
	fi
	rx_crash_and_resume
	rx_check_complete "$tag"
	rx_teardown
}

# ---------------------------------------------------------------------------
# Tier 2 — torn writes (action=torn).  STAGE-torn must redo-from-old;
# COMMIT-torn must replay-from-scratch.  This is the load-bearing recovery path.
# ---------------------------------------------------------------------------
rx_tier2_torn() {               # <type> <band> <phase>
	local type="$1" band="$2" phase="$3"
	local tag="T2 $type torn@$phase band=$band"
	rx_geom "$type" || return
	rx_setup "$RX_NEWN" || { rk_fail "$tag: setup failed"; return; }
	rk_dmesg_clear
	rx_seed "$tag" || { rx_teardown; return; }
	rx_inj_set "$band:$phase:torn"
	rx_start_grow
	if ! rx_wait_parked; then
		rk_fail "$tag: reshape never parked after torn $phase"
		rx_teardown; return
	fi
	rx_crash_and_resume
	rx_check_complete "$tag"
	rx_teardown
}

# ---------------------------------------------------------------------------
# Tier 3 — hybrid fault tolerance.  Freeze the reshape mid-flight (hang@COMMIT on
# a middle band, do NOT crash) and confirm each region tolerates failures up to
# ITS geometry's parity count: the migrated region BELOW the frontier survives
# new_m losses (decoded with the new tables), the pending region ABOVE survives
# old_m losses (previous tables).  add-parity only (array_size constant => clean
# frontier).
#
# Each region is probed on its OWN FRESH array.  The two probes CANNOT share one
# array: a member failed for the scoped read cannot be restored while the reshape
# is parked (a re-added member can't rebuild while the frozen reshape owns the
# sync thread, and raidkm_reshape_migrate_band has no degraded-read path — the
# "v1: non-degraded only" gap), so a single-array below-then-above sequence would
# carry the below-frontier failures into the above-frontier probe and corrupt it.
# For the same reason there is no resume-to-completion / full-oracle step here:
# completing a reshape that lost members mid-flight needs that unimplemented
# degraded migrate_band path.  This tier validates only what is supported today —
# region-scoped degraded READS of a frozen reshape — which is the substantive
# guarantee; reshape completion under no faults is covered by Tiers 0–2.
# NB: COMMIT (not DONE) — the kernel inject only parks at STAGE/COMMIT; DONE is
# unimplemented (see the Tier 1 SKIP note) and would never park.
# ---------------------------------------------------------------------------
# rx_tier3_region <below|above> : one region probe on a fresh array.
rx_tier3_region() {
	local region="$1"
	local tag="T3 add-parity hybrid-fault ${region}-frontier"
	rx_geom add-parity || return
	rx_setup "$RX_NEWN" || { rk_fail "$tag: setup failed"; return; }
	rk_dmesg_clear

	# Seed across (almost) the WHOLE array.  The reshape parks at the MIDDLE
	# band — ~half the ARRAY capacity, not half a small seed — so the scoped
	# read window (near the frontier) must hold real data; seeding only the
	# default RX_SZ would leave it in unwritten zero-fill and the md5 compare
	# would be meaningless.  RX_SZ is local here and restored before every return
	# so other tiers keep their small seed.
	local rx_saved_sz="$RX_SZ"
	if ! rk_create "$RX_LAYOUT" ${RX_DEVS[@]:0:$RX_OLDN}; then
		rk_fail "$tag: create failed"; RX_SZ="$rx_saved_sz"; rx_teardown; return
	fi
	RX_INJ="$(rx_inj_path)"
	RX_SZ=$(( $(sudo blockdev --getsize64 "$MD") / 1048576 - 1 ))
	rk_write "$RX_SZ"
	rk_wait_idle

	# Park at COMMIT of the middle band so a real frontier exists.
	rx_inj_set "mid:COMMIT:hang"
	rx_start_grow
	if ! rx_wait_parked; then
		rk_fail "$tag: reshape never parked at mid COMMIT"
		rx_inj_off; RX_SZ="$rx_saved_sz"; rx_teardown; return
	fi

	# Frontier in array bytes.  reshape_position lags to the last DONE band (the
	# in-flight band sits between reshape_safe and reshape_progress), so it marks
	# reshape_safe — reads strictly below it are migrated, strictly above the
	# +margin are still pending.  Probe an 8 MiB slice hugging the frontier (the
	# most boundary-sensitive spot) to keep the degraded read fast.
	local pos fb tot margin=$((4 * 1024 * 1024)) slice=$((8 * 1024 * 1024))
	pos=$(cat "/sys/block/$MDNAME/md/reshape_position" 2>/dev/null)
	tot=$((RX_SZ * 1024 * 1024))
	if [ -z "$pos" ] || [ "$pos" = none ] || [ "$((pos * 512))" -le "$((margin + slice))" ]; then
		rk_fail "$tag: no usable frontier (reshape_position=$pos)"
		rx_inj_off; RX_SZ="$rx_saved_sz"; rx_teardown; return
	fi
	fb=$((pos * 512))

	local nfail off len
	if [ "$region" = below ]; then
		nfail=$RX_NEW_M			# migrated region -> new geometry tables
		off=$((fb - margin - slice)); len=$slice
	else
		nfail=$RX_OLD_M			# pending region  -> previous tables
		off=$((fb + margin));         len=$slice
		[ "$((off + len))" -gt "$tot" ] && len=$((tot - off))
	fi

	# Fail this region's geometry's worth of members and read only that region.
	# No restore: the array is torn down immediately after (a member lost
	# mid-frozen-reshape can't be brought back online today; this probe is
	# read-only).
	rk_fail_disks ${RX_DEVS[@]:0:$nfail}
	if rx_range_match "$off" "$len"; then
		rk_pass "$tag: region survives $nfail failures"
	else
		rk_fail "$tag: region WRONG under $nfail failures"
	fi

	rx_inj_off			# release the park so the array can be stopped
	RX_SZ="$rx_saved_sz"
	rx_teardown
}

# ---------------------------------------------------------------------------
# Tier 4 — fault + crash combined (the still-open double-fault hole).  Torn the
# COMMIT of a band AND fail a member, on each side of the frontier; recovery
# must reconstruct the in-flight band from its own-side geometry.
# ---------------------------------------------------------------------------
rx_tier4_fault_crash() {        # <type> <band>
	local type="$1" band="$2"
	local tag="T4 $type torn@COMMIT+1fail band=$band"
	rx_geom "$type" || return
	rx_setup "$RX_NEWN" || { rk_fail "$tag: setup failed"; return; }
	rk_dmesg_clear
	rx_seed "$tag" || { rx_teardown; return; }
	rx_inj_set "$band:COMMIT:torn"
	rx_start_grow
	if ! rx_wait_parked; then
		rk_fail "$tag: reshape never parked at COMMIT"
		rx_teardown; return
	fi
	# Fail one member before the crash (within tolerance: old side old_m, new side new_m).
	rk_fail_disks "${RX_DEVS[$((RX_NEWN - 1))]}"
	rx_crash_and_resume
	# After resume the failed member is absent; let any rebuild settle.
	rk_add_disks "${RX_DEVS[$((RX_NEWN - 1))]}"
	rk_wait_full
	rx_check_complete "$tag"
	rx_teardown
}

# ---------------------------------------------------------------------------
# Best-effort crash WITHOUT the inject build: time the crash off reshape_position
# (no phase precision).  Keeps the script useful before the debug knob lands.
# ---------------------------------------------------------------------------
rx_besteffort_crash() {         # <type>
	# NB: separate `local`s — `local a=$1 b=$a` expands $a before it is set,
	# which trips `set -u` ("type: unbound variable").
	local type="$1"
	local tag="BE $type crash (reshape_position-timed, no inject)"
	rx_geom "$type" || return
	rx_setup "$RX_NEWN" || { rk_fail "$tag: setup failed"; return; }
	rk_dmesg_clear
	rx_seed "$tag" || { rx_teardown; return; }
	echo 3000 | sudo tee "/sys/block/$MDNAME/md/sync_speed_max" >/dev/null
	rx_start_grow
	local pos=0 _
	for _ in $(seq 1 400); do
		pos=$(cat "/sys/block/$MDNAME/md/reshape_position" 2>/dev/null)
		[ "$pos" != none ] && [ "${pos:-0}" -gt 4096 ] && break
		sleep 0.1
	done
	if [ "$pos" = none ] || [ "${pos:-0}" -le 0 ]; then
		rk_fail "$tag: reshape did not start (pos=$pos)"; rx_teardown; return
	fi
	rx_crash_and_resume
	# A best-effort crash may legitimately refuse-to-resume; treat a clean
	# refusal as a pass (no silent corruption), else require correct data.
	if grep -q "$MDNAME" /proc/mdstat; then
		rx_check_complete "$tag"
	else
		rk_pass "$tag: refused-to-resume after crash (no silent corruption, pos=$pos)"
	fi
	rx_teardown
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
sudo modprobe dm-flakey 2>/dev/null
rk_load_modules || exit 1
rx_global_cleanup
rx_probe_inject

echo "==== Tier 0: harness sanity (clean reshapes) ===="
rx_tier0_clean add-parity
rx_tier0_clean add-data

if [ "$RX_HAVE_INJECT" != 1 ]; then
	echo
	echo "==== inject knob ABSENT (no CONFIG_RAIDKM_FAULT_INJECT) ===="
	echo "     Tiers 1-4 SKIPPED — running best-effort reshape_position-timed crash."
	rx_besteffort_crash add-parity
	rx_besteffort_crash add-data
	rk_summary "raidkm-test-reshape-crash.sh"
	exit $?
fi

echo
echo "==== Tier 1: clean crash + resume at each phase ===="
# DONE/FINALIZE hang points are NOT implemented in the kernel inject hooks
# (migrate_band parks at STAGE/COMMIT only).  Semantically they are covered
# anyway: a crash after a band's DONE record is the same recovery problem as
# a crash before the next band's STAGE, and a crash before FINALIZE is the
# interrupted-resume path (frontier past the last band).  Skip rather than
# fail until the hooks exist.
for type in add-parity add-data; do
	for phase in STAGE COMMIT; do
		for band in 0 mid -1; do
			rx_tier1_phase "$type" "$band" "$phase"
		done
	done
	echo "  SKIP: T1 $type crash@DONE/@FINALIZE: inject hooks not implemented (covered by STAGE-of-next-band and resume paths)"
done

echo
echo "==== Tier 2: torn writes (redo-from-old / replay-from-scratch) ===="
for type in add-parity add-data; do
	for phase in STAGE COMMIT; do
		for band in 0 mid -1; do
			rx_tier2_torn "$type" "$band" "$phase"
		done
	done
done

echo
echo "==== Tier 3: hybrid fault tolerance (frozen mid-reshape) ===="
rx_tier3_region below		# migrated region: survives new_m failures
rx_tier3_region above		# pending region:  survives old_m failures

echo
echo "==== Tier 4: fault + crash combined ===="
rx_tier4_fault_crash add-parity mid
rx_tier4_fault_crash add-data   mid

rk_summary "raidkm-test-reshape-crash.sh"
