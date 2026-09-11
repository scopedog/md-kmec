#!/bin/bash
# raidkm-member-stats.sh — how an array's I/O reaches its members.
#
# Source this from a script; it is not meant to be run directly:
#   . "$(dirname "${BASH_SOURCE[0]}")/raidkm-member-stats.sh"
#
# The array's own counters show what the filesystem or fio submitted.  What
# matters for the devices underneath — flash with a coarse indirection unit
# (IU) in particular, where a write smaller than the unit makes the drive
# rewrite the whole unit — is the request size AFTER md split the I/O into
# member bios and the block layer merged them.  These helpers find the
# devices whose request counters see that, and report the average request
# size and merge share from two counter snapshots.
#
#   rk_leaf_devs DEV       kernel names that carry DEV's member requests:
#                          md/dm devices expand to their slaves (recursively),
#                          an NVMe native-multipath head to its path devices
#                          (the head itself only counts submitted bios), a
#                          partition of such a head to the head's paths; any
#                          other device is its own leaf
#   rk_stat_snap NAME...   one line per device:
#                          "name rd_ios rd_merges rd_sectors wr_ios wr_merges wr_sectors"
#   rk_stat_report BEFORE AFTER
#                          JSON summed over the devices in both snapshots:
#                          {"devices": n, "read": {...}, "write": {...}} with
#                          requests, merges, sectors, avg_kib, merged_pct
#                          (merged_pct = merges / (requests + merges): the share
#                          of submitted bios the block layer folded into
#                          another request)

rk_leaf_devs() {
	local name s p parent
	name=$(basename "$(readlink -f "$1")")
	if [ -n "$(ls -A "/sys/class/block/$name/slaves" 2>/dev/null)" ]; then
		for s in /sys/class/block/"$name"/slaves/*; do
			rk_leaf_devs "$(basename "$s")"
		done
		return
	fi
	parent=$name
	if [ -e "/sys/class/block/$name/partition" ]; then
		parent=$(basename "$(readlink -f "/sys/class/block/$name/..")")
	fi
	if [ -n "$(ls -A "/sys/block/$parent/multipath" 2>/dev/null)" ]; then
		for p in /sys/block/"$parent"/multipath/*; do
			basename "$p"
		done
		return
	fi
	echo "$name"
}

rk_stat_snap() {
	local n f
	for n in "$@"; do
		read -r -a f < "/sys/class/block/$n/stat" || continue
		echo "$n ${f[0]} ${f[1]} ${f[2]} ${f[4]} ${f[5]} ${f[6]}"
	done
}

rk_stat_report() {
	awk -v before="$1" -v after="$2" '
	function load(text, arr,   lines, i, f, n) {
		n = split(text, lines, "\n")
		for (i = 1; i <= n; i++) {
			if (split(lines[i], f, " ") < 7) continue
			arr[f[1]] = f[2] " " f[3] " " f[4] " " f[5] " " f[6] " " f[7]
		}
	}
	function side(ios, mer, sec,   avg, pct) {
		avg = ios > 0 ? sec * 512 / ios / 1024 : 0
		pct = (ios + mer) > 0 ? 100 * mer / (ios + mer) : 0
		return sprintf("{\"requests\": %d, \"merges\": %d, \"sectors\": %d, \"avg_kib\": %.1f, \"merged_pct\": %.1f}", ios, mer, sec, avg, pct)
	}
	BEGIN {
		load(before, b); load(after, a)
		for (d in a) {
			if (!(d in b)) continue
			split(b[d], x, " "); split(a[d], y, " ")
			for (i = 1; i <= 6; i++) t[i] += y[i] - x[i]
			nd++
		}
		printf "{\"devices\": %d, \"read\": %s, \"write\": %s}\n", nd, side(t[1], t[2], t[3]), side(t[4], t[5], t[6])
	}'
}
