#!/bin/bash
#
# raidkm-bench-declustered-rebuild-load.sh — counter-based demo of declustered
# parity's rebuild-load advantages, WITHOUT needing physical device isolation.
#
# It reads each member's per-disk sector counters (/sys/class/block/<d>/stat:
# field 3 = sectors read, field 7 = sectors written) across a rebuild and
# reports where the I/O landed.  Because it COUNTS bytes rather than contending
# for bandwidth, the load-distribution and survivor-read results are EXACT and
# device-count-independent — they run faithfully on a modest box (16 NVMe
# partitioned into a wide pool, or a laptop).  Only the raw-throughput-under-
# load headline would need many physical spindles; this harness measures the
# mechanism that headline follows from.
#
# Device backend: real devices via RK_DEVS, else LOOP devices over sparse files
# (default).  NOT brd — ramdisks do not do block-layer I/O accounting, so their
# /sys/class/block/ram*/stat counters never move; loop devices account normally
# and need no special hardware.
#
# Three measurements (each prints a table + the ratio that matters):
#
#   A. REBUILD-WRITE DISTRIBUTION — classic k+m (dedicated hot spare) vs
#      declustered (distributed spare), same lost data (one failed member).
#      Classic funnels ~ALL rebuild WRITE onto the single replacement disk (the
#      bottleneck that makes wide rebuilds slow); declustered spreads it across
#      the pool.  Metric: max-single-disk write and the max/mean "spread".
#
#   B. SURVIVOR READ LOAD — recovering one failed disk onto a fresh replacement
#      two ways on the SAME declustered geometry: DECODE (reads k survivors per
#      lost chunk) vs COPY-FROM-SPARE (reads the already-populated spare, ~1x).
#      Metric: total survivor read bytes, decode vs copy.  The one-time
#      population cost that copy front-loads is reported separately for honesty.
#
# Works on brd (default) or real devices via RK_DEVS.  Geometry via the DCL_*
# env vars (same as the declustered gates); scale it up on the wide NVMe box:
#
#   # modest box (default): N=14 pool, g=6 groups
#   sudo -E bash tools/raidkm-bench-declustered-rebuild-load.sh
#
#   # wide pool on 16 NVMe partitioned 5-ways (80 "disks", g=13 = 11+2):
#   RK_DEVS="$(echo /dev/nvme{0..15}n1p{1..5})" DCL_N=80 DCL_G=13 DCL_SC=2 \
#     DATA_MIB=4096 sudo -E bash tools/raidkm-bench-declustered-rebuild-load.sh
#
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}
NBASE=${DCL_NBASE:-16}; SEED=${DCL_SEED:-0x10}
DATA_MIB=${DATA_MIB:-256}		# data written to each array before failing
LOOP_DIR="${LOOP_DIR:-/var/tmp/rkbench-loops}"	# backing files for loop devices
LOOP_MB="${LOOP_MB:-1024}"		# per-loop size (sparse; only DATA is written)
POOL=() LOOPS=()
VALS="$RK_TMP/bench-lastvals"

