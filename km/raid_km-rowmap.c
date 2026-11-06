// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * raidkm row state map: see raid_km_rowmap.h and
 * notes/md-kmec/row-state-map-design-2026-10-31.md.
 */
#include <linux/blkdev.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/crc32c.h>
#include <linux/bitmap.h>
#include <linux/math64.h>

#include "md.h"
#include "raid_km.h"
#include "raid_km-log.h"
#include "raid_km_rowmap.h"
#include "raid_km_snap.h"

/* testing only: let a write into a row that is not W choose
 * read-modify-write, to show the suites catch the parity it leaves */
static bool rowmap_test_no_rcw;
module_param(rowmap_test_no_rcw, bool, 0644);
MODULE_PARM_DESC(rowmap_test_no_rcw,
		 "TESTING ONLY: do not force reconstruct-write into rows the row map does not call written");

/* testing only: do not treat rows a recovery skipped as in sync on the
 * member it rebuilds, to show the suite catches the parity a write into
 * such a row leaves (review finding 1, raidkm_rowmap_rec_skipped()) */
static bool rowmap_test_no_recskip;
module_param(rowmap_test_no_recskip, bool, 0644);
MODULE_PARM_DESC(rowmap_test_no_recskip,
		 "TESTING ONLY: a write into a row a running recovery skipped treats the rebuilt member as missing");

#define RK_RM_LAZY_DELAY	(5 * HZ)

static inline u8 *rk_rm_byte(struct raidkm_rowmap *rm, u64 row)
{
	u64 p = div_u64(row, RK_RM_ROWS_PER_PAGE);
	u32 off = row - p * RK_RM_ROWS_PER_PAGE;

	return rm->map + p * RK_RM_BODY + (off >> 2);
}

static inline unsigned int rk_rm_get(struct raidkm_rowmap *rm, u64 row)
{
	return (READ_ONCE(*rk_rm_byte(rm, row)) >> ((row & 3) * 2)) & 3;
}

static inline unsigned int rk_rm_page(u64 row)
{
	return div_u64(row, RK_RM_ROWS_PER_PAGE);
}

/* under rm->lock */
static void rk_rm_set(struct raidkm_rowmap *rm, u64 row, unsigned int st)
{
	u8 *b = rk_rm_byte(rm, row);
	unsigned int sh = (row & 3) * 2;

	WRITE_ONCE(*b, (*b & ~(3 << sh)) | (st << sh));
	__set_bit(rk_rm_page(row), rm->dirty);
}

/* ---- on-disk pages ------------------------------------------------- */

static u32 rk_rm_page_crc(const u8 *buf)
{
	/* the body and the trailer's id + gen */
	return crc32c(0, buf, RK_RM_BODY + 12) ^ RK_RM_MAGIC;
}

static void rk_rm_seal(struct raidkm_rowmap *rm, u8 *buf, u64 gen)
{
	__le32 *id = (__le32 *)(buf + RK_RM_BODY);
	__le64 *g = (__le64 *)(buf + RK_RM_BODY + 4);
	__le32 *crc = (__le32 *)(buf + RK_RM_BODY + 12);

	*id = cpu_to_le32(rm->id);
	*g = cpu_to_le64(gen);
	*crc = cpu_to_le32(rk_rm_page_crc(buf));
}

/*
 * 1 = a good page of this array (*gen set), 0 = never written here (all
 * zeroes), -1 = not trusted: damaged, or a good page with another id.  The
 * id is the array UUID's, and `mdadm --assemble --update=uuid` changes the
 * UUID under a map full of data; mdadm zeroes the map at create and add,
 * so a foreign page is never a reason to call rows unused (the caller
 * makes an untrusted page all N).
 */
static int rk_rm_check(struct raidkm_rowmap *rm, const u8 *buf, u64 *gen)
{
	u32 id = le32_to_cpu(*(const __le32 *)(buf + RK_RM_BODY));
	u32 crc = le32_to_cpu(*(const __le32 *)(buf + RK_RM_BODY + 12));

	if (!memchr_inv(buf, 0, RK_RM_PAGE))
		return 0;
	if (crc != rk_rm_page_crc(buf))
		return -1;
	if (id != rm->id)
		return -1;
	*gen = le64_to_cpu(*(const __le64 *)(buf + RK_RM_BODY + 4));
	return 1;
}

/* the members (and replacements) a page goes to: every one that is not
 * failed.  Called with no locks; takes a pending reference. */
static struct md_rdev *rk_rm_member(struct r5conf *conf, int slot)
{
	struct md_rdev *rdev;
	int i = slot >> 1;

