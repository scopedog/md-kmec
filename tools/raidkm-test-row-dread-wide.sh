#!/bin/bash
# raidkm-test-row-dread-wide.sh — a degraded read reads each row ONCE.
#
# The row layer used to split a degraded read per chunk: healthy chunks went
# straight to their member, and the missing chunk's decode read the same
# row's k survivors again — every healthy data chunk of that row was read
# twice.  On 8+2 NVMe that was 1.70x survivor reads and 37% of degraded read
# throughput.  raidkm_row_dread_wide() now reads the row once and serves the
# healthy chunks from the decode's own sources.
#
# ramdisks have no I/O accounting, so the read count itself is measured on
# real drives (raidkm-bench-iosize.sh); this test proves the path is taken
# and that every byte it serves is right:
#   T1  classic 8+2, one member failed: 1M reads are served row-wide
#       (rk_row_stats dread_wide moves) and return the right bytes.
#   T2  unaligned spans: odd block size, odd offset — partial first and last
#       chunks, spans that cross rows.
#   T3  two members failed: spans missing two chunks keep the per-chunk path;
#       the data is still right.
#   T4  reads racing writes to the same rows (identical bytes rewritten, so
#       the expected content never changes): every read pass is right.
#   T5  declustered N=12 g=10 s=2, one member failed: row-wide, right bytes.
#   T6  controls — a checker that can fail: rk_row_dread=0 and a healthy
#       array both leave dread_wide at 0.
#
# Usage: bash <this>   (RW_N/RW_M classic geometry, PATMB pattern size)
set -u
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${RW_N:-10}; M=${RW_M:-2}
DN=12; DG=10; DSC=2
PATMB=${PATMB:-64}
MEMBERS=()

