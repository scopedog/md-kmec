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
#                          (md-ubuntu2604/README): generic, aws, azure, azure-fde,
#                          gcp, gke, ibm, oracle, vmware, oem, nvidia, nvidia-bos
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
set -u
kver="${1:-}"
if [ -z "$kver" ]; then
	echo "detect-target.sh: no kernel release given (usage: detect-target.sh <kver>)" >&2
	exit 2
fi
case "$kver" in
	*.el9_8*)	echo rhel98 ;;
	*.el9*)		echo rhel9 ;;
	*.el*)		echo rhel10 ;;
	7.0.0-[0-9]*-generic|7.0.0-[0-9]*-aws|7.0.0-[0-9]*-azure|\
	7.0.0-[0-9]*-azure-fde|7.0.0-[0-9]*-gcp|7.0.0-[0-9]*-gke|\
	7.0.0-[0-9]*-ibm|7.0.0-[0-9]*-oracle|7.0.0-[0-9]*-vmware|\
	7.0.0-[0-9]*-oem|7.0.0-[0-9]*-nvidia|7.0.0-[0-9]*-nvidia-bos)
			echo ubuntu2604 ;;
	7.*)
			echo "detect-target.sh: $kver: no supported md target (Ubuntu realtime and unchecked 7.x kernels are refused)" >&2
			echo unsupported ;;
	*)		echo vanilla ;;
esac