	rcu_read_lock();
	rdev = slot & 1 ? READ_ONCE(conf->disks[i].replacement) :
			  READ_ONCE(conf->disks[i].rdev);
	if (rdev && (test_bit(Faulty, &rdev->flags) || !rdev->bdev))
		rdev = NULL;
	if (rdev)
		atomic_inc(&rdev->nr_pending);
	rcu_read_unlock();
	return rdev;
}

/* the same, for the snapshot metadata (raid_km-snapmeta.c) */
struct md_rdev *raidkm_rowmap_member(struct r5conf *conf, int slot)
{
	return rk_rm_member(conf, slot);
}

/*
 * Write the sealed page in rm->bounce to @only, or to every member.
 * Returns how many members took it, or -1 when there was no member to
 * write to at all.
 */
static int rk_rm_write_page(struct raidkm_rowmap *rm, unsigned int p,
			    struct md_rdev *only)
{
	struct r5conf *conf = rm->conf;
	struct mddev *mddev = conf->mddev;
	int slot, ok = 0, tried = 0;

	for (slot = 0; slot < conf->raid_disks * 2; slot++) {
		struct md_rdev *rdev = rk_rm_member(conf, slot);

		if (!rdev)
			continue;
		if (!only || rdev == only) {
			tried++;
			if (sync_page_io(rdev, rm->region + (sector_t)p * 8,
					 RK_RM_PAGE, rm->bounce,
					 REQ_OP_WRITE | REQ_SYNC | REQ_FUA,
					 false)) {
				ok++;
				atomic64_inc(&rm->page_writes);
			} else {
				atomic64_inc(&rm->write_errors);
				md_error(mddev, rdev);
			}
		}
		rdev_dec_pending(rdev, mddev);
	}
	if (!ok && !only && tried)
		pr_err_ratelimited("md/raid:%s: row map page %u reached no member\n",
				   mdname(mddev), p);
	return tried ? ok : -1;
}

/*
 * Write every page changed so far.  When it returns true, every change
 * made before it was called is on disk: a page another flush had already
 * taken was written by that flush, which held flush_mutex until it was
 * done.  False: a page reached no member although one was there to try
 * (each failed member is md_error()ed, so a retry tries fewer); the page
 * stays dirty and durable does not move, so nothing waiting for it goes
 * out.  With no member left at all there is nothing to protect and the
 * flush counts as done (the data writes go nowhere either).
 */
bool raidkm_rowmap_flush(struct r5conf *conf)
{
	struct raidkm_rowmap *rm = conf->rowmap;
	unsigned long *snap;
	unsigned int p;
	bool failed = false;
	u64 e, gen;

	if (!rm)
		return true;
	snap = bitmap_zalloc(rm->npages, GFP_NOIO);
	mutex_lock(&rm->flush_mutex);
	spin_lock_irq(&rm->lock);
	e = ++rm->epoch;
	if (snap) {
		bitmap_copy(snap, rm->dirty, rm->npages);
		bitmap_zero(rm->dirty, rm->npages);
	}
	spin_unlock_irq(&rm->lock);
	if (!snap) {
		/* no memory for the snapshot: write every page */
		spin_lock_irq(&rm->lock);
		bitmap_zero(rm->dirty, rm->npages);
		spin_unlock_irq(&rm->lock);
	} else if (bitmap_empty(snap, rm->npages)) {
		/* nothing changed since the last flush, which is done (we
		 * hold flush_mutex): only the epoch moves */
		goto done;
	}
	gen = ++rm->gen;
	for (p = 0; p < rm->npages; p++) {
		u8 *buf;

		if (snap && !test_bit(p, snap))
			continue;
		buf = page_address(rm->bounce);
		memset(buf, 0, RK_RM_PAGE);
		spin_lock_irq(&rm->lock);
		memcpy(buf, rm->map + (size_t)p * RK_RM_BODY, RK_RM_BODY);
		spin_unlock_irq(&rm->lock);
		rk_rm_seal(rm, buf, gen);
		if (!rk_rm_write_page(rm, p, NULL)) {
			spin_lock_irq(&rm->lock);
			__set_bit(p, rm->dirty);
			spin_unlock_irq(&rm->lock);
			failed = true;
		}
	}
done:
	if (!failed)
		smp_store_release(&rm->durable, e);
	atomic64_inc(&rm->flushes);
	mutex_unlock(&rm->flush_mutex);
	bitmap_free(snap);
	return !failed;
}

static void rk_rm_lazy_fn(struct work_struct *work)
{
	struct raidkm_rowmap *rm = container_of(to_delayed_work(work),
						struct raidkm_rowmap, lazy);

	raidkm_rowmap_flush(rm->conf);
}

/* ---- state changes --------------------------------------------------- */

