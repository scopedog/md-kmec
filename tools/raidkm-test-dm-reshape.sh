#!/bin/bash
# raidkm-test-dm-reshape.sh — Phase 3/4: ONLINE reshape of a raidkm (md level
# 71) array driven entirely through device-mapper's dm-raid target (dmsetup).
#
# The kernel side is the personality's COW-staged migration (see
# notes/reshape-cow-design.md): data never relocates, so dm-raid's
# data_offset-repositioning engine (which corrupts the rotating layout) is
# bypassed.  dm's role is only to deliver the request:
#
#   - the array carries a CONSTANT data_offset; the gap [0, data_offset) of
#     each data image is the COW scratch/journal zone (>= 1280 sectors needed:
#     1024 scratch + 256 superblock margin),
#   - add-data  (k -> k+1):  reload with one more member pair,
#     "delta_disks 1 data_offset <N>" and the FINAL (grown) table length,
#   - add-parity (m -> m+1): reload with one more member pair,
#     "parity_count m+1 delta_disks 1 data_offset <N>" and the SAME length.
#
# ACTIVATION IS TWO-STEP (same contract as lvm2 drives for raid456 reshape):
# the delta_disks reload only STAMPS the reshape into the dm superblocks —
# rs_start_reshape() sets MD_RECOVERY_WAIT, so the sync thread refuses to run
# until the table is reloaded again.  The reshape actually RUNS on the next
# activation: a second reload with the FINAL geometry table (all members, new
# parity_count, no delta_disks; the superblock owns the in-flight state).
#
# Covered here, rotating ("raidkm") and parity-last ("raidkm_n"):
#   1. add-data  k=3->4 @ m=2: reshape completes, data + grown region usable,
#      scrub=0, then a MAX-DEGRADED read (fail m slots) -> EC-correct.
#   2. add-parity m=2->3 @ k=3: reshape completes, data intact, scrub=0, then
#      a 3-slot-degraded read -> the NEW parity is genuine (EC oracle).
#   3. interrupt + resume: throttled add-parity reshape, dmsetup remove mid-
#      flight, recreate with the final-geometry table (no delta_disks) ->
#      reshape resumes from the journal/SB and finishes; oracles as in 2.
#   4. negatives: placement flip rejected; m-jump (m+2) rejected; insufficient
#      scratch headroom -> reshape refused (array unharmed, stays idle).
#
# Module load (built from md-kmec + mdraid trees, see notes/dm-raid-design.md):
#   insmod mdraid/isa-l/isal_lib.ko; insmod mdraid/raid456.ko
#   insmod md-kmec/km/raidkm.ko;     insmod dmrtest/dm-raid.ko
#   modprobe brd rd_nr=14 rd_size=131072
#
#   sudo bash tools/raidkm-test-dm-reshape.sh
set -u

SZ_MB="${SZ_MB:-64}"            # data written/verified (within the k=3 extent)
CH=128                          # chunk sectors (64 KiB)
DS=65536                        # per-disk data sectors (32 MiB)
LEN3=$((3*DS)); LEN4=$((4*DS))  # k=3 / k=4 table lengths
DOFF=2048                       # constant data_offset: 1 MiB scratch headroom
DEV=/dev/mapper/kmtest
PASS=0; FAIL=0

