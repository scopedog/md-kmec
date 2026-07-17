#!/bin/bash
# raidkm-test-lib.sh — shared helpers for the raidkm (md level 71) test scripts.
#
# Source this from a test script; it is not meant to be run directly:
#   . "$(dirname "$0")/raidkm-test-lib.sh"
#
# Configuration (all overridable via the environment):
#   MD          md device to use                  (default /dev/md70)
#   MDADM       path to the raidkm-aware mdadm     (auto: fork, else PATH)
#   RAIDKM_KO   raidkm.ko path                     (default <tree>/km/raidkm.ko)
#   ISAL_KO     isal_lib.ko path                   (default <tree>/isa-l/isal_lib.ko)
#   RK_RELOAD   1 = rmmod+insmod raidkm each run   (default 0: load only if absent)
#   BRD_NR      ramdisks to create if none present (default 12)
#   BRD_SIZE_KB ramdisk size in KiB                (default 262144 = 256 MiB)
#   CHUNK_KB    array chunk size in KiB            (default 64)
#   RK_TMP      scratch dir for data checksums     (default /tmp/raidkm-test)
#
# Tests need root (sudo) for modprobe/insmod, mdadm, sysfs and drop_caches.

RK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RK_TREE="$(cd "$RK_LIB_DIR/.." && pwd)"          # md-kmec checkout root

MD="${MD:-/dev/md70}"
MDNAME="$(basename "$MD")"
MDADM="${MDADM:-}"                               # resolved by rk_resolve_mdadm
RK_SRC_MD5="${RK_SRC_MD5:-}"
RAIDKM_KO="${RAIDKM_KO:-$RK_TREE/km/raidkm.ko}"
ISAL_KO="${ISAL_KO:-$RK_TREE/isa-l/isal_lib.ko}"
RK_RELOAD="${RK_RELOAD:-0}"
BRD_NR="${BRD_NR:-12}"
BRD_SIZE_KB="${BRD_SIZE_KB:-262144}"
CHUNK_KB="${CHUNK_KB:-64}"
RK_TMP="${RK_TMP:-/tmp/raidkm-test}"

RK_PASS=0
RK_FAIL=0

rk_log()  { echo "    $*"; }
rk_pass() { RK_PASS=$((RK_PASS + 1)); echo "  PASS: $*"; }
rk_fail() { RK_FAIL=$((RK_FAIL + 1)); echo "  FAIL: $*" >&2; }

# Print a summary and return non-zero if anything failed (use as the exit code).
rk_summary() {
	echo
	echo "==== $(basename "$0"): $RK_PASS passed, $RK_FAIL failed ===="
	[ "$RK_FAIL" -eq 0 ]
}

# Resolve a *raidkm-aware* mdadm and verify it (a stock mdadm rejects level 71).
# Candidates: $MDADM, the invoking user's fork checkout (sudo resets $HOME to
# root's, so use SUDO_USER's home), a sibling checkout, then PATH.  Each is
# accepted only if its binary actually contains the "raidkm" literal — that
# weeds out a stock /sbin/mdadm silently shadowing the fork.
rk_resolve_mdadm() {
	local c home cand
	home=$(getent passwd "${SUDO_USER:-$USER}" 2>/dev/null | cut -d: -f6)
	[ -n "$home" ] || home="$HOME"
	cand=( "$MDADM"
	       "$home/projects/mdraid/mdadm/mdadm"
	       "$home/mdadm/mdadm"
	       "$RK_TREE/../mdadm/mdadm"
	       "$(command -v mdadm 2>/dev/null)" )
	for c in "${cand[@]}"; do
		[ -n "$c" ] && [ -x "$c" ] && grep -qa raidkm "$c" && { MDADM="$c"; return 0; }
	done
	echo "ERROR: no raidkm-aware mdadm found — set MDADM=/path/to/fork/mdadm" >&2
	echo "       (a stock mdadm rejects --level=raidkm). tried: ${cand[*]}" >&2
	return 1
}

