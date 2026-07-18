// SPDX-License-Identifier: GPL-2.0
/*
 * raid_km-dcl.c — declustered-parity support for raidkm: Phase 1a self-test.
 *
 * Kernel<->userspace map parity gate (design doc §5a / Phase 1): the
 * userspace acceptance search (tools/declustered-sim.c, later mdadm --create)
 * picks a seed; the kernel must regenerate the IDENTICAL permutation set and
 * mapping from that seed alone.  This file exposes
 *
 *     /sys/module/raidkm/parameters/dcl_selftest
 *
 * Write "N:g:m:s:nbase:seed[:crc32]" to run, entirely standalone (no array,
 * no interaction with live conf state):
 *
 *   1. regenerate PERM from the seed, fingerprint it with crc32-le and (if a
 *      crc was supplied) compare against the simulator's PERM_CRC32;
 *   2. assert P1 capacity balance is EXACT over one period;
 *   3. assert per-row bijectivity + inverse-map consistency over one period;
 *   4. forward/inverse roundtrip over 200k logical chunks;
 *   5. dump the first 32 forward mappings as "DCLMAP ..." lines for
 *      field-by-field comparison against the simulator's reference vectors.
 *
 * Driven by tools/raidkm-test-declustered-map.sh, which runs the simulator
 * and this test on the same seed and diffs the results.  Reading the
 * parameter returns the last verdict line.
 *
 * The mapping core itself is raid_km_dcl.h (lifted verbatim from the
 * simulator's KERNEL-CORE block).  No I/O-path integration yet: Phase 1a is
 * purely additive — raid_km.c is untouched and declustered arrays cannot be
 * created until the layout mode lands (Phase 1b/1c).
 */

#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/crc32.h>
#include <linux/blkdev.h>
#include "md.h"
#include "raid_km.h"
#include "raid_km_dcl.h"

#define DCL_ST_ROUNDTRIP_CHUNKS	200000ULL
#define DCL_ST_DUMP_VECTORS	32
#define DCL_ST_MAX_NBASE	64

static DEFINE_MUTEX(dcl_selftest_lock);
static char dcl_selftest_result[128] = "never run";

/* Chain-walk equivalence sweep (selftest step 6).  Builds a synthetic
 * assignment set (a = min(s, 3) assignments on distinct disks, the last one
 * POPULATING) plus a minimal fake conf carrying ONLY the fields the runtime
 * walks read (dcl, reb[], nreb, reb_pop, reb_mark, chunk_sectors), then
 * asserts, over one full period:
 *   - runtime redirect == core dcl_resolve, read + write maps, with the
 *     POPULATING prefix mark at 0, period/2 and period rows;
 *   - runtime chain_root == core dcl_chain_root == the unique group column
 *     dcl_chain_traverses finds, for every assigned disk + a live probe.
 * The runtime coverage compare `(row+1)*chunk_sectors <= mark_sectors` is
 * exactly `row < mark_rows` when mark_sectors = mark_rows*chunk_sectors,
 * which is how the core's row-granular mark[] is populated. */
#define DCL_ST_CHUNK_SECT	128	/* 64K chunks: any value works */

