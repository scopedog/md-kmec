#!/bin/bash
#
# raidkm-test-declustered-row-transitions.sh — the row layer across declustered
# spare-assignment transitions.
#
# raidkm_row_read() only runs a degraded read through the row layer while every
# spare assignment is STEADY (NONE or POPULATED): in POPULATING and COPYING the
# redirect resolves per row against conf->reb_mark, which moves while the member
# reads are in flight, so those must stay on the stripe path.  That gate is
# checked on entry AND again after raidkm_row_aligned_get(), because the get
# parks the read for the whole of someone else's quiesce -- and the
# copy-from-spare rebalance flips POPULATED -> COPYING from inside one.
#
# The array has to be DEGRADED for the row path to be reached at all, so the
# interesting state (steady + degraded) needs two members down: one POPULATED
# into the distributed spare, a second simply failed.
#
#   T1  population running (POPULATING, degraded): the row path must stay OFF
#       -- dread_done frozen -- and reads must still be correct.
#   T2  assignment POPULATED + a second member failed (steady, degraded): the
#       row path must be LIVE -- dread_done moves -- and reads correct.
#   T3  the copy-from-spare rebalance armed under a degraded read load: once
#       COPYING is announced the row path must stay OFF, and every read must
#       verify.  (Whether a read can be ADMITTED as steady and then resume
#       into COPYING was probed separately with a debug knob and a counter on
#       that exact condition -- 0 hits in 6 runs.  raid5_quiesce() waits for
#       the active_aligned_reads reference a row read holds, so an in-flight
#       read holds the arm off instead.  See raidkm_row_dcl_steady().)
#   T4  the copy COMPLETES -- decoding the rows whose source is T2's failed
#       member rather than abandoning the copy for a decode rebuild -- and
#       then: data correct, scrub clean, no WARN/BUG.
#   T5  TWO assignments POPULATED at once: reads correct and scrub clean with
#       chained redirects live, AND the accounting property behind it -- a
#       populated assignment restores the data but leaves the slot empty, so
#       mddev->degraded still counts it and s assignments consume the whole
#       m-failure budget.  That is also why the row path cannot be exercised
#       here at m=2: it needs an UNASSIGNED failure, and there is no budget
#       left for one.
#
# Geometry is the pinned N=14 pool the other declustered gates use (2 groups of
# g=6 = 4+2, s=2) so two assignments can coexist.
#
#   sudo bash tools/raidkm-test-declustered-row-transitions.sh
set -u

. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

N=${DCL_N:-14}; G=${DCL_G:-6}; M=${DCL_M:-2}; SC=${DCL_SC:-2}; NBASE=${DCL_NBASE:-16}
SEED=${DCL_SEED:-0x10}
# DCL_CSUM=1 creates the array with native checksums: the copy then verifies
# the survivors it decodes a dead-source row from, and the decode result
# against the CRCs the row was written with
CSUM_OPT=; [ "${DCL_CSUM:-0}" = 1 ] && CSUM_OPT=--checksum
FIO_OFF=${FIO_OFF:-$((64 * 1024 * 1024))}
FIO_SZ=${FIO_SZ:-$((48 * 1024 * 1024))}
VICTIM=${DCL_VICTIM:-3}		# populated into the spare
SECOND=${DCL_SECOND:-9}		# failed only, to keep the array degraded
LOAD_SECS=${LOAD_SECS:-25}
# widens the admit -> quiesce-reference window in the degraded row read so the
# rebalance's quiesce lands inside it; 0 would make T3 a coin flip
MEMBERS=()
LOAD_PID=

cleanup() {
	[ -n "$LOAD_PID" ] && kill "$LOAD_PID" 2>/dev/null
	wait 2>/dev/null
	sudo "$MDADM" --stop "$MD" 2>/dev/null
	local d
	for d in "${MEMBERS[@]:-}"; do
		[ -n "$d" ] && sudo "$MDADM" --zero-superblock "$d" 2>/dev/null
	done
}
trap cleanup EXIT

command -v fio >/dev/null || rk_skip "fio is not installed"

mkdir -p "$RK_TMP"
rk_load_modules || exit 1
rk_setup_brd "$N" || exit 1
DISKS=$(rk_pick_disks "$N") || { echo "ERROR: need $N devices" >&2; exit 1; }
read -r -a MEMBERS <<< "$DISKS"

stat_of() {	# stat_of <field> -> value, or 0 when the attribute is absent
	awk -v f="$1" '$1 == f {print $2; found=1} END {if (!found) print 0}' \
		"/sys/block/$MDNAME/md/rk_row_stats" 2>/dev/null
}
dread_done() { stat_of dread_done; }

