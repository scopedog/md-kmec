# Device-mapper (dm-raid) support for raidkm — design

Status: **Phases 1, 2, 3 & 4a/b/d done; 4c (LVM reshape) is the remaining
piece.** Phase 3 (reshape) — originally gated off because dm-raid's
`data_offset` engine corrupts the rotating layout — is **DONE 2026-06-10 via
the COW-staged engine instead** (see `notes/reshape-cow-design.md`): mdraid
branch `raidkm-dm-reshape` lifts the parse gate (data-disk grow + add-parity;
shrink still rejected), pins a CONSTANT data_offset whose front gap hosts the
COW scratch/journal, and follows the same two-step activation contract lvm2
uses for raid456 (a `delta_disks [+ parity_count m+1] data_offset N` reload
stamps the reshape into the superblocks; the next final-geometry reload runs
it).  Validated `tools/raidkm-test-dm-reshape.sh` 34/34 + dm-rebuild 23/23
(base).  Historical Phase-3 "out of scope" text below kept as written.
Phase 1
(create/IO/degraded/scrub/reassembly) IMPLEMENTED, validated, and SHIPPED
(mdraid master `baa4cdc`, scopedog/mdraid, 2026-06-04). Phase 2
(rebuild onto a replacement member) validated 2026-06-05 with **no further
dm-raid.c change** (see §7). **Phase 4 (LVM2 userspace) done 2026-06-05** in the
`scopedog/lvm2` fork (branch `raidkm`): `lvcreate --type raidkm
--paritycount N` provisions a level-71 LV, `lvconvert --repair` rebuilds a leg,
and dmeventd auto-monitors/auto-repairs — all validated on base + GFNI (see §7
Phase 4). Phase 3 (reshape) is **out of scope**: dm-raid's `data_offset`
out-of-place reshape hits raidkm's rotating-layout aliasing corruption; only
mdadm offline windowed relocation is correct (the kernel parse gate stays).
Scope: make raidkm (md
level 71, k+m Reed-Solomon) drivable through device-mapper's `dm-raid` target,
so it can be created with `dmsetup` (and later LVM) instead of only via the
raidkm-aware mdadm + `/dev/mdN`.

Recon done against `mdraid/md/dm-raid.c` (4165 lines) and
`md-kmec/km/raid_km.c` (the level-71 personality). Line numbers below are from
dm-raid.c at commit time and are indicative, not load-bearing.

> **Implementation summary (Phase 1).** ~170 lines added to
> `mdraid/md/dm-raid.c`, shipped in `baa4cdc`. `dmsetup create ... raid raidkm
> <chunk> parity_count <m> <#devs> <pairs>` stands up a level-71 array.
> Validated on **.144** (GFNI: create + I/O consistent) and **.122.19**
> (md-kmec-rhel10, base/no-GFNI AVX2; same kernel 6.12.0-124.8.1, so .144
> modules relay directly):
> - **create + full sync + I/O** round-trips consistently.
> - **degraded read** EC-correct: m=2 (fail data0), m=3 (fail 2 data disks) —
>   degraded SHA == healthy SHA on the base/region-mul decode path.
> - **scrub** (`dmsetup message <dev> 0 check`) → mismatch count (status
>   field $9) = 0.
> - **parity-last** (`raidkm_n` → algorithm 0x002, no rotating bit): 1-disk
>   degraded reconstruct correct.
> - **reassembly**: `dmsetup remove` then recreate same devices → array comes
>   up `AAAAA idle` from the SB with **no resync**, data survives; the SB is
>   authoritative over the table. Code-reviewed clean, no regression to other
>   levels.
>
> Build/load recipe (.144): build dm-raid.o **isolated** in `~/dmrtest`
> (`obj-m := dm-raid.o` + symlinked `~/mdraid-src/md/*.h` +
> `KBUILD_EXTRA_SYMBOLS=~/mdraid-src/Module.symvers`) — the full md/Makefile
> M= build fails modpost "missing MODULE_LICENSE" (pre-existing, hits ORIGINAL
> too). Load matching `~/mdraid-src/raid456.ko` (CRC 0x803d0777) **before**
> dm-raid.ko, plus the rotgfni raidkm.ko + isal_lib. Bug fixed during bringup:
> do NOT route raidkm's stripe-cache through raid456's `raid5_set_cache_size`
> (GPF — raidkm conf is not an r5conf); kept recovery_cp + discard inclusions.
>
> dm status positional fields used: $8 = sync_action, $9 = mismatch_cnt.