static bool dcl_selftest_chains(struct dcl_geom *ge)
{
	u64 period = (u64)ge->nbase * ge->N;
	u32 gcols = ge->ngroups * ge->g;
	u32 nas = min_t(u32, ge->s, 3);
	struct dcl_assign as[3];
	u64 mark_core[3];
	struct rkdcl_reb reb[3];
	struct r5conf *conf;
	static const u32 mark_div[] = { 0, 2, 1 };  /* -> 0, period/2, period */
	u32 mi, i;
	u64 row;
	bool ok = true;

	conf = kzalloc(sizeof(*conf), GFP_KERNEL);
	if (!conf)
		return false;
	conf->dcl = ge;
	conf->reb = reb;
	conf->chunk_sectors = DCL_ST_CHUNK_SECT;

	for (i = 0; i < nas; i++) {
		/* distinct disks for every legal geometry (2a-1 <= N-1) */
		as[i].disk  = i * 2 + 1;
		as[i].spare = i;
		reb[i].disk  = (int)as[i].disk;
		reb[i].spare = (int)as[i].spare;
		reb[i].state = RKDCL_ASSIGN_POPULATED;
	}
	reb[nas - 1].state = RKDCL_ASSIGN_POPULATING;
	conf->nreb = (int)nas;
	conf->reb_pop = (int)nas - 1;

	for (mi = 0; mi < ARRAY_SIZE(mark_div) && ok; mi++) {
		u64 mark_rows = mark_div[mi] ? period / mark_div[mi] : 0;
		u32 lcol;

		atomic64_set(&conf->reb_mark,
			     mark_rows * DCL_ST_CHUNK_SECT);
		for (i = 0; i < nas; i++)
			mark_core[i] = DCL_MARK_ALL;
		mark_core[nas - 1] = mark_rows;

		for (row = 0; row < period && ok; row++) {
			for (lcol = 0; lcol < gcols; lcol++) {
				u32 dead, want_r, want_w;
				int got_r, got_w;
				int disk0 = (int)dcl_disk(ge, row, lcol);

				want_r = dcl_resolve(ge, as, mark_core, nas,
						     row, lcol, &dead);
				got_r = raidkm_dcl_test_redirect(conf, disk0,
								 row, false);
				/* write map: every hop covered */
				mark_core[nas - 1] = DCL_MARK_ALL;
				want_w = dcl_resolve(ge, as, mark_core, nas,
						     row, lcol, &dead);
				mark_core[nas - 1] = mark_rows;
				got_w = raidkm_dcl_test_redirect(conf, disk0,
								 row, true);
				if (got_r != (int)want_r ||
				    got_w != (int)want_w) {
					pr_err("raidkm: DCLTEST chain FAIL row %llu lcol %u mark %llu: runtime r/w %d/%d core %u/%u\n",
					       (unsigned long long)row, lcol,
					       (unsigned long long)mark_rows,
					       got_r, got_w, want_r, want_w);
					ok = false;
					break;
				}
			}
			/* inverse walk: assigned disks + one live probe */
			for (i = 0; i <= nas && ok; i++) {
				u32 probe, k2, fwd_n = 0, cc;
				int fwd = -1, inv_core, inv_rt;

				if (i < nas) {
					probe = as[i].disk;
				} else {
					/* live probe: restart the collision
					 * scan after each bump — a single
					 * pass can land on an earlier entry
					 * when disks are unsorted */
					probe = (as[0].disk + 1) % ge->N;
					k2 = 0;
					while (k2 < nas) {
						if (as[k2].disk == probe) {
							probe = (probe + 1) %
								ge->N;
							k2 = 0;
						} else {
							k2++;
						}
					}
				}
				for (cc = 0; cc < gcols; cc++)
					if (dcl_chain_traverses(ge, as, nas,
								row, cc,
								probe)) {
						fwd = (int)cc;
						fwd_n++;
					}
				inv_core = dcl_chain_root(ge, as, nas, row,
							  probe);
				inv_rt = raidkm_dcl_test_chain_root(conf, row,
								(int)probe);
				if (fwd_n > 1 || inv_core != fwd ||
				    inv_rt != fwd) {
					pr_err("raidkm: DCLTEST chain-root FAIL row %llu disk %u: fwd=%d(n=%u) core=%d runtime=%d\n",
					       (unsigned long long)row, probe,
					       fwd, fwd_n, inv_core, inv_rt);
					ok = false;
				}
			}
			cond_resched();
		}
	}
	if (ok)
		pr_info("raidkm: DCLTEST chain-walk equivalence OK (%u assignment(s), %u marks, %llu rows)\n",
			nas, (u32)ARRAY_SIZE(mark_div),
			(unsigned long long)period);
	kfree(conf);
	return ok;
}

