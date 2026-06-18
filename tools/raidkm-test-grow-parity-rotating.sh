#!/bin/bash
# raidkm-test-grow-parity-rotating.sh — add-parity (m -> m+1) on a
# rotating-layout raidkm array.
#
# A rotating array relocates every block when m grows.  This is now an ONLINE
# COW-staged reshape: each band is read via the old layout, re-encoded with the
# new parity, staged to a scratch region and committed to its home, journaling
# every step so a crash is recoverable on assembly — no --backup-file needed.
# (rk_grow_parity() still passes --backup-file; the online path ignores it.)
# For each m -> m+1:
#   create k=3 rotating, write data, add one parity, then assert
#     (a) geometry grew by one disk and capacity is UNCHANGED (k fixed);
#     (b) data is intact after the migration (read back == written);
#     (c) scrub is clean (parity recomputed correctly for the new m);
#     (d) THE oracle: fail the NEW m disks and read back — the decode must use
#         the new geometry's EC tables, or degraded read corrupts.  Covers the
#         m=3->4 Vandermonde->Cauchy matrix-family boundary.
#
#   sudo bash tools/raidkm-test-grow-parity-rotating.sh
set -u
. "$(dirname "${BASH_SOURCE[0]}")/raidkm-test-lib.sh"

SZ="${SZ:-24}"

rk_load_modules || exit 1
rk_setup_brd 8 || exit 1
rk_dmesg_clear

# add_parity_case <old_m> : k=3 rotating, add one parity (m -> m+1).
add_parity_case() {
	local old_m="$1" k=3
	local new_m=$((old_m + 1))
	local oldn=$((k + old_m)) newn=$((k + new_m))
	local tag="m=$old_m->$new_m rotating (k=$k)"
	local all base add i

	all=$(rk_pick_disks "$newn") || { rk_fail "$tag: not enough ramdisks"; return; }
	base=$(echo $all | cut -d' ' -f1-"$oldn")
	add=$(echo $all | cut -d' ' -f"$newn")

	rk_create "${old_m}r" $base || { rk_fail "$tag: create failed"; return; }
	local sz_before; sz_before=$(sudo blockdev --getsize64 "$MD")
	rk_write "$SZ"

	if ! rk_grow_parity $add; then
		rk_fail "$tag: --add-parity failed"; rk_stop; return
	fi

	# (a) geometry + capacity
	local geom sz_after
	geom=$(rk_geom)
	if [ "$geom" = "[$newn/$newn]" ]; then
		rk_pass "$tag: geometry grew to $geom"
	else
		rk_fail "$tag: geometry $geom (want [$newn/$newn])"
	fi
	sz_after=$(sudo blockdev --getsize64 "$MD")
	if [ "$sz_after" = "$sz_before" ]; then
		rk_pass "$tag: capacity unchanged (k fixed)"
	else
		rk_fail "$tag: capacity changed $sz_before -> $sz_after (k should be fixed)"
	fi

	# (b) data intact after the reshape
	if rk_readback "$SZ"; then
		rk_pass "$tag: data intact after add-parity"
	else
		rk_fail "$tag: data MISMATCH after add-parity"
	fi

	# (c) scrub clean
	local mm; mm=$(rk_scrub)
	[ "$mm" = 0 ] && rk_pass "$tag: scrub clean (mismatch_cnt=0)" \
		      || rk_fail "$tag: scrub mismatch_cnt=$mm"

	# (d) degraded read at the NEW redundancy: fail new_m disks (leaves k
	#     survivors) and reconstruct — exercises the new geometry's decode.
	local fail=$(echo $all | cut -d' ' -f1-"$new_m")
	rk_fail_disks $fail
	if rk_readback "$SZ"; then
		rk_pass "$tag: degraded read reconstructs after add-parity (max $new_m failures)"
	else
		rk_fail "$tag: degraded read FAILED after add-parity"
	fi
	rk_stop
}

# Rotating add-parity is now an ONLINE COW-staged reshape (per-band read-old ->
# re-encode -> stage to scratch -> commit, journaled).  It needs NO backup file
# — the in-kernel journal makes a crash recoverable on assembly — and it
# preserves data + parity correctness while the array stays up.
add_parity_no_backup_case() {
	local old_m=2 k=3
	local new_m=$((old_m + 1))
	local oldn=$((k + old_m))
	local newn=$((oldn + 1))
	local tag="m=$old_m->$new_m rotating add-parity (online, no backup-file)"
	local all base add

	all=$(rk_pick_disks "$newn") || { rk_fail "$tag: not enough ramdisks"; return; }
	base=$(echo $all | cut -d' ' -f1-"$oldn")
	add=$(echo $all | cut -d' ' -f"$newn")

	rk_create "${old_m}r" $base || { rk_fail "$tag: create failed"; return; }
	rk_write "$SZ"

	# online add-parity needs no --backup-file; it must succeed.
	if sudo "$MDADM" --grow "$MD" --add-parity $add >/dev/null 2>&1; then
		rk_pass "$tag: add-parity without --backup-file accepted (online)"
	else
		rk_fail "$tag: online add-parity without --backup-file was rejected"
	fi
	rk_wait_idle
	local geom; geom=$(rk_geom)
	if [ "$geom" = "[$newn/$newn]" ] && rk_readback "$SZ"; then
		rk_pass "$tag: reshaped to [$newn/$newn] + data intact"
	else
		rk_fail "$tag: wrong geom/data after online add-parity (geom $geom)"
	fi
	# EC-correct: fail the new m disks and reconstruct.
	rk_fail_disks $(echo $all | tr ' ' '\n' | head -n "$new_m")
	if rk_readback "$SZ"; then
		rk_pass "$tag: ${new_m}-disk-degraded read reconstructs (new m=$new_m EC-correct)"
	else
		rk_fail "$tag: degraded read WRONG after add-parity"
	fi
	rk_stop
}

add_parity_case 2   # m=2 -> 3 : Vandermonde (from the raid6-equivalent m=2 path)
add_parity_case 3   # m=3 -> 4 : crosses the Vandermonde -> Cauchy matrix boundary
add_parity_no_backup_case   # online: no --backup-file needed

rk_dmesg_clean "raidkm-test-grow-parity-rotating"
rk_summary "raidkm-test-grow-parity-rotating.sh"
