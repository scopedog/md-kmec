#!/bin/bash
#
# check-mddev-abi.sh — build-time ABI guard for the RHEL 10.2 raidkm port.
#
# raidkm.ko is an out-of-tree module that binds to the *builtin* md_mod, so the
# layout of struct mddev / struct md_rdev it was compiled against (the fork's
# md/md.h) must match the running kernel's exactly, or run() reads fields at the
# wrong offsets -> corruption / panic.
#
# The BUILD_BUG_ON in km/raid_km.c locks the *fork's* md.h to the verified
# offsets (catches an accidental header edit). This script is the other half:
# it checks the *kernel's* real layout via BTF (/sys/kernel/btf/vmlinux), so a
# kernel-side change to struct mddev is caught at build time.
#
# Policy: fail the build ONLY on a confirmed size/offset mismatch. If pahole or
# the kernel BTF is unavailable, or parsing fails, warn and SKIP (exit 0) — we
# never block a build we cannot verify. Override the BTF source for a cross
# build with BTF_VMLINUX=/path/to/target/vmlinux.
#
# Expected values below MUST stay in sync with the BUILD_BUG_ON in km/raid_km.c.

set -u
tag="[mddev-abi]"
KVER="${1:-$(uname -r)}"
BTF="${BTF_VMLINUX:-/sys/kernel/btf/vmlinux}"

skip() { echo "$tag SKIP: $1 — struct mddev ABI not verified (build continues)"; exit 0; }

command -v pahole >/dev/null 2>&1 || skip "pahole not found (install 'dwarves')"
[ -r "$BTF" ] || skip "$BTF not readable"
# /sys/kernel/btf/vmlinux describes the RUNNING kernel; if we are building for a
# different kernel and the caller did not point BTF_VMLINUX at the target, the
# check would be misleading — skip rather than risk a false verdict.
if [ "$BTF" = "/sys/kernel/btf/vmlinux" ] && [ "$KVER" != "$(uname -r)" ]; then
	skip "building for $KVER but BTF is the running $(uname -r) (set BTF_VMLINUX)"
fi

# --- expected layout (keep in sync with km/raid_km.c BUILD_BUG_ON) -----------
# Target selected from the kernel release: ".el" => RHEL 10.2, else mainline/Debian.
case "$KVER" in
*.el*)	abi_target=rhel10 ;;
*)	abi_target=vanilla ;;
esac
if [ "$abi_target" = vanilla ]; then
	exp_size=2336					# mainline / Debian 6.12
	mddev_fields="gendisk=120 level=256 reshape_position=344 recovery_active=584"
	exp_rdev_meta_bdev=				# (not pinned for vanilla)
	exp_bitmap_start_sync=120			# bitmap_operations vtable slot (Debian 6.12.90)
else
	exp_size=2080					# RHEL 10.2 builtin md
	mddev_fields="gendisk=120 dm_gendisk=128 level=264 reshape_position=352 \
	              sync_io_depth=488 normal_io_events=600 recovery_active=608 \
	              cluster_ops=2040"
	exp_rdev_meta_bdev=40
	exp_bitmap_start_sync=				# (not pinned for RHEL)
fi
# -----------------------------------------------------------------------------

# struct mddev lives in vmlinux BTF when md is builtin (RHEL) or in md_mod's
# split BTF when md is a module (Debian/mainline). Try vmlinux, then md_mod.
PAHOLE_BTF="$BTF"
dump=$(pahole -C mddev $PAHOLE_BTF 2>/dev/null)
if [ -z "$dump" ] && [ -r /sys/kernel/btf/md_mod ]; then
	modprobe md_mod 2>/dev/null || sudo modprobe md_mod 2>/dev/null || true
	PAHOLE_BTF="--btf_base $BTF /sys/kernel/btf/md_mod"
	dump=$(pahole -C mddev $PAHOLE_BTF 2>/dev/null)