cleanup() {
	[ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	local d
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
}
trap cleanup EXIT

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
rk_setup_brd "$DN" || exit 1
DISKS=$(rk_pick_disks "$DN") || { echo "ERROR: need $DN devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

row_stat() {	# never empty: an empty value would turn [ -gt ] into a green run
	local v
	v=$(sed -n "s/^$1 //p" "/sys/block/$MDNAME/md/rk_row_stats" 2>/dev/null)
	echo "${v:-0}"
}
row_knob() { echo "$2" | sudo tee "/sys/block/$MDNAME/md/$1" >/dev/null 2>&1; }
splats()   { sudo dmesg | grep -cE "WARNING:|BUG:|KASAN:|blocked for more than"; }

mk_pattern() {
	dd if=/dev/urandom of="$RK_TMP/pat" bs=1M count="$PATMB" status=none
	PRE=$(md5sum "$RK_TMP/pat" | cut -d' ' -f1)
}
write_pattern() {
	sudo dd if="$RK_TMP/pat" of="$MD" bs=1M count="$PATMB" oflag=direct status=none
	sync
}
read_md5() {	# read_md5 [bs] — the whole pattern, in blocks of bs
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	sudo dd if="$MD" bs="${1:-1M}" iflag=direct status=none 2>/dev/null |
		head -c $((PATMB * 1048576)) | md5sum | cut -d' ' -f1
}
slice_ok() {	# slice_ok <offset bytes> <length bytes> <bs bytes>: md vs pattern
	local want got
	want=$(tail -c +$(($1 + 1)) "$RK_TMP/pat" | head -c "$2" | md5sum | cut -d' ' -f1)
	echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	got=$(sudo dd if="$MD" bs="$3" skip="$1" iflag=direct,skip_bytes status=none 2>/dev/null |
		head -c "$2" | md5sum | cut -d' ' -f1)
	[ "$want" = "$got" ]
}
create_dcl() {
	rk_stop
	[ -e "$MD" ] && [ ! -b "$MD" ] && sudo rm -f "$MD"
	local d
	for d in "${MEMBERS[@]:0:$DN}"; do
		sudo dd if=/dev/zero of="$d" bs=1M count=4 status=none 2>/dev/null
	done
	printf 'y\n' | sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=2 \
		--layout=declustered --group-width="$DG" --spare-columns="$DSC" \
		--raid-devices="$DN" --chunk="$CHUNK_KB" --bitmap=none --run --force \
		"${MEMBERS[@]:0:$DN}" >/dev/null 2>&1 || return 1
	rk_wait_idle
}

sudo dmesg -C
mk_pattern

# ---- T6a: healthy control ---------------------------------------------------
echo "=== T6a: healthy array — dread_wide stays 0 ==="
rk_create "${M}r" "${MEMBERS[@]:0:$N}" || { rk_fail "create classic ${N}/${M}"; rk_summary; exit 1; }
write_pattern
[ "$(read_md5)" = "$PRE" ] && rk_pass "T6a: healthy read right" || rk_fail "T6a: healthy read wrong"
[ "$(row_stat dread_wide)" = 0 ] && rk_pass "T6a: healthy array never takes the row-wide path" \
	|| rk_fail "T6a: dread_wide $(row_stat dread_wide) on a healthy array"

# ---- T1: classic, one member failed ----------------------------------------
echo "=== T1: classic $((N - M))+$M, one member failed, 1M reads ==="
rk_fail_disks "${MEMBERS[0]}"
row_knob rk_row_dread 1
W0=$(row_stat dread_wide); D0=$(row_stat dread_done)
[ "$(read_md5)" = "$PRE" ] && rk_pass "T1: degraded 1M read right" || rk_fail "T1: degraded 1M read WRONG"
W1=$(row_stat dread_wide); D1=$(row_stat dread_done)
[ "$W1" -gt "$W0" ] && rk_pass "T1: served row-wide (dread_wide $W0 -> $W1, dread_done $D0 -> $D1)" \
	|| rk_fail "T1: row-wide path never ran (dread_wide $W0 -> $W1, dread_done $D0 -> $D1, declined $(row_stat dread_declined))"

# ---- T2: unaligned spans ----------------------------------------------------
echo "=== T2: unaligned spans ==="
[ "$(read_md5 324K)" = "$PRE" ] && rk_pass "T2: 324K blocks right" || rk_fail "T2: 324K blocks WRONG"
slice_ok $((324 * 1024)) $((40 * 1048576)) $((324 * 1024)) \
	&& rk_pass "T2: offset 324K, 40 MiB right" || rk_fail "T2: offset 324K span WRONG"
slice_ok $((CHUNK_KB * 1024 * 3)) $((CHUNK_KB * 1024 * 11)) $((CHUNK_KB * 1024 * 11)) \
	&& rk_pass "T2: an 11-chunk span from chunk 3 (crosses a row) right" \
	|| rk_fail "T2: 11-chunk span WRONG"
sudo dd if="$MD" of=/dev/null bs=4k count=1 skip=3 iflag=direct status=none 2>/dev/null
W2=$(row_stat dread_wide)
[ "$W2" -gt "$W1" ] && rk_pass "T2: unaligned spans also row-wide (dread_wide $W1 -> $W2)" \
	|| rk_fail "T2: unaligned spans never row-wide (dread_wide $W1 -> $W2)"

# ---- T4: reads racing identical rewrites of the same rows ------------------
echo "=== T4: reads racing writes to the same rows ==="
rm -f "$RK_TMP/rw-stop"
( while [ ! -f "$RK_TMP/rw-stop" ]; do
	sudo dd if="$RK_TMP/pat" of="$MD" bs="${CHUNK_KB}k" count=$((16 * 1024 / CHUNK_KB)) \
		oflag=direct status=none 2>/dev/null
  done ) &
WPID=$!
R0=$(row_stat dread_raced); bad=0
for i in $(seq 1 20); do
	slice_ok 0 $((16 * 1048576)) 1048576 || bad=$((bad + 1))
done
touch "$RK_TMP/rw-stop"; wait "$WPID" 2>/dev/null; WPID=""
[ "$bad" = 0 ] && rk_pass "T4: 20 read passes under concurrent rewrites all right (raced $R0 -> $(row_stat dread_raced))" \
	|| rk_fail "T4: $bad of 20 read passes WRONG under concurrent rewrites"
[ "$(read_md5)" = "$PRE" ] && rk_pass "T4: whole pattern right afterwards" || rk_fail "T4: pattern WRONG afterwards"

# ---- T6b: rk_row_dread=0 control -------------------------------------------
echo "=== T6b: rk_row_dread=0 — dread_wide does not move ==="
row_knob rk_row_dread 0
W3=$(row_stat dread_wide)
[ "$(read_md5)" = "$PRE" ] && rk_pass "T6b: stripe-cache degraded read right" || rk_fail "T6b: stripe-cache read WRONG"
[ "$(row_stat dread_wide)" = "$W3" ] && rk_pass "T6b: knob off, row-wide path off" \
	|| rk_fail "T6b: dread_wide moved with rk_row_dread=0 ($W3 -> $(row_stat dread_wide))"
row_knob rk_row_dread 1

# ---- T3: two members failed -------------------------------------------------
echo "=== T3: two members failed ==="
rk_fail_disks "${MEMBERS[3]}"
D3=$(row_stat dread_done)
[ "$(read_md5)" = "$PRE" ] && rk_pass "T3: double-degraded 1M read right" || rk_fail "T3: double-degraded read WRONG"
[ "$(read_md5 324K)" = "$PRE" ] && rk_pass "T3: double-degraded 324K read right" || rk_fail "T3: double-degraded 324K WRONG"
[ "$(row_stat dread_done)" -gt "$D3" ] && rk_pass "T3: row layer still serving (dread_done $D3 -> $(row_stat dread_done), wide $(row_stat dread_wide))" \
	|| rk_fail "T3: row layer idle with two members failed"

# ---- T5: declustered --------------------------------------------------------
echo "=== T5: declustered N=$DN g=$DG s=$DSC, one member failed ==="
if create_dcl; then
	write_pattern
	rk_fail_disks "${MEMBERS[5]}"
	row_knob rk_row_dread 1
	W5=$(row_stat dread_wide)
	[ "$(read_md5)" = "$PRE" ] && rk_pass "T5: declustered degraded 1M read right" || rk_fail "T5: declustered read WRONG"
	[ "$(read_md5 324K)" = "$PRE" ] && rk_pass "T5: declustered 324K read right" || rk_fail "T5: declustered 324K WRONG"
	[ "$(row_stat dread_wide)" -gt "$W5" ] && rk_pass "T5: declustered served row-wide (dread_wide $W5 -> $(row_stat dread_wide))" \
		|| rk_fail "T5: declustered never row-wide (dread_wide $W5 -> $(row_stat dread_wide), declined $(row_stat dread_declined))"
else
	rk_fail "T5: declustered create failed"
fi

[ "$(splats)" = 0 ] && rk_pass "no WARN/BUG/KASAN/hung task" || rk_fail "$(splats) kernel splat line(s)"
rk_summary
