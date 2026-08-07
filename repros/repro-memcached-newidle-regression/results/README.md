# Index: memcached newidle-balance regression results

Measured A/B runs go here under dated subdirectories, one per run with its own README, following the sibling `repro-mysql-EEVDF-regression/results` convention. Each holds a README summarizing the delta, SUT and agent sizing, kernel settings and repetition count, plus the `results-bad.json` / `results-good.json` the scenario emitted.

| Run | BAD 6.1.150 | GOOD 6.1.148 | Delta |
|---|---:|---:|---:|
| `20260807b-lancet-reverify/` | 757,816 | 921,774 | **-17.8%** |
| `20260807-lancet-verified/` | 708,819 | 796,930 | **-11.1%** |
| `20260804-lancet-verified/` | 732,764 | 915,749 | **-20.0%** |

**Each run is a single iteration per variant** -- one BAD measurement and one GOOD measurement. Run-to-run spread is 6.9% on BAD and 15.7% on GOOD, giving deltas from -11.1% to -20.0% with a mean near -16%. The regression reproduces in all three and the direction is never in doubt; read the magnitude as roughly 10-20% at this instance size, and treat a precise figure as requiring repeated measurement rather than these three points.

- `20260807b-lancet-reverify/` - run from the committed tree (`git archive HEAD`) on a fresh fleet against the current framework. Also carries `/proc/schedstat` newidle counters: the good kernel balanced ~975x more often.
- `20260807-lancet-verified/` - the first run measured after the workload and scenario were simplified. Also carries schedstat counters (~90x).
- `20260804-lancet-verified/` - the same kernel pair before the simplification. Retained for comparison; its JSONs carry 11 keys where the current code writes 13.
