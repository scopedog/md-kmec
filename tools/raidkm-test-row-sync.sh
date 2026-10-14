#!/bin/bash
# raidkm-test-row-sync.sh — resync, check and repair through the row layer.
#
# With rk_row_sync=1 a resync, a check or a repair of a healthy array reads
# each chunk-aligned row as one request per member, encodes it once and
# compares the parity on disk with the parity computed
# (raidkm_row_sync_chunk), instead of 32 stripe heads of 4 KiB per chunk.
# The stripe cache's own check (rk_row_sync=0) is the independent oracle
# throughout: the two engines must agree on every count, and what one repairs
# the other must find clean.
#   T1  a check of a clean array runs through rows (sync_done covers every
#       chunk, nothing goes to the stripe cache), finds nothing, and with
#       rk_row_sync=0 the counter stands still.
#   T2  the initial sync of members full of random data, through rows: parity
#       chunks are rewritten, the stripe cache's check then finds 0, and data
#       written afterwards reads back.
#   T3  parity blocks corrupted at known places (two parities of one block
#       count once): both engines report the same mismatch_cnt; a row repair
#       reports it too and fixes it; both engines then find 0; data intact.
#   T4  data blocks corrupted at known places: both engines report the same
#       count, and after a row repair both find 0.
#   T5  the stale-cache case.  A read-modify-write leaves a stripe's parity
#       cached; if that parity was wrong, a row repair fixes it on disk
#       underneath the cache, and the next read-modify-write of the stripe
#       must not start from the old cached parity.
#   T6  checks looping under random and sequential writes: mismatch_cnt stays
#       0 every time (a mismatch here means a row was read while a write to it
#       was in flight), fio's verify passes, and the stripe cache agrees.
#   T7  a repair of corrupted parity under writes elsewhere: the stripe
#       cache's check finds 0 afterwards.
#   T8  an internal bitmap: the initial resync through rows leaves no dirty
#       bit (the row path told the bitmap what it synced), a resync over the
#       clean bitmap skips everything, and a check is clean.  Again with a
#       bitmap chunk smaller than the raid chunk, where a row spans several
#       bitmap bits.
#   T9  pass control under a throttled check: knob flipped off and on, the
#       window resized, held at sync_max and released, frozen, interrupted
#       and run again -- every pass ends, nothing is found, data intact.
#   T10 a member fails under a row check: the pass lets go of the rows and
#       ends, the array is degraded and the data still reads back.
#   T11 other geometries -- 4+2, m=3, m=4, parity-last, a 64 KiB chunk: the
#       initial sync through rows is clean to the stripe cache, corruption is
#       counted the same by both, and a row repair is clean to both.
#   T12 native checksum: the initial resync through rows publishes the CRCs
#       (a full read raises no mismatch and returns the data), and a check
#       that meets a rotted block hands the row to the stripe cache
#       (sync_csum_bad moves), which heals it.  An automatic resync over
#       wrong parity publishes the CRC of the parity it writes: the checks
#       after it agree with the stored CRCs.
#   T13 T6 again with every member behind dm-delay, writes delayed differently
#       by member: the rig on which a check that did not hold its row DOES
#       report mismatches, which a ramdisk cannot show.
#
# Usage: bash <this>    (CHUNK_KB default 128, T11 sets its own;
#                        RS_ONLY="T5 T8" runs only those tests)
set -u
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

CHUNK_KB=${CHUNK_KB:-128}
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

PATMB=${PATMB:-64}
BASE_EXTRA="${RK_CREATE_EXTRA:---bitmap=none}"
RK_CREATE_EXTRA="$BASE_EXTRA"
MEMBERS=()
NDEV=0			# members of the current array
LAYOUT=			# its layout string ("2r", "3", ...)
DEFPARAM=/sys/module/raidkm/parameters/default_row_sync
DEFSAVED=

cleanup() {
	local d
	[ -n "${BGPID:-}" ] && kill "$BGPID" 2>/dev/null
	[ -n "$DEFSAVED" ] && echo "$DEFSAVED" > "$DEFPARAM" 2>/dev/null
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	for d in /dev/mapper/rksync*; do
		[ -e "$d" ] && dmsetup remove "$(basename "$d")" 2>/dev/null
	done
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
}
trap cleanup EXIT

