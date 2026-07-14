# Native checksum read-first redesign — inline verify + verified bypass (2026-07-14)

Shipped as md-kmec `1786f9a` (+ thrash-test commit `a371a51`), srcversion
7EE5AF0B0804BC733AA115F.  Supersedes the "step 1 / always-defer" engine
(`46489a5`) and the sharded verify engine (`29b47ec`) as the read path; the
demand-paged region cache, the on-disk region format, and the write-side CRC
computation are unchanged.

## Why

Real-NVMe benchmarking (bench-nvme16-csum, 8×local-SSD, raidkm m=2) showed the
sharded engine tied baseline on sequential reads (≥4 jobs) and on writes, but
random read sat at **37% of baseline** (459K vs 1236K iops).  Two causes, both
latency-shaped:

1. `chunk_aligned_read` was gated off under csum (`!conf->csum`) because the
   bypass skipped verification — so every 4K read paid the full stripe-cache
   path while the no-csum baseline flew through the bypass.  Baseline's 1.24M
   iops *is* the bypass.
2. Every verified read paid disk-endio → handle_stripe parks stripe → shard
   worker verifies → handle_stripe again → biofill → bio_endio: two md-thread
   hops plus a worker hop (~200 µs) on the latency path.

dm-integrity reads at baseline in every mode because its verify is per-bio,
concurrent, and (in 'I' mode) inline in the end_io.  The old design could not
verify anywhere except the shard worker because CORRECTNESS WAS ORDERING: CRC
stores were queued and had to land before that block's verify (the step-2
inline-verify experiment raced this queue and false-flooded).

## The design shift: state replaces ordering

The in-core cache becomes authoritative the moment a write is issued.  Then a
verify can run anywhere — including interrupt context — because it either sees
the current expected CRC or explicitly sees "can't know yet, defer".

Four pillars (all in km/raid_km.c):

1. **Store-on-hit** (`raidkm_csum_store`, called from ops_run_io): the CRC is
   already computed inline; if the region page is resident, write the 4-byte
   slot right there under the new per-page spinlock `pg->slock` (no fault, no
   sleep).  Only a page miss parks the CRC in the shard's `pending` xarray
   (pkey = member<<40 | blk), which EVERY verify path consults before the page
   slot, until the shard worker faults the page and lands it.

2. **Lock-free inline verify** (`raidkm_csum_peek` + hook in
   `raid5_end_read_request`): expected-CRC lookup is pending-xarray, then RCU
   page lookup + READ_ONCE slot read; crc32c does not sleep, so a resident tag
   verifies in the completion with ZERO extra hops.  Only a non-resident page
   (fetch would block) or an inline mismatch sets R5_CsumPending and queues the
   stripe to the shard worker — directly from the endio (irq-safe qlock), with
   handle_stripe's park kept as the backstop.

3. **Recheck-then-heal**: a fast-path mismatch is never trusted.  The worker
   re-verifies under the shard lock (`raidkm_csum_verify_stripe`, now
   pending-aware via `raidkm_csum_expected`); only a mismatch confirmed there
   feeds the shipped R5_ReadError/R5_IntegrityHeal machinery.  Benign
   read-races-write windows become a retry, not a false heal — this is what
   makes inline verify sound where step 2 was not (dm-integrity's
   integrity_recheck embodies the same rule).

4. **Verified bypass** (`raidkm_csum_verify_abio` / `raidkm_csum_abio_defer` /
   gate in raid5_make_request): chunk_aligned_read is re-enabled under csum for
   whole-4K-aligned reads.  raid5_align_endio verifies the completed bio inline
   on resident tags; a non-resident tag defers the bio to a small work item on
   the csum wq; a mismatch goes through the existing add_bio_to_retry →
   retry_aligned_read stripe-cache path, which re-reads, re-verifies, and heals
   (and drops active_aligned_reads).  Unaligned/partial-block reads keep the
   stripe path.

Shard workers are demoted to cache maintenance — page faults, landing parked
stores, deferred verifies — so the 1022-stripes-per-shard pinning of sequential
streams is gone as a side effect.

Supporting mechanics: region pages are freed via RCU after eviction (lock-free
peek readers); dirty pages flush via a per-shard bounce-page snapshot with
DIRTY cleared under pg->slock BEFORE the copy, and eviction re-checks DIRTY
under pg->slock so a racing direct store is never lost.

## The bug real hardware found (and ramdisks cannot)

