# raidkm Field Manual

A Linux `md` personality implementing arbitrary **k+m** Reed–Solomon erasure
coding — forked from `raid5.c`, encoded through ISA-L (GFNI where the CPU has
it), with three parity placements, built-in per-block checksums that drive
parity self-healing, and online reshape in every direction.

| | |
|---|---|
| level | **71**, personality name `raidkm` |
| parity | **m = 2…8** |
| layouts | `rotating` (default) · `parity-last` · `declustered` |
| drivers | `mdadm` · `dmsetup` · LVM |
| kernels | RHEL 10 · RHEL 9 · mainline |
| mdadm fork | branch `raidkm-level71` |
| licence | GPL-2.0-only |

This is the operator-facing companion to [`README.md`](../README.md), which
remains the canonical record of design decisions, milestones and measurement
provenance. Everything here is drawn from that record and from the source
(`km/raid_km*.{c,h}`, `tools/`) — where the two disagree, the source wins.

---

## Contents

**Orientation** — [What it is](#what-it-is) · [Feature catalogue](#feature-catalogue) · [The three layouts](#the-three-layouts) · [Measured results](#measured-results)

**Procedures** — [1 Build & load](#1-build--load) · [2 Create an array](#2-create-an-array) · [3 Verify & scrub](#3-verify--scrub) · [4 Failure & rebuild](#4-failure--rebuild) · [5 Grow & shrink](#5-grow--shrink) · [6 Declustered operations](#6-declustered-operations) · [7 Checksums & healing](#7-checksums--healing) · [8 device-mapper & LVM](#8-device-mapper--lvm) · [9 Convert from raid6](#9-convert-from-raid6)

**Reference** — [Knob reference](#knob-reference) · [Deployment checklist](#deployment-checklist) · [Limits & gotchas](#limits--gotchas) · [Test suite](#test-suite)

---

## What it is

raidkm registers as an md personality at **level 71** under the name `raidkm`.
Stock raid4/5/6 stay untouched in the kernel — `km/raid_km.c` is a
copy-and-modify of `raid5.c`, and it reuses raid5's m=2 code paths through a
per-conf `effective_level` field rather than mutating `mddev->level` (which md
core treats as invariant after `md_run`).

Parity is the ISA-L `gf_gen_rs_matrix` Reed–Solomon code for every m. Two
deliberate asymmetries are worth knowing before you deploy:

- **Encode at m=2 is raid6's tuned SIMD.** The RS code's first two rows are
  exactly P=XOR and Q=Σ2ⁱ·Dᵢ over GF(2⁸)/0x11d, so m=2 is computed with
  `raid6_call` for speed while writing *byte-identical* parity — which is why
  the m=2 image is a valid prefix of the m≥3 encoding, and why "add a parity"
  stays incremental. m≥3 calls `ec_encode_data_*` directly.
- **Decode is one unified path for every m** (`ops_run_compute_km`) — build the
  survivors' decode matrix, invert with `gf_invert_matrix`, apply with ISA-L. It
  is deliberately **PSHUFB-free**: never raid6's `*_recov`, never ISA-L's PSHUFB
  kernels, which keeps it clear of the StreamScale patent surface. GFNI decode
  comes straight from `isal_lib` and needs no `raid_isal.ko` — that optional
  override only swaps the m=2 *encode* and does not touch decode.

> **Version pairing.** `raidkm.ko` and the patched mdadm are co-dependent —
> features land across both repos together. Run them as a matched pair: the
> mdadm fork is branch `raidkm-level71` (currently at `24e99c1b`). Stock mdadm
> rejects level 71 outright, and stock `mdadm --examine` will `SIGABRT` on a
> raidkm member — deploy the fork as `/usr/sbin/mdadm`.

---

## Feature catalogue

Status tags: **default** is on unless you turn it off; **opt-in** needs a
create-time or sysfs switch; **scoped** ships with a documented boundary.

### Erasure-coding core

| Feature | What it does | |
|---|---|---|
| Arbitrary k+m<br>`--parity-count=2…8` | Reed–Solomon over GF(2⁸); m=2 uses the raid6 P+Q fast path, m≥3 the ISA-L encoder, m≥4 a Cauchy matrix. **m=3 is the first case stock raid6 cannot do at all.** | shipped |
| GFNI acceleration | Encode and decode select SIMD independently — `ec_encode_data_avx512_gfni` / `avx2_gfni` when the CPU has it, the scalar table-lookup base path otherwise. GFNI's encode win shows at m≥3. | auto |
| Degraded read | Survives up to **m** simultaneous member losses on read; verified 1/2/3-fail on GFNI and base. | shipped |
| Degraded write | Reconstruct the failed data from k survivors, re-encode all parity, write the survivors — validated m=2…5 × 1…m failures (data-only, parity-only, mixed, max-degraded). | shipped |
| m-way scrub | Re-encode-and-compare across all m; detect → repair on both SIMD paths, on healthy *and* degraded arrays. | shipped |

### Integrity & self-healing

| Feature | What it does | |
|---|---|---|
| Native per-block checksums<br>`--checksum=crc32c` | A CRC-32C per 4 KiB block that raidkm computes, stores and verifies itself — no `dm-integrity` stacking. CRCs live in a **reserved region at each member's tail** (~0.1% of capacity) in self-checking pages, served through a bounded demand-paged cache auto-sized to cover the whole region. Reads verify **inline in the bio completion**. | opt-in |
| Checksum-driven self-heal | An integrity-flagged read becomes an **m-erasure reconstruction**: the corrupt block is rebuilt from parity and rewritten, on the read path and on scrub, with mixed data+parity corruption healed in a single pass. **Validated to m=8** — eight silent corruptions in one stripe, deterministically, beyond RAID-Z3's three. | shipped |
| Integrity sources | Detection can come from native checksums, a stacked `dm-integrity`, or T10-PI passthrough. raidkm always supplies the *reconstruction*. | shipped |
| `healed_blocks` | Read-only sysfs counter of repairs performed — the signal to watch on a production array. | always |

### Parity placement

| Feature | What it does | |
|---|---|---|
| Rotating<br>`--layout=rotating` | Generalized left-symmetric: the m-slot parity block rotates one disk per stripe, spreading parity **and normal-read traffic** across all members. The create default. | default |
| Parity-last<br>`--layout=parity-last` | Dedicated tail parity, RAID4-style — data lives on disks `[0, N−m)` and never moves, which is what buys the cheap offline add-a-parity grow. | shipped |
| Declustered<br>`--layout=declustered` | Narrow k+m groups scattered over a wide N-disk pool by a seeded balanced permutation, with **distributed spare columns** instead of one hot spare. Clean-room design-theory combinatorics — same idea as dRAID, no CDDL code. | shipped |

### Reshape — every axis, online

| Feature | What it does | |
|---|---|---|
| Add data<br>`--grow --add-data` | k → k+1, capacity grows, m fixed. Drives the inherited kernel online reshape; EC tables are rebuilt for the new k and the **old-k set kept as `prev_ec_*`** so I/O either side of `reshape_position` is correct. No backup file. | shipped |
| Remove data<br>`--grow --raid-devices=N−1` | The inverse, via the same journaled COW engine walked **backwards**. Array-size-first: shrink the filesystem, clamp with `--array-size`, then reshape. One disk per invocation. | shipped |
| Add parity<br>`--grow --add-parity` | m → m+1 at fixed k. Parity-last appends cheaply (offline recreate, no data movement); rotating relocates everything, so it runs an **online journaled COW reshape** — each band staged out-of-place before its home is overwritten, no backup file, crash-recovered by a plain `--assemble`. | shipped |
| Remove parity<br>`--grow --remove-parity` | m → m−1 (≥2 remain), k and capacity fixed, so every row simply re-encodes in place — no array-size dance. The m=4→3 Cauchy→Vandermonde boundary is handled by the re-encode. Classic layouts only. | shipped |
| Pool expand / shrink<br>`--grow --raid-devices=N′` | Declustered: re-tile each row into more (or fewer) k+m groups at fixed g, m, s. Shrink removes one group's disks per reshape and runs the engine backwards. | shipped |
| Spare-count change<br>`--grow --spare-columns=s′` | Trade capacity against distributed-spare columns in either direction, on the fixed pool. | shipped |
| Crash safety | Every COW reshape journals STAGE→COMMIT→DONE. A power loss mid-reshape is recovered by a plain `mdadm --assemble` replaying the in-kernel journal — raidkm sets `RESHAPE_NO_BACKUP`, so mdadm neither demands a backup file nor runs its critical-section restore. Fault suite: **114 passed / 0 failed** on base and GFNI. | shipped |

### Consistency & logging

| Feature | What it does | |
|---|---|---|
| Write-intent bitmap | Inherited from raid5.c, works unchanged on level 71: an unclean shutdown resyncs only the dirty bits, and `--re-add` does a bitmap-scoped recovery (measured 17 s vs 171 s full rebuild). A fresh-spare `--add` still does the full rebuild, correctly. | available |
| PPL<br>`--consistency-policy=ppl` | Closes the parity write hole, extended from raid5's single XOR to **all m partial parities**; recovery rebuilds each as `P_j = PP_j XOR encode_j(modified)`. Costs **−43% to −72%** on RAM-backed devices (a serialized FUA log write), so it is off by default and mutually exclusive with the bitmap. | opt-in |

### Management surfaces

| Feature | What it does | |
|---|---|---|
| mdadm | Create, assemble, grow/shrink in every direction, manage. The full-featured path — reshape is **mdadm-only**. | shipped |
| device-mapper | Level 71 rides the in-tree `dm-raid` target with **no new dm target**; a `FEATURE_FLAG_RAIDKM` superblock bit keeps stock dm-raid off a raidkm SB. Create, I/O, degraded, scrub, reassembly and rebuild-via-reload validated 21/21 base + 51/51 GFNI, m=2…6. | no reshape |
| LVM<br>`lvcreate --type raidkm` | Two segtypes — `raidkm` (rotating) and `raidkm_n` (parity-last) — carrying `parity_count`. Includes `lvconvert --repair` and dmeventd auto-repair. An LV is an ordinary cache origin, so lvmcache can front it. | no reshape |
| raid6 ↔ raidkm convert | Stock RAID6 left-symmetric m=2 and raidkm rotating m=2 are byte-for-byte identical on disk, so conversion **moves no data** — it rewrites each member's superblock level+layout and reassembles. Any other layout is refused. | shipped |

### Performance defaults

| Feature | What it does | |
|---|---|---|
| Worker groups | Auto-enabled: total worker threads default to `max(nproc/2, 2)` across one group per NUMA node. Stock ships them off, which is most of the out-of-box gap. | default |
| Zero-copy writes<br>`skip_copy` | A full-page-aligned write aliases the stripe-cache page to the incoming bio page instead of memcpy'ing it in — and that copy, not the EC (≈0.6% of write-path CPU), is the dominant cost of a full-stripe write. **+39%** on full-stripe sequential DIO; neutral on partial RMW. | default |
| Parallel sync path | Resync/rebuild fans **multiple stripes per `sync_request`** instead of walking one stripe-window at a time — and the rate is independent of worker count. | default |
| Lockless unplug | `raid5_unplug` releases plugged stripes through the lockless `released_stripes` llist instead of the global `device_lock`. **+25% 4K randwrite at lower CPU** on null_blk; upstream-ready and mirrored into the perf tree's raid5.c. | default |

---

## The three layouts

Each cell below is one chunk on one member. Columns are physical disks, rows are
successive device rows. This is the single decision that is hardest to change
later, so read it before `--create`.

### parity-last — `--layout=parity-last --parity-count=2`

N=7, m=2. Data sits on a fixed prefix and never relocates; the tail m disks
carry every parity block. That immobility is exactly what makes `--add-parity` a
cheap append — and what concentrates parity read/write traffic on two members.

```
      d0   d1   d2   d3   d4   d5   d6
row 0 D0   D1   D2   D3   D4   P0   P1
row 1 D0   D1   D2   D3   D4   P0   P1
row 2 D0   D1   D2   D3   D4   P0   P1
row 3 D0   D1   D2   D3   D4   P0   P1
row 4 D0   D1   D2   D3   D4   P0   P1
```

### rotating — `--layout=rotating --parity-count=2`

N=7, m=2, the create default. `pd_idx = N − 1 − (row mod N)`, parity occupies
slots `pd_idx … pd_idx+m−1 (mod N)`, data follows. Parity and normal-read
traffic spread over all members. One slot mapping serves both classic layouts —
parity-last is simply the `pd_idx == k` case — so encode, decode, scrub and PPL
are layout-agnostic.

```
      d0   d1   d2   d3   d4   d5   d6
row 0 P1   D0   D1   D2   D3   D4   P0
row 1 D0   D1   D2   D3   D4   P0   P1
row 2 D1   D2   D3   D4   P0   P1   D0
row 3 D2   D3   D4   P0   P1   D0   D1
row 4 D3   D4   P0   P1   D0   D1   D2
row 5 D4   P0   P1   D0   D1   D2   D3
row 6 P0   P1   D0   D1   D2   D3   D4
```

There are no spare chunks in this layout — rotating moves *parity*, and every
column of every row is data or parity. A hot spare on a classic array is a whole
device sitting outside the mapping, exactly as in stock md.

### declustered — `--layout=declustered --group-width=6 --spare-columns=2`

N=14, g=6 (4+2), s=2 → `ngroups = (N−s)/g = 2`. Each row holds two independent
4+2 groups (`A*` and `B*`) plus two **spare** columns, all placed by the seeded
permutation.

```
      d0    d1    d2    d3    d4    d5    d6    d7    d8    d9    d10   d11   d12   d13
row 0 AD0   BD3   AD3   BD1   S0    AD1   BP1   AP1   BD2   AD2   S1    AP0   BP0   BD0
row 1 S1    BD2   AD2   BD0   BP1   AD0   BP0   AP0   BD1   AD1   S0    AD3   BD3   AP1
row 2 S0    BD1   AD1   AP1   BP0   S1    BD3   AD3   BD0   AD0   BP1   AD2   BD2   AP0
row 3 BP1   BD0   AD0   AP0   BD3   S0    BD2   AD2   AP1   S1    BP0   AD1   BD1   AD3
row 4 BP0   AP1   S1    AD3   BD2   BP1   BD1   AD1   AP0   S0    BD3   AD0   BD0   AD2
row 5 BD3   AP0   S0    AD2   BD1   BP0   BD0   AD0   AD3   BP1   BD2   S1    AP1   AD1
```

`A`/`B` = group, `D*` = data slot, `P*` = parity slot, `S*` = distributed spare.
Note where the spares land: they are not a disk, they are a rotating set of
columns that visits *every* member — which is why a rebuild writes across the
whole pool instead of funnelling into one replacement.

The permutation drawn here is illustrative of the construction, not the exact
seed your array will get: mdadm runs an acceptance search at create time (float
scoring is userspace-only) and records the winning seed plus geometry in a
per-member on-disk `rkdcl` block; the kernel regenerates the identical
permutation from that seed alone.

> **Constraint C1:** `(N − s) mod g == 0` — groups must tile a row without
> wrapping. mdadm validates it and suggests a legal `--spare-columns` if you
> miss. This is also a capacity-efficiency lever: N=80 takes g=13/s=2
> comfortably, while g=16 would force s=16 and burn 12.5% of the pool on spare.

---

## Measured results

| | |
|---|---|
| **6.9–8.2×** | out-of-box IOPS vs stock raid6, k=14 m=2, 16 × brd, defaults on both sides |
| **17.5×** | faster rebuild of a failed 16 GB member, N=80 g=13 declustered vs classic 78+2 |
| **96–101%** | of the no-checksum baseline with native CRC-32C on, real NVMe, four workloads |
| **m = 8** | simultaneous *silent* corruptions healed in one stripe, deterministically |

### Out of the box, wide array

| Workload | stock raid6 | raidkm | speedup |
|---|---:|---:|---:|
| Random 4K write (RMW worst case) | 54,266 | 375,269 | 6.92× |
| Database mixed 75/25 8K | 106,072 | 868,263 | 8.19× |
| High concurrency 70/30 4K, 16 jobs | 177,730 | 1,210,715 | 6.81× |
| OLTP 70/30 16K | 52,574 | 396,083 | 7.53× |
| Partial stripe write 8K | 31,256 | 230,669 | 7.38× |

IOPS, mean of 3 runs. `raidkm-standard-benchmark.sh --runs=3`, 16 × brd, k=14
m=2, 64 KiB chunk, both `--assume-clean`, GCP c3-standard-22 / RHEL 10.2.
Post-run integrity check `mismatch_cnt=0`. This is default-vs-default: the gap
is dominated by raidkm's worker-group auto-default, since stock's RMW path is
serialized at `gtc=0`. At matched `group_thread_cnt` the structural-only edge is
much smaller — and the ratio scales with core count, so it is not a fixed
per-machine constant.

### Rebuild — where declustering pays

| Pool | declustered populate | classic recover | classic (pre-dcl build) | speedup |
|---|---:|---:|---:|---:|
| N=14 g=6 (4+2) | 27.9 s | 57.1 s | 56.8 s | 2.05× |
| N=80 g=13 (11+2) | 48.3 s | 761.5 s | 777.5 s | 15.8× |

16 GiB member, 16 × local SSD, RHEL 10.2, `--rebuild-victim`. Two readings:
declustering wins the rebuild (the classic 78+2 recover is single-writer-bound
at ~21 MB/s), *and* the declustered code adds no overhead to the classic path —
current-classic and pre-declustered-classic recover in the same time at both
scales.

The wall-clock win follows from where the rebuild I/O lands, which exact
per-disk counters make device-count-independent:

| Pool | Rebuild-write funnelling¹ | Survivor read at rebalance² |
|---|---:|---:|
| N=14 g=6 (4+2) | 14.2× | 5.0× |
| N=42 g=10 (8+2) | 42.5× | 9.3× |
| N=80 g=13 (11+2) | 85.0× | 12.6× |

¹ Busiest single disk's write during the rebuild, classic ÷ declustered. The
ratio tracks N — the wider the pool, the more the single-writer bottleneck is
removed.
² Total bytes read off survivors to bring a fresh disk back, copy-from-spare
rebalance ÷ decode rebuild. The ratio tracks g−1, because decode reads g−1
survivors per lost chunk while copy-from-spare reads roughly one disk's worth.

### Cost of native checksums, real NVMe

| Workload | no checksum | native | dm-integrity journal | dm-integrity bitmap |
|---|---:|---:|---:|---:|
| Sequential write, MB/s | 2245 | 2264 · 101% | 1088 · 48% | 2230 · 99% |
| Random write, K IOPS | 97.2 | 93.2 · 96% | 40.8 · 42% | 78.5 · 81% |
| Sequential read, MB/s | 5626 | 5599 · 99.5% | 5624 · 100% | 5014 · 89% |
| Random read, K IOPS | 1236.2 | 1235.9 · 100.0% | 978.0 · 79% | 934.4 · 76% |

8 × 375 G local NVMe, n2-standard-32, RHEL 10.2. raidkm m=2 rotating (6+2), 64
KiB chunk, fio `--direct=1 --iodepth=32`. Zero false mismatches across every
run. Fair-comparison note: dm-integrity *journal* is crash-atomic — a stronger
guarantee than native or bitmap, both of which recompute checksums over the
resync window after an unclean shutdown. That guarantee is what journal's ~2×
write cost buys.

---

## 1 Build & load

The tree is one component of the raidkm mdraid stack — build it through
`mdraid-super`, which assembles all components in the correct order. The steps
below are the direct path when you already have a built `mdraid` sibling.

```sh
# isal_lib.ko's exports come from the sibling mdraid tree
cd ../mdraid   && make          # isal_lib.ko, raid456.ko, …
cd ../md-kmec  && make          # km/raidkm.ko

# userspace; NO_LIBUDEV avoids the libudev build dep
cd ../mdadm && make CXFLAGS=-DNO_LIBUDEV mdadm
```

One source tree builds against three kernel flavours. The build picks a `TARGET`
from the running kernel release and force-includes the matching
`compat/compat-*.h` shim, so the verbatim raid5.c fork compiles against each
kernel's personality API unchanged:

| `TARGET` | Selected when | md headers | Personality API |
|---|---|---|---|
| `rhel10` | `.el10` | built mdraid tree | flat `md_personality` with `.level` |
| `rhel9` | `.el9` | `md-rhel9/` | `md_submodule_head` style (level from `head.id`) |
| `vanilla` | anything else | `md-vanilla/` | mainline |

Override with `make TARGET=rhel9` — useful against a KDIR whose release string
lacks the distro suffix, e.g. a locally-built debug kernel. RHEL 9 is
production-grade: the 12-suite matrix passes 211 checks under KASAN + lockdep
with zero splats.

```sh
# load — the async_tx family is not pulled in by raid6_pq alone
for m in async_tx async_memcpy async_xor async_pq async_raid6_recov raid6_pq; do
        modprobe $m
done
insmod ../mdraid/isa-l/isal_lib.ko
insmod km/raidkm.ko
```

---

## 2 Create an array

On the CLI, placement and count are separate knobs: `--layout=` chooses where
parity goes, `--parity-count=` chooses how much of it there is. Data disks =
`raid-devices − m`.

| Option | Meaning | Default |
|---|---|---|
| `--level=raidkm` | level 71 (also accepts `71`) | — |
| `--parity-count=N` | parity disks m, 2…8 (alias `--parities`) | `2` |
| `--layout=` | `rotating` · `parity-last` (aliases `dedicated`/`fixed`) · `declustered` | `rotating` |
| `--checksum[=crc32c]` | native per-block CRC-32C + self-healing (alias `--integrity=crc32c`) | off |
| `--group-width=g` | declustered: stripe width g = k+m, 3…255 | required for declustered |
| `--spare-columns=s` | declustered: distributed-spare columns per row, 1…127 | smallest legal value |
| `--dcl-nbase=n` | declustered, advanced: base permutations, 1…64 | chosen by search |
| `--dcl-seed=x` | declustered, advanced: pin the acceptance-search seed | chosen by search |
| `--consistency-policy=ppl` | enable PPL (closes the write hole; excludes the bitmap) | off |

```sh
# 3 data + 2 parity (m=2 → the raid6-equivalent fast path), rotating
mdadm --create /dev/md70 --level=raidkm --parity-count=2 \
      --raid-devices=5 --chunk=64 /dev/ram{0,1,2,3,4}

# 4 data + 3 parity (m=3) — the first geometry stock raid6 cannot express
mdadm --create /dev/md70 --level=raidkm --parity-count=3 --layout=rotating \
      --raid-devices=7 --chunk=64 /dev/ram{0,1,2,3,4,5,6}

# 3 data + 4 parity (m=4, Cauchy matrix), dedicated tail parity
mdadm --create /dev/md70 --level=raidkm --parity-count=4 --layout=parity-last \
      --raid-devices=7 --chunk=64 /dev/ram{0,1,2,3,4,5,6}

# m=2 with native per-block checksums + self-healing
mdadm --create /dev/md70 --level=raidkm --parity-count=2 --checksum=crc32c \
      --raid-devices=5 --chunk=64 /dev/ram{0,1,2,3,4}
```

```sh
# declustered: 14-disk pool, two 4+2 groups per row, 2 spare columns
mdadm --create /dev/md0 --level=raidkm --parity-count=2 \
      --layout=declustered --group-width=6 --spare-columns=2 \
      --raid-devices=14 /dev/sd[b-o]

# same, with native checksums — the CRC region stacks after the rkdcl block
mdadm --create /dev/md0 --level=raidkm --parity-count=2 \
      --layout=declustered --group-width=6 --spare-columns=2 --checksum \
      --raid-devices=14 /dev/sd[b-o]
```

> **Choose s deliberately.** `--spare-columns` defaults to the smallest legal
> value, which is *not* the resilient choice: **`s ≥ m` is what lets the pool
> absorb m concurrent failures**, because population consumes one spare column
> per failed member. Spare columns are also the only capacity you can trade back
> later (`--grow --spare-columns=s′`), but an increase is a capacity-shrinking
> reshape, so it needs the array-size-first dance.

`--detail` / `--examine` report `Raid Level : raidkm`, `Layout : rotating` (or
`parity-last`), and `Parity Count : <N>`.

### Deprecated packed layout form

The older `--layout=N` (parity-last) / `--layout=Nr` (rotating) form, which
crammed m into `--layout`, is still accepted for back-compat but prints a
warning. Note the default flipped with the new syntax: omitting `--layout` now
means **rotating**, where it used to mean parity-last — but a bare `--layout=2`
still means parity-last as before.

Internally raidkm packs both knobs into the standard v1.x superblock `layout`
field — low byte carries m, bit `0x100` selects rotating, `0x200` native
checksums, `0x400` declustered (with g and s in the high bits). No
raidkm-specific superblock code is needed; md core round-trips level 71 and the
packed layout through v1.2 unchanged. That packing is an implementation detail
you never type.

---

## 3 Verify & scrub

```sh
mdadm --detail /dev/md70          # Raid Level : raidkm · Layout : rotating · Parity Count : 3
mdadm --examine /dev/ram0         # per-member view (needs the fork — stock mdadm aborts)
cat /proc/mdstat                  # resync / reshape / populate progress
cat /sys/block/md70/queue/optimal_io_size   # = k × chunk, the data row width
```

```sh
echo check  > /sys/block/md70/md/sync_action    # verify, count mismatches
echo repair > /sys/block/md70/md/sync_action    # verify and rewrite parity
cat /sys/block/md70/md/mismatch_cnt             # must be 0 on a healthy array
cat /sys/block/md70/md/healed_blocks            # checksum-driven repairs performed
```

The scrub is an m-way re-encode-and-compare, and it runs on a degraded array
too. With native checksums enabled it is also a self-heal pass: a silently
corrupt block detected by CRC is reconstructed from parity and rewritten rather
than merely counted, with mixed data+parity corruption healed in a single pass.
`healed_blocks` advancing on a production array is the signal that a member is
rotting — check SMART before it becomes a rebuild.

---

## 4 Failure & rebuild

A raidkm array tolerates **m** simultaneous member losses for both reads and
writes. Classic layouts rebuild onto a replacement; declustered arrays do
something different — see [procedure 6](#6-declustered-operations).

```sh
mdadm --stop /dev/md70
mdadm --assemble /dev/md70 /dev/ram{0,1,2,3,4}

# up to m members missing: --run assembles anyway, reads reconstruct
mdadm --assemble --run /dev/md70 /dev/ram{0,1,2,3,4}
```

```sh
mdadm /dev/md70 --fail /dev/ram2 --remove /dev/ram2
mdadm /dev/md70 --add  /dev/ram5      # hot spare → rebuild starts

# bitmap-scoped recovery of a member that was only briefly absent
mdadm /dev/md70 --re-add /dev/ram2    # dirty bits only, not a full rebuild

# pre-emptive migration of a still-working but suspect member
mdadm /dev/md70 --replace /dev/ram2 --with /dev/ram5
```

Recovery reconstructs data via decode and parity via re-encode, and works while
the array is *still degraded* — a spare added to a 2-of-3-lost array rebuilds
correctly. With a write-intent bitmap, `--re-add` of a briefly-absent member
resyncs only the dirty regions; a fresh-spare `--add` correctly falls back to a
full rebuild rather than wrongly scoping it.

> **The exposure window is the thing to shorten.** A classic rebuild funnels
> every reconstructed byte onto the one replacement disk, so rebuild time is
> capped by a single disk's write speed no matter how wide the array — and the
> array stays degraded, and exposed to the next failure, for the whole of it. On
> the measured N=80 pool that was **785 s vs 45 s** declustered. If your pool is
> wide, that difference is the argument for `--layout=declustered`, and it must
> be made at create time.

---

## 5 Grow & shrink

raidkm's `--grow` is **role-tagged**: each disk you list is added in the named
role, so you never compute the new device count yourself. Reshape is mdadm-only
— the dm/LVM path is gated off in the kernel.

| Command | Effect | Mechanism |
|---|---|---|
| `--grow --add-data <disks>` | add data disk(s) — capacity grows, m fixed | online kernel reshape, no backup file; both classic layouts |
| `--grow --raid-devices=N−1` | remove one data disk — capacity shrinks, m fixed | online backward COW; `--array-size` clamp first; one disk per invocation |
| `--grow --add-parity <disks>` | m → m+1, k fixed | parity-last: offline recreate. rotating: online COW reshape, one disk per run |
| `--grow --remove-parity` | m → m−1 (≥2 remain), k and capacity fixed | online COW re-encode in place; classic only, declustered refused |
| `--grow --raid-devices=N′` | declustered: widen or shrink the pool | online COW, re-tiles each row; shrink = one group per reshape |
| `--grow --spare-columns=s′` | declustered: change spare capacity, either direction | online COW on the fixed pool |

### Add capacity

```sh
mdadm --grow /dev/md70 --add-data /dev/ram5              # k=3 → 4, m unchanged
mdadm --grow /dev/md70 --add-data /dev/ram5 /dev/ram6    # k=3 → 5

# traditional stock forms — an untagged grow with explicit --raid-devices
# means "add capacity", so raidkm treats it as --add-data
mdadm --grow /dev/md70 --raid-devices=5 --add /dev/ram5  # one-line
mdadm /dev/md70 --add /dev/ram5 /dev/ram6                # …or add spares first
mdadm --grow /dev/md70 --raid-devices=6                  # …then grow into them
```

A bare `--grow --add <disks>` with **no** `--raid-devices` keeps the raidkm
shorthand of adding **parity**. An explicit `--add-data`/`--add-parity` always
wins, so use those when you want to be unambiguous.

Adding a data disk changes the stripe width, so every block relocates — a true
restripe, inherently O(data). The array stays readable and writable throughout
and needs no backup file, because the wider new layout writes behind the old
layout's read frontier. A crash resumes from the `reshape_position` checkpoint.

Because k changes, the ISA-L matrix and tables are rebuilt for the new k while
the old-k set is kept as `prev_ec_*` and selected per stripe, so I/O to pre- and
post-frontier stripes uses the right geometry for the whole reshape. Validation
for this deliberately used *degraded-read-after-grow*, not just scrub — scrub
masks a stale-table bug that a degraded read exposes.

> **A grow leaves no scar.** Steady-state IOPS on a grown k=4→5 array are
> statistically indistinguishable from an array *created* at k=5 (within ±4%
> across five workloads). The only cost of `--add-data` is the one-time reshape.
> Do remember the filesystem, though: after a grow that changes k the stored
> stride/stripe_width are stale and every write lands off-row — `mdadm --grow`
> prints the exact `tune2fs` refresh command, which is metadata-only.

### Add parity

```sh
# rotating: online, journaled COW reshape — one parity disk per run
mdadm --grow /dev/md70 --add-parity /dev/ram5             # m=2 → 3

# parity-last: offline recreate, no data movement, several at once
mdadm --grow /dev/md70 --add-parity /dev/ram5 /dev/ram6   # m=2 → 4

# fallback for kernels without the COW engine (offline, windowed, resumable)
MDADM_RAIDKM_OFFLINE_ADDPARITY=1 \
  mdadm --grow /dev/md70 --add-parity --backup-file=/var/tmp/rk.bak /dev/ram5
```

**Parity-last** keeps data on a fixed prefix and never relocates it, so adding
parity only appends a disk and recomputes parity. There is no in-kernel online
reshape for a parity-count change — it would alter `max_degraded` — so mdadm
does it offline but data-preserving: stop, recreate at the new m with the same
device order, `data_offset`, UUID and name, then let normal resync recompute
parity while the array is online. Usable throughout, but **not fully
fault-tolerant until the resync finishes**, and the brief stop+recreate is not
crash-safe. On non-identical disks the recreate must reuse the original
`data_offset`.

**Rotating** moves every block when m changes, so there is no cheap append.
raidkm drives an online journaled COW reshape entirely in the kernel: add the
disk, then migrate one band at a time, staging each band's new-geometry stripe
out-of-place in the metadata gap below a constant `data_offset` and journaling
STAGE→COMMIT→DONE before overwriting the band's home. Because no live block is
overwritten until its new copy is durably staged, correctness is
placement-agnostic — the read/write location-aliasing race that sank an earlier
in-place attempt is structurally impossible. `k` is unchanged, so `array_size`
and `data_offset` stay constant; only m (hence `max_degraded` and the parity
placement) changes.

To add a **hot spare** (not part of the array yet), use MANAGE-mode `--add`
without `--grow`: `mdadm /dev/md70 --add /dev/ram5`.

### Shrink

```sh
# 1. shrink the filesystem first, then clamp the array
mdadm --grow /dev/md70 --array-size=<kb>      # mdadm prints the exact value on refusal
# 2. now remove the disk
mdadm --grow /dev/md70 --raid-devices=4

# the freed member becomes a spare — zero it before reuse
mdadm /dev/md70 --remove /dev/ram5
mdadm --zero-superblock /dev/ram5
```

Every shrink is the same engine walked **backwards**: the narrower geometry
packs data deeper per disk, so the walk starts at the end and every home write
lands strictly below the still-live old rows — no backup file, no `data_offset`
shift. A mid-shrink stop or power loss recovers by plain `--assemble`, which
resumes the descending walk. Native-checksum arrays are included (band
verify-src plus CRC re-key).

> **Departing members are not auto-zeroed.** They hold a readable pre-shrink
> copy, and a member failure before you remove them will legitimately pull them
> back in as hot-spare rebuild targets. `--remove` and `--zero-superblock` them
> as part of the procedure, not later.

---

## 6 Declustered operations

A declustered array does not rebuild onto a single replacement. It **populates**
the lost content into the distributed spare columns, and later **rebalances** it
onto a fresh disk. Two distinct steps, each independently crash-safe.

### Population — rebuild into the spare

```sh
echo <failed-index> > /sys/block/md0/md/rk_dcl_populate
cat /sys/block/md0/md/rk_dcl_populate     # populating <X> -> spare <j> mark A/B

# or arm it automatically the moment a member fails (off by default, not persisted)
echo 1 > /sys/block/md0/md/rk_dcl_auto
```

Population runs as a raidkm-owned sync action with a crash-safe journaled prefix
mark (FUA + PREFLUSH every 16 MiB), so a power loss mid-rebuild resumes from the
mark on the next assembly. Up to `s` failures can be populated **sequentially**,
one at a time. Because a spare column can rotate onto *another* failed disk, the
slot→disk map resolves through the active assignments as a chain of redirects;
the on-disk journal is adaptive v2/v3 so an older module fails *closed* rather
than silently dropping an assignment.

### Rebalance — migrate back to a fresh disk

```sh
mdadm /dev/md0 --add /dev/sdp        # copy-from-spare onto the replacement
```

The array copies the already-reconstructed content straight from the distributed
spare onto the new disk: 16 parallel workers, **no GF decode**, and the array is
*never degraded* during it — reads are served live from the replacement below
the copy mark and from the spare above it, split at a strict-journaled per-band
mark. That is both faster and safer than a decode rebuild, and it falls back to
the validated decode leg on any persistent copy fault. When it completes the
spare columns are freed and the pool is whole again.

### Pool and group-geometry reshapes

```sh
mdadm /dev/md0 --add /dev/newdisk...        # add the new pool disks as spares
mdadm --grow /dev/md0 --raid-devices=N'     # widen the pool: more k+m groups per row

mdadm --grow /dev/md0 --add-parity <disks>  # m → m+1 (g → g+1); one disk per group
mdadm --grow /dev/md0 --add-data   <disks>  # k → k+1 (g → g+1); capacity grows
mdadm --grow /dev/md0 --spare-columns=s'    # s → s', either direction
mdadm --grow /dev/md0 --raid-devices=<N-g>  # pool shrink: remove one group's disks
```

Group width g, parity m and spare count s stay fixed across a pool expansion —
only the pool size and the permutation change, so `(N′ − s) mod g == 0` must
still hold and mdadm checks it. mdadm runs the acceptance search for the new
permutation seed, then the kernel migrates one band at a time, COW-staged and
journaled.

While the migration walks the array, the not-yet-migrated region is served by
**old-geometry stripes** — each stripe carries its own geometry (old group
width, old parity count, old EC tables), so concurrent reads and writes on
either side of the frontier are correct. That is the same mechanism as pool
expansion's dual permutation maps, applied on a different axis. Native-checksum
arrays run all of these online too: CRC store/verify is keyed by the stripe's
own geometry, and the band's CRC re-key runs inside the migrating row's
claim/quiesce bracket, so concurrent I/O never sees a stale key.

---

## 7 Checksums & healing

Enable with `--checksum` at create time — the reserved region is carved then, so
it is not a later switch. It composes with every layout, declustered included.

**Where the CRCs live.** Each member's tail carries a reserved region, about
0.1% of capacity, holding a CRC-32C per 4 KiB block in self-checking pages —
per-page CRC plus a generation trailer, so a rotted region page is *detected and
dropped, never trusted*. On a declustered array both reserves stack in the tail:
the `rkdcl` metadata block first, then the CRC region one chunk past the data
area.

**How reads verify.** Inline in the bio completion — a lock-free expected-CRC
lookup plus `crc32c`, no thread handoff — including a verified chunk-aligned read
bypass that serves an in-chunk read straight from the mapped disk without
touching the stripe cache. A fast-path mismatch is *never* trusted: it is
rechecked through the stripe cache before the self-heal fires. That read-first
design is what buys 100.0% of baseline random read; before it, random read sat
at 37%.

**Keying, and why it matters on a declustered pool.** CRCs are keyed by the
*physical pool disk* a block lives on, not its logical slot, so a block served
through the distributed-spare redirect still verifies against the disk it was
actually read from. The copy-from-spare rebalance *migrates* each block's CRC
alongside the bytes rather than recomputing it — so a torn or rotted copy is
copied verbatim but its original CRC travels with it, and the first read of the
new disk detects the mismatch and heals by decode.

**Cache sizing.** The region is served through a bounded demand-paged cache,
auto-sized at array start to cover every member's whole CRC region — roughly one
page per 4 MiB of member capacity — clamped to ~1.6% of RAM with a logged hint
when a huge array is clamped below full coverage. Undersizing costs region-page
faults, never correctness; override with `raidkm_csum_cache_pages`.

> **Crash semantics — know what you bought.** Native checksums recompute CRCs
> over the resync window after an unclean shutdown. That is the same class of
> guarantee as `dm-integrity` *bitmap*; dm-integrity *journal*'s crash-atomic
> tags are strictly stronger, and that guarantee is what its ~2× write cost
> buys. If torn-write atomicity across power loss is a requirement, native
> checksums are not the mechanism to reach for.

---

## 8 device-mapper & LVM

No new dm target was needed: `dm-raid` already stands up an `mddev` and runs
whatever personality `md_run()` selects by level, so level 71 rides the existing
target. Design and validation: [`notes/dm-raid-design.md`](../notes/dm-raid-design.md).

```sh
# dmsetup — 3 data + 2 parity (m=2), rotating, 512 KiB chunk, over 5 devices
dmsetup create kmtest --table \
  "0 <sectors> raid raidkm 3 1024 parity_count 2 5 - /dev/ram0 - /dev/ram1 - /dev/ram2 - /dev/ram3 - /dev/ram4"

dmsetup status  kmtest           # health string + sync_action + mismatch_cnt
dmsetup message kmtest 0 check   # scrub
```

Degrade a leg by suspend / reload-with-`- -` in the victim slot / resume;
rebuild by reloading with a fresh device plus a `rebuild <idx>` parameter.
`raidkm` is the rotating layout, `raidkm_n` parity-last.

```sh
# LVM — the managed path
lvcreate --type raidkm --paritycount 2 -i 3 -L 1G -n data vg   # 3 data + 2 parity
lvconvert --repair vg/data                                     # raidkm-aware leg replace + rebuild
lvchange --monitor y vg/data                                   # dmeventd auto-repair

# an LV is an ordinary cache origin — a fast tier over the EC capacity tier
lvconvert --type cache --cachevol fastvol vg/data
```

> **Reshape is mdadm-only.** The dm/LVM reshape path is out-of-place via
> `data_offset`, which does not fit raidkm's layout, so the kernel gate rejects
> dm reshape and **growing or shrinking a raidkm LV via LVM is unsupported**.
> Use `mdadm --grow` for every capacity or parity change. A hand-driven
> `dmsetup` grow corrupts — that is why the gate exists.

---

## 9 Convert from raid6

Stock RAID6 left-symmetric m=2 and raidkm rotating m=2 are byte-for-byte
identical on disk. Conversion therefore moves **no data** — it rewrites each
member's superblock level and layout, then reassembles.

```sh
sudo bash tools/raidkm-convert.sh /dev/md0             # raid6 → raidkm (rotating, m=2)
sudo bash tools/raidkm-convert.sh --reverse /dev/md0   # raidkm → raid6

# options: --no-assemble (rewrite SBs only) · --mdadm PATH · --yes
```

Only raid6 *left-symmetric* ↔ raidkm *rotating m=2* is convertible; anything
else is refused, because a wrong layout would silently corrupt. The array must
be stopped, and `raidkm.ko` loaded for the raidkm side to assemble. Once
converted, the array is an ordinary raidkm array — so `--add-parity` to m=3 is
then available, which is the usual reason to convert.

---

## Knob reference

### sysfs — per array, under `/sys/block/mdN/md/`

| Attribute | Purpose | Default |
|---|---|---|
| `worker_thread_cnt` | **Recommended knob.** Total worker threads for the array — the natural "I want N parallel workers" model | `nproc/2`, floor 2 |
| `group_thread_cnt` | Same state, stock-compatible view: threads *per* worker group. Either knob updates the other | auto |
| `skip_copy` | Zero-copy full-stripe writes (needs stable pages — free for O_DIRECT workloads) | `1` |
| `stripe_cache_size` | Leave alone. 256 → 8192 *lost* 15–25% on ramdisk | `256` |
| `preread_bypass_threshold` | Irrelevant to full-row writes | stock |
| `rmw_level` | Inherited raid5 RMW policy | stock |
| `sync_action` | `check` / `repair` / `idle` — scrub control | `idle` |
| `mismatch_cnt` | Read-only scrub result | `0` |
| `healed_blocks` | Read-only count of checksum-driven parity repairs | `0` |
| `rk_dcl_populate` | Declustered: write a failed index to arm population; read for state | — |
| `rk_dcl_auto` | Declustered: arm population automatically on member failure (not persisted) | `0` |
| `rk_dcl_reshape` | Declustered: reshape control/state | — |
| `stripe_cache_active` | Read-only occupancy | — |

Rounding caveat on `worker_thread_cnt`: the value is divided across
`num_possible_nodes()` groups with *ceiling* division, so the realized total can
exceed what you wrote — writing 5 on a 2-NUMA box yields 3 × 2 = 6, and the
read-back reflects 6. Never silently less parallelism than requested;
single-NUMA hosts are unaffected. Debug builds add `raidkm_reshape_inject`,
`raidkm_reshape_jtest`, `raidkm_reshape_maptest` and `raidkm_reshape_start`.

### module parameters — `raidkm.ko`

| Parameter | Purpose | Default |
|---|---|---|
| `default_group_thread_cnt` | Initial `group_thread_cnt` for new arrays; `0` disables worker groups | `-1` (auto) |
| `raidkm_csum_cache_pages` | Soft ceiling on resident CRC-region pages; `0` auto-sizes from geometry | `0` |
| `raidkm_csum_shards` | Checksum cache/verify shards — parallel verify workers; `0` = auto per-CPU, capped | `0` |
| `native_csum` | In-core CRC-32C with *no persistence* — a bring-up/debug path, not the shipping feature | `N` |
| `devices_handle_discard_safely` | Set only if every member reliably returns zeroes from discarded regions | `N` |

---

## Deployment checklist

Ordered by impact. Most of the md side is already the default — the wins are
geometry and layout decisions made **before** the array carries data. One-line
version: get k, the journal, and the partition offset right at build time;
everything else is already default or automatic.

**Decide once, at create time — a reshape is the only later fix:**

1. **Choose k so `k × chunk` is a power of two** — 256K, 512K, 1M. Large writes
   are almost always a power of two, so a row is only ever written whole if the
   row is one too. A width like k=5 @ 64K (320K) or k=14 @ 64K (896K) leaves a
   partial row at the tail of every write, at every chunk size, with no tuning
   available.
2. **Prefer declustered parity on wide pools** — it decouples pool width from row
   width, so an 80-disk pool keeps a small, easily-filled row instead of a ~5
   MiB one, and rebuilds far faster.
3. **Keep the 64K chunk default** unless deliberately trading for a specific row
   width.

**Storage layout:**

4. **Put the filesystem journal on a separate device** — the single largest win
   here.
5. **Start the partition or LV on a row boundary.** Nothing detects a violation
   at runtime; it silently phase-shifts every allocation.
6. **Keep other small, barriered write streams off the array** — same mechanism
   as the journal.

**Filesystem geometry:**

7. **Set stride/stripe_width** to match the array, or let `mkfs.ext4` derive them
   from `optimal_io_size`. Verify with `dumpe2fs -h <dev> | grep RAID`.
8. **After a grow that changes k, refresh them with `tune2fs`** — `mdadm --grow`
   prints the exact command.

**md tunables — verify, don't tune:**

9. `skip_copy` and worker groups are already on by default. On many-core hosts,
   raising `worker_thread_cnt` toward `nproc` may help concurrent writes —
   measure rather than assume.
10. `stripe_cache_size` (default fine) and `preread_bypass_threshold`
    (irrelevant to full-row writes) are not worth sweeping.

```sh
cat /sys/block/md70/queue/optimal_io_size    # = k × chunk; mkfs.ext4 picks this up unaided

# by hand: 4 KiB fs blocks, 64 KiB chunk → stride 16
mkfs.ext4 -b 4096 -E stride=$((chunk/4096)),stripe_width=$((k*chunk/4096)) /dev/md70

# after a grow that changed k — metadata only, no data rewrite; then remount
tune2fs -E stride=16,stripe_width=80 /dev/md70
```

On a *declustered* array `optimal_io_size` is the **data row**, not the pool
width: a 14-disk pool with g=6, m=2 advertises `4 × chunk`, not `12 × chunk`.
Grows that leave k unchanged — adding parity, expanding a pool — don't affect
filesystem geometry and print nothing.

### Move the journal off the array

Alignment fixes the *large* writes. What is left is usually a small, frequent
write stream sharing the array with them — and on a parity array that is
expensive out of all proportion to its size. By default the ext4/jbd2 journal is
a hidden inode *inside* the filesystem, so its commits land on the array
interleaved with the data. Those commits are small and sub-row, and every
sub-row write is a read-modify-write.

| Journal location | Array member reads | Journal device |
|---|---:|---|
| internal (on the array) | 43–50 MB / GiB written | — |
| **external (own device)** | **0.2 MB / GiB written** | 39 MB/GiB written, 0 read |

k=8 m=2 at 64 KiB chunk under streaming 1 MiB aligned O_DIRECT writes — same
filesystem, same workload, only the journal moved. Note the symptom this
produces if you don't know to look for it: the cost is nearly constant *per
transaction*, so it scales with commit rate rather than I/O size, and is easy to
mistake for a fixed per-write overhead somewhere in the block layer.

```sh
mke2fs -O journal_dev /dev/sdX          # format a device as an external journal
tune2fs -O ^has_journal /dev/md70       # drop the internal journal
tune2fs -J device=/dev/sdX /dev/md70    # point the filesystem at the new one
```

> **The journal device becomes a correctness dependency.** The filesystem will
> not mount without it, and losing it loses the journal. Give it durability at
> least equal to the array it serves — a mirror, or an SSD with power-loss
> protection. An internal journal is parity-protected; an external one is only as
> safe as the device you put it on. The rule generalizes past journals: **any
> small, frequent write stream co-located with large aligned writes will tax
> them.**

---

## Limits & gotchas

Each of these refuses rather than running wrong — but knowing them before you
plan a maintenance window is cheaper than discovering them in it.

| Limit | Detail | |
|---|---|---|
| Reshape through dm/LVM | Rejected by the kernel gate. Use `mdadm --grow`. A hand-driven `dmsetup` grow corrupts, which is why the gate exists. | refused |
| Reshape with members lost | *Reading through* faults during a reshape is supported; *completing* one after losing members mid-flight is not — `migrate_band` is non-degraded-read only. See `notes/reshape-cow-design.md` §6/§9. | scoped |
| File-backed bitmap on declustered | Refused. The internal bitmap and online member resize are supported. | refused |
| Multi-group pool shrink | One group's worth of disks per reshape; repeat for more. Online member-size shrink is also excluded. | scoped |
| `--remove-parity` on declustered | Refused — classic layouts only. | refused |
| PPL + bitmap | Mutually exclusive; PPL also costs 43–72% of write throughput on RAM-backed devices. | exclusive |
| parity-last add-parity window | The brief stop+recreate is **not crash-safe**, and the array is not fully fault-tolerant until the follow-on resync completes. On non-identical disks the recreate must reuse the original `data_offset`. | window |
| Stock mdadm | Rejects level 71, and `--examine` SIGABRTs on a raidkm member. Deploy the fork as `/usr/sbin/mdadm`. | hard |

---

## Test suite

The suites double as the acceptance gates. They create their own ramdisks and
load the module; point `MDADM` at the fork — they refuse a stock mdadm.

```sh
sudo MDADM=../mdadm/mdadm bash tools/raidkm-test.sh          # full regression suite

# individual gates
tools/raidkm-test-functional.sh        # create/write/read/scrub × both layouts × m=2/3/4
tools/raidkm-test-degraded.sh          # max-degraded reconstruction, read + write
tools/raidkm-test-grow.sh              # --add-data incl. degraded-read-after-grow, --add-parity
tools/raidkm-test-shrink.sh            # backward COW walk (+ -crash variant)
tools/raidkm-test-reshape-concurrent.sh  # I/O across a throttled reshape (dual EC tables)
tools/raidkm-test-reshape-crash.sh     # power-loss / torn-write recovery (fault-inject build)
NATIVE=1 tools/raidkm-test-selfheal.sh # checksum-driven heal (or dm-integrity by default)
NATIVE=1 tools/raidkm-test-csum-thrash.sh  # CRC-region cache eviction round-trip
tools/raidkm-test-declustered-*.sh     # ~30 declustered gates: map, io, populate, rebalance, reshape…

# benchmark harness: 6 fio workloads + a rebuild/populate wall-clock item
tools/raidkm-standard-benchmark.sh --runs=3 --rebuild-victim=/dev/ram2
```

The **reshape crash/fault suite** needs a `CONFIG_RAIDKM_FAULT_INJECT` kernel
and runs five tiers — clean reshape, crash-and-resume at each phase × band, torn
STAGE/COMMIT, hybrid fault tolerance (frozen mid-reshape: the migrated region
survives `m_new` failures and the pending region `m_old`, each probed on its own
array), and torn COMMIT concurrent with a member failure. **114 passed / 0
failed on both base and GFNI.** Without the fault-inject build it auto-runs Tier
0 plus a best-effort timed crash.

The **self-heal suite** writes data, injects *silent* corruption directly on the
raw backing store, and verifies reconstruction on both the read path and the
scrub — data-only, parity-only and mixed, up to m per stripe, confirming
`healed_blocks` advances. `NATIVE=1` additionally covers
detection-after-remount from the persisted CRC region and rotted-region-page
handling (no false heal). The default mode stacks raidkm on `dm-integrity`
members and needs `integritysetup` from the `cryptsetup` package.

> **Harness traps worth knowing.** Raw-member probes must use the member's
> logical block size (`blockdev --getss`), not a hardcoded 512-byte O_DIRECT —
> two harness bugs surfaced only on 4K-logical devices. And `scrub=0` is not
> proof of EC correctness: it can mask a stale-table bug that only a *degraded
> read* exposes. Test the decode.

---

Sources: [`README.md`](../README.md), `km/raid_km.c`, `km/raid_km.h`,
`km/raid_km_dcl.h`, `km/raid_km-reshape.c`, `tools/`, and the `raidkm-level71`
mdadm fork (`24e99c1b`). Benchmark figures are as recorded in the tree, each
with its harness and hardware named alongside. GPL-2.0-only.
