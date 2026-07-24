#!/bin/bash
#
# raidkm-test-declustered-reshape.sh — declustered pool-expansion reshape gate
# (notes/declustered-reshape-design.md §8).
#
# PHASE P0 (this file today): the dual-map plumbing.  No array is created; the
# `dcl_reshape_selftest` module param builds the OLD and NEW permutation maps
# for a pool widening (N -> N', with g/m/s/nbase fixed), freezes a device-row
# frontier, and sweeps the OLD logical address space asserting the two runtime
# geometry selectors — raidkm_dcl_geom_for_chunk() and _for_row() — agree with
# each other and with the frontier rule (a chunk is served by the NEW map iff
# its new-geometry row < frontier).  This validates the trickiest new logic
# (old/new geometry selection either side of a moving frontier) in isolation,
# before the migrate-band engine (P1) relies on it.
#
# Each geometry is tested at four frontiers: 0 (nothing migrated), the
# midpoint, the full span (everything migrated), and just beyond it — so both
# regimes and both edges are exercised.
#
# LATER PHASES (P1+) will extend this script with a real create + migrate +
# placement/decode oracle + crash tiers; for now it is the P0 self-test gate.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

PARAM=/sys/module/raidkm/parameters/dcl_reshape_selftest

# g:m:s:nbase:oldN:oldseed:newN:newseed  — pool widens by exactly one group
# (newN = oldN + g), so ngroups grows by 1.  Seeds are arbitrary pins: the
# consistency property under test does not depend on permutation balance.
CASES=(
	"6:2:2:4:14:0x11:20:0x22"	# m=2 k=4: ngroups 2 -> 3
	"6:3:2:4:14:0x33:20:0x44"	# m=3 k=3: decode-side coverage
	"13:2:2:16:80:0x159:93:0x15a"	# wide N=80 -> 93: ngroups 6 -> 7
)
OLDROWS=2048

mkdir -p "$RK_TMP"
rk_load_modules || exit 1

if [ ! -e "$PARAM" ]; then
	echo "ERROR: $PARAM missing — is this a declustered-reshape (P0) build?" >&2
	exit 1
fi

for spec in "${CASES[@]}"; do
	IFS=: read -r g m s nbase oldN oldseed newN newseed <<< "$spec"
	oldng=$(( (oldN - s) / g ))
	newng=$(( (newN - s) / g ))
	# largest NEW device row the OLDROWS-deep sweep reaches (the new map packs
	# the same data into ~oldng/newng of the rows) — bisect it for the midpoint.
	span=$(( OLDROWS * oldng / newng ))
	lbl="oldN=$oldN newN=$newN g=$g m=$m s=$s"

	for F in 0 $(( span / 2 )) "$span" $(( span + 8 )); do
		rk_dmesg_clear
		in="$g:$m:$s:$nbase:$oldN:$oldseed:$newN:$newseed:$OLDROWS:$F"
		if ! echo "$in" | sudo tee "$PARAM" \
				> /dev/null 2> "$RK_TMP/rs-err"; then
			# a failed consistency sweep returns -EINVAL from the store,
			# so the DCLTEST ring-buffer line carries the verdict + chunk
			rk_fail "$lbl F=$F: selftest FAILED ($(sudo cat "$PARAM" 2>/dev/null))"
			sudo dmesg | grep -E 'DCLTEST|reshape_selftest' | tail -2 |
				sed 's/^/      · /'
			continue
		fi
		verdict=$(sudo cat "$PARAM")
		if grep -q "RESHAPE PASS" <<< "$verdict"; then
			rk_pass "$lbl F=$F: geom-select consistent over $OLDROWS old rows"
		else
			rk_fail "$lbl F=$F: kernel verdict: $verdict"
		fi
	done
done

rk_summary