/*
 * A write of [sector, sector + sectors) of the array is about to go out.
 * A row it covers whole becomes W; a row it covers in part and that was U
 * becomes N.  U -> anything is recorded as needing the next flush before
 * the row's member writes (rm->need); N/S -> W is lazy.  True when such a
 * U transition happened.
 */
bool raidkm_rowmap_note_write(struct r5conf *conf, sector_t sector,
			      unsigned int sectors)
{
	struct raidkm_rowmap *rm = conf->rowmap;
	u64 rs = raidkm_row_data_sectors(conf), first, last, r;
	u64 end = (u64)sector + sectors;
	bool change = false, durable = false, lazy = false;
	unsigned long flags;

	if (!rm || !sectors)
		return false;
	first = div64_u64(sector, rs);
	last = div64_u64(end - 1, rs);
	if (last >= rm->nrows)
		last = rm->nrows - 1;
	for (r = first; r <= last && !change; r++) {
		unsigned int st = rk_rm_get(rm, r);
		bool full = r * rs >= sector && (r + 1) * rs <= end;

		if (st == RK_RM_U || (st != RK_RM_W && full))
			change = true;
	}
	if (!change) {
		/*
		 * Every row is past U already, read without the lock: the
		 * writer that moved it stored need[] before the state
		 * (smp_wmb below), so the need[] raidkm_rowmap_stripe_start()
		 * reads next is at least that writer's.
		 */
		smp_rmb();
		return false;
	}

	spin_lock_irqsave(&rm->lock, flags);
	for (r = first; r <= last; r++) {
		unsigned int st = rk_rm_get(rm, r);
		bool full = r * rs >= sector && (r + 1) * rs <= end;

		if (st == RK_RM_U) {
			/* need[] first: a writer that sees the new state
			 * without the lock must also see the flush it needs */
			WRITE_ONCE(rm->need[rk_rm_page(r)], rm->epoch + 1);
			smp_wmb();
			rk_rm_set(rm, r, full ? RK_RM_W : RK_RM_N);
			atomic64_inc(full ? &rm->to_w : &rm->to_n);
			durable = true;
		} else if (st != RK_RM_W && full) {
			rk_rm_set(rm, r, RK_RM_W);
			atomic64_inc(&rm->to_w);
			lazy = true;
		}
	}
	spin_unlock_irqrestore(&rm->lock, flags);
	/* pairs with the barrier in raid5d's round (raid_km.c): either it
	 * sees the page dirty, or the stripe sees the later seq_flush */
	smp_mb();
	if (lazy && !durable)
		queue_delayed_work(system_wq, &rm->lazy, RK_RM_LAZY_DELAY);
	return durable;
}

/*
 * Device row @row was written whole, in several bios (none of them the
 * whole row: raidkm_rowmap_note_write() made it N): every stripe of it was
 * a reconstruct-write, so its parity is good everywhere -- W, lazily as
 * any N -> W.  The snapshot's COW of a row over one bio.
 */
void raidkm_rowmap_note_row_written(struct r5conf *conf, u64 row)
{
	struct raidkm_rowmap *rm = conf->rowmap;
	unsigned long flags;
	bool lazy = false;

	if (!rm || row >= rm->nrows)
		return;
	spin_lock_irqsave(&rm->lock, flags);
	if (rk_rm_get(rm, row) == RK_RM_N || rk_rm_get(rm, row) == RK_RM_S) {
		rk_rm_set(rm, row, RK_RM_W);
		atomic64_inc(&rm->to_w);
		lazy = true;
	}
	spin_unlock_irqrestore(&rm->lock, flags);
	if (lazy)
		queue_delayed_work(system_wq, &rm->lazy, RK_RM_LAZY_DELAY);
}

sector_t raidkm_tail_start(struct r5conf *conf)
{
	return conf->mddev->dev_sectors + (conf->dcl ? conf->chunk_sectors : 0);
}

/* rows [first_row, last_row) were discarded whole: content undefined */
void raidkm_rowmap_note_discard(struct r5conf *conf, u64 first_row,
				u64 last_row)
{
	struct raidkm_rowmap *rm = conf->rowmap;
	unsigned long flags;
	u64 r, n = 0;

	if (!rm)
		return;
	if (last_row > rm->nrows)
		last_row = rm->nrows;
	spin_lock_irqsave(&rm->lock, flags);
	for (r = first_row; r < last_row; r++) {
		if (rk_rm_get(rm, r) != RK_RM_U) {
			rk_rm_set(rm, r, RK_RM_U);
			n++;
		}
	}
	spin_unlock_irqrestore(&rm->lock, flags);
	if (n) {
		atomic64_add(n, &rm->to_u);
		queue_delayed_work(system_wq, &rm->lazy, RK_RM_LAZY_DELAY);
	}
}

