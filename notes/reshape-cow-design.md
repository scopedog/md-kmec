# Online reshape for raidkm — COW-staged (journaled, out-of-place, per-band)

Status: **IMPLEMENTED (branch `reshape-cow`) + DM-DRIVEN (2026-06-10).** The
engine ships in `km/raid_km.c` / `km/raid_km-reshape.c` (online add-parity
m→m+1 AND add-data k→k+1, journal/scratch in the constant-`data_offset` gap,
Inc4 assembly recovery), and is drivable through device-mapper (mdraid branch
`raidkm-dm-reshape`, `dm-raid.c`): constant data_offset, two-step activation
(stamp reload, then run), per-band claim/release on the
[reshape_safe, reshape_progress) window so the array stays truly online.
Validated: `tools/raidkm-test-dm-reshape.sh` 34/34 + dm-rebuild 23/23 +
native functional 12/12 / grow-parity 13/13 / reshape-concurrent 3/3 on
.122.19 (base). §10 below was the design bet and it held.

Crash/fault validation: `tools/raidkm-test-reshape-crash.sh` (needs the
`CONFIG_RAIDKM_FAULT_INJECT` build) — **114 passed / 0 failed on both base
(.122.19) and GFNI (.144), 2026-06-11.** All tiers green; see §8.

Companion artifacts:
- Test harness: `tools/raidkm-test-reshape-crash.sh` (targets the inject contract
  in §7; degrades to Tier-0 + best-effort crash without the debug build).
- Why dm reshape is gated today: `notes/dm-raid-design.md` §7 Phase 3 / Phase 4c.

---

## 1. Motivation

