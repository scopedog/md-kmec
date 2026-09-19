#!/bin/bash
# raidkm-rig-nvme.sh — carve a real-disk rig for the raidkm test suites.
#
# The suites are calibrated for the ramdisks raidkm-test-lib.sh builds itself:
# BRD_NR members of BRD_SIZE_KB (12 x 256 MiB).  Pointed at real disks through
# RK_DEVS they still work, but every create resyncs the WHOLE member and every
# rebuild and scrub walks it again, so handing them a 2 GiB partition makes the
# tier eight times slower and handing them a whole 375 GiB namespace makes it
# never finish.  That is what the CI smoke tier hit on real NVMe: `replace`
# alone ran past its 900 s budget and was killed.
#
# So carve members the size the suites expect, one per namespace (one per
# namespace, not several per namespace: md serialises resync between arrays
# that share a physical device, and a leftover array on a sibling partition is
# enough to make every benchmark arm report resync=DELAYED).
#
#   sudo bash tools/raidkm-rig-nvme.sh --yes /dev/nvme0n{1..14}
#   sudo RK_DEVS="$(cat /var/tmp/raidkm-rig.devs)" bash tools/raidkm-test-ci.sh --tier=smoke
#
# THIS DESTROYS THE NAMED DISKS.  It refuses one that is mounted, holds a
# mounted filesystem, carries an LVM PV, or backs a live md array, and it needs
# --yes before it writes anything.
#
# Options
#   --size-mb=N     member size (default 256, matching BRD_SIZE_KB)
#   --part=N        which partition to hand to the suites (default 1); a carve
#                   always writes a fresh single-partition table, so this is
#                   only interesting together with --keep
#   --keep          do not repartition; just wipe and list the existing
#                   partitions (use when the rig is already carved)
#   --out=FILE      where to write the RK_DEVS list (default
#                   /var/tmp/raidkm-rig.devs); it is also printed
#   --yes           actually do it
set -u
PATH="$PATH:/usr/sbin:/sbin"

SIZE_MB=256
PART=1
KEEP=0
OUT=/var/tmp/raidkm-rig.devs
YES=0
DISKS=()

die() { echo "raidkm-rig-nvme: $*" >&2; exit 1; }
note() { echo "  $*"; }

for arg in "$@"; do
	case "$arg" in
	--size-mb=*)     SIZE_MB="${arg#*=}" ;;
	--part=*)        PART="${arg#*=}" ;;
	--keep)          KEEP=1 ;;
	--out=*)         OUT="${arg#*=}" ;;
	--yes)           YES=1 ;;
	-h|--help)       sed -n '2,40p' "$0"; exit 0 ;;
	-*)              die "unknown option: $arg" ;;
	*)               DISKS+=("$arg") ;;
	esac
done

[ "${#DISKS[@]}" -ge 1 ] || die "name the whole-disk devices to carve (e.g. /dev/nvme0n1 ...)"
[[ "$SIZE_MB" =~ ^[1-9][0-9]*$ ]] || die "--size-mb must be a positive integer"
[[ "$PART" =~ ^[1-9][0-9]*$ ]] || die "--part must be a positive integer"
[ "$(id -u)" = 0 ] || die "run as root"

# Partition name for a whole-disk node: nvme0n1 -> nvme0n1p1, sda -> sda1.
partof() {
	local d="$1" n="$2"
	case "$d" in
	*[0-9]) echo "${d}p${n}" ;;
	*)      echo "${d}${n}" ;;
	esac
}