/* @msect: a member sector of the stripe */
bool raidkm_rowmap_force_rcw(struct r5conf *conf, sector_t msect)
{
	struct raidkm_rowmap *rm = conf->rowmap;
	u64 row;

	if (!rm || rowmap_test_no_rcw)
		return false;
	row = div_u64(msect, rm->chunk_sectors);
	return row < rm->nrows && rk_rm_get(rm, row) != RK_RM_W;
}

/*
 * A write was linked to @sh (sh->stripe_lock held).  If the stripe's map
 * page has a change not yet on disk, park the stripe on bitmap_list until
 * raid5d's next round has flushed it -- the write-intent bitmap's own
 * mechanism (STRIPE_BIT_DELAY + bm_seq against seq_write).
 */
void raidkm_rowmap_stripe_start(struct r5conf *conf, struct stripe_head *sh)
{
	struct raidkm_rowmap *rm = conf->rowmap;
	u64 row = div_u64(sh->sector, rm->chunk_sectors);
	u64 need;
	struct stripe_head *h;
	int seq;

	if (row >= rm->nrows)
		return;
	need = READ_ONCE(rm->need[rk_rm_page(row)]);
	if ((s64)(need - smp_load_acquire(&rm->durable)) <= 0)
		return;
	smp_mb();	/* the page went dirty before seq_flush is read */
	seq = READ_ONCE(conf->seq_flush) + 1;
	h = sh->batch_head ? sh->batch_head : sh;
	WARN_ON_ONCE(sh->batch_head);
	if (test_bit(STRIPE_BIT_DELAY, &h->state) && h->bm_seq - seq > 0)
		seq = h->bm_seq;
	h->bm_seq = seq;
	set_bit(STRIPE_BIT_DELAY, &h->state);
	atomic64_inc(&rm->waits);
}

/* row path: the row's map page is on disk before its member writes */
void raidkm_rowmap_wait_row(struct r5conf *conf, sector_t msect)
{
	struct raidkm_rowmap *rm = conf->rowmap;
	u64 row, need;

	if (!rm)
		return;
	row = div_u64(msect, rm->chunk_sectors);
	if (row >= rm->nrows)
		return;
	need = READ_ONCE(rm->need[rk_rm_page(row)]);
	while ((s64)(need - smp_load_acquire(&rm->durable)) > 0) {
		atomic64_inc(&rm->waits);
		raidkm_rowmap_flush(conf);
	}
}

/*
 * Every row in state @from becomes @to, a page at a time so the lock is
 * never held over the whole map.  @persist: the change is written back
 * (lazily); otherwise it is in-core only (N -> S).
 */
static u64 rk_rm_convert(struct raidkm_rowmap *rm, unsigned int from,
			 unsigned int to, bool persist)
{
	unsigned int p;
	u64 n = 0;

	for (p = 0; p < rm->npages; p++) {
		u64 r = (u64)p * RK_RM_ROWS_PER_PAGE;
		u64 end = min_t(u64, rm->nrows, r + RK_RM_ROWS_PER_PAGE);

		spin_lock_irq(&rm->lock);
		for (; r < end; r++) {
			u8 *b;
			unsigned int sh;

			if (rk_rm_get(rm, r) != from)
				continue;
			if (persist) {
				rk_rm_set(rm, r, to);
			} else {
				b = rk_rm_byte(rm, r);
				sh = (r & 3) * 2;
				WRITE_ONCE(*b, (*b & ~(3 << sh)) | (to << sh));
			}
			n++;
		}
		spin_unlock_irq(&rm->lock);
		cond_resched();
	}
	return n;
}

/* ---- sync passes ----------------------------------------------------- */

static bool rk_rm_skippable(struct mddev *mddev, unsigned int st)
{
	if (st == RK_RM_U)
		return true;
	/* check: an N/S row is not consistent outside what was written, so
	 * it would only report mismatches; a repair or resync makes it W */
	return test_bit(MD_RECOVERY_CHECK, &mddev->recovery) &&
	       (st == RK_RM_N || st == RK_RM_S);
}

/*
 * A recovery skips a U row, then a write turns it N before the member's
 * recovery_offset has passed it: the stripe path treats the member as
 * failed there (computes its chunk from parity, does not write it), and
 * the pass never comes back.  Once in sync, the member's chunk does not
 * match the parity the write built, and a second failure rebuilds the
 * written data wrong.  So a row the pass skipped is in sync on the member
 * being rebuilt -- its content is as undefined there as anywhere -- and a
 * later write treats it so (reads it for the reconstruct-write, writes it).
 * The bits are set under rm->lock with the U check, the same lock
 * raidkm_rowmap_note_write() moves a row out of U under, and every stripe
 * of such a write is looked at after that.  Cleared when a member is
 * added and when a pass starts from 0; a resumed pass keeps them, they lie
 * below the recovery_offset of the members the earlier pass rebuilt.
 */
