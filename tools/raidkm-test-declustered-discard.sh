#!/bin/bash
#
# raidkm-test-declustered-discard.sh -- discards on a declustered array.
#
# A declustered row is one chunk of every pool member, with ngroups groups of
# k data + m parity columns in it and s spare columns.  A discard of whole
# rows is attached to every group's stripe of each row and goes down through
# the write map, so a column a rebuild redirected into a spare is trimmed on
# the spare; with the row map the rows go U.  Members get the discard only
# with devices_handle_discard_safely, and not while a population or copy-back
# is moving the spare redirects.
#
#   T1  the array takes discards (limits), the row map says member_discard
#   T2  discard of rows in the middle: they go U, the members trim (their
#       discard counters move), every other byte reads back
#   T3  4K and whole-row writes into the discarded rows read back
#   T4  a member fails, population runs (throttled): a discard meanwhile
#       makes rows U but trims no member
#   T5  population done (POPULATED: a column lives on the spares): discard
#       goes down again, every other byte still reads back
#   T6  ext4: mkfs (discards the array), files, rm, fstrim, e2fsck clean
#   T7  (DCL_CSUM=1, --checksum) no native csum mismatch the whole run
#
# Members: loop devices on a private tmpfs (they take discards).
#   sudo RAIDKM_KO=.../raidkm.ko ISAL_KO=.../isal_lib.ko MDADM=.../mdadm \
#        [DCL_CSUM=1] bash tools/raidkm-test-declustered-discard.sh
set -u

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}
MEMSZ=${DCL_MEMSZ:-96}				# MiB per member
CHUNK_KB=${CHUNK_KB:-64}
RK_RELOAD=${RK_RELOAD:-1}
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"
CSUM_OPT=; [ "${DCL_CSUM:-0}" = 1 ] && CSUM_OPT=--checksum
NG=$(( (N - SC) / G )); K=$(( G - M ))
ROW=$(( NG * K * CHUNK_KB * 1024 ))		# array bytes per row
MEM=$RK_TMP/dcl-discard-mem
SRC=/var/tmp/raidkm-dcl-discard.src		# the array's content, on disk
LOOPS=()
MEMBERS=()

cleanup() {
	sudo "$MDADM" --stop "$MD" >/dev/null 2>&1
	local l
	for l in "${LOOPS[@]:-}"; do [ -n "$l" ] && sudo losetup -d "$l" 2>/dev/null; done
	# loop detach is asynchronous: wait for it rather than leave the tmpfs behind
	for l in $(seq 50); do mountpoint -q "$MEM" || break; sudo umount "$MEM" 2>/dev/null; sleep 0.2; done
	mountpoint -q "$MEM" && sudo umount -l "$MEM"
	rm -f "$SRC"
	echo N | sudo tee /sys/module/raidkm/parameters/devices_handle_discard_safely >/dev/null 2>&1
}
trap cleanup EXIT
# raidkm-test-ci.sh ends a suite past its limit with SIGTERM, which skips an
# EXIT trap unless it is turned into an exit
trap 'exit 130' INT
trap 'exit 143' TERM

command -v fio >/dev/null || rk_skip "fio is not installed"
rk_load_modules || exit 1
echo Y | sudo tee /sys/module/raidkm/parameters/devices_handle_discard_safely >/dev/null
sudo mkdir -p "$MEM"
mountpoint -q "$MEM" && { echo "$MEM is still mounted (an earlier run?)"; exit 1; }
sudo mount -t tmpfs -o size=$(( N * MEMSZ + 64 ))m tmpfs "$MEM" || rk_skip "no tmpfs"
for i in $(seq 0 $((N - 1))); do
	sudo truncate -s ${MEMSZ}M "$MEM/m$i"
	LOOPS+=("$(sudo losetup -f --show "$MEM/m$i")")
done
MEMBERS=("${LOOPS[@]}")

rk_dmesg_clear
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--chunk="$CHUNK_KB" --row-map $CSUM_OPT --bitmap=none \
	--raid-devices=$N "${MEMBERS[@]}" --run --force >"$RK_TMP/dcl-discard-create.log" 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat ||
	{ rk_fail "create failed: $(tail -1 "$RK_TMP/dcl-discard-create.log")"; rk_summary; exit 1; }
