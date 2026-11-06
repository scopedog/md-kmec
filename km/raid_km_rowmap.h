/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * raidkm row state map (RAIDKM_LAYOUT_ROWMAP): one 2-bit state per row --
 * one chunk of every member -- saying whether the row's parity can be
 * trusted.  Design: notes/md-kmec/row-state-map-design-2026-10-31.md.
 *
 *   U  unwritten: no live data, parity not trusted, content undefined.
 *      Rebuild, resync and check skip it.  A new array starts all U, a
 *      discard covering the row returns it to U.
 *   N  needs sync: written since U by something less than the whole row;
 *      every write to it is a reconstruct-write, so each stripe written is
 *      consistent, the rest of the row may not be.
 *   S  syncing: N while a full resync/repair pass is over it (in-core
 *      meaning; on disk it reads back as N).  A complete pass makes it W.
 *   W  written: an ordinary row.
 *
 * U -> N/W must be on disk before any member write of the row goes out:
 * otherwise a crash leaves live data in a row the map calls unused, and a
 * rebuild skips it.  Everything else is lazy -- losing it leaves a row
 * looking more used than it is, which only costs a skip.
 *
 * On disk: a tail reserve on every member at data_offset + dev_sectors
 * (one chunk later on a declustered array: its rkdcl block is there),
 * 4 KiB pages of (4096 - 16) * 4 states and a trailer, written to every
 * member.  The copy with the highest generation and a good CRC wins.
 *
 * Declustered: a row is still one chunk of every member (the pool), with
 * ngroups * k data chunks in it; its state covers every group of the row.
 */
#ifndef _RAID_KM_ROWMAP_H
#define _RAID_KM_ROWMAP_H

#include <linux/types.h>
#include <linux/spinlock.h>
#include <linux/mutex.h>
#include <linux/workqueue.h>
#include <linux/bitmap.h>
#include <linux/slab.h>

struct r5conf;
struct mddev;
struct stripe_head;

/*
 * One bit per row: bitmap_zalloc() is kmalloc, which fails above
 * KMALLOC_MAX_SIZE (4 MiB, 33.5 M bits), so an array with more rows than
 * that could not assemble with the row map or snapshots.  These fall back
 * to vmalloc.  GFP_KERNEL only (kvmalloc and GFP_NOIO do not mix on every
 * kernel we build for); free with rk_bitmap_free().
 */
static inline unsigned long *rk_bitmap_zalloc(u64 nbits)
{
	return kvcalloc(BITS_TO_LONGS(nbits), sizeof(unsigned long),
			GFP_KERNEL);
}

static inline void rk_bitmap_free(unsigned long *map)
{
	kvfree(map);
}

#define RK_RM_U		0
#define RK_RM_N		1
#define RK_RM_W		2
#define RK_RM_S		3

#define RK_RM_PAGE	4096		/* on-disk page, whatever PAGE_SIZE is */
#define RK_RM_TRAILER	16
#define RK_RM_BODY	(RK_RM_PAGE - RK_RM_TRAILER)
#define RK_RM_ROWS_PER_PAGE (RK_RM_BODY * 4)	/* 16320; mdadm uses the same */
#define RK_RM_MAGIC	0x524b524dU		/* "RKRM" */

struct raidkm_rowmap {
	struct r5conf		*conf;
	spinlock_t		lock;		/* states, dirty, need, epoch */
	struct mutex		flush_mutex;	/* one flush at a time */
	u64			nrows;
	unsigned int		npages;
	unsigned int		chunk_sectors;
	sector_t		region;		/* member sector rel. data_offset */
	u8			*map;		/* npages * RK_RM_BODY bytes */
	unsigned long		*dirty;		/* pages changed since a snapshot */
	unsigned long		*rec_skipped;	/* rows a recovery skipped (U) */
	u64			*need;		/* epoch that makes a page durable */
	u64			epoch;		/* bumped at every flush snapshot */
	u64			durable;	/* last epoch fully on disk */
	u64			gen;		/* on-disk generation */
	u32			id;		/* crc32c of the array uuid */
	bool			member_discard;	/* members take the discards too */
	bool			pass_marked;	/* N rows were marked S */
	struct delayed_work	lazy;		/* writes back U and W changes */
	struct page		*bounce;	/* flush_mutex */
	atomic64_t		to_n, to_w, to_u, flushes, page_writes;
	atomic64_t		write_errors, skipped_rows, waits, promoted;
};

int raidkm_rowmap_init(struct r5conf *conf);
void raidkm_rowmap_seed(struct r5conf *conf);
void raidkm_rowmap_note_row_written(struct r5conf *conf, u64 row);
struct md_rdev *raidkm_rowmap_member(struct r5conf *conf, int slot);
void raidkm_rowmap_stop(struct r5conf *conf);
void raidkm_rowmap_free(struct r5conf *conf);
bool raidkm_rowmap_note_write(struct r5conf *conf, sector_t sector,
			      unsigned int sectors);
void raidkm_rowmap_note_discard(struct r5conf *conf, u64 first_row,
				u64 last_row);
bool raidkm_rowmap_force_rcw(struct r5conf *conf, sector_t msect);
bool raidkm_rowmap_rec_skipped(struct r5conf *conf, sector_t msect);
void raidkm_rowmap_member_added(struct r5conf *conf);
void raidkm_rowmap_stripe_start(struct r5conf *conf, struct stripe_head *sh);
void raidkm_rowmap_raid5d_round(struct r5conf *conf);
bool raidkm_rowmap_flush(struct r5conf *conf);
/* where a member's tail regions begin, in sectors from its data_offset:
 * after the data, and after the rkdcl chunk on a declustered array.  The
 * CRC region starts here; the row map after it (or here without csum). */
sector_t raidkm_tail_start(struct r5conf *conf);
/* the CRC region's start, or -1 (raid_km.c; rk_rowmap csum_region) */
s64 raidkm_csum_region_start(struct r5conf *conf);
void raidkm_rowmap_wait_row(struct r5conf *conf, sector_t msect);
sector_t raidkm_rowmap_sync_skip(struct mddev *mddev, sector_t sector_nr,
				 sector_t max_sector);
sector_t raidkm_rowmap_run_end(struct mddev *mddev, sector_t sector_nr,
			       sector_t end);
void raidkm_rowmap_pass_end(struct mddev *mddev, sector_t max_sector);
ssize_t raidkm_rowmap_show(struct mddev *mddev, char *page);
ssize_t raidkm_rowmap_store(struct mddev *mddev, const char *page, size_t len);

#endif