bool raidkm_rowmap_rec_skipped(struct r5conf *conf, sector_t msect)
{
	struct raidkm_rowmap *rm = conf->rowmap;
	u64 row = div_u64(msect, rm->chunk_sectors);

	return !rowmap_test_no_recskip && row < rm->nrows &&
	       test_bit(row, rm->rec_skipped);
}

/* a member joins: no row is skipped on it yet */
void raidkm_rowmap_member_added(struct r5conf *conf)
{
	struct raidkm_rowmap *rm = conf->rowmap;

	spin_lock_irq(&rm->lock);
	bitmap_zero(rm->rec_skipped, rm->nrows);
	spin_unlock_irq(&rm->lock);
}

/* a replacement being built: it is written beside a member that is in sync
 * (ops_run_io), and a reconstruct-write reads the member, not it -- a
 * skipped row would leave chunks there that the parity does not cover */
static bool rk_rm_replacing(struct r5conf *conf)
{
	struct md_rdev *rdev;
	bool r = false;
	int i;

	rcu_read_lock();
	for (i = 0; i < conf->raid_disks && !r; i++) {
		rdev = READ_ONCE(conf->disks[i].replacement);
		r = rdev && !test_bit(Faulty, &rdev->flags);
	}
	rcu_read_unlock();
	return r;
}

/* a new member gets every page before the pass that rebuilds it */
static void rk_rm_seed(struct r5conf *conf)
{
	struct raidkm_rowmap *rm = conf->rowmap;
	unsigned int p;
	int slot;

	raidkm_rowmap_flush(conf);
	/* the snapshot metadata too: written whole to every member */
	raidkm_snap_seed(conf);
	mutex_lock(&rm->flush_mutex);
	for (slot = 0; slot < conf->raid_disks * 2; slot++) {
		struct md_rdev *rdev = rk_rm_member(conf, slot);

		if (!rdev)
			continue;
		if (!test_bit(In_sync, &rdev->flags)) {
			for (p = 0; p < rm->npages; p++) {
				u8 *buf = page_address(rm->bounce);

				memset(buf, 0, RK_RM_PAGE);
				spin_lock_irq(&rm->lock);
				memcpy(buf, rm->map + (size_t)p * RK_RM_BODY,
				       RK_RM_BODY);
				spin_unlock_irq(&rm->lock);
				rk_rm_seal(rm, buf, rm->gen);
				rk_rm_write_page(rm, p, rdev);
			}
			pr_info("md/raid:%s: row map: %u page(s) written to %pg before its rebuild\n",
				mdname(conf->mddev), rm->npages, rdev->bdev);
		}
		rdev_dec_pending(rdev, conf->mddev);
	}
	mutex_unlock(&rm->flush_mutex);
}

/* declustered copy-back: the replacement gets every page before the copy
 * (a stock recovery seeds from raidkm_rowmap_sync_skip()) */
void raidkm_rowmap_seed(struct r5conf *conf)
{
	rk_rm_seed(conf);
}

/*
 * At the top of raid5_sync_request: how many sectors from @sector_nr the
 * pass may skip (0 = none).  At the start of a full pass it also seeds a
 * member being rebuilt, or marks N rows S for a resync/repair.
 */