First benchmark run: 27 confirmed false mismatches, clustered on adjacent
blocks of single region pages, during the write phases.  Mechanism: the
first-write flood (prewrite) parks millions of stores in `pending` (no pages
resident yet); the worker drains that backlog for tens of seconds against real
region I/O; rewrites of the same blocks meanwhile take the new fast slot path;
the worker then lands the OLD parked value over the NEWER slot → stale CRC →
RMW reads catch it.  The ramdisk thrash gate never sees this because its drain
window is microseconds.

Fix (in `1786f9a`): **supersede-in-place** — a store that finds a pending entry
for its block cmpxchg-updates the ENTRY (cannot fail on an existing key), never
the slot; the worker's cmpxchg-erase fails on superseded values and a later
pass re-lands them.  Plus pending inserts use GFP_NOIO (the old sreq strength):
a dropped store leaves a STALE on-region slot, not an absent one, so NOWAIT was
too weak.  Re-run: 0 mismatches under the same load.

## Cache sizing (operational)

The region working set is per MEMBER (data+parity blocks, not data bytes):
member_blocks/1022 × nr_members.  For 8×8 GiB members that is 16416 pages —
the benchmark's 16384 was *just* under, and the resulting steady eviction churn
cost random write ~15% (79.2K vs 93.1K iops at 20480 pages).  Follow-up
DONE (2026-07-14, after this note): raidkm_csum_cache_pages now defaults to 0
= auto-size from array geometry at csum enable (full region coverage, clamped
to ~1.6% of RAM with a logged hint when clamped).

## Measured (bench-nvme16-csum, 2026-07-14; 8-disk m=2, chunk 64K, 8G/dev,
fio direct iodepth=32 30s; seqread nj=4, randread nj=16, randwrite nj=4;
cache 20480 pages)

| workload        | baseline | NATIVE (this design) | dm-integrity journal | dm-integrity bitmap |
|-----------------|---------:|---------------------:|---------------------:|--------------------:|
| seq write MB/s  |     2245 |       **2264 (101%)**|                 1088 |                2230 |
| rand write iops |    97.2K |       **93.2K (96%)**|                40.8K |               78.5K |
| seq read MB/s   |     5626 |        5599 (99.5%)  |                 5624 |                5014 |
| rand read iops  |  1236.2K |    **1235.9K (100%)**|               978.0K |              934.4K |

(NATIVE column = final post-review-hardening run, sv 6CF433E9.)  0 false csum
mismatches.  Native beats dm-integrity BITMAP on all four workloads and beats
JOURNAL on writes and random read; sequential read is a tie within noise
(5599 vs 5624, both at the device ceiling).  The sharded-only engine's 37%
random read is fully closed.

## Post-ship adversarial review (2026-07-14, commit after 1786f9a)

Three independent review passes (concurrency/lifetime, state-machine, error
paths) found the R5_CsumPending fence leaking on both edges — endio published
R5_UPTODATE before raising the gate (~1 µs window), and the worker lowered the
gate before the verdict (multi-ms window across a region fault) — during which
a concurrently running handle_stripe (direct callers: raid5_sync_request,
retry_aligned_read) could consume an unverified block as read data or a
reconstruction source.  Both pre-dated the redesign (step 1 had the same
ordering) but were fixed together with: R5_InJournal verify exclusion, a
dedicated abio workqueue + bounded store-drain passes (starvation), rdev
nr_pending pinning around region I/O (hot-remove UAF), no fake clean page on a
failed region read, flush bounds check, alloc-failure leak/abort fixes, and
free_conf teardown ordering.  Gates re-passed (12/0, 5/5, 60/0) and the
benchmark was re-run after the fixes (table above).

## Validation

- raidkm-test-functional.sh 12/0
- raidkm-test-csum-thrash.sh 5/5 (re-run after the supersede fix; this gate
  also re-validates eviction round-trips and detect+heal after eviction)
- raidkm-test-selfheal.sh NATIVE=1 60/0 (mismatch path now traverses
  bypass-verify → add_bio_to_retry → stripe recheck → heal)

## Residual / follow-ups

- Last ~4% of sequential read vs baseline/journal: inline bypass verify costs
  ~13 µs per 64K chunk in completion context.  If it matters: defer verify of
  bios above a size threshold to the concurrent wq.
- Auto-size the CRC cache from geometry (above).
- KASAN/lockdep pass over the new RCU/slock paths on the debug kernel.