static int dcl_selftest_run(struct dcl_geom *ge, u32 want_crc)
{
	u64 period = (u64)ge->nbase * ge->N;
	u64 row, lc, lc2;
	u32 crc, lcol, d, group, slot, role;
	u64 *cnt = NULL;
	u8 *seen = NULL;
	struct dcl_addr a;
	int err = -EIO;
	bool crc_ok = true, p1_ok = true, bij_ok = true, rt_ok = true;
	bool chain_ok = true;

	dcl_geom_tables(ge);

	/* 1. PERM fingerprint (crc32-le == the simulator's crc32_buf) */
	crc = crc32_le(~0U, (const u8 *)ge->base,
		       (size_t)ge->nbase * ge->N * sizeof(u32)) ^ ~0U;
	if (want_crc && crc != want_crc) {
		pr_err("raidkm: DCLTEST perm crc 0x%08x != expected 0x%08x\n",
		       crc, want_crc);
		crc_ok = false;
	}

	cnt = kvcalloc((size_t)ge->N * 3, sizeof(*cnt), GFP_KERNEL);
	seen = kmalloc(ge->N, GFP_KERNEL);
	if (!cnt || !seen) {
		err = -ENOMEM;
		goto out;
	}

	/* 2+3. one pass over the period: role counts, bijectivity, inverse */
	for (row = 0; row < period && bij_ok; row++) {
		memset(seen, 0, ge->N);
		for (lcol = 0; lcol < ge->N; lcol++) {
			d = dcl_disk(ge, row, lcol);
			role = dcl_role(ge, lcol, &group, &slot);
			if (d >= ge->N || seen[d] ||
			    dcl_lcol(ge, row, d) != lcol) {
				pr_err("raidkm: DCLTEST bijectivity/inverse FAIL row %llu lcol %u disk %u\n",
				       (unsigned long long)row, lcol, d);
				bij_ok = false;
				break;
			}
			seen[d] = 1;
			cnt[(size_t)d * 3 + role]++;
		}
		cond_resched();
	}
	for (d = 0; d < ge->N && bij_ok; d++) {
		if (cnt[(size_t)d * 3 + DCL_ROLE_DATA]   != (u64)ge->nbase * ge->ngroups * ge->k ||
		    cnt[(size_t)d * 3 + DCL_ROLE_PARITY] != (u64)ge->nbase * ge->ngroups * ge->m ||
		    cnt[(size_t)d * 3 + DCL_ROLE_SPARE]  != (u64)ge->nbase * ge->s) {
			pr_err("raidkm: DCLTEST P1 FAIL disk %u: data=%llu parity=%llu spare=%llu\n",
			       d,
			       (unsigned long long)cnt[(size_t)d * 3 + 0],
			       (unsigned long long)cnt[(size_t)d * 3 + 1],
			       (unsigned long long)cnt[(size_t)d * 3 + 2]);
			p1_ok = false;
		}
	}

	/* 4. forward -> inverse roundtrip */
	for (lc = 0; lc < DCL_ST_ROUNDTRIP_CHUNKS && rt_ok; lc++) {
		dcl_forward(ge, lc, &a);
		if (a.disk >= ge->N ||
		    dcl_inverse(ge, a.disk, a.row, &lc2, &group, &slot)
			!= DCL_ROLE_DATA ||
		    lc2 != lc || group != a.group || slot != a.slot) {
			pr_err("raidkm: DCLTEST roundtrip FAIL lc=%llu\n",
			       (unsigned long long)lc);
			rt_ok = false;
		}
		if (!(lc & 0xffff))
			cond_resched();
	}

	/* 5. reference vectors for the userspace diff */
	for (lc = 0; lc < DCL_ST_DUMP_VECTORS; lc++) {
		dcl_forward(ge, lc, &a);
		pr_info("raidkm: DCLMAP %llu %llu %u %u %u %u\n",
			(unsigned long long)lc, (unsigned long long)a.row,
			a.group, a.slot, a.lcol, a.disk);
	}

	/* 6. chain-walk equivalence: the RUNTIME walks (raidkm_dcl_redirect
	 * / raidkm_dcl_chain_root, reached via the raid_km.c test hooks on a
	 * synthetic conf) must match the KERNEL-CORE reference walks
	 * (dcl_resolve / dcl_chain_root / dcl_chain_traverses) — same code
	 * the simulator's P4/A6 checker proves — over the full period, for
	 * read and write maps, at empty/mid/full prefix marks.  This is the
	 * mechanical tie between the proven reference and the code the I/O
	 * path actually executes (three hand-synced copies otherwise). */
	if (!dcl_selftest_chains(ge))
		chain_ok = false;

	if (crc_ok && p1_ok && bij_ok && rt_ok && chain_ok)
		err = 0;
	scnprintf(dcl_selftest_result, sizeof(dcl_selftest_result),
		  "N=%u g=%u m=%u s=%u nbase=%u seed=0x%llx crc=0x%08x %s",
		  ge->N, ge->g, ge->m, ge->s, ge->nbase,
		  (unsigned long long)ge->seed, crc, err ? "FAIL" : "PASS");
	pr_info("raidkm: DCLTEST %s\n", dcl_selftest_result);
out:
	kvfree(cnt);
	kfree(seen);
	return err;
}