Online array expansion is wanted for the future. dm/LVM reshape is **gated off**
(`mdraid` parse gate `9bcfed5`) and 4c proved LVM does **not** fix it: dm-raid's
reshape is out-of-place via `data_offset` repositioning, and md's reshape engine
computes its read/write safe-distance assuming **raid456 placement**. The
*rotating* layout relocates blocks a different distance per stripe, so that math
is wrong and a write clobbers a not-yet-relocated source ("source held block
`bn + shift·k`"). The synchronous-reshape bound failed because it tightened the
*same* fragile math instead of removing it. mdadm's backup-file path works; dm's
data_offset path corrupts.

We deliberately reject COW/ZFS as a *general* architecture (no off-the-shelf EC
COW exists at m≥4; owning a novel engine puts the highest-durability tier on the
least-proven code; and per the OpenZFS RAIDZ-expansion experience COW does not
even make *rebalancing* free). Instead we apply COW **only to the reshape path**.

## 2. Key idea — delete the frontier math

> Never overwrite a live old block until its new-geometry replacement is durably
> staged. Correctness then no longer depends on any frontier calculation or on
> the placement function — it becomes **placement-agnostic**, which is exactly
> what rotating needs.

This is the same principle that made the offline `save→recreate→restore`
migration reliable, done **incrementally and online** instead of all-at-once and
offline. It is also what md's backup-file already does for the *critical
section* only; we do it uniformly for the whole reshape, which removes the
special-casing where the rotating bug lives.

## 3. Placement function (the math the band sizing falls out of)

`raid5_compute_sector()` rotating case (`km/raid_km.c:3710`):

```
N = raid_disks      m = parity_count      k = data_disks = N - m
chunk_number C   (logical array chunk)
stripe row  s = C / k            data index d = C % k
pd_idx(s)     = N - 1 - (s mod N)
qd_idx        = (pd_idx + m - 1) mod N
data slot     = (pd_idx + m + d) mod N
per-disk sector = s * chunk_sectors + chunk_offset
rotation period = N stripe rows   (pd_idx depends on s mod N)
```

## 4. Band sizing (the two reshape kinds)

### 4A. add-parity  m → m+1   (k FIXED) — the easy case

Because k is fixed, `s = C/k` and `d = C%k` are **identical** in old and new
geometry; data does not renumber. Only N, m, and therefore pd_idx/slot/parity
*within* row s change. So **each stripe row is a self-contained migration unit**:

1. read old row s (k data + m_old parity across N_old disks, all at sector s)
2. re-encode → k data + (m_old+1) parity with the new EC matrix
3. stage to temp, journal `row s: staged`
4. write new row s to sector s across N_new disks (overwrites old members at
   sector s, plus the freshly-added disk)
5. advance reshape_position

- **No data renumbering, no `data_offset` shift, no array_size change** (k fixed
  → pure redundancy upgrade).
- band = **1 row** minimum; batch a rotation period `LCM(N_old, N_new)` rows for
  even disk wear (m=3→4, k=4: N=7→8 → 56 rows).
- temp = 1 row → `N_new × chunk` (512 KiB at 64K/k4/m4), or 28 MiB for the 56-row
  batch. Bounded and tiny.
- The same-sector rewrite is safe **only because of the temp**: old row s is
  fully captured before overwrite, and the journal makes step 4 idempotent.

### 4B. add-data  k → k+1   (m FIXED)

Data renumbers (`s = C/k` changes), so a band must align to whole rows in both
geometries → **band = LCM(k_old, k_new) data chunks**. (k 3→4: LCM=12 = 4 old
rows / 3 new rows; temp ≈ 3 rows × N_new × chunk ≈ 1.1 MiB.)

New geometry is **more compact** (k_new>k_old → fewer rows). Migrating **forward**
(increasing C), new row j is written only after old row j is fully vacated —
proof: new-written rows `[0, F/k_new)` ⊆ vacated old rows `[0, F/k_old)` since
k_new>k_old. So **no `data_offset` shift**; temp is purely per-band crash
atomicity. `array_size` grows at finalize (capacity increases here, unlike 4A).

## 5. Control loop, journal, recovery

### What to keep vs replace in raid5.c
- **Keep** `make_request` reshape gating (compare sector to `reshape_progress`,
  pick `previous` vs current geometry via `raid5_compute_sector`, stall within
  the active window) — it is correct for rotating because `compute_sector` is
  correct, and it gives online I/O for free.
- **Replace** the body of `reshape_request` (the stripe-copy frontier logic)
  with the band/temp/journal loop.
- **Reuse** PPL/journal region for scratch+header; `prev_ec_*`/`ec_*` dual
  matrices (extend "previous set" to mean `old_m`); md sync-speed throttle
  (`speed_min/max`) so "slow but steady" is just a knob.

### Scratch (temp) region — self-redundant for free
Stage each band into scratch **in the new geometry**, so the staged copy already
carries its `m_new` parity and survives ≤ m_new disk losses with no extra
mirroring. STAGE and COMMIT are both full new-geometry stripe writes.

### Loop
```
raidkm_reshape_thread(mddev):
  while reshape_position < end_of_data:
      band    = next_band(reshape_position)           # [c_start, c_end)
      quiesce(band)                                    # make_request stalls I/O to this range
      src     = read_old(band)                         # compute_sector(previous=1); decode only if a disk is failed
      newdata = reencode(src, old_m → new_m)           # k data + new_m parity, new EC matrix
      journal(band, STAGE);  write_scratch(newdata);  flush()
      journal(band, COMMIT); write_home(newdata);     flush()   # copy scratch → new-geometry home
      journal(band, DONE)
      reshape_position = c_end
      if (++n % SB_BATCH == 0) md_update_sb()          # persist frontier periodically
      unquiesce(band)
  finalize_geometry()                                  # single atomic commit point
```
`finalize_geometry()`: update SB `raid_disks=N_new, m=new_m, layout,
max_degraded=new_m` (and `array_size` for add-data), clear reshape state.
Idempotent — if crashed with all bands DONE, recovery re-runs it.

### Journal record (double-buffered A/B slots in the scratch zone)
```c
struct raidkm_reshape_journal {
    __le32 magic;             /* 'RKRJ' */
    __le32 version;
    __le64 seq;               /* monotonic; newest valid slot wins */
    __le64 band_start_chunk;
    __le32 band_chunks;
    __le32 phase;             /* IDLE / STAGE / COMMIT / DONE */
    __le32 old_m, new_m;
    __le32 old_raid_disks, new_raid_disks;
    __le32 chunk_sectors, scratch_rows;
    __le64 reshape_position;  /* committed frontier; SB is the backstop */
    __le32 data_csum;         /* checksum of the staged band in scratch */
    __le32 hdr_csum;          /* torn-write guard on this header */
};
```
Two slots, alternated by `seq`; pick highest `seq` with valid `hdr_csum`.
`data_csum` proves the staged band is complete before COMMIT trusts it.

### Recovery on assembly
| Phase read back | Scratch state        | Action                                   |
|-----------------|----------------------|------------------------------------------|
| IDLE / DONE     | —                    | reshape_position authoritative; next band |
| STAGE           | data_csum bad        | discard scratch; **redo band from old**   |
| STAGE           | data_csum good       | proceed to COMMIT                         |
| COMMIT          | data_csum good (guar)| **replay write_home from scratch** → DONE |

Every transition is redo-from-old or replay-from-scratch — never a state where
the only copy is in flight. That is the invariant.

## 6. Two design notes / the risk case

- **Dual EC matrices**: normal-path add-parity never decodes — read the k data
  directly and *encode* new_m parity; the old matrix is touched only if a member
  is already failed. Cheap.
- **Hybrid fault tolerance** (the risk case to test FIRST): below the frontier
  tolerates `m_new`, above tolerates `m_old`; `reshape_position` tells
  reconstruction which matrix to use per row. Per-row independence (4A) keeps
  this clean, but it is where "simple" gets stress-tested. **VALIDATED 2026-06-11
  for region-scoped degraded READS** (Tier 3): a frozen mid-reshape array
  reconstructs the below-frontier region under `m_new` failures (new tables) and
  the above-frontier region under `m_old` (previous tables), base + GFNI. **NOT
  yet supported: COMPLETING a reshape that lost members mid-flight** —
  `raidkm_reshape_migrate_band` is non-degraded-read only ("v1"), so a member
  lost across the parked reshape can neither be migrated past nor rebuilt (the
  parked reshape owns the sync thread). Closing that needs a degraded-read
  migrate path (future work); until then the guarantee is "read through max
  faults mid-reshape", not "finish the reshape through max faults".

## 7. Test contract — `raidkm_reshape_inject` (debug knob)

Built only under **`CONFIG_RAIDKM_FAULT_INJECT`**. Per-array sysfs:

```
/sys/block/<md>/md/raidkm_reshape_inject = "<band>:<phase>:<action>"
  band   : ordinal — 0 = first, -1 = last, "mid" = a middle band, else absolute
  phase  : STAGE | COMMIT | DONE | FINALIZE
  action : hang — durably write this phase's journal, then PARK before next step
           torn — durably write this phase's journal, BEGIN the next step but
                  write only a partial/torn subset of its bios, then PARK
  "off"/empty disarms.  Read-back: "parked@<band>:<phase>" | "armed" | "off".
```

The harness arms a point, starts the reshape, waits for `parked@…`, simulates
power loss via dm-flakey `drop_writes` (pending SB/journal/home writes vanish),
`--stop`, thaw, `--assemble`, lets the kernel recover, then asserts.

## 8. Test tiers (`tools/raidkm-test-reshape-crash.sh`)

- **Tier 0** harness sanity — clean add-parity (m=3→4) + add-data (k=3→4), no crash.
- **Tier 1** clean crash + resume at every phase × {first, mid, last} band, both types.
- **Tier 2** torn writes: STAGE-torn → redo-from-old; COMMIT-torn → replay-from-scratch.
  **COMMIT-torn add-parity m=3→4 (base + GFNI) is the go/no-go gate** — if
  scratch→home replay yields a byte-correct, EC-correct band there, the core
  reliability claim holds; build that one first.
- **Tier 3** hybrid fault tolerance — **two INDEPENDENT region probes, each on a
  fresh array** (`rx_tier3_region below|above`): seed the full device (so the
  mid-array frontier bisects real data), park mid-reshape (hang@COMMIT mid band),
  fail this region's parity count of members (below `new_m` via new tables, above
  `old_m` via previous tables), read an 8 MiB slice hugging the frontier, tear
  down. add-parity only (constant array_size → clean frontier). **No restore / no
  resume-to-completion**: a member lost mid-frozen-reshape can't be restored
  online (re-add can't rebuild while the parked reshape holds the sync thread; no
  degraded migrate_band), so a single-array below-then-above sequence would
  cross-contaminate, and reshape completion under fault needs the unimplemented
  degraded migrate path. Completion under *no* fault is covered by Tiers 0–2.
  (Earlier single-array design with `--fail`/restore/resume was withdrawn for
  exactly these reasons, 2026-06-11.)
