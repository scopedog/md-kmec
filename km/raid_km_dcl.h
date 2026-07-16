/* SPDX-License-Identifier: GPL-2.0 */
/*
 * raid_km_dcl.h — declustered-parity mapping core for raidkm (md level 71).
 *
 * This is the KERNEL-CORE block of tools/declustered-sim.c, lifted VERBATIM
 * (integer math only, no allocation inside the map functions).  The simulator
 * is the reference implementation and the source of the acceptance search;
 * the kernel only ever REGENERATES the permutation set from the seed recorded
 * in the superblock, so the two sides must stay bit-identical.  Any change
 * here must be mirrored in tools/declustered-sim.c and re-validated with
 * tools/raidkm-test-declustered-map.sh (kernel<->userspace map parity gate).
 *
 * Layout model (v1) — see notes/declustered-parity-design.md §4/§5a:
 *   - a ROW is one chunk-index across the whole pool; physical chunk == row
 *     on every disk (dense per-row packing, table-free placement).
 *   - each row's N logical columns: ngroups groups of width g = k+m (data
 *     slots 0..k-1, parity k..g-1) then s spare columns.  C1: N-s == ngroups*g.
 *   - lcol -> disk through nbase seeded Fisher-Yates base shuffles, each
 *     expanded by all N rotations (NPERMS = nbase*N):
 *         disk = (base[row-perm][lcol] + rot) % N
 *     P1 capacity balance is EXACT by construction; the rebuild load of a
 *     failed disk depends only on disk differences (rotation symmetry).
 *
 * Clean-room note: construction is classic design-theory combinatorics
 * (Holland & Gibson lineage); no OpenZFS dRAID (CDDL) code consulted.
 */
#ifndef _RAID_KM_DCL_H
#define _RAID_KM_DCL_H

#include <linux/types.h>

/* SplitMix64: tiny, seedable, well-mixed.  NOT crypto; determinism is what
 * matters — the kernel must regenerate the identical PERM from the seed. */
static inline u64 dcl_splitmix64(u64 *state)
{
	u64 z = (*state += 0x9e3779b97f4a7c15ULL);

	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return z ^ (z >> 31);
}

/* Seeded Fisher-Yates shuffle of [0, n).  The modulo bias is negligible for
 * n <= 255 and, more importantly, IDENTICAL in kernel and userspace. */
static inline void dcl_gen_base_perm(u32 n, u64 seed, u32 *perm)
{
	u32 i, j, tmp;
	u64 st = seed;

	for (i = 0; i < n; i++)
		perm[i] = i;
	for (i = n - 1; i > 0; i--) {
		j = (u32)(dcl_splitmix64(&st) % (u64)(i + 1));
		tmp = perm[i]; perm[i] = perm[j]; perm[j] = tmp;
	}
}

/* Declustered geometry.  Mirrors the superblock fields (design doc §6). */
struct dcl_geom {
	u32 N;		/* pool disks				*/
	u32 g;		/* group width = k + m			*/
	u32 m;		/* parity per group			*/
	u32 k;		/* data per group (g - m)		*/
	u32 s;		/* distributed spare columns per row	*/
	u32 ngroups;	/* (N - s) / g   (C1: exact)		*/
	u32 nbase;	/* base shuffles			*/
	u64 seed;	/* accepted seed (superblock field)	*/
	/* derived tables, nbase*N u32 each, caller-allocated */
	u32 *base;	/* base[b*N + lcol] = disk (rot 0)	*/
	u32 *ibase;	/* ibase[b*N + disk] = lcol (rot 0)	*/
};

/* Per-base-shuffle seed: decorrelate the shuffles, keep one SB seed. */
static inline u64 dcl_seed_for_base(u64 seed, u32 b)
{
	u64 st = seed + 0x100000001b3ULL * (u64)(b + 1);

	return dcl_splitmix64(&st);
}

static inline void dcl_geom_tables(struct dcl_geom *ge)
{
	u32 b, c;

	for (b = 0; b < ge->nbase; b++) {
		dcl_gen_base_perm(ge->N, dcl_seed_for_base(ge->seed, b),
				  ge->base + (size_t)b * ge->N);
		for (c = 0; c < ge->N; c++)
			ge->ibase[(size_t)b * ge->N +
				  ge->base[(size_t)b * ge->N + c]] = c;
	}
}

/* Logical column -> physical disk for a given row. */
static inline u32 dcl_disk(const struct dcl_geom *ge, u64 row, u32 lcol)
{
	u32 pidx = (u32)(row % ((u64)ge->nbase * ge->N));
	u32 b = pidx / ge->N, t = pidx % ge->N;

	return (ge->base[(size_t)b * ge->N + lcol] + t) % ge->N;
}

/* Physical disk -> logical column for a given row (inverse of dcl_disk). */
static inline u32 dcl_lcol(const struct dcl_geom *ge, u64 row, u32 disk)
{
	u32 pidx = (u32)(row % ((u64)ge->nbase * ge->N));
	u32 b = pidx / ge->N, t = pidx % ge->N;

	return ge->ibase[(size_t)b * ge->N + (disk + ge->N - t) % ge->N];
}

