/*
 * declustered-sim.c — Phase-0 simulator for raidkm declustered parity.
 *
 * See notes/declustered-parity-design.md.  This is the "no kernel code until
 * this passes" gate: it generates the balanced permutation set, computes the
 * full forward/inverse chunk map, PROVES the balance properties, measures the
 * rebuild-distribution quality, and emits reference vectors that the eventual
 * kernel implementation must reproduce bit-for-bit.
 *
 * Build:   gcc -O2 -Wall -Wextra -o declustered-sim declustered-sim.c -lm
 * Run:     ./declustered-sim -N 14 -g 6 -m 2 -s 2
 *          ./declustered-sim -N 80 -g 13 -m 2 -s 2 --vectors vecs.tsv
 *
 * Layout model (v1, doc §4):
 *   - a ROW is one chunk-index across the whole pool: N columns, one per disk;
 *     physical chunk index == row on every disk (table-free placement).
 *   - each row's N logical columns split into ngroups groups of width g = k+m
 *     (data slots 0..k-1, parity slots k..g-1, i.e. parity at the group tail)
 *     followed by s spare columns:  [ g | g | ... | g | s ]
 *     with the v1 constraint C1:  N - s == ngroups * g.
 *   - logical column -> physical disk goes through the permutation set:
 *         pidx = row % (nbase * N);  b = pidx / N;  t = pidx % N;
 *         disk = (base[b][lcol] + t) % N
 *     i.e. nbase seeded Fisher-Yates base shuffles, each expanded by all N
 *     rotations.  The rotation expansion gives:
 *       P1 EXACT: over one period every lcol visits every disk exactly once,
 *         so per-disk data/parity/spare counts are identical by construction.
 *       P2 ROTATION-SYMMETRIC: the rebuild load a failed disk X imposes on
 *         surviving disk Y depends only on (Y - X) mod N, so a single
 *         difference-load vector characterises every failure, and the
 *         acceptance search below only optimises the base shuffles.
 *
 * Kernel-liftable core: everything between the KERNEL-CORE-BEGIN/END markers
 * uses fixed-width integer math only (no libc, no floats) and is the exact
 * code the kernel module will carry.  The float parts (CV metrics, acceptance
 * search) run in USERSPACE ONLY (mdadm at --create time); the kernel merely
 * regenerates PERM from the accepted seed recorded in the superblock.
 *
 * Clean-room note (doc §2): the rotation/difference construction is classic
 * design-theory combinatorics (Holland & Gibson lineage); no OpenZFS dRAID
 * (CDDL) code was consulted or copied.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

/* ------------------------------------------------------------------------ */
/* KERNEL-CORE-BEGIN: deterministic PRNG + permutation + chunk map           */
/* (u64/u32 integer math only; this block must move to the kernel verbatim)  */
/* ------------------------------------------------------------------------ */

typedef uint64_t u64;
typedef uint32_t u32;

/* SplitMix64: tiny, seedable, well-mixed.  NOT crypto; determinism is what
 * matters — the kernel must regenerate the identical PERM from the seed. */
static inline u64 splitmix64(u64 *state)
{
	u64 z = (*state += 0x9e3779b97f4a7c15ULL);
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return z ^ (z >> 31);
}

/* Seeded Fisher-Yates shuffle of [0, n).  The modulo bias is negligible for
 * n <= 255 and, more importantly, IDENTICAL in kernel and userspace. */
static void dcl_gen_base_perm(u32 n, u64 seed, u32 *perm)
{
	u32 i, j, tmp;
	u64 st = seed;

	for (i = 0; i < n; i++)
		perm[i] = i;
	for (i = n - 1; i > 0; i--) {
		j = (u32)(splitmix64(&st) % (u64)(i + 1));
		tmp = perm[i]; perm[i] = perm[j]; perm[j] = tmp;
	}
}

/* Declustered geometry.  Mirrors the future superblock fields (doc §6). */
struct dcl_geom {
	u32 N;		/* pool disks				*/
	u32 g;		/* group width = k + m			*/
	u32 m;		/* parity per group			*/
	u32 k;		/* data per group (g - m)		*/
	u32 s;		/* distributed spare columns per row	*/
	u32 ngroups;	/* (N - s) / g   (C1: exact)		*/
	u32 nbase;	/* base shuffles			*/
	u64 seed;	/* accepted seed (superblock field)	*/
	/* derived tables, nbase*N u32 each */
	u32 *base;	/* base[b*N + lcol] = disk (t = 0)	*/
	u32 *ibase;	/* ibase[b*N + disk] = lcol (t = 0)	*/
};