static int dcl_selftest_set(const char *val, const struct kernel_param *kp)
{
	struct dcl_geom ge;
	u64 seed;
	u32 want_crc = 0;
	int n, ret;

	memset(&ge, 0, sizeof(ge));
	n = sscanf(val, "%u:%u:%u:%u:%u:%llx:%x",
		   &ge.N, &ge.g, &ge.m, &ge.s, &ge.nbase, &seed, &want_crc);
	if (n < 6) {
		pr_err("raidkm: dcl_selftest wants N:g:m:s:nbase:seed[:crc]\n");
		return -EINVAL;
	}
	ge.seed = seed;

	/* geometry limits: doc §4 C1 + field caps.  s >= 1 matches mdadm's
	 * rkdcl_validate_geometry AND protects the chain sweep, whose
	 * synthetic assignment set indexes reb[nas-1] with nas=min(s,3). */
	if (ge.m < 2 || ge.g <= ge.m || !ge.s || ge.N < ge.g + ge.s ||
	    ge.N > 255 || !ge.nbase || ge.nbase > DCL_ST_MAX_NBASE ||
	    (ge.N - ge.s) % ge.g) {
		pr_err("raidkm: dcl_selftest bad geometry (C1: (N-s)%%g==0; N<=255, m>=2, s>=1, nbase<=%u)\n",
		       DCL_ST_MAX_NBASE);
		return -EINVAL;
	}
	ge.k = ge.g - ge.m;
	ge.ngroups = (ge.N - ge.s) / ge.g;

	ge.base  = kvmalloc_array((size_t)ge.nbase * ge.N, sizeof(u32),
				  GFP_KERNEL);
	ge.ibase = kvmalloc_array((size_t)ge.nbase * ge.N, sizeof(u32),
				  GFP_KERNEL);
	if (!ge.base || !ge.ibase) {
		ret = -ENOMEM;
		goto out;
	}

	mutex_lock(&dcl_selftest_lock);
	ret = dcl_selftest_run(&ge, want_crc);
	mutex_unlock(&dcl_selftest_lock);
out:
	kvfree(ge.base);
	kvfree(ge.ibase);
	return ret;
}

static int dcl_selftest_get(char *buffer, const struct kernel_param *kp)
{
	int len;

	mutex_lock(&dcl_selftest_lock);
	len = scnprintf(buffer, PAGE_SIZE, "%s\n", dcl_selftest_result);
	mutex_unlock(&dcl_selftest_lock);
	return len;
}

static const struct kernel_param_ops dcl_selftest_ops = {
	.set = dcl_selftest_set,
	.get = dcl_selftest_get,
};
module_param_cb(dcl_selftest, &dcl_selftest_ops, NULL, 0600);
MODULE_PARM_DESC(dcl_selftest,
	"declustered map self-test: write N:g:m:s:nbase:seed[:crc32] (see tools/raidkm-test-declustered-map.sh)");

/* ---- Phase 1c: load the on-disk rkdcl metadata block at setup_conf -------- */

/* Verify a candidate rkdcl block (magic, version 1..3, crc, geometry vs
 * the layout word, v2/v3 assignment sanity).  Returns 0 if the block is
 * valid for this array. */
static int rkdcl_verify_blk(struct mddev *mddev, struct rkdcl_sb *blk)
{
	int layout = mddev->new_layout;
	u32 vers = le32_to_cpu(blk->version);
	u32 crc, want;

	if (memcmp(blk->magic, RKDCL_MAGIC, 8) ||
	    vers < RKDCL_SB_VERSION || vers > RKDCL_SB_VERSION3)
		return -EINVAL;
	want = le32_to_cpu(blk->hdr_crc);
	blk->hdr_crc = 0;
	crc = crc32_le(~0U, (const u8 *)blk, RKDCL_SB_BYTES) ^ ~0U;
	blk->hdr_crc = cpu_to_le32(want);
	if (crc != want)
		return -EINVAL;
	/* geometry must agree with the layout word and the rdev count */
	if (le32_to_cpu(blk->pool_disks) != (u32)mddev->raid_disks ||
	    le32_to_cpu(blk->group_width) != (u32)RAIDKM_LAYOUT_DCL_G(layout) ||
	    le32_to_cpu(blk->parity) != (u32)raidkm_layout_m(layout) ||
	    le32_to_cpu(blk->spare_cols) != (u32)RAIDKM_LAYOUT_DCL_S(layout) ||
	    !le32_to_cpu(blk->nbase) || le32_to_cpu(blk->nbase) > 64)
		return -EINVAL;
	if (vers == RKDCL_SB_VERSION2) {
		u32 x = le32_to_cpu(blk->assign_disk);
		u32 j = le32_to_cpu(blk->assign_spare);
		u32 st = le32_to_cpu(blk->assign_state);

		if (st > RKDCL_ASSIGN_COPYING)
			return -EINVAL;
		if (st != RKDCL_ASSIGN_NONE &&
		    (x >= le32_to_cpu(blk->pool_disks) ||
		     j >= le32_to_cpu(blk->spare_cols)))
			return -EINVAL;
	}
	if (vers >= RKDCL_SB_VERSION3) {
		u32 n = le32_to_cpu(blk->nassign);
		u32 i, k, npop = 0;

		if (n > le32_to_cpu(blk->spare_cols) || n > RKDCL_MAX_ASSIGN)
			return -EINVAL;
		for (i = 0; i < n; i++) {
			u32 x  = le32_to_cpu(blk->assign[i].disk);
			u32 j  = le32_to_cpu(blk->assign[i].spare);
			u32 st = le32_to_cpu(blk->assign[i].state);

			/* table entries are ACTIVE by definition.  COPYING
			 * only reaches v3 once multi-assignment copy exists
			 * (today build_blk emits v2 for nreb==1), but the
			 * three v2/v3 sites (verify/load/build) must agree
			 * on the format ahead of that. */
			if (st != RKDCL_ASSIGN_POPULATING &&
			    st != RKDCL_ASSIGN_POPULATED &&
			    st != RKDCL_ASSIGN_COPYING)
				return -EINVAL;
			/* at most ONE in-flight pass (sequential rule) */
			if ((st == RKDCL_ASSIGN_POPULATING ||
			     st == RKDCL_ASSIGN_COPYING) && ++npop > 1)
				return -EINVAL;
			if (x >= le32_to_cpu(blk->pool_disks) ||
			    j >= le32_to_cpu(blk->spare_cols))
				return -EINVAL;
			for (k = 0; k < i; k++)
				if (le32_to_cpu(blk->assign[k].disk) == x ||
				    le32_to_cpu(blk->assign[k].spare) == j)
					return -EINVAL;	/* duplicates */
		}
	}
	return 0;
}

