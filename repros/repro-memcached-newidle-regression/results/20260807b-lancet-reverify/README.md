# memcached newidle-balance regression, reverification run - 2026-08-07

An independent repeat of the A/B, run from the committed tree on a fresh 5-host fleet, to check that the code as committed reproduces the regression against the current framework.

## Result

| Kernel | max QPS under 1 ms p99 SLO |
|---|---:|
| GOOD 6.1.148-173.267 | 921,774 |
| BAD 6.1.150-174.273 | 757,816 |
| **Regression (bad vs good)** | **-17.8%** |

**A single iteration per variant**, like the other two runs in this directory. Same settings: 2,000,000 records, `binary-search` mode, SLO p99 <= 1000 us, `LANCET_NUM_RUNS=2`, `LANCET_RUN_LENGTH=60`. The p99 at each converged point was 1050.5 us (bad, an average across two repetitions of 989 us and 1050 us) and 960.9 us (good), each with a 95% confidence interval under 4% of the value.

## The three runs together

| Run | BAD | GOOD | Delta |
|---|---:|---:|---:|
| 2026-08-07 reverification (this set) | 757,816 | 921,774 | -17.8% |
| 2026-08-07 first run | 708,819 | 796,930 | -11.1% |
| 2026-08-04, before the code was simplified | 732,764 | 915,749 | -20.0% |

Run-to-run spread is 6.9% on BAD and 15.7% on GOOD, so the deltas range from -11.1% to -20.0% with a mean near -16%. The regression reproduces in every run and the direction is never in doubt; the magnitude at this instance size should be read as roughly 10-20%, and a mean of three single-iteration runs is not a substitute for repeated measurement.

## Mechanism

`newidle-deltas.txt` carries the `/proc/schedstat` newidle counters. In this run the good kernel attempted newidle load balancing about 975x more often than the bad kernel and pulled about 4567x more tasks -- the same direction as the first run and a larger ratio. Raw snapshots are committed so the numbers can be recomputed.

## Setup

Identical to the first run: 5 hosts in us-west-2, SUT c7a.4xlarge (AMD EPYC 9R14, 16 vCPU, 2 L3 instances confirmed via `lscpu`) from the AL2023 `kernel-6.1` AMI line, coordinator c7a.xlarge, 2 throughput agents c7a.4xlarge, 1 latency agent c7a.2xlarge, least-privilege instance profile, security group permitting intra-group traffic only.

## What this run additionally checked

- The tree was staged from the commit itself (`git archive HEAD`), not a working copy, so this exercises exactly what is committed.
- Both kernels installed and defaulted on the first attempt, confirming the AL2023 kernel-line precondition check and the package naming.
- Every Lancet probe measured successfully (achieved throughput within 0.05% of offered on all probes); no probe returned a failure sentinel.
- The scenario recorded its reboot requests through the framework's state API (`FLAG=REBOOT` with a reason), and its per-variant build revisions through the framework's persistent-variable API.
