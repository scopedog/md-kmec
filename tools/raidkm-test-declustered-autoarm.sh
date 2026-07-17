#!/bin/bash
#
# raidkm-test-declustered-autoarm.sh — rk_dcl_auto: population arms itself
# from the error handler when a member fails (no sysfs arming step).
#
# On the pinned N=14 pool (2 groups of g=6 = 4+2, s=2, seed 0x10):
#   1. create + baseline (fio verify region + pattern chunks);
#   2. rk_dcl_auto defaults to 0 and rejects junk;
#   3. auto=0: failing a member does NOT arm (state stays none); the
#      classic re-add rebuild leg restores the array;
#   4. auto=1: a bare `mdadm --fail` (member still attached, Faulty) arms
#      population via raid5d and it completes; content + scrub clean;
#   5. --add of a wiped replacement retires the assignment, stock recovery
#      rebuilds it (degraded=0), content intact;
#   6. 3b rescan legs (needs s >= 2): a burst double-failure ends with BOTH
#      members auto-populated regardless of park-slot interleaving (the
#      raid5d rescan re-derives the want from array state), and adding a
#      replacement for only ONE of two populated victims — which retires
#      ALL assignments — automatically RE-populates the still-missing one.
#      No kernel WARN/BUG anywhere.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}
SEED=${DCL_SEED:-0x10}
FIO_OFF=$((128 * 1024 * 1024))
FIO_SZ=$((64 * 1024 * 1024))
MEMBERS=()

auto_file() { echo "/sys/block/$MDNAME/md/rk_dcl_auto"; }
pop_show()  { cat "/sys/block/$MDNAME/md/rk_dcl_populate" 2>/dev/null; }