command -v fio >/dev/null || { echo "ERROR: fio not installed" >&2; exit 1; }
mkdir -p "$RK_TMP"
rk_load_modules || exit 1
rk_setup_brd 12 || exit 1
DISKS=$(rk_pick_disks 12) || { echo "ERROR: need 12 devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"
[ -w "$DEFPARAM" ] || rk_skip "this raidkm has no rk_row_sync (no $DEFPARAM)"
DEFSAVED=$(cat "$DEFPARAM")

SYS() { echo "/sys/block/$MDNAME/md/$1"; }
row_stat() {	# never empty: an empty value would turn [ -gt ] into a green run
	local v
	v=$(sed -n "s/^$1 //p" "$(SYS rk_row_stats)" 2>/dev/null)
	echo "${v:-0}"
}
knob()   { echo "$2" | sudo tee "$(SYS "$1")" >/dev/null 2>&1; }
splats() { sudo dmesg | rk_dmesg_filter_known | grep -cE "$RK_SPLAT"; }
dropc()  { echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null; }
chunks() {	# chunks per member
	echo $(( $(cat "$(SYS component_size)") / CHUNK_KB ))
}

# randomize <n>: fill the first n members, so a new array's parity is wrong
# everywhere and its initial sync has every row to do
randomize() {
	local d
	rk_stop			# not under the previous test's array
	for d in "${MEMBERS[@]:0:$1}"; do
		sudo dd if=/dev/urandom of="$d" bs=1M status=none 2>/dev/null
	done
}
# setup <layout> <ndisks> <initial-sync engine: 0 stripe cache | 1 rows>
setup() {
	LAYOUT=$1; NDEV=$2
	echo "$3" > "$DEFPARAM"
	rk_create "$1" "${MEMBERS[@]:0:$2}" || { echo "$DEFSAVED" > "$DEFPARAM"; return 1; }
	echo "$DEFSAVED" > "$DEFPARAM"
	[ "$(cat "$(SYS rk_row_sync)")" = "$3" ]
}
# run <check|repair|resync> <engine>: one pass, echo mismatch_cnt
run() {
	knob rk_row_sync "$2"
	echo "$1" > "$(SYS sync_action)"
	# md starts the pass from its own thread, which on a busy array can be
	# later than a look at /proc/mdstat: wait on sync_action
	rk_wait_pass
	cat "$(SYS mismatch_cnt)"
}
reassemble() {	# stop and assemble: nothing stays cached, the array is clean
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	rk_udev_quiesce
	rk_assemble "${MEMBERS[@]:0:$NDEV}"
}
stop_array() {
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	rk_udev_quiesce
}

# The member slot holding parity index <p> of member row <row>: parity p sits
# at slot pd+p, with pd = n-1-(row mod n) rotating, k otherwise.
par_slot() {	# par_slot <row> <p>
	local m pd
	m=$(rk_m_of "$LAYOUT")
	if [ "${LAYOUT: -1}" = r ]; then pd=$(( NDEV - 1 - $1 % NDEV ))
	else pd=$(( NDEV - m )); fi
	echo $(( (pd + $2) % NDEV ))
}
data_slot() {	# data_slot <row> <d>
	local m pd
	m=$(rk_m_of "$LAYOUT")
	if [ "${LAYOUT: -1}" = r ]; then pd=$(( NDEV - 1 - $1 % NDEV ))
	else pd=$(( NDEV - m )); fi
	echo $(( (pd + m + $2) % NDEV ))
}
# rot <slot> <row> <4K block in the chunk>: overwrite that block of the member
# raw.  The array must be stopped, or the stripe cache may still hold the block.
rot() {
	local dev=${MEMBERS[$1]} off
	off=$(rk_data_offset "$dev")
	[ -n "$off" ] || return 1
	sudo dd if=/dev/urandom of="$dev" bs=4k count=1 oflag=direct conv=notrunc \
		seek=$(( off / 8 + $2 * CHUNK_KB / 4 + $3 )) status=none 2>/dev/null
}

mk_pattern() { dd if=/dev/urandom of="$1" bs=1M count="$2" status=none; }
put() {	# put <file> <offset bytes> <bs>
	sudo dd if="$1" of="$MD" bs="$3" seek="$2" oflag=direct,seek_bytes \
		conv=notrunc status=none 2>/dev/null
}
same() {	# same <file> <offset bytes>
	local len want got
	len=$(stat -c %s "$1")
	want=$(md5sum < "$1" | cut -d' ' -f1)
	dropc
	got=$(sudo dd if="$MD" bs=1M skip="$2" iflag=direct,skip_bytes \
		status=none 2>/dev/null | head -c "$len" | md5sum | cut -d' ' -f1)
	[ "$want" = "$got" ]
}
throttle()   { echo 1000 > "$(SYS sync_speed_min)"; echo "${1:-20000}" > "$(SYS sync_speed_max)"; }
unthrottle() { echo 2000000 > "$(SYS sync_speed_min)"; echo 2000000 > "$(SYS sync_speed_max)"; }
running()    { grep -qE 'check|resync|repair' /proc/mdstat; }
CHUNK0=$CHUNK_KB
sudo dmesg -C

echo "== raidkm row resync/check: chunk ${CHUNK_KB}K =="

# ---- T1: a check of a clean array runs through rows --------------------------
t1() {
if setup 2r 10 0; then
	mk_pattern "$RK_TMP/pat" "$PATMB"; put "$RK_TMP/pat" 0 1M
	nch=$(chunks)
	d0=$(row_stat sync_done); s0=$(row_stat sync_stripe_chunks)
	mm=$(run check 1)
	d=$(( $(row_stat sync_done) - d0 )); sc=$(( $(row_stat sync_stripe_chunks) - s0 ))
	if [ "$mm" = 0 ] && [ "$d" = "$nch" ] && [ "$sc" = 0 ]; then
		rk_pass "T1: check through rows: sync_done $d = $nch chunks, 0 to the stripe cache, mismatch_cnt 0"
	else
		rk_fail "T1: check through rows: sync_done $d of $nch, stripe_chunks $sc, mismatch_cnt $mm"
	fi
	d0=$(row_stat sync_done)
	mm=$(run check 0)
	d=$(( $(row_stat sync_done) - d0 ))
	if [ "$mm" = 0 ] && [ "$d" = 0 ]; then
		rk_pass "T1: control rk_row_sync=0: sync_done stands still, mismatch_cnt 0"
	else
		rk_fail "T1: control rk_row_sync=0: sync_done moved $d, mismatch_cnt $mm"
	fi
	same "$RK_TMP/pat" 0 && rk_pass "T1: data intact" || rk_fail "T1: data changed"
else
	rk_fail "T1: setup"
fi
}

# ---- T2: the initial sync through rows --------------------------------------
t2() {
randomize 10
if setup 2r 10 1; then
	nch=$(chunks)
	d=$(row_stat sync_done); w=$(row_stat sync_parity_writes)
	sc=$(row_stat sync_stripe_chunks)
	if [ "$d" = "$nch" ] && [ "$sc" = 0 ] && [ "$w" -gt "$nch" ]; then
		rk_pass "T2: initial sync through rows: sync_done $d = $nch chunks, $w parity chunks rewritten"
	else
		rk_fail "T2: initial sync through rows: sync_done $d of $nch, stripe_chunks $sc, parity writes $w"
	fi
	mm=$(run check 0)
	[ "$mm" = 0 ] && rk_pass "T2: the stripe cache's check finds 0 after it" ||
		rk_fail "T2: the stripe cache's check finds mismatch_cnt $mm after the row sync"
	mk_pattern "$RK_TMP/pat" "$PATMB"; put "$RK_TMP/pat" 0 1M
	same "$RK_TMP/pat" 0 && [ "$(run check 1)" = 0 ] &&
		rk_pass "T2: data written afterwards reads back, row check 0" ||
		rk_fail "T2: data or parity wrong after writes"
else
	rk_fail "T2: setup"
fi
}

# ---- T3: parity corruption at known places ----------------------------------
t3() {
# rows 3, 3, 40, 41 and the last: five blocks, one of them hit in P and in Q
t3_rot() {
	local last=$(( $(chunks) - 1 ))
	stop_array
	rot "$(par_slot 3 0)" 3 0 &&
	rot "$(par_slot 3 1)" 3 0 &&
	rot "$(par_slot 3 0)" 3 17 &&
	rot "$(par_slot 40 1)" 40 31 &&
	rot "$(par_slot 41 0)" 41 5 &&
	rot "$(par_slot "$last" 1)" "$last" 31 &&
	rk_assemble "${MEMBERS[@]:0:$NDEV}"
}
if setup 2r 10 0; then
	mk_pattern "$RK_TMP/pat" "$PATMB"; put "$RK_TMP/pat" 0 1M
	want=$(( 5 * 8 ))
	if t3_rot; then
		a=$(run check 1); b=$(run check 0)
		if [ "$a" = "$want" ] && [ "$b" = "$want" ]; then
			rk_pass "T3: 5 corrupted parity blocks: rows and the stripe cache both report mismatch_cnt $want"
		else
			rk_fail "T3: mismatch_cnt rows $a, stripe cache $b, expected $want"
		fi
		w0=$(row_stat sync_parity_writes)
		a=$(run repair 1)
		w=$(( $(row_stat sync_parity_writes) - w0 ))
		# 4 rows hold the 5 blocks; row 3 has both of its parities hit
		if [ "$a" = "$want" ] && [ "$w" = 5 ]; then
			rk_pass "T3: row repair reports $a and rewrites $w parity chunks"
		else
			rk_fail "T3: row repair reports $a (expected $want), rewrote $w parity chunks (expected 5)"
		fi
		a=$(run check 1); b=$(run check 0)
		[ "$a" = 0 ] && [ "$b" = 0 ] &&
			rk_pass "T3: after the repair both engines find 0" ||
			rk_fail "T3: after the repair: rows $a, stripe cache $b"
		same "$RK_TMP/pat" 0 && rk_pass "T3: data intact" || rk_fail "T3: data changed"
	else
		rk_fail "T3: could not corrupt the members"
	fi
else
	rk_fail "T3: setup"
fi
}

# ---- T4: data corruption at known places ------------------------------------
t4() {
if setup 2r 10 0; then
	mk_pattern "$RK_TMP/pat" "$PATMB"; put "$RK_TMP/pat" 0 1M
	stop_array
	if rot "$(data_slot 7 0)" 7 3 && rot "$(data_slot 7 5)" 7 3 &&
	   rot "$(data_slot 9 7)" 9 30 && rk_assemble "${MEMBERS[@]:0:$NDEV}"; then
		a=$(run check 1); b=$(run check 0)
		if [ "$a" = 16 ] && [ "$b" = 16 ]; then
			rk_pass "T4: 3 corrupted data blocks in 2 stripes: both engines report mismatch_cnt 16"
		else
			rk_fail "T4: mismatch_cnt rows $a, stripe cache $b, expected 16"
		fi
		run repair 1 >/dev/null
		a=$(run check 1); b=$(run check 0)
		[ "$a" = 0 ] && [ "$b" = 0 ] &&
			rk_pass "T4: after a row repair both engines find 0" ||
			rk_fail "T4: after the repair: rows $a, stripe cache $b"
	else
		rk_fail "T4: could not corrupt the members"
	fi
else
	rk_fail "T4: setup"
fi
}

# ---- T5: parity cached in the stripe cache, repaired underneath it ----------
t5() {
# Row 0, blocks 0-7.  Their parity is corrupted on disk (array stopped), then a
# 4 KiB read-modify-write of each (in data chunk 1) reads that wrong parity
# into the cache and leaves it there.  The row repair fixes the disk; a second
# read-modify-write of the same stripes (in data chunk 3) that still used the
# cached parity would write the old error back.
if setup 2r 10 0; then
	mk_pattern "$RK_TMP/pat" 4; put "$RK_TMP/pat" 0 1M
	stop_array
	ok=1
	for b in 0 1 2 3 4 5 6 7; do
		rot "$(par_slot 0 0)" 0 "$b" || ok=0
		rot "$(par_slot 0 1)" 0 "$b" || ok=0
	done
	rk_assemble "${MEMBERS[@]:0:$NDEV}" || ok=0
	if [ "$ok" = 1 ]; then
		knob rk_row_sync 1
		mk_pattern "$RK_TMP/small" 1
		rmw() {	# rmw <data chunk>: one 4 KiB write into each of the 8 stripes
			local b
			for b in 0 1 2 3 4 5 6 7; do
				sudo dd if="$RK_TMP/small" of="$MD" bs=4k count=1 \
					skip=$(( $1 * 8 + b )) \
					seek=$(( $1 * CHUNK_KB / 4 + b )) oflag=direct \
					conv=notrunc status=none 2>/dev/null
			done
		}
		# Keep the stripes cached from the first write to the second: a
		# big cache, and a repair that covers rows 0-1 and is then HELD
		# at sync_max while the second write goes in.  (A pass over the
		# whole array recycles every stripe head on its way, and so does
		# the resync md starts after an interrupted repair.)
		knob stripe_cache_size 4096
		rmw 1
		d0=$(row_stat sync_done); s0=$(row_stat sync_stripe_chunks)
		echo $(( 2 * CHUNK_KB * 2 )) > "$(SYS sync_max)"
		echo repair > "$(SYS sync_action)"
		for i in $(seq 1 40); do
			[ "$(cut -d' ' -f1 "$(SYS sync_completed)")" = $(( 2 * CHUNK_KB * 2 )) ] && break
			sleep 0.25
		done
		a=$(cat "$(SYS mismatch_cnt)")
		d=$(( $(row_stat sync_done) - d0 )); sc=$(( $(row_stat sync_stripe_chunks) - s0 ))
		rmw 3
		echo idle > "$(SYS sync_action)"
		sleep 0.5; rk_wait_idle
		# md resumes an interrupted check or repair where it stopped
		# (sync_min): the oracle below must start at 0 again
		echo 0 > "$(SYS sync_min)"
		echo max > "$(SYS sync_max)"
		b=$(run check 0)
		if [ "$d" != 2 ]; then
			rk_fail "T5: the repair of rows 0-1 did not go through rows ($d rows, $sc stripe chunks): the test proves nothing"
		elif [ "$a" = 64 ] && [ "$b" = 0 ]; then
			rk_pass "T5: parity repaired under the cache (mismatch_cnt $a), and a read-modify-write after it leaves the stripe cache's check at 0"
		else
			rk_fail "T5: repair reported $a (expected 64); after the next read-modify-write the stripe cache's check finds $b (stale cached parity?)"
		fi
	else
		rk_fail "T5: could not corrupt the members"
	fi
else
	rk_fail "T5: setup"
fi
}

# ---- T6: checks under writes ------------------------------------------------
t6() {
if setup 2r 10 0; then
	knob rk_row_sync 1
	knob stripe_cache_size 1024
	asz=$(( $(blockdev --getsize64 "$MD") / 1048576 ))
	fio --name=rnd --filename="$MD" --rw=randwrite --bs=4k --direct=1 \
	    --ioengine=libaio --iodepth=16 --numjobs=1 --size=$(( asz / 2 ))M \
	    --verify=crc32c --verify_backlog=2048 --time_based --runtime=25 \
	    --name=seq --filename="$MD" --rw=write --bs=1M --direct=1 \
	    --ioengine=libaio --iodepth=4 --offset=$(( asz / 2 ))M \
	    --size=$(( asz / 2 ))M --verify=crc32c --verify_backlog=64 \
	    --time_based --runtime=25 \
	    --output="$RK_TMP/fio-t6.out" >/dev/null 2>&1 &
	BGPID=$!
	sleep 1
	d0=$(row_stat sync_done); passes=0; bad=0
	while kill -0 "$BGPID" 2>/dev/null; do
		mm=$(run check 1)
		passes=$((passes + 1))
		[ "$mm" = 0 ] || { bad=$((bad + 1)); rk_log "pass $passes under load: mismatch_cnt $mm"; }
	done
	wait "$BGPID"; frc=$?; BGPID=
	d=$(( $(row_stat sync_done) - d0 ))
	if [ "$bad" = 0 ] && [ "$passes" -ge 3 ] && [ "$d" -gt 0 ]; then
		rk_pass "T6: $passes row checks under random and sequential writes, mismatch_cnt 0 every time ($d rows through the row path, $(row_stat sync_stripe_chunks) chunks to the stripe cache, $(row_stat rebuild_retries) retries)"
	else
		rk_fail "T6: $bad of $passes row checks under writes reported a mismatch (rows done $d)"
	fi
	[ "$frc" = 0 ] && ! grep -q "verify:" "$RK_TMP/fio-t6.out" &&
		rk_pass "T6: fio verify passed" ||
		rk_fail "T6: fio failed (rc $frc): $(grep -m2 -E 'verify|error' "$RK_TMP/fio-t6.out")"
	a=$(run check 1); b=$(run check 0)
	[ "$a" = 0 ] && [ "$b" = 0 ] &&
		rk_pass "T6: afterwards both engines find 0" ||
		rk_fail "T6: afterwards: rows $a, stripe cache $b"
else
	rk_fail "T6: setup"
fi
}

# ---- T7: a repair under writes ----------------------------------------------
t7() {
if setup 2r 10 0; then
	mk_pattern "$RK_TMP/pat" "$PATMB"; put "$RK_TMP/pat" 0 1M
	stop_array
	ok=1; nrot=0
	for r in 5 100 200 300 400; do
		rot "$(par_slot "$r" 0)" "$r" 9 || ok=0
		nrot=$((nrot + 1))
	done
	rk_assemble "${MEMBERS[@]:0:$NDEV}" || ok=0
	if [ "$ok" = 1 ]; then
		knob rk_row_sync 1
		knob stripe_cache_size 1024
		asz=$(( $(blockdev --getsize64 "$MD") / 1048576 ))
		# the corrupted rows are all below member row 512 = array 512 MiB
		fio --name=rnd --filename="$MD" --rw=randwrite --bs=4k --direct=1 \
		    --ioengine=libaio --iodepth=16 --offset=600M \
		    --size=$(( asz - 700 ))M --time_based --runtime=8 \
		    >/dev/null 2>&1 &
		BGPID=$!
		sleep 1
		a=$(run repair 1)
		# fio runs 8 s, the repair a fraction of that here: one still
		# running when fio ended ran, at least in part, without the writes
		kill -0 "$BGPID" 2>/dev/null && under=1 || under=0
		wait "$BGPID"; BGPID=
		[ "$under" = 1 ] ||
			rk_skip_check "T7: the repair outlasted the writes: part of it ran without them"
		b=$(run check 0)
		if [ "$a" = $(( nrot * 8 )) ] && [ "$b" = 0 ]; then
			rk_pass "T7: row repair under writes fixed $nrot blocks (mismatch_cnt $a); the stripe cache's check finds 0"
		else
			rk_fail "T7: row repair under writes reported $a (expected $(( nrot * 8 ))); the stripe cache's check then finds $b"
		fi
		same "$RK_TMP/pat" 0 && rk_pass "T7: data intact" || rk_fail "T7: data changed"
	else
		rk_fail "T7: could not corrupt the members"
	fi
else
	rk_fail "T7: setup"
fi
}

# ---- T8: an internal bitmap -------------------------------------------------
t8() {
bitmap_dirty() {	# dirty bits according to the first member's bitmap
	sudo "$MDADM" -X "${MEMBERS[0]}" 2>/dev/null |
		sed -n 's/.*Bitmap : [0-9]* bits (chunks), \([0-9]*\) dirty.*/\1/p'
}
# The bitmap daemon writes cleared bits out lazily (three of its 5 s periods
# on the stripe path too): wait for them, and echo what is left.
bitmap_settle() {
	local i dirty=
	for i in $(seq 1 45); do
		dirty=$(bitmap_dirty)
		[ "$dirty" = 0 ] && break
		sleep 1
	done
	echo "${dirty:-?}"
}
RK_CREATE_EXTRA="--bitmap=internal --bitmap-chunk=4M"
randomize 10
if setup 2r 10 1; then
	nch=$(chunks)
	d=$(row_stat sync_done)
	dirty=$(bitmap_settle)
	if [ "$d" = "$nch" ] && [ "$dirty" = 0 ]; then
		rk_pass "T8: initial resync through rows with a bitmap: sync_done $d = $nch chunks, 0 dirty bits afterwards"
	else
		rk_fail "T8: initial resync with a bitmap: sync_done $d of $nch, dirty bits '${dirty:-?}' (expected 0)"
	fi
	[ "$(run check 0)" = 0 ] && rk_pass "T8: the stripe cache's check finds 0" ||
		rk_fail "T8: the stripe cache's check finds a mismatch after the row resync"
	# a resync over the clean bitmap: every region is skipped
	d0=$(row_stat sync_done)
	knob rk_row_sync 1
	echo frozen > "$(SYS sync_action)"
	echo 0 > "$(SYS resync_start)" 2>/dev/null
	rs=$(cat "$(SYS resync_start)")
	echo idle > "$(SYS sync_action)"
	sleep 1; rk_wait_idle
	d=$(( $(row_stat sync_done) - d0 ))
	if [ "$rs" != 0 ]; then
		rk_skip_check "T8: this kernel does not let resync_start be reset on a running array"
	elif [ "$d" -le 64 ] && [ "$(cat "$(SYS resync_start)")" = none ]; then
		rk_pass "T8: a resync over a clean bitmap skips the array ($d chunks read)"
	else
		rk_fail "T8: a resync over a clean bitmap read $d chunks, resync_start $(cat "$(SYS resync_start)")"
	fi
	mm=$(run check 1); dirty=$(bitmap_settle)
	[ "$mm" = 0 ] && [ "$dirty" = 0 ] &&
		rk_pass "T8: row check with a bitmap: mismatch_cnt 0, 0 dirty bits" ||
		rk_fail "T8: row check with a bitmap: mismatch_cnt $mm, dirty bits '${dirty:-?}'"
else
	rk_fail "T8: setup"
fi
# A bitmap chunk smaller than the raid chunk: one row then spans several
# bitmap bits, all of which the row path has to report, and md's cursor can
# stop inside a chunk.
RK_CREATE_EXTRA="--bitmap=internal --bitmap-chunk=64K"
randomize 10
if [ "$CHUNK_KB" -le 64 ]; then
	rk_skip_check "T8: a bitmap chunk below the raid chunk needs a raid chunk above 64K"
elif setup 2r 10 1; then
	nch=$(chunks)
	d=$(row_stat sync_done)
	dirty=$(bitmap_settle)
	if [ "$d" = "$nch" ] && [ "$dirty" = 0 ]; then
		rk_pass "T8: with a 64K bitmap chunk under a ${CHUNK_KB}K raid chunk: sync_done $d = $nch chunks, 0 dirty bits afterwards"
	else
		rk_fail "T8: 64K bitmap chunk: sync_done $d of $nch, dirty bits '${dirty:-?}' (expected 0)"
	fi
	[ "$(run check 0)" = 0 ] && rk_pass "T8: 64K bitmap chunk: the stripe cache's check finds 0" ||
		rk_fail "T8: 64K bitmap chunk: the stripe cache's check finds a mismatch after the row resync"
else
	rk_fail "T8: setup with a 64K bitmap chunk"
fi
RK_CREATE_EXTRA="$BASE_EXTRA"
}

# ---- T9: pass control -------------------------------------------------------
t9() {
if setup 2r 10 0; then
	mk_pattern "$RK_TMP/pat" "$PATMB"; put "$RK_TMP/pat" 0 1M
	nch=$(chunks)
	knob rk_row_sync 1
	d0=$(row_stat sync_done); s0=$(row_stat sync_stripe_chunks)
	# md takes a lower sync_max only before the pass starts: the pass runs
	# into it, waits there, and goes on when it is released
	stopat=$(( nch * 6 / 10 * CHUNK_KB * 2 ))
	echo "$stopat" > "$(SYS sync_max)"
	throttle 20000
	echo check > "$(SYS sync_action)"
	sleep 1
	knob rk_row_sync 0; sleep 0.7; knob rk_row_sync 1; sleep 0.5
	knob rk_row_rebuild_window 8; sleep 0.5; knob rk_row_rebuild_window 0; sleep 0.5
	knob rk_row_rebuild_window 64
	smax=no
	for i in $(seq 1 80); do
		[ "$(cut -d' ' -f1 "$(SYS sync_completed)")" = "$stopat" ] && { smax=yes; break; }
		sleep 0.25
	done
	sleep 1		# held there, the window drained
	running || smax=no
	echo max > "$(SYS sync_max)"
	sleep 0.5
	unthrottle
	rk_wait_idle
	mm=$(cat "$(SYS mismatch_cnt)")
	d=$(( $(row_stat sync_done) - d0 )); sc=$(( $(row_stat sync_stripe_chunks) - s0 ))
	# chunks the stripe cache took while the knob was off are in neither
	# counter, so the two only bound the pass from below
	if [ "$mm" = 0 ] && ! running && [ "$smax" = yes ] && [ "$d" -gt 0 ] &&
	   [ $(( d + sc )) -le "$nch" ]; then
		rk_pass "T9: knob off/on, window 8/0/64, held at sync_max and released: pass ended, mismatch_cnt 0 (rows $d + stripe chunks $sc of $nch, unclaimed $(row_stat rebuild_unclaimed))"
	else
		rk_fail "T9: pass control: mismatch_cnt $mm, rows $d, stripe chunks $sc of $nch, held at sync_max: $smax, still running: $(running && echo yes || echo no)"
	fi
	# frozen, resumed as a new pass, then interrupted and run to the end
	throttle 30000
	echo check > "$(SYS sync_action)"; sleep 1
	echo frozen > "$(SYS sync_action)"; sleep 0.5
	fr=$(running && echo yes || echo no)
	echo idle > "$(SYS sync_action)"
	echo 0 > "$(SYS sync_min)"
	echo check > "$(SYS sync_action)"; sleep 1
	echo idle > "$(SYS sync_action)"; sleep 0.5
	it=$(running && echo yes || echo no)
	unthrottle
	# an interrupted pass leaves sync_min where it stopped
	echo 0 > "$(SYS sync_min)"
	d0=$(row_stat sync_done)
	mm=$(run check 1)
	[ $(( $(row_stat sync_done) - d0 )) = "$nch" ] || mm="$mm (and the pass was not a full one)"
	if [ "$fr" = no ] && [ "$it" = no ] && [ "$mm" = 0 ]; then
		rk_pass "T9: frozen and interrupted passes stop; the next full pass finds 0"
	else
		rk_fail "T9: after frozen (running: $fr) / idle (running: $it): mismatch_cnt $mm"
	fi
	same "$RK_TMP/pat" 0 && rk_pass "T9: data intact" || rk_fail "T9: data changed"
else
	rk_fail "T9: setup"
fi
}

# ---- T10: a member fails under a row check ----------------------------------
t10() {
if setup 2r 10 0; then
	mk_pattern "$RK_TMP/pat" "$PATMB"; put "$RK_TMP/pat" 0 1M
	knob rk_row_sync 1
	throttle 30000
	echo check > "$(SYS sync_action)"; sleep 1
	sudo "$MDADM" --fail "$MD" "${MEMBERS[3]}" >/dev/null 2>&1
	sleep 1
	unthrottle
	for i in $(seq 1 120); do running || break; sleep 0.5; done
	deg=$(cat "$(SYS degraded)")
	if ! running && [ "$deg" = 1 ] && same "$RK_TMP/pat" 0; then
		rk_pass "T10: a member failed under a row check: the pass ended, degraded $deg, data reads back"
	else
		rk_fail "T10: member failure under a row check: running $(running && echo yes || echo no), degraded $deg, or data wrong"
	fi
else
	rk_fail "T10: setup"
fi
}

# ---- T11: other geometries --------------------------------------------------
t11() {
geom() {	# geom <label> <layout> <ndisks> <chunk KiB>
	local label=$1 a b c d sc nch want
	CHUNK_KB=$4
	randomize "$3"
	if ! setup "$2" "$3" 1; then
		rk_fail "T11 $label: setup"; CHUNK_KB=$CHUNK0; return
	fi
	nch=$(chunks)
	d=$(row_stat sync_done); sc=$(row_stat sync_stripe_chunks)
	a=$(run check 0)
	if [ "$d" = "$nch" ] && [ "$sc" = 0 ] && [ "$a" = 0 ]; then
		rk_pass "T11 $label: initial sync through rows ($d chunks), clean to the stripe cache"
	else
		rk_fail "T11 $label: initial sync: sync_done $d of $nch, stripe chunks $sc, the stripe cache's check finds $a"
	fi
	mk_pattern "$RK_TMP/pat" 32; put "$RK_TMP/pat" 0 1M
	stop_array
	rot "$(par_slot 2 0)" 2 1
	rot "$(par_slot 11 $(( $(rk_m_of "$2") - 1 )))" 11 6
	rot "$(data_slot 20 1)" 20 0
	rk_assemble "${MEMBERS[@]:0:$NDEV}"
	a=$(run check 1); b=$(run check 0)
	c=$(run repair 1); d=$(run check 0)
	want=24
	if [ "$a" = "$want" ] && [ "$b" = "$want" ] && [ "$c" = "$want" ] && [ "$d" = 0 ]; then
		rk_pass "T11 $label: 3 corrupted blocks: both engines report $want, and a row repair is clean to the stripe cache"
	else
		rk_fail "T11 $label: check rows $a, stripe cache $b, row repair $c (expected $want each); stripe cache after the repair $d"
	fi
	CHUNK_KB=$CHUNK0
}
geom "4+2 rotating"	2r 6 "$CHUNK_KB"
geom "8+3 rotating"	3r 11 "$CHUNK_KB"
geom "8+4 rotating"	4r 12 "$CHUNK_KB"
geom "8+2 parity-last"	2  10 "$CHUNK_KB"
geom "8+2 64K chunk"	2r 10 64
}

# ---- T12: native checksum ---------------------------------------------------
t12() {
csum_warns() { sudo dmesg | grep -c "native csum mismatch"; }
RK_CREATE_EXTRA="--checksum"
CHUNK_KB=$CHUNK0
if setup 2r 6 1; then
	nch=$(chunks)
	d=$(row_stat sync_done)
	mk_pattern "$RK_TMP/pat" 32; put "$RK_TMP/pat" 0 1M
	w0=$(csum_warns)
	dropc
	sudo dd if="$MD" of=/dev/null bs=1M iflag=direct status=none 2>/dev/null
	rdrc=$?
	if [ "$d" = "$nch" ] && [ "$rdrc" = 0 ] && [ "$(csum_warns)" = "$w0" ] &&
	   same "$RK_TMP/pat" 0; then
		rk_pass "T12: initial resync through rows on a --checksum array ($d chunks); a full read raises no csum mismatch and returns the data"
	else
		rk_fail "T12: --checksum initial resync: sync_done $d of $nch, read rc $rdrc, csum warnings $(( $(csum_warns) - w0 ))"
	fi
	a=$(run check 1); b=$(run check 0)
	[ "$a" = 0 ] && [ "$b" = 0 ] && rk_pass "T12: both engines' checks find 0" ||
		rk_fail "T12: checks: rows $a, stripe cache $b"
	# rot one data block: the CRCs were flushed by the clean stop, so the
	# row check must notice, stand aside, and the stripe cache heal it
	stop_array
	rot "$(data_slot 4 1)" 4 2
	rk_assemble "${MEMBERS[@]:0:$NDEV}"
	c0=$(row_stat sync_csum_bad)
	run check 1 >/dev/null
	c=$(( $(row_stat sync_csum_bad) - c0 ))
	if [ "$c" -ge 1 ] && same "$RK_TMP/pat" 0 && [ "$(run check 0)" = 0 ]; then
		rk_pass "T12: a rotted block under a row check: the row went to the stripe cache (sync_csum_bad $c), the data reads back and a check is clean"
	else
		rk_fail "T12: rotted block: sync_csum_bad moved $c, or the data / a later check is wrong"
	fi
	# Parity that is wrong on disk, met by an AUTOMATIC resync: that pass
	# re-derives the CRCs instead of checking them, so the row path has to
	# publish the CRC of the parity it writes, not of the parity it read.
	# A check afterwards verifies every chunk of every row against them.
	stop_array
	rot "$(par_slot 6 0)" 6 3; rot "$(par_slot 6 1)" 6 3; rot "$(par_slot 9 0)" 9 0
	rk_assemble "${MEMBERS[@]:0:$NDEV}"
	knob rk_row_sync 1
	w0=$(row_stat sync_parity_writes); d0=$(row_stat sync_done)
	echo frozen > "$(SYS sync_action)"
	echo 0 > "$(SYS resync_start)" 2>/dev/null
	rs=$(cat "$(SYS resync_start)")
	echo idle > "$(SYS sync_action)"
	for i in $(seq 1 100); do
		[ "$(cat "$(SYS sync_action)")" != idle ] && break
		sleep 0.05
	done
	rk_wait_idle
	if [ "$rs" != 0 ]; then
		rk_skip_check "T12: this kernel does not let resync_start be reset on a running array"
	else
		w=$(( $(row_stat sync_parity_writes) - w0 )); d=$(( $(row_stat sync_done) - d0 ))
		a=$(cat "$(SYS mismatch_cnt)")
		c0=$(row_stat sync_csum_bad); w0=$(csum_warns)
		b=$(run check 1); c=$(( $(row_stat sync_csum_bad) - c0 ))
		e=$(run check 0)
		if [ "$d" = "$nch" ] && [ "$w" = 3 ] && [ "$a" = 16 ] && [ "$b" = 0 ] &&
		   [ "$c" = 0 ] && [ "$e" = 0 ] && [ "$(csum_warns)" = "$w0" ] &&
		   same "$RK_TMP/pat" 0; then
			rk_pass "T12: an automatic resync through rows over wrong parity on a --checksum array: 3 parity chunks rewritten (mismatch_cnt $a), and both checks then agree with the stored CRCs (no row refused, no csum mismatch)"
		else
			rk_fail "T12: resync over wrong parity with checksum: rows $d of $nch, parity writes $w (expected 3), mismatch_cnt $a (expected 16); row check $b with $c rows refused; stripe check $e; csum warnings $(( $(csum_warns) - w0 ))"
		fi
	fi
else
	rk_fail "T12: setup"
fi
RK_CREATE_EXTRA="$BASE_EXTRA"
}

# ---- T13: checks under writes, with the members' timing pulled apart --------
# A ramdisk copies the data when a request is submitted, so a row read and a
# write to the same row can hardly interleave on it, and T6 would pass even if
# the row were not held (tried: it does).  Here every member sits behind
# dm-delay: reads wait 3 ms, writes 0, 2, 4 or 6 ms by member.  A row write
# then lands on some members before a row read is served and on others after,
# so a check that read a row it did not hold reports mismatches (tried, with
# the hold removed: 6 of 13 passes did).
t13() {
local i sz saved=("${MEMBERS[@]}") dly=() frc mm passes=0 bad=0 d0 d a b asz
modprobe dm-delay 2>/dev/null
if ! dmsetup targets 2>/dev/null | grep -q '^delay'; then
	rk_skip_check "T13: no dm-delay target on this kernel"
	return
fi
rk_stop
# The delay devices show whatever superblock their member carries, and udev
# would assemble the previous test's array from them: wipe those first.
for i in 0 1 2 3 4 5 6 7 8 9; do
	"$MDADM" --zero-superblock "${saved[$i]}" 2>/dev/null
	dd if=/dev/zero of="${saved[$i]}" bs=1M count=4 status=none 2>/dev/null
done
rk_udev_quiesce
for i in 0 1 2 3 4 5 6 7 8 9; do
	sz=$(blockdev --getsz "${saved[$i]}")
	dmsetup remove "rksync$i" 2>/dev/null
	echo "0 $sz delay ${saved[$i]} 0 3 ${saved[$i]} 0 $(( (i % 4) * 2 ))" |
		dmsetup create "rksync$i" || { rk_fail "T13: dm-delay setup"; break; }
	dly+=("/dev/mapper/rksync$i")
done
if [ "${#dly[@]}" = 10 ]; then
	udevadm settle 2>/dev/null
	MEMBERS=("${dly[@]}")
	if setup 2r 10 1; then
		knob stripe_cache_size 1024
		asz=$(( $(blockdev --getsize64 "$MD") / 1048576 ))
		fio --name=seq --filename="$MD" --rw=write --bs=1M --direct=1 \
		    --ioengine=libaio --iodepth=4 --size=$(( asz / 2 ))M \
		    --verify=crc32c --verify_backlog=64 --time_based --runtime=25 \
		    --name=rnd --filename="$MD" --rw=randwrite --bs=4k --direct=1 \
		    --ioengine=libaio --iodepth=16 --offset=$(( asz / 2 ))M \
		    --size=$(( asz / 2 ))M --verify=crc32c --verify_backlog=2048 \
		    --time_based --runtime=25 \
		    --output="$RK_TMP/fio-t13.out" >/dev/null 2>&1 &
		BGPID=$!
		sleep 1
		d0=$(row_stat sync_done)
		while kill -0 "$BGPID" 2>/dev/null; do
			mm=$(run check 1)
			passes=$((passes + 1))
			[ "$mm" = 0 ] || { bad=$((bad + 1)); rk_log "pass $passes under load: mismatch_cnt $mm"; }
		done
		wait "$BGPID"; frc=$?; BGPID=
		d=$(( $(row_stat sync_done) - d0 ))
		if [ "$bad" = 0 ] && [ "$passes" -ge 3 ] && [ "$d" -gt 0 ]; then
			rk_pass "T13: $passes row checks under writes on members with skewed delays, mismatch_cnt 0 every time ($d rows through the row path, $(row_stat sync_stripe_chunks) chunks to the stripe cache, $(row_stat rebuild_retries) retries)"
		else
			rk_fail "T13: $bad of $passes row checks under writes on skewed members reported a mismatch (rows done $d)"
		fi
		[ "$frc" = 0 ] && ! grep -q "verify:" "$RK_TMP/fio-t13.out" &&
			rk_pass "T13: fio verify passed" ||
			rk_fail "T13: fio failed (rc $frc): $(grep -m2 -E 'verify|error' "$RK_TMP/fio-t13.out")"
		a=$(run check 1); b=$(run check 0)
		[ "$a" = 0 ] && [ "$b" = 0 ] &&
			rk_pass "T13: afterwards both engines find 0" ||
			rk_fail "T13: afterwards: rows $a, stripe cache $b"
	else
		rk_fail "T13: setup"
	fi
fi
rk_stop
for i in "${dly[@]}"; do
	"$MDADM" --zero-superblock "$i" 2>/dev/null
	dmsetup remove "$(basename "$i")" 2>/dev/null
done
MEMBERS=("${saved[@]}")
rk_udev_quiesce
}

# RS_ONLY="T5 T8" runs just those (the negative controls use it)
for t in T1 T2 T3 T4 T5 T6 T7 T8 T9 T10 T11 T12 T13; do
	case " ${RS_ONLY:-$t} " in *" $t "*) ;; *) continue ;; esac
	"${t,,}"
done

n=$(splats)
[ "$n" = 0 ] && rk_pass "no kernel WARN/BUG/hung-task report" ||
	rk_fail "$n kernel report(s): $(sudo dmesg | grep -m3 -E "$RK_SPLAT")"

rk_summary
