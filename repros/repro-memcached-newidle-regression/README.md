# Repro: memcached regression from "sched/fair: Proportional newidle balance"

Reproduces the memcached regression introduced by upstream Linux commit `33cf66d88306` ("sched/fair: Proportional newidle balance"), first present in mainline **v6.19**. On CPUs with more than one last-level cache (LLC) the new proportional newidle balancer pulls fewer tasks across LLCs under memcached's bursty wakeup pattern, inflating tail latency under load and lowering the QPS sustainable under a latency SLO.

Four A/B runs on an AMD c7a.4xlarge (2 LLC), all at 2,000,000 records and a 1 ms p99 SLO:

| Run | Kernels compared | BAD | GOOD | Delta |
|---|---|---:|---:|---:|
| [2026-08-11 build mode](results/20260811-build-v6.19-revert) | mainline v6.19 +/- the revert (**single commit**) | 791,893 | 885,884 | **-10.6%** |
| [2026-08-07 reverification](results/20260807b-lancet-reverify) | AL2023 6.1.150 vs 6.1.148 | 757,816 | 921,774 | **-17.8%** |
| [2026-08-07](results/20260807-lancet-verified) | AL2023 6.1.150 vs 6.1.148 | 708,819 | 796,930 | **-11.1%** |
| [2026-08-04](results/20260804-lancet-verified) | AL2023 6.1.150 vs 6.1.148 | 732,764 | 915,749 | **-20.0%** |

**Each figure is a single iteration per variant.** The build-mode run is the one that attributes the effect to the commit itself: BAD and GOOD are the same mainline tag compiled on the same host minutes apart, differing only by `git am` of the revert in `patches/`, and the scenario records the two build revisions so a silently-failed revert cannot be measured as an A/B. The three AL2023 runs compare 6.1.148 against 6.1.150, a package-version difference that carries more than the one commit; their spread is 6.9% on BAD and 15.7% on GOOD. Read the magnitude as roughly 10-20% at this instance size, with the single-commit measurement at the low end of that range.

The `/proc/schedstat` newidle counters show the mechanism directly and in the same direction in every run that captured them: with the commit present the balancer attempted newidle load balancing about 9.3x less often on the single-commit v6.19 pair, and about 90x and 975x less often on the AL2023 pair, pulling far fewer tasks across LLCs in each case. Note that v6.19 emits schedstat version 17 while the 6.1 kernels emit version 15, and the two layouts put the newidle counters at different offsets -- each result set documents which it used. The effect was originally reported in the 5-11% range on other kernel and instance combinations.

## Load generator: Lancet (why not memtier)

This scenario drives the [`memcached-lancet`](../../workloads/memcached-lancet) workload (EPFL Lancet). memtier_benchmark was also built, validated as a working memcached load generator, and run against the exact kernels below -- and found insufficient to reproduce this regression. It was not ruled out on theory; it was tried and measured.

Both workloads were run against the same kernels on the same AMD c7a.4xlarge hardware:

| Load generator | Kernels | Result |
|---|---|---|
| memtier (peak + fixed-rate throughput) | mainline v6.19 vs v6.19+revert | -0.55% / -2.1% — within noise (raw data not committed) |
| memtier (peak + fixed-rate throughput) | AL2023 6.1.148 vs 6.1.150 | -0.31% / -0.38% — within noise |
| **Lancet (max QPS under 1ms p99 SLO)** | AL2023 6.1.148 vs 6.1.150 | **796,930 -> 708,819 (-11.1%)**, and 915,749 -> 732,764 (-20.0%) on an earlier run |

memtier is closed-loop and measures latency on the same connections it uses to generate load, so a cross-LLC scheduling penalty tends to be averaged into throughput. Lancet is open-loop with a **separate latency agent** that samples tail latency independently while other agents saturate the server, so the p99 knee — where this regression lives — is visible. For this class of scheduler regression the load generator looks like the load-bearing choice.

One caveat, and it is the honest limit of the memtier comparison: the memtier sweeps were driven with an LDG at only 2x the SUT's vCPUs (below this repo's own 4x saturation guidance) and peaked around 670k QPS, so they never reached the ~750k knee where the Lancet effect appears. The memtier null is therefore consistent with either closed-loop averaging or simply not driving hard enough. What is solid: on the exact kernel pair and instance, the regression is large under Lancet and absent under memtier at the operating points reached.

The regression shows up first as tail latency. In the 2026-08-07 run the bad kernel crossed the 1 ms p99 ceiling at about 710k offered QPS while the good kernel was still at 758 us at 774k; the max-QPS-under-SLO figure is downstream of that. Both variants are measured on the same fleet within one scenario invocation, so each pair is internally comparable.

The lightweight `memcached` (memtier) workload remains useful for general throughput benchmarking and as a low-dependency, single-LDG option; it is simply not sufficient for *this* regression.

## Topology requirement (read this first)

The regression is **specific to multi-LLC CPUs**. It reproduces on AMD EPYC parts that expose multiple Core Complex Dies (CCDs), each with its own L3. It does **not** reproduce on single-LLC parts.