/* Per-base-shuffle seed: decorrelate the shuffles, keep one SB seed. */
static inline u64 dcl_seed_for_base(u64 seed, u32 b)
{
	u64 st = seed + 0x100000001b3ULL * (u64)(b + 1);
	return splitmix64(&st);
}

static void dcl_geom_tables(struct dcl_geom *ge)
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

static void dcl_forward(const struct dcl_geom *ge, u64 logical_chunk,
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
static u32 dcl_inverse(const struct dcl_geom *ge, u32 disk, u64 phys_chunk,
		       u64 *logical_chunk, u32 *group, u32 *slot)
{
	u64 row = phys_chunk;
	u32 lcol = dcl_lcol(ge, row, disk);
	u32 role = dcl_role(ge, lcol, group, slot);

	if (role == DCL_ROLE_DATA)
		*logical_chunk = row * (u64)ge->ngroups * ge->k +
				 (u64)*group * ge->k + *slot;
	return role;
}

/* ---- Phase 3b: multi-assignment chained resolve ------------------------- */
/*
 * With several spare assignments {X_i -> spare column j_i} active at once,
 * a redirect can land on another failed-and-assigned disk: spare columns
 * rotate over ALL pool disks, so there are rows where j_2's physical disk
 * IS X_1.  Resolution therefore CHAINS: col -> j_2 -> X_1 (dead, assigned)
 * -> j_1 -> live disk.  Bijectivity of the per-row column<->disk map gives
 * the properties the checker below asserts:
 *
 *  - each failed disk occupies exactly one column per row, so at most one
 *    chain traverses a given assignment: chains are vertex-disjoint and
 *    resolved endpoints never collide;
 *  - a cycle would need every disk on it to sit at a spare column of the
 *    row (the only predecessor of a cycle element is another cycle
 *    element), so chains starting at GROUP columns always terminate; cycles
 *    are spare-only and content-free (copies of copies of nothing);
 *  - a chain ends either at a live disk or DEAD (an unassigned failed disk,
 *    a POPULATING assignment above its mark, or a content-free self-loop).
 *
 * `mark[i]` is the per-assignment prefix mark in ROWS: a hop through
 * assignment i is permitted iff row < mark[i].  POPULATED = mark ~0ULL.
 * The WRITE map passes ~0ULL for every active assignment (the §1
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

/* ------------------------------------------------------------------------ */
/* KERNEL-CORE-END                                                           */
/* ------------------------------------------------------------------------ */

/* crc32 (bit-reflected, poly 0xEDB88320) for PERM-table fingerprints so the
 * kernel unit test can compare its regenerated table against the vectors. */
static u32 crc32_buf(const void *buf, size_t len)
{
	const unsigned char *p = buf;
	u32 crc = 0xffffffffu;
	size_t i;
	int b;

	for (i = 0; i < len; i++) {
		crc ^= p[i];
		for (b = 0; b < 8; b++)
			crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1)));
	}
	return crc ^ 0xffffffffu;
}

/* ---- P1: exact per-disk role balance over one period --------------------- */

static int check_p1(const struct dcl_geom *ge, int verbose)
{
	u64 period = (u64)ge->nbase * ge->N;
	u64 *cnt = calloc((size_t)ge->N * 3, sizeof(*cnt));
	u64 row;
	u32 d, lcol, group, slot, role;
	int ok = 1;

	for (row = 0; row < period; row++)
		for (lcol = 0; lcol < ge->N; lcol++) {
			d = dcl_disk(ge, row, lcol);
			role = dcl_role(ge, lcol, &group, &slot);
			cnt[(size_t)d * 3 + role]++;
		}

	/* by construction: data = nbase*ngroups*k, parity = nbase*ngroups*m,
	 * spare = nbase*s — identical for every disk */
	for (d = 0; d < ge->N; d++) {
		if (cnt[(size_t)d * 3 + DCL_ROLE_DATA]   != (u64)ge->nbase * ge->ngroups * ge->k ||
		    cnt[(size_t)d * 3 + DCL_ROLE_PARITY] != (u64)ge->nbase * ge->ngroups * ge->m ||
		    cnt[(size_t)d * 3 + DCL_ROLE_SPARE]  != (u64)ge->nbase * ge->s) {
			printf("P1 FAIL disk %u: data=%llu parity=%llu spare=%llu\n",
			       d,
			       (unsigned long long)cnt[(size_t)d * 3 + 0],
			       (unsigned long long)cnt[(size_t)d * 3 + 1],
			       (unsigned long long)cnt[(size_t)d * 3 + 2]);
			ok = 0;
		}
	}
	if (ok && verbose)
		printf("P1 capacity balance: EXACT (per disk over %llu-row period: "
		       "data=%u parity=%u spare=%u)\n",
		       (unsigned long long)period,
		       ge->nbase * ge->ngroups * ge->k,
		       ge->nbase * ge->ngroups * ge->m,
		       ge->nbase * ge->s);
	free(cnt);
	return ok;
}