# A degraded read load that VERIFIES: fio wrote this region with a crc32c
# pattern, so a wrong byte fails the job rather than going unnoticed.
load_start() {	# load_start <seconds>
	sudo fio --name=rowload --filename="$MD" --direct=1 --bs=64k --rw=randread \
		--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=32 \
		--numjobs=4 --time_based --runtime="$1" --verify=crc32c \
		--verify_fatal=1 --group_reporting \
		--output="$RK_TMP/rowtrans-load.log" > /dev/null 2>&1 &
	LOAD_PID=$!
}
load_wait() {	# reap the load; 0 = every verify passed
	local rc=0
	[ -n "$LOAD_PID" ] || return 0
	wait "$LOAD_PID" || rc=$?
	LOAD_PID=
	return $rc
}

# ---- create + baseline --------------------------------------------------------
for d in "${MEMBERS[@]}"; do
	sudo dd if=/dev/zero of="$d" bs=1M count=4 status=none 2>/dev/null || true
done
rk_dmesg_clear
sudo "$MDADM" --create "$MD" --level=raidkm --parity-count=$M \
	--layout=declustered --group-width=$G --spare-columns=$SC \
	--dcl-nbase=$NBASE --dcl-seed=$SEED --chunk="$CHUNK_KB" $CSUM_OPT \
	--raid-devices=$N "${MEMBERS[@]}" --run --force > /dev/null 2>&1 &&
   grep -q "$MDNAME : active raidkm" /proc/mdstat ||
	{ rk_fail "create/activate failed"; rk_summary; exit 1; }
rk_wait_idle

[ -r "/sys/block/$MDNAME/md/rk_row_stats" ] || \
	rk_skip "this raidkm has no rk_row_stats (a pre-row-layer module?)"
echo 1 | sudo tee "/sys/block/$MDNAME/md/rk_row_dread" > /dev/null 2>&1 || \
	rk_skip "this raidkm has no rk_row_dread"

sudo fio --name=base --filename="$MD" --direct=1 --bs=64k --rw=write \
	--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=8 \
	--verify=crc32c --do_verify=1 --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/rowtrans-base.log" > /dev/null 2>&1 \
	|| { rk_fail "baseline fio failed"; rk_summary; exit 1; }
sync
rk_pass "baseline written and verified ($((FIO_SZ / 1048576)) MiB, crc32c)"

FDEV="${MEMBERS[$VICTIM]}"
SDEV="${MEMBERS[$SECOND]}"

# ---- T1: POPULATING -> the row path must stay off -----------------------------
echo "=== T1: population running (POPULATING) — the row path must stay off ==="
rk_fail_disks "$FDEV"
sudo "$MDADM" --remove "$MD" "$FDEV" > /dev/null 2>&1
# throttle so the population is still running when we sample
echo 2000 | sudo tee "/sys/block/$MDNAME/md/sync_speed_max" > /dev/null 2>&1
echo "$VICTIM" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 \
	|| { rk_fail "T1: arming the population failed"; rk_summary; exit 1; }

if rk_pop_show | grep -q "^populating"; then
	before=$(dread_done)
	load_start 8
	load_wait && ok=1 || ok=0
	after=$(dread_done)
	[ "$ok" = 1 ] && rk_pass "T1: reads correct while POPULATING" \
		      || rk_fail "T1: a read returned wrong data while POPULATING"
	if [ "$after" = "$before" ]; then
		rk_pass "T1: row path stayed off while POPULATING (dread_done $before)"
	else
		rk_fail "T1: row path served $((after - before)) read(s) while POPULATING"
	fi
else
	rk_log "T1: population was not observable as POPULATING ($(rk_pop_show)); skipping the freeze check"
	rk_skip_check "T1: population finished before it could be sampled"
fi
# T1b: a load that is RUNNING when the population completes.  The transition
# only ever enables the row path (POPULATING -> POPULATED makes the array
# steady), so nothing should notice -- but "nothing should notice" is the kind
# of claim worth holding a verify load against.
load_start 20
sleep 2
echo 2000000 | sudo tee "/sys/block/$MDNAME/md/sync_speed_max" > /dev/null 2>&1
rk_wait_idle
rk_pop_show | grep -q "^populated" \
	&& rk_pass "T1: victim $VICTIM populated into the spare" \
	|| { rk_fail "T1: population did not complete: $(rk_pop_show)"; rk_summary; exit 1; }
