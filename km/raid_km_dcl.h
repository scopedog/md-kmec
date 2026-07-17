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

/* ---- Phase 3b: multi-assignment chained resolve --------------------------- */
/*
 * With several spare assignments {X_i -> spare column j_i} active at once,
 * a redirect can land on another failed-and-assigned disk: spare columns
 * rotate over ALL pool disks, so there are rows where j_2's physical disk
 * IS X_1.  Resolution therefore CHAINS: col -> j_2 -> X_1 (dead, assigned)
 * -> j_1 -> live disk.  Bijectivity of the per-row column<->disk map gives
 * (proven by the simulator's P4 checker, tools/declustered-sim.c):
 *
 *  - each failed disk occupies exactly one column per row, so at most one
 *    chain traverses a given assignment: chains are vertex-disjoint and
 *    resolved endpoints never collide;
 *  - a cycle would need every disk on it to sit at a spare column of the
 *    row (the only predecessor of a cycle element is another cycle
 *    element), so chains starting at GROUP columns always terminate; cycles
 *    are spare-only and content-free;
 *  - a chain ends either at a live disk or DEAD (an unassigned failed disk,
 *    a POPULATING assignment above its mark, or a content-free self-loop).
 *
 * `mark[i]` is the per-assignment prefix mark in ROWS: a hop through
 * assignment i is permitted iff row < mark[i].  POPULATED = DCL_MARK_ALL.
 * The WRITE map passes DCL_MARK_ALL for every active assignment (the
 * redirect-all-writes invariant, applied transitively).
 */
struct dcl_assign {
	u32 disk;	/* X_i: failed physical disk		*/
	u32 spare;	/* j_i: spare column index, < s		*/
};

#define DCL_MARK_ALL	(~0ULL)

/* Resolve (row, lcol) -> physical disk through the active assignment chain.
 * *dead = 1 when the endpoint holds no live copy (caller decodes). */
static inline u32 dcl_resolve(const struct dcl_geom *ge,
			      const struct dcl_assign *as, const u64 *mark,
			      u32 nas, u64 row, u32 lcol, u32 *dead)
{
	u32 disk = dcl_disk(ge, row, lcol);
	u32 hops;

	for (hops = 0; hops <= nas; hops++) {
		u32 i, nlcol;

		for (i = 0; i < nas; i++)
			if (as[i].disk == disk)
				break;
		if (i == nas) {			/* live endpoint */
			*dead = 0;
			return disk;
		}
		if (row >= mark[i]) {		/* not covered: decode */
			*dead = 1;
			return disk;
		}
		nlcol = ge->ngroups * ge->g + as[i].spare;
		if (nlcol == lcol) {		/* self-loop: content-free */
			*dead = 1;
			return disk;
		}
		lcol = nlcol;
		disk = dcl_disk(ge, row, lcol);
	}
	*dead = 1;	/* spare-only cycle (unreachable from group columns) */
	return disk;
}

/* Does the WRITE chain of (row, lcol) traverse disk X?  Population of a
 * newly armed assignment {X -> j} must rebuild every group column whose
 * chain traverses X — not only X's own column: rows where X held another
 * assignment's spare content re-materialise through the extended chain
 * (this replaces the single-assignment "spare column here -> skip" rule). */
static inline int dcl_chain_traverses(const struct dcl_geom *ge,
				      const struct dcl_assign *as, u32 nas,
				      u64 row, u32 lcol, u32 X)
{
	u32 disk = dcl_disk(ge, row, lcol);
	u32 hops;

	for (hops = 0; hops <= nas; hops++) {
		u32 i, nlcol;

		if (disk == X)
			return 1;
		for (i = 0; i < nas; i++)
			if (as[i].disk == disk)
				break;
		if (i == nas)
			return 0;		/* live endpoint, X not seen */
		nlcol = ge->ngroups * ge->g + as[i].spare;
		if (nlcol == lcol)
			return 0;		/* self-loop, content-free */
		lcol = nlcol;
		disk = dcl_disk(ge, row, lcol);
	}
	return 0;
}