- **Tier 4** fault + crash combined — torn COMMIT + a member failure (the
  formerly-open double-fault hole; closed by `raidkm_reshape_reconstruct_band`,
  bd458f3 — replay reconstructs the in-flight band from its own-side geometry).

**EC oracle** (the real assertion — scrub=0 ≠ EC-correct): strong single pattern
(drop `new_m` members, reconstruct — proves the NEW parity is genuine), or
`RX_FULL_ORACLE=1` for the exhaustive `C(N, new_m)` sweep via assemble-minus-combo.
Run **base + GFNI** on .144 (m=3→4 crosses Vandermonde→Cauchy).

Without the inject build the script auto-skips Tiers 1–4 and runs Tier 0 + a
best-effort `reshape_position`-timed crash, so it is runnable today against the
existing online add-data path.

## 9. Touch-ups / known gaps
- **Degraded `migrate_band` (the real remaining gap).**
  `raidkm_reshape_migrate_band` reads the old-home row non-degraded only; if a
  member is genuinely gone across a parked/resumed reshape it cannot migrate that
  band, and the lost member cannot rebuild while the reshape owns the sync thread.
  Consequence: raidkm can *read* through up to `m_new` faults mid-reshape but
  cannot *finish* the reshape through them. Closing it (decode the missing
  old-home slots via `prev_ec_*` before re-encoding) would let a reshape complete
  through max faults and is the prerequisite for any resume-after-fault test.
- Tier 3 frontier math: `reshape_position` is array sectors (`fb = pos*512`) and
  at a COMMIT park it lags to the last DONE band (= `reshape_safe`); the probes
  read an 8 MiB slice strictly below it (migrated) / above `fb+margin` (pending).
  NOTE the reshape parks at ~half the *array*, so Tier 3 must seed the *whole*
  device, not the small default `RX_SZ` (else the slice lands in zero-fill — the
  bug that produced the spurious 2026-06-11 "below-frontier WRONG" verdict).
- Band selector `0/mid/-1` assumes the kernel resolves `mid` (= `last_band/2`);
  switch to absolute ordinals if preferred (the test already computes geometry).

## 10. Why this is also the cleanest dm answer
It is **not** dm-raid's `data_offset` reshape, so it never touches the code 4c
gates. dm/LVM's role shrinks to: issue the reshape request, poll status. The
kernel raidkm personality does its own COW-staged migration internally — which is
why "reshape through device mapping" becomes viable.
