#!/bin/bash
# raidkm-test-selfheal.sh — Phase 0: checksum-driven self-healing on a stacked
# raidkm-over-dm-integrity config.  Validates that SILENT data corruption (wrong
# bytes, no device error) is caught by the integrity layer, surfaced to md as a
# read error, LOCATED, reconstructed from m>=2 parity, and healed on disk.
#
# Why this test exists (see notes/checksum-self-healing-impl-plan-2026-07-01.md):
# the reconstruction+heal machinery already exists in raid_km.c and is m-general
# (heal loop `s.failed <= raidkm_sh_m(sh)` at ~6524; multi-erasure decode at
# ~4724).  The ONLY missing piece for self-healing is a per-block integrity
# SIGNAL that turns silent corruption into an EIO.  dm-integrity provides exactly
# that, so this test proves "self-healing works today by stacking" and surfaces
# the real gaps (esp. whether the scrub path heals >2 erasures/stripe — the
# deferred Phase 2 differentiator).
#
# The corruption is injected on the RAW backing device, UNDER dm-integrity, so
# the integrity layer's stored checksum no longer matches — i.e. genuinely silent
# corruption, not a reported media error.  We locate a block by writing a unique
# ASCII needle through the array and grepping for it on the members.
#
#   sudo bash tools/raidkm-test-selfheal.sh
#
# Extra config (beyond raidkm-test-lib.sh):
#   NDISK      members (dm-integrity devices) to build          (default 6)
#   MSET       parity counts to sweep                           (default "2 3 4")
#   LAYOUTS    layouts per m: r=rotating, p=parity-last            (default "r p")
#   WRITE_MIB  data written to the array per case                (default 8)
# This test forces small 64 MiB ramdisks (dm-integrity wants to format them).
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

NDISK="${NDISK:-6}"
MSET="${MSET:-2 3 4}"
LAYOUTS="${LAYOUTS:-r p}"
WRITE_MIB="${WRITE_MIB:-8}"
NATIVE="${NATIVE:-0}"                       # 1 = raidkm native CRC (P1a), no dm-integrity
BLK=4096                                   # corruption granularity (one page)
: "${BRD_NR:=$NDISK}" ; export BRD_NR
: "${BRD_SIZE_KB:=65536}" ; export BRD_SIZE_KB   # 64 MiB — keep format/wipe cheap

SI_INAME=()      # dm-integrity mapping names (rkshi0..)
SI_MAPPER=()     # /dev/mapper/<name>  — the array members
SI_BACKING=()    # /dev/ramN           — the raw devices we corrupt under integrity
SI_DEV="" ; SI_OFF=""                     # si_locate() results

# ---- teardown -------------------------------------------------------------
si_teardown() {
	rk_stop
	local n
	[ "$NATIVE" = 1 ] && return 0
	for n in "${SI_INAME[@]:-}"; do
		[ -n "$n" ] && sudo integritysetup close "$n" 2>/dev/null
	done
}
trap si_teardown EXIT