---

## 1. What device-mapper / dm-raid actually is

Device Mapper (dm) is the kernel framework that builds virtual block devices by
mapping I/O through pluggable *targets* (`struct target_type`: `.ctr`, `.map`,
`.dtr`, `.status`, `.message`). It is the layer under LVM, dm-crypt, dm-thin,
dm-integrity, multipath — and **dm-raid**.

`dm-raid.c` does **not** reimplement RAID. It stands up an in-memory `struct
mddev` and runs whichever md personality matches `mddev->level`, driving the
*same* raid5.c-lineage code that mdadm arrays use. LVM RAID LVs are exactly
this. The on-disk metadata is dm-raid's own `struct dm_raid_superblock`
(managed by the kernel/LVM), **not** the mdadm v1.x superblock.

Consequence: "dm support for raidkm" = teach the existing bridge to parse,
size, validate and persist **level 71**. It is a *front-end / provisioning*
integration, not a data-path change — it adds no performance and no new RAID
capability; raidkm already provides the erasure coding via md today.

---

## 2. Core decision — extend `dm-raid.c`, do not write a new target

The raidkm I/O engine is the md personality; rewriting it under a raw dm target
would reinvent dm-raid. So:

- The personality is selected automatically inside `md_run()` by
  `mddev->level == 71`. **dm-raid needs no per-level engine wiring.** As long
  as raidkm.ko is loaded/registered, `md_run` finds it.
- `raid_map()` → md is already level-agnostic; the bio path needs no changes.
- All work is in the ctr/parse/size/validate/persist/status surface.

---

## 3. Two structural facts that make this clean

### 3.1 `m` and layout already live in `mddev->layout`

raidkm packs parity-count and the rotating bit into the layout word
(`raidkm_layout_m()`, `raidkm_layout_is_rotating()`, `RAIDKM_LAYOUT_*` in
raid_km.c). dm-raid persists geometry straight from the mddev:

- `super_sync` (dm-raid.c:2152-2153): `sb->level = mddev->level`,
  `sb->layout = mddev->layout` (+ `new_level`/`new_layout` at 2161-2162).
- `super_init_validation` (dm-raid.c:2263-2264): restores them verbatim.

⇒ **No new superblock fields.** The existing `level`/`layout`/`new_level`/
`new_layout` carry raidkm's m + layout for free, including across reshape.

### 3.2 `incompat_features` is a ready-made safety latch

`super_validate` (dm-raid.c:2484-2487) already rejects any non-zero
`incompat_features`:

```c
if (sb->incompat_features) {
    rs->ti->error = "Unable to assemble array: No incompatible feature flags supported yet";
    return -EINVAL;
}
```

⇒ Writing a `FEATURE_FLAG_RAIDKM` bit there makes **a stock dm-raid kernel
refuse a raidkm device** instead of misinterpreting level 71. Our fork accepts
exactly that one bit. Safe, forward/backward, no format guesswork.

> **As shipped:** `FEATURE_FLAG_RAIDKM` went in as `0x1` (the design proposed
> `0x2`). It works — stock dm-raid rejects any non-zero incompat — but a high
> bit (e.g. `0x80000000`) would be safer against a future upstream incompat-bit
> collision. Changing it is an on-disk format change; cheap now (nothing
> deployed). See hardening item 2 in §7.

---