teardown_loops() {
	local d; for d in "${LOOPS[@]:-}"; do [ -n "$d" ] && sudo losetup -d "$d" 2>/dev/null; done
	rm -rf "$LOOP_DIR"
}
cleanup() {
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	local d
	for d in "${POOL[@]:-}"; do [ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null; done
	teardown_loops
}
trap cleanup EXIT

# Provision NEED loop devices over sparse backing files (real bio accounting).
setup_loops() {
	local n="$1" i f ld
	mkdir -p "$LOOP_DIR"
	for ((i=0;i<n;i++)); do
		f="$LOOP_DIR/disk$i.img"
		rm -f "$f"; truncate -s "${LOOP_MB}M" "$f" || return 1
		ld=$(sudo losetup --find --show "$f") || return 1
		LOOPS+=("$ld")
	done
}

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
# need G+1 for the classic rebuild (k+m members + one hot spare); N for dcl
NEED=$(( N > G + 1 ? N : G + 1 ))
if [ -n "${RK_DEVS:-}" ]; then
	read -r -a POOL <<< "$(rk_pick_disks "$NEED")" || { echo "RK_DEVS has < $NEED devices"; exit 1; }
else
	setup_loops "$NEED" || { echo "loop setup failed (need losetup + $((NEED*LOOP_MB/1024))GiB free in ${LOOP_DIR%/*})"; exit 1; }
	POOL=("${LOOPS[@]}")
fi

# --- per-disk counters ---------------------------------------------------------
# Parent whole-disk of a member (partition -> its disk; whole disk -> itself);
# iostats is a per-QUEUE attribute that must be ON for the counters to move
# (brd defaults it OFF — found the hard way in the csum gate).
parent_of() { local p; p=$(lsblk -no pkname "$1" 2>/dev/null | head -1); echo "${p:-$(basename "$1")}"; }
iostat_on()  { local d; for d in "$@"; do echo 1 | sudo tee "/sys/block/$(parent_of "$d")/queue/iostats" >/dev/null 2>&1; done; }
rd_sec() { awk '{print $3}' "/sys/class/block/$(basename "$1")/stat" 2>/dev/null; }
wr_sec() { awk '{print $7}' "/sys/class/block/$(basename "$1")/stat" 2>/dev/null; }

declare -A SNAP_RD SNAP_WR
snap_begin() { local d; for d in "$@"; do SNAP_RD[$d]=$(rd_sec "$d"); SNAP_WR[$d]=$(wr_sec "$d"); done; }
# snap_report <label> <read|write> <dev...> : print a per-disk delta table (MiB)
# for the measured disks and write "<tot_rd> <tot_wr> <max_wr> <max_rd>" (MiB)
# to $VALS for the caller to read back.  Runs in the MAIN shell (sees SNAP_*).
snap_report() {
	local label="$1" which="$2"; shift 2
	local d rc wc tr=0 tw=0 maxw=0 maxr=0 n=0
	printf '\n  %-36s  read MiB   write MiB\n' "$label"
	printf '  %s\n' "------------------------------------  --------  ---------"
	for d in "$@"; do
		rc=$(( ( $(rd_sec "$d") - ${SNAP_RD[$d]:-0} ) / 2048 ))
		wc=$(( ( $(wr_sec "$d") - ${SNAP_WR[$d]:-0} ) / 2048 ))
		tr=$((tr+rc)); tw=$((tw+wc)); n=$((n+1))
		[ "$rc" -gt "$maxr" ] && maxr=$rc
		[ "$wc" -gt "$maxw" ] && maxw=$wc
		printf '  %-36s  %8d  %9d\n' "$(basename "$d")" "$rc" "$wc"
	done
	local meanr=$(( tr / (n>0?n:1) )) meanw=$(( tw / (n>0?n:1) ))
	printf '  %s\n' "------------------------------------  --------  ---------"
	printf '  %-36s  %8d  %9d\n' "TOTAL ($n disks)" "$tr" "$tw"
	printf '  %-36s  %8d  %9d\n' "mean/disk" "$meanr" "$meanw"
	printf '  %-36s  %8d  %9d\n' "max single disk" "$maxr" "$maxw"
	if [ "$which" = write ]; then
		awk -v mx="$maxw" -v mn="$meanw" 'BEGIN{if(mn>0)printf "  write spread (max/mean): %.2fx  (1.0 = perfectly balanced)\n",mx/mn}'
	else
		awk -v mx="$maxr" -v mn="$meanr" 'BEGIN{if(mn>0)printf "  read  spread (max/mean): %.2fx  (1.0 = perfectly balanced)\n",mx/mn}'
	fi
	echo "$tr $tw $maxw $maxr" > "$VALS"
}

fill_and_sync() {	# write DATA_MIB of random data through the array, to disk
	sudo dd if=/dev/urandom of="$MD" bs=1M count="$DATA_MIB" oflag=direct status=none 2>/dev/null
	sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
}
zero_head() { sudo dd if=/dev/zero of="$1" bs=1M count=4 status=none 2>/dev/null; }
create_dcl() {		# create a declustered array over POOL[0..N-1]
	local i; for ((i=0;i<N;i++)); do zero_head "${POOL[$i]}"; done
	sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
		--layout=declustered --group-width=$G --spare-columns=$SC \
		--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
		--raid-devices=$N "${POOL[@]:0:$N}" --run --force >/dev/null 2>&1 &&
	   grep -q "$MDNAME : active raidkm" /proc/mdstat || return 1
	rk_wait_idle		# let the initial resync finish before we fail a member
}

iostat_on "${POOL[@]}"
echo "======================================================================"
echo " raidkm declustered rebuild-load demo"
echo "   pool N=$N  group g=$G (k=$((G-M))+m=$M)  spare-cols=$SC  data=${DATA_MIB}MiB"
echo "   devices: $( [ -n "${RK_DEVS:-}" ] && echo "real ($NEED from RK_DEVS)" || echo "$NEED loop x ${LOOP_MB}MiB sparse ($LOOP_DIR)")"
echo "======================================================================"

# ==== A. rebuild-WRITE distribution: classic vs declustered =====================
echo; echo "== A. rebuild-write distribution (one failed member) =="

# A1 classic k+m + one hot spare.  Measured set = the G-1 survivors + the spare
# (= POOL[1..G]); zero the spare's head BEFORE snapping so its 4 MiB wipe isn't
# counted as rebuild write.
rk_create "${M}" "${POOL[@]:0:$G}" || { echo "classic create failed"; exit 1; }
fill_and_sync
rk_fail_disks "${POOL[0]}"; sudo "$MDADM" --remove "$MD" "${POOL[0]}" >/dev/null 2>&1
zero_head "${POOL[$G]}"
rk_unthrottle
snap_begin "${POOL[@]:1:$G}"
rk_add_disks "${POOL[$G]}"            # add the hot spare -> classic recovery
rk_wait_full
snap_report "classic ${M}-parity: rebuild onto 1 spare" write "${POOL[@]:1:$G}"
read -r cl_tr cl_tw cl_maxw cl_maxr < "$VALS"
sudo "$MDADM" --stop "$MD" 2>/dev/null

# A2 declustered: populate into the distributed spare.
create_dcl || { echo "declustered create failed"; exit 1; }
fill_and_sync
rk_fail_disks "${POOL[0]}"; sudo "$MDADM" --remove "$MD" "${POOL[0]}" >/dev/null 2>&1
rk_unthrottle
snap_begin "${POOL[@]:1:$((N-1))}"
echo 0 | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" >/dev/null 2>&1
rk_wait_populated || echo "  (warning: populate did not report populated)"
snap_report "declustered: populate into distributed spare" write "${POOL[@]:1:$((N-1))}"
read -r dc_tr dc_tw dc_maxw dc_maxr < "$VALS"
sudo "$MDADM" --stop "$MD" 2>/dev/null

echo
awk -v a="$cl_maxw" -v b="$dc_maxw" 'BEGIN{if(b>0)printf "  >>> max single-disk WRITE: classic %d MiB vs declustered %d MiB  =  %.1fx less funnelling\n",a,b,a/b}'

# ==== B. survivor READ load: decode vs copy-from-spare rebalance =================
echo; echo "== B. survivor read load: decode-rebuild vs copy-from-spare (one failed member) =="

# B-decode: fail then --add immediately (no population) -> stock decode rebuild.
create_dcl || { echo "declustered create failed"; exit 1; }
fill_and_sync
rk_fail_disks "${POOL[0]}"; sudo "$MDADM" --remove "$MD" "${POOL[0]}" >/dev/null 2>&1
zero_head "${POOL[0]}"
rk_unthrottle
snap_begin "${POOL[@]:1:$((N-1))}"
rk_add_disks "${POOL[0]}"             # replacement rebuilds by DECODE
rk_wait_full
snap_report "DECODE rebuild: read survivors, decode each lost chunk" read "${POOL[@]:1:$((N-1))}"
read -r de_tr de_tw de_maxw de_maxr < "$VALS"
sudo "$MDADM" --stop "$MD" 2>/dev/null

# B-copy: fail -> POPULATE (one-time) -> --add -> copy-from-spare.
create_dcl || { echo "declustered create failed"; exit 1; }
fill_and_sync
rk_fail_disks "${POOL[0]}"; sudo "$MDADM" --remove "$MD" "${POOL[0]}" >/dev/null 2>&1
rk_unthrottle
snap_begin "${POOL[@]:1:$((N-1))}"    # measure the one-time population cost
echo 0 | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" >/dev/null 2>&1
rk_wait_populated || echo "  (warning: populate did not report populated)"
snap_report "  (one-time) population decode cost" read "${POOL[@]:1:$((N-1))}"
read -r pop_tr pop_tw pop_maxw pop_maxr < "$VALS"
zero_head "${POOL[0]}"
rk_unthrottle
snap_begin "${POOL[@]:1:$((N-1))}"    # reset: measure the COPY step alone
rk_add_disks "${POOL[0]}"             # replacement filled by COPY-FROM-SPARE
rk_wait_full
snap_report "COPY-from-spare rebalance: read the spare copy" read "${POOL[@]:1:$((N-1))}"
read -r co_tr co_tw co_maxw co_maxr < "$VALS"
sudo "$MDADM" --stop "$MD" 2>/dev/null

echo
awk -v d="$de_tr" -v c="$co_tr" -v p="$pop_tr" 'BEGIN{
  if(c>0)printf "  >>> survivor READ at rebalance: decode %d MiB vs copy %d MiB  =  %.1fx less survivor read\n",d,c,d/c
  printf "      (copy front-loads a one-time population decode of %d MiB, paid when the disk first failed)\n",p
}'

echo
echo "======================================================================"
echo " Summary  (pool N=$N g=$G m=$M, ${DATA_MIB}MiB data)"
echo "   A. write funnelling  : classic max-disk ${cl_maxw} MiB  vs  declustered ${dc_maxw} MiB"
echo "   B. survivor read     : decode ${de_tr} MiB  vs  copy ${co_tr} MiB"
echo "   Counters are exact regardless of device count; raw throughput-under-"
echo "   load would additionally need many physical spindles (unshared)."
echo "======================================================================"
