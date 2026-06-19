# Memory optimization (KSM + zram)

<sub>[Home](../README.md) · [Architecture](architecture.md) · [Requirements](requirements.md) · [IPI vs agent](ipi-vs-agent.md) · [Fidelity](fidelity.md) · [Disconnected](disconnected.md) · [Variables](variables.md) · [Examples](examples.md) · **Memory** · [Troubleshooting](troubleshooting.md)</sub>

Every node boots the same RHCOS image, so most guest RAM is identical or cold.
Two host features let a cluster's nominal RAM far exceed what it actually
consumes, without touching the host OS: **KSM** (dedup) and **zram** (compress).
`make optimize` turns them on with a per-VM cgroup squeeze; `make optimize-undo`
reverts.

## The pipeline

How a page of guest RAM is handled, in order:

1. **KSM (dedup).** The kernel samepage-merging daemon scans the VMs' active RAM
   and merges identical pages (zero pages, shared libraries, the same RHCOS files
   across nodes) into one copy-on-write page. This shrinks the footprint before
   anything is compressed.
2. **cgroup wall (libvirt hook).** `hooks/qemu` intercepts each VM at launch,
   finds its transient `machine-qemu-*.scope` (cgroup v2), and caps it with
   `memory.high`. The host OS and other processes stay on raw RAM, unrestricted.
3. **The squeeze (`memory.high`).** When a VM exceeds its cap the kernel reclaims
   that VM's coldest pages early instead of OOM-killing. Reclaimed anonymous pages
   go to swap.
4. **zram (compress).** The host swap is a compressed-RAM block device (zstd by
   default). The reclaimed cold pages compress into RAM, never touching disk.

Net effect: identical pages collapse (KSM), cold pages compress (zram), and the
host kernel does it transparently per-VM.

## zram vs zswap

| | **zram** | **zswap** |
|---|---|---|
| What | a compressed RAM block device used **as swap** | a compressed **cache in front of** a real (disk) swap device |
| Backing | none, stays in RAM | needs a disk swap device; spills cold pages to it |
| Disk I/O | never | yes, on writeback / overflow |
| Pool size | up to its disksize | capped (`max_pool_percent`); overflow goes to disk |
| Use when | no disk swap, want pure-RAM density | want a RAM cache plus a disk overflow backstop |

For a single KVM host that just wants more effective RAM (no desire to hit disk),
**zram is the right choice** and is what this lab targets. Layering zswap in front
of a zram swap is pointless (double compression); pick one.

## Enable / disable

```bash
make optimize        # KSM + zram + per-VM cgroup hook
make optimize-undo   # revert (KSM off + unmerge, lift memory.high, remove hook)
```

`scripts/optimize-host.sh apply` does three things:

* **KSM**: `ksmtuned` if packaged, else `run=1` directly.
* **zram**: verifies `/dev/zram0` is an active swap (creates one sized to RAM if
  the host has none and `zramctl` is available).
* **hook**: installs `hooks/qemu` to `/etc/libvirt/hooks/qemu`. On VM start it sets
  `memory.high` to `VMETAL_MEM_HIGH_PCT`% (default 60) of the VM's RAM.

Reboot the VMs (`make down` / `make up`) so the hook squeezes them.

### Persist across reboots (runtime settings reset otherwise)

* KSM: enable `ksmtuned.service`.
* zram: a `zram-generator` config at `/etc/systemd/zram-generator.conf`.
* swappiness: a `sysctl.d` drop-in (note: some distros, e.g. CachyOS, set an
  aggressive `vm.swappiness=150` at runtime that proactively swaps even with free
  RAM; lower it if you want the cluster to stay in RAM until truly pressured).

`make check` warns when KSM, zram, or the hook is off.

## Tuning knobs

| Knob | Where | Effect |
|------|-------|--------|
| `VMETAL_MEM_HIGH_PCT` | hook env (default 60) | uncompressed-RAM cap per VM; lower = more aggressive eviction to zram |
| `ZRAM_COMP` | optimize-host.sh (default zstd) | zram compression algorithm |
| `vm.swappiness` | sysctl | how eagerly the kernel swaps anon pages (0 = only under real pressure) |
| `SQUEEZE_PCT` / `BENCH_ALGOS` | bench env | squeeze cap and algorithms swept in the benchmark |

## Benchmark