## 4. The one real friction: variable `m` vs fixed `parity_devs`

`struct raid_type.parity_devs` is a per-type *constant*. raidkm's `m` is
variable (2..8). But `parity_devs` is read at only **4 functional sites**:

| line | function | use |
|---|---|---|
| 742  | `raid_set_alloc` | floor: `raid_devs <= parity_devs` reject |
| 1030 | `validate_raid_redundancy` | rebuild cap: `rebuild_cnt > parity_devs` |
| 1583 | `mddev_data_stripes` | `raid_disks - parity_devs` |
| 1589 | `rs_data_stripes` | `raid_disks - parity_devs` |

Fix: one helper, used at the sizing/redundancy sites:

```c
static unsigned int rs_parity_devs(struct raid_set *rs)
{
    return rs_is_raidkm(rs) ? raidkm_layout_m(rs->md.new_layout)
                            : rs->raid_type->parity_devs;
}
```

Ordering note: `raid_set_alloc` runs *before* `parse_raid_params`, so `m` is
not yet known there. Keep its check coarse (use `minimal_devs`) and add the
precise `m`-vs-#devices check immediately after parsing `parity_count`.

---

## 5. Concrete change map (all `dm-raid.c` unless noted) — ALL SHIPPED in `baa4cdc`

| Area (line) | Change |
|---|---|
| `raid_types[]` (~290) | add `{"raidkm", "raidkm (k+m Reed-Solomon)", 0, 3, 71, 0}` — `parity_devs=0` sentinel (real m via param), `minimal_devs=3`, `level=71` |
| classifiers (401-488) | add `rs_is_raidkm()` / `rt_is_raidkm()` (`level==71`); audit `rs_is_raid456`/`rs_is_reshapable` callers and fold raidkm in where it must behave like parity RAID (stripe cache, recovery, reshapability) |
| `__valid_flags` (492) | add `RAIDKM_VALID_FLAGS` ≈ RAID6 set: sync/nosync, rebuild, region_size, stripe/chunk, delta_disks, data_offset, (later) the raidkm params |
| `get_raid_type_by_ll` (669) | `if (level == 71) return <raidkm type>` — match on level only (layout holds m/rotating, not an `ALGORITHM_*`) |
| `parse_raid_params` (1130) | add `parity_count <m>` (required for raidkm, 2..8) and `raidkm_layout rotating|parity_last`; set `mddev->new_level = 71` and encode `mddev->new_layout` via the raidkm helpers |
| `validate_raid_redundancy` (1008) | raidkm branch: tolerate up to `m` missing/rebuilding members |
| sizing (1583/1589) | use `rs_parity_devs()` |
| `super_sync` (2114) | when `level==71`: `sb->incompat_features = cpu_to_le32(FEATURE_FLAG_RAIDKM)` |
| `super_validate` (2461) | accept `incompat == FEATURE_FLAG_RAIDKM` (else keep rejecting) |
| `super_init_validation` (2241) | works as-is (restores level/layout); verify `get_raid_type_by_ll` reassignment at 2293/2300-2301 returns the raidkm type |
| `raid_ctr` (3009) | extend the `rs_is_raid6(rs) && nosync` new-array guard (3125) to raidkm; rest of the flow is unchanged |
| `raid_status` / `raid_message` (3522/3728) | emit/parse `raid raidkm ... parity_count <m> [raidkm_layout rotating] ...`; sync-state reporting is largely reusable |
| new `#define` | `FEATURE_FLAG_RAIDKM` (incompat_features) — **shipped as `0x1`**; high bit safer (hardening item 2) |
| header glue | dm-raid.c must see `raidkm_layout_m()`/`_is_rotating()`/`RAIDKM_LAYOUT_*`. Put the encode/decode inlines + bit defs in a small shared header both dm-raid.c and raid_km.c include (e.g. `raid_km_layout.h`), to avoid duplicating the encoding. |

---

## 6. Table-line format (`dmsetup`)

