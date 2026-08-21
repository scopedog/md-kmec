# KCSAN data-race gate for md-kmec — GCP runbook

Catches the data-race class that KASAN/lockdep cannot: unmarked shared accesses
on raidkm's lock-elided fast paths (skip_copy aliasing, stripe-head recycling,
the live `group_thread_cnt` worker_groups swap, the declustered redirect map,
the heal/preread atomics). Separate kernel build from the KASAN gate —
**KCSAN and KASAN are mutually exclusive.**

Files: `tools/kcsan.config` (config fragment), `tools/raidkm-test-kcsan-stress.sh`
(stress harness, reuses `raidkm-test-lib.sh`).

## 1. Test machine

Prefer a **real-NVMe** box — NVMe timing widens the store-vs-worker windows a
ramdisk hides, so races reproduce far better than on brd. You want local NVMe
(at least `NDISK`+1 devices, passed via `RK_DEVS`) plus a kernel build
toolchain; a cloud instance with local SSDs works well, as does bare metal.

brd also works for a first smoke — the harness falls back automatically when
`RK_DEVS` is unset — but do the confirming run on NVMe.

## 2. Build the KCSAN kernel

In the mdraid-super umbrella (builds kernel → symvers → raidkm
→ mdadm in the right order):

```
cd ~/mdraid-super
scripts/kconfig/merge_config.sh -m kernel/.config md-kmec/tools/kcsan.config   # adjust path to your kernel src
make olddefconfig
make            # umbrella build; KCSAN instruments the whole kernel + raidkm
sudo make install install-modules   # or your usual install target
```

Toolchain: GCC ≥ 11 or Clang ≥ 14 (KCSAN needs `-fsanitize=thread`). Verify
`CONFIG_KCSAN=y` landed and did **not** silently drop because KASAN was still set
(`grep KCSAN\\\|KASAN kernel/.config` — exactly one should be `=y`).

Boot into it with aggressive sampling (KCSAN is 1-in-N sampled; the default
`skip_watch=4000` is too sparse for a targeted md run):

```
sudo grubby --update-kernel=/boot/vmlinuz-<ver> \
  --args="kcsan.skip_watch=250 kcsan.udelay_task=500 kcsan.udelay_interrupt=20"
sudo reboot
```

After reboot confirm it's live: `ls /sys/kernel/debug/kcsan` must exist.

## 3. Run

```
cd ~/mdraid-super/md-kmec        # RAIDKM_KO resolved by the lib

# NVMe device list — NOTE the layout is ONE controller with many namespaces
# (nvme0n1..nvme0n16), so glob /dev/nvme0n*, NOT /dev/nvme*n1:
NVME="$(ls /dev/nvme0n* | tr '\n' ' ')"

# Enable KCSAN at runtime FIRST (EARLY_ENABLE=n kernel; nonzero udelay is
# REQUIRED — get_random_u32_below(0) under DELAY_RANDOMIZE divides by zero):
sudo mount -t debugfs none /sys/kernel/debug 2>/dev/null
echo 250 | sudo tee /sys/module/kcsan/parameters/skip_watch
echo 80  | sudo tee /sys/module/kcsan/parameters/udelay_task        # MUST be >0
echo 20  | sudo tee /sys/module/kcsan/parameters/udelay_interrupt   # MUST be >0
echo on  | sudo tee /sys/kernel/debug/kcsan

# Pass env THROUGH sudo (plain `sudo VAR=x` is eaten) with `sudo env`; also point
# ISAL_KO at the fork's isa-l. KCSAN slows everything ~10-50x, so keep DURATION
# modest. rotating m=2 + m=4 on NVMe:
sudo env RK_DEVS="$NVME" ISAL_KO="$HOME/mdraid-super/kernel/isa-l/isal_lib.ko" \
     NDISK=8 MSET="2 4" DURATION=120 \
     bash tools/raidkm-test-kcsan-stress.sh

# declustered:
sudo RK_DEVS="$(ls /dev/nvme*n1 | head -14 | tr '\n' ' ')" \
     LAYOUT=declustered DCL_N=14 DCL_G=6 DCL_M=2 DURATION=300 \
     bash tools/raidkm-test-kcsan-stress.sh

# quieter reports (whitelist KCSAN to md/raid symbols):
sudo RK_DEVS="$NVME" KCSAN_FOCUS=1 ... bash tools/raidkm-test-kcsan-stress.sh
```

The harness drives concurrent 4k-random + full-stripe-aligned + read fio load
while chaos loops churn gtc / stripe_cache_size / skip_copy / scrub / fail+rebuild,
then scrapes the ring buffer.

## 4. Verdict & triage

- **PASS**: zero KCSAN splats whose stack touches `raid_km|raid5|md_|dcl|skip_copy|
  stripe_head|worker_group|…`. Unrelated global splats are counted but not failed
  (KCSAN finds races all over the kernel; only ours gate).
- Every splat is saved: `$RK_TMP/kcsan/splat-<label>-N.relevant.txt` (ours) and
  `.global.txt` (rest); full ring buffer in `dmesg-<label>.txt`.
- KCSAN is **sampling-based** — one clean run is weak evidence. Run the gate
  repeatedly / for long windows; a real race eventually trips. Treat first PASS as
  "no race seen yet," not "race-free."

## 5. Two-sweep discipline

1. **First sweep**: `CONFIG_KCSAN_STRICT=n` (default in the fragment) — low noise,
   catches the egregious races.
2. **Second sweep**: rebuild with `CONFIG_KCSAN_STRICT=y` and
   `CONFIG_KCSAN_REPORT_VALUE_CHANGE_ONLY=n` — forces every unmarked shared access
   on the fast paths to justify itself with `READ_ONCE`/`WRITE_ONCE`/`data_race()`.
   Expect more hits; each is either a real bug or a spot that needs an explicit
   annotation documenting why it's safe.

## Known-suspect sites to check first if a splat fires

- `async_copy_data` / `ops_run_biodrain` ↔ `handle_stripe_clean_event`:
  `dev->page` vs `dev->orig_page` across the skip_copy borrow/restore.
- `raid5_wakeup_stripe_thread` / `do_release_stripe` ↔ `raid5_get_active_stripe`:
  stripe count==0 ⟹ on-a-list invariant (the group-lock design's atomicity bug).
- the `group_thread_cnt` store handler ↔ `raid5d`/worker dispatch: worker_groups
  pointer swap (prior live-gtc UAF; verify the quiesce bracket covers the reader).
- `km_dcl_resolve` (redirect map) ↔ populate/rebalance assignment publish.
- `conf->healed_blocks` / `stat_w_preread` atomics vs their readers.
