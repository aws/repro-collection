# memcached newidle-balance regression, verified run - 2026-08-07

The reference result set: the first run measured end to end by the code as it now stands, on a 2-LLC AMD part, across the two reboots the kernel A/B requires.

## Result

| Kernel | max QPS under 1 ms p99 SLO |
|---|---:|
| GOOD 6.1.148-173.267 | 796,930 |
| BAD 6.1.150-174.273 | 708,819 |
| **Regression (bad vs good)** | **-11.1%** |

**This is a single iteration per variant** -- one BAD measurement and one GOOD measurement, not a repeat of either, so no error bar is implied. Two other runs of the same kernel pair are in this directory: [20260804](../20260804-lancet-verified) measured -20.0% (bad 732,764 vs good 915,749) and the [reverification](../20260807b-lancet-reverify) measured -17.8% (bad 757,816 vs good 921,774). Run-to-run spread is 6.9% on BAD and 15.7% on GOOD; read the magnitude as roughly 10-20% at this instance size.

Both variants at 2,000,000 records, `binary-search` mode, SLO p99 <= 1000 us, `LANCET_NUM_RUNS=2`, `LANCET_RUN_LENGTH=60`. The p99 at each converged point was 882.5 us (bad) and 966.8 us (good), each with a 95% confidence interval under 4% of the value, so neither score sits on an unmeasured percentile.

## Mechanism

`newidle-deltas.txt` carries the `/proc/schedstat` newidle load-balance counters, summed over all 32 scheduler domains, delta across the measurement window. The bad kernel attempts newidle balancing about 90x less often and pulls about 308x fewer tasks. That is the commit doing what it says - scaling the newidle budget by the domain's average load - and it is why the tail latency rises and the sustainable QPS falls. Raw snapshots are committed alongside so the numbers can be recomputed.

## Setup

5 hosts, us-west-2, stock AL2023 2023.12 from the `kernel-6.1` AMI line, least-privilege instance profile (SSM core only), security group permitting intra-group traffic only.

- SUT: c7a.4xlarge (AMD EPYC 9R14, 16 vCPU, **2 L3 instances** confirmed via `lscpu`)
- Coordinator: c7a.xlarge
- Throughput agents: 2x c7a.4xlarge
- Latency agent: c7a.2xlarge

Kernels installed with `dnf` from the AL2023 repos (`SCENARIO_KERNEL_MODE=al2023`).

## What was checked against the machine

- **Each variant ran on its intended kernel.** `uname -r` reported 6.1.150 for bad and 6.1.148 for good, and `sut-provenance-<variant>.txt` recorded the kernel, arch, vCPU count and record count from the SUT itself.
- **The dataset was loaded both times.** `Loaded 2000000 records` on each variant before the coordinator was signalled.
- **The coordinator measured the variant the SUT reported**, not a variant it assumed: the SUT sends its label over the control channel and the results file is named from that label.
- **Each score came from a converged search.** The bisect probes are visible in the run log, with achieved throughput within 0.03% of the offered rate at every probe.

## Note on the earlier result set

An earlier run on 2026-08-04 measured -20.0% (bad 732,764 vs good 915,749) with the same kernel pair and record count, using the code before it was simplified. The bad-kernel figures agree closely (708,819 vs 732,764, about 3%); the good-kernel figures differ more (796,930 vs 915,749), which moves the delta. Both runs are n=1 per variant on separate fleets, so the honest reading is that the regression reproduces and is large, with the magnitude varying run to run in the 10-20% range on this instance size. Quote this set, since it is the one the committed code produced.
