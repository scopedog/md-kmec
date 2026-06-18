#!/bin/bash
# raidkm-test-dm-rebuild.sh — Phase 2: rebuild a raidkm (md level 71) member
# through device-mapper's dm-raid target (dmsetup), not mdadm.
#
# dm-raid drives recovery for level 71 with no raidkm-specific plumbing: the
# rebuild is requested by reloading the table with a fresh (zeroed) device in
# the victim slot plus a "rebuild <idx>" parameter, then resuming.  md's
# recovery thread reconstructs the slot with raidkm's k+m Reed-Solomon decode.
#
# For each placement (rotating = "raidkm", parity-last = "raidkm_n") at m = 2
# and 3, with k = 3 data:
#
#   1. create + initial resync to AAAAA idle
#   2. write known data, record its SHA
#   3. ZERO the victim slot's metadata+data devices and reload with
#      "rebuild <idx>" -> forces a genuine EC reconstruction, not a no-op resync
#   4. wait for recovery to finish (health back to all-A, sync_action idle)
#   5. ORACLES:
#        a. array returns to full (all 'A')
#        b. readback SHA matches the pre-rebuild data
#        c. scrub ("check" message) reports 0 mismatches
#        d. a subsequent MAX-DEGRADED read (fail m *other* slots) still
#           reconstructs -> proves the rebuilt slot is EC-correct, not merely
#           scrub-consistent.  (scrub=0 alone does not imply correct parity
#           placement on a rotating layout; cf. the f99d8f2 rebuild bug.)
#
# REQUIRES the post-f99d8f2 raidkm.ko (m=2 rotating rebuild parity fix); a
# stale module silently fails oracle (c) with a nonzero mismatch.
#
#   sudo bash tools/raidkm-test-dm-rebuild.sh
set -u

SZ_MB="${SZ_MB:-64}"          # data written/verified
LEN="${LEN:-196608}"          # array sectors (k=3 * 65536); safe per-disk size
DEV=/dev/mapper/kmtest
PASS=0; FAIL=0