```
<start> <len> raid raidkm <#params> \
        parity_count <m> [raidkm_layout rotating] [region_size <s>] [chunk <s>] \
        <#devs> <meta0> <data0> <meta1> <data1> ...
```

Example — k=4 data, m=3 parity, rotating, 7 metadata/data device pairs:

```
0 <sectors> raid raidkm 4 parity_count 3 raidkm_layout rotating \
        7 /dev/.../meta0 /dev/.../data0 ... meta6 data6
```

After create, the superblock carries level/layout, so reload/assembly needs no
params (matching how dm-raid handles other levels).

---

## 7. Phasing

- **Phase 1 — create + I/O + degraded read + scrub via `dmsetup`** ✅ **DONE
  (`baa4cdc`, 2026-06-04).** Everything in §5 except reshape. Validated on .144
  (GFNI) + .122.19 (base): create/sync/I/O, degraded read EC-correct (m=2 &
  m=3), scrub mismatch=0, parity-last 1-disk, reassembly with no resync (SB
  authoritative). See the implementation summary at the top. No LVM.

  Phase-1 hardening leftovers (all OPTIONAL, none blocking; carried forward):
  1. `mddev_data_stripes()` uses `rs_parity_devs(new_layout)` but its doc says
     "as of superblock" — only matters for Phase-3 add-parity (current m !=
     new m); fix then.
  2. `FEATURE_FLAG_RAIDKM` is `0x1` (design said `0x2`); a high bit is safer —
     see §3.2 note. On-disk format change, cheap now.
  3. A mismatched table `parity_count`/layout is silently resolved to the SB
     with no error — add an explicit "raidkm geometry immutable" reject for UX.
  4. Dead code: `raidkm_layout_is_rotating()` + `RAIDKM_LAYOUT_KNOWN` unused
     (harmless).

- **Phase 2 — rebuild** onto a replacement member ✅ **DONE (2026-06-05).**
  Table reload with a fresh (zeroed) device in the victim slot + a
  `rebuild <idx>` param → md's recovery thread reconstructs it via raidkm's
  k+m decode; `raid_status` shows `aA` health + `recover` progress, settling
  to all-`A` + `idle`. **No dm-raid.c change needed** — the rebuild path is
  level-agnostic and the Phase-1 `validate_raid_redundancy` branch already
  caps redundancy at `rs_parity_devs()` = m. Validated on .122.19 (base/no-GFNI)
  via `tools/raidkm-test-dm-rebuild.sh`: rotating + parity-last, four oracles
  each (return-to-full, readback SHA, scrub mismatch=0, max-degraded reconstruct
  — the strong oracle proving the rebuilt slot is EC-correct, not merely
  scrub-consistent). 16/16 at m=2,3 (Vandermonde path) plus 24/24 at m=4,5,6
  (`MS="4 5 6"`, the Cauchy m≥4 path) — 40/40 total.

  Gotchas found during bringup:
  - **REQUIRES the post-f99d8f2 raidkm.ko** (m=2 rotating rebuild parity fix).
    A stale module rebuilds the data role of a rotating slot correctly (data
    reads back fine) but mis-rebuilds the *parity* role → scrub reports a
    nonzero mismatch on exactly those stripes. The loose `~/raidkm.ko` on the
    VM predated the fix and reproduced this (mismatch=17408); the tree-built
    module (srcversion `2A87C1C…`) is clean. Use the current tree modules, not
    the relayed loose `.ko`.
  - **`dmsetup table` GP-faulted on any raidkm device — FIXED (mdraid
    `f776778`).** Originally mis-attributed to an "oversized table length
    panic": the trigger was actually the trailing `dmsetup table` in the repro
    script, and it reproduces on *any* raidkm array regardless of LEN.
    `raid_status()`'s STATUSTYPE_TABLE path dereferenced `rs->raid_type->name`
    directly; `raid_type` sits right after the embedded `struct mddev` in
    `struct raid_set`, and a trailing md-core write clobbers its low 2 bytes
    once the array runs, so `rs->raid_type` points 2 bytes into the correct
    `raid_types[]` entry → `%s` on a garbage name pointer → GP fault
    (`string+0x48` ← `vsnprintf` ← `raid_status+0x74f`). Only TABLE hit it;
    INFO/IMA already re-derive the type via `get_raid_type_by_ll()`. Fix: do
    the same lookup in TABLE. Verified: table now round-trips, rebuild suite
    20/20. (Debugged via the libvirt serial-console log
    `/tmp/md-kmec-rhel10-console.log` — `console=ttyS0` captures the oops
    pre-kdump-reboot; the loose `~/*.ko` were stale, so this needed a fresh
    build from current source: `make -C $KDIR M=md KCFLAGS="-include
    md/compat-rhel10.h" raid456.ko dm-raid.ko` in one invocation for matching
    CRC `0x803d0777`.)

    Follow-up — chunk-alignment guard **DONE (mdraid `1c99ccd`).** A table
    length whose per-disk size isn't a chunk multiple used to produce a dm
    device larger than the array's chunk-rounded capacity (the personality
    rounds `dev_sectors`), leaving an unmaintained tail region beyond
    `resync_max` (observed: a 600000-sector table reading past the 599808 the
    array backs, silently, no fault). `rs_set_dev_and_array_sectors()` now
    rejects it with `-EINVAL` ("raidkm target length not a multiple of (data
    disks x chunk size)") for raidkm. Validated: misaligned 600000 rejected,
    aligned 196608/393216 fine, rebuild suite 21/21.
