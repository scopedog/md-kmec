# raidkm AVX-512-GFNI validation + RHEL 10.2 port findings (2026-06-12)

Validated the in-kernel AVX-512-GFNI EC path on **real Sapphire Rapids** (first-ever — the prior
GFNI coverage was AVX2-GFNI only on an i5-1340P; the KVM testbed has no GFNI). Host: GCP
`c3-standard-4` (Spot), **RHEL 10.2**, kernel `6.12.0-211.20.1.el10_2`, **Xeon Platinum 8481C**
(`avx512f/bw/vl` + `gfni` + `vaes`). Instance torn down after the run.

## What PASSED (EC / AVX-512 correctness — the goal)
- `isal_lib.ko` loaded reporting **`(GFNI AVX-512)`** — CPU dispatch selected the AVX-512 path.
- `isal_test.ko`: **`k+m AVX-512 PASS (ec_encode_data_avx512_gfni matches base for 11 configs up to
  k=16 m=8)`** — byte-for-byte vs the `*_base` reference, in-kernel. (+ AVX2 PASS 8 configs, GFNI/base PASS.)
- `raidkm.ko` builds (4.1 MB), loads, registers at level 71: `Personalities : [raid4] [raid5] [raid6] [raidkm]`
  (coexists with stock raid456).
- `tools/raidkm-test-ec-mds.sh`: **PASS** — "every raidkm (m,k) code is MDS" (in-kernel matrix check).

**Conclusion: the AVX-512-GFNI EC math is correct on real hardware.** The same `_mm512_gf2p8affine`
C-intrinsics kernels are also validated in the isa-l upstreaming tree
(`~/projects/isa-l/notes/gcp-avx512-validation-2026-06-12.md`).

## What's BLOCKED: array-level I/O suite (functional / degraded / replace)
All fail at `mdadm --create` — **NOT an EC fault** (see above), a RHEL-10.2 port bug. See issue #3.

## RHEL 10.2 port findings (mainline raidkm targets 10.1; 10.2 drifted)
The build/run needed three changes. **#1 and #2 mirror the upstream changes and are the real port
fix; both were applied as throwaway LOCAL edits on the now-destroyed test instance — reproduce from
here.** #3 is unresolved.

### #1 — `gendisk->sync_io` removed (build) — fix in the **mdraid** fork (`md/`)
10.2 dropped `struct gendisk::sync_io`. Two sites, mirror upstream (no-op writer; reader uses
`part_stat` only):
- `md/md.h` `md_sync_acct()`: drop `if (blk_queue_io_stat(...)) atomic_add(nr_sectors, &bdev->bd_disk->sync_io);`
  → no-op body.
- `md/md.c` `is_mddev_idle()`: `curr_events = (int)part_stat_read_accum(disk->part0, sectors) -
  atomic_read(&disk->sync_io);` → drop the `- atomic_read(&disk->sync_io)` term.
(`raid456.ko`/`raid5.c` build fine — they don't reference these directly; only the shared `md.h`
inline + `md.c` reader do.)

### #2 — `raid6_empty_zero_page` → `raid6_get_zero_page()` (build) — fix in **md-kmec** (`km/raid_km.c`)
10.2 replaced the global `raid6_empty_zero_page` with the accessor `raid6_get_zero_page()` (returns
`void *`; compiler literally suggests it). Only `raid_km.c` uses it — two sites (~lines 2555, 2688),
both cast the result: replace the token `raid6_empty_zero_page` → `raid6_get_zero_page()`.
NB: do it in `raid_km.c`, **not** via a global compat macro — a macro corrupts `pq.h`'s own
declarations of that symbol.

### #3 — fresh `mdadm --create` aborts in `run()` (UNRESOLVED — needs debugging)
Every fresh create of a level-71 array (reproduced on **pristine** ramdisks, so not stale
superblocks) fails:
```
mdadm: RUN_ARRAY failed: Invalid argument
dmesg: md/raid:md70: not clean -- starting background reconstruction
       md/raid:md70: unsupported reshape required - aborting.
       md: pers->run() failed ...
```
The message is `km/raid_km.c:10410`, inside `run()`'s reshape-recovery block — which is only entered
when the kernel thinks a reshape is in progress (`mddev->reshape_position != MaxSector`), and there
it aborts because `mddev->new_level != mddev->level`. On a *fresh* create neither should be true.
**Hypothesis:** a RHEL 10.1→10.2 md-core change in how the v1.2 superblock's `reshape_position` /
`new_level` fields are loaded into `mddev` (or a fork-mdadm SB-write interaction). The reshape gate
itself is behaving correctly (reshape is out-of-scope); the bug is upstream of it — bogus reshape
state on a clean create. **Next step:** compare what the fork mdadm writes (`mdadm --examine`) against
the `if (mddev->reshape_position != MaxSector)` entry condition and the 10.2 v1.2 SB load path; this
is personality-port work, independent of the (proven-correct) EC path.

## Reproduction (build recipe used)
On a c3 SPR, RHEL 10: `dnf install kernel-devel-$(uname -r) gcc make nasm git fio elfutils-libelf-devel systemd-devel`.
Layout `mdraid/` `md-kmec/` `mdadm/` as siblings. Build: `make -C mdraid` (isal_lib.ko + Module.symvers),
then `make -C md-kmec MDRAID_BUILD=../mdraid` (raidkm.ko + isa-l symlinks), then `make -C mdadm`
(branch `raidkm-level71`). Load deps with `modprobe raid456` (pulls async_tx/raid6) before `insmod raidkm.ko`,
else: `Unknown symbol raid6_call / async_gen_syndrome / ...`.