/* INVERSE walk: the group column whose write-chain traverses disk X in
 * this row, or -1 when none does (X holds an unassigned spare column, or
 * a content-free spare-only cycle/self-loop).  Walk predecessors: X's
 * column; while it is an active assignment's spare column, step to that
 * assignment's disk (its unique predecessor — bijectivity) and repeat.
 * At most one chain traverses any disk per row (vertex-disjointness), so
 * this is THE candidate; equivalence with the forward dcl_chain_traverses
 * is asserted by the simulator's P4 A6 check and by the kernel dcl
 * selftest against the runtime walk. */
static inline int dcl_chain_root(const struct dcl_geom *ge,
				 const struct dcl_assign *as, u32 nas,
				 u64 row, u32 X)
{
	u32 hops;

	for (hops = 0; hops <= nas; hops++) {
		u32 lcol = dcl_lcol(ge, row, X);
		u32 i, j;

		if (lcol < ge->ngroups * ge->g)
			return (int)lcol;	/* group column: root found */
		j = lcol - ge->ngroups * ge->g;
		for (i = 0; i < nas; i++)
			if (as[i].spare == j)
				break;
		if (i == nas)
			return -1;	/* unassigned spare: content-free */
		X = as[i].disk;		/* unique predecessor */
	}
	return -1;		/* spare-only cycle: content-free */
}

/* On-disk rkdcl metadata block: 4 KiB at data_offset + data_size (the
 * reserved tail chunk), one identical copy per member, written by mdadm at
 * --create (mdadm raidkm-dcl.h is the userspace mirror of this struct).
 * All multi-byte fields little-endian.  Versioned: the Phase-3
 * spare-assignment table + rebuild high-water mark extend it. */
#define RKDCL_MAGIC		"RKDCLMD1"
#define RKDCL_SB_VERSION	1	/* geometry only			*/
#define RKDCL_SB_VERSION2	2	/* + spare assignment / rebuild mark	*/
#define RKDCL_SB_VERSION3	3	/* + multi-assignment table (3b)	*/
#define RKDCL_SB_BYTES		4096

/* v2 spare-assignment state (notes/declustered-population-design.md §2) */
#define RKDCL_NO_ASSIGN		(~0U)
#define RKDCL_ASSIGN_NONE	0	/* no assignment		*/
#define RKDCL_ASSIGN_POPULATING	1	/* rebuild into spare running	*/
#define RKDCL_ASSIGN_POPULATED	2	/* redirect permanent		*/

/* v3 assignment-table entry (24 bytes).  Table capacity is the format
 * maximum s (layout word keeps s <= 127); the live count is nassign. */
#define RKDCL_MAX_ASSIGN	127

struct rkdcl_assign {
	__le32		disk;		/* X_i				*/
	__le32		spare;		/* spare column index j_i	*/
	__le32		state;		/* RKDCL_ASSIGN_*		*/
	__le32		pad;
	__le64		mark;		/* journaled read mark, DEVICE
					 * SECTORS; <= runtime mark	*/
} __packed;

/*
 * ADAPTIVE VERSIONING (decided 2026-07-17): the journal writes version 2
 * while <= 1 assignment is active (legacy assign_* fields carry it, table
 * zero) and version 3 only while >= 2 are.  Every journal write overwrites
 * the same 4 KiB slot on ALL live members with gen++, so arming a second
 * assignment removes every v2 copy — the published v2 module fails CLOSED
 * (rejects version 3 -> no valid block -> refuses to assemble) instead of
 * silently dropping an assignment (whose spare its writes would go stale).
 * Retiring back to <= 1 assignment restores v2 blocks and downgrade compat.
 * In a v3 block the legacy assign_* fields MIRROR assign[0] (debug/examine
 * convenience only; the table is authoritative).
 */
struct rkdcl_sb {
	char		magic[8];	/* RKDCL_MAGIC, no NUL		*/
	__le32		version;	/* RKDCL_SB_VERSION{,2,3}	*/
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
	/* ---- v3 fields (zero in v1/v2 blocks) ------------------------ */
	__le32		nassign;	/* live entries in assign[]	*/
	__le32		pad1;
	struct rkdcl_assign assign[RKDCL_MAX_ASSIGN];
	/* pad to RKDCL_SB_BYTES */
} __packed;

#endif /* _RAID_KM_DCL_H */
