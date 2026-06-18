#!/bin/bash
# raidkm-test-ec-mds.sh — build + run the EC matrix MDS self-test.
#
# Pure userspace check (no array, module, or root needed): confirms the
# generator matrix raidkm would use at every supported (m,k) — Vandermonde for
# m<=3, Cauchy for m>=4 — is MDS, i.e. every m-disk erasure is recoverable.
# Compiles tools/raidkm-ec-mds-verify.c against the isa-l source in the tree.
#
#   bash tools/raidkm-test-ec-mds.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SRC="$RK_TREE/tools/raidkm-ec-mds-verify.c"
ISADIR="$RK_TREE/isa-l"
CC="${CC:-cc}"
# Self-contained scratch (no root, no shared $RK_TMP) — this test needs neither.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/raidkm-ec-mds-verify"

if [ ! -f "$ISADIR/ec_base.c" ]; then
	rk_fail "isa-l source not found at $ISADIR/ec_base.c — build the tree first (make)"
elif ! "$CC" -O2 "$SRC" "$ISADIR/ec_base.c" -I "$ISADIR" -o "$BIN" 2>"$WORK/cc.log"; then
	rk_fail "compile failed:"
	sed 's/^/    /' "$WORK/cc.log" >&2
elif "$BIN"; then
	rk_pass "EC matrix MDS self-test: every raidkm (m,k) code is MDS"
else
	rk_fail "EC matrix is NOT MDS for some raidkm (m,k) — see output above"
fi

rk_summary