/* Read + verify the rkdcl metadata block from EVERY readable member and keep
 * the highest-generation valid copy (v1 blocks count as gen 0) — a torn
 * multi-member journal update must never roll the assignment state back
 * further than the last checkpoint.  Regenerate the permutation tables from
 * the recorded seed, hang the result off conf->dcl, and restore the Phase-3
 * spare-assignment state.  Called from setup_conf with the rdevs attached;
 * total failure aborts activation — a declustered array must never run on a
 * guessed or stale map.
 */
int raidkm_dcl_load(struct r5conf *conf, struct mddev *mddev)
{
	struct md_rdev *rdev;
	struct rkdcl_sb *blk, *best;
	struct dcl_geom *ge = NULL;
	struct page *pg, *best_pg;
	u32 perm_crc;
	u64 best_gen = 0;
	bool have_best = false;
	int nread = 0;
	int err = -EINVAL;

	BUILD_BUG_ON(sizeof(struct rkdcl_sb) > RKDCL_SB_BYTES);
	BUILD_BUG_ON(offsetof(struct rkdcl_sb, seed) != 40);
	BUILD_BUG_ON(offsetof(struct rkdcl_sb, gen) != 56);
	BUILD_BUG_ON(offsetof(struct rkdcl_sb, assign_mark) != 80);
	BUILD_BUG_ON(offsetof(struct rkdcl_sb, nassign) != 88);
	BUILD_BUG_ON(offsetof(struct rkdcl_sb, assign) != 96);
	BUILD_BUG_ON(sizeof(struct rkdcl_assign) != 24);

	pg = alloc_page(GFP_KERNEL);
	best_pg = alloc_page(GFP_KERNEL);
	if (!pg || !best_pg) {
		err = -ENOMEM;
		goto out_page;
	}
	blk = page_address(pg);
	best = page_address(best_pg);

	rdev_for_each(rdev, mddev) {
		u64 gen;

		if (!rdev->bdev || test_bit(Faulty, &rdev->flags))
			continue;
		/* The block sits at data_offset + data_size == dev_sectors
		 * (the same derivation as the native-checksum region);
		 * sync_page_io takes the data-relative sector. */
		if (!sync_page_io(rdev, mddev->dev_sectors, RKDCL_SB_BYTES,
				  pg, REQ_OP_READ, false)) {
			pr_warn("md/raid:%s: declustered: rkdcl metadata read failed on %pg\n",
				mdname(mddev), rdev->bdev);
			continue;
		}
		nread++;
		if (rkdcl_verify_blk(mddev, blk))
			continue;
		gen = le32_to_cpu(blk->version) >= RKDCL_SB_VERSION2 ?
			le64_to_cpu(blk->gen) : 0;
		if (!have_best || gen > best_gen) {
			memcpy(best, blk, RKDCL_SB_BYTES);
			best_gen = gen;
			have_best = true;
		}
	}
	if (!have_best) {
		pr_err("md/raid:%s: declustered: no valid rkdcl metadata block on any member (%d readable)\n",
		       mdname(mddev), nread);
		goto out_page;
	}
	blk = best;

	ge = kzalloc(sizeof(*ge), GFP_KERNEL);
	if (!ge) {
		err = -ENOMEM;
		goto out_page;
	}
	ge->N = le32_to_cpu(blk->pool_disks);
	ge->g = le32_to_cpu(blk->group_width);
	ge->m = le32_to_cpu(blk->parity);
	ge->k = ge->g - ge->m;
	ge->s = le32_to_cpu(blk->spare_cols);
	ge->ngroups = (ge->N - ge->s) / ge->g;
	ge->nbase = le32_to_cpu(blk->nbase);
	ge->seed = le64_to_cpu(blk->seed);
	ge->base  = kvmalloc_array((size_t)ge->nbase * ge->N, sizeof(u32),
				   GFP_KERNEL);
	ge->ibase = kvmalloc_array((size_t)ge->nbase * ge->N, sizeof(u32),
				   GFP_KERNEL);
	if (!ge->base || !ge->ibase) {
		err = -ENOMEM;
		goto out_ge;
	}
	dcl_geom_tables(ge);
	perm_crc = crc32_le(~0U, (const u8 *)ge->base,
			    (size_t)ge->nbase * ge->N * sizeof(u32)) ^ ~0U;

	/* Phase 3: restore the spare-assignment / population state from the
	 * winning (highest-gen) block.  The journal mark is a safe UNDER-
	 * estimate of progress (checkpoints lag the runtime prefix mark);
	 * population redoes rows [journal, crash) — idempotent spare
	 * rewrites. */
	spin_lock_init(&conf->reb_win_lock);
	conf->nreb = 0;
	conf->reb_pop = -1;
	conf->reb_want = -1;
	conf->reb_gen = best_gen;
	/* window + assignment table allocated unconditionally: runtime
	 * arming needs them too */
	conf->reb_win_bits = bitmap_zalloc(RKDCL_REB_WINDOW, GFP_KERNEL);
	conf->reb = kcalloc(ge->s, sizeof(*conf->reb), GFP_KERNEL);
	if (!conf->reb_win_bits || !conf->reb) {
		err = -ENOMEM;
		goto out_reb;
	}
	/* disk -1 everywhere: a not-yet-published entry must never match a
	 * real physical index if a racing reader glimpses it (arm publishes
	 * with store-release, this is defense in depth; kcalloc's zero would
	 * alias healthy disk 0). */
	for (nread = 0; nread < (int)ge->s; nread++) {
		conf->reb[nread].disk  = -1;
		conf->reb[nread].spare = -1;
	}
	nread = 0;
	if (le32_to_cpu(blk->version) == RKDCL_SB_VERSION2 &&
	    le32_to_cpu(blk->assign_state) != RKDCL_ASSIGN_NONE) {
		/* v2: single legacy assignment */
		conf->reb[0].state = le32_to_cpu(blk->assign_state);
		conf->reb[0].disk  = le32_to_cpu(blk->assign_disk);
		conf->reb[0].spare = le32_to_cpu(blk->assign_spare);
		conf->nreb = 1;
		if (conf->reb[0].state == RKDCL_ASSIGN_POPULATING ||
		    conf->reb[0].state == RKDCL_ASSIGN_COPYING)
			conf->reb_pop = 0;	/* a sync pass is mid-flight */
	} else if (le32_to_cpu(blk->version) >= RKDCL_SB_VERSION3) {
		/* v3: assignment table (verified: <= s, distinct,
		 * <= 1 POPULATING) */
		u32 i, n = le32_to_cpu(blk->nassign);

		for (i = 0; i < n; i++) {
			conf->reb[i].disk  = le32_to_cpu(blk->assign[i].disk);
			conf->reb[i].spare = le32_to_cpu(blk->assign[i].spare);
			conf->reb[i].state = le32_to_cpu(blk->assign[i].state);
			if (conf->reb[i].state == RKDCL_ASSIGN_POPULATING ||
			    conf->reb[i].state == RKDCL_ASSIGN_COPYING)
				conf->reb_pop = i;	/* pass mid-flight */
		}
		conf->nreb = n;
	}
	if (conf->reb_pop >= 0) {
		/* restore the active (POPULATING/COPYING) entry's prefix mark
		 * (v2: legacy field; v3: its table entry) */
		u64 mark = le32_to_cpu(blk->version) == RKDCL_SB_VERSION2 ?
			le64_to_cpu(blk->assign_mark) :
			le64_to_cpu(blk->assign[conf->reb_pop].mark);
		u64 base = mark;

		do_div(base, RAID5_STRIPE_SECTORS(conf));
		atomic64_set(&conf->reb_mark, mark);
		conf->reb_journal_mark = mark;
		conf->reb_win_base = base;	/* stripe-address granules */
	}

	conf->dcl = ge;
	pr_info("md/raid:%s: declustered geometry loaded: pool N=%u, %u groups of g=%u (k=%u+m=%u), %u spare col(s)/row, nbase=%u seed=0x%llx perm_crc=0x%08x\n",
		mdname(mddev), ge->N, ge->ngroups, ge->g, ge->k, ge->m,
		ge->s, ge->nbase, (unsigned long long)ge->seed, perm_crc);
	for (nread = 0; nread < conf->nreb; nread++)
		pr_info("md/raid:%s: declustered: spare assignment restored: disk %d -> spare col %d, %s, mark %llu (gen %llu)\n",
			mdname(mddev), conf->reb[nread].disk,
			conf->reb[nread].spare,
			conf->reb[nread].state == RKDCL_ASSIGN_POPULATING ?
				"POPULATING" :
			conf->reb[nread].state == RKDCL_ASSIGN_COPYING ?
				"COPYING" : "POPULATED",
			nread == conf->reb_pop ?
				(unsigned long long)atomic64_read(&conf->reb_mark) :
				(unsigned long long)mddev->dev_sectors,
			(unsigned long long)conf->reb_gen);
	__free_page(pg);
	__free_page(best_pg);
	return 0;

out_reb:
	bitmap_free(conf->reb_win_bits);
	conf->reb_win_bits = NULL;
	kfree(conf->reb);
	conf->reb = NULL;
out_ge:
	kvfree(ge->base);
	kvfree(ge->ibase);
	kfree(ge);
out_page:
	if (pg)
		__free_page(pg);
	if (best_pg)
		__free_page(best_pg);
	return err;
}

