/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Compatibility shims for building the raidkm md sources against the
 * Ubuntu 26.04 kernel 7.0 (every flavour but realtime: md-ubuntu2604/README).
 * Ubuntu builds md core into the kernel (CONFIG_BLK_DEV_MD=y; struct mddev
 * lives in vmlinux BTF), so raidkm binds to that builtin md and is built
 * against the stock 7.0 drivers/md headers vendored in md-ubuntu2604/
 * (Makefile TARGET=ubuntu2604), not the fork's patched md/.  struct mddev
 * (size 1936) is pinned in km/raid_km.c and checked against the running
 * kernel's BTF by tools/check-mddev-abi.sh.
 *
 * 7.0 md core vs RHEL 10.2's 6.12 backport:
 *   - struct md_personality embeds struct md_submodule_head (type/id/name/
 *     owner); only register_md_submodule() exists (like el9, unlike rhel10's
 *     flat register_md_personality rename).  raid_km.c initializes the head
 *     under RAIDKM_PERS_HAS_HEAD; the register shims below pass &p->head.
 *   - bitmap_ops write tracking was renamed startwrite/endwrite ->
 *     start_write/end_write (md_bitmap_fn: 3-arg, void).
 *   - mddev->recovery_active is still a 4-byte atomic_t (atomic_add).
 *   - raid6_get_zero_page() is provided by 7.0's <linux/raid/pq.h> (like
 *     RHEL 10, unlike el9/vanilla), so no shim is needed for it here.
 */
#ifndef MD_COMPAT_UBUNTU2604_H
#define MD_COMPAT_UBUNTU2604_H

#include <linux/mm.h>		/* ZERO_PAGE / page_address */
#include <linux/crc32c.h>	/* crc32c() — 7.0 name for crc32c_le() */

#define RAIDKM_TARGET_UBUNTU2604 1
#define RAIDKM_PERS_HAS_HEAD 1

#define register_md_personality(p)	register_md_submodule(&(p)->head)
#define unregister_md_personality(p)	unregister_md_submodule(&(p)->head)

/*
 * bitmap write tracking: md core counts each write bio (md_clone_bio ->
 * pers->bitmap_sector -> start/end write in md_end_clone_io); raidkm maps it
 * to member rows (raidkm_bitmap_sector) and keeps no count of its own.
 */
#define RAIDKM_MD_COUNTS_BITMAP	1

/*
 * Plan A's bitmap holds (raidkm_csum_bmh_*) take and release a chunk's count
 * directly; md core counts the writes themselves (RAIDKM_MD_COUNTS_BITMAP).
 */
#define raidkm_bitmap_startwrite(mddev, off, sects)			\
	(mddev)->bitmap_ops->start_write((mddev), (off), (sects))
#define raidkm_bitmap_endwrite(mddev, off, sects, ok)			\
	(mddev)->bitmap_ops->end_write((mddev), (off), (sects))

/*
 * mddev->recovery_active is a 4-byte atomic_t in stock 7.0 md core (the fork's
 * md.h makes it atomic64_t, but md core is builtin and stock); the declustered
 * sync-credit accounting goes through this shim so raid_km.c stays
 * single-source.
 */
#define raidkm_recovery_active_add(mddev, sectors)			\
	atomic_add((sectors), &(mddev)->recovery_active)
#define raidkm_recovery_active_read(mddev)				\
	atomic_read(&(mddev)->recovery_active)


/*
 * 7.0 renamed crc32c_le() to crc32c() (declared in <linux/crc32c.h>, included
 * above).  raid_km.c's native-checksum paths still call crc32c_le().
 */
#define crc32c_le(crc, data, length)	crc32c((crc), (data), (length))
/* ... and it is the arch-accelerated CRC (6.14+): raidkm takes no transform */
#define RAIDKM_CRC32C_LIB_ACCEL	1

/*
 * 7.0 removed md_sync_acct(): the per-disk sync_io accounting it fed was
 * dropped from md core (stock 7.0 raid5.c makes no such call).  No-op it.
 */
#define md_sync_acct(bdev, nr_sectors)	do { } while (0)

/*
 * 7.0 renamed mddev->recovery_cp to mddev->resync_offset (md.h uses the new
 * name only, so this object-like macro rewrites raid_km.c's ->recovery_cp
 * accesses without touching md.h).
 */
#define recovery_cp			resync_offset

/*
 * 7.0 dropped md_done_sync()'s third (ok) argument: a failed sync stripe is
 * reported with md_sync_error() (sets MD_RECOVERY_INTR and wakes the md
 * thread), after md_done_sync(), as stock 7.0 raid5.c's handle_failed_sync()
 * does.  Preserve raid_km.c's single-source md_done_sync(mddev, sectors, ok).
 */
#define raidkm_md_done_sync(mddev, sectors, ok)				\
	do {								\
		md_done_sync((mddev), (sectors));			\
		if (!(ok))						\
			md_sync_error(mddev);				\
	} while (0)

/*
 * 7.0 md_finish_sync() sets resync_offset = curr_resync for any interrupted
 * resync/repair, even when it was MaxSector (6.12-era md core only moved it
 * forward).  raid_km.c keeps an interrupted declustered population (a repair
 * pass that changes no parity) from marking a clean array dirty.
 */
#define RAIDKM_MD_INTR_REPAIR_SETS_OFFSET	1

/* 7.0 bitmap_ops->resize dropped its trailing `init` bool argument. */
#define raidkm_bitmap_resize(mddev, blocks, chunksize, init)		\
	(mddev)->bitmap_ops->resize((mddev), (blocks), (chunksize))

/*
 * 7.0 removed mddev->recovery_disabled and the personality retry-gate that used
 * it (stock 7.0 raid5.c add/remove_disk no longer reference it).  Mirror that:
 * the conf-side snapshot/init become no-ops, and the two guard terms collapse
 * to their stock-7.0 values (remove: the dropped term == always-true; add: the
 * dropped -EBUSY check == never-busy).
 */
#define raidkm_recovery_disabled_snapshot(conf, mddev)	do { } while (0)
#define raidkm_recovery_disabled_init(conf, mddev)	do { } while (0)
#define raidkm_recovery_can_remove(mddev, conf)		1
#define raidkm_recovery_add_busy(mddev, conf)		0

#endif /* MD_COMPAT_UBUNTU2604_H */