fi
[ -n "$dump" ] || skip "pahole could not read struct mddev from $BTF or md_mod BTF"

# size: last "/* size: N" line in the struct dump
got_size=$(printf '%s\n' "$dump" | grep -oE '/\* size: [0-9]+' | tail -1 | grep -oE '[0-9]+')
[ -n "$got_size" ] || skip "could not parse struct mddev size from pahole output"

# offset of a top-level member "name": grab the first integer in the trailing
# /* off size */ comment on the (whitespace/'*')-prefixed "name;" line. The
# prefix class avoids matching a substring (e.g. 'level' inside 'new_level').
field_off() {
	printf '%s\n' "$dump" | grep -E "[[:space:]*]$1;" | head -1 \
		| sed -nE 's:.*/\*[[:space:]]*([0-9]+).*:\1:p'
}

fail=0
miss() { printf "  %-24s expected %-6s got %s\n" "$1" "$2" "$3"; fail=1; }

[ "$got_size" = "$exp_size" ] || miss "sizeof(struct mddev)" "$exp_size" "$got_size"
for kv in $mddev_fields; do
	f=${kv%=*}; want=${kv#*=}
	got=$(field_off "$f")
	if [ -z "$got" ]; then
		echo "$tag note: could not parse offset of mddev.$f (skipping that field)"
		continue
	fi
	[ "$got" = "$want" ] || miss "offsetof(mddev,$f)" "$want" "$got"
done

# struct md_rdev: meta_bdev (offset pinned only for the RHEL target)
if [ -n "$exp_rdev_meta_bdev" ]; then
	rdump=$(pahole -C md_rdev $PAHOLE_BTF 2>/dev/null)
	if [ -n "$rdump" ]; then
		got=$(printf '%s\n' "$rdump" | grep -E "[[:space:]*]meta_bdev;" | head -1 \
			| sed -nE 's:.*/\*[[:space:]]*([0-9]+).*:\1:p')
		[ -z "$got" ] || [ "$got" = "$exp_rdev_meta_bdev" ] || \
			miss "offsetof(md_rdev,meta_bdev)" "$exp_rdev_meta_bdev" "$got"
	fi
fi

# struct bitmap_operations: the start_sync vtable slot.  raidkm calls
# mddev->bitmap_ops->start_sync(); if a stable backport reorders bitmap_ops
# (e.g. Debian 6.12.90's bitmap rework vs torvalds v6.12.0 added two ops before
# start_sync), the slot shifts and raidkm jumps to the wrong function -> oops in
# the bitmap resync.  struct mddev offsets can match while this is broken, so
# check it explicitly (pinned for the vanilla target).
if [ -n "$exp_bitmap_start_sync" ]; then
	bdump=$(pahole -C bitmap_operations $PAHOLE_BTF 2>/dev/null)
	if [ -n "$bdump" ]; then
		got=$(printf '%s\n' "$bdump" | grep -E '\(\*start_sync\)' | head -1 \
			| sed -nE 's:.*/\*[[:space:]]*([0-9]+).*:\1:p')
		[ -z "$got" ] || [ "$got" = "$exp_bitmap_start_sync" ] || \
			miss "offsetof(bitmap_operations,start_sync)" "$exp_bitmap_start_sync" "$got"
	fi
fi

if [ "$fail" = 1 ]; then
	echo "$tag ERROR: struct mddev/md_rdev ABI DRIFT vs the verified $abi_target layout (kernel $KVER)."
	echo "$tag raidkm.ko would read fields at the wrong offsets against the builtin md_mod."
	echo "$tag Re-port needed: re-derive offsets ('pahole -C mddev $BTF'), update md/md.h and"
	echo "$tag the BUILD_BUG_ON in km/raid_km.c to match, then rebuild. Failing the build."
	exit 1
fi

echo "$tag OK: struct mddev (size $got_size) matches the verified $abi_target layout (kernel $KVER)."
exit 0
