#!/bin/bash
#
# raidkm-test-journal.sh — md write journal (--write-journal) on raidkm.
#
# The journal (raid_km-cache.c, inherited from raid5-cache) knows two parity
# slots, pd_idx and qd_idx, and replays a stripe by row sector and slot index.
# That is right for m <= 2 on a rotating or parity-last array and wrong for:
#   - m > 2: the middle parities are logged as DATA blocks at location 0, so a
#     replay writes a parity page over array block 0 (silently: the stripe's
#     parity is rebuilt to match, mismatch_cnt stays 0);
#   - declustered pools: no group in the log, and a slot is not a member.
# The kernel refuses both (r5l_init_log); this suite checks:
#   T1. m=2 rotating (write-through and write-back) and parity-last
#       (write-through): a power cut after
#       acknowledged writes, then assembly replays the journal: data
#       identical, mismatch_cnt 0.  (raidkm has no m=1: mdadm needs
#       --parity-count >= 2.)
#   T2. m=3 and m=4 rotating with a journal: refused, array not active.
# The way back for an m>2 journal array made by an older module (assemble
# without the journal, read-only; consistency_policy=resync; --readwrite)
# was checked by hand on 2026-11-16: this module cannot create the members.
# (declustered + journal is refused in raidkm-test-declustered-create.sh.)
#
# The cut: every member and the journal sit on dm-linear; all are suspended
# together and reloaded as dm-flakey drop_writes, so nothing after that
# instant reaches any device; then the array is stopped and the linear
# tables restored, which udev may auto-assemble (the replay runs there).
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

K=4
DMN=()		# dm names created by this suite
RAWS=()		# their backing devices

# remove our dm devices; one still held is retried with --force, and a
# name that still will not go stays in DMN so the EXIT trap tries again
dm_remove_all_mine() {
	local n left=()
	for n in "${DMN[@]:-}"; do
		[ -n "$n" ] || continue
		sudo dmsetup remove "$n" 2>/dev/null ||
			sudo dmsetup remove --force "$n" 2>/dev/null ||
			left+=("$n")
	done
	DMN=("${left[@]}")
}

# Stop any md array holding one of our dm devices (udev incremental
# assembly), twice, settling before and after, so an assembly triggered by
# the stop itself is caught too and the next create/assemble or dmsetup
# remove does not race it.  Scoped to our devices, unlike rk_udev_quiesce.
stop_holders() {
	local n dm h pass
	for pass in 1 2; do
		sudo udevadm settle 2>/dev/null
		for n in "${DMN[@]:-}"; do
			[ -n "$n" ] || continue
			dm=$(basename "$(readlink -f "/dev/mapper/$n")")
			for h in /sys/block/"$dm"/holders/md*; do
				[ -e "$h" ] && sudo "$MDADM" --stop "/dev/$(basename "$h")" >/dev/null 2>&1
			done
		done
	done
	sudo udevadm settle 2>/dev/null
	return 0
}

cleanup() {
	rk_stop
	stop_holders
	dm_remove_all_mine
	local r
	for r in "${RAWS[@]:-}"; do
		[ -n "$r" ] && sudo "$MDADM" --zero-superblock "$r" 2>/dev/null
	done
	rm -f "$RK_TMP"/jr-*
}
trap cleanup EXIT

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
command -v dmsetup >/dev/null 2>&1 || rk_skip "dmsetup not installed"
sudo modprobe dm-flakey || rk_skip "dm-flakey not available"
# T1 needs K+2+1 devices (members + journal); T2 needs K+M+1 and skips an m
# the rig cannot hold.  Ram disks are made for all of it; a real-device rig
# (RK_DEVS) only has to hold T1, so a smaller rig still runs the replay gate.
if [ -n "${RK_DEVS:-}" ]; then rk_setup_brd $((K + 2 + 1)); else rk_setup_brd $((K + 4 + 1)); fi || exit 1