- **Phase 3 — reshape**: 🚫 **GATED OFF — PERMANENT (out of scope).** Originally
  gated "until Phase 4 (LVM)", but Phase 4c proved LVM does NOT fix it: dm/LVM
  `data_offset` out-of-place reshape silently corrupts raidkm regardless of who
  drives it (see Phase 4c in §7). Kernel hooks remain in place as dormant
  groundwork (`477ff7a`); reshape stays refused at parse (`0dc0e46` →
  `9bcfed5`). **Do NOT lift the gate.** raidkm reshape is mdadm-only.
  - **Why gated:** dm-raid reshape is out-of-place via `data_offset`
    repositioning, which only LVM drives correctly (it allocates and positions
    the reshape space). A hand-driven `dmsetup` data-disk **grow** on a
    normally-created array (data at offset 0) is wrong by construction and
    **corrupts** — verified on .144 (pre/post SHA differ). Data-disk **shrink**
    is additionally unimplemented in the raidkm personality (it inherits
    raid5's generic `check_reshape()`, which mechanically accepts
    `delta_disks < 0` and would leave the array inconsistent — verified: 4-disk
    view over k=3 data, no reshape, no error). So **any `delta_disks` reshape
    is rejected** in `parse_raid_params()` (the only reliably-reached point;
    the `rs_check_reshape()` guard is *not* hit for a reshape table that
    super-resolves to the SB).
  - **Dormant groundwork (do NOT lift):** raidkm is wired into
    `rs_is_reshapable()`, the `rs_check_reshape()` allow-list + a grow-only
    guard (reject layout/chunk/placement change and `delta_disks < 0`), and the
    `reshape=true` branch of `rs_prepare_reshape()` — so it *could* ride
    dm-raid's engine like raid456. **Phase 4c proved this engine corrupts raidkm
    (data_offset aliasing), so the parse gate stays — the groundwork is left
    dormant, not lifted.** The md add-data *engine* is fine via mdadm's
    backup-file in-place path (EC-table rebuild on a k change is mdadm-validated);
    it is specifically the dm `data_offset` out-of-place path that corrupts.
  - Test: `raidkm-test-dm-rebuild.sh` asserts both grow and shrink reloads are
    refused (`53/53` GFNI, `23/23` base incl. the reject checks). The disk-add path is level-agnostic
    and the EC-table rebuild on a k change lives in the personality (already
    mdadm-validated). Confirmed on .144: a 6-device + `delta_disks 1` reload is
    accepted (passes the gates — no "bogus raid type"/"only supported"
    rejection); no regression (rebuild suite 21/21).
  - **THE CATCH (this was the "highest risk"):** dm-raid reshape is **NOT**
    backup-file based — it's **out-of-place via `data_offset` repositioning**
    (`rs_adjust_data_offsets`). A forward add-disk reshape needs free space at
    the *start* of each device, i.e. data must already live at `data_offset>0`.
    That placement (allocate reshape space, position data) is what **LVM
    orchestrates**; a normally `dmsetup`-created array has data at offset 0, so
    hand-driving the reshape is wrong by construction and **corrupts** —
    verified on .144 (pre/post SHA differ). This is not a raidkm bug (raid456
    behaves identically); it just means **dm add-data can only be faithfully
    exercised through LVM (`lvextend`) — Phase 4**. The md add-data engine
    itself is already validated via the mdadm reshape path.
  - **add-parity** (m change) / **placement change**: **rejected.** Both ride
    `mddev->layout`; `rs_check_reshape()` refuses a raidkm reshape with
    `new_layout != layout`. An m change needs an offline save/recreate@m+1/
    restore migration dm-raid can't do. Caveat: an m change requested via a
    plain table reload is silently resolved to the SB *before* this guard
    (no-op, not corruption) — same class as Phase-1 hardening item 3.