# Load raidkm + its deps (the async_tx family is NOT pulled in by raid6_pq).
# Guard against the stale-module trap.  rk_load_modules() only insmods a module
# when it is absent, so a stale module left loaded from an earlier run (e.g. a
# pre-fix raidkm.ko) would be exercised SILENTLY — a real foot-gun that has
# masked a parity-rebuild bug before.  Compare the loaded module's srcversion
# (/sys/module/<mod>/srcversion) against the .ko the test intends to use; on a
# mismatch fail loudly (or warn, for non-critical modules).
#   rk_verify_srcversion <module> <ko-path> [warn]
# Override with RK_SKIP_SRCVERSION=1.
rk_verify_srcversion() {
	local mod="$1" ko="$2" mode="${3:-fail}" loaded want
	[ "${RK_SKIP_SRCVERSION:-0}" = 1 ] && return 0
	loaded="$(cat "/sys/module/$mod/srcversion" 2>/dev/null)" || return 0
	[ -n "$loaded" ] || return 0            # builtin or no modversions: nothing to check
	if [ -f "$ko" ]; then
		want="$(modinfo -F srcversion "$ko" 2>/dev/null)"
	else
		want="$(modinfo -F srcversion "$mod" 2>/dev/null)"   # fall back to depmod'd module
	fi
	[ -n "$want" ] || return 0
	if [ "$loaded" = "$want" ]; then
		rk_log "$mod srcversion $loaded matches $(basename "${ko:-$mod}")"
		return 0
	fi
	if [ "$mode" = warn ]; then
		echo "  WARN: loaded $mod srcversion $loaded != ${ko:-$mod} ($want)" >&2
		return 0
	fi
	echo "ERROR: a stale $mod is loaded: srcversion $loaded != ${ko:-$mod} ($want)." >&2
	echo "       rmmod it (or run with RK_RELOAD=1) so the .ko under test is the one exercised." >&2
	echo "       Set RK_SKIP_SRCVERSION=1 to bypass this check." >&2
	return 1
}

rk_load_modules() {
	rk_resolve_mdadm || { echo "ERROR: no mdadm found (set MDADM=)" >&2; return 1; }
	if [ "$RK_RELOAD" = 1 ]; then
		sudo rmmod raidkm 2>/dev/null || true
	fi
	if ! lsmod | grep -q '^raidkm '; then
		local m
		# md_mod + libcrc32c: builtin on RHEL (these modprobes no-op), but a
		# loadable module on mainline/Debian — raidkm pulls md_*/crc32c symbols
		# from them, so they must be loaded first or insmod fails Unknown-symbol.
		for m in md_mod libcrc32c async_tx async_memcpy async_xor async_pq \
			 async_raid6_recov raid6_pq xor; do
			sudo modprobe "$m" 2>/dev/null || true
		done
		if [ -f "$ISAL_KO" ]; then
			sudo insmod "$ISAL_KO" 2>/dev/null || true
		else
			sudo modprobe isal_lib 2>/dev/null || true
		fi
		sudo insmod "$RAIDKM_KO" 2>/dev/null || true
	fi
	lsmod | grep -q '^raidkm ' || {
		echo "ERROR: raidkm not loaded (RAIDKM_KO=$RAIDKM_KO, ISAL_KO=$ISAL_KO)" >&2
		return 1
	}
	# The loaded module must be the .ko under test, not a stale leftover.
	rk_verify_srcversion raidkm   "$RAIDKM_KO" fail || return 1
	rk_verify_srcversion isal_lib "$ISAL_KO"   warn || return 1
	mkdir -p "$RK_TMP"
}

# Ensure at least <need> (default $BRD_NR) block-device ram* nodes exist.
# RK_DEVS: space-separated list of REAL block devices to test on instead of brd
# (real-HW gating: NVMe timing exercises the store-vs-worker/drain windows that
# a ramdisk's ~microsecond latency hides).  When set, rk_setup_brd is a no-op
# and rk_pick_disks serves from this list.  The caller is responsible for the
# devices being wipeable (rk_create zeroes them).
RK_DEVS="${RK_DEVS:-}"