# ---- refuse anything in use -------------------------------------------------
# A rig script that eats the boot disk costs more than the rig it builds, so
# every check here is a hard stop, not a warning.
inuse() {
	local d="$1" holder base
	base="$(basename "$d")"
	[ -b "$d" ] || { echo "not a block device"; return 0; }
	# whole disk, not a partition
	[ -e "/sys/block/$base" ] || { echo "not a whole-disk device"; return 0; }
	# mounted, itself or via any partition.  The partition prefix has to be
	# exact: /dev/nvme0n1 plus a bare digit is /dev/nvme0n10, a DIFFERENT disk.
	local pfx
	case "$d" in *[0-9]) pfx="${d}p" ;; *) pfx="$d" ;; esac
	while read -r src _; do
		case "$src" in "$d"|"$pfx"[0-9]*) echo "mounted ($src)"; return 0 ;; esac
	done < /proc/mounts
	# swap
	if grep -q "^$d" /proc/swaps 2>/dev/null; then echo "in use as swap"; return 0; fi
	# LVM physical volume
	if command -v pvs >/dev/null && pvs --noheadings -o pv_name 2>/dev/null |
	   grep -qE "^\s*$d([0-9]+|p[0-9]+)?\s*$"; then echo "holds an LVM PV"; return 0; fi
	# a live md array holding it or one of its partitions
	for holder in /sys/block/"$base"/holders/* /sys/block/"$base"/*/holders/*; do
		[ -e "$holder" ] || continue
		case "$(basename "$holder")" in
		md*) echo "held by $(basename "$holder")"; return 0 ;;
		esac
	done
	return 1
}

echo "raidkm-rig-nvme: ${#DISKS[@]} disk(s), member size ${SIZE_MB} MiB, partition $PART"
for d in "${DISKS[@]}"; do
	if why=$(inuse "$d"); then die "$d is in use: $why"; fi
done

if [ "$YES" != 1 ]; then
	echo
	echo "Would DESTROY: ${DISKS[*]}"
	echo "Re-run with --yes to carve them."
	exit 1
fi

# ---- stop whatever is still holding the old rig ----------------------------
# A suite killed by its timeout leaves an assembled array behind; the next run
# then cannot zero the members and fails in a way that looks like a code bug.
for md in $(awk '/^md/ {print $1}' /proc/mdstat 2>/dev/null); do
	for d in "${DISKS[@]}"; do
		# mdstat lists members as "nvme0n1p1[3]"; anchor on that bracket or
		# nvme0n1 also matches nvme0n10p1, an unrelated disk.
		if grep -qE "(^|[[:space:]])$(basename "$d")(p?[0-9]+)?\[" \
		   <(grep "^$md " /proc/mdstat); then
			note "stopping /dev/$md (holds a rig disk)"
			mdadm --stop "/dev/$md" >/dev/null 2>&1 || true
		fi
	done
done

DEVS=()
for d in "${DISKS[@]}"; do
	p="$(partof "$d" "$([ "$KEEP" = 1 ] && echo "$PART" || echo 1)")"
	if [ "$KEEP" = 1 ]; then
		[ -b "$p" ] || die "$p does not exist (drop --keep to carve it)"
	else
		note "carving $p (${SIZE_MB} MiB)"
		mdadm --zero-superblock "$p" >/dev/null 2>&1 || true
		wipefs -a "$d" >/dev/null 2>&1 || true
		# 1 MiB start keeps the member aligned to any IU these drives use.
		# sfdisk rather than sgdisk: util-linux ships everywhere mdadm
		# does, gdisk does not (the bench images do not carry it).
		if ! sfdisk --wipe always --wipe-partitions always -q "$d" >/dev/null 2>&1 <<-EOF
			label: gpt
			start=1MiB, size=${SIZE_MB}MiB, name=rkrig
		EOF
		then
			die "could not partition $d"
		fi
		udevadm settle >/dev/null 2>&1 || true
		partprobe "$d" >/dev/null 2>&1 || true
		udevadm settle >/dev/null 2>&1 || true
		[ -b "$p" ] || die "$p did not appear after partitioning $d"
	fi
	# udev re-assembles a stale superblock the moment a partition appears, so
	# a member can come back as an array member between the carve and the
	# first suite.  Stop whatever claimed it, then zero -- both orders matter:
	# --zero-superblock refuses a member md still holds.
	# (Holding udev off with `udevadm control --stop-exec-queue` instead is a
	# trap: every later `udevadm settle` then waits on a queue that will not
	# run, and the script hangs.)
	for md in $(awk '/^md/ {print $1}' /proc/mdstat 2>/dev/null); do
		grep -qE "(^|[[:space:]])$(basename "$p")\[" <(grep "^$md " /proc/mdstat) &&
			mdadm --stop "/dev/$md" >/dev/null 2>&1 || true
	done
	mdadm --zero-superblock "$p" >/dev/null 2>&1 || true
	dd if=/dev/zero of="$p" bs=1M count=8 oflag=direct status=none 2>/dev/null || true
	DEVS+=("$p")
done

udevadm settle >/dev/null 2>&1 || true

# ---- report -----------------------------------------------------------------
echo
printf '%-20s %10s %6s %6s\n' device size lbs pbs
for p in "${DEVS[@]}"; do
	printf '%-20s %10s %6s %6s\n' "$p" \
		"$(blockdev --getsize64 "$p" 2>/dev/null)" \
		"$(blockdev --getss "$p" 2>/dev/null)" \
		"$(blockdev --getpbsz "$p" 2>/dev/null)"
done

printf '%s\n' "${DEVS[*]}" > "$OUT"
echo
echo "RK_DEVS written to $OUT:"
echo "  ${DEVS[*]}"
echo
echo "Run the tier with:"
echo "  sudo RK_DEVS=\"\$(cat $OUT)\" MDADM=<raidkm mdadm> \\"
echo "       bash tools/raidkm-test-ci.sh --tier=smoke"
