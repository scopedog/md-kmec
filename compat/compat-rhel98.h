/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Compatibility shims for building the raidkm md sources against the
 * RHEL 9.8 kernel (5.14.0-687.x.el9_8).  Paired with md-rhel98/ — an EXACT
 * copy of that kernel's drivers/md headers.  The same as compat-rhel9.h
 * (9.7) but for what 9.8's md core changed (md-rhel98/README):
 *
 *   - bitmap_ops->start_write/end_write (renamed, void) instead of
 *     startwrite/endwrite;
 *   - mddev->resync_offset instead of recovery_cp (raidkm's sources say
 *     recovery_cp, which names nothing else in the kernel headers);
 *   - md_sync_acct() is gone with gendisk->sync_io: a no-op, as upstream
 *     (the idle check reads part_stat only).
 *
 * The 9.7 text follows.
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
#ifndef MD_COMPAT_RHEL98_H
#define MD_COMPAT_RHEL98_H

#include <linux/mm.h>		/* ZERO_PAGE / page_address */

#define RAIDKM_TARGET_RHEL9 1
#define RAIDKM_TARGET_RHEL98 1
#define RAIDKM_PERS_HAS_HEAD 1

#define register_md_personality(p)	register_md_submodule(&(p)->head)
#define unregister_md_personality(p)	unregister_md_submodule(&(p)->head)

/*
 * bitmap write tracking: el9_8's bitmap_ops->start_write/end_write are 3-arg
 * (write-behind/success flags dropped), same shape as RHEL 10 / Debian 6.12.
 */
#define raidkm_bitmap_startwrite(mddev, off, sects)			\
	(mddev)->bitmap_ops->start_write((mddev), (off), (sects))
#define raidkm_bitmap_endwrite(mddev, off, sects, ok)			\
	(mddev)->bitmap_ops->end_write((mddev), (off), (sects))

/* 9.8: struct mddev's recovery_cp is resync_offset (upstream 6.17 name) */
#define recovery_cp resync_offset

/* 9.8: gendisk->sync_io and md_sync_acct() are gone; md's idle check
 * reads part_stat only, as upstream */
struct block_device;
struct bio;
static inline void md_sync_acct(struct block_device *bdev,
				unsigned long nr_sectors) { }
static inline void md_sync_acct_bio(struct bio *bio,
				    unsigned long nr_sectors) { }

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

/*
 * el9_7 declares bio_add_folio_nofail() in <linux/bio.h> but does not
 * export it (5.14.0-611.55.1 Module.symvers): a raidkm.ko that calls it
 * fails to load ("Unknown symbol").  Upstream's body is exactly this, and
 * __bio_add_page() is exported.  bio.h first, so its declaration is not
 * hit by the macro (it has include guards).
 */
#include <linux/bio.h>
#define bio_add_folio_nofail(bio, folio, len, off)			\
	__bio_add_page((bio), &(folio)->page, (len), (off))

#endif /* MD_COMPAT_RHEL98_H */
