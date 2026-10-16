#!/bin/bash
# raidkm-test-tunables.sh — a sysfs tuning write that changes nothing must not
# suspend the array.
#
# group_thread_cnt, worker_thread_cnt and skip_copy (and stripe_size, where it
# is writable) suspend the array to apply a new value.  Tuning tools rewrite
# every value on every md change uevent (mdadm --readwrite, a writer closing
# the device), so each of those writes used to drain the array's I/O for
# nothing (reported by HRT, 2026-10-14).  The stores now answer a write of the
# current value before the suspend.
#
# What this proves (k=4 m=2 rotating), counting mddev_suspend() calls with a
# kprobe (kprobe_profile):
#   T1  writing each setting's current value, 5 times: 0 suspends
#   T2  writing a different value still applies it (the show reads it back)
#       and does suspend; writing the old value back restores it
#
# Usage: bash <this>     (see raidkm-test-lib.sh for configuration)
set -u
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

TR=/sys/kernel/tracing
[ -d "$TR/events" ] || TR=/sys/kernel/debug/tracing
PROBE=rk_tunables/suspend

cleanup() {
	if [ -e "$TR/events/$PROBE/enable" ]; then
		echo 0 > "$TR/events/$PROBE/enable"
		echo "-:$PROBE" >> "$TR/kprobe_events"
	fi
	rk_stop 2>/dev/null
}
trap cleanup EXIT

# the worker groups: one per node ID up to the highest possible one
# (alloc_thread_groups, nr_node_ids), not one per possible node -- they differ
# on a sparse map ("0,2" is 3 groups); the map is a list ("0,2", "0-1,4-5")
possible_nodes() {
	local p r hi=0
	p=$(cat /sys/devices/system/node/possible 2>/dev/null) || { echo 1; return; }
	for r in ${p//,/ }; do
		r=${r#*-}
		[ "$r" -gt "$hi" ] && hi=$r
	done
	echo $(( hi + 1 ))
}
suspends() { awk -v p="${PROBE#*/}" '$1 == p { print $2 }' "$TR/kprobe_profile"; }

rk_load_modules || exit 1
rk_setup_brd 6 || exit 1
mountpoint -q "$TR" || mount -t tracefs none "$TR" 2>/dev/null
# a run killed before its EXIT trap (a suite timeout, a Ctrl-C) leaves the
# probe registered and enabled: removing an enabled probe fails (-EBUSY), and
# the add below would then register a second one.  Disable, then drop it.
[ -e "$TR/events/$PROBE/enable" ] && echo 0 > "$TR/events/$PROBE/enable" 2>/dev/null
echo "-:$PROBE" >> "$TR/kprobe_events" 2>/dev/null
if ! echo "p:$PROBE mddev_suspend" >> "$TR/kprobe_events" 2>/dev/null; then
	rk_skip "no kprobe on mddev_suspend (kprobe_events unavailable)"
fi
echo 1 > "$TR/events/$PROBE/enable" || rk_skip "cannot enable the kprobe"

disks=$(rk_pick_disks 6) || { rk_fail "not enough ramdisks"; rk_summary; exit 1; }
rk_create 2r $disks || { rk_fail "create"; rk_summary; exit 1; }
rk_write 16
# the dd above closes $MD: a change uevent, and a host rule that rewrites md
# tunings on it would suspend between the counts below.  Let it run first.
udevadm settle 2>/dev/null
Y=/sys/block/$MDNAME/md

knobs=(group_thread_cnt worker_thread_cnt skip_copy)
[ -w "$Y/stripe_size" ] && [ "$(getconf PAGESIZE)" != 4096 ] && knobs+=(stripe_size)

# ---- T1: the current value, again ---------------------------------------------
for k in "${knobs[@]}"; do
	v=$(cat "$Y/$k")
	s0=$(suspends)
	for i in 1 2 3 4 5; do echo "$v" > "$Y/$k" || rk_fail "T1: $k: write of $v failed"; done
	s1=$(suspends)
	[ "$s1" = "$s0" ] && [ "$(cat "$Y/$k")" = "$v" ] &&
		rk_pass "T1: $k: 5 writes of the current value ($v), 0 suspends" ||
		rk_fail "T1: $k: 5 writes of the current value ($v): $((s1 - s0)) suspends, now $(cat "$Y/$k")"
done

# ---- T2: a different value still applies --------------------------------------
for k in group_thread_cnt worker_thread_cnt skip_copy; do
	v=$(cat "$Y/$k")
	case $k in
	skip_copy) nv=$(( !v )) ;;
	worker_thread_cnt) nv=$(( v + $(possible_nodes) )) ;;	# one more per group
	*) nv=$(( v + 1 )) ;;
	esac
	s0=$(suspends)
	echo "$nv" > "$Y/$k"
	got=$(cat "$Y/$k"); s1=$(suspends)
	echo "$v" > "$Y/$k"
	back=$(cat "$Y/$k")
	[ "$got" = "$nv" ] && [ "$s1" -gt "$s0" ] && [ "$back" = "$v" ] &&
		rk_pass "T2: $k: $v -> $nv applied ($((s1 - s0)) suspend), back to $v" ||
		rk_fail "T2: $k: $v -> $nv read back $got with $((s1 - s0)) suspends, restored to $back"
done

rk_readback 16 && rk_pass "data intact" || rk_fail "data changed"
rk_summary
