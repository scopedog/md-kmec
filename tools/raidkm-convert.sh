#!/bin/bash
#
# raidkm-convert.sh — convert an md array in place between stock RAID6 and raidkm.
#
# Stock RAID6 (left-symmetric, m=2) and raidkm rotating m=2 are byte-for-byte
# identical on disk, so this moves NO data: it just rewrites each member's
# superblock level+layout via `mdadm --raidkm-convert`, then reassembles.
#
#   forward (default):  raid6 (left-symmetric)  ->  raidkm (rotating, m=2)
#   --reverse:          raidkm (rotating, m=2)  ->  raid6 (left-symmetric)
#
# ONLY raid6 left-symmetric <-> raidkm rotating m=2 is convertible; anything
# else is refused (a wrong layout would silently corrupt).  The raidkm.ko module
# must be loaded for the raidkm side to assemble.
#
# Usage:
#   sudo bash tools/raidkm-convert.sh [options] <md-device>
#
# Options:
#   --reverse        raidkm -> raid6 (default is raid6 -> raidkm)
#   --no-assemble    rewrite superblocks only; leave the array stopped
#   --mdadm PATH     raidkm-aware mdadm fork (else $MDADM / autodetect)
#   --yes            don't prompt for confirmation
#   -h | --help
#
# Example:
#   sudo bash tools/raidkm-convert.sh /dev/md0          # raid6 -> raidkm
#   sudo bash tools/raidkm-convert.sh --reverse /dev/md0
#
set -u

REVERSE=0
ASSEMBLE=1
ASSUME_YES=0
MDADM="${MDADM:-}"
ARRAY=""

die() { echo "error: $*" >&2; exit 1; }

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \?//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--reverse)     REVERSE=1 ;;
		--no-assemble) ASSEMBLE=0 ;;
		--yes|-y)      ASSUME_YES=1 ;;
		--mdadm)       MDADM="$2"; shift ;;
		--mdadm=*)     MDADM="${1#*=}" ;;
		-h|--help)     usage 0 ;;
		-*)            die "unknown option: $1 (try --help)" ;;
		*)             [ -z "$ARRAY" ] || die "only one array may be given"; ARRAY="$1" ;;
	esac
	shift
done

[ -n "$ARRAY" ] || usage 1
[ "$(id -u)" -eq 0 ] || die "must run as root (sudo)"

# --- resolve a raidkm-aware mdadm (a stock mdadm rejects --raidkm-convert) -----
resolve_mdadm() {
	local here c
	here="$(cd "$(dirname "$0")" && pwd)"
	for c in "$MDADM" \
	         "$here/../../mdadm/mdadm" \
	         "$HOME/projects/mdraid/mdadm/mdadm" \
	         "$HOME/mdadm/mdadm" \
	         "$(command -v mdadm 2>/dev/null)"; do
		[ -n "$c" ] && [ -x "$c" ] && grep -qa raidkm-convert "$c" 2>/dev/null && { MDADM="$c"; return 0; }
	done
	die "no mdadm with --raidkm-convert found — set --mdadm /path/to/fork/mdadm"
}
resolve_mdadm

# --- inspect the (assembled) array --------------------------------------------
B="$(basename "$ARRAY")"
[ -d "/sys/block/$B/md" ] || die "$ARRAY is not an assembled md array"

LEVEL="$(cat "/sys/block/$B/md/level" 2>/dev/null)"
LAYOUT="$(cat "/sys/block/$B/md/layout" 2>/dev/null)"

# refuse if mounted / in use
if findmnt -rno SOURCE | grep -qx "/dev/$B"; then
	die "/dev/$B is mounted — unmount it first"
fi

# collect member devices from the array's slaves
MEMBERS=()
for s in "/sys/block/$B/slaves"/*; do
	[ -e "$s" ] || continue
	MEMBERS+=("/dev/$(basename "$s")")
done
[ "${#MEMBERS[@]}" -ge 4 ] || die "found only ${#MEMBERS[@]} members under /sys/block/$B/slaves"

# validate the source geometry for the requested direction
if [ "$REVERSE" -eq 0 ]; then
	FROM="raid6 (left-symmetric)"; TO="raidkm (rotating, m=2)"
	[ "$LEVEL" = "raid6" ]   || die "$ARRAY is level '$LEVEL', expected raid6 (use --reverse for raidkm->raid6)"
	[ "$LAYOUT" = "2" ]      || die "$ARRAY layout is $LAYOUT, only left-symmetric (2) converts to raidkm rotating"
else
	FROM="raidkm (rotating, m=2)"; TO="raid6 (left-symmetric)"
	[ "$LEVEL" = "raidkm" ]  || die "$ARRAY is level '$LEVEL', expected raidkm (drop --reverse for raid6->raidkm)"
	# raidkm layout: low byte = m, bit 0x100 = rotating.  258 = 0x102 = rotating|m2.
	[ "$LAYOUT" = "258" ]    || die "$ARRAY layout is $LAYOUT; only rotating m=2 (258) maps to raid6 left-symmetric"
fi

echo "Array:     /dev/$B"
echo "Members:   ${MEMBERS[*]}"
echo "Convert:   $FROM  ->  $TO"
echo "mdadm:     $MDADM"
echo "Reassemble after convert: $([ "$ASSEMBLE" -eq 1 ] && echo yes || echo "no (--no-assemble)")"
echo

if [ "$ASSUME_YES" -ne 1 ]; then
	printf "This stops /dev/%s and rewrites every member superblock. Proceed? [y/N] " "$B"
	read -r ans
	case "$ans" in y|Y|yes|YES) ;; *) echo "aborted."; exit 1 ;; esac
fi

# --- do it --------------------------------------------------------------------
echo "==> stopping /dev/$B"
"$MDADM" --stop "/dev/$B" >/dev/null || die "failed to stop /dev/$B"

echo "==> converting superblocks"
"$MDADM" --raidkm-convert "${MEMBERS[@]}" || die "superblock conversion failed (some members may be half-converted; fix and re-run on all members)"

if [ "$ASSEMBLE" -eq 0 ]; then
	echo "==> done (superblocks converted; array left stopped)."
	echo "    assemble with:  $MDADM --assemble /dev/$B ${MEMBERS[*]}"
	exit 0
fi

echo "==> reassembling /dev/$B"
"$MDADM" --assemble "/dev/$B" "${MEMBERS[@]}" --run >/dev/null || \
	die "reassembly failed — superblocks ARE converted; retry: $MDADM --assemble /dev/$B ${MEMBERS[*]}"

NEWLEVEL="$(cat "/sys/block/$B/md/level" 2>/dev/null)"
echo "==> done.  /dev/$B is now level '$NEWLEVEL'."
"$MDADM" --detail "/dev/$B" 2>/dev/null | grep -iE 'Raid Level|Layout|Parity Count|Array Size|State :' | sed 's/^/    /'
