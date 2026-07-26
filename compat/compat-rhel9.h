/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Compatibility shims for building the raidkm md sources against the
 * RHEL 9.7 kernel (5.14.0-611.x.el9_7).  Paired with md-rhel9/ — an EXACT
 * copy of that kernel's drivers/md headers (same vendoring rule as
 * md-vanilla/, see its README).
 *
 * Despite the 5.14 base, el9_7 carries the 6.12-era md core backport:
 * md_submodule registration, the reworked bitmap_ops vtable (3-arg
 * startwrite/endwrite), md_init_stacking_limits / queue_limits_*.  So this
 * file is closest to compat-vanilla.h, with two el9 particulars:
 *
 *   - struct md_personality embeds struct md_submodule_head (type/id/name/
 *     owner) instead of flat name/level/owner members, and only
 *     register_md_submodule() exists.  raid_km.c initializes the head under
 *     RAIDKM_PERS_HAS_HEAD and the register shims below pass &p->head.
 *   - raid6_get_zero_page() is not exported (RHEL 10 exports it); use the
 *     global zero page like the vanilla build does.
 */
#ifndef MD_COMPAT_RHEL9_H
#define MD_COMPAT_RHEL9_H

#include <linux/mm.h>		/* ZERO_PAGE / page_address */

#define RAIDKM_TARGET_RHEL9 1
#define RAIDKM_PERS_HAS_HEAD 1

#define register_md_personality(p)	register_md_submodule(&(p)->head)
#define unregister_md_personality(p)	unregister_md_submodule(&(p)->head)

/*
 * bitmap write tracking: el9_7's bitmap_ops->startwrite/endwrite are 3-arg
 * (write-behind/success flags dropped), same shape as RHEL 10 / Debian 6.12.
 */
#define raidkm_bitmap_startwrite(mddev, off, sects)			\
	(mddev)->bitmap_ops->startwrite((mddev), (off), (sects))
#define raidkm_bitmap_endwrite(mddev, off, sects, ok)			\
	(mddev)->bitmap_ops->endwrite((mddev), (off), (sects))

/*
 * mddev->recovery_active is a 32-bit atomic_t on el9 (BTF: @584, 4 bytes),
 * like mainline; the RHEL 10 port carries it as atomic64_t.
 */
#define raidkm_recovery_active_add(mddev, sectors)			\
	atomic_add((sectors), &(mddev)->recovery_active)

/*
 * el9 does not export raid6_get_zero_page(); the global zero page is an
 * always-zero read-only data source, which is all the EC kernels need.
 */
#define raid6_get_zero_page()	((void *)page_address(ZERO_PAGE(0)))

#endif /* MD_COMPAT_RHEL9_H */