pass(){ echo "  PASS: $*"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# status fields: start len "raid" type ndev health sync_ratio sync_action mismatch ...
st(){ dmsetup status kmtest 2>/dev/null; }
wait_idle(){  # wait for sync_action==idle; optional required health string ($1)
	local i hc sa
	for i in $(seq 1 "${2:-240}"); do
		read _ _ _ _ _ hc _ sa _ <<<"$(st)"
		[ "${sa:-}" = idle ] && { [ -z "${1:-}" ] || [ "$hc" = "$1" ]; } && return 0
		sleep 1
	done
	return 1
}
sha(){ echo 3 > /proc/sys/vm/drop_caches; dd if=$DEV bs=1M count="$SZ_MB" iflag=direct status=none | sha256sum | cut -d' ' -f1; }
zero(){ dd if=/dev/zero of="$1" bs=1M count=8 status=none; }
allA(){ printf 'A%.0s' $(seq 1 "$1"); }

# member device pair lists: pairs N -> "/dev/ram0 ... /dev/ram(2N-1)"
pairs(){ local out="" i; for i in $(seq 0 $((2*$1 - 1))); do out="$out /dev/ram$i"; done; echo "$out"; }
zero_n(){ local i; for i in $(seq 0 $((2*$1 - 1))); do zero "/dev/ram$i"; done; }

# degraded read oracle: reload with the top $2 of $1 slots missing, expect $3
deg_read(){
	local n=$1 f=$2 want=$3 lbl=$4 len=$5 rtype=$6 m=$7
	local pp="" i
	for i in $(seq 0 $((n-1))); do
		if [ "$i" -ge $((n - f)) ]; then pp="$pp - -"
		else pp="$pp /dev/ram$((2*i)) /dev/ram$((2*i+1))"; fi
	done
	dmsetup suspend kmtest
	dmsetup reload kmtest --table "0 $len raid $rtype 3 $CH parity_count $m $n$pp"
	dmsetup resume kmtest
	[ "$(sha)" = "$want" ] && pass "$lbl: $f-degraded read reconstructs" \
	                       || fail "$lbl: $f-degraded read mismatch"
}

scrub0(){
	local lbl=$1 mm
	dmsetup message kmtest 0 check
	wait_idle "" || true
	read _ _ _ _ _ _ _ _ mm _ <<<"$(st)"
	[ "${mm:-x}" = 0 ] && pass "$lbl: scrub mismatch=0" || fail "$lbl: scrub mismatch=${mm:-?}"
}

# ---- 1. add-data k=3 -> 4 at fixed m=2 -------------------------------------
test_grow_data(){
	local rtype=$1 lbl="$1 add-data k3->4"
	echo "== $lbl =="
	zero_n 6
	if ! dmsetup create kmtest --table \
	   "0 $LEN3 raid $rtype 5 $CH parity_count 2 data_offset $DOFF 5$(pairs 5)"; then
		fail "$lbl: create"; return
	fi
	wait_idle "$(allA 5)" || { fail "$lbl: initial resync"; dmsetup remove kmtest; return; }

	dd if=/dev/urandom of=/tmp/pat bs=1M count="$SZ_MB" status=none
	dd if=/tmp/pat of=$DEV bs=1M oflag=direct status=none; blockdev --flushbufs $DEV
	local sha0; sha0=$(sha)

	dmsetup suspend kmtest
	if ! dmsetup reload kmtest --table \
	   "0 $LEN4 raid $rtype 7 $CH parity_count 2 delta_disks 1 data_offset $DOFF 6$(pairs 6)"; then
		fail "$lbl: grow reload rejected"; dmsetup resume kmtest; dmsetup remove kmtest; return
	fi
	dmsetup resume kmtest        # stamps the reshape into the superblocks
	dmsetup suspend kmtest
	dmsetup reload kmtest --table "0 $LEN4 raid $rtype 3 $CH parity_count 2 6$(pairs 6)"
	dmsetup resume kmtest        # second activation actually runs the reshape
	if wait_idle "$(allA 6)" 600; then
		pass "$lbl: reshape completed to 6 members"
	else
		fail "$lbl: reshape did not complete [$(st)]"; dmsetup remove kmtest; return
	fi

	[ "$(sha)" = "$sha0" ] && pass "$lbl: data intact after grow" || fail "$lbl: data mismatch after grow"

	# the grown region (beyond the old k=3 capacity, 96 MiB) must be addressable
	if timeout 30 dd if=/dev/urandom of=$DEV bs=1M count=8 seek=100 oflag=direct status=none 2>/dev/null &&
	   timeout 30 dd if=$DEV bs=1M count=8 skip=100 iflag=direct status=none >/dev/null 2>&1; then
		pass "$lbl: grown region readable/writable"
	else
		fail "$lbl: grown region I/O failed (array size not grown?)"
	fi

	scrub0 "$lbl"
	deg_read 6 2 "$sha0" "$lbl" "$LEN4" "$rtype" 2
	dmsetup remove kmtest
}

# ---- 2. add-parity m=2 -> 3 at fixed k=3 -----------------------------------
test_add_parity(){
	local rtype=$1 lbl="$1 add-parity m2->3"
	echo "== $lbl =="
	zero_n 6
	if ! dmsetup create kmtest --table \
	   "0 $LEN3 raid $rtype 5 $CH parity_count 2 data_offset $DOFF 5$(pairs 5)"; then
		fail "$lbl: create"; return
	fi
	wait_idle "$(allA 5)" || { fail "$lbl: initial resync"; dmsetup remove kmtest; return; }

	dd if=/dev/urandom of=/tmp/pat bs=1M count="$SZ_MB" status=none
	dd if=/tmp/pat of=$DEV bs=1M oflag=direct status=none; blockdev --flushbufs $DEV
	local sha0; sha0=$(sha)

	dmsetup suspend kmtest
	if ! dmsetup reload kmtest --table \
	   "0 $LEN3 raid $rtype 7 $CH parity_count 3 delta_disks 1 data_offset $DOFF 6$(pairs 6)"; then
		fail "$lbl: add-parity reload rejected"; dmsetup resume kmtest; dmsetup remove kmtest; return
	fi
	dmsetup resume kmtest        # stamps the reshape into the superblocks
	dmsetup suspend kmtest
	dmsetup reload kmtest --table "0 $LEN3 raid $rtype 3 $CH parity_count 3 6$(pairs 6)"
	dmsetup resume kmtest        # second activation actually runs the reshape
	if wait_idle "$(allA 6)" 600; then
		pass "$lbl: reshape completed to m=3"
	else
		fail "$lbl: reshape did not complete [$(st)]"; dmsetup remove kmtest; return
	fi

	[ "$(sha)" = "$sha0" ] && pass "$lbl: data intact" || fail "$lbl: data mismatch"
	local tl; tl=$(dmsetup table kmtest)
	case " $tl " in
		*" parity_count 3 "*) pass "$lbl: table reports parity_count 3" ;;
		*) fail "$lbl: table = '$tl'" ;;
	esac
	scrub0 "$lbl"
	# EC oracle: the NEW (3rd) parity must be genuine -> fail 3 slots
	deg_read 6 3 "$sha0" "$lbl" "$LEN3" "$rtype" 3
	dmsetup remove kmtest
}

