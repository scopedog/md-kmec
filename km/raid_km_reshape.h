/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _RAID_KM_RESHAPE_H
#define _RAID_KM_RESHAPE_H

#include <linux/types.h>

/*
 * COW-staged online reshape for raidkm (level 71).
 * See md-kmec/notes/reshape-cow-design.md for the full design.
 *
 * One band is migrated at a time, never overwriting a live old block until its
 * new-geometry replacement is durably staged:
 *
 *   read old geometry  ->  STAGE: re-encode into a scratch region in the NEW
 *   geometry (so the staged copy carries its own m_new parity)  ->  COMMIT:
 *   copy scratch to the band's new home  ->  DONE.
 *
 * Recovery on assembly is driven entirely by the journal phase:
 *   STAGE  + bad data_csum -> redo the band from the (intact) old home
 *   COMMIT + good data_csum -> replay home from scratch (idempotent)
 * so correctness never depends on md's raid456-assuming frontier math, which is
 * what corrupts the rotating layout in the stock reshape engine.
 *
 * The journal header is written double-buffered (two slots; the highest seq with
 * a valid hdr_csum wins) at a fixed offset in the reserved reshape-scratch zone.
 */

#define RAIDKM_RJ_MAGIC		0x4a524b52u	/* 'RKRJ' */
#define RAIDKM_RJ_VERSION	1u

enum raidkm_reshape_phase {
	RAIDKM_PH_IDLE		= 0,
	RAIDKM_PH_STAGE		= 1,	/* band re-encoded into scratch */
	RAIDKM_PH_COMMIT	= 2,	/* scratch being copied to home */
	RAIDKM_PH_DONE		= 3,	/* band fully migrated */
	RAIDKM_PH_FINALIZE	= 4,	/* all bands done; SB geometry flip pending */
};

/* On-disk journal record (one per slot).  __le fields, fixed layout. */
struct raidkm_reshape_journal {
	__le32	magic;			/* RAIDKM_RJ_MAGIC */
	__le32	version;		/* RAIDKM_RJ_VERSION */
	__le64	seq;			/* monotonic; newest valid slot wins */
	__le64	band_start_chunk;	/* logical data-chunk index of active band */
	__le32	band_chunks;		/* band length in logical data chunks */
	__le32	phase;			/* enum raidkm_reshape_phase */
	__le32	old_m, new_m;		/* parity counts being migrated between */
	__le32	old_raid_disks, new_raid_disks;
	__le32	chunk_sectors;
	__le32	scratch_rows;		/* stripe rows the scratch zone holds */
	__le64	reshape_position;	/* committed frontier (array sectors) */
	__le32	data_csum;		/* crc32c of the staged band in scratch */
	__le32	hdr_csum;		/* crc32c of this header with hdr_csum == 0 */
} __packed;

/* ---- in-core reshape context + journal/scratch I/O (raid_km-reshape.c) ---- */

#define RAIDKM_PAGE_SECTORS		(PAGE_SIZE >> 9)
#define RAIDKM_RJ_SLOTS			2	/* double-buffered journal slots */
/*
 * Per-disk reshape scratch zone: holds the double-buffered journal (slots 0..1
 * in its first pages) followed by one staged band.  It lives in the gap just
 * BELOW each member's data_offset (which md does not use for data; under
 * dm-raid it is front reshape space provided by LVM), addressed as a raw
 * bdev sector: abs = data_offset - SCRATCH + local.  raidkm_check_reshape
 * guards that every member has enough headroom.
 */
#define RAIDKM_RESHAPE_SCRATCH_SECTORS	1024		/* 512 KiB: journal + one band */
/* required free sectors between the superblock area and data_offset */
#define RAIDKM_RESHAPE_SB_MARGIN	256

struct r5conf;
struct md_rdev;

struct raidkm_reshape_ctx {
	u64		jseq;		/* next journal sequence number to write */
	/* band geometry (filled by the migration loop) */
	u32		old_m, new_m;
	u32		old_raid_disks, new_raid_disks;
	u32		chunk_sectors;
	u32		scratch_rows;
};

/* I/O to a member's scratch zone at @local (0..SCRATCH), below data_offset. */
int raidkm_scratch_io(struct md_rdev *rdev, sector_t local, struct page *page,
		      blk_opf_t op);
int raidkm_reshape_jwrite(struct r5conf *conf, struct raidkm_reshape_ctx *ctx,
			  enum raidkm_reshape_phase phase, u64 band_start_chunk,
			  u32 band_chunks, u32 data_csum, sector_t reshape_position);
/* overwrite both slots with fresh IDLE records when a reshape starts */
int raidkm_reshape_journal_init(struct r5conf *conf, struct raidkm_reshape_ctx *ctx);
int raidkm_reshape_jread(struct r5conf *conf, struct raidkm_reshape_journal *out);

/*
 * Physical disk slot of every block in stripe row @row for a raidkm geometry
 * (@raid_disks, parity count @m, @rotating).  Fills @data_slot[0..k-1] (k =
 * raid_disks - m) with the disk holding data index d, and @parity_slot[0..m-1]
 * with the disk holding parity index p.  Mirrors raid5_compute_sector()'s
 * rotating math; the per-disk sector of the row is simply row * chunk_sectors.
 */
void raidkm_reshape_row_layout(int raid_disks, int m, bool rotating,
			       sector_t row, int *data_slot, int *parity_slot);

/* crc32c over the band's k data blocks (data-index order) for the journal. */
u32 raidkm_reshape_band_csum(struct page **band, int npages,
			     const int *data_slot, int k);

#ifdef RAIDKM_FAULT_INJECT
/*
 * Debug-only fault injection (build with RAIDKM_FAULT_INJECT=1).  Driven from
 *   /sys/block/<md>/md/raidkm_reshape_inject = "<band>:<phase>:<action>"
 * band   : >=0 absolute ordinal, or one of the sentinels below
 * phase  : STAGE | COMMIT | DONE | FINALIZE
 * action : hang  — durably write this phase's journal, then PARK before the
 *                  next step (clean-boundary crash sim)
 *          torn  — write this phase's journal, BEGIN the next step but write
 *                  only a partial/torn subset of its bios, then PARK
 * Writing "off" (or empty) disarms.
 */
enum raidkm_inject_action {
	RAIDKM_INJ_OFF		= 0,
	RAIDKM_INJ_HANG		= 1,
	RAIDKM_INJ_TORN		= 2,
};

/* Band-selector sentinels (negative; >=0 is an absolute ordinal). */
#define RAIDKM_INJ_BAND_FIRST	0L
#define RAIDKM_INJ_BAND_LAST	(-1L)
#define RAIDKM_INJ_BAND_MID	(-2L)

struct raidkm_reshape_inject {
	long				band;	/* selector */
	enum raidkm_reshape_phase	phase;
	enum raidkm_inject_action	action;
	/* set by the reshape thread once it parks at the inject point */
	bool				parked;
	long				parked_band;
	enum raidkm_reshape_phase	parked_phase;
};
#endif /* RAIDKM_FAULT_INJECT */

#endif /* _RAID_KM_RESHAPE_H */