sector_t raidkm_rowmap_sync_skip(struct mddev *mddev, sector_t sector_nr,
				 sector_t max_sector)
{
	struct r5conf *conf = mddev->private;
	struct raidkm_rowmap *rm = conf->rowmap;
	bool sync = test_bit(MD_RECOVERY_SYNC, &mddev->recovery);
	u64 row, r, lim;
	unsigned int cs;

	if (!rm || test_bit(MD_RECOVERY_RESHAPE, &mddev->recovery))
		return 0;
	cs = rm->chunk_sectors;
	if (sector_nr == 0) {
		if (!sync) {
			spin_lock_irq(&rm->lock);
			bitmap_zero(rm->rec_skipped, rm->nrows);
			spin_unlock_irq(&rm->lock);
			rk_rm_seed(conf);
		} else if (!test_bit(MD_RECOVERY_CHECK, &mddev->recovery) &&
			   !rm->pass_marked && !mddev->degraded) {
			/* in-core only: S is written back as it is and
			 * every path treats it as N */
			u64 n = rk_rm_convert(rm, RK_RM_N, RK_RM_S, false);

			rm->pass_marked = true;
			if (n)
				pr_info("md/raid:%s: row map: %llu row(s) to sync\n",
					mdname(mddev), n);
		}
	}
	/* a resync that cannot run (too many members gone) syncs nothing */
	if (rm->pass_marked && mddev->degraded >= conf->max_degraded)
		rm->pass_marked = false;

	row = div_u64(sector_nr, cs);
	lim = min_t(u64, rm->nrows, div_u64(max_sector + cs - 1, cs));
	if (!sync) {
		/* recovery: see raidkm_rowmap_rec_skipped() */
		if (rk_rm_replacing(conf))
			return 0;
		lim = min_t(u64, lim, row + RK_RM_ROWS_PER_PAGE);
		spin_lock_irq(&rm->lock);
		for (r = row; r < lim && rk_rm_get(rm, r) == RK_RM_U; r++)
			__set_bit(r, rm->rec_skipped);
		spin_unlock_irq(&rm->lock);
	} else {
		lim = min_t(u64, lim, row + (1 << 20));
		for (r = row;
		     r < lim && rk_rm_skippable(mddev, rk_rm_get(rm, r)); r++)
			;
	}
	if (r == row)
		return 0;
	atomic64_add(r - row, &rm->skipped_rows);
	return min_t(sector_t, r * cs, max_sector) - sector_nr;
}

/* where the next skippable row starts at or after @sector_nr (row engine
 * look-ahead), @end if none before it */
sector_t raidkm_rowmap_run_end(struct mddev *mddev, sector_t sector_nr,
			       sector_t end)
{
	struct r5conf *conf = mddev->private;
	struct raidkm_rowmap *rm = conf->rowmap;
	unsigned int cs;
	u64 r, lim;

	if (!rm)
		return end;
	cs = rm->chunk_sectors;
	lim = min_t(u64, rm->nrows, div_u64(end + cs - 1, cs));
	/* recovery skips nothing while a replacement is built (sync_skip) */
	if (!test_bit(MD_RECOVERY_SYNC, &mddev->recovery) &&
	    rk_rm_replacing(conf))
		return end;
	for (r = div_u64(sector_nr, cs); r < lim; r++)
		if (rk_rm_skippable(mddev, rk_rm_get(rm, r)))
			return max_t(sector_t, sector_nr,
				     min_t(sector_t, r * cs, end));
	return end;
}

/* the final call of a pass: a complete resync/repair made S rows W */
void raidkm_rowmap_pass_end(struct mddev *mddev, sector_t max_sector)
{
	struct r5conf *conf = mddev->private;
	struct raidkm_rowmap *rm = conf->rowmap;
	u64 n;

	if (!rm || !rm->pass_marked)
		return;
	rm->pass_marked = false;
	if (test_bit(MD_RECOVERY_INTR, &mddev->recovery) ||
	    max_sector < mddev->dev_sectors)
		return;
	/*
	 * Only a pass that synced every stripe of every S row: with a
	 * write-intent bitmap an unrequested resync (unclean shutdown) skips
	 * each bitmap-clean region (raid5_sync_request, the row engine's
	 * raidkm_row_bitmap_run_end), and an N row's stripes nobody wrote
	 * are exactly those -- their parity is still garbage.  A requested
	 * repair or a full sync (conf->fullsync) syncs everything.
	 */
	if (mddev->bitmap && !conf->fullsync &&
	    !test_bit(MD_RECOVERY_REQUESTED, &mddev->recovery)) {
		rk_rm_convert(rm, RK_RM_S, RK_RM_N, false);
		return;
	}
	n = rk_rm_convert(rm, RK_RM_S, RK_RM_W, true);
	if (n) {
		atomic64_add(n, &rm->promoted);
		queue_delayed_work(system_wq, &rm->lazy, RK_RM_LAZY_DELAY);
	}
}

/* ---- setup ------------------------------------------------------------- */

