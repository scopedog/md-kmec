#!/bin/sh
# detect-target.sh — the one map from a kernel release string to the raidkm
# build TARGET.  Used by md-kmec/Makefile, tools/check-mddev-abi.sh and the
# umbrella (mdraid-super) Makefile, so they cannot disagree.
#
# Map (first match wins):
#   *.el9_8*            -> rhel98      RHEL/Rocky 9.8 builtin md (9.8 moved struct mddev)
#   *.el9*              -> rhel9       RHEL/Rocky 9.x builtin md (5.14-el9, 6.12 backport)
#   *.el*               -> rhel10      RHEL/Rocky 10.x builtin md
#   7.0.0-<abi>-<flavour> -> ubuntu2604 Ubuntu 26.04 kernel 7.0 (builtin md), the
#                          flavours whose md layout was checked against their BTF
#                          (md-ubuntu2604/README): UBUNTU2604_FLAVOURS below
#   7.*                 -> unsupported  realtime (PREEMPT_RT: struct mddev 2392),
#                          an unchecked flavour, or any other 7.x kernel: the
#                          vanilla headers are 6.12's, so never fall through to them
#   *                   -> vanilla     mainline / Debian 6.12
#
# The flavours are named, not matched by shape, so a Debian 7.0.0-N-amd64 is
# not taken for Ubuntu (it is refused with the other unchecked 7.x kernels).  A flavour on this list is only *selected* here: the
# struct mddev ABI check (check-mddev-abi.sh, BTF) and the BUILD_BUG_ON pins in
# km/raid_km.c are what accept or refuse its layout.
#
# This is only the default: a caller may override with TARGET= (e.g. a locally
# built kernel whose release lacks a distro suffix).  Prints the target; exits 2
# if no kernel release is given.
#
#   detect-target.sh --flavours ubuntu2604
# prints the checked 7.0 flavours, space-separated.  raidkm's DKMS package
# renders its BUILD_EXCLUSIVE_KERNEL from this, so the list lives only here.
set -u

# Ubuntu 26.04 kernel 7.0 flavours whose struct mddev was checked against BTF.
UBUNTU2604_FLAVOURS="generic aws azure azure-fde gcp gke ibm oracle vmware oem nvidia nvidia-bos"

if [ "${1:-}" = --flavours ]; then
	case "${2:-}" in
	ubuntu2604)	echo "$UBUNTU2604_FLAVOURS"; exit 0 ;;
	*)		echo "detect-target.sh: --flavours: unknown target '${2:-}' (known: ubuntu2604)" >&2
			exit 2 ;;
	esac
fi

kver="${1:-}"
if [ -z "$kver" ]; then
	echo "detect-target.sh: no kernel release given (usage: detect-target.sh <kver>)" >&2
	exit 2
fi

# 7.0.0-<abi>-<flavour>: is <flavour> on the list (and <abi> all digits)?
is_ubuntu2604() {
	rest=${1#7.0.0-}
	[ "$rest" != "$1" ] || return 1
	abi=${rest%%-*}
	flavour=${rest#*-}
	[ "$flavour" != "$rest" ] || return 1
	case "$abi" in ''|*[!0-9]*) return 1 ;; esac
	for f in $UBUNTU2604_FLAVOURS; do
		[ "$f" = "$flavour" ] && return 0
	done
	return 1
}

case "$kver" in
	*.el9_8*)	echo rhel98; exit 0 ;;
	*.el9*)		echo rhel9; exit 0 ;;
	*.el*)		echo rhel10; exit 0 ;;
esac
if is_ubuntu2604 "$kver"; then
	echo ubuntu2604
	exit 0
fi
case "$kver" in
	7.*)
			echo "detect-target.sh: $kver: no supported md target (Ubuntu realtime and unchecked 7.x kernels are refused)" >&2
			echo unsupported ;;
	*)		echo vanilla ;;
esac