rk_wait_idle
SYS=/sys/block/$MDNAME/md
rm_get() { awk -v k="$1" '$1 == k {print $2}' $SYS/rk_rowmap; }
# discard I/Os the members completed (field 12 of /sys/block/X/stat)
mdisc() { local l s=0; for l in "${LOOPS[@]}"; do
	s=$(( s + $(awk '{print $12}' /sys/block/$(basename $l)/stat) )); done; echo $s; }
SIZE=$(sudo blockdev --getsize64 "$MD"); ROWS=$(( SIZE / ROW ))
# compare the array with SRC, except rows [first, first + n)
same_but() {	# same_but <label> <first row> <rows>
	local a=$2 b=$(( $2 + $3 ))
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
	if cmp -s <(sudo dd if="$MD" bs=$ROW count=$a iflag=direct status=none) \
		  <(dd if="$SRC" bs=$ROW count=$a status=none) &&
	   cmp -s <(sudo dd if="$MD" bs=$ROW skip=$b iflag=direct status=none) \
		  <(dd if="$SRC" bs=$ROW skip=$b status=none); then
		rk_pass "$1: every byte outside the discarded rows reads back"
	else
		rk_fail "$1: data outside the discarded rows changed"
	fi
}
echo "    $N members, $NG group(s) of $K+$M, $SC spare column(s); $ROWS rows of $(( ROW / 1024 )) KiB"

# ---- T1 -----------------------------------------------------------------------
dmax=$(cat /sys/block/$MDNAME/queue/discard_max_bytes)
[ "$dmax" -gt 0 ] && [ "$(rm_get member_discard)" = 1 ] &&
	rk_pass "T1 the declustered array takes discards (max $dmax bytes), member_discard 1" ||
	rk_fail "T1 discard_max_bytes $dmax, member_discard $(rm_get member_discard)"

# ---- T2 -----------------------------------------------------------------------
dd if=/dev/urandom of="$SRC" bs=$ROW count=$ROWS status=none
sudo dd if="$SRC" of="$MD" bs=$ROW oflag=direct status=none
R=$(( ROWS / 3 )); NR=16			# rows R .. R+NR-1
u0=$(rm_get unwritten); d0=$(mdisc)
sudo blkdiscard -o $(( R * ROW )) -l $(( NR * ROW )) "$MD" || rk_fail "T2 blkdiscard"
[ "$(rm_get unwritten)" = $(( u0 + NR )) ] && rk_pass "T2 $NR discarded rows are U" ||
	rk_fail "T2 unwritten $u0 -> $(rm_get unwritten), expected +$NR"
d1=$(mdisc)
[ "$d1" -gt "$d0" ] && rk_pass "T2 the members trimmed ($((d1 - d0)) discards)" ||
	rk_fail "T2 no member got a discard ($d0 -> $d1)"
same_but T2 $R $NR

# ---- T3 -----------------------------------------------------------------------
P=$(( R * ROW + 3 * CHUNK_KB * 1024 + 8192 ))
dd if=/dev/urandom of="$SRC" bs=4096 seek=$(( P / 4096 )) count=1 conv=notrunc status=none
sudo dd if="$SRC" of="$MD" bs=4096 skip=$(( P / 4096 )) seek=$(( P / 4096 )) count=1 \
	oflag=direct conv=notrunc status=none
W=$(( (R + 2) * ROW ))
dd if=/dev/urandom of="$SRC" bs=$ROW seek=$(( R + 2 )) count=1 conv=notrunc status=none
sudo dd if="$SRC" of="$MD" bs=$ROW skip=$(( R + 2 )) seek=$(( R + 2 )) count=1 \
	oflag=direct conv=notrunc status=none
sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
cmp -s <(sudo dd if="$MD" bs=4096 skip=$(( P / 4096 )) count=1 iflag=direct status=none) \
       <(dd if="$SRC" bs=4096 skip=$(( P / 4096 )) count=1 status=none) &&
cmp -s <(sudo dd if="$MD" bs=$ROW skip=$(( R + 2 )) count=1 iflag=direct status=none) \
       <(dd if="$SRC" bs=$ROW skip=$(( R + 2 )) count=1 status=none) &&
	rk_pass "T3 a 4K and a whole-row write into discarded rows read back" ||
	rk_fail "T3 writes into discarded rows read back wrong"