rk_setup_brd() {
	local need="${1:-$BRD_NR}" have want
	if [ -n "$RK_DEVS" ]; then
		have=$(rk_pick_disks "$need" 2>/dev/null | wc -w)
		[ "$have" -ge "$need" ] && return 0
		echo "ERROR: RK_DEVS has $have devices, need $need" >&2
		return 1
	fi
	have=$(rk_pick_disks "$need" 2>/dev/null | wc -w)
	[ "$have" -ge "$need" ] && return 0
	# Too few ram devices.  brd may already be loaded at a smaller rd_nr from a
	# prior (smaller-NDISK) test -- a plain modprobe is then a no-op, the count
	# never grows, and the caller fails "need N, found M" (e.g. mparity needs 11
	# ram disks but a preceding NDISK=6 test left brd at 6).  Force a reload at a
	# count covering this caller (the larger of $need and $BRD_NR).  rmmod fails
	# harmlessly if a stale array still holds a ram dev, in which case we fall
	# back to the plain modprobe -- no worse than before.
	want=$need; [ "${BRD_NR:-0}" -gt "$want" ] && want=$BRD_NR
	lsmod | grep -q '^brd ' && sudo rmmod brd 2>/dev/null
	sudo modprobe brd rd_nr="$want" rd_size="$BRD_SIZE_KB" 2>/dev/null || true
	have=$(rk_pick_disks "$need" 2>/dev/null | wc -w)
	[ "$have" -ge "$need" ]
}

# Echo the first <n> working /dev/ram* block devices (skips broken nodes).
rk_pick_disks() {
	local need="$1" picked=() d
	for d in ${RK_DEVS:-/dev/ram*}; do
		[ -b "$d" ] || continue
		sudo blockdev --getsize64 "$d" >/dev/null 2>&1 || continue
		picked+=("$d")
		[ "${#picked[@]}" -ge "$need" ] && break
	done
	[ "${#picked[@]}" -ge "$need" ] || {
		echo "ERROR: need $need devices, found only ${#picked[@]} (RK_DEVS='${RK_DEVS:-}')" >&2
		return 1
	}
	echo "${picked[@]}"
}

# Numeric parity count m from a layout string ("3" or "3r" -> 3).
rk_m_of() { echo "${1//[!0-9]/}"; }

rk_stop() {
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	sudo "$MDADM" --stop /dev/md127 2>/dev/null
	return 0
}

# rk_create <layout> <dev...> : wipe the members and create a raidkm array.
rk_create() {
	local layout="$1"; shift
	local n=$#
	rk_stop
	# A prior run may have left $MD as a regular file (a dd to $MD while the
	# array was down creates one); mdadm then refuses "not an md array".
	[ -e "$MD" ] && [ ! -b "$MD" ] && sudo rm -f "$MD"
	local d
	# With native integrity, zero the whole member so a prior array's checksum
	# region can't leave stale CRCs behind (mdadm zeroing the reserved region at
	# create is the product-side follow-up); otherwise just wipe the head.
	for d in "$@"; do
		if [[ "${RK_CREATE_EXTRA:-}" == *integrity* ]]; then
			sudo dd if=/dev/zero of="$d" bs=1M status=none 2>/dev/null || true
		else
			sudo dd if=/dev/zero of="$d" bs=1M count=4 status=none 2>/dev/null
		fi
	done
	# layout arg stays "N"/"Nr" for callers; translate to the current CLI
	# (--parity-count + --layout=rotating|parity-last).
	local m place
	m=$(rk_m_of "$layout")
	[ "${layout: -1}" = r ] && place=rotating || place=parity-last
	sudo "$MDADM" --create "$MD" --level=raidkm \
		--parity-count="$m" --layout="$place" \
		--raid-devices="$n" --chunk="$CHUNK_KB" ${RK_CREATE_EXTRA:-} "$@" --run --force \
		>/dev/null 2>&1 || return 1
	rk_wait_idle
}

# rk_assemble <dev...> : re-assemble an existing raidkm array (persistence tests).
rk_assemble() {
	sudo "$MDADM" --assemble "$MD" "$@" >/dev/null 2>&1 || return 1
	rk_wait_idle
}

# Wait for any background resync/recovery/reshape/check to finish.
rk_wait_idle() {
	local i
	for i in $(seq 1 1200); do
		grep -qiE 'resync|recovery|reshape|check' /proc/mdstat || break
		sleep 0.5
	done
}