# setup_dm <count>: wrap the first <count> devices in dm-linear rkjr0..
setup_dm() {
	local cnt="$1" i sz
	read -r -a RAWS <<< "$(rk_pick_disks "$cnt" 2>/dev/null)"
	[ "${#RAWS[@]}" -ge "$cnt" ] || return 1
	for i in "${!RAWS[@]}"; do
		sudo "$MDADM" --zero-superblock "${RAWS[$i]}" 2>/dev/null
		sudo dd if=/dev/zero of="${RAWS[$i]}" bs=1M count=4 status=none
		sz=$(sudo blockdev --getsz "${RAWS[$i]}")
		sudo dmsetup create "rkjr$i" --table "0 $sz linear ${RAWS[$i]} 0" || return 1
		DMN+=("rkjr$i")
	done
	sudo udevadm settle
	return 0
}

# cut_all: the atomic power cut (two-phase, as crash_now in
# raidkm-test-declustered-reshape-flakey.sh): suspend every device WITHOUT
# flushing, so in-flight bios are held, not drained to the backing device;
# load drop_writes everywhere; resume, and the held bios go to drop_writes
cut_all() {
	local i sz
	for i in "${!DMN[@]}"; do
		sudo dmsetup suspend --noflush --nolockfs --noudevsync "${DMN[$i]}"
	done
	for i in "${!DMN[@]}"; do
		sz=$(sudo blockdev --getsz "${RAWS[$i]}")
		sudo dmsetup load "${DMN[$i]}" --table "0 $sz flakey ${RAWS[$i]} 0 0 3600 1 drop_writes"
	done
	for i in "${!DMN[@]}"; do sudo dmsetup resume "${DMN[$i]}"; done
}
restore_all() {
	local i sz
	for i in "${!DMN[@]}"; do
		sz=$(sudo blockdev --getsz "${RAWS[$i]}")
		sudo dmsetup suspend "${DMN[$i]}"
		sudo dmsetup load "${DMN[$i]}" --table "0 $sz linear ${RAWS[$i]} 0"
		sudo dmsetup resume "${DMN[$i]}"
	done
	sudo udevadm settle
}