/* ---- bijectivity + forward/inverse roundtrip ----------------------------- */

static int check_roundtrip(const struct dcl_geom *ge, u64 nchunks, int verbose)
{
	u64 lc, lc2;
	u32 group, slot;
	struct dcl_addr a;
	u64 period = (u64)ge->nbase * ge->N;
	u64 row;
	u32 lcol;
	unsigned char *seen = malloc(ge->N);

	/* per-row bijectivity over one period */
	for (row = 0; row < period; row++) {
		memset(seen, 0, ge->N);
		for (lcol = 0; lcol < ge->N; lcol++) {
			u32 d = dcl_disk(ge, row, lcol);
			if (d >= ge->N || seen[d]) {
				printf("BIJECTIVITY FAIL row %llu lcol %u disk %u\n",
				       (unsigned long long)row, lcol, d);
				free(seen);
				return 0;
			}
			seen[d] = 1;
			if (dcl_lcol(ge, row, d) != lcol) {
				printf("INVERSE-PERM FAIL row %llu lcol %u\n",
				       (unsigned long long)row, lcol);
				free(seen);
				return 0;
			}
		}
	}
	free(seen);

	/* forward -> inverse roundtrip on a span well past one period */
	for (lc = 0; lc < nchunks; lc++) {
		dcl_forward(ge, lc, &a);
		if (dcl_inverse(ge, a.disk, a.row, &lc2, &group, &slot)
		    != DCL_ROLE_DATA || lc2 != lc) {
			printf("ROUNDTRIP FAIL lc=%llu\n", (unsigned long long)lc);
			return 0;
		}
	}
	if (verbose)
		printf("Bijectivity + %llu-chunk forward/inverse roundtrip: OK\n",
		       (unsigned long long)nchunks);
	return 1;
}

/* ---- P4: multi-assignment chain invariants (Phase 3b) --------------------- */

#define DCL_MAX_ASSIGN_SIM	127	/* == rkdcl v3 table capacity */

/*
 * For an assignment set (X_i -> j_i) with per-assignment marks, over one full
 * period, assert:
 *   A1  every GROUP-column chain terminates within nas hops, visiting no
 *       column twice (group chains never enter cycles);
 *   A2  per row, the resolved write-map disks of all group columns are
 *       pairwise distinct and live (no write collisions, nothing lands on a
 *       failed disk);
 *   A3  cycles exist only among spare columns (content-free); counted;
 *   A4  chains are vertex-disjoint: <= 1 group column per row traverses any
 *       given failed disk; for the newest assignment X, EXACTLY one when X's
 *       column that row is a group column (the v1 case);
 *   A5  read-map mark semantics for the newest (POPULATING) assignment:
 *       candidate rows >= M dead-end exactly at X; rows < M resolve live.
 */
