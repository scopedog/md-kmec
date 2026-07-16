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

	if (crc_ok && p1_ok && bij_ok && rt_ok)
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

	/* geometry limits: doc §4 C1 + field caps */
	if (ge.m < 2 || ge.g <= ge.m || ge.N < ge.g + ge.s || ge.N > 255 ||
	    !ge.nbase || ge.nbase > DCL_ST_MAX_NBASE ||
	    (ge.N - ge.s) % ge.g) {
		pr_err("raidkm: dcl_selftest bad geometry (C1: (N-s)%%g==0; N<=255, m>=2, nbase<=%u)\n",
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

/* Read + verify one member's rkdcl metadata block (magic, version, crc,
 * geometry vs the layout word), regenerate the permutation tables from the
 * recorded seed, and hang the result off conf->dcl.  Called from setup_conf
 * with the rdevs attached; any failure aborts activation — a declustered
 * array must never run on a guessed or stale map.
 */
int raidkm_dcl_load(struct r5conf *conf, struct mddev *mddev)
{
	struct md_rdev *rdev, *from = NULL;
	struct rkdcl_sb *blk;
	struct dcl_geom *ge = NULL;
	struct page *pg;
	u32 crc, want, perm_crc;
	int layout = mddev->new_layout;
	int err = -EINVAL;

	BUILD_BUG_ON(sizeof(struct rkdcl_sb) > RKDCL_SB_BYTES);
	BUILD_BUG_ON(offsetof(struct rkdcl_sb, seed) != 40);

	rdev_for_each(rdev, mddev) {
		if (rdev->bdev && !test_bit(Faulty, &rdev->flags)) {
			from = rdev;
			break;
		}
	}
	if (!from) {
		pr_err("md/raid:%s: declustered: no readable member for the rkdcl metadata block\n",
		       mdname(mddev));
		return -EINVAL;
	}

	pg = alloc_page(GFP_KERNEL);
	if (!pg)
		return -ENOMEM;
	/* The block sits at data_offset + data_size == dev_sectors (the same
	 * derivation as the native-checksum region); sync_page_io takes the
	 * data-relative sector. */
	if (!sync_page_io(from, mddev->dev_sectors, RKDCL_SB_BYTES, pg,
			  REQ_OP_READ, false)) {
		pr_err("md/raid:%s: declustered: rkdcl metadata read failed on %pg\n",
		       mdname(mddev), from->bdev);
		err = -EIO;
		goto out_page;
	}
	blk = page_address(pg);

	if (memcmp(blk->magic, RKDCL_MAGIC, 8) ||
	    le32_to_cpu(blk->version) != RKDCL_SB_VERSION) {
		pr_err("md/raid:%s: declustered: bad rkdcl magic/version on %pg\n",
		       mdname(mddev), from->bdev);
		goto out_page;
	}
	want = le32_to_cpu(blk->hdr_crc);
	blk->hdr_crc = 0;
	crc = crc32_le(~0U, (const u8 *)blk, RKDCL_SB_BYTES) ^ ~0U;
	blk->hdr_crc = cpu_to_le32(want);
	if (crc != want) {
		pr_err("md/raid:%s: declustered: rkdcl crc mismatch on %pg (0x%08x != 0x%08x)\n",
		       mdname(mddev), from->bdev, crc, want);
		goto out_page;
	}
	/* geometry must agree with the layout word and the rdev count */
	if (le32_to_cpu(blk->pool_disks) != (u32)mddev->raid_disks ||
	    le32_to_cpu(blk->group_width) != (u32)RAIDKM_LAYOUT_DCL_G(layout) ||
	    le32_to_cpu(blk->parity) != (u32)raidkm_layout_m(layout) ||
	    le32_to_cpu(blk->spare_cols) != (u32)RAIDKM_LAYOUT_DCL_S(layout) ||
	    !le32_to_cpu(blk->nbase) || le32_to_cpu(blk->nbase) > 64) {
		pr_err("md/raid:%s: declustered: rkdcl block disagrees with the superblock layout\n",
		       mdname(mddev));
		goto out_page;
	}

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

	conf->dcl = ge;
	pr_info("md/raid:%s: declustered geometry loaded: pool N=%u, %u groups of g=%u (k=%u+m=%u), %u spare col(s)/row, nbase=%u seed=0x%llx perm_crc=0x%08x\n",
		mdname(mddev), ge->N, ge->ngroups, ge->g, ge->k, ge->m,
		ge->s, ge->nbase, (unsigned long long)ge->seed, perm_crc);
	__free_page(pg);
	return 0;

out_ge:
	kvfree(ge->base);
	kvfree(ge->ibase);
	kfree(ge);
out_page:
	__free_page(pg);
	return err;
}

void raidkm_dcl_free(struct r5conf *conf)
{
	if (!conf->dcl)
		return;
	kvfree(conf->dcl->base);
	kvfree(conf->dcl->ibase);
	kfree(conf->dcl);
	conf->dcl = NULL;
}