void raidkm_dcl_free(struct r5conf *conf)
{
	if (!conf->dcl)
		return;
	/* the raid5d thread is already stopped, so no re-queue can race */
	cancel_work_sync(&conf->dcl_rescue_work);
	kvfree(conf->dcl->base);
	kvfree(conf->dcl->ibase);
	kfree(conf->dcl);
	conf->dcl = NULL;
	bitmap_free(conf->reb_win_bits);
	conf->reb_win_bits = NULL;
	kfree(conf->reb);
	conf->reb = NULL;
}

/* ---- Phase 3: the rkdcl journal (spare assignment + rebuild mark) --------- */

/* Build the on-disk block from the conf state (geometry from conf->dcl,
 * assignments from conf->reb[]).  ADAPTIVE VERSIONING (raid_km_dcl.h): v2
 * while <= 1 assignment is active — the published v2 module can still
 * assemble the array — and v3 while >= 2 (the v2 module must fail CLOSED,
 * which rejecting version 3 provides).  Since every journal write lands on
 * the same 4 KiB slot of ALL live members, the transition replaces every
 * older-format copy.  In a v3 block the legacy assign_* fields mirror
 * entry 0 (display only; the table is authoritative). */
static void rkdcl_build_blk(struct r5conf *conf, struct rkdcl_sb *blk)
{
	struct dcl_geom *ge = conf->dcl;
	u64 emark;
	int i;

	memset(blk, 0, RKDCL_SB_BYTES);
	memcpy(blk->magic, RKDCL_MAGIC, 8);
	blk->version	 = cpu_to_le32(conf->nreb >= 2 ?
				       RKDCL_SB_VERSION3 : RKDCL_SB_VERSION2);
	blk->pool_disks	 = cpu_to_le32(ge->N);
	blk->group_width = cpu_to_le32(ge->g);
	blk->parity	 = cpu_to_le32(ge->m);
	blk->spare_cols	 = cpu_to_le32(ge->s);
	blk->ngroups	 = cpu_to_le32(ge->ngroups);
	blk->nbase	 = cpu_to_le32(ge->nbase);
	blk->seed	 = cpu_to_le64(ge->seed);
	blk->gen	 = cpu_to_le64(conf->reb_gen);
	if (conf->nreb) {
		/* legacy fields = entry 0 (v2: the whole story; v3: mirror) */
		emark = conf->reb_pop == 0 ? conf->reb_journal_mark :
					     conf->mddev->dev_sectors;
		blk->assign_state = cpu_to_le32(conf->reb[0].state);
		blk->assign_disk  = cpu_to_le32(conf->reb[0].disk);
		blk->assign_spare = cpu_to_le32(conf->reb[0].spare);
		blk->assign_mark  = cpu_to_le64(emark);
	} else {
		blk->assign_state = cpu_to_le32(RKDCL_ASSIGN_NONE);
		blk->assign_disk  = cpu_to_le32(RKDCL_NO_ASSIGN);
	}
	if (conf->nreb >= 2) {
		blk->nassign = cpu_to_le32(conf->nreb);
		for (i = 0; i < conf->nreb; i++) {
			emark = conf->reb_pop == i ? conf->reb_journal_mark :
						     conf->mddev->dev_sectors;
			blk->assign[i].disk  = cpu_to_le32(conf->reb[i].disk);
			blk->assign[i].spare = cpu_to_le32(conf->reb[i].spare);
			blk->assign[i].state = cpu_to_le32(conf->reb[i].state);
			blk->assign[i].mark  = cpu_to_le64(emark);
		}
	}
	blk->hdr_crc = 0;
	blk->hdr_crc = cpu_to_le32(crc32_le(~0U, (const u8 *)blk,
					    RKDCL_SB_BYTES) ^ ~0U);
}