static int check_chains(const struct dcl_geom *ge, const struct dcl_assign *as,
			const u64 *mark, u32 nas, int verbose)
{
	u64 period = (u64)ge->nbase * ge->N;
	u64 wmark[DCL_MAX_ASSIGN_SIM];
	u64 row, cyc_rows = 0, cand_rows = 0;
	u32 gcols = ge->ngroups * ge->g;
	u32 Xnew = as[nas - 1].disk;
	int ok = 1;

	for (row = 0; row < nas; row++)
		wmark[row] = DCL_MARK_ALL;

	for (row = 0; row < period && ok; row++) {
		u32 seen_disk[256], nseen = 0;
		u32 c, i, ncand = 0;

		for (c = 0; c < gcols; c++) {
			/* A1: manual walk, no column revisits, bounded */
			u32 visited[DCL_MAX_ASSIGN_SIM + 1], nvis = 0;
			u32 lcol = c, disk = dcl_disk(ge, row, lcol);
			u32 dead, hops = 0, rdisk;

			while (1) {
				u32 v;

				for (v = 0; v < nvis; v++)
					if (visited[v] == lcol) {
						printf("A1 FAIL row %llu col %u: column %u revisited\n",
						       (unsigned long long)row, c, lcol);
						return 0;
					}
				visited[nvis++] = lcol;
				for (i = 0; i < nas; i++)
					if (as[i].disk == disk)
						break;
				if (i == nas)
					break;
				if (++hops > nas + 1) {
					printf("A1 FAIL row %llu col %u: unterminated chain\n",
					       (unsigned long long)row, c);
					return 0;
				}
				lcol = ge->ngroups * ge->g + as[i].spare;
				disk = dcl_disk(ge, row, lcol);
			}
			/* A2: write-map endpoints distinct + live */
			rdisk = dcl_resolve(ge, as, wmark, nas, row, c, &dead);
			if (dead || rdisk != disk) {
				printf("A2 FAIL row %llu col %u: write map dead=%u disk=%u/%u\n",
				       (unsigned long long)row, c, dead, rdisk, disk);
				return 0;
			}
			for (i = 0; i < nseen; i++)
				if (seen_disk[i] == rdisk) {
					printf("A2 FAIL row %llu col %u: endpoint collision on disk %u\n",
					       (unsigned long long)row, c, rdisk);
					return 0;
				}
			seen_disk[nseen++] = rdisk;
			/* A4/A5 below need candidacy for the newest assignment */
			if (dcl_chain_traverses(ge, as, nas, row, c, Xnew)) {
				u32 d5, r5 = dcl_resolve(ge, as, mark, nas,
							 row, c, &d5);

				ncand++;
				if (row >= mark[nas - 1]) {
					if (!d5 || r5 != Xnew) {
						printf("A5 FAIL row %llu col %u: above-mark dead=%u disk=%u (want dead at %u)\n",
						       (unsigned long long)row, c, d5, r5, Xnew);
						return 0;
					}
				} else if (d5) {
					printf("A5 FAIL row %llu col %u: below-mark resolved dead\n",
					       (unsigned long long)row, c);
					return 0;
				}
			}
		}
		/* A3: walks from active spare columns; cycles must be spare-only */
		for (i = 0; i < nas; i++) {
			u32 lcol = ge->ngroups * ge->g + as[i].spare;
			u32 disk = dcl_disk(ge, row, lcol), hops;
			int cycled = 0;

			for (hops = 0; hops <= nas; hops++) {
				u32 j;

				for (j = 0; j < nas; j++)
					if (as[j].disk == disk)
						break;
				if (j == nas)
					break;
				lcol = ge->ngroups * ge->g + as[j].spare;
				disk = dcl_disk(ge, row, lcol);
				if (lcol == ge->ngroups * ge->g + as[i].spare) {
					cycled = 1;	/* closed loop */
					break;
				}
			}
			if (cycled) {
				cyc_rows++;
				break;	/* one count per row is enough */
			}
		}
		/* A4: vertex-disjointness for the newest assignment */
		if (ncand > 1) {
			printf("A4 FAIL row %llu: %u chains traverse disk %u\n",
			       (unsigned long long)row, ncand, Xnew);
			return 0;
		}
		if (dcl_lcol(ge, row, Xnew) < gcols && ncand != 1) {
			printf("A4 FAIL row %llu: X at group column but no candidate\n",
			       (unsigned long long)row);
			return 0;
		}
		cand_rows += ncand;
	}
	if (verbose)
		printf("P4 chain invariants (%u assignments, X=%u): OK\n"
		       "  candidate rows %llu/%llu (rebuild volume), spare-only cycle rows %llu\n",
		       nas, Xnew, (unsigned long long)cand_rows,
		       (unsigned long long)period, (unsigned long long)cyc_rows);
	return ok;
}