# rk_wait_full : wait until the array is fully in-sync — no recovery in flight
# AND no degraded/rebuilding slot.  Robust against the gap between issuing
# --add / --replace and md actually starting the recovery (rk_wait_idle alone
# returns early in that window because the recovery string isn't there yet).
rk_wait_full() {
	local i
	# give md up to ~5s to notice the event and start a sync action
	for i in $(seq 1 20); do
		grep -qiE 'recovery|resync|reshape|check' /proc/mdstat && break
		[ "$(cat "/sys/block/$MDNAME/md/degraded" 2>/dev/null)" = "0" ] || break
		sleep 0.25
	done
	# then wait for it to finish and for every slot to be in-sync
	for i in $(seq 1 1200); do
		if ! grep -qiE 'recovery|resync|reshape|check' /proc/mdstat &&
		   [ "$(cat "/sys/block/$MDNAME/md/degraded" 2>/dev/null)" = "0" ]; then
			break
		fi
		sleep 0.5
	done
}

# rk_write <MiB> : fill the array with random data, remember its checksum.
rk_write() {
	sudo dd if=/dev/urandom of="$RK_TMP/src" bs=1M count="$1" status=none 2>/dev/null
	sudo dd if="$RK_TMP/src" of="$MD" bs=1M count="$1" oflag=direct status=none 2>/dev/null
	sync
	RK_SRC_MD5=$(md5sum "$RK_TMP/src" | cut -d' ' -f1)
}

# rk_readback <MiB> : drop caches, read back, return 0 iff it matches rk_write.
rk_readback() {
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
	sudo dd if="$MD" of="$RK_TMP/rd" bs=1M count="$1" iflag=direct status=none 2>/dev/null
	[ "$(md5sum "$RK_TMP/rd" | cut -d' ' -f1)" = "$RK_SRC_MD5" ]
}

# Run a parity scrub and echo the resulting mismatch_cnt.
rk_scrub() {
	echo check | sudo tee "/sys/block/$MDNAME/md/sync_action" >/dev/null
	rk_wait_idle
	cat "/sys/block/$MDNAME/md/mismatch_cnt"
}

rk_fail_disks() { local d; for d in "$@"; do sudo "$MDADM" --fail "$MD" "$d" >/dev/null 2>&1; done; sleep 1; }
# Manage-mode helpers for disk replacement.
rk_remove_disks() { local d; for d in "$@"; do sudo "$MDADM" --remove "$MD" "$d" >/dev/null 2>&1; done; }
rk_add_disks()    { local d; for d in "$@"; do sudo "$MDADM" --add    "$MD" "$d" >/dev/null 2>&1; done; }
# rk_replace_disk <victim> [<spare>] : hot-replace a still-live member (md keeps
# the original in service until the copy onto the replacement finishes).
rk_replace_disk() { sudo "$MDADM" "$MD" --replace "$1" ${2:+--with "$2"} >/dev/null 2>&1; }

# Throttle/unthrottle resync/recovery so a stress action can land mid-rebuild.
rk_throttle()   { echo "${1:-1500}" | sudo tee "/sys/block/$MDNAME/md/sync_speed_max" >/dev/null 2>&1; }
rk_unthrottle() { echo 2000000 | sudo tee "/sys/block/$MDNAME/md/sync_speed_max" >/dev/null 2>&1; }
# Wait (up to ~10s) until a recovery is actually in flight (mdstat shows it AND a
# slot is still degraded), so the caller acts WHILE the rebuild runs.
rk_wait_recovery_active() {
	local i
	for i in $(seq 1 40); do
		grep -qi recovery /proc/mdstat &&
		  [ "$(cat "/sys/block/$MDNAME/md/degraded" 2>/dev/null)" != "0" ] && return 0
		sleep 0.25
	done
	return 1
}
rk_grow_data()   { sudo "$MDADM" --grow "$MD" --add-data   "$@" >/dev/null 2>&1 || return 1; rk_wait_idle; }
# rotating add-parity stages data out-of-place through a backup file; PARITY_N
# ignores --backup-file, so passing it unconditionally is safe.
RK_BACKUP="${RK_BACKUP:-/var/tmp/raidkm-test-backup}"
rk_grow_parity() { sudo "$MDADM" --grow "$MD" --add-parity --backup-file="$RK_BACKUP" "$@" >/dev/null 2>&1 || return 1; rk_wait_idle; }

# Current [active/total] geometry from /proc/mdstat, for reporting.
rk_geom() { grep -A1 "$MDNAME" /proc/mdstat | tail -1 | grep -o '\[[0-9]*/[0-9]*\]'; }