/* Checkpoint the assignment state to every live member (gen++, FUA).
 * BLOCKING — md sync-thread / arming / add_disk context only, never the
 * stripe path (the P3a rule).
 *
 * Two success policies:
 *  - LAX (mark checkpoints, completion): at least one member carries the
 *    new generation.  Members that missed it only cost journal freshness,
 *    never correctness — the mark is an under-estimate and completion
 *    replays idempotently from the last POPULATING record.
 *  - STRICT (arm / retire — assignment-SET transitions, which include the
 *    adaptive v2<->v3 version flips): EVERY non-Faulty member must accept
 *    the block.  A live member left holding a stale lower-gen copy is
 *    invisible to the new module's gen election, but the PUBLISHED v2
 *    module rejects v3 blocks — a stale v2 survivor would be the only
 *    "valid" copy it sees and would resurrect the old assignment set
 *    instead of failing closed.  Same-version transitions want it too: a
 *    retire recorded on a single member resurrects retired assignments if
 *    that member is later lost.  Callers roll the transition back on
 *    -EIO.  (Residual caveat, documented in the design note: a FAULTY
 *    member's block cannot be rewritten at all; its staleness is fenced
 *    by md's own event-count gating at assemble.)
 */
int raidkm_dcl_journal_write(struct r5conf *conf, bool strict)
{
	struct mddev *mddev = conf->mddev;
	struct md_rdev *rdev;
	struct page *pg;
	int written = 0, failed = 0;

	pg = alloc_page(GFP_KERNEL);
	if (!pg)
		return -ENOMEM;
	conf->reb_gen++;
	conf->reb_journal_mark = (u64)atomic64_read(&conf->reb_mark);
	rkdcl_build_blk(conf, page_address(pg));

	rdev_for_each(rdev, mddev) {
		if (!rdev->bdev || test_bit(Faulty, &rdev->flags))
			continue;
		/* PREFLUSH: the journaled mark asserts "spare writes below
		 * this are durable" — flush each member's cache (population
		 * data writes are not FUA) before the FUA'd journal block. */
		if (sync_page_io(rdev, mddev->dev_sectors, RKDCL_SB_BYTES, pg,
				 REQ_OP_WRITE | REQ_SYNC | REQ_PREFLUSH |
				 REQ_FUA, false)) {
			written++;
		} else {
			failed++;
			pr_warn("md/raid:%s: declustered: rkdcl journal write failed on %pg%s\n",
				mdname(mddev), rdev->bdev,
				strict ? " (strict transition write)" : "");
		}
	}
	__free_page(pg);
	if (strict)
		return failed ? -EIO : (written ? 0 : -EIO);
	return written ? 0 : -EIO;
}

