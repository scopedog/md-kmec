#!/bin/bash
# raidkm-create.sh — assemble a kmec md array via sysfs.
#
# mdadm hardcodes the list of recognised RAID levels and rejects "kmec"
# (and the kmec level number 70).  Until that lands in mdadm, this
# script drives the same sysfs interface mdadm uses internally.
#
# Usage:
#   sudo bash tools/raidkm-create.sh <md> <m> <chunk_kb> <dev1> <dev2> ...
#
# Example: 4-data + 2-parity, 64 KiB chunk, six loop backings:
#   sudo bash tools/raidkm-create.sh md0 2 64 \
#       /dev/loop0 /dev/loop1 /dev/loop2 /dev/loop3 /dev/loop4 /dev/loop5
#
# When done, stop with:  sudo mdadm --stop /dev/md0

set -e

if [ "$#" -lt 5 ]; then
    echo "usage: $0 <md_name> <m_parity> <chunk_kb> <dev1> [<dev2> ...]" >&2
    exit 1
fi

MD="$1"; shift
M="$1"; shift
CHUNK_KB="$1"; shift
DEVS=("$@")
N=${#DEVS[@]}

if [ "$N" -le "$M" ]; then
    echo "error: need at least m+1=$((M+1)) devices, got $N" >&2
    exit 2
fi

# Reserve the md device.
echo "$MD" > /sys/module/md_mod/parameters/new_array

# Configure the array.
echo kmec               > /sys/block/$MD/md/level
echo "$N"               > /sys/block/$MD/md/raid_disks
echo "$M"               > /sys/block/$MD/md/layout
echo $((CHUNK_KB * 1024)) > /sys/block/$MD/md/chunk_size

# Attach each device by major:minor and assign it the matching slot.
for i in "${!DEVS[@]}"; do
    DEV="${DEVS[$i]}"
    MAJ=$((16#$(stat -c %t "$DEV")))
    MIN=$((16#$(stat -c %T "$DEV")))
    echo "$MAJ:$MIN" > /sys/block/$MD/md/new_dev
    BASENAME=$(basename "$DEV")
    echo "$i" > /sys/block/$MD/md/dev-$BASENAME/slot
done

# Activate.  The first transition out of "inactive" must be "active";
# the kernel rolls forward to "clean" once md_run() returns.
echo active > /sys/block/$MD/md/array_state

cat /proc/mdstat