pass(){ echo "  PASS: $*"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# status fields: start len "raid" "raidkm" ndev health sync_ratio sync_action mismatch ...
st_field(){ local f=$1; dmsetup status kmtest | awk -v f="$f" '{print $f}'; }
wait_idle(){  # wait until sync_action==idle (field 8); optional require-full ($2=full)
	local i hc sa
	for i in $(seq 1 180); do
		read _ _ _ _ _ hc _ sa _ <<<"$(dmsetup status kmtest)"
		[ "$sa" = idle ] && { [ "${1:-}" != full ] || [ "$hc" = "$2" ]; } && return 0
		sleep 1
	done
	return 1
}
sha(){ echo 3 > /proc/sys/vm/drop_caches; dd if=$DEV bs=1M count="$SZ_MB" iflag=direct status=none | sha256sum | cut -d' ' -f1; }
zero(){ dd if=/dev/zero of="$1" bs=1M count=8 status=none; }

# build "<meta0> <data0> ..." from a device array
pairs(){ local out=""; for d in "$@"; do out="$out $d"; done; echo "$out"; }

# A table length whose per-disk size isn't a chunk multiple must be rejected
# with EINVAL (not silently create a dm device larger than the array backs).
test_reject_misaligned(){
	echo "== reject misaligned table length =="
	for d in 0 2 4 6 8; do zero "/dev/ram$d"; done
	# 600000 / 3 data = 200000 sectors/disk, chunk 128 -> 200000 % 128 != 0
	if dmsetup create kmtest --table \
	   "0 600000 raid raidkm 3 128 parity_count 2 5 /dev/ram0 /dev/ram1 /dev/ram2 /dev/ram3 /dev/ram4 /dev/ram5 /dev/ram6 /dev/ram7 /dev/ram8 /dev/ram9" 2>/dev/null; then
		fail "misaligned length was accepted"; dmsetup remove kmtest 2>/dev/null
	else
		pass "misaligned length rejected (EINVAL)"
	fi
}

# raidkm dm reshape contract (COW-staged migration, see
# raidkm-test-dm-reshape.sh for the positive paths):
#  - GROW (delta_disks > 0) requires a data_offset argument (the constant
#    scratch headroom); without it the reload must be refused at parse time
#    rather than silently doing nothing.
#  - SHRINK (delta_disks < 0) is unimplemented in the personality and must
#    always be refused.
test_reject_reshape(){
	echo "== reject invalid data-disk reshape requests =="
	for d in 0 2 4 6 8; do zero "/dev/ram$d"; done
	if ! dmsetup create kmtest --table \
	   "0 196608 raid raidkm 3 128 parity_count 2 5 /dev/ram0 /dev/ram1 /dev/ram2 /dev/ram3 /dev/ram4 /dev/ram5 /dev/ram6 /dev/ram7 /dev/ram8 /dev/ram9" 2>/dev/null; then
		fail "reshape-test: create failed"; return
	fi
	wait_idle || true
	dmsetup suspend kmtest
	# GROW (delta_disks +1) without data_offset -> no scratch zone, refuse
	if dmsetup reload kmtest --table \
	   "0 262144 raid raidkm 5 128 parity_count 2 delta_disks 1 6 /dev/ram0 /dev/ram1 /dev/ram2 /dev/ram3 /dev/ram4 /dev/ram5 /dev/ram6 /dev/ram7 /dev/ram8 /dev/ram9 /dev/ram10 /dev/ram11" 2>/dev/null; then
		fail "grow without data_offset was accepted"
	else
		pass "grow without data_offset rejected (EINVAL)"
	fi
	# SHRINK (delta_disks -1)
	if dmsetup reload kmtest --table \
	   "0 131072 raid raidkm 5 128 parity_count 2 delta_disks -1 4 /dev/ram0 /dev/ram1 /dev/ram2 /dev/ram3 /dev/ram4 /dev/ram5 /dev/ram6 /dev/ram7" 2>/dev/null; then
		fail "shrink (delta_disks -1) was accepted"
	else
		pass "shrink rejected (EINVAL)"
	fi
	dmsetup remove kmtest 2>/dev/null
}

run_case(){
	local rtype=$1 m=$2 lbl=$3
	local n=$((3 + m))                       # k=3 + m parity members
	echo "== $lbl m=$m ($rtype, $n members) =="

	# device pairs: ram0..ram(2n-1)  -> (meta,data) per member
	local devs=() i
	for i in $(seq 0 $((2*n - 1))); do devs+=("/dev/ram$i"); done
	for d in "${devs[@]}"; do zero "$d"; done

	# dm-raid table: <start> <len> raid <raid_type> <#params> <params> <#devs> <pairs>
	local plist; plist=$(pairs "${devs[@]}")
	if ! dmsetup create kmtest --table "0 $LEN raid $rtype 3 128 parity_count $m $n $plist"; then
		fail "$lbl: create"; return
	fi
	wait_idle full "$(printf 'A%.0s' $(seq 1 $n))" || { fail "$lbl: initial resync"; dmsetup remove kmtest; return; }

	# regression: STATUSTYPE_TABLE must not deref a stale rs->raid_type
	# (used to GP-fault); the emitted line must round-trip the type + params.
	local tl; tl=$(dmsetup table kmtest)
	case " $tl " in
		*" raid $rtype 3 128 parity_count $m "*) pass "$lbl: dmsetup table round-trips" ;;
		*) fail "$lbl: dmsetup table = '$tl'" ;;
	esac

	dd if=/dev/urandom of=/tmp/pat bs=1M count="$SZ_MB" status=none
	dd if=/tmp/pat of=$DEV bs=1M count="$SZ_MB" oflag=direct status=none; blockdev --flushbufs $DEV
	local sha0; sha0=$(sha)

	# --- rebuild victim slot 1 onto its own zeroed devices ---
	local vmeta=${devs[2]} vdata=${devs[3]}    # slot 1 = devs[2],[3]
	dmsetup suspend kmtest
	zero "$vmeta"; zero "$vdata"
	dmsetup reload kmtest --table "0 $LEN raid $rtype 5 128 parity_count $m rebuild 1 $n $plist"
	dmsetup resume kmtest
	if wait_idle full "$(printf 'A%.0s' $(seq 1 $n))"; then
		pass "$lbl: rebuilt to full [$(st_field 6)]"
	else
		fail "$lbl: did not return to full [$(st_field 6)]"; dmsetup remove kmtest; return
	fi

	[ "$(sha)" = "$sha0" ] && pass "$lbl: readback after rebuild" || fail "$lbl: readback mismatch"

	dmsetup message kmtest 0 check
	wait_idle || true
	local mm; read _ _ _ _ _ _ _ _ mm _ <<<"$(dmsetup status kmtest)"
	[ "$mm" = 0 ] && pass "$lbl: scrub mismatch=0" || fail "$lbl: scrub mismatch=$mm"

	# --- max-degraded read: fail the highest m slots (slot 1, rebuilt, is kept
	# since n-m = 3 > 1) -> m missing members, must reconstruct via EC ---
	local pp="" i
	for i in $(seq 0 $((n-1))); do
		if [ "$i" -ge $((n - m)) ]; then pp="$pp - -"
		else pp="$pp ${devs[$((2*i))]} ${devs[$((2*i+1))]}"; fi
	done
	local tbl="0 $LEN raid $rtype 3 128 parity_count $m $n$pp"
	dmsetup suspend kmtest; dmsetup reload kmtest --table "$tbl"; dmsetup resume kmtest
	[ "$(sha)" = "$sha0" ] && pass "$lbl: max-degraded read reconstructs [$(st_field 6)]" \
	                       || fail "$lbl: max-degraded read [$(st_field 6)]"

	dmsetup remove kmtest
}

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
grep -q '\[raidkm\]' /proc/mdstat || { echo "raidkm personality not registered"; exit 1; }
ls /dev/ram9 >/dev/null 2>&1 || { echo "need >=10 brd ramdisks (modprobe brd rd_nr=12 rd_size=131072)"; exit 1; }

# MS = space-separated parity counts to test (default "2 3"; m>=4 needs more
# ramdisks: n=3+m members -> 2*(3+m) brd devices, e.g. MS="4 5 6" -> up to 18).
for m in ${MS:-2 3}; do
	[ "$m" -ge 2 ] && [ "$m" -le 8 ] || { echo "skip bogus m=$m"; continue; }
	ls "/dev/ram$((2*(3+m)-1))" >/dev/null 2>&1 || { fail "m=$m: need $((2*(3+m))) ramdisks"; continue; }
	run_case raidkm   "$m" rotating
	run_case raidkm_n "$m" parity-last
done

test_reject_misaligned
test_reject_reshape

echo "==== dm rebuild: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