`make bench` (`scripts/bench-memory.sh`) runs an identical CPU workload
(`openssl speed` from a UBI image) on the cluster under each setting and records
host memory + guest throughput; `scripts/plot-bench.py` renders the chart.

To make the comparison honest the harness:

* forces `vm.swappiness=0` and `swapoff`s zram for the **baseline / KSM** states,
  so they are provably swap-free (the cluster must fit in RAM, so size it to fit);
* **unmerges** KSM (`run=2`, not just `run=0`, which leaves pages merged) and waits
  for it to drain between states;
* lets each optimization reach **steady state before measuring**: KSM scans
  aggressively to convergence then dials the scan rate down (an aggressive scan
  *during* the run cut throughput ~4x); zram fills until eviction settles;
* sweeps the zram algorithm by resetting the device (`swapoff` -> `reset` ->
  `comp_algorithm` -> `swapon`), so each algo starts from an empty device.

### Results

Measured on a 3 control-plane + 2 worker cluster (92 GiB allocated, 128 GiB host):

![memory optimization benchmark](bench.png)

| setting | host RAM | **saved vs baseline** | KSM merged | zram data → compr | ratio | swap | CPU (M k/s) |
|---------|---------:|----------------------:|-----------:|------------------:|:-----:|-----:|------------:|
| baseline | 117.8 GiB | n/a | 0 | n/a | n/a | **0** | 24.5 |
| KSM | 92.6 GiB | **25.2 GiB** | 27.0 GiB | n/a | n/a | 0 | 24.5 |
| zram (zstd) | 94.6 GiB | **23.2 GiB** | 0 | 35.6 → 12.9 GiB | **2.8×** | 37 GiB | 24.3 |
| KSM + zram (zstd) | 90.9 GiB | **26.9 GiB** | 11.9 GiB | 25.6 → 9.3 GiB | 2.7× | 26 GiB | 24.5 |
| zram (lz4) | 100.3 GiB | **17.5 GiB** | 0 | 33.4 → 16.3 GiB | 2.0× | 35 GiB | 24.5 |
| KSM + zram (lz4) | 96.7 GiB | **21.1 GiB** | 8.3 GiB | 29.0 → 14.5 GiB | 2.0× | 30 GiB | 24.4 |

Takeaways:

* **KSM** reclaims ~27 GiB by deduping the identical RHCOS pages across nodes. Its
  effect shrinks under active load, where pages diverge and copy-on-write breaks
  the merges (KSM-saved drops in the `ksm+zram` rows because the squeeze also pushes
  pages to zram, leaving fewer resident pages to dedup).
* **zram** compresses cold pages **2.8x with zstd** vs **2.0x with lz4**; lz4 is
  faster but less dense, zstd is the better default here.
* **Performance is flat (~24.5M)** across all settings: at steady state KSM and
  zram cost effectively no throughput.
* **Total saved vs baseline**: KSM + zram (zstd) reclaims **~27 GiB** of the
  117.8 GiB baseline (KSM alone 25 GiB, zram-zstd alone 23 GiB). Combining helps
  a little; zstd over lz4 helps more on the zram side.

## Disk

The node disks are qcow2 with `cache=none` + `io=native` (direct I/O), plus
`discard=unmap` + `detect_zeroes=unmap`. Direct I/O is deliberate here: a host
page cache (`cache=writeback`) would compete for the very RAM that KSM and zram
work to free, so it is counterproductive in a memory-dense lab. If you have RAM to
spare and want faster disk, set `disk_cache: writeback` + `disk_io: threads`
(caches in host RAM, honours flushes); `unsafe` is fastest but loses data on a host
crash (fine only for a throwaway cluster). `discard`/`detect_zeroes` let the thin
qcow2 shrink as the guest frees blocks. Disk settings apply when the domain is
defined, so a running cluster needs `make down` / `make up` to pick them up.

## Caveats

* The benchmark cluster must **fit in RAM at baseline** (swap off), or the baseline
  pods cannot run. Size nodes accordingly (`master_memory_mib` / `worker_memory_mib`).
* Switching the zram algorithm requires draining the device back to RAM; if the host
  is full this fails, so the algo sweep needs headroom (the harness warns and keeps
  the current algo rather than crashing).
* These are host tunables, not part of the install. They are safe to toggle on a
  running cluster and only affect the lab VMs' cgroups, never the host OS.