static void rk_rm_load(struct raidkm_rowmap *rm)
{
	struct r5conf *conf = rm->conf;
	struct mddev *mddev = conf->mddev;
	u8 *buf = page_address(rm->bounce);
	unsigned int p, damaged = 0, loaded = 0;

	for (p = 0; p < rm->npages; p++) {
		u64 best = 0, gen;
		bool have = false, bad = false;
		int slot;

		for (slot = 0; slot < conf->raid_disks * 2; slot++) {
			struct md_rdev *rdev = rk_rm_member(conf, slot);
			int ok;

			if (!rdev)
				continue;
			/*
			 * In-sync members only: every flush reaches each of
			 * them, so their best copy is the newest.  A member
			 * not (yet) in sync -- re-added, recovering -- may hold
			 * pages from before it left, and after a forced or
			 * degraded assemble those can carry a HIGHER gen than
			 * anything written since (the counter restarted from
			 * the members present), i.e. win with rows U that now
			 * hold data.  It gets every page at its rebuild.
			 */
			if (rdev->raid_disk < 0 ||
			    !test_bit(In_sync, &rdev->flags)) {
				rdev_dec_pending(rdev, mddev);
				continue;
			}
			/*
			 * A read error is not a blank page: the page may have
			 * been written.  With no valid copy on any in-sync
			 * member, an unreadable one loads the page as all N,
			 * never zeroed (all U) -- even when the others read
			 * blank.  Deliberately cautious: the cost is a resync
			 * of rows that may hold nothing, after a read error at
			 * assemble.
			 */
			if (!sync_page_io(rdev, rm->region + (sector_t)p * 8,
					  RK_RM_PAGE, rm->bounce, REQ_OP_READ,
					  false)) {
				bad = true;
			} else {
				ok = rk_rm_check(rm, buf, &gen);
				if (ok < 0)
					bad = true;
				if (ok > 0 && (!have || gen > best)) {
					memcpy(rm->map + (size_t)p * RK_RM_BODY,
					       buf, RK_RM_BODY);
					best = gen;
					have = true;
				}
			}
			rdev_dec_pending(rdev, mddev);
		}
		if (have) {
			loaded++;
			if (best > rm->gen)
				rm->gen = best;
		} else if (bad) {
			/* written once, now unreadable or another id's: every
			 * row in it may hold data, none can be trusted synced */
			memset(rm->map + (size_t)p * RK_RM_BODY, 0x55,
			       RK_RM_BODY);
			damaged++;
		}
	}
	pr_info("md/raid:%s: row map: %llu rows, %u page(s), %u loaded, %u damaged (all rows N), generation %llu\n",
		mdname(mddev), rm->nrows, rm->npages, loaded, damaged, rm->gen);
}

int raidkm_rowmap_init(struct r5conf *conf)
{
	struct mddev *mddev = conf->mddev;
	struct raidkm_rowmap *rm;
	struct md_rdev *rdev;

	if (raid5_has_log(conf) ||
	    raid5_has_ppl(conf) || test_bit(MD_HAS_JOURNAL, &mddev->flags) ||
	    test_bit(MD_HAS_PPL, &mddev->flags) ||
	    mddev->reshape_position != MaxSector) {
		pr_err("md/raid:%s: row map: not supported with a journal/PPL or a reshape\n",
		       mdname(mddev));
		return -EINVAL;
	}
	rm = kzalloc(sizeof(*rm), GFP_KERNEL);
	if (!rm)
		return -ENOMEM;
	rm->conf = conf;
	spin_lock_init(&rm->lock);
	mutex_init(&rm->flush_mutex);
	INIT_DELAYED_WORK(&rm->lazy, rk_rm_lazy_fn);
	rm->chunk_sectors = conf->chunk_sectors;
	rm->nrows = div_u64(mddev->dev_sectors, conf->chunk_sectors);
	rm->npages = DIV_ROUND_UP_ULL(rm->nrows, RK_RM_ROWS_PER_PAGE);
	/* after the data; declustered: after the rkdcl chunk, which sits
	 * at dev_sectors (raidkm_csum_region() makes the same step); with
	 * native checksums after their region, which then has a fixed size
	 * (raidkm_csum_reserve_sectors(), mdadm rkrm_off1() the same) */
	rm->region = raidkm_tail_start(conf);
	if (raidkm_layout_has_csum(mddev->new_layout))
		rm->region += raidkm_csum_reserve_sectors(mddev->dev_sectors);
	rm->id = crc32c(0, mddev->uuid, sizeof(mddev->uuid));

	rdev_for_each(rdev, mddev) {
		if (rdev->raid_disk < 0 || !rdev->bdev)
			continue;
		/* metadata 1.0 keeps its superblock (and bitmap) at the
		 * end of the device, where the map would go */
		if (rdev->sb_start > rdev->data_offset) {
			pr_err("md/raid:%s: row map: needs metadata 1.1/1.2 (%pg has its superblock at the end)\n",
			       mdname(mddev), rdev->bdev);
			kfree(rm);
			return -EINVAL;
		}
		if (bdev_nr_sectors(rdev->bdev) <
		    rdev->data_offset + rm->region + (sector_t)rm->npages * 8) {
			pr_err("md/raid:%s: row map: %pg has no room for the %u-page map after the data\n",
			       mdname(mddev), rdev->bdev, rm->npages);
			kfree(rm);
			return -EINVAL;
		}
	}
	rm->map = vzalloc((size_t)rm->npages * RK_RM_BODY);
	rm->dirty = rk_bitmap_zalloc(rm->npages);
	rm->rec_skipped = rk_bitmap_zalloc(rm->nrows);
	rm->need = kvcalloc(rm->npages, sizeof(*rm->need), GFP_KERNEL);
	rm->bounce = alloc_page(GFP_KERNEL);
	if (!rm->map || !rm->dirty || !rm->rec_skipped || !rm->need ||
	    !rm->bounce) {
		conf->rowmap = rm;
		raidkm_rowmap_free(conf);
		return -ENOMEM;
	}
	conf->rowmap = rm;
	rk_rm_load(rm);
	return 0;
}