# No-WARN/BUG check on the kernel ring buffer since the last rk_dmesg_clear.
rk_dmesg_clear() { sudo dmesg -C >/dev/null 2>&1 || true; }
rk_dmesg_clean() {
	local hits
	hits=$(sudo dmesg 2>/dev/null | grep -iE 'WARN|BUG|map not correct|call trace|gf_invert' |
		grep -civ 'appears to be on the same physical disk')
	[ "${hits:-0}" -eq 0 ]
}

# ---- declustered (Phase 3/3b) shared helpers ---------------------------------
# One home for the primitives every declustered gate used to carry privately
# (pop_show, chunk-I/O oracles, the --examine offset scrape, the accumulated
# dmesg verdict, the udev teardown discipline) — a format or message change
# now lands in exactly one place.

# Population sysfs state (multi-line since 3b: one line per assignment).
rk_pop_show() { cat "/sys/block/$MDNAME/md/rk_dcl_populate" 2>/dev/null; }
rk_pop_mark() { rk_pop_show | sed -n 's/.*mark \([0-9]*\)\/.*/\1/p'; }

# Exactly-chunk-sized 8-byte-tag pattern file at $RK_TMP/<tag><lc>.
rk_mkpat() {	# rk_mkpat <tag3> <lc>
	yes "$1$(printf '%04d' "$2")" | head -c $((CHUNK_KB * 1024)) | \
		sudo tee "$RK_TMP/$1$2" > /dev/null
}
rk_wrchunk() {	# rk_wrchunk <file> <lc>
	sudo dd if="$1" of="$MD" bs="${CHUNK_KB}k" seek="$2" count=1 \
		oflag=direct conv=notrunc,fsync status=none
}
rk_rdchunk() {	# rk_rdchunk <lc> <file>
	sudo dd if="$MD" of="$2" bs="${CHUNK_KB}k" skip="$1" count=1 \
		iflag=direct status=none
}

# Member SB geometry scrapes (mdadm --examine output — the ONE place that
# knows the format).  "Avail Dev Size" == data_size; "Used Dev Size" is
# omitted when equal, so Avail is the one to use for tail-region offsets.
rk_data_offset() {	# rk_data_offset <dev> -> sectors (empty on failure)
	sudo "$MDADM" --examine "$1" 2>/dev/null | \
		sed -n 's/.*Data Offset : \([0-9]*\) sectors.*/\1/p'
}
rk_avail_size() {	# rk_avail_size <dev> -> sectors (empty on failure)
	sudo "$MDADM" --examine "$1" 2>/dev/null | \
		sed -n 's/.*Avail Dev Size : \([0-9]*\) sectors.*/\1/p'
}
# rkdcl metadata block version of a member (block at data_offset + data_size).
rk_rkdcl_version() {	# rk_rkdcl_version <dev> -> version (or -1)
	local do_s av_s
	do_s=$(rk_data_offset "$1"); av_s=$(rk_avail_size "$1")
	[ -n "$do_s" ] && [ -n "$av_s" ] || { echo -1; return; }
	sudo dd if="$1" bs=1 skip=$(( (do_s + av_s) * 512 + 8 )) count=4 \
		status=none 2>/dev/null | od -An -tu4 | tr -d ' '
}

# Accumulated no-WARN/BUG verdict across gates that clear dmesg mid-run:
# call rk_dmesg_window_close before each rk_dmesg_clear, then check
# RK_DMESG_BAD at the end.
RK_DMESG_BAD=0
rk_dmesg_window_close() { rk_dmesg_clean || RK_DMESG_BAD=1; }

# udev teardown discipline for array stop/re-assemble seams: teardown or
# thaw events can trigger udev INCREMENTAL assembly of members into an
# md127 that steals them from the next create/assemble (observed twice:
# a population "resumed fine — on md127", and a 7-member inactive md127
# wedging the next iteration's create).  Settle so udev's assembly (if
# any) completes, tear every scanned array down, settle again so the
# teardown events drain.
rk_udev_quiesce() {
	sudo udevadm settle 2>/dev/null
	sudo "$MDADM" --stop --scan > /dev/null 2>&1
	sudo udevadm settle 2>/dev/null
}