/* A population stripe address (or a skipped one) is durably done; advance
 * the prefix read-mark.  The window is in STRIPE-ADDRESS granules (one row =
 * chunk_sectors / RAID5_STRIPE_SECTORS of them); the exported reb_mark is in
 * DEVICE SECTORS.  Completions may reorder inside md's flight window, so
 * they are collected in a circular bitmap and the mark only advances over a
 * solid prefix (a populated-but-unmarked row keeps decoding on the fly —
 * correct, merely slower). */
void raidkm_dcl_pop_done(struct r5conf *conf, sector_t sector)
{
	u64 granule = (u64)sector;
	unsigned long flags;

	do_div(granule, RAID5_STRIPE_SECTORS(conf));
	spin_lock_irqsave(&conf->reb_win_lock, flags);
	if (granule < conf->reb_win_base)	/* journal-resume redo */
		goto out;
	if (WARN_ON_ONCE(granule >= conf->reb_win_base + RKDCL_REB_WINDOW))
		goto out;	/* mark stalls; correctness kept (decode) */
	__set_bit(granule % RKDCL_REB_WINDOW, conf->reb_win_bits);
	while (test_bit(conf->reb_win_base % RKDCL_REB_WINDOW,
			conf->reb_win_bits)) {
		__clear_bit(conf->reb_win_base % RKDCL_REB_WINDOW,
			    conf->reb_win_bits);
		conf->reb_win_base++;
	}
	atomic64_set(&conf->reb_mark,
		     conf->reb_win_base * RAID5_STRIPE_SECTORS(conf));
out:
	spin_unlock_irqrestore(&conf->reb_win_lock, flags);
}
