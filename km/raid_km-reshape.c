// SPDX-License-Identifier: GPL-2.0
/*
 * raid_km-reshape.c — COW-staged online reshape for raidkm (level 71).
 *
 * This file holds the journal + scratch-region I/O primitives that the
 * (forthcoming) per-band migration loop and the assembly-time recovery both
 * build on.  See md-kmec/notes/reshape-cow-design.md.
 *
 * The on-disk journal record (struct raidkm_reshape_journal) is written
 * double-buffered (two slots, the highest valid seq wins) and replicated to
 * every healthy member, so it survives up to the array's fault tolerance with
 * no extra mirroring.  Records are FUA + PREFLUSH so a phase boundary is durable
 * before the next step begins.
 */

#include <linux/kernel.h>
#include <linux/blkdev.h>
#include <linux/gfp.h>
#include <linux/crc32c.h>

#include "md.h"
#include "raid_km.h"

/* crc32c over the record with hdr_csum treated as zero (host order). */
static u32 raidkm_rj_csum(struct raidkm_reshape_journal *rj)
{
	__le32 saved = rj->hdr_csum;
	u32 c;

	rj->hdr_csum = 0;
	c = ~crc32c_le(~0, (void *)rj, sizeof(*rj));
	rj->hdr_csum = saved;
	return c;
}

/*
 * I/O to a member's scratch zone, which lives in the gap just below
 * data_offset (md uses no data there; under dm-raid it is the front reshape
 * space LVM leaves unused).  @local is the byte-page sector within the zone
 * [0, RAIDKM_RESHAPE_SCRATCH_SECTORS): abs = data_offset - SCRATCH + local.
 * raidkm_check_reshape guarantees the headroom (data_offset >= sb_start +
 * SCRATCH + margin) before any reshape starts.
 *
 * The bio is built directly on rdev->bdev at the absolute sector instead of
 * going through sync_page_io: its metadata_op base would route to
 * rdev->meta_bdev when one exists (dm-raid keeps metadata on a separate
 * device, where these sectors mean something else entirely), and its data-op
 * base rebases onto data_offset/new_data_offset, which cannot address below
 * data_offset.
 */
int raidkm_scratch_io(struct md_rdev *rdev, sector_t local, struct page *page,
		      blk_opf_t op)
{
	struct bio bio;
	struct bio_vec bvec;

	bio_init(&bio, rdev->bdev, &bvec, 1, op);
	bio.bi_iter.bi_sector = rdev->data_offset -
		RAIDKM_RESHAPE_SCRATCH_SECTORS + local;
	__bio_add_page(&bio, page, PAGE_SIZE, 0);
	submit_bio_wait(&bio);

	return !bio.bi_status;
}

/*
 * Write the journal record for @phase to the active slot (jseq & 1) on every
 * healthy member, then advance ctx->jseq.  Returns 0 if at least one member
 * took the write, -EIO if none did, -ENOMEM on allocation failure.
 */
int raidkm_reshape_jwrite(struct r5conf *conf, struct raidkm_reshape_ctx *ctx,
			  enum raidkm_reshape_phase phase, u64 band_start_chunk,
			  u32 band_chunks, u32 data_csum, sector_t reshape_position)
{
	struct page *page;
	struct raidkm_reshape_journal *rj;
	sector_t slot_local;
	int i, nwritten = 0;

	page = alloc_page(GFP_KERNEL);
	if (!page)
		return -ENOMEM;
	rj = page_address(page);
	memset(rj, 0, sizeof(*rj));
	rj->magic		= cpu_to_le32(RAIDKM_RJ_MAGIC);
	rj->version		= cpu_to_le32(RAIDKM_RJ_VERSION);
	rj->seq			= cpu_to_le64(ctx->jseq);
	rj->band_start_chunk	= cpu_to_le64(band_start_chunk);
	rj->band_chunks		= cpu_to_le32(band_chunks);
	rj->phase		= cpu_to_le32(phase);
	rj->old_m		= cpu_to_le32(ctx->old_m);
	rj->new_m		= cpu_to_le32(ctx->new_m);
	rj->old_raid_disks	= cpu_to_le32(ctx->old_raid_disks);
	rj->new_raid_disks	= cpu_to_le32(ctx->new_raid_disks);
	rj->chunk_sectors	= cpu_to_le32(ctx->chunk_sectors);
	rj->scratch_rows	= cpu_to_le32(ctx->scratch_rows);
	rj->reshape_position	= cpu_to_le64(reshape_position);
	rj->data_csum		= cpu_to_le32(data_csum);
	rj->hdr_csum		= cpu_to_le32(raidkm_rj_csum(rj));

	slot_local = (ctx->jseq & (RAIDKM_RJ_SLOTS - 1)) * RAIDKM_PAGE_SECTORS;

	for (i = 0; i < conf->raid_disks; i++) {
		struct md_rdev *rdev = conf->disks[i].rdev;

		if (!rdev || test_bit(Faulty, &rdev->flags) ||
		    !test_bit(In_sync, &rdev->flags))
			continue;
		if (raidkm_scratch_io(rdev, slot_local, page,
				      REQ_OP_WRITE | REQ_FUA | REQ_PREFLUSH))
			nwritten++;
	}

	__free_page(page);
	if (nwritten == 0)
		return -EIO;
	ctx->jseq++;
	return 0;
}

