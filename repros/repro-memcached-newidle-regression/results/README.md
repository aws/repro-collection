# Index: memcached newidle-balance regression results

Measured A/B runs go here under dated subdirectories, one per run with its own README, following the sibling `repro-mysql-EEVDF-regression/results` convention. Each holds a README summarizing the delta, SUT and agent sizing, kernel settings and repetition count, plus the `results-bad.json` / `results-good.json` the scenario emitted.

| Run | Kernels compared | BAD | GOOD | Delta |
|---|---|---:|---:|---:|
| `20260811-build-v6.19-revert/` | mainline v6.19 +/- the revert (**single commit**) | 791,893 | 885,884 | **-10.6%** |
| `20260807b-lancet-reverify/` | AL2023 6.1.150 vs 6.1.148 | 757,816 | 921,774 | **-17.8%** |
| `20260807-lancet-verified/` | AL2023 6.1.150 vs 6.1.148 | 708,819 | 796,930 | **-11.1%** |
| `20260804-lancet-verified/` | AL2023 6.1.150 vs 6.1.148 | 732,764 | 915,749 | **-20.0%** |

**Each run is a single iteration per variant.** The three AL2023 runs compare two package versions, which carry more than the one commit; the build-mode run compares the same mainline tag built twice on one host, differing only by `git am` of the revert, and is the set to cite for attribution to the commit itself. Its -10.6% sits at the low end of the AL2023 range, consistent with the package delta contributing a little on top. Run-to-run spread on the AL2023 pair is 6.9% on BAD and 15.7% on GOOD, so read the magnitude as roughly 10-20% at this instance size rather than a precise figure.

Every set except `20260804` also carries `/proc/schedstat` newidle counters showing the balancer attempting newidle balancing far less often with the commit present: 9.3x in build mode, 90x and 975x in the two AL2023 runs that captured it.