| Instance | Cores / topology | Reproduces? |
|---|---|---|
| c7a.4xlarge (AMD EPYC 9R14) | 16 cores, **2 CCDs / 2 L3** | yes — measured, see [Results](#results) |
| c8g.4xlarge (Graviton4) | single L3 | not expected (~0%) — not measured here |
| c7i.4xlarge (Intel) | single socket, 1 L3 | not expected (~0%) — not measured here |

The single-LLC rows follow from the mechanism (there are no cross-LLC pulls to throttle) and from where the regression was originally observed; this repro has no committed single-LLC control run, so treat them as expectations rather than results.

Confirm the SUT has 2 L3 caches before trusting a result:

```
for c in /sys/devices/system/cpu/cpu*/cache/index3/id; do cat $c; done | sort -u | wc -l   # expect 2 on c7a.4xlarge
```

## The A/B kernels

Two modes, selected with `SCENARIO_KERNEL_MODE`:

**`al2023` (default)** — no compile: `dnf install` the exact AL2023 kernel pair the regression was first observed on. This is the default because it is the only mode any committed result in [`results/`](results) was produced with, it needs no kernel build (minutes instead of ~35-40 min per kernel), and `dnf` handles grub and the initramfs so the boot path is not hand-managed:

| Variant | Kernel | Notes |
|---|---|---|
| **BAD** | `kernel-6.1.150-174.273.amzn2023` | the backport carrying the culprit |
| **GOOD** | `kernel-6.1.148-173.267.amzn2023` | the version just before it |

The trade-off: these two kernels differ by a whole patch release, not just the culprit, so strictly this mode shows "the regression appeared between 6.1.148 and 6.1.150" rather than attributing it to a single commit. In practice this is the highest-fidelity reproduction of what was actually observed in the field, and `build` mode below is available when single-commit attribution is what you need.

**`build`** (experimental) — compile mainline `v6.19`; the two kernels differ by exactly one commit:

| Variant | Kernel | Contains culprit? |
|---|---|---|
| **BAD** | mainline `v6.19` as-is | yes |
| **GOOD** | mainline `v6.19` + `git revert 33cf66d88306` | no |

The other newidle regression of the same era (`155213a2aed4` "sched/fair: Bump sd->max_newidle_lb_cost when newidle balance fails") was already reverted upstream before v6.19, so isolating this commit requires reverting exactly one commit. Reverting `33cf66d88306` on `v6.19` applies with no conflicts.

This mode is the cleaner experiment in principle — a one-commit delta — but it is marked experimental here because no committed result set was produced with it: each kernel takes ~35-40 min to build, and a custom kernel on EC2 must have ENA in the initramfs or the instance boots without networking (see `util/kernel_from_src.sh`). Expect to validate the boot path yourself before trusting a run.

## Scheduler statistics (mechanism evidence)

The throughput result says *that* the regression happens; these counters say *why*. The SUT snapshots `/proc/schedstat` immediately before and after the measurement window and reports the delta, so a run carries the load-balancer behaviour alongside the QPS number.

The relevant counters are per scheduling domain, grouped by idleness, and the group that matters here is "cpu was just becoming idle" — the newidle balancer the culprit commit modifies. On a 2-CCD part `domain0` spans one CCD (intra-LLC) while the next domain spans both (cross-LLC), so compare the same domain index between kernels. The summary prints call count, "load did not require balancing", failures, tasks pulled, and pulls per 1000 newidle calls; a kernel that balances across LLCs less shows fewer pulls for the same offered load.

Artifacts on the SUT, one set per kernel variant so the two can be compared: `schedstat-before-<variant>`, `schedstat-after-<variant>`, `schedstat-newidle-<variant>.json` (machine-readable deltas), and `sut-provenance-<variant>.txt` (kernel, arch, vCPUs, LLC count, record count — the SUT is the only host that knows these, so the coordinator's results JSON deliberately does not claim them). No schedstat artifact is committed under `results/` yet: collection was added after the reference run, so the counters are produced by a run but not yet part of the committed evidence. Set `MEMCACHED_COLLECT_SCHEDSTAT=false` to skip, or `MEMCACHED_SCHEDSTAT_DIR` to relocate them. Collection enables `/proc/sys/kernel/sched_schedstats` for the run (the counters do not accumulate otherwise) and restores it in cleanup.

Note that `perf sched stats` is deliberately not used: it is a recent subcommand and unavailable on the stock AL2023 kernels this repro pins, whereas `/proc/schedstat` carries the same newidle counters and needs no extra tooling.

## Build mode notes

`build` mode compiles `SCENARIO_KERNEL_TAG` twice: BAD is the tag as-is, GOOD is the tag plus the revert in `patches/`. `util/kernel_from_src.sh` applies it with `git am` and stamps `LOCALVERSION=-<gitrev>`, so `uname -r` distinguishes the two builds and the scenario refuses to continue if the revert failed to apply (both variants would otherwise be the same kernel).

Verified on AL2023 2023.12 (c7a.8xlarge, x86_64), 2026-08-06: the revert applies cleanly to `v6.19` (11 hunks, 6 files, +4/-64), the kernel builds and installs as `6.19.0-<gitrev>`, and the variant gate matches the revert's revision and not the tag's. Two dependency gaps surfaced there and are handled in `scenario:install:sut`: `kernel_from_src.sh` builds perf and treats a perf failure as fatal *before* installing the kernel, and on AL2023 perf needs an interpreter named `python` (the distro provides only `python3`) plus `libtraceevent-devel`. Without those the kernel compiles but never installs.

`al2023` mode needs none of this -- it installs the pinned kernel pair with `dnf` and is the path all committed results used.

## Sources

- External link — [torvalds/linux commit 33cf66d88306 "sched/fair: Proportional newidle balance"](https://github.com/torvalds/linux/commit/33cf66d88306663d16e4759e9d24766b0aaa2e17) — accessed 2026-07-31
