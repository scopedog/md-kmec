# md-kmec

> **Build note:** This is one component of the raidkm mdraid stack and is not
> meant to be built on its own. Please use
> [mdraid-super](https://github.com/scopedog/mdraid-super) to build
> the entire package — it assembles this repo together with the other
> components in the correct order.

A Linux md personality implementing arbitrary *k+m* Reed-Solomon
erasure coding, built as a fork of [our optimized
mdraid](https://github.com/scopedog/mdraid)'s `raid5.c`
plus [our ISA-L fork](https://github.com/scopedog/isa-l)'s
EC primitives (GFNI when the CPU has it, table-lookup
GF_REGION_MUL fallback otherwise).

Registered as a personality at **level 71** under the name
`raidkm`.  All m use the ISA-L `gf_gen_rs_matrix` Reed-Solomon
code: m≥3 calls ISA-L's `ec_encode_data_*` directly, while m=2 is
computed with raid6's tuned SIMD (`raid6_call`) — which produces
byte-identical parity to the ISA-L m=2 encode (see "Architectural
commitments" below).  Parity placement is selectable per array via
`--layout`: **rotating** (the default — generalized left-symmetric,
spreads parity and read traffic across all members, matching stock
RAID6's own default placement) or **parity-last** (dedicated parity
on the tail m disks, which keeps the cheap offline add-a-parity grow).
The parity-disk count **m** is set separately with `--parity-count`.

The earlier standalone implementation lives on the `proto`
branch and the `v0-proto` tag.  Benchmarks of that prototype
against the raid5.c-derived line motivated switching to the
fork-and-extend approach this branch takes.

## Architectural commitments

These are load-bearing for the design and not up for negotiation:

1. **k+m semantics from the start**, including m=2, with an
   on-disk format that stays reshape-compatible to arbitrary m.
   Parity is the ISA-L `gf_gen_rs_matrix` Reed-Solomon code in
   PARITY_N layout for every m.  At m=2 that code's first two
   rows are exactly P=XOR and Q=Σ2ⁱ·Dᵢ over GF(2⁸)/0x11d —
   identical to raid6's P+Q — so we compute m=2 with raid6's
   tuned SIMD (`raid6_call`) for speed while writing byte-identical
   parity, keeping the m=2 image a valid prefix of the m≥3 ISA-L
   encoding (so "add a parity" stays incremental).  raid6's
   hardcoded math alone is a dead end for m>2, which is why m≥3
   uses ISA-L directly.  Verified byte-for-byte: see the EC-verifier
   milestone below.

   **Encode and decode are asymmetric.**  The m=2 *encode* above runs raid6's
   XOR + shift P+Q (`raid6_call.gen_syndrome` — AVX `VPXOR` for P, the shift/
   mask GF(×2) for Q).  *Decode* (degraded read, rebuild, degraded-write
   reconstruct) instead routes through **one unified path for every m**
   (`ops_run_compute_km`): build the survivors' decode matrix, invert it with
   `gf_invert_matrix`, and apply it with ISA-L's `ec_encode_data_*` — GFNI
   (`ec_encode_data_avx512_gfni` / `avx2_gfni`) when the CPU has it, else the
   scalar `ec_encode_data_base` table lookup.  Decode is deliberately
   **PSHUFB-free**: it never uses raid6's `*_recov` (the inherited 2-failure
   path raidkm doesn't reach) nor ISA-L's PSHUFB kernels, avoiding the
   StreamScale patent surface.  The two SIMD selections are independent: GFNI
   decode comes straight from `isal_lib` (gated on `isal_have_*gfni()`), so it
   needs **no** `raid_isal.ko` — that optional override only swaps the m=2
   *encode* `raid6_call` to a GFNI P+Q and does not touch decode.

2. **Forked from raid5.c**, not patched in place.  `raid_km.c` is
   a copy + modify of `raid5.c`.  Stock raid4/5/6 stay untouched
   in the kernel; we accept the maintenance cost of porting
   upstream raid5 fixes manually.

3. **m=2 AND m=3 validated** before declaring any milestone done.
   m=2 because it's the most-tested case and lets us cross-check
   against stock raid6 behavior; m=3 because it's the first case
   that stock raid6 can't do at all.

## Status

| Milestone | State |
|---|---|
| Prototype preserved at `v0-proto` tag / `proto` branch | ✅ done (2026-05-23) |
| Master cleared, scaffolding committed | ✅ done (2026-05-23) |
| Fork `raid5.c` → `km/raid_km.c`, symbols renamed, builds clean | ✅ done (2026-05-23) |
| Loads as a personality at level 71, coexists with stock raid456 | ✅ done (2026-05-23) |
| m=2 array activates natively at level 71, no shim | ✅ done (2026-05-23) |
| Basic I/O works (writes + reads) | ✅ done (2026-05-23) — 1.9 GB/s write, 7.9 GB/s read on brd |
| Resync / scrub path works | ✅ done (2026-05-23) — completes cleanly in ~2.4 s for 2 GiB |
| Standard benchmark passes vs stock raid6 | ✅ done (2026-05-23, re-measured 2026-05-29) — 1.34-2.35× at default, up to 1.43-2.28× tuned; **re-measured on RHEL 10.2 across base / AVX2-GFNI / AVX-512-GFNI (2026-06-15): raidkm wins every workload — 1.35-2.43× scalar, up to 4.20× on AVX-512-GFNI** (see table below) |
| Reliability soak: long fio randwrite+verify, disk-fail mid-I/O, scrub/repair | ✅ done (2026-05-25) — ~230 GiB crc32c-verified across healthy/2-fail/3-fail; a member failed mid-fio survives with correct data; scrub mismatch_cnt=0; surfaced + fixed an nsrc<k WARN on mid-I/O failure |
| Reliability: hot-replace / rebuild onto a spare | ✅ done (2026-05-25) — fail a member, `mdadm --add` a spare, recovery reconstructs (data via decode, parity via re-encode) and writes the rebuilt member; validated for data-disk, parity-disk, and rebuild-while-still-degraded — spare holds correct bytes, scrub mismatch_cnt=0 |
| Write-intent bitmap (unclean-shutdown resync only the dirty bits) | ✅ done (2026-05-25) — internal bitmap created/assembled on level 71; writes set dirty bits and `endwrite` clears them after settle; a write-while-degraded marks only the affected region dirty (3/128 chunks for an 8M write); `--re-add` does a bitmap-scoped recovery (17s vs 171s full rebuild, throttled) with correct data; a fresh-spare `--add` still does a full rebuild (not wrongly scoped). Inherited from raid5.c — no kernel changes needed |
| PPL (partial parity log) — closes the raid5/6 write hole | ✅ done (2026-05-25) — **opt-in, off by default** (enable with `mdadm --create … --consistency-policy=ppl`). Extended raid5-only PPL to arbitrary m: logs **all m** partial parities (raid5 logs only the single XOR P). RMW copies the m parity pages (prexor already leaves them = partial parity); RCW encodes the not-overwritten data (raid6 at m=2, ISA-L at m>2); recovery rebuilds every parity as `P_j = PP_j XOR encode_j(modified)`. Validated: 2 power-loss crash tests (virsh destroy mid-fio) replay the log on reassembly, `mismatch_count=0`, post-recovery scrub clean. **Cost (opt-in): −43% to −72% on brd** — the inherent serialized FUA log write, exaggerated by RAM-speed backing; arrays without `--consistency-policy=ppl` are unaffected. Mutually exclusive with the write-intent bitmap |
| k+m via ISA-L (replace `raid6_call` for m ≥ 3) | ✅ done (2026-05-24) |
| Full-stripe write works for m=3 | ✅ done (2026-05-24) |
| Small RMW writes for m=3 | ✅ done (2026-05-24) — `ec_encode_data_update_*` RMW |
| m=2 byte-identical to ISA-L via `raid6_call` fast path (reshape-compatible, full perf) | ✅ done (2026-05-24) |
| EC correctness verified (encode == ISA-L + every erasure reconstructs) | ✅ done (2026-05-24) — verifier 18/18 at m=2 (k=2..10, full + RMW), m=3 spot-checks |
| m-way scrub / resync / repair for m ≥ 3 | ✅ done (2026-05-24) — synchronous ISA-L re-encode + compare; detect→repair verified on GFNI + base |
| Degraded reads / recovery for m ≥ 2 (m-way decode via `gf_invert_matrix`) | ✅ done (2026-05-24) — survives up to m failures on read; verified 1/2/3-fail on GFNI + base |
| `mdadm --create` / `--assemble` for level 71 (persistent v1.2 superblock) | ✅ done (2026-05-25) — patched mdadm 4.4; data round-trips stop→assemble for m=2/3/4; degraded assemble works |
| `mdadm --grow --add-parity` (alias: `--add`) to add a parity disk, m → m+1 (PARITY_N: offline grow-via-resync; rotating: online COW reshape) | ✅ done — **PARITY_N** (2026-05-25): offline recreate, data + UUID preserved across m=2→3 and m=3→4; no data movement (parity appended, existing data stays put). **Rotating** — now an **online, journaled COW reshape** (2026-06-09; merged to master 2026-06-11): in-kernel, in-place (constant `data_offset`, no stripe-cache), EC-correct, **no backup file**, and crash-safe — a power loss mid-reshape is recovered by a plain `mdadm --assemble` replaying the in-kernel journal. Each band is staged out-of-place before its home is overwritten, so the read/write location-aliasing race that sank the earlier in-place attempt (withdrawn 2026-06-01) is structurally gone. The pre-COW **offline windowed relocation** is retained as a fallback for kernels without the COW engine (`MDADM_RAIDKM_OFFLINE_ADDPARITY`). Validated whole-array m=2→3 (base) + m=3→4 Cauchy (GFNI) — data + scrub + new-m-degraded-read oracle — plus a true power-loss crash; reshape crash/fault suite **114/0 on base+GFNI**. See the `--add-parity` section below |
| `mdadm --grow --add-data` to add a data disk (online reshape, capacity grow at fixed m) | ✅ done (2026-05-26) — drives the inherited kernel online reshape (`delta_disks`, fixed `max_degraded`); relocation rides the layout-aware sector map, no backup file needed (a grow has `writepos < readpos`). The data-disk count k changes, so the ISA-L EC matrix/tables are **rebuilt for the new k** in `raid5_start_reshape`; the old-k set is kept as `prev_ec_*` and selected per stripe by k (`raidkm_a_matrix`/`raidkm_g_*`) for the duration of the reshape, since I/O to pre- vs post-`reshape_position` stripes uses both geometries (freed at `finish_reshape`; rebuilt at mid-reshape assembly). **Both layouts.** mdadm freezes the array before the spare-add (else the `raid_disks` write races `md_check_recovery` → `EBUSY`). Validated by **degraded-read-after-grow** (not just scrub, which masks a stale-table bug): PARITY_N+rotating × m=2/3/4 max-degraded, plus m=3 grown to k=6 — all reconstruct correctly; GFNI-checked |
| Rotating parity layout (balance disk usage; parity-last is dedicated-parity) | ✅ done (2026-05-26) — selected via **`--layout=rotating`** (generalized left-symmetric: the m-slot parity block rotates one disk per stripe so parity — and normal-read traffic — spread across all members instead of the tail m). One slot mapping serves both layouts (`pd_idx` is the only layout-specific value; parity-last is the `pd_idx==k` case), so encode/decode/scrub/PPL are layout-agnostic. Layout packed into the superblock `layout` field (low byte = m, bit 0x100 = rotating). Rotating later became the create default (2026-06-01); the parity-last placement is bit-for-bit unchanged. Validated: m=2/3/4 create/read/scrub=0, degraded read+write (2- and 3-disk loss), stop→assemble persistence, PPL+rotating partial-write scrub=0, rotation confirmed by raw-disk compare. Add-parity is supported on **both** layouts but at different cost: PARITY_N appends a parity disk cheaply (offline grow-via-resync, no data movement), while rotating must relocate every block, so its add-parity drives a full **online COW reshape** (journaled, out-of-place per band, no backup file; an earlier in-place online reshape was withdrawn for a location-aliasing race) — see the `--add-parity` row above |
| Degraded *write* + degraded-array scrub (any m ≥ 2, up to m failures) | ✅ done (2026-05-25) — reconstruct failed data from k survivors, re-encode all parity, write the surviving members; data correct + no deadlock across m=2/3/4/5 × 1–m failures (data-only / parity-only / mixed / max-degraded) |
| GFNI cross-validation of degraded write + recovery | ✅ done (2026-05-25) — degraded-write matrix + hot-replace rebuilds repeated on an i5-1340P (GFNI): 10/10 pass, exercising the `ec_encode_data_avx2_gfni` path. The KVM testbed has no GFNI, so this is the only coverage of the GFNI EC variants under the new write/recovery scheduling |
| **Device-mapper: drive raidkm via the kernel `dm-raid` target** (`dmsetup`) | ✅ done (2026-06-05) — level 71 is reachable through the in-tree `dm-raid` target with **no new dm target** (`dmsetup create … raid raidkm <chunk> parity_count <m> …`); m + rotating ride in the dm table, a `FEATURE_FLAG_RAIDKM` superblock bit keeps stock dm-raid from touching a raidkm SB. Phase 1 (create + I/O + degraded + scrub + reassembly) and Phase 2 (rebuild via reload + `rebuild <idx>`) validated 21/21 base + 51/51 GFNI, m=2..6. Reshape via dm is **gated off** (a hand-driven dmsetup grow corrupts — needs LVM's data-offset positioning). The `dm-raid.c` changes live in the [mdraid](https://github.com/scopedog/mdraid) fork. See `notes/dm-raid-design.md` |
| **LVM-managed raidkm** (`lvcreate --type raidkm`) | ✅ done (2026-06-05) — the lvm2 raidkm fork provisions level-71 LVs via two segtypes `raidkm` (rotating) / `raidkm_n` (parity-last) carrying `parity_count` (m). Validated base + GFNI, m=2/3/4: create/activate/I/O/reassembly/degraded; `lvconvert --repair` (raidkm-aware leg replacement + rebuild); and **dmeventd** monitoring + auto-repair (level-agnostic plugin, no code change). Reshape via dm/LVM is out of scope (the data-offset out-of-place reshape doesn't fit raidkm — mdadm-only); the kernel reshape gate stays on. See `notes/dm-raid-design.md` |

### How level 71 is integrated into raid5.c

raid_km registers at level 71 but reuses raid5.c's existing m=2
code paths via a per-conf `effective_level` field set to 6 in
`setup_conf`.  Internal "do raid6 math" checks (`switch
(conf->level)` cases, `conf->level == 6` branches) consult
`conf->effective_level` instead, so the verbatim raid5.c logic
fires for raid_km without mutating `mddev->level` (which md core
treats as invariant after `md_run`).  Two further fixes were
needed to make it land:

- **`effective_level` set order**: must be assigned *before*
  `raid5_alloc_percpu`, because the CPUHP callback path
  (`raid5_alloc_percpu → cpuhp_state_add_instance →
  raid456_cpu_up_prepare → alloc_scratch_buffer`) reads it to
  decide whether to allocate the per-CPU `spare_page` used for
  P+Q syndrome validation.  If set later, `spare_page` stays
  NULL and `async_pq.c` hits BUG_ON during resync.
- **CPU-hotplug slot**: `raid5_alloc_percpu` and
  `free_scratch_buffer` originally referenced the fixed
  `CPUHP_MD_RAID5_PREPARE` enum, which stock raid456 already
  reserves.  raid_km asks for a dynamic slot via
  `CPUHP_BP_PREPARE_DYN` (stored in `raid_km_cpuhp_state`) and
  both call sites use that instead.

### Benchmark — raidkm vs stock raid6

**Out of the box** — stock raid6 at its default `group_thread_cnt=0` vs md-kmec
raidkm at *its* defaults — `tools/raidkm-standard-benchmark.sh --runs=3`, 16 × brd
ramdisks, k=14 m=2, 64 KiB chunk, both `--assume-clean`, on a GCP
`c3-standard-22` (22 vCPU, **RHEL 10.2** `6.12.0-211.16.1.el10_2`).  raidkm
auto-defaults `group_thread_cnt` to `nproc/2` (= 11 here) and now enables
zero-copy writes (`skip_copy`) by default; stock ships both off
(IOPS, mean of 3 runs; Test 6 = post-run integrity check, `mismatch_cnt=0`):

| Test | stock raid6 (`gtc=0`) | md-kmec raidkm (default) | speedup |
|---|---|---|---|
| 1 Random 4K Write (RMW worst case) | 54,266  | 375,269   | **6.92×** |
| 2 Database Mixed 75/25 8K          | 106,072 | 868,263   | **8.19×** |
| 3 High Concurrency 70/30 4K (16 j) | 177,730 | 1,210,715 | **6.81×** |
| 4 OLTP 70/30 16K                   | 52,574  | 396,083   | **7.53×** |
| 5 Partial Stripe Write 8K          | 31,256  | 230,669   | **7.38×** |

The out-of-box gap (**~7-8×** on this wide array) is dominated by md-kmec's
worker-group auto-default — stock raid6's RMW path is serialized at `gtc=0`,
while raidkm parallelizes stripe handling across `nproc/2` worker threads.  This
is a *default-vs-default* comparison; at **matched** `gtc` the structural-only
edge is much smaller (the win is the on-by-default tuning, see the SIMD table and
the vCPU-scaling note below).

#### Zero-copy full-stripe writes (`skip_copy`, default on)

md-kmec defaults `skip_copy` on (in `raid5_set_limits`): for a full-page-aligned
write the stripe-cache page is aliased directly to the incoming bio page instead
of being `memcpy`'d in through the biodrain step — and that copy, *not* the
erasure-coding (EC is ~0.6 % of write-path CPU), is the dominant cost of a
full-stripe write.  The only requirement is stable pages, which is free for the
O_DIRECT workloads this fork targets; override per-array via the
`skip_copy` sysfs attribute.

Full-stripe sequential DIO write (16-disk wide array above, `bs=896k` = one full
stripe, 3 reps):

| `skip_copy` | throughput |
|---|---|
| **1 (md-kmec default)** | **13.33 GiB/s** |
| 0 | 9.56 GiB/s |

— **+39 %**, matching the +36 % measured on stock raid6 with `skip_copy` forced
on.  The win is confined to **full-stripe** writes; on small/partial RMW writes
the tiny copy is dwarfed by read-modify-write amplification, so `skip_copy` is
neutral there — 8 KiB partial-stripe random write, 4 reps each:

| `skip_copy` | IOPS per rep |
|---|---|
| 1 | 210k / 214k / 214k / 215k |
| 0 | 210k / 210k / 212k / 209k |

(no regression — within noise, marginally ahead).  Note the standard-benchmark
suite above is entirely small random / RMW writes, so it does **not** exercise
the regime `skip_copy` helps; the full-stripe win shows on the large-sequential-write
path.

#### Across the SIMD spectrum (6-disk, three boxes)

raidkm m=2 vs stock raid6 with the canonical
`tools/raidkm-standard-benchmark.sh --runs=3` (6-workload OLTP/IOPS suite; drops
page cache + dentries before every test; both arrays created `--assume-clean` so
neither resyncs during the run), 6 brd ramdisks, k=4 m=2, 512 KiB chunk, on
**RHEL 10.2** (kernel `6.12.0-211.22.1.el10_2`).  Re-measured 2026-06-15 across
the full SIMD spectrum to separate the structural win from the ISA-L GFNI encode
(IOPS, mean of 3 runs; Test 6 = post-run integrity check, `mismatch_cnt=0`
everywhere):

| Test | base / no-GFNI<br>(AMD Ryzen 5800X) | AVX2-GFNI<br>(Intel i5-1340P) | AVX-512-GFNI<br>(Xeon 8481C / GCP **c3-standard-8, 8 vCPU**) |
|---|---|---|---|
| 1 Random 4K Write         | 239,211 vs 124,327 (**1.92×**) | 107,728 vs 46,615 (**2.31×**) | 305,853 vs 72,767 (**4.20×**) |
| 2 DB Mixed 8K (75/25)     | 420,982 vs 275,658 (**1.53×**) | 182,964 vs 96,838 (**1.89×**) | 504,563 vs 157,899 (**3.20×**) |
| 3 High Concurrency 4K rw  | 555,725 vs 410,337 (**1.35×**) | 219,223 vs 135,716 (**1.62×**) | 818,197 vs 220,291 (**3.71×**) |
| 4 OLTP 16K rw             | 222,370 vs 124,760 (**1.78×**) | 88,546 vs 42,677 (**2.07×**) | 266,346 vs 73,455 (**3.63×**) |
| 5 Partial Stripe Write 8K | 179,735 vs 73,994 (**2.43×**) | 59,135 vs 24,053 (**2.46×**) | 159,960 vs 43,837 (**3.65×**) |

(Each cell is *raidkm vs stock raid6* IOPS and the speedup.)  **raidkm wins every
workload at every tier**, at ~2-4× lower latency.  The win is **structural**: the
forked raid5.c carries our post-fork mdraid optimizations — worker-groups
auto-default, `STRIPE_ON_INACTIVE_LIST` lock-skip, and a faster write/RMW/
partial-stripe path.

> ⚠️ **The ratio scales with vCPU/core count — it is *not* a fixed per-machine
> constant.**  raidkm's worker groups parallelize stripe handling across cores
> (total worker threads auto-default to `nproc/2`; see [Tuning](#tuning) to change
> it), so raidkm throughput rises with cores, while stock raid6's RMW path is
> largely serialized and barely scales.  Measured on the **same `main` build, same
> GCP c3 / Xeon 8481C**, varying only the vCPU count (Random-4K-Write, 2026-06-19):
>
> | instance | raidkm IOPS | stock raid6 IOPS | ratio |
> |---|---|---|---|
> | c3-standard-4 (4 vCPU) | 178,934 | 72,041 | **2.48×** |
> | c3-standard-8 (8 vCPU) | 324,958 | 83,852 | **3.88×** |
>
> So the three columns above differ as much by **core count** as by SIMD tier (the
> `Xeon 8481C` column was a **c3-standard-8 / 8 vCPU** box).  **At m=2 parity is the
> `raid6_call` P+Q fast path, *not* the ISA-L GFNI encoder — GFNI does not change
> the m=2 numbers** (verified 2026-06-19: loading the GFNI `raid6_call` override
> moved m=2 IOPS <1%; the 8-vCPU column reproduces with GFNI *off*).  GFNI's encode
> advantage shows at **m ≥ 3**.  **raidkm keeps scaling with cores; stock raid6
> does not.**
>
> **Absolute IOPS are not comparable across the three machines** (different CPUs,
> core counts, RAM/ramdisk sizes).  Reproduce the stock raid6 column by `xzcat`ing
> `/lib/modules/$(uname -r)/kernel/drivers/md/raid456.ko.xz` into a writable file
> and `insmod`ing it instead of `raid_km.ko`.

#### Rebuild / resync speed

raidkm also rebuilds a failed disk **substantially faster** than stock raid6,
because its resync path **fans multiple stripes per `sync_request`** instead of
walking them one stripe-window at a time.  Single-disk recovery, 6 × brd, k=4
m=2, 3 GiB/disk, on a GCP `c3-standard-8` (8 vCPU, Xeon 8481C), with the global
resync governor (`/proc/sys/dev/raid/speed_limit_max`) raised so neither side is
throttled:

| `group_thread_cnt` | stock raid6 | raidkm m=2 |
|---|---|---|
| 0 (stock default) | ~200 MB/s | **1178 MB/s** (5.9×) |
| 4 (matched) | ~585 MB/s | **1178 MB/s** (2.0×) |

Two things to read here.  **raidkm's rebuild rate is independent of
`group_thread_cnt`** (1178 MB/s at both 0 and 4) — the parallelism is in the
sync path itself, not the worker pool; stock raid6's recovery is serialized at
the default `gtc=0` and only speeds up once worker groups are enabled.  So the
honest gap is **~2× apples-to-apples** (matched `gtc=4`) and **~6× out of the
box** (stock ships worker groups off, raidkm's parallel sync is always on).
Rebuild is a streaming, fully-parallelizable scan, so the gap is wider than the
random-I/O table above.  *(brd is RAM-backed and compute-bound; on real disks
the rebuild is capped by disk write bandwidth, so the gap narrows — the full win
shows on fast NVMe or when the rebuild is CPU/EC-bound.)*

#### Worker-thread tuning detail (single box, RHEL 10.1)

Earlier single-box measurement on the AMD Ryzen 5800X VM (`md-kmec-rhel10`,
kernel `6.12.0-124.8.1.el10_1`, `--runs=3 --runtime=20`) isolating the
`worker_thread_cnt` knob: the auto-default `wtc=2` (4-core single-NUMA box) vs
the hand-tuned `wtc=4` (see the [Tuning](#tuning) section).  Stock raid6 measured
against the same VM/ramdisks/kernel.

<table>
  <thead>
    <tr>
      <th rowspan="2">Test</th>
      <th colspan="2" align="center">raidkm</th>
      <th rowspan="2" align="right">Stock raid6</th>
    </tr>
    <tr>
      <th align="right">wtc=2 default (vs Stock)</th>
      <th align="right">wtc=4 (vs Stock)</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td>1 Random 4K Write</td>
      <td align="right"><strong>259,156</strong> ± 5.2% (<strong>2.00×</strong>)</td>
      <td align="right"><strong>274,650</strong> ± 0.9% (<strong>2.12×</strong>)</td>
      <td align="right">129,367 ± 4.3%</td>
    </tr>
    <tr>
      <td>2 DB Mixed 8K (75/25)</td>
      <td align="right"><strong>427,510</strong> ± 0.6% (<strong>1.50×</strong>)</td>
      <td align="right"><strong>467,748</strong> ± 0.5% (<strong>1.64×</strong>)</td>
      <td align="right">285,811 ± 2.3%</td>
    </tr>
    <tr>
      <td>3 High Concurrency 4K rw</td>
      <td align="right"><strong>568,588</strong> ± 1.0% (<strong>1.34×</strong>)</td>
      <td align="right"><strong>606,627</strong> ± 0.8% (<strong>1.43×</strong>)</td>
      <td align="right">423,035 ± 1.4%</td>
    </tr>
    <tr>
      <td>4 OLTP 16K rw</td>
      <td align="right"><strong>239,478</strong> ± 2.5% (<strong>1.85×</strong>)</td>
      <td align="right"><strong>242,968</strong> ± 0.7% (<strong>1.88×</strong>)</td>
      <td align="right">129,588 ± 0.9%</td>
    </tr>
    <tr>
      <td>5 Partial Stripe Write 8K</td>
      <td align="right"><strong>180,554</strong> ± 1.1% (<strong>2.35×</strong>)</td>
      <td align="right"><strong>175,580</strong> ± 1.0% (<strong>2.28×</strong>)</td>
      <td align="right">76,990 ± 0.4%</td>
    </tr>
  </tbody>
</table>

raidkm is **1.34-2.35× faster than stock raid6** at m=2 on every workload at the
auto-default, and **1.43-2.28×** with `worker_thread_cnt` raised to 4 (which
lifts the *floor* on concurrent/mixed-write tests but slightly trades off Test 5).
The win comes
because the raid5.c we forked carries our post-fork mdraid optimizations
(worker-groups auto-default, `STRIPE_ON_INACTIVE_LIST` lock-skip, etc.).  The m=2
parity here is computed by the `raid6_call` SIMD fast path; after briefly unifying
m=2 onto ISA-L (which regressed 30-50% on no-GFNI hardware) the fast path was
restored.  Reproduce stock raid6 numbers by `xzcat`ing
`/lib/modules/$(uname -r)/kernel/drivers/md/raid456.ko.xz` into a writable file
and `insmod`ing it instead of raid_km.

### Cost of `--grow --add-data` (online capacity grow)

Same VM/ramdisks, m=2, 64 KiB chunk.  A grow has **two** costs: a one-time
restripe, and (the important question) any *lasting* penalty afterwards.

**One-time reshape.** Adding a data disk relocates every block, so the cost is
a full online read+rewrite of the array — inherently O(data).  Growing a
filled k=4→5 array (≈2.0 GiB of data) took **2.5 s ≈ 825 MiB/s** on brd.  That
is a RAM-speed *upper bound*: on real disks the reshape is bounded by disk
bandwidth and throttled by `sync_speed_{min,max}`, exactly like any md
reshape.  The array stays readable/writable throughout, and no backup file is
needed (a grow has `writepos < readpos`).

**No lasting cost.**  A grown array performs the same as one *created* at the
final geometry — the reshape leaves no scar.  Steady-state IOPS for k=5 m=2
(N=7), natively created vs grown from k=4 (`--runs=2 --runtime=15`):

| Test                      | native k=5 | grown k=4→5 | grown / native |
|---------------------------|-----------:|------------:|---------------:|
| 1 Random 4K Write         |    212,077 |     229,838 | 1.08\*         |
| 2 DB Mixed 8K (75/25)     |    377,679 |     379,835 | 1.01           |
| 3 High Concurrency 4K rw  |    535,525 |     542,583 | 1.01           |
| 4 OLTP 16K rw             |    196,346 |     191,542 | 0.98           |
| 5 Partial Stripe Write 8K |    138,016 |     143,182 | 1.04           |

The two are statistically indistinguishable (\*Test 1's native run had cv≈8%,
so 1.08 is run-to-run noise; the rest are within ±4%).  So the only cost of
`--add-data` is the one-time reshape; steady-state is identical to native.

### Tuning

raidkm already auto-enables raid5 **worker groups**: total worker threads default
to `max(num_online_cpus()/2, 2)`, distributed across `num_possible_nodes()` groups
(the kernel creates one worker group per NUMA node).  The single `raid5d` kthread
would otherwise cap stripe handling at ~one core; worker groups are on out of the
box — the benchmark above was measured with them — so there is no large "free"
win sitting unused.  The one knob worth revisiting per host:

- **`worker_thread_cnt`** (`/sys/block/mdX/md/worker_thread_cnt`) — total worker
  threads for the array.  **Recommended user-facing knob** because it expresses
  intent in the natural "I want N parallel workers" mental model.  The auto-default
  is `nproc/2` (with a floor of 2 to preserve the win on small hosts) — conservative
  because workers are CPU-bound and share the box with `raid5d`, your application,
  and IRQ handling.  Raising further toward `nproc` may help *concurrent/mixed
  writes*: the benchmark table above includes both the auto-default (2 on a 4-core
  single-NUMA box) and `worker_thread_cnt=4`, showing **+6 / +9 / +7 %** on the
  concurrent/mixed-write tests (1, 2, 3), noise on Test 4, and a small regression
  on Test 5.  On dual-socket 2×16 the default lands at 16 total workers (8 per
  group × 2 groups); raising to 32 puts it at one worker per core.  To override:
  `echo 4 | sudo tee /sys/block/md70/md/worker_thread_cnt`.

  *Rounding:* the written value is divided across `num_possible_nodes()` groups
  with ceiling division, so the **actual** worker thread count may be higher than
  what you wrote when the total isn't evenly divisible by the node count.  E.g.,
  writing 5 on a 2-NUMA box yields 3 per group × 2 groups = 6 workers; the
  read-back reflects the realized total (6), not what you wrote (5).  This never
  happens on single-NUMA hosts.  The choice to round up rather than down ensures
  you never silently get less parallelism than requested.
- **`group_thread_cnt`** (`/sys/block/mdX/md/group_thread_cnt`, or the
  `default_group_thread_cnt` module param at load).  Stock-mdraid-compatible
  view: **threads per worker group** (total = `group_thread_cnt × num_groups`).
  Same underlying state as `worker_thread_cnt`; either knob updates the other.
  Useful when migrating tuning scripts from stock RAID5/6 or when you want explicit
  per-group control on multi-NUMA hosts.
- **`stripe_cache_size`** — leave at the default **256**.  Raising it *reduced*
  throughput on ramdisk (no device latency to hide, just more cache churn):
  256 → 8192 lost ~15-25% on both boxes.  It may help on real spinning disks, so
  measure before changing rather than bumping it blindly.

(Measured on brd ramdisks, which are CPU/memcpy-bound; on real disks the worker-
group win should be larger — threads overlap device latency — and the stripe-cache
result may invert.)

### Testing

`tools/raidkm-test.sh` runs the regression suite — functional
(create/write/read/scrub), max-degraded reconstruction, grow (`--add-data`
online reshape incl. degraded-read-after-grow, `--add-parity` — PARITY_N offline
recreate / rotating online COW reshape),
the traditional stock `--grow --raid-devices` syntax (one-line and two-step,
verified to grow capacity), and I/O concurrent with a throttled reshape
— across PARITY_N and rotating at m=2/3/4, on brd ramdisks:

```sh
sudo MDADM=../mdadm/mdadm bash tools/raidkm-test.sh
```

It loads the module + deps and creates ramdisks itself; point `MDADM` at the
raidkm-aware fork (it refuses a stock mdadm).  Exit status is non-zero if any
check fails.  Individual stages can be run directly (`raidkm-test-{functional,
degraded,grow,grow-traditional,reshape-concurrent}.sh`); see
`raidkm-test-lib.sh` for the env knobs.

**Reshape crash/fault suite** (`tools/raidkm-test-reshape-crash.sh`, needs a
`CONFIG_RAIDKM_FAULT_INJECT` kernel build): power-loss and torn-write recovery of
the COW-staged online reshape, driven by the `raidkm_reshape_inject` debug knob.
Tier 0 clean reshape · Tier 1 crash+resume at each phase × band · Tier 2 torn
STAGE/COMMIT (redo-from-old / replay-from-scratch) · Tier 3 hybrid fault tolerance
(frozen mid-reshape: the migrated region survives `m_new` failures, the pending
region `m_old`, each probed on its own array) · Tier 4 torn COMMIT + concurrent
member failure.  **114 passed / 0 failed on both base and GFNI (2026-06-11).**
Scope: this validates *reading through* faults during a reshape; *completing* a
reshape after losing members mid-flight is not yet supported (`migrate_band` is
non-degraded-read only) — see `notes/reshape-cow-design.md` §6/§9.  Without the
fault-inject build the script auto-runs Tier 0 + a best-effort timed crash.

## Repository layout

```
md-kmec/
├── Kbuild               # top-level kbuild glue (obj-m += km/)
├── Makefile             # build infra; symlinks ../mdraid/md and ../mdraid/isa-l
├── compat/
│   └── compat-rhel10.h  # RHEL 10.1 personality-API shim (force-included by the build)
├── tools/
│   ├── raidkm-test.sh               # run the full test suite (functional/degraded/grow)
│   ├── raidkm-test-lib.sh           # shared helpers sourced by the test scripts
│   ├── raidkm-test-functional.sh    # create/write/read/scrub, PARITY_N+rotating × m=2/3/4
│   ├── raidkm-test-degraded.sh      # max-degraded reconstruction (read + write)
│   ├── raidkm-test-grow.sh          # --add-data (incl. degraded-read-after-grow) + --add-parity
│   ├── raidkm-test-grow-traditional.sh    # stock --grow --raid-devices syntax (one-line + two-step)
│   ├── raidkm-test-reshape-concurrent.sh  # I/O concurrent with a throttled reshape (dual EC tables)
│   ├── raidkm-test-reshape-crash.sh    # power-loss/torn-write recovery of the COW reshape (fault-inject build)
│   ├── raidkm-standard-benchmark.sh   # fio harness, reused from prototype
│   └── raidkm-create.sh               # sysfs array creation; needs adapting
│                                    # to "raidkm" name / level 71
└── km/
    ├── Kbuild           # builds raidkm.ko = raid_km.o + raid_km-cache.o + raid_km-ppl.o
    ├── raid_km.c        # fork of mdraid/md/raid5.c with effective_level dispatch
    ├── raid_km.h        # fork of raid5.h (RAID_KM_LEVEL, is_raid6_math, effective_level)
    ├── raid_km-cache.c  # fork of raid5-cache.c (journal, dormant unless attached)
    ├── raid_km-ppl.c    # fork of raid5-ppl.c (partial parity log, ditto)
    ├── raid_km-log.h    # fork of raid5-log.h
    └── raid0.h          # fork (for the takeover stubs to link)
```

## Building

Requires built [mdraid](https://github.com/scopedog/mdraid)
in a sibling directory for `isal_lib.ko`'s exports.

```sh
cd ../mdraid && make     # produces isal_lib.ko + raid456.ko etc.
cd ../md-kmec && make    # produces km/raidkm.ko
```

The build force-includes `compat/compat-rhel10.h` so the verbatim
raid5.c source compiles against the RHEL 10.1 personality API
(`register_md_submodule` etc.).

## Managing raidkm arrays with mdadm

Stock `mdadm` rejects level 71.  A patched **mdadm 4.4** that
understands `raidkm`/level 71 lives in the sibling
[`mdadm`](../mdadm) checkout (branch `raidkm-level71`).  On the CLI,
placement and count are separate: `--layout=rotating|parity-last`
and `--parity-count=N`.  Internally raidkm packs both into the v1.x
superblock `layout` field — the **low byte carries m** (2–8) and
**bit `0x100` selects rotating** (clear = parity-last) — but that
packing is an implementation detail you don't type.  Under
parity-last, data lives on disks `[0, raid_devices − m)` and never
moves; under rotating the m-slot parity block rotates one disk per
stripe.  No raidkm-specific superblock code is needed — md core
round-trips level 71 and the packed `layout` through the standard
v1.2 superblock.

**Version pairing.** `raidkm.ko` and the patched mdadm are
co-dependent — features land across both repos together (level-71
create / assemble / grow, and the PPL consistency policy).  Build and
run them as a **matched pair**: the mdadm fork that goes with this
tree is branch **`raidkm-level71`**, currently at commit
**`d86ac2b1`** ("raidkm: split parity count from layout; default to
rotating").  When you advance one repo, rebuild the other from
its matching commit.  The fork will be wired in as a git submodule once it has a
published remote (`scopedog/mdadm`); until then it lives in
the sibling [`mdadm`](../mdadm) checkout and the pairing is tracked
here by hand.

Build it (userspace; `NO_LIBUDEV` avoids the libudev build dep):

```sh
cd ../mdadm && make CXFLAGS=-DNO_LIBUDEV mdadm
```

Load the personality and its dependencies (the `async_tx` family
is **not** pulled in by `raid6_pq` alone), then `isal_lib.ko`,
then `raidkm.ko`:

```sh
for m in async_tx async_memcpy async_xor async_pq async_raid6_recov raid6_pq; do
        modprobe $m
done
insmod ../mdraid/isa-l/isal_lib.ko
insmod km/raidkm.ko
```

### Create

Two independent knobs: **`--parity-count=N`** sets the parity-disk count
m (2–8, default 2; alias `--parities`), and **`--layout=`** sets the
placement — `rotating` (default) or `parity-last` (aliases `dedicated`/
`fixed`).  Data disks = `raid-devices − m`.

```sh
# 3 data + 2 parity (m=2, raid6-equivalent fast path), rotating (default)
mdadm --create /dev/md70 --level=raidkm --parity-count=2 \
      --raid-devices=5 --chunk=64 /dev/ram0 /dev/ram1 /dev/ram2 /dev/ram3 /dev/ram4

# 3 data + 4 parity (m=4, Cauchy matrix), parity-last (dedicated tail parity)
mdadm --create /dev/md70 --level=raidkm --parity-count=4 --layout=parity-last \
      --raid-devices=7 --chunk=64 \
      /dev/ram0 /dev/ram1 /dev/ram2 /dev/ram3 /dev/ram4 /dev/ram5 /dev/ram6

# 4 data + 3 parity (m=3), rotating — parity spread across all 7 disks
mdadm --create /dev/md70 --level=raidkm --parity-count=3 --layout=rotating \
      --raid-devices=7 --chunk=64 \
      /dev/ram0 /dev/ram1 /dev/ram2 /dev/ram3 /dev/ram4 /dev/ram5 /dev/ram6
```

> **Deprecated:** the older packed form `--layout=N` (parity-last) /
> `--layout=Nr` (rotating), which crammed m into `--layout`, is still
> accepted for back-compat but prints a warning; prefer `--parity-count`
> + `--layout=rotating|parity-last`.  Note the default flipped with the
> new syntax: omitting `--layout` now means **rotating** (it used to mean
> PARITY_N), so a bare `--layout=2` still means parity-last as before.

`--detail` / `--examine` report `Raid Level : raidkm`, `Layout :
rotating` (or `parity-last`), and `Parity Count : <N>`.

### Assemble

```sh
mdadm --stop /dev/md70
mdadm --assemble /dev/md70 /dev/ram0 /dev/ram1 /dev/ram2 /dev/ram3 /dev/ram4
```

A degraded array (up to **m** missing members) assembles with
`--run`; missing data is reconstructed on read:

```sh
mdadm --assemble --run /dev/md70 /dev/ram0 /dev/ram1 /dev/ram2 /dev/ram3 /dev/ram4
```

### Grow

raidkm `--grow` has two role-tagged forms; each disk you list is added in
the named role, so you never compute the new device count yourself:

| command | what it does | layouts | mechanism |
|---|---|---|---|
| `--grow --add-data <disks>` | add **data** disk(s) — grow capacity, m fixed | PARITY_N **and** rotating | online kernel reshape |
| `--grow --add-parity <disks>` | add **parity** disk(s) — raise m, k fixed | PARITY_N **and** rotating | PARITY_N: offline recreate. rotating: **online COW reshape** (no backup-file, crash-safe via the kernel journal); offline windowed relocation retained as a fallback (`MDADM_RAIDKM_OFFLINE_ADDPARITY`) — see below |

**The traditional (stock) `--grow` syntax also works.**  Because parity in a
stock RAID6 is fixed, growing `--raid-devices` there means *add capacity*, so
on raidkm an **untagged** grow that gives an explicit `--raid-devices=N` is
treated as `--add-data` (grow data at fixed m).  Both stock entry forms work —
the one-line `--add` and the classic two-step where you add hot spares first:

```sh
mdadm --grow /dev/md70 --raid-devices=5 --add /dev/ram5   # one-line: == --add-data
# …or…
mdadm /dev/md70 --add /dev/ram5 /dev/ram6                 # add spares (MANAGE)
mdadm --grow /dev/md70 --raid-devices=6                   # grow into them == --add-data
```

A bare `--grow --add <disks>` with **no** `--raid-devices` keeps the raidkm
shorthand of adding **parity** (alias for `--add-parity`).  An explicit
`--add-data`/`--add-parity` always wins, so use those when you want to be
unambiguous.

#### `--add-data` — grow capacity (online reshape)

```sh
mdadm --grow /dev/md70 --add-data /dev/ram5            # k=3 → k=4 (m unchanged)
mdadm --grow /dev/md70 --add-data /dev/ram5 /dev/ram6  # k=3 → k=5
```

Adding a data disk changes the stripe width, so every block relocates — a
true restripe.  raidkm drives the **inherited kernel online reshape**
(`delta_disks` at a fixed parity count): the new disk(s) are added as spares,
`raid_disks` is bumped, and the kernel relocates the array stripe-by-stripe
with a crash-safe `reshape_position` checkpoint.  Works for **both** layouts
(the relocation rides the layout-aware sector mapping).  The array stays
readable/writable throughout, and a grow needs **no backup file** (the wider
new layout writes behind the old layout's read frontier, so nothing
unread is overwritten — and a crash resumes from the checkpoint).  The layout
is immutable across a grow.  Monitor with `/proc/mdstat` or `--detail`.

#### `--add-parity` — add a parity disk (both layouts)

Adding parity raises m (more fault tolerance) at a fixed data-disk count.
**How it's done depends on the layout**, because the two layouts place parity
differently:

**PARITY_N — offline recreate (cheap, no data movement).**  PARITY_N keeps
data on a fixed prefix of disks and never relocates it, so adding parity only
appends a parity disk and recomputes parity for the new m.  There is no
in-kernel online reshape for a parity-count change (it would alter
`max_degraded`), so `--grow` does it **offline but data-preserving**: it stops
the array and recreates it at the new m (same device order, `data_offset`, UUID
and name), then md's normal resync recomputes parity while the array is online.
You can add **several** parity disks in one command.

```sh
mdadm --grow /dev/md70 --add-parity /dev/ram5             # m=2 → m=3
mdadm --grow /dev/md70 --add-parity /dev/ram5 /dev/ram6   # m=2 → m=4
mdadm --grow /dev/md70 --add /dev/ram5                    # legacy alias (= --add-parity)
```

The array is usable throughout the background resync, but is **not fully
fault-tolerant until the resync completes** (the same window as any md
rebuild), and the brief stop+recreate is not crash-safe.  On real
(non-identical) disks the recreate must reuse the original `data_offset`; on
uniform disks mdadm picks it deterministically.

**Rotating — online COW reshape (default).**
Under rotating parity every block moves when m changes, so there is no cheap
append.  raidkm drives an **online, journaled, copy-on-write reshape** entirely
in the kernel: it adds the new disk, then migrates the array **one band at a
time**, staging each band's new-geometry stripe **out-of-place** (in the
metadata gap below a constant `data_offset`) and journaling STAGE→COMMIT→DONE
before overwriting the band's home location.  Because no live block is
overwritten until its new-geometry copy is durably staged, correctness is
placement-agnostic — the read/write location-aliasing race that sank the earlier
*in-place* attempt (withdrawn 2026-06-01) is structurally impossible.  The
data-disk count `k` is unchanged, so `array_size` and `data_offset` stay
constant; only m (hence `max_degraded` and the parity placement) changes.

The array stays readable/writable throughout and needs **no backup file**: a
power loss mid-reshape is recovered by a plain `mdadm --assemble`, which replays
the in-kernel journal (raidkm sets `RESHAPE_NO_BACKUP`, so mdadm neither demands
a backup-file nor runs its critical-section restore).  Add **one** parity disk
per run; raise m further with repeated runs.  The same reshape is also drivable
through device-mapper / LVM.

```sh
mdadm --grow /dev/md70 --add-parity /dev/ram5   # m=2 → m=3 (rotating), online
```

> **Validated.** Whole-array m=2→3 (base) and m=3→4 Cauchy (GFNI) — data
> byte-identical + scrub=0 + new-m-degraded-read EC oracle — plus a true
> power-loss crash (dm-flakey `drop_writes`) recovered by a plain `--assemble`.
> The reshape crash/fault suite (`tools/raidkm-test-reshape-crash.sh`) is **114
> passed / 0 failed on base and GFNI** (2026-06-11).
>
> **Scope.** *Reading through* faults during a reshape is supported; *completing*
> a reshape after losing members mid-flight is not yet (`migrate_band` is
> non-degraded-read only) — see `notes/reshape-cow-design.md` §6/§9.
>
> **Fallback — offline windowed relocation.** For kernels without the COW engine,
> the pre-COW offline path is retained behind `MDADM_RAIDKM_OFFLINE_ADDPARITY=1`:
> it stops the array, relocates data on the raw members in ≤64 MiB **batches**
> (each backed up to `--backup-file` first for crash rollback — bounded scratch,
> a 64 MiB window, *not* array-sized), then recreates at m+1 and lets resync
> rebuild parity.  Crash-safe/resumable via a `<backup-file>.raidkm-state`
> sidecar (re-run the same command to roll back the in-flight window and continue),
> but the array is offline for the duration.
>
> ```sh
> MDADM_RAIDKM_OFFLINE_ADDPARITY=1 \
>   mdadm --grow /dev/md70 --add-parity --backup-file=/var/tmp/rk.bak /dev/ram5
> ```

To add a **hot spare** (not part of the array yet), use MANAGE-mode `--add`
without `--grow`: `mdadm /dev/md70 --add /dev/ram5`.

## Managing raidkm via device-mapper and LVM

Besides `mdadm`, raidkm arrays can be driven through **device-mapper** — either
directly with `dmsetup` (the kernel `dm-raid` target), or, the managed way, as
**LVM logical volumes**. This needs no new dm target: `dm-raid` already stands up
an `mddev` and runs whatever personality `md_run()` selects by level, so level 71
rides the existing target. (The enabling `dm-raid.c` changes live in the
[mdraid](https://github.com/scopedog/mdraid) fork; full design and
validation are in [`notes/dm-raid-design.md`](notes/dm-raid-design.md).)

### dmsetup (raw device-mapper)

```sh
# 3 data + 2 parity (m=2), rotating, 512 KiB chunk, over 5 devices:
dmsetup create kmtest --table \
  "0 <sectors> raid raidkm 3 1024 parity_count 2 5 - /dev/ram0 - /dev/ram1 - /dev/ram2 - /dev/ram3 - /dev/ram4"
dmsetup status kmtest            # health string + sync_action + mismatch_cnt
dmsetup message kmtest 0 check   # scrub
```

Degraded = suspend / reload-with-`- -` in the victim slot / resume. Rebuild =
reload with a fresh device + a `rebuild <idx>` parameter. `raidkm` is the
rotating layout; `raidkm_n` is parity-last.

### LVM (`lvcreate --type raidkm`)

The lvm2 raidkm fork registers two segtypes — `raidkm` (rotating) and `raidkm_n`
(parity-last) — each carrying the parity count `m`:

```sh
lvcreate --type raidkm --paritycount 2 -i 3 -L 1G -n data vg   # 3 data + 2 parity
lvconvert --repair vg/data                                     # raidkm-aware leg replace + rebuild
lvchange --monitor y vg/data                                   # dmeventd auto-repair
```

Create / activate / I/O / reassembly / degraded read, `lvconvert --repair`, and
dmeventd auto-repair are validated for m=2/3/4 on both the base and GFNI EC paths.
Because the dm/LVM reshape path (out-of-place via data-offset) does not fit
raidkm's layout, **growing/shrinking a raidkm LV is not supported via LVM** — use
`mdadm --grow` for capacity/parity changes (the kernel gate rejects dm reshape).

An LVM raidkm LV is an ordinary cache origin, so it can be fronted by **lvmcache**
(`lvconvert --type cache`) — e.g. a fast tier over the EC capacity tier under a
filesystem. See `notes/rhel9-lvmcache-ost.md` (on the `rhel9-port` branch) for an
end-to-end `dm-cache → dm-raid(raidkm)` validation.

## License

GPL-2.0-only.  See [LICENSE](LICENSE).