/* ---- P2: rebuild load distribution for a failed disk --------------------- */
/*
 * Single-disk failure X, one period of rows.  Where X holds a data or parity
 * column of group G: every survivor of G performs one chunk READ, and the
 * reconstructed chunk is WRITTEN to the row's spare column j (j = 0 for the
 * metric; identical statistics for any fixed j).  Where X holds a spare
 * column: no work.  The rotation expansion makes the resulting per-survivor
 * load vector a pure function of (Y - X) mod N, so X = 0 characterises all X
 * (we spot-check that claim for a few X too).
 *
 * Returned metrics (userspace only — floats allowed here):
 *   read_cv / write_cv : coefficient of variation of per-survivor loads
 *   speedup            : rebuilt_chunks / max(single-disk read+write load)
 *                        — the effective rebuild parallelism vs a dedicated
 *                        spare (whose bottleneck is rebuilt_chunks writes on
 *                        one disk).
 */
struct p2_metrics {
	double read_cv, write_cv, speedup;
	u64 rebuilt;			/* chunks rebuilt per period */
	u64 max_read, max_write, max_combined;
};

static void measure_p2(const struct dcl_geom *ge, u32 X, struct p2_metrics *pm)
{
	u64 period = (u64)ge->nbase * ge->N;
	u64 *reads = calloc(ge->N, sizeof(*reads));
	u64 *writes = calloc(ge->N, sizeof(*writes));
	u64 row, rebuilt = 0;
	u32 Y, group, slot, role, j;
	double rsum = 0, wsum = 0, rss = 0, wss = 0, rmean, wmean;
	u32 nsurv = ge->N - 1;

	for (row = 0; row < period; row++) {
		u32 lcol = dcl_lcol(ge, row, X);

		role = dcl_role(ge, lcol, &group, &slot);
		if (role == DCL_ROLE_SPARE)
			continue;
		/* survivors of X's group each read one chunk */
		for (j = 0; j < ge->g; j++) {
			u32 d = dcl_disk(ge, row, group * ge->g + j);
			if (d != X)
				reads[d]++;
		}
		/* reconstructed chunk lands on the row's spare 0 */
		writes[dcl_disk(ge, row, ge->ngroups * ge->g + 0)]++;
		rebuilt++;
	}

	pm->rebuilt = rebuilt;
	pm->max_read = pm->max_write = pm->max_combined = 0;
	for (Y = 0; Y < ge->N; Y++) {
		if (Y == X)
			continue;
		rsum += reads[Y]; wsum += writes[Y];
		if (reads[Y] > pm->max_read)   pm->max_read = reads[Y];
		if (writes[Y] > pm->max_write) pm->max_write = writes[Y];
		if (reads[Y] + writes[Y] > pm->max_combined)
			pm->max_combined = reads[Y] + writes[Y];
	}
	rmean = rsum / nsurv; wmean = wsum / nsurv;
	for (Y = 0; Y < ge->N; Y++) {
		if (Y == X)
			continue;
		rss += (reads[Y] - rmean) * (reads[Y] - rmean);
		wss += (writes[Y] - wmean) * (writes[Y] - wmean);
	}
	pm->read_cv  = rmean > 0 ? sqrt(rss / (nsurv - 1)) / rmean : 0.0;
	pm->write_cv = wmean > 0 ? sqrt(wss / (nsurv - 1)) / wmean : 0.0;
	pm->speedup  = pm->max_combined ? (double)rebuilt / pm->max_combined : 0.0;
	free(reads); free(writes);
}

/* ---- acceptance search (userspace / mdadm --create only) ----------------- */

struct accept_result {
	u64 seed;
	struct p2_metrics pm;
};

static void accept_search(struct dcl_geom *ge, u64 seed0, u32 tries,
			  struct accept_result *best)
{
	u32 i;
	struct p2_metrics pm;
	double best_score = 1e300;

	for (i = 0; i < tries; i++) {
		ge->seed = seed0 + i;
		dcl_geom_tables(ge);
		measure_p2(ge, 0, &pm);
		/* score: bottleneck first (maximise speedup), CV as tiebreak */
		double score = 1.0 / (pm.speedup > 0 ? pm.speedup : 1e-9)
			       + 0.01 * (pm.read_cv + pm.write_cv);
		if (score < best_score) {
			best_score = score;
			best->seed = ge->seed;
			best->pm = pm;
		}
	}
	/* leave the winner's tables in place */
	ge->seed = best->seed;
	dcl_geom_tables(ge);
}

/* ---- reference vectors for the kernel unit test --------------------------- */

