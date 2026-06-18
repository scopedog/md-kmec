# Upstream raid5.c drift audit — raidkm (2026-06-15)

raidkm (`km/raid_km.c`) is a fork of `drivers/md/raid5.c`; we port upstream raid5
fixes by hand. This audits what we may have missed.

## Scope / method
- **Audit A — fork vs its base raid5.c** (`mdraid/md/raid5.c`): did raid5.c change
  after the raidkm fork without being ported?
- **Audit B — base vs mainline**: mainline raid5.c fixes since our 6.12 import that
  neither tree has.

## Audit A — CLEAN (no fork-base drift)
- raidkm forked at `4cd7698` (2026-05-23) from `mdraid/md/raid5.c`, whose last change
  was `3287e55` (2026-04-28). **Every** TLC raid5 change predates the fork, and raid5.c
  has not been touched since (the RHEL 10.2 port was in `md.h`/`md.c`, not raid5.c).
- ⇒ raid_km.c is current with its base; nothing landed in raid5.c that raidkm missed.

## Audit B — mainline raid5.c since the 6.12 import (`f2ba122` = pristine upstream 6.12)
40 mainline commits touch `drivers/md/raid5.c` since v6.12 (full list:
`/tmp/raid5_upstream.txt` at audit time; regenerate with
`gh api "repos/torvalds/linux/commits?path=drivers/md/raid5.c&since=2024-11-18T00:00:00Z"`).
Triaged:

### Tier 1 — genuine bug fixes, code path PRESENT in the fork → evaluate + port
| commit | fix | applicability |
|---|---|---|
| `7f9f7c697474` (2026-04) | soft lockup in `retry_aligned_read()` | **applicable** — `retry_aligned_read` present in raid_km.c |
| `52e4324935be` (2026-03) | skip 2-failure compute when other disk is `R5_LOCKED` | **applicable** — degraded-compute path present (R5_LOCKED used) |
| `418b3e64e445` (2026-04) | **UAF** on IO across the reshape position | **needs careful check** — `get_reshape_loc`/`raid5_make_request` present, but raidkm has its OWN COW reshape engine; verify whether the upstream reshape-IO window this fixes exists in the fork. Highest severity (UAF). |

### Tier 2 — fix present-area, lower/uncertain applicability
| commit | fix | applicability |
|---|---|---|
| `a913d1f6a7f6` (2025-11) | IO hang when array broken with IO inflight | uncertain — `MD_BROKEN`/`is_array_broken` not found in fork (6.12 may predate, or different mechanism) |
| `2d9f7150ac19` (2026-01) | `raid5_run()` return error when `log_init()` fails | minor error-path; check raidkm `run()` |
| `cd1635d844d2` (2026-01) | IO hang on degraded array with **llbitmap** | N/A — llbitmap is a newer bitmap type the fork doesn't have |

### Confirmed NOT applicable
- `7ad6ef91d874` (2025-12) NULL-deref in `raid5_store_group_thread_cnt`: raidkm's store
  (and its added `worker_thread_cnt` store) check `conf` right after the lock and never
  call `raid5_quiesce()` before that check — the safe pre-6.12 structure. The upstream
  bug was introduced by a *later* quiesce-addition raidkm doesn't carry. **Clean.**

### Already covered independently — fix #9 validated against mainline
- Upstream `bb74b093c33c` + `5ae58d1500e3` + `bb9317b13ade` (2025-07) make the bitmap_ops
  sync helpers tolerate "bitmap not enabled". Our RHEL 10.2 fix #9 guards the same calls
  (`mddev->bitmap` checked before start/end/close_sync, cond_end_sync, resize, start/endwrite
  — 10 guard sites). **Note:** upstream fixed it *inside* md-bitmap; RHEL 10.2's 6.12 lacks
  that backport, so raidkm's call-site guards are the correct workaround for our target.

### Not worth chasing in a 6.12-pinned fork (refactors / API churn / features)
~30 commits: the bitmap_ops vtable rework (`08c50142a128`, `4f0e7d0e03b7`, `9c89f604476c`,
`cd5fc6533818`), `md_submodule_head` switch, `recovery_cp`→`resync_offset` rename,
mddev_flags merges, block-layer plumbing (logical block size, `bio_submit_split_bioset`,
`max_hw_wzeroes`), treewide `kmalloc_obj`/GFP churn, etc. These are API restructurings for
post-6.12 kernels, not fixes — chasing them in the fork is churn with no correctness payoff.

## Port assessment (patches pulled + mapped onto raid_km.c, 2026-06-15)

### `7f9f7c697474` (soft lockup in retry_aligned_read) — ✅ PORTABLE, clean
raid_km.c:8539 has the exact unfixed pattern (`if (!add_stripe_bio(...)) { raid5_release_stripe(sh); ... }`).
Self-contained (raid5.c-internal; `__release_stripe`/`hash_lock_index`/`temp_inactive_list`
all present). Port = replace `raid5_release_stripe(sh);` with:
```c
int hash;
spin_lock_irq(&conf->device_lock);
hash = sh->hash_lock_index;
__release_stripe(conf, sh, &conf->temp_inactive_list[hash]);
spin_unlock_irq(&conf->device_lock);
```
Low risk; no md-core dependency.

### `52e4324935be` (skip 2-failure compute when other disk R5_LOCKED) — ✅ PORTABLE, clean
raid_km.c:4938 has `BUG_ON(other < 0);` in fetch_block. Port = insert right after it:
```c
if (test_bit(R5_LOCKED, &sh->dev[other].flags))
        return 0;
```
2-line guard (defers compute); self-contained; applies to the m=2 / dual-degraded compute
path with skip_copy. Low risk.

### `418b3e64e445` (UAF on IO across reshape position) — ⛔ NOT PORTABLE on RHEL 10.2 (blocked)
The fix spans md.c + md.h + raid5.c: it **deletes the exported `md_free_cloned_bio()`** and
reworks `md_end_clone_io()` (reads the clone via `container_of`, repurposes `bio->bi_private`
as a reshape `completion`, and `complete()`s instead of `bio_endio()` on the last clone). The
raid5.c half (which raid_km.c:7452 mirrors as `md_free_cloned_bio(bi)`) sets
`bi->bi_private = &done; bio_endio(bi); wait_for_completion(&done)`.
Those md.c/md.h changes live in the **builtin md_mod** (RHEL-controlled); raidkm can't make
them. Porting only the raid5.c half against RHEL 10.2's unmodified md core would (a) feed
`&done` to `md_end_clone_io` which still reads `bi_private` as the `md_io_clone` →
type-confusion crash, and (b) hang (nothing calls `complete`). **Do NOT port the raid5.c half
alone.** Exposure: narrow UAF window during an **add-data** (k→k+1) online reshape (which uses
the inherited stripe-cache reshape, hitting `STRIPE_WAIT_RESHAPE`) with a multi-stripe bio
crossing `reshape_position`. (The add-PARITY m→m+1 path uses raidkm's own COW engine, not this.)
**Action:** track RHEL 10.2 errata for a backport of 418b3e into md_mod; once md core carries
it, add the raid5.c half. Until then it stays a documented limitation.

## Recommendation
Port the **2 self-contained Tier-1 fixes** (`7f9f7c697474`, `52e4324935be`) — both small,
low-risk, no md-core dependency; build-verify on .144 then commit. **`418b3e64e445` is blocked**
on a RHEL md-core backport (don't attempt a partial port). Spot-check the Tier-2 three. Ignore
the refactor/feature bulk. Re-run this audit after any future mainline rebase of the mdraid base.