load_wait && rk_pass "T1b: reads correct across the POPULATING -> POPULATED boundary" \
	  || rk_fail "T1b: a read returned wrong data across the population boundary"

# ---- T2: POPULATED + a second failure = steady AND degraded -------------------
echo "=== T2: assignment POPULATED + a second member failed — the row path must be live ==="
rk_fail_disks "$SDEV"
deg=$(cat "/sys/block/$MDNAME/md/degraded" 2>/dev/null || echo 0)
[ "${deg:-0}" -ge 1 ] || { rk_fail "T2: array is not degraded after failing $SDEV"; rk_summary; exit 1; }

before=$(dread_done)
load_start 8
load_wait && ok=1 || ok=0
after=$(dread_done)
[ "$ok" = 1 ] && rk_pass "T2: reads correct while steady + degraded" \
	      || rk_fail "T2: a read returned wrong data while steady + degraded"
if [ "$after" -gt "$before" ]; then
	rk_pass "T2: row path served the degraded reads ($((after - before)) chunks)"
else
	rk_fail "T2: row path served nothing — T3 would be vacuous (dread_done $before)"
fi

# ---- T3: the rebalance arms under load; COPYING takes the row path off --------
echo "=== T3: copy-from-spare rebalance armed under a degraded read load ==="
sudo dd if=/dev/zero of="$FDEV" bs=1M count=4 status=none 2>/dev/null || true
sudo "$MDADM" --zero-superblock "$FDEV" 2>/dev/null || true
# throttle the copy so COPYING lasts long enough to sample across
echo 2000 | sudo tee "/sys/block/$MDNAME/md/sync_speed_max" > /dev/null 2>&1
rk_dmesg_window_close; rk_dmesg_clear

load_start "$LOAD_SECS"
sleep 1				# reads in flight before the arm
rk_add_disks "$FDEV"

armed=0
for i in $(seq 1 80); do
	sudo dmesg | grep -q "copy-from-spare rebalance armed for disk $VICTIM" && { armed=1; break; }
	sleep 0.2
done
if [ "$armed" = 1 ]; then
	# Sampled a moment after the announcement, so reads admitted before the
	# flip have drained: what is counted here would be NEW admissions, and
	# the entry gate must refuse them while the assignment is COPYING.
	sleep 2
	before=$(dread_done)
	sleep 3
	after=$(dread_done)
	[ "$after" = "$before" ] \
		&& rk_pass "T3: no new row-path reads admitted while COPYING (dread_done $before)" \
		|| rk_fail "T3: row path admitted $((after - before)) read(s) while COPYING"
else
	rk_fail "T3: the copy path never armed: $(sudo dmesg | grep -iE 'declustered:.*(copy|retired)' | tail -1)"
fi

load_wait && rk_pass "T3: every read correct across the transition" \
	  || rk_fail "T3: a read returned wrong data across the transition"

echo 2000000 | sudo tee "/sys/block/$MDNAME/md/sync_speed_max" > /dev/null 2>&1

# ---- T4: settle, verify, scrub ------------------------------------------------
echo "=== T4: the copy completes and the data is intact ==="
rk_wait_idle
# The copy must COMPLETE, not fall back to the decode rebuild: until the copy
# decoded rows whose source is gone, T2's failed $SDEV hosted X's content in
# some rows, every copy aborted in its first band, and T3 passed on a
# rebuild that happened to keep the row path quiet.  Some of those rows are
# the ones decoded here, so the count must be nonzero too.
done_line=$(sudo dmesg | grep "copy of disk $VICTIM COMPLETE" | tail -1)
ndec=$(sed -n 's/.*(\([0-9]*\) row(s) decoded.*/\1/p' <<< "$done_line")
if [ -n "$done_line" ] && [ "${ndec:-0}" -gt 0 ]; then
	rk_pass "T4: the copy completed ($ndec row(s) decoded around the failed $SDEV)"
else
	rk_fail "T4: the copy did not complete with decoded rows: $(sudo dmesg | grep -iE 'declustered:.*(copy|retired)' | tail -1)"
fi
sudo "$MDADM" --re-add "$MD" "$SDEV" > /dev/null 2>&1 || \
	sudo "$MDADM" --add "$MD" "$SDEV" > /dev/null 2>&1 || true
rk_wait_full

sudo fio --name=verify --filename="$MD" --direct=1 --bs=64k --rw=read \
	--offset=$FIO_OFF --size=$FIO_SZ --ioengine=libaio --iodepth=8 \
	--verify=crc32c --verify_fatal=1 --group_reporting \
	--output="$RK_TMP/rowtrans-verify.log" > /dev/null 2>&1 \
	&& rk_pass "T4: data verifies after the copy" \
	|| rk_fail "T4: data does NOT verify after the copy"