# from here SRC's discarded rows other than those two hold nothing defined:
# keep them out of the comparisons by refilling them
sudo dd if="$SRC" of="$MD" bs=$ROW skip=$R seek=$R count=$NR oflag=direct conv=notrunc status=none
same_but "T3 refilled" 0 0

# ---- T4 -----------------------------------------------------------------------
F=3; FDEV=${MEMBERS[$F]}
rk_fail_disks "$FDEV"
sudo "$MDADM" --remove "$MD" "$FDEV" >/dev/null 2>&1
rk_throttle 4000
if echo "$F" | sudo tee $SYS/rk_dcl_populate >/dev/null 2>&1; then
	for i in $(seq 1 100); do rk_pop_show | grep -q populating && break; sleep 0.1; done
	u0=$(rm_get unwritten); d0=$(mdisc)
	R2=$(( R + NR + 8 ))
	sudo blkdiscard -o $(( R2 * ROW )) -l $(( NR * ROW )) "$MD"
	pop=$(rk_pop_show | head -1)
	if echo "$pop" | grep -q populating; then
		[ "$(mdisc)" = "$d0" ] && [ "$(rm_get unwritten)" = $(( u0 + NR )) ] &&
			rk_pass "T4 during population: $NR rows U, no member trimmed" ||
			rk_fail "T4 during population: member discards $d0 -> $(mdisc), unwritten $u0 -> $(rm_get unwritten)"
	else
		rk_skip_check "T4 population ended before the discard ($pop)"
	fi
	# those rows: undefined now, refill them (writes go U -> N)
	sudo dd if="$SRC" of="$MD" bs=$ROW skip=$R2 seek=$R2 count=$NR oflag=direct conv=notrunc status=none
	rk_unthrottle
	rk_wait_populated && rk_pass "T4 population complete ($(rk_pop_show | head -1))" ||
		rk_fail "T4 population did not complete: $(rk_pop_show)"
else
	rk_fail "T4 arming population of member $F refused"
fi
same_but "T4 after population" 0 0

# ---- T5 -----------------------------------------------------------------------
R3=$(( R + 2 * NR + 32 ))
u0=$(rm_get unwritten); d0=$(mdisc)
sudo blkdiscard -o $(( R3 * ROW )) -l $(( NR * ROW )) "$MD"
[ "$(mdisc)" -gt "$d0" ] && [ "$(rm_get unwritten)" = $(( u0 + NR )) ] &&
	rk_pass "T5 POPULATED: $NR rows U and trimmed ($(( $(mdisc) - d0 )) discards)" ||
	rk_fail "T5 POPULATED: member discards $d0 -> $(mdisc), unwritten $u0 -> $(rm_get unwritten)"
same_but "T5 with a column on the spares" $R3 $NR

# ---- T6 -----------------------------------------------------------------------
if command -v mkfs.ext4 >/dev/null; then
	MNT=$RK_TMP/dcl-discard-mnt; sudo mkdir -p "$MNT"
	sudo mkfs.ext4 -q -F -E discard "$MD" >/dev/null 2>&1 && sudo mount "$MD" "$MNT" && {
		for i in $(seq 1 8); do sudo dd if=/dev/urandom of="$MNT/f$i" bs=1M count=16 status=none; done
		sync; sudo rm -f "$MNT"/f[1-4]
		t=$(sudo fstrim -v "$MNT" 2>&1)
		sudo umount "$MNT"
		echo "$t" | grep -q "trimmed" && rk_pass "T6 ext4: $t" || rk_fail "T6 fstrim: $t"
		sudo e2fsck -fn "$MD" >/dev/null 2>&1 && rk_pass "T6 e2fsck clean after mkfs, rm, fstrim" ||
			rk_fail "T6 e2fsck not clean"
	} || rk_fail "T6 mkfs.ext4 / mount"
fi

# ---- T7 -----------------------------------------------------------------------
if [ -n "$CSUM_OPT" ]; then
	n=$(sudo dmesg | grep -c "native csum mismatch")
	[ "$n" = 0 ] && rk_pass "T7 no native csum mismatch" || rk_fail "T7 $n native csum mismatch(es)"
fi
rk_dmesg_clean && rk_pass "no WARN/BUG in the kernel log" || rk_fail "kernel log: $(sudo dmesg | grep -iE 'WARN|BUG|call trace' | head -2)"
rk_summary