/* clean stop: everything on disk */
void raidkm_rowmap_stop(struct r5conf *conf)
{
	struct raidkm_rowmap *rm = conf->rowmap;

	if (!rm)
		return;
	cancel_delayed_work_sync(&rm->lazy);
	if (!bitmap_empty(rm->dirty, rm->npages))
		raidkm_rowmap_flush(conf);
}

void raidkm_rowmap_free(struct r5conf *conf)
{
	struct raidkm_rowmap *rm = conf->rowmap;

	if (!rm)
		return;
	cancel_delayed_work_sync(&rm->lazy);
	vfree(rm->map);
	rk_bitmap_free(rm->dirty);
	rk_bitmap_free(rm->rec_skipped);
	kvfree(rm->need);
	if (rm->bounce)
		__free_page(rm->bounce);
	kfree(rm);
	conf->rowmap = NULL;
}

/* ---- sysfs: rk_rowmap ---------------------------------------------- */

ssize_t raidkm_rowmap_show(struct mddev *mddev, char *page)
{
	struct r5conf *conf;
	struct raidkm_rowmap *rm;
	u64 cnt[4] = { 0 }, r;
	s64 csum_region, snap_region;
	ssize_t ret;

	ret = mddev_lock(mddev);
	if (ret)
		return ret;
	conf = mddev->private;
	if (!conf || !conf->rowmap) {
		mddev_unlock(mddev);
		return sprintf(page, "off\n");
	}
	rm = conf->rowmap;
	for (r = 0; r < rm->nrows; r++)
		cnt[rk_rm_get(rm, r)]++;
	/*
	 * Where the tail regions start on every member, in sectors from its
	 * data_offset (-1: none): the CRCs (raidkm_csum_region()), the row map
	 * (rm->region), the snapshot metadata (raidkm_snap's region).  Tools
	 * and tests read these instead of repeating the reserve arithmetic.
	 * csum_region is -1 also when a member has no room for the CRCs.
	 */
	csum_region = raidkm_csum_region_start(conf);
	snap_region = conf->snap ? (s64)conf->snap->region : -1;
	ret = sprintf(page,
		      "rows %llu\nunwritten %llu\nneedsync %llu\nsyncing %llu\nwritten %llu\n"
		      "to_n %lld\nto_w %lld\nto_u %lld\npromoted %lld\nskipped_rows %lld\n"
		      "flushes %lld\npage_writes %lld\nwrite_errors %lld\nwaits %lld\n"
		      "pages %u\ngeneration %llu\nmember_discard %d\n"
		      "csum_region %lld\nmap_region %llu\nsnap_region %lld\n",
		      rm->nrows, cnt[RK_RM_U], cnt[RK_RM_N], cnt[RK_RM_S],
		      cnt[RK_RM_W],
		      atomic64_read(&rm->to_n), atomic64_read(&rm->to_w),
		      atomic64_read(&rm->to_u), atomic64_read(&rm->promoted),
		      atomic64_read(&rm->skipped_rows),
		      atomic64_read(&rm->flushes), atomic64_read(&rm->page_writes),
		      atomic64_read(&rm->write_errors), atomic64_read(&rm->waits),
		      rm->npages, rm->gen, rm->member_discard,
		      csum_region, (unsigned long long)rm->region, snap_region);
	mddev_unlock(mddev);
	return ret;
}

/* "flush": write every changed page now */
ssize_t raidkm_rowmap_store(struct mddev *mddev, const char *page, size_t len)
{
	struct r5conf *conf;
	int err;

	if (!sysfs_streq(page, "flush"))
		return -EINVAL;
	err = mddev_lock(mddev);
	if (err)
		return err;
	conf = mddev->private;
	if (!conf || !conf->rowmap)
		err = -ENODEV;
	else
		raidkm_rowmap_flush(conf);
	mddev_unlock(mddev);
	return err ?: len;
}