mm=$(rk_scrub)
[ "$mm" = 0 ] && rk_pass "T4: scrub clean (mismatch_cnt=0)" \
	      || rk_fail "T4: scrub mismatch_cnt=$mm"

bad=$(stat_of dread_csum_bad)
[ "${bad:-0}" = 0 ] && rk_pass "T4: no row-layer csum rejection" \
		    || rk_fail "T4: dread_csum_bad=$bad"

rk_dmesg_clean && [ "$RK_DMESG_BAD" = 0 ] \
	&& rk_pass "T4: no kernel WARN/BUG" \
	|| rk_fail "T4: kernel warning/BUG during the transitions"

# ---- T5: two assignments POPULATED at once ------------------------------------
# Spare columns rotate over every pool disk, so a redirect can land on another
# failed-and-assigned disk and resolution CHAINS (raidkm_dcl_redirect).  Two
# assignments make that reachable.
#
# It also pins a property that is easy to assume away: a populated assignment
# restores the DATA (the kernel says "redundancy restored"), but the slot stays
# empty, and mddev->degraded is raid5_calc_degraded() -- which counts empty
# slots.  So s populated assignments consume the whole m-failure budget, and
# md refuses to fail another member until a replacement is added and copied
# back.  The row path needs mddev->degraded to run at all, so this is also the
# ceiling on exercising the chain: with m=2 and two assignments live there is
# no room left for the unassigned failure that would force a decode.
echo "=== T5: two POPULATED assignments at once ==="
rk_dmesg_window_close; rk_dmesg_clear
A=${DCL_A:-1}; B=${DCL_B:-6}; C=${DCL_C:-11}
ADEV="${MEMBERS[$A]}"; BDEV="${MEMBERS[$B]}"; CDEV="${MEMBERS[$C]}"

pop_one() {	# pop_one <slot> <dev>
	rk_fail_disks "$2"
	sudo "$MDADM" --remove "$MD" "$2" > /dev/null 2>&1
	echo "$1" | sudo tee "/sys/block/$MDNAME/md/rk_dcl_populate" > /dev/null 2>&1 || return 1
	rk_wait_idle
	rk_pop_show | grep -q "^populated"
}

if pop_one "$A" "$ADEV" && pop_one "$B" "$BDEV"; then
	rk_pass "T5: two assignments populated into the spare columns"

	deg=$(cat "/sys/block/$MDNAME/md/degraded" 2>/dev/null || echo -1)
	[ "$deg" = 2 ] && rk_pass "T5: both populated slots still count as degraded (degraded=$deg) — the spares restored the data, not md's accounting" \
		       || rk_fail "T5: expected degraded=2 with two assignments live, got $deg"

	# the failure budget is spent: md must refuse a third
	rk_fail_disks "$CDEV"
	deg2=$(cat "/sys/block/$MDNAME/md/degraded" 2>/dev/null || echo -1)
	if [ "$deg2" = "$deg" ]; then
		rk_pass "T5: a further failure is refused at degraded == m (still $deg2) — populated assignments consume the budget"
	else
		rk_fail "T5: the array accepted a third failure (degraded $deg -> $deg2) — check raid5_error's redundancy guard"
	fi

	before=$(dread_done)
	load_start 12
	load_wait && ok=1 || ok=0
	after=$(dread_done)
	[ "$ok" = 1 ] && rk_pass "T5: reads correct with two assignments live" \
		      || rk_fail "T5: a read returned wrong data with two assignments live"
	rk_log "T5: dread_done $before->$after (the row path needs an UNASSIGNED failure to decode; with m=2 there is no budget left for one)"

	mm=$(rk_scrub)
	[ "$mm" = 0 ] && rk_pass "T5: scrub clean with two assignments live" \
		      || rk_fail "T5: scrub mismatch_cnt=$mm with two assignments live"
	bad=$(stat_of dread_csum_bad)
	[ "${bad:-0}" = 0 ] && rk_pass "T5: no row-layer csum rejection" \
			    || rk_fail "T5: dread_csum_bad=$bad"
	rk_dmesg_clean && [ "$RK_DMESG_BAD" = 0 ] \
		&& rk_pass "T5: no kernel WARN/BUG" \
		|| rk_fail "T5: kernel warning/BUG with two assignments live"
else
	rk_fail "T5: could not populate two assignments ($(rk_pop_show))"
fi

rk_summary