# ---- helpers --------------------------------------------------------------
# A 4 KiB block of a unique, greppable ASCII needle for id $1.
si_marker() {
	local tok reps
	tok=$(printf 'RKSH-NEEDLE-%04d-' "$1")
	reps=$(( BLK / ${#tok} + 1 ))
	yes "$tok" | head -n "$reps" | tr -d '\n' | head -c "$BLK"
}

# Rewrite the whole written region from the source file: heals data, parity AND
# dm-integrity tags for every block we ever touch, giving each scenario (and the
# next --create) a known-clean array regardless of prior (possibly uncorrectable)
# corruption.
si_restore() {
	sudo dd if="$RK_TMP/src" of="$MD" bs=1M count="$WRITE_MIB" \
		oflag=direct status=none 2>/dev/null
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
}

# Build the source (random + K needles at stripe-row-0 data-slot offsets), write
# it to the array, remember its md5.  Needle j lands in data slot j of stripe row
# 0 -> a DATA block on a distinct member, so corrupting j needles = j data
# erasures in ONE stripe.
si_write_baseline() {
	local k="$1" j off
	sudo dd if=/dev/urandom of="$RK_TMP/src" bs=1M count="$WRITE_MIB" status=none 2>/dev/null
	for ((j = 0; j < k; j++)); do
		off=$(( j * CHUNK_KB * 1024 ))
		si_marker "$j" > "$RK_TMP/needle.$j"
		sudo dd if="$RK_TMP/needle.$j" of="$RK_TMP/src" bs=1 seek="$off" \
			conv=notrunc status=none 2>/dev/null
	done
	sudo dd if="$RK_TMP/src" of="$MD" bs=1M count="$WRITE_MIB" \
		oflag=direct status=none 2>/dev/null
	sync
	RK_SRC_MD5=$(md5sum "$RK_TMP/src" | cut -d' ' -f1)
}

# Find needle id $1 on the members -> SI_DEV, SI_OFF (byte offset on the backing
# device).  It lives on exactly one member (it is one data block).
si_locate() {
	local tok d hit
	tok=$(printf 'RKSH-NEEDLE-%04d-' "$1")
	SI_DEV="" ; SI_OFF=""
	for d in "${SI_BACKING[@]}"; do
		hit=$(sudo grep -a -b -o -m1 "$tok" "$d" 2>/dev/null | head -1)
		[ -n "$hit" ] && { SI_DEV="$d"; SI_OFF="${hit%%:*}"; return 0; }
	done
	return 1
}

# Silently corrupt one page at SI_DEV/SI_OFF (raw device, UNDER dm-integrity).
si_corrupt_here() {
	sudo dd if=/dev/urandom of="$SI_DEV" bs=1 seek="$SI_OFF" count="$BLK" \
		conv=notrunc status=none 2>/dev/null
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
}

# Corrupt needles 0..($1-1): $1 data erasures in stripe row 0.
si_corrupt_n() {
	local n="$1" i
	for ((i = 0; i < n; i++)); do
		si_locate "$i" || { rk_log "could not locate needle $i on any member"; return 1; }
		si_corrupt_here
	done
}

si_repair() {
	# Flush the md stripe cache first.  A stripe still cached clean from the
	# preceding si_restore write would otherwise hide the on-disk corruption
	# from the scrub: the resync trusts UPTODATE cached pages and never
	# re-reads the (corrupt) disk, so the repair would "miss" a freshly
	# corrupted block.  Shrinking stripe_cache_size to the minimum evicts the
	# inactive cached stripes; restoring it re-enables normal operation.
	local scs
	scs=$(cat "/sys/block/$MDNAME/md/stripe_cache_size" 2>/dev/null)
	echo 17 | sudo tee "/sys/block/$MDNAME/md/stripe_cache_size" >/dev/null 2>&1
	[ -n "$scs" ] && echo "$scs" | sudo tee "/sys/block/$MDNAME/md/stripe_cache_size" >/dev/null 2>&1
	echo repair | sudo tee "/sys/block/$MDNAME/md/sync_action" >/dev/null 2>&1
	rk_wait_idle
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1
}

# On-disk heal proof: after a heal, md rewrites the reconstructed block through
# dm-integrity, so the original ASCII marker bytes reappear on the backing member
# (our urandom corruption contains no marker token).  If needles 0..$1-1 are all
# re-locatable, the corrupt blocks were genuinely repaired on disk — a stronger
# signal than mismatch_cnt, which counts parity mismatches, not integrity EIOs.
si_all_healed() {
	local n="$1" i
	for ((i = 0; i < n; i++)); do
		si_locate "$i" || return 1
	done
	return 0
}

# Print integrity/read-error evidence from dmesg (informational, not pass/fail).
si_evidence() {
	sudo dmesg 2>/dev/null | grep -iE 'integrity|checksum failed|read error|corrected|native csum' \
		| tail -3 | sed 's/^/      · /'
}

# True iff NO dm-integrity checksum failure has been logged since the last
# rk_dmesg_clear — used after a heal to prove the rewritten block's tag is now
# valid (a re-read no longer trips the integrity check).
si_no_eio() {
	if [ "$NATIVE" = 1 ]; then
		! sudo dmesg 2>/dev/null | grep -qiE 'native csum mismatch'
	else
		! sudo dmesg 2>/dev/null | grep -qiE 'integrity.*checksum failed'
	fi
}

# raidkm's cumulative self-heal counter (sysfs, per-array; 0 if the kernel
# predates the telemetry patch — the > comparisons below then just fail loudly).
rk_healed() { cat "/sys/block/$MDNAME/md/healed_blocks" 2>/dev/null || echo 0; }

# ---- preflight ------------------------------------------------------------
if [ "$NATIVE" != 1 ]; then
	command -v integritysetup >/dev/null 2>&1 || {
		echo "ERROR: integritysetup not found — install cryptsetup(-bin) on the test VM." >&2
		echo "       (this Phase 0 test stacks raidkm on dm-integrity)." >&2
		exit 1
	}
	sudo modprobe dm_integrity 2>/dev/null || true
	sudo modprobe dm_mod 2>/dev/null || true
fi

rk_load_modules || exit 1

if [ "$NATIVE" = 1 ]; then
	# Enable the P1a in-core native CRC (module param, read by setup_conf at
	# --create).  It lives under whichever module carries it (raidkm).
	np=$(find /sys/module -maxdepth 3 -path '*/parameters/native_csum' 2>/dev/null | head -1)
	[ -n "$np" ] || { echo "ERROR: native_csum param absent — kernel lacks P1a native csum" >&2; exit 1; }
	echo 1 | sudo tee "$np" >/dev/null || exit 1
	rk_log "native checksum ENABLED ($np)"
fi

rk_setup_brd "$NDISK" || exit 1

DISKS=$(rk_pick_disks "$NDISK") || { echo "ERROR: need $NDISK ramdisks" >&2; exit 1; }

# ---- build the dm-integrity stack -----------------------------------------
# Close any leftovers from an aborted run, then format+open one integrity target
# per member.  `format` initialises tags for the whole device so it reads back as
# zeros with valid checksums (a fresh --create resync can then read every sector).
if [ "$NATIVE" = 1 ]; then
	# Native mode: the members ARE the raw ramdisks.  raidkm's own per-block
	# CRC catches silent corruption, so there is no dm-integrity layer, and
	# corrupting a member's backing == silently corrupting the member.
	for d in $DISKS; do
		SI_BACKING+=("$d"); SI_MAPPER+=("$d")
	done
	rk_log "native checksum stack: $NDISK raw members [$DISKS] (no dm-integrity)"
else
	i=0
	for d in $DISKS; do
		name="rkshi$i"
		sudo integritysetup close "$name" 2>/dev/null || true
		sudo integritysetup format --batch-mode --integrity crc32c --tag-size 4 "$d" \
			>/dev/null 2>&1 || { echo "ERROR: integritysetup format $d failed" >&2; exit 1; }
		sudo integritysetup open --integrity crc32c "$d" "$name" \
			>/dev/null 2>&1 || { echo "ERROR: integritysetup open $d failed" >&2; exit 1; }
		SI_INAME+=("$name"); SI_BACKING+=("$d"); SI_MAPPER+=("/dev/mapper/$name")
		i=$((i + 1))
	done
	rk_log "dm-integrity stack: $NDISK crc32c members over [$DISKS]"
fi

# ---- the sweep ------------------------------------------------------------
for m in $MSET; do
	for suf in $LAYOUTS; do
		case "$suf" in
			r) layout="${m}r"; lbl=rotating ;;
			p) layout="$m";    lbl=parity-last ;;
			*) rk_log "unknown layout '$suf' (use r|p)"; continue ;;
		esac
		k=$(( NDISK - m ))
		[ "$k" -ge 2 ] || { rk_log "skip m=$m ($lbl): needs k>=2, have $k"; continue; }

		if ! rk_create "$layout" "${SI_MAPPER[@]}"; then
			rk_fail "m=$m $lbl: create over dm-integrity failed"; continue
		fi
		si_write_baseline "$k"

		# Baseline: a healthy stacked array must scrub clean.
		mm=$(rk_scrub)
		[ "$mm" = 0 ] && rk_pass "m=$m $lbl: baseline scrub clean" \
				|| rk_fail "m=$m $lbl: baseline scrub mismatch=$mm (expected 0)"

		# --- Scenario 1: heal on READ (single silent corruption) ----------
		rk_dmesg_clear
		si_restore
		si_corrupt_n 1
		if rk_readback "$WRITE_MIB"; then
			rk_pass "m=$m $lbl: silent corruption located + reconstructed on read"
		else
			rk_fail "m=$m $lbl: read returned WRONG data after silent corruption"
		fi
		si_evidence
		rk_dmesg_clean || rk_fail "m=$m $lbl: WARN/BUG in dmesg after read-heal"

		# --- Scenario 2: heal on SCRUB + on-disk clean --------------------
		rk_dmesg_clear
		si_restore
		h0=$(rk_healed)
		si_corrupt_n 1
		si_repair
		if si_all_healed 1 && rk_readback "$WRITE_MIB"; then
			rk_pass "m=$m $lbl: scrub located + repaired corrupt DATA (not parity), restored on disk"
		else
			rk_fail "m=$m $lbl: scrub did not heal corrupt block on disk"
		fi
		h1=$(rk_healed)
		if [ "$h1" -gt "$h0" ]; then
			rk_pass "m=$m $lbl: healed_blocks telemetry counted the data heal ($h0->$h1)"
		else
			# best-effort: a data heal can land via the stock compute_result
			# write path, which does not bump the R5_ReWrite-sited counter.
			rk_log "m=$m $lbl: data heal not counted this pass ($h0->$h1); healed via stock compute path (counter is best-effort)"
		fi
		rk_dmesg_clean || rk_fail "m=$m $lbl: WARN/BUG in dmesg after scrub-heal"

		# --- Scenario 3: multi-corruption in ONE stripe (Phase 2 boundary)-
		# j data erasures/stripe are correctable for any j<=m.  j<=2 is the
		# raid6 baseline and a HARD assertion; j>2 exercises >2-erasure scrub
		# healing (the deferred Phase 2 differentiator) — reported as a
		# surfaced gap rather than a hard failure so Phase 0/1 stays green.
		jmax=$m; [ "$jmax" -gt "$k" ] && jmax=$k
		for ((j = 2; j <= jmax; j++)); do
			rk_dmesg_clear
			si_restore
			si_corrupt_n "$j"
			si_repair
			if si_all_healed "$j" && rk_readback "$WRITE_MIB"; then
				rk_pass "m=$m $lbl: healed $j simultaneous corruptions in one stripe"
			elif [ "$j" -le 2 ]; then
				rk_fail "m=$m $lbl: FAILED to heal $j corruptions/stripe"
			else
				rk_log "SURFACED GAP (deferred Phase 2): m=$m $lbl did not heal $j>2 erasures/stripe"
			fi
			rk_dmesg_clean || rk_fail "m=$m $lbl: WARN/BUG in dmesg after j=$j heal"
		done

		# --- Scenario 4: corrupt a PARITY block (parity-last only) --------
		# Phase 0 needles are all DATA blocks; parity heal was only exercised
		# implicitly.  Parity-last puts parity on members [k..k+m-1], so member
		# k's row-0 block is a parity block — at the SAME backing offset as a
		# row-0 data block (members are identically formatted).  A repair must
		# rebuild parity from data AND restore a valid integrity tag.  Assert:
		# follow-up `check` mismatch==0 (parity VALUE matches data — here
		# mismatch_cnt IS meaningful, unlike the EIO-only data case), no residual
		# integrity EIO (tag healed), data intact.
		if [ "$suf" = p ] && [ "$NATIVE" != 1 ]; then   # P1a: parity/mixed heal is P2 (native verifies data only)
			rk_dmesg_clear
			si_restore
			if si_locate 0; then
				SI_DEV="${SI_BACKING[$k]}"      # first parity member, SI_OFF kept
				ph0=$(rk_healed)
				si_corrupt_here
				si_repair
				rk_dmesg_clear; mm=$(rk_scrub)
				c_eio=no; si_no_eio && c_eio=yes
				ph1=$(rk_healed)
				c_rb=no; rk_readback "$WRITE_MIB" && c_rb=yes
				if [ "$m" -gt 2 ]; then
					# raidkm's ops_run_check_pq fix: parity rebuilt on disk, ONE pass.
					if [ "$mm" = 0 ] && [ "$c_eio" = yes ] && [ "$c_rb" = yes ]; then
						rk_pass "m=$m $lbl: corrupt PARITY block rebuilt (value + tag healed)"
					else
						rk_fail "m=$m $lbl: parity heal failed (mismatch=$mm tag_healed=$c_eio data_ok=$c_rb)"
						sudo dmesg 2>/dev/null | grep -iE 'integrity|read error|corrected|raidkm' | tail -6 | sed 's/^/      · /'
					fi
					[ "$ph1" -gt "$ph0" ] \
						&& rk_pass "m=$m $lbl: healed_blocks telemetry counted the parity heal ($ph0->$ph1)" \
						|| rk_fail "m=$m $lbl: healed_blocks did not advance on parity heal ($ph0->$ph1)"
				else
					# m==2 now heals a corrupt parity in ONE scrub too: fetch_block
					# reconstructs the failed parity so the stock raid6 write path
					# rewrites it (matches stock raid6).
					if [ "$mm" = 0 ] && [ "$c_eio" = yes ] && [ "$c_rb" = yes ]; then
						rk_pass "m=$m $lbl: corrupt PARITY block rebuilt (value + tag healed)"
					else
						rk_fail "m=$m $lbl: parity heal failed (mismatch=$mm tag_healed=$c_eio data_ok=$c_rb)"
					fi
					rk_log "m=$m $lbl: parity healed via stock write path (counter $ph0->$ph1)"
				fi
				rk_dmesg_clean || rk_fail "m=$m $lbl: WARN/BUG in dmesg after parity-heal"
			else
				rk_fail "m=$m $lbl: could not derive a parity offset"
			fi
		fi

		# --- Scenario 5: single heal under CONCURRENT I/O load ------------
		# Phase 0 was quiescent.  Drive steady write+read traffic on a DISJOINT
		# region (4-6 MiB, clear of stripe row 0) while we corrupt + repair row
		# 0, to shake out heal-path / handle_stripe races against normal I/O and
		# the sync thread.  Assert via the backing-marker restore (readback would
		# mismatch — the load region is deliberately overwritten) + no oops.
		rk_dmesg_clear
		si_restore
		( while :; do
			sudo dd if=/dev/urandom of="$MD" bs=1M seek=4 count=2 oflag=direct status=none 2>/dev/null
			sudo dd if="$MD" of=/dev/null   bs=1M skip=4 count=2 iflag=direct status=none 2>/dev/null
		  done ) & load=$!
		si_corrupt_n 1
		si_repair
		heal_ok=0; si_all_healed 1 && heal_ok=1
		kill "$load" 2>/dev/null; wait "$load" 2>/dev/null
		[ "$heal_ok" = 1 ] && rk_pass "m=$m $lbl: heal under concurrent I/O load" \
				   || rk_fail "m=$m $lbl: heal FAILED under concurrent I/O load"
		rk_dmesg_clean || rk_fail "m=$m $lbl: WARN/BUG in dmesg under concurrent heal"

		# --- Scenario 6: MIXED data+parity corruption in ONE stripe (parity-last) --
		# Scenarios 1-3 corrupt only DATA, 4 only PARITY.  A real multi-failure mixes
		# them: dc data + pc parity erasures in the SAME stripe (dc+pc<=m, correctable).
		# This is the strongest no-parity-propagation test: if the heal rewrote parity
		# to match the corrupt DATA block (the 5668-5688 flaw firing on an integrity-
		# flagged data block) the recovered data would be WRONG.  Parity-last so parity
		# members [k..k+m-1] row-0 blocks share the backing offset of a data block.
		if [ "$suf" = p ] && [ "$NATIVE" != 1 ]; then   # P1a: parity/mixed heal is P2 (native verifies data only)
			pc=$(( m / 2 )); [ "$pc" -lt 1 ] && pc=1
			dc=$(( m - pc ))
			[ "$dc" -gt "$k" ] && { dc=$k; pc=$(( m - dc )); }
			[ "$dc" -lt 1 ] && { dc=1; pc=$(( m - dc )); }
			rk_dmesg_clear
			si_restore
			mh0=$(rk_healed)
			if si_locate 0; then
				row0off="$SI_OFF"                  # capture BEFORE corrupting
				si_corrupt_n "$dc"                 # dc data erasures (stripe row 0)
				for ((pi = 0; pi < pc; pi++)); do  # pc parity erasures, same row
					SI_DEV="${SI_BACKING[$((k + pi))]}"; SI_OFF="$row0off"
					si_corrupt_here
				done
				si_repair
				rk_dmesg_clear; mm=$(rk_scrub)
				c_eio=no;  si_no_eio                && c_eio=yes
				c_rb=no;   rk_readback "$WRITE_MIB" && c_rb=yes
				c_data=no; si_all_healed "$dc"      && c_data=yes
				mh1=$(rk_healed)
				if [ "$mm" = 0 ] && [ "$c_eio" = yes ] && [ "$c_rb" = yes ] && [ "$c_data" = yes ]; then
					rk_pass "m=$m $lbl: healed MIXED $dc data + $pc parity erasures in one stripe"
				else
					rk_fail "m=$m $lbl: mixed heal failed (mismatch=$mm tag=$c_eio data_ok=$c_rb ondisk=$c_data; d=$dc p=$pc)"
					sudo dmesg 2>/dev/null | grep -iE 'integrity|read error|corrected|raidkm|not up to date' | tail -6 | sed 's/^/      · /'
				fi
				if [ "$m" -gt 2 ]; then
					[ "$mh1" -gt "$mh0" ] \
						&& rk_pass "m=$m $lbl: healed_blocks counted mixed heal ($mh0->$mh1)" \
						|| rk_fail "m=$m $lbl: healed_blocks did not advance on mixed heal ($mh0->$mh1)"
				else
					rk_log "m=$m $lbl: mixed heal counter $mh0->$mh1 (m=2 parity via stock path, best-effort)"
				fi
				rk_dmesg_clean || rk_fail "m=$m $lbl: WARN/BUG in dmesg after mixed heal"
			else
				rk_fail "m=$m $lbl: could not locate row-0 needle for mixed corruption"
			fi
		fi

		si_restore                         # leave members fully readable for next --create
		rk_stop
	done
done

rk_summary
