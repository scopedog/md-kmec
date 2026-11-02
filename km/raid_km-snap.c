// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * raidkm native snapshots: the I/O paths, the snapshot devices and the
 * commands.  What is on disk: raid_km-snapmeta.c.  See raid_km_snap.h and
 * notes/md-kmec/native-snapshot-p2-design-2026-10-31.md.
 *
 * Origin rows L (what /dev/mdX exports) map to physical rows P (the whole
 * array; rows past the origin are the reserve).  A linear chain of
 * read-only snapshots; the first write to a row the newest snapshot shares
 * redirects it to a free row, whole: a full-row write is remapped there as
 * it is, a partial write is merged into a copy of the old row by a worker.
 * Either way the origin write is acked only after the journal record that
 * moves the old row to the newest snapshot is durable, and the in-core maps
 * change only then (rk_snap_apply, on the commit worker): until then a
 * read of L sees the old row, a later write to L waits for the COW.
 *
 * A physical bio (an origin bio once remapped, a copy, a snapshot read)
 * carries BIO_REMAPPED, as a partition's bio does once blk_partition_remap()
 * moved it: submit_bio_noacct() then skips the end-of-device check (the
 * reserve lies past the exported capacity), a same-device clone or split
 * inherits the flag, so raidkm's own splits and resubmits keep it, and
 * raidkm_snap_map_bio() does not remap it twice.  bio_set_dev() clears it.
 * md partitions would arrive flagged too, so they are off on these arrays.
 *
 * Physical bios raidkm builds itself (row copies) go to md_handle_request()
 * directly, so they are cut here to what a bio from the queue can be: at
 * most sn->piece pages (BIO_MAX_VECS, and the md queue's max_hw_sectors,
 * which the request context's stripe bitmap is sized from).
 *
 * Create and destroy: set hold (no new COW starts; writes that would start
 * one wait on the overflow list), wait for the COWs in flight to finish
 * (a partial COW's copy goes through md_handle_request, so this comes
 * before the suspend), suspend the array, then the journal record.
 *
 * Lifetime: every rk_snap sysfs command and every open snapshot disk holds
 * one of md's openers (as an open of /dev/mdX does), so stopping the array
 * fails with -EBUSY meanwhile instead of freeing conf and sn under them.
 */
#include <linux/blkdev.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/bitmap.h>
#include <linux/math64.h>
#include <linux/completion.h>
#include <linux/highmem.h>
#include <linux/timekeeping.h>
#include <linux/sched.h>
#include <linux/delay.h>

#include "md.h"
#include "raid_km.h"
#include "raid_km_rowmap.h"
#include "raid_km_snap.h"

/* test only: a stop writes no checkpoint, so the next assemble has to get
 * everything since the last one from the journal (as after a crash) */
static bool snap_test_no_stop_ckpt;
module_param(snap_test_no_stop_ckpt, bool, 0644);
MODULE_PARM_DESC(snap_test_no_stop_ckpt, "test only: no checkpoint at stop (the next assemble replays the journal)");

/* one row of pages for a read-merge-write */
struct rk_rowbuf {
	unsigned int		n;
	struct page		*pages[];
};

static struct block_device *rk_md_bdev(struct raidkm_snap *sn)
{
	return sn->conf->mddev->gendisk->part0;
}

/* ---- md openers: keep the array from being stopped ------------------- */

/* as md_open(): fails once a stop has begun (MD_CLOSING) */
static int rk_md_pin(struct mddev *mddev)
{
	int err = 0;

	mutex_lock(&mddev->open_mutex);
	if (test_bit(MD_CLOSING, &mddev->flags))
		err = -EBUSY;
	else
		atomic_inc(&mddev->openers);
	mutex_unlock(&mddev->open_mutex);
	return err;
}

static void rk_md_unpin(struct mddev *mddev)
{
	atomic_dec(&mddev->openers);
}

/* ---- physical I/O ------------------------------------------------------ */

static void rk_phys_endio(struct bio *bio)
{
	complete(bio->bi_private);
}

static void rk_phys_submit(struct raidkm_snap *sn, struct bio *bio)
{
	bio_set_dev(bio, rk_md_bdev(sn));
	bio_set_flag(bio, BIO_REMAPPED);
	md_handle_request(sn->conf->mddev, bio);
}

/* send a physical bio (and whatever is chained to it) and wait for it */
static blk_status_t rk_phys_wait(struct raidkm_snap *sn, struct bio *bio)
{
	DECLARE_COMPLETION_ONSTACK(done);

	bio->bi_private = &done;
	bio->bi_end_io = rk_phys_endio;
	rk_phys_submit(sn, bio);
	wait_for_completion_io(&done);
	return bio->bi_status;
}

/*
 * Read or write a whole row between b and physical row P, in bios of at
 * most sn->piece pages, each chained into the next; the last one is waited
 * for, and carries the first error of any.
 */
static blk_status_t rk_row_io(struct raidkm_snap *sn, blk_opf_t opf,
			      struct rk_rowbuf *b, u64 P)
{
	struct bio *prev = NULL, *bio;
	unsigned int i = 0, j, n;
	blk_status_t st;

	while (i < b->n) {
		n = min(b->n - i, sn->piece);
		bio = bio_alloc_bioset(rk_md_bdev(sn), n, opf, GFP_NOIO,
				       &sn->bs);
		bio->bi_iter.bi_sector = P * sn->rs +
					 ((sector_t)i << (PAGE_SHIFT - 9));
		for (j = 0; j < n; j++)
			__bio_add_page(bio, b->pages[i + j], PAGE_SIZE, 0);
		i += n;
		if (prev) {
			bio_chain(prev, bio);
			rk_phys_submit(sn, prev);
		}
		prev = bio;
	}
	st = rk_phys_wait(sn, prev);
	bio_put(prev);
	return st;
}

static void *rk_rowbuf_alloc(gfp_t gfp, void *data)
{
	unsigned int n = (unsigned long)data, i;
	struct rk_rowbuf *b = kvmalloc(struct_size(b, pages, n), gfp);

	if (!b)
		return NULL;
	b->n = n;
	for (i = 0; i < n; i++) {
		b->pages[i] = alloc_page(gfp);
		if (!b->pages[i]) {
			while (i--)
				__free_page(b->pages[i]);
			kvfree(b);
			return NULL;
		}
	}
	return b;
}

static void rk_rowbuf_free(void *elem, void *data)
{
	struct rk_rowbuf *b = elem;
	unsigned int i;

	for (i = 0; i < b->n; i++)
		__free_page(b->pages[i]);
	kvfree(b);
}

/*
 * The write's data into the row buffer at byte pos.  A segment is cut where
 * a buffer page ends: a write need not be page aligned in the row (512 B
 * sectors).  WRITE_ZEROES has no data: its range becomes zeroes.
 */
static void rk_merge(struct rk_rowbuf *b, struct bio *bi, size_t pos)
{
	struct bvec_iter it;
	struct bio_vec bv;
	unsigned int po, n, done;

	if (bio_op(bi) == REQ_OP_WRITE_ZEROES) {
		size_t end = pos + bi->bi_iter.bi_size;

		while (pos < end) {
			po = pos & ~PAGE_MASK;
			n = min_t(size_t, end - pos, PAGE_SIZE - po);
			memset(page_address(b->pages[pos >> PAGE_SHIFT]) + po,
			       0, n);
			pos += n;
		}
		return;
	}
	bio_for_each_segment(bv, bi, it) {
		for (done = 0; done < bv.bv_len; done += n, pos += n) {
			po = pos & ~PAGE_MASK;
			n = min_t(unsigned int, bv.bv_len - done, PAGE_SIZE - po);
			memcpy_from_page(page_address(b->pages[pos >> PAGE_SHIFT]) + po,
					 bv.bv_page, bv.bv_offset + done, n);
		}
	}
}

/* a free physical row, or U64_MAX; sn->lock held */
static u64 rk_alloc_row(struct raidkm_snap *sn)
{
	u64 p = find_next_zero_bit(sn->used, sn->R, sn->cursor);

	if (p >= sn->R)
		p = find_first_zero_bit(sn->used, sn->R);
	if (p >= sn->R)
		return U64_MAX;
	__set_bit(p, sn->used);
	sn->cursor = p + 1;
	return p;
}

static struct raidkm_snap_one *rk_newest(struct raidkm_snap *sn)
{
	return list_empty(&sn->snaps) ? NULL :
	       list_last_entry(&sn->snaps, struct raidkm_snap_one, list);
}

/* the COW in flight for row L, or NULL; sn->lock held */
static struct rk_snap_cow *rk_busy_find(struct raidkm_snap *sn, u64 L)
{
	struct rk_snap_cow *c;

	hash_for_each_possible(sn->busy, c, node, L)
		if (c->L == L)
			return c;
	return NULL;
}


struct raidkm_snap_one *rk_snap_slot(struct raidkm_snap *sn, u8 slot)
{
	struct raidkm_snap_one *g;

	list_for_each_entry(g, &sn->snaps, list)
		if (g->slot == slot)
			return g;
	return NULL;
}

/* ---- COW ------------------------------------------------------------------ */

static void rk_snap_pend(struct raidkm_snap *sn, struct rk_snap_op *op)
{
	unsigned long flags;

	spin_lock_irqsave(&sn->lock, flags);
	list_add_tail(&op->node, &sn->pending);
	spin_unlock_irqrestore(&sn->lock, flags);
	queue_work(sn->cwq, &sn->commit_work);
}

/*
 * The COW is over: committed (the maps already say so), failed before
 * anything was recorded (undo: newP is free again), or the commit failed
 * (newP stays taken: a record naming it may be on a member).  End the
 * origin write, free the slot, send again what waited for it.  The commit
 * or COW worker; never with sn->lock held.
 */
void rk_snap_cow_finish(struct raidkm_snap *sn, struct rk_snap_cow *c,
			blk_status_t st, bool undo)
{
	struct bio *bi = c->bio, *w;
	struct bio_list again;
	unsigned long flags;

	bio_list_init(&again);
	spin_lock_irqsave(&sn->lock, flags);
	if (undo)
		__clear_bit(c->op.newP, sn->used);
	hash_del(&c->node);
	bio_list_merge(&again, &c->waiters);
	if (!sn->hold) {
		bio_list_merge(&again, &sn->overflow);
		bio_list_init(&sn->overflow);
	}
	__clear_bit(c - sn->cow, sn->cow_busy);
	spin_unlock_irqrestore(&sn->lock, flags);
	if (st)
		atomic64_inc(st == BLK_STS_NOSPC ? &sn->cow_nospc : &sn->cow_fail);
	bi->bi_status = st;
	bio_endio(bi);
	while ((w = bio_list_pop(&again)))
		submit_bio_noacct(w);
	if (atomic_dec_and_test(&sn->cows))
		wake_up_all(&sn->drain_wq);
}

/* a whole-row COW's data write is done: on to the commit (irq context) */
static void rk_cow_whole_endio(struct bio *bi)
{
	struct rk_snap_cow *c = bi->bi_private;

	bi->bi_end_io = c->end_io;
	bi->bi_private = c->private;
	c->op.status = bi->bi_status;
	rk_snap_pend(c->sn, &c->op);
}

/* a partial write to a shared row: read the old row, merge, write it whole */
static void rk_cow_fn(struct work_struct *work)
{
	struct rk_snap_cow *c = container_of(work, struct rk_snap_cow, work);
	struct raidkm_snap *sn = c->sn;
	struct bio *bi = c->bio;
	u64 L = c->L, oldP, newP;
	sector_t off = bi->bi_iter.bi_sector - L * sn->rs;
	struct rk_rowbuf *b;
	blk_status_t st;

	spin_lock_irq(&sn->lock);
	oldP = sn->origin[L];
	newP = rk_alloc_row(sn);
	spin_unlock_irq(&sn->lock);
	if (newP == U64_MAX) {
		rk_snap_cow_finish(sn, c, BLK_STS_NOSPC, false);
		return;
	}
	/* from the pool: waits for a buffer rather than fail the write */
	b = mempool_alloc(sn->buf_pool, GFP_NOIO);
	st = rk_row_io(sn, REQ_OP_READ, b, oldP);
	if (!st) {
		rk_merge(b, bi, (size_t)off << 9);
		st = rk_row_io(sn, REQ_OP_WRITE, b, newP);
	}
	mempool_free(b, sn->buf_pool);
	atomic64_inc(&sn->cow_partial);
	c->op.type = RK_OP_REDIRECT;
	c->op.L = L;
	c->op.oldP = oldP;
	c->op.newP = newP;
	c->op.status = st;
	rk_snap_pend(sn, &c->op);
}

/*
 * raid5_make_request(), before anything else: remap an origin bio to its
 * physical row, or take a write to a shared row for a COW.  RK_SNAP_DONE:
 * the bio is ours now.  *bip may change: a bio across a row boundary is
 * split there, the rest goes back to the queue.
 *
 * Runs inside md_handle_request(), i.e. with active_io held: nsnaps only
 * changes with the array suspended, so it is stable here, and nothing here
 * may wait (a create/destroy's suspend waits for us).
 */
int raidkm_snap_map_bio(struct r5conf *conf, struct bio **bip)
{
	struct raidkm_snap *sn = conf->snap;
	struct bio *bi = *bip;
	struct rk_snap_cow *c;
	sector_t s = bi->bi_iter.bi_sector, off;
	u64 L, P, newP = U64_MAX;
	unsigned long flags;
	unsigned int i;
	bool whole;

	if (bio_flagged(bi, BIO_REMAPPED) || !bio_sectors(bi))
		return RK_SNAP_GO;
	if (bio_op(bi) == REQ_OP_DISCARD) {
		/* a discard is only a hint, and rows may be shared */
		bio_endio(bi);
		return RK_SNAP_DONE;
	}
	L = div64_u64(s, sn->rs);
	if (L >= sn->O) {
		pr_err_ratelimited("md/raid:%s: snap: bio %llu+%u past the origin\n",
				   mdname(conf->mddev), (unsigned long long)s,
				   bio_sectors(bi));
		bio_io_error(bi);
		return RK_SNAP_DONE;
	}
	if (bio_end_sector(bi) > (L + 1) * sn->rs) {
		/* the queue splits at min(row, bio cap): a member's transfer
		 * cap below the row cuts bios across rows */
		struct bio *split = bio_split(bi, (L + 1) * sn->rs - s,
					      GFP_NOIO, &conf->bio_split);

		if (IS_ERR_OR_NULL(split)) {
			bi->bi_status = BLK_STS_RESOURCE;
			bio_endio(bi);
			return RK_SNAP_DONE;
		}
		bio_chain(split, bi);
		submit_bio_noacct(bi);
		*bip = bi = split;
	}
	off = s - L * sn->rs;
	if (!op_is_write(bio_op(bi)) || !sn->nsnaps) {
		/* no snapshot: nothing shared, no COW in flight, the map
		 * changes only with a COW */
		P = READ_ONCE(sn->origin[L]);
		goto remap;
	}

	spin_lock_irqsave(&sn->lock, flags);
	c = rk_busy_find(sn, L);
	if (c) {
		bio_list_add(&c->waiters, bi);
		spin_unlock_irqrestore(&sn->lock, flags);
		return RK_SNAP_DONE;
	}
	if (!test_bit(L, sn->shared)) {
		P = sn->origin[L];
		spin_unlock_irqrestore(&sn->lock, flags);
		goto remap;
	}
	if (unlikely(sn->broken)) {
		/* no record can be written: a copy would only take a row */
		spin_unlock_irqrestore(&sn->lock, flags);
		atomic64_inc(&sn->cow_fail);
		bio_io_error(bi);
		return RK_SNAP_DONE;
	}
	i = find_first_zero_bit(sn->cow_busy, RK_SNAP_COWS);
	if (sn->hold || i >= RK_SNAP_COWS) {
		/* a create/destroy is waiting for the COWs to drain, or every
		 * slot is busy: the next COW to end (or the unhold) sends it
		 * again */
		bio_list_add(&sn->overflow, bi);
		spin_unlock_irqrestore(&sn->lock, flags);
		return RK_SNAP_DONE;
	}
	whole = !off && bio_sectors(bi) == sn->rs;
	if (whole) {
		newP = rk_alloc_row(sn);
		if (newP == U64_MAX) {
			spin_unlock_irqrestore(&sn->lock, flags);
			atomic64_inc(&sn->cow_nospc);
			bi->bi_status = BLK_STS_NOSPC;
			bio_endio(bi);
			return RK_SNAP_DONE;
		}
	}
	__set_bit(i, sn->cow_busy);
	c = &sn->cow[i];
	c->bio = bi;
	c->L = L;
	bio_list_init(&c->waiters);
	hash_add(sn->busy, &c->node, L);
	atomic_inc(&sn->cows);
	if (!whole) {
		spin_unlock_irqrestore(&sn->lock, flags);
		queue_work(sn->wq, &c->work);
		return RK_SNAP_DONE;
	}
	c->op.type = RK_OP_REDIRECT;
	c->op.L = L;
	c->op.oldP = sn->origin[L];
	c->op.newP = newP;
	spin_unlock_irqrestore(&sn->lock, flags);
	/* the write goes on to the new row as it is; its completion is the
	 * COW's, and the origin write ends after the commit */
	c->end_io = bi->bi_end_io;
	c->private = bi->bi_private;
	bi->bi_end_io = rk_cow_whole_endio;
	bi->bi_private = c;
	atomic64_inc(&sn->cow_whole);
	P = newP;
remap:
	bi->bi_iter.bi_sector = P * sn->rs + off;
	bio_set_flag(bi, BIO_REMAPPED);
	return RK_SNAP_GO;
}

/* ---- applying a journal op to the in-core state ---------------------------- */

/*
 * The one place the maps and the chain change: on the commit worker once
 * the op's record is durable, or at assemble while replaying (replay: no
 * I/O runs, a CREATE's g was allocated by the parser, a destroyed g is
 * freed here).  rk_sn_op_valid() checked a replayed op before.
 */
void rk_snap_apply(struct raidkm_snap *sn, struct rk_snap_op *op, bool replay)
{
	struct r5conf *conf = sn->conf;
	struct raidkm_snap_one *g, *older;
	unsigned long flags, L;
	bool was_newest;
	u64 moved = 0, freed = 0;
	void *e;

	switch (op->type) {
	case RK_OP_REDIRECT:
		g = rk_newest(sn);
		/* a reader of g looks at exc first, then the origin: first
		 * the old row into exc, then the origin's new row */
		xa_store(&g->exc, op->L, xa_mk_value((u64)op->oldP + 1),
			 GFP_NOIO | __GFP_NOFAIL);
		rk_sn_rmap_set(sn, op->oldP, op->L, RK_SN_OWN_SNAP0 + g->slot);
		rk_sn_rmap_set(sn, op->newP, op->L, RK_SN_OWN_ORIGIN);
		spin_lock_irqsave(&sn->lock, flags);
		g->nexc++;
		WRITE_ONCE(sn->origin[op->L], op->newP);
		sn->redirected += (op->newP != op->L) - (op->oldP != op->L);
		clear_bit(op->L, sn->shared);
		__set_bit(op->newP, sn->used);
		spin_unlock_irqrestore(&sn->lock, flags);
		return;

	case RK_OP_CREATE:
		g = op->g;
		g->slot = op->slot;
		spin_lock_irqsave(&sn->lock, flags);
		list_add_tail(&g->list, &sn->snaps);	/* ids only grow */
		sn->nsnaps++;
		__set_bit(op->slot, sn->slots);
		if (g->id >= sn->next_id)
			sn->next_id = g->id + 1;
		bitmap_fill(sn->shared, sn->O);
		spin_unlock_irqrestore(&sn->lock, flags);
		return;

	case RK_OP_DESTROY:
		g = rk_snap_slot(sn, op->slot);
		older = list_is_first(&g->list, &sn->snaps) ? NULL :
			list_prev_entry(g, list);
		/* g's rows: to the next older one where it read through g,
		 * else free (the commit is durable: nothing replays them as
		 * g's again, so they may go U and be reused) */
		xa_for_each(&g->exc, L, e) {
			u64 P = xa_to_value(e) - 1;

			if (older && !xa_load(&older->exc, L)) {
				/* live: reserved by the caller, cannot fail */
				xa_store(&older->exc, L, e, replay ?
					 GFP_KERNEL | __GFP_NOFAIL : GFP_NOIO);
				older->nexc++;
				rk_sn_rmap_set(sn, P, L,
					       RK_SN_OWN_SNAP0 + older->slot);
				moved++;
			} else {
				rk_sn_rmap_set(sn, P, 0, RK_SN_OWN_FREE);
				spin_lock_irqsave(&sn->lock, flags);
				__clear_bit(P, sn->used);
				spin_unlock_irqrestore(&sn->lock, flags);
				raidkm_rowmap_note_discard(conf, P, P + 1);
				atomic64_inc(&sn->freed);
				freed++;
			}
			cond_resched();
		}
		spin_lock_irqsave(&sn->lock, flags);
		was_newest = g == rk_newest(sn);
		list_del(&g->list);
		sn->nsnaps--;
		__clear_bit(op->slot, sn->slots);
		spin_unlock_irqrestore(&sn->lock, flags);
		/*
		 * g was the newest: the origin is now shared with the next
		 * older one exactly where that one reads through to the
		 * origin, i.e. where it has no exception (after the moves).
		 * Without sn->lock: the array is suspended (no map_bio) and no
		 * COW runs, the only readers of shared.  O(exceptions).
		 */
		if (list_empty(&sn->snaps)) {
			bitmap_zero(sn->shared, sn->O);
		} else if (was_newest) {
			bitmap_fill(sn->shared, sn->O);
			xa_for_each(&older->exc, L, e) {
				__clear_bit(L, sn->shared);
				cond_resched();
			}
		}
		xa_destroy(&g->exc);
		op->L = moved;
		op->newP = freed;
		if (replay)
			kfree(g);
		return;

	case RK_OP_RENAME:	/* under sn->lock: the disk's sysfs reads it */
		g = rk_snap_slot(sn, op->slot);
		spin_lock_irqsave(&sn->lock, flags);
		strscpy(g->name, op->text, sizeof(g->name));
		spin_unlock_irqrestore(&sn->lock, flags);
		return;

	case RK_OP_SET:
		g = rk_snap_slot(sn, op->slot);
		spin_lock_irqsave(&sn->lock, flags);
		strscpy(g->attrs, op->text, sizeof(g->attrs));
		spin_unlock_irqrestore(&sn->lock, flags);
		return;
	}
}

/* ---- snapshot block devices (read-only) ------------------------------ */

static void rk_snap_read_endio(struct bio *clone)
{
	struct bio *parent = clone->bi_private;

	parent->bi_status = clone->bi_status;
	bio_put(clone);
	bio_endio(parent);
}

static void rk_snap_submit_bio(struct bio *bio)
{
	struct raidkm_snap_one *g = bio->bi_bdev->bd_disk->private_data;
	struct raidkm_snap *sn = g->sn;
	struct raidkm_snap_one *h;
	sector_t s;
	u64 L, P = U64_MAX;
	struct bio *clone;

	/* a bio-based queue is not split for us (md_submit_bio does it for
	 * itself too): cut at the row (chunk_sectors) and md's bio size, the
	 * rest comes back here */
	bio = bio_split_to_limits(bio);
	if (!bio)
		return;
	s = bio->bi_iter.bi_sector;
	L = div64_u64(s, sn->rs);
	if (op_is_write(bio_op(bio))) {
		bio->bi_status = BLK_STS_IOERR;	/* read-only */
		bio_endio(bio);
		return;
	}
	if (!bio_sectors(bio)) {
		bio_endio(bio);
		return;
	}
	/* split above: never across a row */
	if (L >= sn->O || bio_end_sector(bio) > (L + 1) * sn->rs) {
		bio_io_error(bio);
		return;
	}
	spin_lock_irq(&sn->lock);
	for (h = g; &h->list != &sn->snaps; h = list_next_entry(h, list)) {
		void *e = xa_load(&h->exc, L);

		if (e) {
			P = xa_to_value(e) - 1;
			break;
		}
	}
	if (P == U64_MAX)
		P = sn->origin[L];
	spin_unlock_irq(&sn->lock);

	clone = bio_alloc_clone(rk_md_bdev(sn), bio, GFP_NOIO, &sn->bs);
	clone->bi_iter.bi_sector = P * sn->rs + (s - L * sn->rs);
	bio_set_flag(clone, BIO_REMAPPED);
	clone->bi_private = bio;
	clone->bi_end_io = rk_snap_read_endio;
	md_handle_request(sn->conf->mddev, clone);
}

/*
 * An open snapshot disk holds one of md's openers: the array cannot be
 * stopped under a mounted snapshot (-EBUSY, as with a mounted origin).
 * Called with the snapshot disk's open_mutex held, the order md_open()
 * takes md's open_mutex in.
 */
static int rk_snap_open(struct gendisk *disk, blk_mode_t mode)
{
	struct raidkm_snap_one *g = disk->private_data;
	struct mddev *mddev = g->sn->conf->mddev;
	int err = 0;

	/*
	 * Under this disk's open_mutex.  A stop holds md's open_mutex and
	 * deletes this disk (del_gendisk takes our open_mutex): waiting for
	 * md's here would deadlock (ABBA).  So try it, and give up once the
	 * stop has marked the snapshot disks dying; other holders of md's
	 * open_mutex keep it briefly.
	 */
	while (!mutex_trylock(&mddev->open_mutex)) {
		if (READ_ONCE(g->dying))
			return -ENODEV;
		if (signal_pending(current))
			return -ERESTARTSYS;
		msleep(1);
	}
	if (READ_ONCE(g->dying))
		err = -ENODEV;
	else if (test_bit(MD_CLOSING, &mddev->flags))
		err = -EBUSY;
	else
		atomic_inc(&mddev->openers);
	mutex_unlock(&mddev->open_mutex);
	return err;
}

static void rk_snap_release(struct gendisk *disk)
{
	struct raidkm_snap_one *g = disk->private_data;

	rk_md_unpin(g->sn->conf->mddev);
}

static const struct block_device_operations rk_snap_fops = {
	.owner		= THIS_MODULE,
	.open		= rk_snap_open,
	.release	= rk_snap_release,
	.submit_bio	= rk_snap_submit_bio,
};

/*
 * Each snapshot disk's own sysfs: /sys/block/mdXsN/rk_snap/{name,id,ctime,
 * attrs,exc}.  md/rk_snap's listing is one page, which a few snapshots
 * with a snapshot tool's attributes fill; these files are each small, so mdadm
 * lists from them.  Copied under sn->lock, never sn->mutex: a destroy holds
 * that while del_gendisk() waits for these to return.
 */
static ssize_t rk_snap_disk_show(struct device *dev, char *page, int what)
{
	struct raidkm_snap_one *g = dev_to_disk(dev)->private_data;
	struct raidkm_snap *sn = g->sn;
	char *buf;
	ssize_t n;

	buf = kmalloc(RK_SNAP_ATTRS, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;
	spin_lock_irq(&sn->lock);
	switch (what) {
	case 0: strscpy(buf, g->name, RK_SNAP_ATTRS); break;
	case 1: snprintf(buf, RK_SNAP_ATTRS, "%d", g->id); break;
	case 2: snprintf(buf, RK_SNAP_ATTRS, "%lld", (long long)g->ctime); break;
	case 3: strscpy(buf, g->attrs, RK_SNAP_ATTRS); break;
	default: snprintf(buf, RK_SNAP_ATTRS, "%llu", g->nexc); break;
	}
	spin_unlock_irq(&sn->lock);
	n = sysfs_emit(page, "%s\n", buf);
	kfree(buf);
	return n;
}
#define RK_SNAP_DISK_ATTR(_name, _what)					\
static ssize_t rk_snap_##_name##_show(struct device *dev,		\
				      struct device_attribute *a, char *page) \
{									\
	return rk_snap_disk_show(dev, page, _what);			\
}									\
static DEVICE_ATTR(_name, 0444, rk_snap_##_name##_show, NULL)
RK_SNAP_DISK_ATTR(name, 0);
RK_SNAP_DISK_ATTR(id, 1);
RK_SNAP_DISK_ATTR(ctime, 2);
RK_SNAP_DISK_ATTR(attrs, 3);
RK_SNAP_DISK_ATTR(exc, 4);
static struct attribute *rk_snap_disk_attrs[] = {
	&dev_attr_name.attr, &dev_attr_id.attr, &dev_attr_ctime.attr,
	&dev_attr_attrs.attr, &dev_attr_exc.attr, NULL,
};
static const struct attribute_group rk_snap_disk_group = {
	.name	= "rk_snap",
	.attrs	= rk_snap_disk_attrs,
};
static const struct attribute_group *rk_snap_disk_groups[] = {
	&rk_snap_disk_group, NULL,
};

static int rk_snap_add_disk(struct raidkm_snap_one *g)
{
	struct raidkm_snap *sn = g->sn;
	struct block_device *md = rk_md_bdev(sn);
	struct queue_limits lim = {
		.logical_block_size	= bdev_logical_block_size(md),
		.physical_block_size	= bdev_physical_block_size(md),
		.io_min			= bdev_io_min(md),
		.io_opt			= bdev_io_opt(md),
		/* a clone goes to md_handle_request() as it is: no larger
		 * than a bio md's own queue lets through */
		.max_hw_sectors		= min_t(u64, sn->rs,
						queue_max_hw_sectors(bdev_get_queue(md))),
		.chunk_sectors		= sn->rs,
	};
	struct gendisk *disk;
	int err;

	disk = blk_alloc_disk(&lim, NUMA_NO_NODE);
	if (IS_ERR(disk))
		return PTR_ERR(disk);
	disk->fops = &rk_snap_fops;
	disk->private_data = g;
	disk->flags |= GENHD_FL_NO_PART;
	snprintf(disk->disk_name, sizeof(disk->disk_name), "%ss%d",
		 mdname(sn->conf->mddev), g->id);
	set_capacity(disk, sn->O * sn->rs);
	set_disk_ro(disk, true);
	WRITE_ONCE(g->dying, false);
	err = device_add_disk(NULL, disk, rk_snap_disk_groups);
	if (err) {
		put_disk(disk);
		return err;
	}
	g->disk = disk;
	return 0;
}

static void rk_snap_del_disk(struct raidkm_snap_one *g)
{
	if (g->disk) {
		del_gendisk(g->disk);
		put_disk(g->disk);
		g->disk = NULL;
	}
}


/* ---- setup and teardown ------------------------------------------------- */

static void rk_snap_disks_fn(struct work_struct *work)
{
	struct raidkm_snap *sn = container_of(work, struct raidkm_snap,
					      disks_work);
	struct raidkm_snap_one *g;
	int err;

	mutex_lock(&sn->mutex);
	list_for_each_entry(g, &sn->snaps, list) {
		if (g->disk)
			continue;
		err = rk_snap_add_disk(g);
		if (err)
			pr_err("md/raid:%s: snap %s: no block device (%d)\n",
			       mdname(sn->conf->mddev), g->name, err);
	}
	mutex_unlock(&sn->mutex);
}

/*
 * raid5_run(), after the row map: an array created with --snapshots loads
 * its snapshot metadata here, or does not start.  Its capacity becomes the
 * origin's (raid5_run sets it from conf->snap).
 */
int raidkm_snap_init(struct r5conf *conf)
{
	struct mddev *mddev = conf->mddev;
	struct raidkm_rowmap *rm = conf->rowmap;
	struct gendisk *disk = mddev->gendisk;
	struct raidkm_snap *sn;
	struct md_rdev *rdev;
	unsigned long idx;
	void *part;
	u64 rs, i;
	int err;

	if (!rm || !disk) {
		pr_err("md/raid:%s: snap: snapshots need the row map and an md block device\n",
		       mdname(mddev));
		return -EINVAL;
	}
	rs = (u64)conf->chunk_sectors * (conf->raid_disks - conf->m);
	if (rs << 9 < PAGE_SIZE || (rs << 9) & ~PAGE_MASK) {
		pr_err("md/raid:%s: snap: the row is not a whole number of pages\n",
		       mdname(mddev));
		return -EINVAL;
	}
	if (rm->nrows >= U32_MAX) {
		pr_err("md/raid:%s: snap: %llu rows, at most %u\n",
		       mdname(mddev), rm->nrows, U32_MAX - 1);
		return -EINVAL;
	}
	/* a partition's bio comes BIO_REMAPPED, i.e. as if physical */
	mutex_lock(&disk->open_mutex);
	xa_for_each_start(&disk->part_tbl, idx, part, 1) {
		mutex_unlock(&disk->open_mutex);
		pr_err("md/raid:%s: snap: the array has partitions\n",
		       mdname(mddev));
		return -EBUSY;
	}
	disk->flags |= GENHD_FL_NO_PART;
	mutex_unlock(&disk->open_mutex);

	sn = kzalloc(sizeof(*sn), GFP_KERNEL);
	if (!sn) {
		disk->flags &= ~GENHD_FL_NO_PART;
		return -ENOMEM;
	}
	sn->conf = conf;
	sn->rs = rs;
	sn->R = rm->nrows;
	sn->id = rm->id;
	sn->region = rm->region + (sector_t)rm->npages * (RK_RM_PAGE >> 9);
	spin_lock_init(&sn->lock);
	mutex_init(&sn->mutex);
	INIT_LIST_HEAD(&sn->snaps);
	INIT_LIST_HEAD(&sn->pending);
	hash_init(sn->busy);
	bio_list_init(&sn->overflow);
	init_waitqueue_head(&sn->drain_wq);
	xa_init(&sn->rmap);
	INIT_WORK(&sn->commit_work, rk_sn_commit_fn);
	INIT_WORK(&sn->disks_work, rk_snap_disks_fn);
	for (i = 0; i < RK_SNAP_COWS; i++) {
		sn->cow[i].sn = sn;
		INIT_WORK(&sn->cow[i].work, rk_cow_fn);
	}
	conf->snap = sn;	/* not yet published: raid5_run has not ended */

	rdev_for_each(rdev, mddev) {
		if (rdev->raid_disk < 0 || !rdev->bdev)
			continue;
		if (!raidkm_snap_room(conf, rdev)) {
			pr_err("md/raid:%s: snap: %pg has no room for the snapshot metadata after the row map\n",
			       mdname(mddev), rdev->bdev);
			err = -EINVAL;
			goto fail;
		}
	}
	err = rk_sn_load(sn);
	if (err)
		goto fail;
	sn->cursor = sn->O;
	sn->wq = alloc_workqueue("rk_snap_%s", WQ_MEM_RECLAIM | WQ_UNBOUND, 0,
				 mdname(mddev));
	sn->cwq = alloc_ordered_workqueue("rk_snapc_%s", WQ_MEM_RECLAIM,
					  mdname(mddev));
	sn->buf_pool = mempool_create(2, rk_rowbuf_alloc, rk_rowbuf_free,
				      (void *)(unsigned long)((rs << 9) >> PAGE_SHIFT));
	if (!sn->wq || !sn->cwq || !sn->buf_pool ||
	    bioset_init(&sn->bs, 64, 0, BIOSET_NEED_BVECS)) {
		err = -ENOMEM;
		goto fail;
	}
	sn->piece = 1;		/* set from the queue limits at start */
	return 0;
fail:
	raidkm_snap_free(conf);
	return err;
}

/* a member (or a spare being added) has room for the snapshot region */
bool raidkm_snap_room(struct r5conf *conf, struct md_rdev *rdev)
{
	struct raidkm_snap *sn = conf->snap;

	return !sn || !rdev->bdev ||
	       bdev_nr_sectors(rdev->bdev) >= rdev->data_offset + sn->region +
	       rk_sn_region_pages(sn->R) * (RK_SN_PAGE >> 9);
}

/* raid5_start(): the queue has its limits, the array runs */
void raidkm_snap_start(struct r5conf *conf)
{
	struct raidkm_snap *sn = conf->snap;

	if (!sn)
		return;
	sn->piece = clamp_t(unsigned int,
			    queue_max_hw_sectors(conf->mddev->gendisk->queue) >>
			    (PAGE_SHIFT - 9), 1, BIO_MAX_VECS);
	queue_work(sn->wq, &sn->disks_work);
}

/*
 * A clean stop (raid5_free, before the row map's stop: a destroy's freed
 * rows reach the row map here): no snapshot disk is open (md's opener
 * check), no I/O runs.  The COWs and commits drain, a last checkpoint
 * makes the next assemble quick.
 */
void raidkm_snap_stop(struct r5conf *conf)
{
	struct raidkm_snap *sn = conf->snap;
	struct raidkm_snap_one *g;

	if (!sn)
		return;
	flush_workqueue(sn->wq);
	flush_workqueue(sn->cwq);
	mutex_lock(&sn->mutex);
	/* md's open_mutex is held here (do_md_stop): an open waiting for it
	 * gives up on dying, so del_gendisk() can take the disk's */
	list_for_each_entry(g, &sn->snaps, list)
		WRITE_ONCE(g->dying, true);
	list_for_each_entry(g, &sn->snaps, list)
		rk_snap_del_disk(g);
	mutex_unlock(&sn->mutex);
	if (!sn->broken && !conf->mddev->ro && !snap_test_no_stop_ckpt &&
	    (!bitmap_empty(sn->rdirty, sn->N) || sn->jhead != sn->jtail ||
	     !sn->ckpt))
		rk_sn_checkpoint_sync(sn, false);
}

/* a member is about to be rebuilt: it gets the whole region first (from
 * the row map's seed, at the start of the pass) */
void raidkm_snap_seed(struct r5conf *conf)
{
	struct raidkm_snap *sn = conf->snap;

	if (!sn || conf->mddev->ro)
		return;
	if (!rk_sn_checkpoint_sync(sn, true))
		pr_info("md/raid:%s: snap: metadata written to every member before the rebuild\n",
			mdname(conf->mddev));
}

/*
 * From raid5_free() after raidkm_snap_stop(), from free_conf() (setup
 * aborts; a second call finds conf->snap NULL), and from a failed init.
 */
void raidkm_snap_free(struct r5conf *conf)
{
	struct raidkm_snap *sn = conf->snap;
	struct raidkm_snap_one *g, *t;

	if (!sn)
		return;
	conf->snap = NULL;
	if (conf->mddev->gendisk)
		conf->mddev->gendisk->flags &= ~GENHD_FL_NO_PART;
	if (sn->wq) {
		flush_workqueue(sn->wq);
		destroy_workqueue(sn->wq);
	}
	if (sn->cwq) {
		flush_workqueue(sn->cwq);
		destroy_workqueue(sn->cwq);
	}
	list_for_each_entry_safe(g, t, &sn->snaps, list) {
		rk_snap_del_disk(g);
		xa_destroy(&g->exc);
		kfree(g);
	}
	mempool_destroy(sn->buf_pool);
	bioset_exit(&sn->bs);
	rk_sn_free(sn);
	kfree(sn);
}

/* ---- create / destroy / rename / set ------------------------------------- */

static struct raidkm_snap_one *rk_snap_find(struct raidkm_snap *sn,
					    const char *name)
{
	struct raidkm_snap_one *g;

	list_for_each_entry(g, &sn->snaps, list)
		if (!strcmp(g->name, name))
			return g;
	return NULL;
}

/* 1-63 of [A-Za-z0-9._-], not starting with '-' (it would read as an option) */
static bool rk_name_ok(const char *name)
{
	size_t n = strlen(name);

	return n && n < RK_SNAP_NAME && *name != '-' &&
	       strspn(name, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
			    "0123456789._-") == n;
}

/* key=value: key 1-32 of [a-z0-9_] and not one raidkm reports itself,
 * value of [A-Za-z0-9._:-] (a tool may hex-encode free text) */
static int rk_kv_ok(const char *kv)
{
	static const char * const own[] = { "name", "id", "ctime", "dev", "exc" };
	const char *eq = strchr(kv, '=');
	size_t k = eq ? eq - kv : 0;
	int i;

	if (!k || k > 32 || strspn(kv, "abcdefghijklmnopqrstuvwxyz0123456789_") != k ||
	    strspn(eq + 1, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
			   "0123456789._:-") != strlen(eq + 1))
		return -EINVAL;
	for (i = 0; i < ARRAY_SIZE(own); i++)
		if (strlen(own[i]) == k && !strncmp(kv, own[i], k))
			return -EINVAL;
	return 0;
}

/* set key=value in "k=v k=v ...", replacing the key's old value */
static int rk_attr_set(char *attrs, const char *kv)
{
	size_t k = strchr(kv, '=') - kv, n;
	char *p = attrs, *end;

	while (*p) {
		end = strchrnul(p, ' ');
		if (!strncmp(p, kv, k) && p[k] == '=') {
			if (*end)	/* the rest after the separator */
				memmove(p, end + 1, strlen(end + 1) + 1);
			else		/* it was the last one */
				*p = 0;
			if (!*p && p > attrs)
				p[-1] = 0;	/* no separator left at the end */
			continue;
		}
		p = *end ? end + 1 : end;
	}
	n = strlen(attrs);
	if (n + !!n + strlen(kv) >= RK_SNAP_ATTRS)
		return -E2BIG;
	if (n)
		attrs[n++] = ' ';
	strcpy(attrs + n, kv);
	return 0;
}

/* apply "k=v k=v ..." (args, space-separated, may be NULL) to attrs:
 * all or nothing */
static int rk_attrs_apply(char *attrs, char *args)
{
	char *tmp, *kv;
	int err = 0;

	if (!args || !*args)
		return 0;
	tmp = kmemdup(attrs, RK_SNAP_ATTRS, GFP_KERNEL);
	if (!tmp)
		return -ENOMEM;
	while (!err && (kv = strsep(&args, " ")))
		if (*kv)
			err = rk_kv_ok(kv) ?: rk_attr_set(tmp, kv);
	if (!err)
		memcpy(attrs, tmp, RK_SNAP_ATTRS);
	kfree(tmp);
	return err;
}


/* no new COW starts; wait for the ones in flight (they need the commit
 * worker and, for partial rows, md_handle_request: before any suspend) */
static void rk_snap_hold(struct raidkm_snap *sn)
{
	spin_lock_irq(&sn->lock);
	sn->hold = true;
	spin_unlock_irq(&sn->lock);
	wait_event(sn->drain_wq, !atomic_read(&sn->cows));
}

static void rk_snap_unhold(struct raidkm_snap *sn)
{
	struct bio_list l;
	struct bio *w;

	spin_lock_irq(&sn->lock);
	sn->hold = false;
	l = sn->overflow;
	bio_list_init(&sn->overflow);
	spin_unlock_irq(&sn->lock);
	while ((w = bio_list_pop(&l)))
		submit_bio_noacct(w);
}

/*
 * Take g out of the chain through the journal.  sn->mutex held, g has no
 * disk (no reader).  Every slot the move into the next older snapshot
 * fills is reserved first, so applying the record cannot fail; -ENOMEM
 * before the record: nothing changed.
 */
static int rk_snap_drop(struct raidkm_snap *sn, struct raidkm_snap_one *g,
			u64 *moved, u64 *freed)
{
	struct mddev *mddev = sn->conf->mddev;
	struct rk_snap_op op = { .type = RK_OP_DESTROY, .slot = g->slot };
	struct raidkm_snap_one *older;
	unsigned long L;
	void *e;
	int err = 0;

	rk_snap_hold(sn);
	older = list_is_first(&g->list, &sn->snaps) ? NULL :
		list_prev_entry(g, list);
	if (older) {
		xa_for_each(&g->exc, L, e) {
			if (xa_load(&older->exc, L))
				continue;
			err = xa_reserve(&older->exc, L, GFP_NOIO);
			if (err)
				break;
			cond_resched();
		}
	}
	if (!err) {
		mddev_suspend(mddev, false);
		err = rk_sn_submit_sync(sn, &op);
		mddev_resume(mddev);
	}
	if (err && older)
		/* drops reservations only, never a real entry */
		xa_for_each(&g->exc, L, e)
			xa_release(&older->exc, L);
	rk_snap_unhold(sn);
	if (!err) {
		*moved = op.L;
		*freed = op.newP;
	}
	return err;
}

static int rk_snap_create(struct raidkm_snap *sn, const char *name, char *args)
{
	struct mddev *mddev = sn->conf->mddev;
	struct rk_snap_op op = { .type = RK_OP_CREATE };
	struct raidkm_snap_one *g;
	u64 moved = 0, freed = 0;
	unsigned int slot;
	bool frozen;
	int err, id;

	if (!rk_name_ok(name))
		return -EINVAL;
	g = kzalloc(sizeof(*g), GFP_KERNEL);
	if (!g)
		return -ENOMEM;
	/* a snapshot never exists without its attributes */
	err = rk_attrs_apply(g->attrs, args);
	if (err) {
		kfree(g);
		return err;
	}
	strscpy(g->name, name, sizeof(g->name));
	xa_init(&g->exc);
	g->sn = sn;

	mutex_lock(&sn->mutex);
	slot = find_first_zero_bit(sn->slots, RK_SNAP_SLOTS);
	err = rk_snap_find(sn, name) ? -EEXIST :
	      slot >= RK_SNAP_SLOTS ? -ENOSPC : sn->broken ? -EIO : 0;
	if (err) {
		mutex_unlock(&sn->mutex);
		kfree(g);
		return err;
	}
	/* the filesystem's own consistent point: a journaling filesystem commits its journal,
	 * as dm suspend does it for LVM.  Not mounted: nothing to freeze. */
	frozen = !bdev_freeze(rk_md_bdev(sn));
	/* no COW in flight, none starts; then no origin bio in flight.  Not
	 * under reconfig_mutex: the freeze's and the drain's writes may need
	 * md's thread, which takes it. */
	rk_snap_hold(sn);
	mddev_suspend(mddev, false);
	g->id = sn->next_id;
	g->ctime = ktime_get_real_seconds();
	op.slot = slot;
	op.g = g;
	err = rk_sn_submit_sync(sn, &op);	/* durable, then in the chain */
	mddev_resume(mddev);
	rk_snap_unhold(sn);
	if (frozen)
		bdev_thaw(rk_md_bdev(sn));
	if (err) {
		mutex_unlock(&sn->mutex);
		kfree(g);
		return err;
	}

	err = rk_snap_add_disk(g);
	if (err) {
		/* no snapshot without its device: take it out again */
		pr_err("md/raid:%s: snap %s: no block device (%d)\n",
		       mdname(mddev), name, err);
		if (!rk_snap_drop(sn, g, &moved, &freed))
			kfree(g);
		/* else it stays, listed with dev=- */
		mutex_unlock(&sn->mutex);
		return err;
	}
	/* g is listed: once the mutex drops, a destroy may free it */
	id = g->id;
	mutex_unlock(&sn->mutex);
	pr_info("md/raid:%s: snap %s created (id %d, %sfrozen)\n",
		mdname(mddev), name, id, frozen ? "" : "not ");
	return 0;
}

static int rk_snap_destroy(struct raidkm_snap *sn, const char *name)
{
	struct mddev *mddev = sn->conf->mddev;
	struct raidkm_snap_one *g;
	u64 moved = 0, freed = 0;
	bool busy = false;
	int err;

	mutex_lock(&sn->mutex);
	g = rk_snap_find(sn, name);
	if (!g) {
		mutex_unlock(&sn->mutex);
		return -ENOENT;
	}
	/* in use (mounted): a snapshot tool unmounts first, then destroys.  The
	 * check and 'dying' under the disk's open_mutex: no open slips in
	 * between (rk_snap_open runs under it) */
	if (g->disk) {
		mutex_lock(&g->disk->open_mutex);
		busy = disk_openers(g->disk);
		if (!busy)
			WRITE_ONCE(g->dying, true);
		mutex_unlock(&g->disk->open_mutex);
	}
	if (busy) {
		mutex_unlock(&sn->mutex);
		return -EBUSY;
	}
	/* no reader of g after this */
	rk_snap_del_disk(g);
	err = rk_snap_drop(sn, g, &moved, &freed);
	if (err) {
		/* nothing changed: give it its device back */
		if (rk_snap_add_disk(g))
			pr_err("md/raid:%s: snap %s: destroy failed (%d) and its device is gone\n",
			       mdname(mddev), name, err);
		mutex_unlock(&sn->mutex);
		return err;
	}
	mutex_unlock(&sn->mutex);
	pr_info("md/raid:%s: snap %s destroyed: %llu row(s) moved to the next older, %llu freed\n",
		mdname(mddev), name, moved, freed);
	kfree(g);
	return 0;
}

static int rk_snap_rename(struct raidkm_snap *sn, const char *old,
			  const char *new)
{
	struct rk_snap_op op = { .type = RK_OP_RENAME };
	struct raidkm_snap_one *g;
	int err;

	if (!rk_name_ok(new))
		return -EINVAL;
	mutex_lock(&sn->mutex);
	g = rk_snap_find(sn, old);
	if (!g) {
		err = -ENOENT;
	} else if (rk_snap_find(sn, new)) {
		err = -EEXIST;
	} else {
		op.slot = g->slot;
		op.text = (char *)new;
		err = rk_sn_submit_sync(sn, &op);
	}
	mutex_unlock(&sn->mutex);
	return err;
}

static int rk_snap_set(struct raidkm_snap *sn, const char *name, char *args)
{
	struct rk_snap_op op = { .type = RK_OP_SET };
	struct raidkm_snap_one *g;
	char *attrs;
	int err;

	if (!args || !*args)
		return -EINVAL;
	mutex_lock(&sn->mutex);
	g = rk_snap_find(sn, name);
	if (!g) {
		mutex_unlock(&sn->mutex);
		return -ENOENT;
	}
	attrs = kmemdup(g->attrs, RK_SNAP_ATTRS, GFP_KERNEL);
	err = attrs ? rk_attrs_apply(attrs, args) : -ENOMEM;
	if (!err) {
		op.slot = g->slot;
		op.text = attrs;
		err = rk_sn_submit_sync(sn, &op);
	}
	kfree(attrs);
	mutex_unlock(&sn->mutex);
	return err;
}

/* ---- sysfs: rk_snap ---------------------------------------------------- */

/*
 * conf->snap under reconfig_mutex, then one of md's openers held (a stop
 * fails with -EBUSY until rk_snap_put) and the mutex dropped: create and
 * destroy freeze and suspend the array, which may need md's thread, and
 * that takes reconfig_mutex.
 */
static int rk_snap_get(struct mddev *mddev, struct raidkm_snap **snp)
{
	struct r5conf *conf;
	int err;

	err = mddev_lock(mddev);
	if (err)
		return err;
	conf = mddev->private;
	if (!conf)
		err = -ENODEV;
	else if (!conf->snap)
		err = -ENOENT;
	else
		err = rk_md_pin(mddev);
	if (!err)
		*snp = conf->snap;
	mddev_unlock(mddev);
	return err;
}

static void rk_snap_put(struct mddev *mddev)
{
	rk_md_unpin(mddev);
}

ssize_t raidkm_snap_show(struct mddev *mddev, char *page)
{
	struct raidkm_snap *sn;
	struct raidkm_snap_one *g;
	ssize_t n = 0;
	int err;

	err = rk_snap_get(mddev, &sn);
	if (err == -ENOENT || err == -ENODEV)
		return sprintf(page, "off\n");
	if (err)
		return err;
	mutex_lock(&sn->mutex);
	n += sysfs_emit_at(page, n,
			   "origin_rows %llu\nreserve_rows %llu\nreserve_pct %u\nfree_rows %llu\nredirected %llu\n"
			   "cow_whole %lld\ncow_partial %lld\ncow_fail %lld\ncow_nospc %lld\nfreed %lld\n"
			   "checkpoint %llu\njournal_tail %llu\njournal_head %llu\ncommits %lld\nrecords %lld\n"
			   "checkpoints %lld\nreplayed %lld\nbroken %d\nsnapshots %d\n",
			   sn->O, sn->R - sn->O, sn->reserve_pct,
			   sn->R - bitmap_weight(sn->used, sn->R),
			   READ_ONCE(sn->redirected),
			   atomic64_read(&sn->cow_whole),
			   atomic64_read(&sn->cow_partial),
			   atomic64_read(&sn->cow_fail),
			   atomic64_read(&sn->cow_nospc),
			   atomic64_read(&sn->freed),
			   READ_ONCE(sn->ckpt), READ_ONCE(sn->jtail),
			   READ_ONCE(sn->jhead),
			   atomic64_read(&sn->commits),
			   atomic64_read(&sn->records),
			   atomic64_read(&sn->ckpts),
			   atomic64_read(&sn->replayed),
			   READ_ONCE(sn->broken), sn->nsnaps);
	list_for_each_entry(g, &sn->snaps, list)
		n += sysfs_emit_at(page, n,
				   "snap name=%s id=%d ctime=%lld dev=/dev/%s exc=%llu%s%s\n",
				   g->name, g->id, (long long)g->ctime,
				   g->disk ? g->disk->disk_name : "-", g->nexc,
				   *g->attrs ? " " : "", g->attrs);
	if (n >= PAGE_SIZE - 1)
		pr_warn_ratelimited("md/raid:%s: snap: rk_snap listing truncated at one page\n",
				    mdname(mddev));
	mutex_unlock(&sn->mutex);
	rk_snap_put(mddev);
	return n;
}

/* "create <name> [k=v]...", "destroy <name>", "rename <old> <new>",
 * "set <name> k=v...", "checkpoint" */
ssize_t raidkm_snap_store(struct mddev *mddev, const char *page, size_t len)
{
	struct raidkm_snap *sn;
	char *buf, *cmd, *name, *rest;
	int err;

	buf = kstrndup(page, len, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;
	rest = strim(buf);
	cmd = strsep(&rest, " ");
	name = strsep(&rest, " ");
	err = rk_snap_get(mddev, &sn);
	if (err == -ENOENT)
		err = -EINVAL;		/* not an array with snapshots */
	if (err)
		goto out;
	if (!strcmp(cmd, "checkpoint") && !name)
		err = rk_sn_checkpoint_sync(sn, false);
	else if (!name)
		err = -EINVAL;
	else if (!strcmp(cmd, "create"))
		err = rk_snap_create(sn, name, rest);
	else if (!strcmp(cmd, "destroy") && !rest)
		err = rk_snap_destroy(sn, name);
	else if (!strcmp(cmd, "rename") && rest && !strchr(rest, ' '))
		err = rk_snap_rename(sn, name, rest);
	else if (!strcmp(cmd, "set"))
		err = rk_snap_set(sn, name, rest);
	else
		err = -EINVAL;
	rk_snap_put(mddev);
out:
	kfree(buf);
	return err ?: len;
}