static void emit_vectors(const struct dcl_geom *ge, const char *path, u64 nvec)
{
	FILE *f = fopen(path, "w");
	u64 lc;
	struct dcl_addr a;

	if (!f) { perror(path); return; }
	fprintf(f, "# declustered-sim reference vectors v1\n");
	fprintf(f, "# N=%u g=%u m=%u k=%u s=%u ngroups=%u nbase=%u nperms=%u seed=0x%016llx\n",
		ge->N, ge->g, ge->m, ge->k, ge->s, ge->ngroups, ge->nbase,
		ge->nbase * ge->N, (unsigned long long)ge->seed);
	fprintf(f, "# PERM_CRC32=0x%08x\n",
		crc32_buf(ge->base, (size_t)ge->nbase * ge->N * sizeof(u32)));
	fprintf(f, "# logical_chunk\trow\tgroup\tslot\tlcol\tdisk\n");
	for (lc = 0; lc < nvec; lc++) {
		dcl_forward(ge, lc, &a);
		fprintf(f, "%llu\t%llu\t%u\t%u\t%u\t%u\n",
			(unsigned long long)lc, (unsigned long long)a.row,
			a.group, a.slot, a.lcol, a.disk);
	}
	fclose(f);
	printf("wrote %llu reference vectors to %s\n",
	       (unsigned long long)nvec, path);
}

/* Full per-row layout dump: every logical column's physical disk and role
 * (Dg.s = data slot s of group g, Pg.j = parity j of group g, Sj = spare
 * column j).  The Phase-3 population gate uses the Sj columns — the spare
 * disks are not derivable from the data-chunk vectors. */
static void emit_rowmap(const struct dcl_geom *ge, const char *path, u64 nrows)
{
	FILE *f = fopen(path, "w");
	u64 row;
	u32 lcol;

	if (!f) { perror(path); return; }
	fprintf(f, "# declustered-sim rowmap v1: row lcol disk role\n");
	for (row = 0; row < nrows; row++)
		for (lcol = 0; lcol < ge->N; lcol++) {
			u32 d = dcl_disk(ge, row, lcol);
			char role[32];

			if (lcol >= ge->ngroups * ge->g)
				snprintf(role, sizeof(role), "S%u",
					 lcol - ge->ngroups * ge->g);
			else if (lcol % ge->g >= ge->k)
				snprintf(role, sizeof(role), "P%u.%u",
					 lcol / ge->g, lcol % ge->g - ge->k);
			else
				snprintf(role, sizeof(role), "D%u.%u",
					 lcol / ge->g, lcol % ge->g);
			fprintf(f, "%llu\t%u\t%u\t%s\n",
				(unsigned long long)row, lcol, d, role);
		}
	fclose(f);
	printf("wrote %llu rowmap rows to %s\n",
	       (unsigned long long)nrows, path);
}

/* rowmap v2: v1 columns + the read-map resolved disk and dead flag for the
 * given assignment set — the multi-assignment gate's placement oracle
 * (chain rows are exactly where resolved != disk beyond one hop). */
static void emit_rowmap2(const struct dcl_geom *ge,
			 const struct dcl_assign *as, const u64 *mark,
			 u32 nas, const char *path, u64 nrows)
{
	FILE *f = fopen(path, "w");
	u64 row;
	u32 lcol, i;

	if (!f) { perror(path); return; }
	fprintf(f, "# declustered-sim rowmap v2: row lcol disk role resolved dead\n");
	fprintf(f, "# assignments:");
	for (i = 0; i < nas; i++)
		fprintf(f, " %u:%u:%llu", as[i].disk, as[i].spare,
			(unsigned long long)mark[i]);
	fprintf(f, "\n");
	for (row = 0; row < nrows; row++)
		for (lcol = 0; lcol < ge->N; lcol++) {
			u32 d = dcl_disk(ge, row, lcol);
			u32 dead, rd;
			char role[32];

			if (lcol >= ge->ngroups * ge->g)
				snprintf(role, sizeof(role), "S%u",
					 lcol - ge->ngroups * ge->g);
			else if (lcol % ge->g >= ge->k)
				snprintf(role, sizeof(role), "P%u.%u",
					 lcol / ge->g, lcol % ge->g - ge->k);
			else
				snprintf(role, sizeof(role), "D%u.%u",
					 lcol / ge->g, lcol % ge->g);
			rd = dcl_resolve(ge, as, mark, nas, row, lcol, &dead);
			fprintf(f, "%llu\t%u\t%u\t%s\t%u\t%u\n",
				(unsigned long long)row, lcol, d, role,
				rd, dead);
		}
	fclose(f);
	printf("wrote %llu rowmap rows to %s\n",
	       (unsigned long long)nrows, path);
}

