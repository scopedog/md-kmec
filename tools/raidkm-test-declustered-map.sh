#!/bin/bash
#
# raidkm-test-declustered-map.sh — kernel<->userspace declustered-map parity
# gate (design doc §5a / Phase 1a).
#
# The userspace simulator (tools/declustered-sim.c) is the reference for the
# declustered layout: it runs the acceptance search and picks the permutation
# seed that mdadm will one day record in the superblock.  The kernel
# (km/raid_km_dcl.h, exercised via the raidkm `dcl_selftest` module param)
# must regenerate the IDENTICAL permutation set and mapping from that seed.
#
# For each geometry in the matrix this script:
#   1. runs the simulator with a pinned seed (-T 1 => accepted seed == pinned),
#      capturing its PERM crc32 and 32 forward-map reference vectors;
#   2. writes "N:g:m:s:nbase:seed:crc" to the kernel self-test param — the
#      kernel re-derives PERM, checks the crc, asserts P1 exactness, per-row
#      bijectivity + inverse consistency, and a 200k-chunk roundtrip;
#   3. diffs the kernel's DCLMAP vector dump against the simulator's vectors
#      field by field.
#
# No array is created; only the module needs to be loaded.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SIM_SRC="$RK_TREE/tools/declustered-sim.c"
SIM="$RK_TMP/declustered-sim"
PARAM=/sys/module/raidkm/parameters/dcl_selftest

# geometry matrix: N:g:m:s:nbase:seed  (seeds pinned; -T 1 accepts them as-is)
GEOMS=(
	"14:6:2:2:4:0x3c"
	"42:10:2:2:4:0x39"
	"80:13:2:2:16:0x159"
	"80:16:3:16:4:0x38"
)

mkdir -p "$RK_TMP"
rk_load_modules || exit 1

if [ ! -e "$PARAM" ]; then
	echo "ERROR: $PARAM missing — is this a Phase-1a raidkm build?" >&2
	exit 1
fi

cc -O2 -o "$SIM" "$SIM_SRC" -lm || {
	echo "ERROR: cannot build $SIM_SRC" >&2; exit 1; }

for spec in "${GEOMS[@]}"; do
	IFS=: read -r N g m s nbase seed <<< "$spec"
	lbl="N=$N g=$g m=$m s=$s nbase=$nbase seed=$seed"

	# 1. simulator reference run (pinned seed, deterministic)
	out=$("$SIM" -N "$N" -g "$g" -m "$m" -s "$s" -b "$nbase" \
		     -S "$seed" -T 1 --vectors "$RK_TMP/vec.tsv" --nvec 32)
	if ! grep -q "ALL CHECKS PASSED" <<< "$out"; then
		rk_fail "$lbl: simulator checks failed"
		continue
	fi
	crc=$(sed -n 's/.*PERM crc32 \(0x[0-9a-f]*\)).*/\1/p' <<< "$out")
	if [ -z "$crc" ]; then
		rk_fail "$lbl: could not parse simulator PERM crc32"
		continue
	fi

	# 2. kernel self-test on the same seed + crc
	rk_dmesg_clear
	if ! echo "$N:$g:$m:$s:$nbase:$seed:$crc" | sudo tee "$PARAM" \
			> /dev/null 2> "$RK_TMP/dcl-err"; then
		rk_fail "$lbl: kernel self-test FAILED ($(sudo cat "$PARAM" 2>/dev/null))"
		sudo dmesg | grep -E 'DCLTEST' | tail -3 | sed 's/^/      · /'
		continue
	fi
	verdict=$(sudo cat "$PARAM")
	if ! grep -q "PASS" <<< "$verdict"; then
		rk_fail "$lbl: kernel verdict: $verdict"
		continue
	fi
	rk_pass "$lbl: kernel PERM identity + P1 + bijectivity + roundtrip"

	# 3. vector diff: kernel DCLMAP vs simulator vectors
	sudo dmesg | sed -n 's/.*DCLMAP //p' | head -32 > "$RK_TMP/vec-kern"
	grep -v '^#' "$RK_TMP/vec.tsv" | tr '\t' ' ' > "$RK_TMP/vec-sim"
	if diff -q "$RK_TMP/vec-kern" "$RK_TMP/vec-sim" > /dev/null; then
		rk_pass "$lbl: 32 forward-map vectors identical kernel<->sim"
	else
		rk_fail "$lbl: vector mismatch kernel<->sim"
		diff "$RK_TMP/vec-kern" "$RK_TMP/vec-sim" | head -8 | sed 's/^/      · /'
	fi
done

rk_summary
