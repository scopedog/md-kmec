/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Compatibility shims for building the raidkm md sources against a
 * mainline / Debian 6.12 kernel (e.g. Debian 13 "trixie",
 * 6.12.x+debN-amd64).  Paired with compat-rhel10.h; raid_km.c stays
 * single-source and the RHEL-vs-mainline differences are isolated here.
 *
 * Differences from RHEL 10.2's 6.12 md core:
 *   - struct mddev is the mainline layout (2336 B), without RHEL's
 *     dm_gendisk / sync_io_depth / normal_io_events / cluster_ops.
 *   - md personalities register via register_md_personality() (the
 *     original name; RHEL renamed it to register_md_submodule()), so
 *     no rename is needed here.
 *   - raid6_get_zero_page() is not exported; use the global zero page.
 *
 * NB: Debian's 6.12.90 backported the upstream bitmap_ops rework, so its
 * bitmap_ops->startwrite/endwrite are 3-arg (no write-behind/success flags) —
 * same shape as RHEL's — and start_behind_write/end_behind_write are separate
 * ops.  These shims therefore match compat-rhel10.h.  This file is paired with
 * the EXACT Debian drivers/md/*.h vendored under md-vanilla/, so struct and
 * vtable offsets match the running kernel (no header skew).
 */
#ifndef MD_COMPAT_VANILLA_H
#define MD_COMPAT_VANILLA_H

#include <linux/mm.h>		/* ZERO_PAGE / page_address */

#define RAIDKM_TARGET_VANILLA612 1

/*
 * bitmap write tracking.  Debian 6.12.90's bitmap_ops->startwrite/endwrite are
 * 3-arg (the write-behind/success flags moved to start_behind_write/
 * end_behind_write); raidkm never issues write-behind, so we just drop them.
 */
#define raidkm_bitmap_startwrite(mddev, off, sects)			\
	(mddev)->bitmap_ops->startwrite((mddev), (off), (sects))
#define raidkm_bitmap_endwrite(mddev, off, sects, ok)			\
	(mddev)->bitmap_ops->endwrite((mddev), (off), (sects))

/*
 * RHEL 10.2 exports raid6_get_zero_page(); mainline does not.  The
 * global zero page is an always-zero, read-only data source, which is
 * exactly what the syndrome path needs for a missing/zero block.
 */
#define raid6_get_zero_page()	((void *)page_address(ZERO_PAGE(0)))

/*
 * Note: no md_wakeup_thread shim.  The vendored Debian md.h already defines
 * md_wakeup_thread() as a wrapper around the exported __md_wakeup_thread(), and
 * raidkm registers via register_md_personality() (the original name, which
 * Debian retains) — so neither needs a compat override here.
 */

#endif /* MD_COMPAT_VANILLA_H */
