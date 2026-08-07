# memcached newidle-balance regression, earlier run - 2026-08-04

An earlier run, kept for comparison with [20260807-lancet-verified](../20260807-lancet-verified). It measured **-20.0%** where the later run measured -11.1% on the same kernel pair and record count. **Each is a single iteration per variant**, so the two are not repeats and the pair is not an error bar. This run predates a simplification of the workload and scenario, and its emitted JSONs carry 11 keys where the current code writes 13 -- the scores, dataset parameters and SLO in them are the measured values and are unaffected. Cite the 2026-08-07 run, which the committed code produced.

## Result

| Kernel | max QPS under 1 ms p99 SLO |
|---|---:|
| GOOD 6.1.148-173.267 | 915,749 |
| BAD 6.1.150-174.273 | 732,764 |
| **Regression (bad vs good)** | **-20.0%** |

Both variants measured at **2,000,000 records** (the workload default), so the two are like-for-like. Scenario default binary-search mode, SLO p99 <= 1000 us, `LANCET_NUM_RUNS=2`, `LANCET_RUN_LENGTH=60`.

## Setup

5 hosts, stock AL2023, least-privilege instance profile (SSM-core only), us-west-2. SUT c7a.4xlarge (AMD EPYC 9R14, 16 cores, **2 L3 instances** confirmed via `lscpu` before the run). Coordinator c7a.xlarge, 2 throughput agents c7a.4xlarge, 1 latency agent c7a.2xlarge. Kernels installed with `dnf` from the AL2023 repos.

## What was verified, and how

Each of these was checked against the machine rather than taken from a log message, because the review that preceded this run found several failure modes that produced confident-looking output from a broken measurement.

- **Both variants ran on their intended kernel.** The scenario's kernel gate reported `Running kernel is the 'bad' variant (6.1.150-174.273...)` and `Running kernel is the 'good' variant (6.1.148-173.267...)` — an affirmative `uname -r` check, not a trusted sentinel. Three driver invocations recorded the full sequence: stock 6.1.177 -> bad 6.1.150 -> good 6.1.148, resuming across both reboots.
- **The dataset was actually loaded, for both variants.** `Loaded 2000000 records` twice, zero preload failures, with the loader verifying `stats curr_items` before declaring success.
- **The cache was genuinely warm.** Sampled on the SUT mid-measurement: `curr_items 4000000` (2M preloaded plus Lancet's own SETs), `evictions 0`, 806 MB of the 2048 MB limit, and a **98.8% GET hit rate** (667.6M hits vs 7.9M misses). This is the check that would have caught the old preloader, which left the cache mostly empty while reporting success.
- **The two scores came from two distinct measurements.** Different values, results files written 33 minutes apart, separate `Measuring '<variant>'` cycles, and both JSONs recording `"records": 2000000`.
- **The scenario completed on its own.** It reached `scenario:report` and printed the delta without intervention — the first run to do so; earlier attempts stalled in the teardown handshake.

## Raw data

`results-bad.json` and `results-good.json` as emitted by the scenario **at the time of this run**. Note a version skew, stated here rather than hidden: the code now in the tree emits three further fields (`run_label`, `slo_percentile_ci`, `slo_percentile_us`) that were added after this run, so these two files carry 11 keys where a fresh run would carry 14. The scores, dataset parameters and SLO in them are the measured values and are unaffected; but because `run_label` is absent, the scenario's `_same_experiment` cross-run guard cannot use it on this data (it treats a missing label as acceptable) and falls back to comparing the dataset/SLO parameters, which do match. Re-running the reference measurement on the current code — which would also capture the per-probe curve noted below — is the tracked follow-up before these numbers are quoted anywhere load-bearing. The per-probe binary-search curve is **not** included: the runner writes its detailed log to a single per-run temp path that the second variant overwrites, and cleanup now removes it. Preserving that curve requires writing it under the results directory per variant, which is a tracked follow-up. The converged scores in the JSONs are what the scenario records and are authoritative.