/* Column roles.  lcol < ngroups*g: group member (slot < k data, else parity);
 * otherwise spare index lcol - ngroups*g. */
#define DCL_ROLE_DATA	0
#define DCL_ROLE_PARITY	1
#define DCL_ROLE_SPARE	2

static inline u32 dcl_role(const struct dcl_geom *ge, u32 lcol,
			   u32 *group, u32 *slot)
{
	if (lcol < ge->ngroups * ge->g) {
		*group = lcol / ge->g;
		*slot  = lcol % ge->g;
		return *slot < ge->k ? DCL_ROLE_DATA : DCL_ROLE_PARITY;
	}
	*group = 0;
	*slot  = lcol - ge->ngroups * ge->g;	/* spare index */
	return DCL_ROLE_SPARE;
}

/* Forward map: logical data chunk -> (row, group, slot, lcol, disk).
 * Physical chunk index == row (one column per disk per row). */
struct dcl_addr {
	u64 row;	/* == physical chunk index on `disk`	*/
	u32 group;
	u32 slot;	/* data slot within the group, < k	*/
	u32 lcol;
	u32 disk;
};

static inline void dcl_forward(const struct dcl_geom *ge, u64 logical_chunk,
			       struct dcl_addr *a)
{
	u64 dcpr = (u64)ge->ngroups * ge->k;	/* data columns per row */
	u32 dcol = (u32)(logical_chunk % dcpr);

	a->row   = logical_chunk / dcpr;
	a->group = dcol / ge->k;
	a->slot  = dcol % ge->k;
	a->lcol  = a->group * ge->g + a->slot;
	a->disk  = dcl_disk(ge, a->row, a->lcol);
}

/* Inverse map: (disk, physical chunk) -> role (+ logical chunk for data).
 * Returns the role; *logical_chunk valid only for DCL_ROLE_DATA. */
static inline u32 dcl_inverse(const struct dcl_geom *ge, u32 disk,
			      u64 phys_chunk, u64 *logical_chunk,
			      u32 *group, u32 *slot)
{
	u64 row = phys_chunk;
	u32 lcol = dcl_lcol(ge, row, disk);
	u32 role = dcl_role(ge, lcol, group, slot);

	if (role == DCL_ROLE_DATA)
		*logical_chunk = row * (u64)ge->ngroups * ge->k +
				 (u64)*group * ge->k + *slot;
	return role;
}

/* On-disk rkdcl metadata block: 4 KiB at data_offset + data_size (the
 * reserved tail chunk), one identical copy per member, written by mdadm at
 * --create (mdadm raidkm-dcl.h is the userspace mirror of this struct).
 * All multi-byte fields little-endian.  Versioned: the Phase-3
 * spare-assignment table + rebuild high-water mark extend it. */
#define RKDCL_MAGIC		"RKDCLMD1"
#define RKDCL_SB_VERSION	1	/* geometry only			*/
#define RKDCL_SB_VERSION2	2	/* + spare assignment / rebuild mark	*/
#define RKDCL_SB_BYTES		4096

/* v2 spare-assignment state (notes/declustered-population-design.md §2) */
#define RKDCL_NO_ASSIGN		(~0U)
#define RKDCL_ASSIGN_NONE	0	/* no assignment		*/
#define RKDCL_ASSIGN_POPULATING	1	/* rebuild into spare running	*/
#define RKDCL_ASSIGN_POPULATED	2	/* redirect permanent		*/

struct rkdcl_sb {
	char		magic[8];	/* RKDCL_MAGIC, no NUL		*/
	__le32		version;	/* RKDCL_SB_VERSION{,2}		*/
	__le32		hdr_crc;	/* crc32-le of the 4 KiB block
					 * with this field zeroed	*/
	__le32		pool_disks;	/* N — cross-check vs SB	*/
	__le32		group_width;	/* g = k + m			*/
	__le32		parity;		/* m				*/
	__le32		spare_cols;	/* s				*/
	__le32		ngroups;	/* (N - s) / g			*/
	__le32		nbase;		/* base permutations		*/
	__le64		seed;		/* accepted permutation seed	*/
	__le64		flags;		/* 0				*/
	/* ---- v2 fields (zero in v1 blocks) --------------------------- */
	__le64		gen;		/* journal generation; highest
					 * crc-valid copy wins on load	*/
	__le32		assign_disk;	/* X, or RKDCL_NO_ASSIGN	*/
	__le32		assign_spare;	/* spare column index j		*/
	__le32		assign_state;	/* RKDCL_ASSIGN_*		*/
	__le32		pad0;
	__le64		assign_mark;	/* journaled read mark, DEVICE
					 * SECTORS; <= the runtime
					 * prefix mark			*/
	/* pad to RKDCL_SB_BYTES */
} __packed;

#endif /* _RAID_KM_DCL_H */