# ---- 3. interrupt mid-reshape, recreate, resume ----------------------------
test_resume_interrupted(){
	local rtype=$1 lbl="$1 interrupt+resume"
	echo "== $lbl =="
	zero_n 6
	dmsetup create kmtest --table \
	   "0 $LEN3 raid $rtype 5 $CH parity_count 2 data_offset $DOFF 5$(pairs 5)" || { fail "$lbl: create"; return; }
	wait_idle "$(allA 5)" || { fail "$lbl: initial resync"; dmsetup remove kmtest; return; }

	dd if=/dev/urandom of=/tmp/pat bs=1M count="$SZ_MB" status=none
	dd if=/tmp/pat of=$DEV bs=1M oflag=direct status=none; blockdev --flushbufs $DEV
	local sha0; sha0=$(sha)

	# stamp the reshape, then activate with a throttle so we can reliably
	# catch it in flight
	dmsetup suspend kmtest
	dmsetup reload kmtest --table \
	   "0 $LEN3 raid $rtype 7 $CH parity_count 3 delta_disks 1 data_offset $DOFF 6$(pairs 6)" \
	   || { fail "$lbl: reshape reload"; dmsetup resume kmtest; dmsetup remove kmtest; return; }
	dmsetup resume kmtest
	dmsetup suspend kmtest
	dmsetup reload kmtest --table \
	   "0 $LEN3 raid $rtype 5 $CH parity_count 3 max_recovery_rate 512 6$(pairs 6)" \
	   || { fail "$lbl: throttled activation reload"; dmsetup resume kmtest; dmsetup remove kmtest; return; }
	dmsetup resume kmtest

	local i sa ratio cur=0
	for i in $(seq 1 60); do
		read _ _ _ _ _ _ ratio sa _ <<<"$(st)"
		cur=${ratio%%/*}
		[ "${sa:-}" = reshape ] && [ "${cur:-0}" -gt 0 ] 2>/dev/null && break
		sleep 1
	done
	if [ "${sa:-}" = reshape ]; then
		pass "$lbl: reshape in flight (${ratio:-?})"
	else
		fail "$lbl: never observed in-flight reshape [$(st)]"; dmsetup remove kmtest; return
	fi

	dmsetup remove kmtest || { fail "$lbl: mid-reshape remove"; return; }

	# recreate with the FINAL geometry table: all 6 members, parity_count 3,
	# NO delta_disks (the superblock owns the in-flight reshape state)
	if ! dmsetup create kmtest --table \
	   "0 $LEN3 raid $rtype 3 $CH parity_count 3 6$(pairs 6)"; then
		fail "$lbl: recreate mid-reshape"; return
	fi
	if wait_idle "$(allA 6)" 600; then
		pass "$lbl: resumed and completed"
	else
		fail "$lbl: did not complete after resume [$(st)]"; dmsetup remove kmtest; return
	fi
	[ "$(sha)" = "$sha0" ] && pass "$lbl: data intact" || fail "$lbl: data mismatch"
	scrub0 "$lbl"
	deg_read 6 3 "$sha0" "$lbl" "$LEN3" "$rtype" 3
	dmsetup remove kmtest
}

# ---- 4. negatives -----------------------------------------------------------
test_negatives(){
	echo "== negatives =="
	zero_n 6
	dmsetup create kmtest --table \
	   "0 $LEN3 raid raidkm 5 $CH parity_count 2 data_offset $DOFF 5$(pairs 5)" || { fail "neg: create"; return; }
	wait_idle "$(allA 5)" || { fail "neg: initial resync"; dmsetup remove kmtest; return; }
	dd if=/dev/urandom of=/tmp/pat bs=1M count="$SZ_MB" status=none
	dd if=/tmp/pat of=$DEV bs=1M oflag=direct status=none; blockdev --flushbufs $DEV
	local sha0; sha0=$(sha)
	dmsetup suspend kmtest

	# placement flip (rotating -> parity-last) is not a reshape we support
	if dmsetup reload kmtest --table \
	   "0 $LEN3 raid raidkm_n 5 $CH parity_count 2 data_offset $DOFF 5$(pairs 5)" 2>/dev/null; then
		fail "neg: placement flip accepted"
		dmsetup reload kmtest --table "0 $LEN3 raid raidkm 5 $CH parity_count 2 data_offset $DOFF 5$(pairs 5)"
	else
		pass "neg: placement flip rejected"
	fi

	# m jump (2 -> 4 with two new disks) must be refused (single step only)
	zero /dev/ram12; zero /dev/ram13
	if dmsetup reload kmtest --table \
	   "0 $LEN3 raid raidkm 7 $CH parity_count 4 delta_disks 2 data_offset $DOFF 7$(pairs 7)" 2>/dev/null; then
		fail "neg: m+2 jump accepted"
		dmsetup reload kmtest --table "0 $LEN3 raid raidkm 5 $CH parity_count 2 data_offset $DOFF 5$(pairs 5)"
	else
		pass "neg: m+2 jump rejected"
	fi
	dmsetup resume kmtest
	dmsetup remove kmtest

	# insufficient scratch headroom: array created with data_offset 512
	# (< 1024+256) -> the reshape must be refused by the personality and the
	# array must keep running unreshaped with data intact
	zero_n 6
	dmsetup create kmtest --table \
	   "0 $LEN3 raid raidkm 5 $CH parity_count 2 data_offset 512 5$(pairs 5)" || { fail "neg: create(512)"; return; }
	wait_idle "$(allA 5)" || { fail "neg: initial resync(512)"; dmsetup remove kmtest; return; }
	dd if=/tmp/pat of=$DEV bs=1M oflag=direct status=none; blockdev --flushbufs $DEV
	sha0=$(sha)
	dmsetup suspend kmtest
	dmsetup reload kmtest --table \
	   "0 $LEN4 raid raidkm 7 $CH parity_count 2 delta_disks 1 data_offset 512 6$(pairs 6)" 2>/dev/null \
	   && dmsetup resume kmtest || dmsetup resume kmtest
	sleep 3
	local sa; read _ _ _ _ _ _ _ sa _ <<<"$(st)"
	[ "${sa:-}" = idle ] && pass "neg: no-headroom reshape refused (idle)" \
	                     || fail "neg: no-headroom reshape ran?! [$(st)]"
	[ "$(sha)" = "$sha0" ] && pass "neg: data intact after refused reshape" \
	                       || fail "neg: data damaged by refused reshape"
	dmsetup remove kmtest
}

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
grep -q '\[raidkm\]' /proc/mdstat 2>/dev/null || modprobe raidkm 2>/dev/null
grep -q '\[raidkm\]' /proc/mdstat || { echo "raidkm personality not registered"; exit 1; }
dmsetup targets | grep -q ^raid || { echo "dm-raid target not loaded"; exit 1; }
ls /dev/ram13 >/dev/null 2>&1 || { echo "need >=14 brd ramdisks (modprobe brd rd_nr=14 rd_size=131072)"; exit 1; }

for rtype in raidkm raidkm_n; do
	test_grow_data "$rtype"
	test_add_parity "$rtype"
	test_resume_interrupted "$rtype"
done
test_negatives

echo "==== dm reshape: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