/*
 * Initialize the reshape journal: overwrite BOTH slots on every healthy member
 * with fresh IDLE records.  Called when a reshape STARTS (raid5_start_reshape),
 * so a stale journal left in the scratch zone by a previous array on the same
 * devices can never be mistaken for this reshape's state — without this, a
 * leftover DONE record (e.g. on reused LVM PVs, which nobody zeroes) made
 * recovery "resume" past the end and finalize the new geometry without
 * migrating anything.
 */
int raidkm_reshape_journal_init(struct r5conf *conf, struct raidkm_reshape_ctx *ctx)
{
	int slot, err;

	for (slot = 0; slot < RAIDKM_RJ_SLOTS; slot++) {
		err = raidkm_reshape_jwrite(conf, ctx, RAIDKM_PH_IDLE, 0, 0, 0, 0);
		if (err)
			return err;
	}
	return 0;
}

/*
 * Scan both journal slots on every healthy member and copy the record with the
 * highest seq that has a valid magic/version/hdr_csum into @out.  Returns 0 if
 * a valid record was found, -ENOENT if none, -ENOMEM on allocation failure.
 */
int raidkm_reshape_jread(struct r5conf *conf, struct raidkm_reshape_journal *out)
{
	struct page *page;
	struct raidkm_reshape_journal *rj;
	u64 best_seq = 0;
	bool found = false;
	int i, slot;

	page = alloc_page(GFP_KERNEL);
	if (!page)
		return -ENOMEM;
	rj = page_address(page);

	for (i = 0; i < conf->raid_disks; i++) {
		struct md_rdev *rdev = conf->disks[i].rdev;

		if (!rdev || test_bit(Faulty, &rdev->flags))
			continue;
		for (slot = 0; slot < RAIDKM_RJ_SLOTS; slot++) {
			u64 seq;

			if (!raidkm_scratch_io(rdev, slot * RAIDKM_PAGE_SECTORS,
					       page, REQ_OP_READ))
				continue;
			if (le32_to_cpu(rj->magic) != RAIDKM_RJ_MAGIC ||
			    le32_to_cpu(rj->version) != RAIDKM_RJ_VERSION ||
			    le32_to_cpu(rj->hdr_csum) != raidkm_rj_csum(rj))
				continue;
			seq = le64_to_cpu(rj->seq);
			if (!found || seq >= best_seq) {
				best_seq = seq;
				memcpy(out, rj, sizeof(*out));
				found = true;
			}
		}
	}

	__free_page(page);
	return found ? 0 : -ENOENT;
}

void raidkm_reshape_row_layout(int raid_disks, int m, bool rotating,
			       sector_t row, int *data_slot, int *parity_slot)
{
	int k = raid_disks - m;
	int pd_idx, d, p;

	if (rotating) {
		sector_t r = row;
		/* pd_idx = raid_disks - 1 - (row mod raid_disks) */
		pd_idx = raid_disks - 1 - (int)sector_div(r, raid_disks);
	} else {
		pd_idx = k;	/* PARITY_N: parity at the tail [k, raid_disks) */
	}

	/* m parity slots are pd_idx .. pd_idx+m-1 (mod N); data index d lands at
	 * slot (pd_idx + m + d) mod N — identical to raid5_compute_sector(). */
	for (p = 0; p < m; p++)
		parity_slot[p] = (pd_idx + p) % raid_disks;
	for (d = 0; d < k; d++)
		data_slot[d] = (pd_idx + m + d) % raid_disks;
}

u32 raidkm_reshape_band_csum(struct page **band, int npages,
			     const int *data_slot, int k)
{
	u32 c = ~0U;
	int d, po;

	for (d = 0; d < k; d++)
		for (po = 0; po < npages; po++)
			c = crc32c_le(c, page_address(band[data_slot[d] * npages + po]),
				      PAGE_SIZE);
	return ~c;
}
