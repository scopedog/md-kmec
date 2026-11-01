// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * raidkm native snapshots: what is on disk -- the region, the journal, the
 * checkpoints, and loading it all at assemble.  See raid_km_snap.h and
 * notes/md-kmec/native-snapshot-p2-design-2026-10-31.md.
 *
 * The region (every member, right after the row map, in 4 KiB pages):
 *
 *	header x2 | table x2 | pmap x2 | rmap slot 0 | rmap slot 1 | journal
 *
 * Every page is sealed: a 16-byte trailer {id, gen, crc32c ^ kind magic}.
 * A checkpoint c + 1 writes the changed rmap pages into the slot that does
 * not hold them as of c, then table and pmap into copy (c + 1) & 1, then
 * the header copy (c + 1) & 1; each step after a flush.  Until that header
 * is down, c is whole on disk, and the journal from c's tail is still in
 * the ring.
 *
 * A commit: the COW data writes have completed; an empty flush to every
 * member makes them durable there (one member's flush does not cover
 * another member's data, hence a phase of its own); then the records,
 * FUA, to every member.  Commits are serial, so the members' rings differ
 * by at most the last record, and that one was never acked.
 *
 * The commit worker is the only writer of rmap, pmap, rdirty and of the
 * snapshot list's contents (rk_snap_apply), and runs the checkpoints, so
 * a checkpoint always sees every applied record and nothing else.
 */
#include <linux/blkdev.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/bitmap.h>
#include <linux/math64.h>
#include <linux/crc32c.h>
#include <linux/completion.h>
#if __has_include(<linux/unaligned.h>)
#include <linux/unaligned.h>		/* 6.12 on */
#else
#include <asm/unaligned.h>
#endif

#include "md.h"
#include "raid_km.h"
#include "raid_km_rowmap.h"
#include "raid_km_snap.h"

#define RK_SN_JBUF	32	/* records per commit, at most */

/* little-endian fields at any byte offset of a record */
#define rk_put16(v, p)	put_unaligned_le16(v, p)
#define rk_put32(v, p)	put_unaligned_le32(v, p)
#define rk_put64(v, p)	put_unaligned_le64(v, p)
#define rk_get16(p)	get_unaligned_le16(p)
#define rk_get32(p)	get_unaligned_le32(p)
#define rk_get64(p)	get_unaligned_le64(p)

/* the ring slot of journal seq (RK_SN_JPAGES is a power of two) */
static inline u64 rk_sn_jidx(u64 seq) { return seq & (RK_SN_JPAGES - 1); }
#define RK_SN_CBUF	128	/* pages per checkpoint write */

/* ---- layout ------------------------------------------------------------- */

static u64 rk_sn_N(u64 R)
{
	return DIV_ROUND_UP_ULL(R, RK_SN_RMAP_PER_PAGE);
}

static u64 rk_sn_pmp(u64 N)
{
	return DIV_ROUND_UP_ULL(N, RK_SN_PMAP_PER_PAGE);
}

/* the region's size for R physical rows; mdadm computes the same */
u64 rk_sn_region_pages(u64 R)
{
	u64 N = rk_sn_N(R);

	return RK_SN_OFF_PMAP + 2 * rk_sn_pmp(N) + 2 * N + RK_SN_JPAGES;
}

static u64 rk_sn_off_rmap(struct raidkm_snap *sn, unsigned int slot)
{
	return RK_SN_OFF_PMAP + 2 * sn->pmp + slot * sn->N;
}

static u64 rk_sn_off_jrnl(struct raidkm_snap *sn)
{
	return RK_SN_OFF_PMAP + 2 * sn->pmp + 2 * sn->N;
}

/* ---- sealed pages --------------------------------------------------------- */

static u32 rk_sn_crc(const u8 *buf, u32 kind)
{
	return crc32c(0, buf, RK_SN_BODY + 12) ^ kind;
}

static void rk_sn_seal(struct raidkm_snap *sn, u8 *buf, u32 kind, u64 gen)
{
	*(__le32 *)(buf + RK_SN_BODY) = cpu_to_le32(sn->id);
	*(__le64 *)(buf + RK_SN_BODY + 4) = cpu_to_le64(gen);
	*(__le32 *)(buf + RK_SN_BODY + 12) = cpu_to_le32(rk_sn_crc(buf, kind));
}

/* 1 = a good page of this array and kind (*gen set), 0 = all zeroes,
 * -1 = damaged, another kind, or another array's */
static int rk_sn_check(struct raidkm_snap *sn, const u8 *buf, u32 kind,
		       u64 *gen)
{
	if (!memchr_inv(buf, 0, RK_SN_PAGE))
		return 0;
	if (le32_to_cpu(*(const __le32 *)(buf + RK_SN_BODY + 12)) !=
	    rk_sn_crc(buf, kind) ||
	    le32_to_cpu(*(const __le32 *)(buf + RK_SN_BODY)) != sn->id)
		return -1;
	*gen = le64_to_cpu(*(const __le64 *)(buf + RK_SN_BODY + 4));
	return 1;
}

/* ---- member I/O ------------------------------------------------------------ */

/* member slot (disks[i] even, replacement odd), not failed, with a
 * pending reference: the row map's rule, shared */
#define rk_sn_member(conf, slot)	raidkm_rowmap_member(conf, slot)

struct rk_sn_iob {
	atomic_t		pending;
	struct completion	done;
};

static void rk_sn_io_endio(struct bio *bio)
{
	struct rk_sn_iob *iob = bio->bi_private;

	if (atomic_dec_and_test(&iob->pending))
		complete(&iob->done);
}

/*
 * Write n pages (n == 0: an empty flush) at region page @pg of every member
 * that is not failed, all at once, and wait.  A member that fails it is
 * md_error()ed.  Returns how many members took it, -1 when there was no
 * member to write to.
 */
static int rk_sn_write_all(struct raidkm_snap *sn, u64 pg, struct page **pages,
			   unsigned int n, blk_opf_t opf)
{
	struct r5conf *conf = sn->conf;
	struct mddev *mddev = conf->mddev;
	int slots = conf->raid_disks * 2, slot, ok = 0, tried = 0;
	struct md_rdev **rdevs = sn->io_rdevs;
	struct bio **bios = sn->io_bios;
	struct rk_sn_iob iob;
	unsigned int j;

	/* the commit worker is the only caller: the arrays are its own */
	memset(rdevs, 0, slots * sizeof(*rdevs));
	atomic_set(&iob.pending, 1);
	init_completion(&iob.done);
	for (slot = 0; slot < slots; slot++) {
		struct md_rdev *rdev = rk_sn_member(conf, slot);
		struct bio *bio;

		if (!rdev)
			continue;
		rdevs[slot] = rdev;
		bio = bio_alloc(rdev->bdev, n, opf, GFP_NOIO);
		if (n)
			bio->bi_iter.bi_sector = rdev->data_offset + sn->region +
						 pg * (RK_SN_PAGE >> 9);
		for (j = 0; j < n; j++)
			__bio_add_page(bio, pages[j], RK_SN_PAGE, 0);
		bio->bi_private = &iob;
		bio->bi_end_io = rk_sn_io_endio;
		bios[slot] = bio;
		atomic_inc(&iob.pending);
		tried++;
		submit_bio(bio);
	}
	if (!atomic_dec_and_test(&iob.pending))
		wait_for_completion_io(&iob.done);
	for (slot = 0; slot < slots; slot++) {
		if (!rdevs[slot])
			continue;
		if (bios[slot]->bi_status) {
			pr_err_ratelimited("md/raid:%s: snap: metadata write to %pg failed (%d)\n",
					   mdname(mddev), rdevs[slot]->bdev,
					   blk_status_to_errno(bios[slot]->bi_status));
			md_error(mddev, rdevs[slot]);
		} else {
			ok++;
		}
		bio_put(bios[slot]);
		rdev_dec_pending(rdevs[slot], mddev);
	}
	return tried ? ok : -1;
}

/* an empty flush to every member; false: none took it */
static bool rk_sn_flush_all(struct raidkm_snap *sn)
{
	return rk_sn_write_all(sn, 0, NULL, 0,
			       REQ_OP_WRITE | REQ_PREFLUSH | REQ_SYNC) > 0;
}

/* write n pages and count it as done when at least one member took them
 * (each failed member is md_error()ed: the array is degraded, the copies
 * that remain are the ones it reads) */
static bool rk_sn_put(struct raidkm_snap *sn, u64 pg, struct page **pages,
		      unsigned int n, blk_opf_t flags)
{
	return rk_sn_write_all(sn, pg, pages, n, REQ_OP_WRITE | flags) > 0;
}

/*
 * Read region page @pg of this kind into @page: from in-sync members only,
 * as the row map (a member not (yet) in sync may hold pages from before it
 * left), a copy whose gen is in [lo, hi].  lo == hi: the first such copy
 * (every member got the same one).  A range: the NEWEST across all of
 * them -- a crash in the middle of writing a header leaves members with
 * different ones, and a stale member forced back in sync must not win by
 * answering first.  1 = found (*gen), 0 = zeroes on every member read,
 * -1 = no copy in range and something not zero.  Load only (GFP_KERNEL).
 */
static int rk_sn_get(struct raidkm_snap *sn, u64 pg, struct page *page,
		     u32 kind, u64 lo, u64 hi, u64 *gen)
{
	struct r5conf *conf = sn->conf;
	struct mddev *mddev = conf->mddev;
	u8 *buf = page_address(page), *tmp;
	bool bad = false, have = false;
	u64 best = 0;
	int slot, r;

	tmp = kmalloc(RK_SN_PAGE, GFP_KERNEL);
	if (!tmp)
		return -1;
	for (slot = 0; slot < conf->raid_disks * 2; slot++) {
		struct md_rdev *rdev = rk_sn_member(conf, slot);
		u64 g;

		if (!rdev)
			continue;
		r = -2;
		if (rdev->raid_disk >= 0 && test_bit(In_sync, &rdev->flags) &&
		    sync_page_io(rdev, sn->region + pg * (RK_SN_PAGE >> 9),
				 RK_SN_PAGE, page, REQ_OP_READ, false))
			r = rk_sn_check(sn, buf, kind, &g);
		rdev_dec_pending(rdev, mddev);
		if (r == 1 && g >= lo && g <= hi) {
			if (!have || g > best) {
				memcpy(tmp, buf, RK_SN_PAGE);
				best = g;
				have = true;
			}
			if (lo == hi)
				break;
		} else if (r == 1 || r == -1) {
			bad = true;
		}
	}
	if (have) {
		memcpy(buf, tmp, RK_SN_PAGE);
		*gen = best;
	}
	kfree(tmp);
	return have ? 1 : bad ? -1 : 0;
}

/* ---- the reverse map ---------------------------------------------------------- */

static void rk_sn_default(struct raidkm_snap *sn, u64 P, u16 *owner, u32 *L)
{
	if (P < sn->O) {
		*owner = RK_SN_OWN_ORIGIN;
		*L = P;
	} else {
		*owner = RK_SN_OWN_FREE;
		*L = 0;
	}
}

void rk_sn_rmap_get(struct raidkm_snap *sn, u64 P, u16 *owner, u32 *L)
{
	void *e = xa_load(&sn->rmap, P);

	if (!e) {
		rk_sn_default(sn, P, owner, L);
		return;
	}
	*owner = xa_to_value(e) >> 32;
	*L = (u32)xa_to_value(e);
}

/* rmap[P] = {L, owner}; the commit worker (or the load) only */
void rk_sn_rmap_set(struct raidkm_snap *sn, u64 P, u32 L, u16 owner)
{
	u16 dow;
	u32 dL;

	rk_sn_default(sn, P, &dow, &dL);
	if (owner == RK_SN_OWN_FREE)
		L = 0;
	if (owner == dow && L == dL)
		xa_erase(&sn->rmap, P);
	else
		xa_store(&sn->rmap, P, xa_mk_value(((u64)owner << 32) | L),
			 GFP_NOIO | __GFP_NOFAIL);
	__set_bit(div_u64(P, RK_SN_RMAP_PER_PAGE), sn->rdirty);
}

/* ---- journal records ------------------------------------------------------------- */

static unsigned int rk_sn_op_size(struct rk_snap_op *op)
{
	switch (op->type) {
	case RK_OP_REDIRECT:	return 1 + 12;
	case RK_OP_CREATE:	return 1 + 1 + 4 + 8 + RK_SNAP_NAME + 2 + strlen(op->g->attrs);
	case RK_OP_DESTROY:	return 1 + 1;
	case RK_OP_RENAME:	return 1 + 1 + RK_SNAP_NAME;
	case RK_OP_SET:		return 1 + 1 + 2 + strlen(op->text);
	}
	return 0;
}

static u8 *rk_sn_op_put(u8 *p, struct rk_snap_op *op)
{
	*p++ = op->type;
	switch (op->type) {
	case RK_OP_REDIRECT:
		rk_put32(op->L, p);
		rk_put32(op->oldP, p + 4);
		rk_put32(op->newP, p + 8);
		return p + 12;
	case RK_OP_CREATE:
		*p++ = op->slot;
		rk_put32(op->g->id, p);
		rk_put64(op->g->ctime, p + 4);
		memcpy(p + 12, op->g->name, RK_SNAP_NAME);
		p += 12 + RK_SNAP_NAME;
		/* the attributes: a snapshot never exists without them, also
		 * when the create is replayed before any checkpoint */
		rk_put16(strlen(op->g->attrs), p);
		memcpy(p + 2, op->g->attrs, strlen(op->g->attrs));
		return p + 2 + strlen(op->g->attrs);
	case RK_OP_DESTROY:
		*p++ = op->slot;
		return p;
	case RK_OP_RENAME:
		*p++ = op->slot;
		memset(p, 0, RK_SNAP_NAME);
		strscpy(p, op->text, RK_SNAP_NAME);
		return p + RK_SNAP_NAME;
	case RK_OP_SET: {
		u16 n = strlen(op->text);

		*p++ = op->slot;
		rk_put16(n, p);
		memcpy(p + 2, op->text, n);
		return p + 2 + n;
	}
	}
	return p;
}

/* parse one op at p (end: the record's end) into op; the text, if any, is
 * kmalloc'ed.  NULL: malformed. */
static const u8 *rk_sn_op_get(struct raidkm_snap *sn, const u8 *p,
			      const u8 *end, struct rk_snap_op *op)
{
	memset(op, 0, sizeof(*op));
	if (p >= end)
		return NULL;
	op->type = *p++;
	switch (op->type) {
	case RK_OP_REDIRECT:
		if (end - p < 12)
			return NULL;
		op->L = rk_get32(p);
		op->oldP = rk_get32(p + 4);
		op->newP = rk_get32(p + 8);
		return p + 12;
	case RK_OP_CREATE: {
		struct raidkm_snap_one *g;
		u16 n;

		if (end - p < 1 + 12 + RK_SNAP_NAME + 2)
			return NULL;
		n = rk_get16(p + 1 + 12 + RK_SNAP_NAME);
		if (n >= RK_SNAP_ATTRS || end - p < 1 + 12 + RK_SNAP_NAME + 2 + n)
			return NULL;
		g = kzalloc(sizeof(*g), GFP_KERNEL);
		if (!g)
			return NULL;
		op->slot = *p++;
		g->id = rk_get32(p);
		g->ctime = rk_get64(p + 4);
		memcpy(g->name, p + 12, RK_SNAP_NAME);
		g->name[RK_SNAP_NAME - 1] = 0;
		p += 12 + RK_SNAP_NAME + 2;
		memcpy(g->attrs, p, n);		/* kzalloc'ed: terminated */
		g->slot = op->slot;
		g->sn = sn;
		xa_init(&g->exc);
		op->g = g;
		return p + n;
	}
	case RK_OP_DESTROY:
		if (end - p < 1)
			return NULL;
		op->slot = *p++;
		return p;
	case RK_OP_RENAME:
		if (end - p < 1 + RK_SNAP_NAME)
			return NULL;
		op->slot = *p++;
		op->text = kstrndup(p, RK_SNAP_NAME - 1, GFP_KERNEL);
		return op->text ? p + RK_SNAP_NAME : NULL;
	case RK_OP_SET: {
		u16 n;

		if (end - p < 3)
			return NULL;
		op->slot = *p++;
		n = rk_get16(p);
		if (n >= RK_SNAP_ATTRS || end - p < 2 + n)
			return NULL;
		op->text = kstrndup(p + 2, n, GFP_KERNEL);
		return op->text ? p + 2 + n : NULL;
	}
	}
	return NULL;
}

/* undo: no record naming this op reached any member */
static void rk_sn_op_finish(struct raidkm_snap *sn, struct rk_snap_op *op,
			    int err, bool undo)
{
	if (op->type == RK_OP_REDIRECT) {
		/* the data write failed, or the commit failed before any
		 * record went out: nothing points at newP, it is free again.
		 * A record may be on a member: newP stays taken. */
		rk_snap_cow_finish(sn, container_of(op, struct rk_snap_cow, op),
				   err ? BLK_STS_IOERR : op->status,
				   op->status || (err && undo));
		return;
	}
	op->err = err;
	complete(op->done);
}

/* ---- checkpoint --------------------------------------------------------------- */

/* the rmap entries of page p into buf; false: all default */
static bool rk_sn_rmap_page(struct raidkm_snap *sn, u64 p, u8 *buf)
{
	u64 first = p * RK_SN_RMAP_PER_PAGE, P;
	struct rk_sn_rent *r = (struct rk_sn_rent *)buf;
	unsigned long idx;
	bool any = false;
	void *e;

	memset(buf, 0, RK_SN_PAGE);
	xa_for_each_range(&sn->rmap, idx, e, first,
			  first + RK_SN_RMAP_PER_PAGE - 1) {
		P = idx - first;
		r[P].L = cpu_to_le32((u32)xa_to_value(e));
		r[P].owner = cpu_to_le16(xa_to_value(e) >> 32);
		any = true;
	}
	return any;
}

/*
 * Write the checkpoint ckpt + 1.  full: every touched rmap page, not only
 * the changed ones (a member about to be rebuilt gets the whole region).
 * The commit worker only (or the caller of rk_sn_checkpoint_sync, which
 * runs it there).
 */
static int rk_sn_checkpoint(struct raidkm_snap *sn, bool full)
{
	struct mddev *mddev = sn->conf->mddev;
	u64 c = sn->ckpt + 1, p, run_p = 0;
	unsigned int n = 0, run_t = 0, i, k;
	struct rk_sn_hdr *h;
	struct raidkm_snap_one *g;
	u8 *buf;

	if (sn->broken)
		return -EIO;
	if (mddev->ro)
		return -EROFS;		/* nothing written: not a checkpoint */

	/* 1. rmap pages, each into its other slot */
	for (p = 0; p < sn->N; p++) {
		bool dirty = test_bit(p, sn->rdirty);
		bool touched = sn->pmap[p] & RK_SN_PM_TOUCHED;
		unsigned int t;

		if (!dirty && !(full && touched))
			continue;
		/* built in the spare page; it joins the run when contiguous */
		buf = page_address(sn->cbuf[RK_SN_CBUF]);
		if (!rk_sn_rmap_page(sn, p, buf)) {
			/* all default again: never read, never written */
			sn->pmap[p] = 0;
			continue;
		}
		t = touched && !(sn->pmap[p] & RK_SN_PM_SLOT);
		if (n && (n == RK_SN_CBUF || t != run_t || p != run_p + n)) {
			if (!rk_sn_put(sn, rk_sn_off_rmap(sn, run_t) + run_p,
				       sn->cbuf, n, 0))
				goto fail;
			n = 0;
		}
		if (!n) {
			run_p = p;
			run_t = t;
		}
		rk_sn_seal(sn, buf, RK_SN_MAGIC_RMAP, c);
		memcpy(page_address(sn->cbuf[n]), buf, RK_SN_PAGE);
		sn->pmap[p] = RK_SN_PM_TOUCHED | (t ? RK_SN_PM_SLOT : 0);
		n++;
	}
	if (n && !rk_sn_put(sn, rk_sn_off_rmap(sn, run_t) + run_p, sn->cbuf, n, 0))
		goto fail;
	if (!rk_sn_flush_all(sn))
		goto fail;

	/* 2. pmap and table into copy c & 1 (the pmap in runs of cbuf) */
	for (p = 0; p < sn->pmp; p += n) {
		n = min_t(u64, RK_SN_CBUF, sn->pmp - p);
		for (i = 0; i < n; i++) {
			u64 first = (p + i) * RK_SN_PMAP_PER_PAGE;
			u64 cnt = min_t(u64, RK_SN_PMAP_PER_PAGE, sn->N - first);

			buf = page_address(sn->cbuf[i]);
			memset(buf, 0, RK_SN_PAGE);
			memcpy(buf, sn->pmap + first, cnt);
			rk_sn_seal(sn, buf, RK_SN_MAGIC_PMAP, c);
		}
		if (!rk_sn_put(sn, RK_SN_OFF_PMAP + (c & 1) * sn->pmp + p,
			       sn->cbuf, n, 0))
			goto fail;
	}
	for (i = 0; i < RK_SN_TBL_PAGES; i++) {
		buf = page_address(sn->cbuf[i]);
		memset(buf, 0, RK_SN_PAGE);
	}
	list_for_each_entry(g, &sn->snaps, list) {
		struct rk_sn_tent *t;

		i = g->slot / RK_SN_TBL_PER_PAGE;
		k = g->slot % RK_SN_TBL_PER_PAGE;
		t = (struct rk_sn_tent *)page_address(sn->cbuf[i]) + k;
		t->id = cpu_to_le32(g->id);
		t->used = cpu_to_le32(1);
		t->ctime = cpu_to_le64(g->ctime);
		memcpy(t->name, g->name, RK_SNAP_NAME);
		memcpy(t->attrs, g->attrs, RK_SNAP_ATTRS);
	}
	for (i = 0; i < RK_SN_TBL_PAGES; i++)
		rk_sn_seal(sn, page_address(sn->cbuf[i]), RK_SN_MAGIC_TBL, c);
	if (!rk_sn_put(sn, RK_SN_OFF_TBL + (c & 1) * RK_SN_TBL_PAGES, sn->cbuf,
		       RK_SN_TBL_PAGES, 0) ||
	    !rk_sn_flush_all(sn))
		goto fail;

	/* 3. the header: c is the checkpoint from here */
	buf = page_address(sn->cbuf[0]);
	memset(buf, 0, RK_SN_PAGE);
	h = (struct rk_sn_hdr *)buf;
	h->magic = cpu_to_le32(RK_SN_MAGIC_HDR);
	h->version = cpu_to_le32(RK_SN_VERSION);
	h->reserve_pct = cpu_to_le32(sn->reserve_pct);
	h->jpages = cpu_to_le32(RK_SN_JPAGES);
	h->R = cpu_to_le64(sn->R);
	h->O = cpu_to_le64(sn->O);
	h->rs = cpu_to_le64(sn->rs);
	h->ckpt = cpu_to_le64(c);
	h->jtail = cpu_to_le64(sn->jhead);
	h->next_id = cpu_to_le32(sn->next_id);
	h->slots = cpu_to_le32(RK_SNAP_SLOTS);
	h->rmap_pages = cpu_to_le64(sn->N);
	rk_sn_seal(sn, buf, RK_SN_MAGIC_HDR, c);
	if (!rk_sn_put(sn, RK_SN_OFF_HDR + (c & 1), sn->cbuf, 1,
		       REQ_FUA | REQ_SYNC))
		goto fail;

	sn->ckpt = c;
	sn->jtail = sn->jhead;
	bitmap_zero(sn->rdirty, sn->N);
	atomic64_inc(&sn->ckpts);
	return 0;
fail:
	pr_err("md/raid:%s: snap: checkpoint %llu reached no member; snapshot metadata is read-only from now\n",
	       mdname(mddev), c);
	sn->broken = true;
	return -EIO;
}

/* ---- commit ----------------------------------------------------------------- */

/*
 * After a load the ring past the head may still hold good records: a
 * commit writes up to RK_SN_JBUF records at once, and a crash that tore
 * one of them leaves the ones after it intact -- replay stopped at the torn
 * one.  Once new records reuse the head, a later replay would run on into
 * those old ones.  So before the first new record, every slot a torn batch
 * can have reached ([jhead, jhead + RK_SN_JBUF)) is zeroed, FUA.  (Today a
 * batch fits one record -- at most RK_SNAP_COWS redirects of 13 bytes and
 * one command, the commands being serial -- so this guards the format
 * against larger batches; it costs 128 KiB once per assemble.)
 */
static bool rk_sn_scrub_ring(struct raidkm_snap *sn)
{
	struct page *z[RK_SN_JBUF];
	u64 base = rk_sn_off_jrnl(sn), idx = rk_sn_jidx(sn->jhead);
	unsigned int first = min_t(u64, RK_SN_JBUF, RK_SN_JPAGES - idx), i;
	blk_opf_t f = REQ_FUA | REQ_SYNC;

	for (i = 0; i < RK_SN_JBUF; i++)
		z[i] = ZERO_PAGE(0);
	if (!rk_sn_put(sn, base + idx, z, first, f))
		return false;
	if (first < RK_SN_JBUF && !rk_sn_put(sn, base, z, RK_SN_JBUF - first, f))
		return false;
	sn->jscrub = false;
	return true;
}

/*
 * Before the first record after a load.  Replay may have taken the last
 * record from one member only (a crash while it was being written): new
 * records after it would leave the other members' rings with a hole in
 * the middle, and losing that member later would lose every record after
 * the hole.  So what replay applied goes into a checkpoint first (every
 * member; the tail moves past it), then the ring past the head is scrubbed.
 */
static bool rk_sn_settle(struct raidkm_snap *sn)
{
	if (!sn->jscrub)
		return true;
	if (sn->jhead != sn->jtail && rk_sn_checkpoint(sn, false))
		return false;
	return rk_sn_scrub_ring(sn);
}

/* write records [0, n) of jbuf as seq jhead.. into the ring */
static bool rk_sn_put_records(struct raidkm_snap *sn, unsigned int n)
{
	u64 base = rk_sn_off_jrnl(sn);
	u64 idx = rk_sn_jidx(sn->jhead);
	unsigned int first = min_t(u64, n, RK_SN_JPAGES - idx);
	blk_opf_t f = REQ_FUA | REQ_SYNC;

	if (!rk_sn_put(sn, base + idx, sn->jbuf, first, f))
		return false;
	if (first < n && !rk_sn_put(sn, base, sn->jbuf + first, n - first, f))
		return false;
	return true;
}

void rk_sn_commit_fn(struct work_struct *work)
{
	struct raidkm_snap *sn = container_of(work, struct raidkm_snap,
					      commit_work);
	struct rk_snap_op *op, *t;

	for (;;) {
		LIST_HEAD(batch);
		LIST_HEAD(fit);
		struct rk_snap_op *stop = NULL;
		unsigned int nrec = 0, used = RK_SN_JMAX;
		u8 *rec = NULL, *p = NULL;
		bool undo = false;
		int err = 0;

		spin_lock_irq(&sn->lock);
		list_splice_init(&sn->pending, &batch);
		spin_unlock_irq(&sn->lock);
		if (list_empty(&batch))
			break;

		list_for_each_entry_safe(op, t, &batch, node) {
			unsigned int sz;

			/* a COW whose data write failed: no record, undone */
			if (op->type == RK_OP_REDIRECT && op->status) {
				list_del(&op->node);
				rk_sn_op_finish(sn, op, 0, true);
				continue;
			}
			sz = rk_sn_op_size(op);
			if (used + sz > RK_SN_JMAX) {
				if (nrec == RK_SN_JBUF) {
					/* the records are full: from here on
					 * in the next round */
					stop = op;
					break;
				}
				if (rec)
					rk_put16(p - rec - RK_SN_JHDR,
							   rec + 8);
				rec = page_address(sn->jbuf[nrec]);
				memset(rec, 0, RK_SN_PAGE);
				rk_put64(sn->jhead + nrec, rec);
				p = rec + RK_SN_JHDR;
				used = 0;
				nrec++;
			}
			p = rk_sn_op_put(p, op);
			used += sz;
		}
		if (stop) {
			list_cut_before(&fit, &batch, &stop->node);
			/* back in front of whatever came meanwhile: in order */
			spin_lock_irq(&sn->lock);
			list_splice(&batch, &sn->pending);
			spin_unlock_irq(&sn->lock);
			INIT_LIST_HEAD(&batch);
			list_splice_init(&fit, &batch);
		}
		if (rec)
			rk_put16(p - rec - RK_SN_JHDR, rec + 8);

		if (nrec) {
			bool data = false;
			unsigned int i;

			/* a redirect's new row, and what a create's snapshot
			 * holds, must be durable before the record says so;
			 * rename/set/destroy depend on no data */
			list_for_each_entry(op, &batch, node)
				if (op->type == RK_OP_REDIRECT ||
				    op->type == RK_OP_CREATE) {
					data = true;
					break;
				}
			for (i = 0; i < nrec; i++)
				rk_sn_seal(sn, page_address(sn->jbuf[i]),
					   RK_SN_MAGIC_JRNL, sn->jhead + i);
			if (sn->broken || !rk_sn_settle(sn) ||
			    (data && !rk_sn_flush_all(sn))) {
				/* no record reached a member: undone */
				err = -EIO;
				undo = true;
			} else if (!rk_sn_put_records(sn, nrec)) {
				/* a member may hold part of it: newP stays */
				err = -EIO;
			} else {
				sn->jhead += nrec;
				atomic64_inc(&sn->commits);
				atomic64_add(nrec, &sn->records);
			}
			if (err && !sn->broken) {
				pr_err("md/raid:%s: snap: journal commit reached no member; snapshot metadata is read-only from now\n",
				       mdname(sn->conf->mddev));
				sn->broken = true;
			}
		}
		list_for_each_entry_safe(op, t, &batch, node) {
			list_del(&op->node);
			if (!err)
				rk_snap_apply(sn, op, false);
			rk_sn_op_finish(sn, op, err, undo);
		}
		if (!sn->broken && sn->jhead - sn->jtail >= RK_SN_JPAGES / 2)
			rk_sn_checkpoint(sn, false);
	}
}

/*
 * The array may be written: read-only refuses, auto-read-only (md's state
 * after an assemble until the first write) switches to read-write exactly
 * as md_write_start() does for that first write -- a snapshot command
 * writes the members too, and a snapshot is often taken right after an
 * assemble, before anything else wrote.
 */
static int rk_sn_writable(struct mddev *mddev)
{
	if (mddev->ro == MD_RDONLY)
		return -EROFS;
	if (mddev->ro == MD_AUTO_READ) {
		flush_work(&mddev->sync_work);
		mddev->ro = MD_RDWR;
		set_bit(MD_RECOVERY_NEEDED, &mddev->recovery);
		md_wakeup_thread(mddev->thread);
		md_wakeup_thread(mddev->sync_thread);
		sysfs_notify_dirent_safe(mddev->sysfs_state);
	}
	return 0;
}

/* queue a create/destroy/rename/set and wait until it is durable and
 * applied (or failed: nothing changed) */
int rk_sn_submit_sync(struct raidkm_snap *sn, struct rk_snap_op *op)
{
	DECLARE_COMPLETION_ONSTACK(done);
	int err = rk_sn_writable(sn->conf->mddev);

	if (err)
		return err;
	op->done = &done;
	spin_lock_irq(&sn->lock);
	list_add_tail(&op->node, &sn->pending);
	spin_unlock_irq(&sn->lock);
	queue_work(sn->cwq, &sn->commit_work);
	wait_for_completion(&done);
	return op->err;
}

struct rk_sn_ckpt_work {
	struct work_struct	work;
	struct raidkm_snap	*sn;
	bool			full;
	int			err;
};

static void rk_sn_ckpt_fn(struct work_struct *work)
{
	struct rk_sn_ckpt_work *w = container_of(work, struct rk_sn_ckpt_work,
						 work);

	/* whatever was queued before goes first */
	rk_sn_commit_fn(&w->sn->commit_work);
	w->err = rk_sn_checkpoint(w->sn, w->full);
}

/* a checkpoint now, on the commit worker (the only writer of the map) */
int rk_sn_checkpoint_sync(struct raidkm_snap *sn, bool full)
{
	struct rk_sn_ckpt_work w = { .sn = sn, .full = full };
	int err = rk_sn_writable(sn->conf->mddev);

	if (err)
		return err;

	INIT_WORK_ONSTACK(&w.work, rk_sn_ckpt_fn);
	queue_work(sn->cwq, &w.work);
	flush_work(&w.work);
	destroy_work_on_stack(&w.work);
	return w.err;
}

/* ---- load at assemble ---------------------------------------------------------- */

static int rk_sn_load_hdr(struct raidkm_snap *sn, struct page *page,
			  u64 *c, u64 *R, u64 *O, u64 *rs, u64 *N)
{
	struct mddev *mddev = sn->conf->mddev;
	struct rk_sn_hdr *h = page_address(page);
	u64 best = 0, gen;
	int i, r, which = -1;
	bool bad = false;

	for (i = 0; i < 2; i++) {
		r = rk_sn_get(sn, RK_SN_OFF_HDR + i, page, RK_SN_MAGIC_HDR,
			      0, U64_MAX, &gen);
		if (r < 0)
			bad = true;
		if (r == 1 && (which < 0 || gen > best)) {
			best = gen;
			which = i;
		}
	}
	if (which < 0) {
		pr_err("md/raid:%s: snap: %s\n", mdname(mddev), bad ?
		       "no good snapshot header on any in-sync member" :
		       "no snapshot header (created without mdadm --snapshots?)");
		return -EUCLEAN;
	}
	r = rk_sn_get(sn, RK_SN_OFF_HDR + which, page, RK_SN_MAGIC_HDR,
		      best, best, &gen);
	if (r != 1 || le32_to_cpu(h->magic) != RK_SN_MAGIC_HDR ||
	    le32_to_cpu(h->version) != RK_SN_VERSION ||
	    le32_to_cpu(h->jpages) != RK_SN_JPAGES ||
	    le32_to_cpu(h->reserve_pct) < 1 || le32_to_cpu(h->reserve_pct) > 90) {
		pr_err("md/raid:%s: snap: snapshot header of an unknown format\n",
		       mdname(mddev));
		return -EUCLEAN;
	}
	*c = le64_to_cpu(h->ckpt);
	if (*c != gen)
		return -EUCLEAN;
	sn->reserve_pct = le32_to_cpu(h->reserve_pct);
	sn->jtail = le64_to_cpu(h->jtail);
	sn->next_id = le32_to_cpu(h->next_id) ?: 1;
	*R = le64_to_cpu(h->R);
	*O = le64_to_cpu(h->O);
	*rs = le64_to_cpu(h->rs);
	*N = le64_to_cpu(h->rmap_pages);
	return 0;
}

static int rk_sn_load_table(struct raidkm_snap *sn, struct page *page, u64 c)
{
	struct mddev *mddev = sn->conf->mddev;
	u8 *buf = page_address(page);
	unsigned int i, k;
	u64 gen;
	int r;

	for (i = 0; i < RK_SN_TBL_PAGES; i++) {
		r = rk_sn_get(sn, RK_SN_OFF_TBL + (c & 1) * RK_SN_TBL_PAGES + i,
			      page, RK_SN_MAGIC_TBL, c, c, &gen);
		if (r != 1) {
			pr_err("md/raid:%s: snap: snapshot table page %u of checkpoint %llu unreadable on every in-sync member\n",
			       mdname(mddev), i, c);
			return -EUCLEAN;
		}
		for (k = 0; k < RK_SN_TBL_PER_PAGE; k++) {
			struct rk_sn_tent *t = (struct rk_sn_tent *)buf + k;
			unsigned int slot = i * RK_SN_TBL_PER_PAGE + k;
			struct raidkm_snap_one *g, *h;

			if (slot >= RK_SNAP_SLOTS || !le32_to_cpu(t->used))
				continue;
			g = kzalloc(sizeof(*g), GFP_KERNEL);
			if (!g)
				return -ENOMEM;
			g->sn = sn;
			g->slot = slot;
			g->id = le32_to_cpu(t->id);
			g->ctime = le64_to_cpu(t->ctime);
			memcpy(g->name, t->name, RK_SNAP_NAME);
			g->name[RK_SNAP_NAME - 1] = 0;
			memcpy(g->attrs, t->attrs, RK_SNAP_ATTRS);
			g->attrs[RK_SNAP_ATTRS - 1] = 0;
			xa_init(&g->exc);
			/* the chain is in id order, oldest first */
			list_for_each_entry(h, &sn->snaps, list)
				if (h->id > g->id)
					break;
			list_add_tail(&g->list, &h->list);
			__set_bit(slot, sn->slots);
			sn->nsnaps++;
		}
	}
	return 0;
}

static int rk_sn_load_maps(struct raidkm_snap *sn, struct page *page, u64 c)
{
	struct mddev *mddev = sn->conf->mddev;
	u8 *buf = page_address(page);
	u64 p, gen, P;
	int r;

	for (p = 0; p < sn->pmp; p++) {
		u64 first = p * RK_SN_PMAP_PER_PAGE;

		r = rk_sn_get(sn, RK_SN_OFF_PMAP + (c & 1) * sn->pmp + p,
			      page, RK_SN_MAGIC_PMAP, c, c, &gen);
		if (r != 1) {
			pr_err("md/raid:%s: snap: pmap page %llu of checkpoint %llu unreadable on every in-sync member\n",
			       mdname(mddev), p, c);
			return -EUCLEAN;
		}
		memcpy(sn->pmap + first, buf,
		       min_t(u64, RK_SN_PMAP_PER_PAGE, sn->N - first));
	}
	for (p = 0; p < sn->N; p++) {
		struct rk_sn_rent *e = (struct rk_sn_rent *)buf;
		unsigned int i, t;

		if (!(sn->pmap[p] & RK_SN_PM_TOUCHED))
			continue;
		t = !!(sn->pmap[p] & RK_SN_PM_SLOT);
		/* the newest copy no later than c: pages of an unfinished
		 * c + 1 went to the other slot */
		r = rk_sn_get(sn, rk_sn_off_rmap(sn, t) + p, page,
			      RK_SN_MAGIC_RMAP, 0, c, &gen);
		if (r != 1) {
			pr_err("md/raid:%s: snap: rmap page %llu unreadable on every in-sync member\n",
			       mdname(mddev), p);
			return -EUCLEAN;
		}
		for (i = 0; i < RK_SN_RMAP_PER_PAGE; i++) {
			u16 owner = le16_to_cpu(e[i].owner);

			P = p * RK_SN_RMAP_PER_PAGE + i;
			if (owner == RK_SN_OWN_DEFAULT)
				continue;
			if (P >= sn->R)
				return -EUCLEAN;
			if (xa_is_err(xa_store(&sn->rmap, P,
					xa_mk_value(((u64)owner << 32) |
						    le32_to_cpu(e[i].L)),
					GFP_KERNEL)))
				return -ENOMEM;
		}
		cond_resched();
	}
	return 0;
}

/*
 * origin, exc, used, shared from the reverse map, with the checks that it
 * is one: every origin row L has exactly one physical row, every row has
 * one owner (by construction), every snapshot row's owner exists.
 */
static int rk_sn_derive(struct raidkm_snap *sn)
{
	struct mddev *mddev = sn->conf->mddev;
	unsigned long *moved, idx;
	struct raidkm_snap_one *g;
	u64 L;
	void *e;
	int err = 0;

	moved = bitmap_zalloc(sn->O, GFP_KERNEL);
	if (!moved)
		return -ENOMEM;
	for (L = 0; L < sn->O; L++)
		sn->origin[L] = L;
	bitmap_set(sn->used, 0, sn->O);
	xa_for_each(&sn->rmap, idx, e) {
		u16 owner = xa_to_value(e) >> 32;
		u32 l = (u32)xa_to_value(e);

		if (owner == RK_SN_OWN_FREE) {
			__clear_bit(idx, sn->used);
		} else if (owner == RK_SN_OWN_ORIGIN) {
			if (l >= sn->O || test_and_set_bit(l, moved) ||
			    !xa_load(&sn->rmap, l)) {
				/* twice the origin of l, or l's home row
				 * still says it is l's */
				err = -EUCLEAN;
				break;
			}
			sn->origin[l] = idx;
			__set_bit(idx, sn->used);
		} else {
			g = rk_snap_slot(sn, owner - RK_SN_OWN_SNAP0);
			if (!g || l >= sn->O) {
				err = -EUCLEAN;
				break;
			}
			if (xa_is_err(xa_store(&g->exc, l, xa_mk_value(idx + 1),
					       GFP_KERNEL))) {
				err = -ENOMEM;
				break;
			}
			g->nexc++;
			__set_bit(idx, sn->used);
		}
		cond_resched();
	}
	/* a row P < O that is not origin row P any more: origin row P must
	 * have moved somewhere */
	if (!err)
		xa_for_each_range(&sn->rmap, idx, e, 0, sn->O - 1) {
			if (!test_bit(idx, moved)) {
				err = -EUCLEAN;
				break;
			}
		}
	bitmap_free(moved);
	if (err) {
		pr_err("md/raid:%s: snap: the reverse map is inconsistent\n",
		       mdname(mddev));
		return err;
	}
	sn->redirected = 0;
	for (L = 0; L < sn->O; L++)
		sn->redirected += sn->origin[L] != L;
	if (sn->nsnaps) {
		g = list_last_entry(&sn->snaps, struct raidkm_snap_one, list);
		bitmap_fill(sn->shared, sn->O);
		xa_for_each(&g->exc, idx, e)
			__clear_bit(idx, sn->shared);
	}
	return 0;
}

/* check a record's op against the state before applying it in replay */
static bool rk_sn_op_valid(struct raidkm_snap *sn, struct rk_snap_op *op)
{
	switch (op->type) {
	case RK_OP_REDIRECT:
		return sn->nsnaps && op->L < sn->O && op->newP < sn->R &&
		       op->oldP < sn->R &&
		       sn->origin[op->L] == op->oldP &&
		       !test_bit(op->newP, sn->used);
	case RK_OP_CREATE:
		return op->slot < RK_SNAP_SLOTS && !test_bit(op->slot, sn->slots);
	case RK_OP_DESTROY:
	case RK_OP_RENAME:
	case RK_OP_SET:
		return op->slot < RK_SNAP_SLOTS && rk_snap_slot(sn, op->slot);
	}
	return false;
}

static int rk_sn_replay(struct raidkm_snap *sn, struct page *page)
{
	struct mddev *mddev = sn->conf->mddev;
	u8 *buf = page_address(page);
	u64 seq = sn->jtail, gen, n = 0;
	int r;

	for (;;) {
		const u8 *p, *end;
		u16 len;

		/* the trailer's gen is the seq: a copy from an older lap of
		 * the ring is not taken */
		r = rk_sn_get(sn, rk_sn_off_jrnl(sn) + rk_sn_jidx(seq), page,
			      RK_SN_MAGIC_JRNL, seq, seq, &gen);
		if (r != 1)
			break;
		len = rk_get16(buf + 8);
		if (len > RK_SN_JMAX)
			return -EUCLEAN;
		p = buf + RK_SN_JHDR;
		end = p + len;
		while (p < end) {
			struct rk_snap_op op;

			p = rk_sn_op_get(sn, p, end, &op);
			if (!p || !rk_sn_op_valid(sn, &op)) {
				pr_err("md/raid:%s: snap: journal record %llu does not apply\n",
				       mdname(mddev), seq);
				if (op.type == RK_OP_CREATE && op.g)
					kfree(op.g);
				kfree(op.text);
				return -EUCLEAN;
			}
			rk_snap_apply(sn, &op, true);
			kfree(op.text);
			n++;
		}
		seq++;
		cond_resched();
	}
	sn->jhead = seq;
	sn->jscrub = true;	/* rk_sn_scrub_ring() before the next record */
	atomic64_set(&sn->replayed, n);
	return 0;
}

int rk_sn_load(struct raidkm_snap *sn)
{
	struct mddev *mddev = sn->conf->mddev;
	struct page *page;
	u64 c, R, O, rs, N;
	int err;

	sn->N = rk_sn_N(sn->R);
	sn->pmp = rk_sn_pmp(sn->N);
	page = alloc_page(GFP_KERNEL);
	if (!page)
		return -ENOMEM;
	err = rk_sn_load_hdr(sn, page, &c, &R, &O, &rs, &N);
	if (err)
		goto out;
	if (!R) {
		/* mdadm's init header: the origin is (100 - pct)% of the rows */
		O = div_u64(sn->R * (100 - sn->reserve_pct), 100);
		if (!O || O >= sn->R) {
			err = -EINVAL;
			goto out;
		}
	} else if (R != sn->R || rs != sn->rs || N != sn->N || !O || O >= R) {
		pr_err("md/raid:%s: snap: header geometry (%llu rows of %llu sectors, origin %llu) does not match the array (%llu rows of %llu)\n",
		       mdname(mddev), R, rs, O, sn->R, sn->rs);
		err = -EUCLEAN;
		goto out;
	}
	sn->O = O;
	sn->ckpt = c;
	err = rk_sn_alloc(sn);
	if (err)
		goto out;
	if (c) {
		err = rk_sn_load_table(sn, page, c);
		if (!err)
			err = rk_sn_load_maps(sn, page, c);
		if (err)
			goto out;
	}
	err = rk_sn_derive(sn);
	if (err)
		goto out;
	err = rk_sn_replay(sn, page);
	if (err)
		goto out;
	pr_info("md/raid:%s: snap: %llu origin rows, %llu reserve rows, %d snapshot(s), checkpoint %llu, %lld journal op(s) replayed\n",
		mdname(mddev), sn->O, sn->R - sn->O, sn->nsnaps, sn->ckpt,
		atomic64_read(&sn->replayed));
out:
	__free_page(page);
	return err;
}

/* the in-core maps once R and O are known */
int rk_sn_alloc(struct raidkm_snap *sn)
{
	unsigned int i;

	sn->origin = kvmalloc_array(sn->O, sizeof(u32), GFP_KERNEL);
	sn->shared = bitmap_zalloc(sn->O, GFP_KERNEL);
	sn->used = bitmap_zalloc(sn->R, GFP_KERNEL);
	sn->pmap = kvzalloc(sn->N, GFP_KERNEL);
	sn->rdirty = bitmap_zalloc(sn->N, GFP_KERNEL);
	sn->jbuf = kcalloc(RK_SN_JBUF, sizeof(*sn->jbuf), GFP_KERNEL);
	sn->io_rdevs = kcalloc(sn->conf->raid_disks * 2, sizeof(*sn->io_rdevs),
			       GFP_KERNEL);
	sn->io_bios = kcalloc(sn->conf->raid_disks * 2, sizeof(*sn->io_bios),
			      GFP_KERNEL);
	/* + 1: a spare page to hold one while a run is written */
	sn->cbuf = kcalloc(RK_SN_CBUF + 1, sizeof(*sn->cbuf), GFP_KERNEL);
	if (!sn->origin || !sn->shared || !sn->used || !sn->pmap ||
	    !sn->rdirty || !sn->jbuf || !sn->cbuf || !sn->io_rdevs ||
	    !sn->io_bios)
		return -ENOMEM;
	for (i = 0; i < RK_SN_JBUF; i++)
		if (!(sn->jbuf[i] = alloc_page(GFP_KERNEL)))
			return -ENOMEM;
	for (i = 0; i <= RK_SN_CBUF; i++)
		if (!(sn->cbuf[i] = alloc_page(GFP_KERNEL)))
			return -ENOMEM;
	return 0;
}

void rk_sn_free(struct raidkm_snap *sn)
{
	unsigned int i;

	if (sn->jbuf)
		for (i = 0; i < RK_SN_JBUF; i++)
			if (sn->jbuf[i])
				__free_page(sn->jbuf[i]);
	if (sn->cbuf)
		for (i = 0; i <= RK_SN_CBUF; i++)
			if (sn->cbuf[i])
				__free_page(sn->cbuf[i]);
	kfree(sn->jbuf);
	kfree(sn->cbuf);
	kfree(sn->io_rdevs);
	kfree(sn->io_bios);
	xa_destroy(&sn->rmap);
	kvfree(sn->pmap);
	bitmap_free(sn->rdirty);
	kvfree(sn->origin);
	bitmap_free(sn->shared);
	bitmap_free(sn->used);
}