/* ---- main ----------------------------------------------------------------- */

static void usage(const char *argv0)
{
	fprintf(stderr,
		"usage: %s -N <pool> -g <group=k+m> -m <parity> -s <spares>\n"
		"          [-b nbase=4] [-S seed=1] [-T tries=64]\n"
		"          [--vectors <file>] [--nvec <n=1024>]\n"
		"          [--rowmap <file>] [--nrows <n=64>]\n"
		"          [--assign X:j[:M]]... [-q]\n"
		"constraint C1: (N - s) %% g == 0\n"
		"--assign: spare assignment X->column j, optional POPULATING\n"
		"          prefix mark M in rows (omitted = POPULATED); repeatable,\n"
		"          <= s assignments, at most the LAST may carry a mark.\n"
		"          Runs the P4 chain checks; --rowmap emits v2 (resolved).\n"
		"          With s >= 2 and no --assign, P4 runs on a synthetic set.\n", argv0);
	exit(2);
}

int main(int argc, char **argv)
{
	struct dcl_geom ge;
	struct accept_result best;
	struct p2_metrics pm;
	struct dcl_assign as[DCL_MAX_ASSIGN_SIM];
	u64 mark[DCL_MAX_ASSIGN_SIM];
	u64 seed0 = 1, nvec = 1024, nrows = 64;
	u32 tries = 64, X, nas = 0, explicit_nas;
	const char *vecpath = NULL, *rowmappath = NULL;
	int i, verbose = 1, ok = 1;

	memset(&ge, 0, sizeof(ge));
	ge.nbase = 4;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-N") && i + 1 < argc)       ge.N = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-g") && i + 1 < argc)  ge.g = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-m") && i + 1 < argc)  ge.m = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-s") && i + 1 < argc)  ge.s = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-b") && i + 1 < argc)  ge.nbase = atoi(argv[++i]);
		else if (!strcmp(argv[i], "-S") && i + 1 < argc)  seed0 = strtoull(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "-T") && i + 1 < argc)  tries = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--vectors") && i + 1 < argc) vecpath = argv[++i];
		else if (!strcmp(argv[i], "--nvec") && i + 1 < argc) nvec = strtoull(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--rowmap") && i + 1 < argc) rowmappath = argv[++i];
		else if (!strcmp(argv[i], "--nrows") && i + 1 < argc) nrows = strtoull(argv[++i], NULL, 0);
		else if (!strcmp(argv[i], "--assign") && i + 1 < argc) {
			unsigned int ax, aj;
			unsigned long long am;
			int nf;

			if (nas >= DCL_MAX_ASSIGN_SIM) usage(argv[0]);
			nf = sscanf(argv[++i], "%u:%u:%llu", &ax, &aj, &am);
			if (nf < 2) usage(argv[0]);
			as[nas].disk  = ax;
			as[nas].spare = aj;
			mark[nas] = nf == 3 ? (u64)am : DCL_MARK_ALL;
			nas++;
		}
		else if (!strcmp(argv[i], "-q"))                  verbose = 0;
		else usage(argv[0]);
	}

	if (!ge.N || !ge.g || !ge.m || ge.g <= ge.m || ge.N < ge.g + ge.s)
		usage(argv[0]);
	if (ge.N > 255) {	/* on-disk format cap (GF(2^8) pool limit);
				 * also bounds check_chains' seen_disk[] */
		fprintf(stderr, "N=%u exceeds the format cap of 255 disks\n",
			ge.N);
		return 2;
	}
	if ((ge.N - ge.s) % ge.g) {
		fprintf(stderr, "C1 violated: (N-s) %% g = (%u-%u) %% %u = %u != 0\n",
			ge.N, ge.s, ge.g, (ge.N - ge.s) % ge.g);
		return 2;
	}
	ge.k = ge.g - ge.m;
	ge.ngroups = (ge.N - ge.s) / ge.g;
	ge.base  = malloc((size_t)ge.nbase * ge.N * sizeof(u32));
	ge.ibase = malloc((size_t)ge.nbase * ge.N * sizeof(u32));

	printf("geometry: N=%u pool, %u groups of g=%u (k=%u+m=%u), s=%u spares/row, "
	       "nbase=%u (period %u rows)\n",
	       ge.N, ge.ngroups, ge.g, ge.k, ge.m, ge.s, ge.nbase, ge.nbase * ge.N);

	/* acceptance search over seeds (userspace-only, floats fine) */
	accept_search(&ge, seed0, tries, &best);
	printf("accepted seed 0x%016llx after %u tries (PERM crc32 0x%08x)\n",
	       (unsigned long long)best.seed, tries,
	       crc32_buf(ge.base, (size_t)ge.nbase * ge.N * sizeof(u32)));

	/* proofs + metrics on the accepted geometry */
	ok &= check_p1(&ge, verbose);
	ok &= check_roundtrip(&ge, 200000, verbose);

	measure_p2(&ge, 0, &pm);
	printf("P2 rebuild distribution (single failure, one period):\n"
	       "  rebuilt=%llu chunks  read_cv=%.4f  write_cv=%.4f\n"
	       "  max/survivor: read=%llu write=%llu combined=%llu\n"
	       "  rebuild speedup vs dedicated spare: %.2fx "
	       "(theoretical ceiling ~%.2fx)\n",
	       (unsigned long long)pm.rebuilt, pm.read_cv, pm.write_cv,
	       (unsigned long long)pm.max_read, (unsigned long long)pm.max_write,
	       (unsigned long long)pm.max_combined,
	       pm.speedup, (double)(ge.N - 1) / ge.g);

	/* rotation-symmetry spot check: P2 must be identical for other X */
	for (X = 1; X < ge.N && X <= 3; X++) {
		struct p2_metrics pmx;
		measure_p2(&ge, X, &pmx);
		if (pmx.rebuilt != pm.rebuilt ||
		    pmx.max_combined != pm.max_combined ||
		    fabs(pmx.read_cv - pm.read_cv) > 1e-12) {
			printf("P2 SYMMETRY FAIL at X=%u\n", X);
			ok = 0;
		}
	}
	if (ok && verbose)
		printf("P2 rotation symmetry (X=1..3 identical to X=0): OK\n");

	/* P4: multi-assignment chain invariants (explicit set, or synthetic
	 * when the geometry has room for one).  Only an EXPLICIT --assign set
	 * switches --rowmap to the v2 format — the Phase-3 populate gate
	 * parses v1. */
	explicit_nas = nas;
	if (!nas && ge.s >= 2) {
		u32 a = ge.s < 3 ? ge.s : 3, ai;

		for (ai = 0; ai < a; ai++) {
			/* 2a-1 <= N-1 for every legal geometry (N >= g+s >= 3+a) */
			as[ai].disk  = ai * 2 + 1;
			as[ai].spare = ai;
			mark[ai] = DCL_MARK_ALL;
		}
		mark[a - 1] = (u64)ge.nbase * ge.N / 2;	/* newest POPULATING */
		nas = a;
	}
	if (nas) {
		u32 ai, aj;

		if (nas > ge.s) {
			fprintf(stderr, "--assign: %u assignments > s=%u\n", nas, ge.s);
			return 2;
		}
		for (ai = 0; ai < nas; ai++) {
			if (as[ai].disk >= ge.N || as[ai].spare >= ge.s) {
				fprintf(stderr, "--assign %u:%u out of range\n",
					as[ai].disk, as[ai].spare);
				return 2;
			}
			if (ai < nas - 1 && mark[ai] != DCL_MARK_ALL) {
				fprintf(stderr, "--assign: only the last assignment may be POPULATING\n");
				return 2;
			}
			for (aj = 0; aj < ai; aj++)
				if (as[ai].disk == as[aj].disk ||
				    as[ai].spare == as[aj].spare) {
					fprintf(stderr, "--assign: duplicate disk/spare\n");
					return 2;
				}
		}
		ok &= check_chains(&ge, as, mark, nas, verbose);
	}

	if (vecpath)
		emit_vectors(&ge, vecpath, nvec);
	if (rowmappath) {
		if (explicit_nas)
			emit_rowmap2(&ge, as, mark, explicit_nas,
				     rowmappath, nrows);
		else
			emit_rowmap(&ge, rowmappath, nrows);
	}

	printf("%s\n", ok ? "ALL CHECKS PASSED" : "CHECKS FAILED");
	free(ge.base); free(ge.ibase);
	return ok ? 0 : 1;
}
