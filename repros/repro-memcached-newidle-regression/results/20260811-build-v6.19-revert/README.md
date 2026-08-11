# memcached newidle-balance regression, build mode - single-commit A/B - 2026-08-11

The only result set that isolates the culprit commit itself. Both kernels are mainline **v6.19** built from source on the same host; GOOD differs from BAD by exactly the revert in `patches/v6.19/`. The other result sets compare the AL2023 6.1.148 and 6.1.150 packages, which differ by a whole package version rather than one commit.

## Result

| Kernel | Build | max QPS under 1 ms p99 SLO |
|---|---|---:|
| GOOD | v6.19 + revert (`6.19.0-d0e1da115`) | 885,884 |
| BAD | v6.19 as-is (`6.19.0-05f7e89ab`) | 791,893 |
| **Regression (bad vs good)** | | **-10.6%** |

A single iteration per variant, like every other set in this directory. Both at 2,000,000 records, `binary-search` mode, SLO p99 <= 1000 us, `LANCET_NUM_RUNS=2`, `LANCET_RUN_LENGTH=60`. The p99 at each converged point was 973.7 us (bad) and 1003.5 us (good), each with a 95% confidence interval under 1.7% of the value.

## Why this set matters

The AL2023 sets bracket the same effect at -11.1% to -20.0%, but 6.1.148 vs 6.1.150 is a package-version difference that carries more than the one commit. Here BAD and GOOD are the same tag built on the same machine minutes apart, differing only by `git am` of the revert -- and the recorded build revisions differ (`05f7e89ab` vs `d0e1da115`), which is how the scenario proves the revert actually applied. -10.6% on a single-commit difference sits at the low end of the AL2023 range, which is what you would expect if the package delta contributes a little on top.

## Mechanism

`newidle-deltas.txt` carries the `/proc/schedstat` newidle counters. With the commit present the balancer attempts newidle balancing 9.3x less often and pulls 12.6x fewer tasks. Note that v6.19 emits schedstat **version 17**, whose field layout differs from the version 15 the 6.1 kernels emit -- the file documents both offsets, because parsing one with the other's offsets produces wrong numbers that still look plausible.

## Setup

5 hosts, us-west-2, AL2023 2023.12. SUT c7a.4xlarge (AMD EPYC 9R14, 16 vCPU, 2 L3 instances), 120 GB root to hold the kernel tree and two builds. Coordinator c7a.xlarge, 2 throughput agents c7a.4xlarge, 1 latency agent c7a.2xlarge. `SCENARIO_KERNEL_MODE=build`, `SCENARIO_KERNEL_TAG=v6.19`, shallow clone of the tag.

Each kernel takes about 9 minutes to compile on this SUT; the full A/B including both builds, two reboots and two searches ran well over two hours.

## Two things this run found

**A bootable kernel is not automatic.** `make install` on AL2023 wrote a bare `/boot/vmlinuz` with no initramfs, and grub then looked for `initramfs-vmlinuz.img`, did not find it, and stopped at the boot prompt -- unrecoverable without console access. The scenario now installs a versioned `vmlinuz` plus a `dracut`-generated initramfs, registers a matching grub entry, and verifies both exist and are the default before asking for a reboot.

**Agent SSH limits matter at high offered rates.** Lancet's agent-manager redeploys the agents over SSH on every probe. An early attempt at the GOOD variant exhausted the default `MaxStartups` and seven probes above 774k failed to run at all; the scoring guard refused to report the converged 774k because the ceiling was bounded by failures rather than by the SLO. Raising `MaxStartups` on the agents cleared it. Without that guard the run would have reported GOOD as slower than BAD.