# ---- T1: cut + replay ----------------------------------------------------------
# t1 <m> <journal_mode> <layout>
t1() {
	local M="$1" mode="$2" lay="$3" N i tag mm cur
	N=$((K + M)); tag="T1 m=$M $lay $mode"
	setup_dm $((N + 1)) || { rk_fail "$tag: dm setup failed"; dm_remove_all_mine; return; }
	local MEM=(); for i in $(seq 0 $((N - 1))); do MEM+=("/dev/mapper/rkjr$i"); done
	local JDEV=/dev/mapper/rkjr$N
	rk_stop
	if ! sudo "$MDADM" --create "$MD" --level=raidkm --parity-count="$M" --layout="$lay" \
		--chunk="$CHUNK_KB" --raid-devices=$N --write-journal="$JDEV" "${MEM[@]}" \
		--run --force >/dev/null 2>&1; then
		rk_fail "$tag: create with a write journal failed"
		sudo dmesg | tail -4 | sed 's/^/      · /'
		rk_stop; stop_holders; dm_remove_all_mine; return
	fi
	rk_wait_idle
	# set the mode even for write-through, and check it either way, so a
	# changed default fails loudly instead of repeating the other run
	echo "$mode" | sudo tee "/sys/block/$MDNAME/md/journal_mode" >/dev/null 2>&1
	cur=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "/sys/block/$MDNAME/md/journal_mode")
	if [ "$cur" != "$mode" ]; then
		rk_fail "$tag: journal_mode is '$cur', not '$mode'"
		rk_stop; stop_holders; dm_remove_all_mine; return
	fi
	local A="$RK_TMP/jr-a" B="$RK_TMP/jr-b" E="$RK_TMP/jr-e" G="$RK_TMP/jr-g"
	head -c 8M /dev/urandom > "$A"
	head -c 64K /dev/urandom > "$B"
	sudo dd if="$A" of="$MD" bs=1M oflag=direct status=none
	sync
	# partial-stripe writes (read-modify-write, data + parity logged)
	sudo dd if="$B" of="$MD" bs=64K seek=16 oflag=direct status=none
	sudo dd if="$B" of="$MD" bs=64K seek=48 oflag=direct status=none
	cp "$A" "$E"
	dd if="$B" of="$E" bs=64K seek=16 conv=notrunc status=none
	dd if="$B" of="$E" bs=64K seek=48 conv=notrunc status=none
	rk_dmesg_window_close
	rk_dmesg_clear
	cut_all
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	restore_all
	stop_holders		# a udev assembly has already replayed: fine
	if sudo "$MDADM" --assemble "$MD" "${MEM[@]}" "$JDEV" --run >/dev/null 2>&1; then
		rk_wait_idle
		# write-through logs data + parity (data-parity stripes); write-back
		# acknowledges once data is logged (data-only stripes)
		if sudo dmesg | grep -oE "recovering [0-9]+ data-only stripes and [0-9]+ data-parity stripes" |
		   grep -qvE "recovering 0 data-only stripes and 0 data-parity"; then
			rk_pass "$tag: journal replayed after the cut ($(sudo dmesg | grep -oE 'recovering [0-9]+ data-only stripes and [0-9]+ data-parity stripes' | head -1))"
		else
			rk_fail "$tag: no journal replay logged after the cut"
		fi
		sudo dd if="$MD" of="$G" bs=1M count=8 iflag=direct status=none
		if cmp -s "$G" "$E"; then
			rk_pass "$tag: data after replay identical (8 MiB, incl. block 0)"
		else
			rk_fail "$tag: data after replay differs ($(cmp -l "$G" "$E" | wc -l) bytes)"
		fi
		mm=$(rk_scrub 2>/dev/null | tail -1)
		[ "$mm" = 0 ] && rk_pass "$tag: check after replay: mismatch_cnt 0" \
			      || rk_fail "$tag: check after replay: mismatch_cnt $mm"
	else
		rk_fail "$tag: assemble after the cut failed"
		sudo dmesg | tail -4 | sed 's/^/      · /'
	fi
	rk_stop; stop_holders; dm_remove_all_mine
}

t1 2 write-through rotating
t1 2 write-back rotating
t1 2 write-through parity-last

# ---- T2: m>2 refused -----------------------------------------------------------
for M in 3 4; do
	N=$((K + M))
	read -r -a R2 <<< "$(rk_pick_disks $((N + 1)) 2>/dev/null)"
	if [ "${#R2[@]}" -lt $((N + 1)) ]; then
		rk_skip_check "T2: m=$M needs $((N + 1)) devices"
		continue
	fi
	sudo "$MDADM" --zero-superblock "${R2[@]}" 2>/dev/null
	rk_dmesg_window_close
	rk_dmesg_clear
	sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M --layout=rotating \
		--chunk="$CHUNK_KB" --raid-devices=$N --write-journal="${R2[$N]}" \
		"${R2[@]:0:$N}" --run --force >/dev/null 2>&1
	if grep -q "^$MDNAME : active" /proc/mdstat; then
		rk_fail "T2: m=$M with a write journal is ACTIVE (must be refused)"
	elif sudo dmesg | grep -q "write journal supports at most 2 parities (array has $M)"; then
		rk_pass "T2: m=$M with --write-journal refused by the kernel"
	else
		rk_fail "T2: m=$M journal create not active, but no refusal message"
		sudo dmesg | tail -4 | sed 's/^/      · /'
	fi
	rk_stop
	sudo "$MDADM" --zero-superblock "${R2[@]}" 2>/dev/null
done

rk_dmesg_window_close
[ "$RK_DMESG_BAD" = 0 ] && rk_pass "no kernel WARN/BUG during the run (all windows)" \
			|| rk_fail "kernel WARN/BUG in a window the suite cleared"
rk_summary