cleanup() {
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	local d
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
}
trap cleanup EXIT

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
rk_setup_brd "$N" || exit 1
DISKS=$(rk_pick_disks "$N") || { echo "ERROR: need $N devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

mkpat() {	# mkpat <tag3> <lc>
	yes "$1$(printf '%04d' "$2")" | head -c $((CHUNK_KB * 1024)) | \
		sudo tee "$RK_TMP/$1$2" > /dev/null
}
wrchunk() { sudo dd if="$1" of="$MD" bs="${CHUNK_KB}k" seek="$2" count=1 \
		oflag=direct conv=notrunc,fsync status=none; }
rdchunk() { sudo dd if="$MD" of="$2" bs="${CHUNK_KB}k" skip="$1" count=1 \
		iflag=direct status=none; }

# ---- 1. create + baseline -----------------------------------------------------
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M status=none 2>/dev/null || true
done
rk_dmesg_clear
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" \
	--raid-devices=$N "${MEMBERS[@]}" --run --force > /dev/null 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat ||
	{ rk_fail "create/activate failed"; rk_summary; exit 1; }
rk_wait_idle
mm=$(cat /sys/block/$MDNAME/md/mismatch_cnt 2>/dev/null || echo -1)
[ "$mm" = 0 ] && rk_pass "created; initial resync clean" \
	      || rk_fail "initial resync mismatch_cnt=$mm"
sudo fio --name=base --filename="$MD" --direct=1 --bs=64k --rw=write \
	--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=8 \
	--verify=crc32c --do_verify=1 --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/aa-fio-base.log" > /dev/null 2>&1 \
	|| { rk_fail "baseline fio failed"; rk_summary; exit 1; }
LCS=(0 7 23)
for lc in "${LCS[@]}"; do mkpat AAR "$lc"; wrchunk "$RK_TMP/AAR$lc" "$lc"; done
sync
rk_pass "baseline data laid down (fio + ${#LCS[@]} pattern chunks)"

# ---- 2. default off + input validation -----------------------------------------
def=$(cat "$(auto_file)" 2>/dev/null)
[ "$def" = 0 ] && rk_pass "rk_dcl_auto defaults to 0" \
	       || rk_fail "rk_dcl_auto default is '$def' (want 0)"
bad=0
for v in 2 junk -1; do
	echo "$v" | sudo tee "$(auto_file)" > /dev/null 2>&1 && bad=1
done
[ "$bad" = 0 ] && [ "$(cat "$(auto_file)")" = 0 ] \
	&& rk_pass "junk values refused (still 0)" \
	|| rk_fail "junk value accepted by rk_dcl_auto"

# ---- 3. auto=0: failure does NOT arm --------------------------------------------
F1=1
rk_fail_disks "${MEMBERS[$F1]}"
sleep 3
if pop_show | grep -q "^none"; then
	rk_pass "auto=0: failed member did not arm population"
else
	rk_fail "auto=0 but population armed: $(pop_show)"
fi
sudo "$MDADM" --remove "$MD" "${MEMBERS[$F1]}" > /dev/null 2>&1
sudo "$MDADM" --zero-superblock "${MEMBERS[$F1]}" 2>/dev/null
rk_add_disks "${MEMBERS[$F1]}"
rk_wait_full
deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
[ "$deg" = 0 ] && rk_pass "auto=0 leg: classic re-add rebuild (degraded=0)" \
	       || rk_fail "re-add rebuild failed (degraded=$deg)"

# ---- 4. auto=1: bare --fail arms and populates ----------------------------------
echo 1 | sudo tee "$(auto_file)" > /dev/null
[ "$(cat "$(auto_file)")" = 1 ] && rk_pass "rk_dcl_auto=1 accepted" \
			        || rk_fail "cannot set rk_dcl_auto=1"
F2=4
rk_fail_disks "${MEMBERS[$F2]}"		# member stays attached, Faulty
ok=0
for i in $(seq 1 120); do
	pop_show | grep -q "^populated" && { ok=1; break; }
	sleep 1
done
if [ $ok = 1 ] && sudo dmesg | grep -q "population ARMED: disk $F2"; then
	rk_pass "bare --fail auto-armed and population completed ($(pop_show))"
else
	rk_fail "auto-arm did not complete: $(pop_show)"; rk_summary; exit 1
fi
ok=1
for lc in "${LCS[@]}"; do
	rdchunk "$lc" "$RK_TMP/ar$lc"
	cmp -s "$RK_TMP/AAR$lc" "$RK_TMP/ar$lc" || { ok=0; break; }
done
sudo fio --name=basev --filename="$MD" --direct=1 --bs=64k --rw=read \
	--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=8 \
	--verify=crc32c --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/aa-fio-verify.log" > /dev/null 2>&1 || ok=0
[ $ok = 1 ] && rk_pass "content reads back while POPULATED (chunks + fio verify)" \
	    || rk_fail "POPULATED read mismatch"
mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "POPULATED scrub clean (mismatch_cnt=0)" \
	      || rk_fail "POPULATED scrub mismatch_cnt=$mm"

# ---- 5. replacement retires the assignment --------------------------------------
sudo "$MDADM" --remove "$MD" "${MEMBERS[$F2]}" > /dev/null 2>&1
sudo "$MDADM" --zero-superblock "${MEMBERS[$F2]}" 2>/dev/null
sudo dd if=/dev/zero of="${MEMBERS[$F2]}" bs=1M status=none 2>/dev/null || true
rk_add_disks "${MEMBERS[$F2]}"
rk_wait_full
deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
if [ "$deg" = 0 ] && sudo dmesg | grep -q "spare assignment(s) retired" \
   && pop_show | grep -q "^none"; then
	rk_pass "replacement retired the assignment + rebuilt (degraded=0)"
else
	rk_fail "rebalance after auto-populate failed (degraded=$deg, $(pop_show))"
fi
ok=1
for lc in "${LCS[@]}"; do
	rdchunk "$lc" "$RK_TMP/rb$lc"
	cmp -s "$RK_TMP/AAR$lc" "$RK_TMP/rb$lc" || { ok=0; break; }
done
mm=$(rk_scrub)
[ $ok = 1 ] && [ "$mm" = 0 ] \
	&& rk_pass "content intact after rebalance + final scrub clean" \
	|| rk_fail "post-rebalance content/scrub bad (ok=$ok mismatch=$mm)"
# ---- 6. 3b rescan: burst double-failure + retire-one re-arm ---------------------
if [ "$SC" -ge 2 ]; then
	F3=2; F4=7
	rk_fail_disks "${MEMBERS[$F3]}" "${MEMBERS[$F4]}"	# burst: one park slot
	# BOTH must end POPULATED whatever the park/rescan interleaving —
	# that guarantee IS the rescan (the one-shot park alone drops one)
	ok=0
	for i in $(seq 1 240); do
		pop_show | grep -q "^populated $F3 " && \
		pop_show | grep -q "^populated $F4 " && { ok=1; break; }
		sleep 1
	done
	[ $ok = 1 ] && rk_pass "burst double-failure: BOTH auto-populated sequentially" \
		    || { rk_fail "burst leg incomplete: $(pop_show | tr '\n' ';')"; rk_summary; exit 1; }
	# replacement for F3 ONLY: retire-all fires, then the rescan must
	# re-park + re-populate the still-missing F4 with no operator step
	sudo "$MDADM" --remove "$MD" "${MEMBERS[$F3]}" > /dev/null 2>&1
	sudo "$MDADM" --zero-superblock "${MEMBERS[$F3]}" 2>/dev/null
	sudo dd if=/dev/zero of="${MEMBERS[$F3]}" bs=1M status=none 2>/dev/null || true
	rk_add_disks "${MEMBERS[$F3]}"
	rk_wait_full
	ok=0
	for i in $(seq 1 240); do
		pop_show | grep -q "^populated $F4 " && { ok=1; break; }
		sleep 1
	done
	deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
	[ $ok = 1 ] && [ "$deg" = 1 ] \
		&& rk_pass "retire-one: still-missing member re-populated automatically (degraded=1)" \
		|| rk_fail "retire-one re-arm failed (deg=$deg, $(pop_show | tr '\n' ';'))"
	# restore: add F4's replacement, back to clean
	sudo "$MDADM" --remove "$MD" "${MEMBERS[$F4]}" > /dev/null 2>&1
	sudo "$MDADM" --zero-superblock "${MEMBERS[$F4]}" 2>/dev/null
	sudo dd if=/dev/zero of="${MEMBERS[$F4]}" bs=1M status=none 2>/dev/null || true
	rk_add_disks "${MEMBERS[$F4]}"
	rk_wait_full
	mm=$(rk_scrub)
	deg=$(cat /sys/block/$MDNAME/md/degraded 2>/dev/null || echo -1)
	[ "$mm" = 0 ] && [ "$deg" = 0 ] \
		&& rk_pass "restored to clean after rescan legs (degraded=0, scrub clean)" \
		|| rk_fail "post-rescan restore bad (deg=$deg mismatch=$mm)"
fi

rk_dmesg_clean && rk_pass "no kernel WARN/BUG during the run" \
	       || rk_fail "kernel log had WARN/BUG — check dmesg"

rk_summary