- **Phase 4 — LVM2 userspace** (`lvcreate --type raidkm`): ✅ **DONE 2026-06-05**
  in the `scopedog/lvm2` fork (branch `raidkm`, forked at tag
  `v2_03_32` = the VMs' deployed 2.03.32). Build userspace from tree; **never
  `make install`** over system lvm (VM root is on LVM); test against a scratch VG
  on brd/dm-linear PVs with an isolated `--config` device filter so the system
  `rhel` VG is untouched. Sub-phases:
  - **4a create/activate/I/O** ✅. Metadata model: two segtypes `raidkm`
    (rotating) + `raidkm_n` (parity-last), each storing integer `parity_count`
    (= m, 2..8) per LV segment, modeled on raid10 `data_copies` (segtype
    `parity_devs` registered 0; real m carried per-LV). `lvcreate --type raidkm
    --paritycount N -i K` emits the same dm table Phases 1–2 validated. Commits:
    `2c15e54` (segtype + libdm table-gen), `5a76fc6` (alloc threading), `8ba3c0d`
    (lvcreate CLI — MVP works), `7cdb341` (k≤m parity-alloc fix, e.g. m=4 k=4).
    Validated .122.19 (base) + .144 (GFNI): active `AAAAA` synced, I/O SHA
    round-trip, `lvchange -an/-ay` reassembly, max-degraded reconstruct, m=2/3
    (Vandermonde) + m=4 (Cauchy/ISA-L), both layouts. libdm gotcha: `SEG_RAIDKM`
    must be in BOTH the `_emit_segment_line` target switch AND the
    `_emit_areas_line` raid case, else "unknown target type" / "Cannot understand
    number of raid devices".
  - **4b `lvconvert --repair`** ✅ (`5597eff`): raidkm-aware repair via a
    `_raid_parity_devs(seg)` helper (`seg->parity_count` for raidkm) at
    `_data_rimages_count` + the two repair tolerance guards (which short-circuit
    on `parity_devs==0`); `_for_each_pv` passes raidkm data-count to
    `_calc_area_multiple` (else returns 1 → `build_parallel_areas` overruns
    rimage). Repair = kernel `rebuild <idx>` recovery (the validated Phase-2
    path), NOT reshape — no aliasing risk. Validated .122.19 with the FULL oracle
    on m=2 AND m=4: replace failed leg → rebuild onto spare, data preserved,
    scrub=0, degraded-read-after-repair (fail m OTHER legs, keep rebuilt leg)
    reconstructs → rebuilt leg EC-correct.
  - **4c reshape (`lvextend`/`lvconvert --stripes`)**: ❌ **OUT OF SCOPE.** Same
    conclusion as Phase 3: dm/LVM `data_offset` out-of-place reshape silently
    corrupts raidkm (rotating-layout read/write location-aliasing). mdadm
    `--grow --add-data` (backup-file, in-place) preserves data + degraded-read
    EC-correct; dm/LVM does not. No viable kernel-only fix (a synchronous-reshape
    bound was disproven). raidkm reshape stays **mdadm-only**; the kernel parse
    gate (`9bcfed5`) is kept, NOT lifted. The reshape-enabling LVM changes were
    discarded; the `_raid_parity_devs`/`_calc_area_multiple` raidkm-awareness
    that 4b needs was kept.
  - **4d dmeventd monitoring** ✅ — **NO raidkm code change** (zero commits; lvm2
    stays @ `5597eff`). The dmeventd raid plugin + `dm_get_status_raid` are
    level-agnostic: they parse the raidkm health string and run `lvconvert
    --repair --use-policies` generically. The only requirement is a
    **raidkm-aware in-process `liblvm2cmd`** — an INSTALLED fork has this for
    free. Validated full cycle .122.19 (`raid_fault_policy="allocate"`, spare
    PV): `lvchange --monitor y` → `monitored`; fail a leg (dm-error) → dmeventd
    logged "Device #N of raidkm array … has failed" and AUTO-relocated the leg
    onto the spare in ~2s → `AAAAA`; data preserved + degraded-read-after-repair
    EC-correct (strong oracle). From-tree TEST gotcha (env-only, NOT a raidkm
    bug): lvm's privileged exec of dmeventd STRIPS `LD_LIBRARY_PATH`, so the
    auto-started daemon loads the *system* (stock) `liblvm2cmd` → repair fails
    "Unrecognised segment type raidkm"; fix for testing = point dmeventd config
    `executable=` at a wrapper that re-exports `LD_LIBRARY_PATH`/`LVM_SYSTEM_DIR`
    then `exec`s the real dmeventd (do NOT redirect its fds — that breaks the
    startup-readiness pipe and `lvchange` hangs).

---

## 8. Risks / open questions

- **Reshape-model mismatch (Phase 3)** — RESOLVED/CHARACTERIZED: dm-raid uses
  `data_offset` out-of-place reshape, not raidkm's mdadm-style backup-file. The
  kernel gates are enabled (`477ff7a`) so raidkm rides the same engine as
  raid456, but execution needs LVM's reshape-space orchestration (Phase 4). m
  change stays offline-only (rejected for dm reshape).
- **`raid_status` positional fields** — LVM parses status positionally;
  adding raidkm fields must not break the generic parser. Low-stakes for
  Phase 1 (dmsetup-only), must be designed carefully before Phase 4.
- **Where the code ships** — dm-raid.c lives in the mdraid kernel tree
  (`mdraid/md/`). The change is built into kernel/md there; raidkm.ko stays the
  separate personality. At runtime it is just "level 71 personality
  registered," identical to the md path. The md-kmec build already resolves the
  raidkm/isal symbols; dm-raid only needs the layout inlines (§5 header glue).
- **No data-path benefit** — this is provisioning/management only; the EC,
  performance, and resilience all come from the unchanged raidkm engine.

---

## 9. Why bother (recap)

Buys LVM-managed raidkm volumes and clean composition with other dm targets
(dm-integrity under raidkm to *detect* corruption before EC reconstructs from
it; dm-crypt; dm-cache). The operational payoff lands with Phase 4 (LVM2). For
pure dm stacking (integrity/crypt over a raidkm device) you can already layer
dm over `/dev/mdN` today without any of this — dm-raid is specifically the path
to *LVM-managed* raidkm.
