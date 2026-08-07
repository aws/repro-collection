# Index: memcached newidle-balance regression results

Measured A/B runs go here under dated subdirectories, one per run with its own README, following the sibling `repro-mysql-EEVDF-regression/results` convention. Each holds a README summarizing the delta, SUT and agent sizing, kernel settings and repetition count, plus the `results-bad.json` / `results-good.json` the scenario emitted.

| Run | BAD 6.1.150 | GOOD 6.1.148 | Delta |
|---|---:|---:|---:|
| `20260807-lancet-verified/` | 708,819 | 796,930 | **-11.1%** |
| `20260804-lancet-verified/` | 732,764 | 915,749 | **-20.0%** |

**Both are a single iteration per variant** -- one BAD measurement and one GOOD measurement each, on separate fleets. Neither is a repeat of the other, so no error bar is implied and the two deltas are not an uncertainty range. The BAD scores agree within about 3%; the GOOD scores differ by about 13%, which accounts for the spread. Re-run before quoting a precise figure.

- `20260807-lancet-verified/` - measured end to end by the code in this directory. Also carries the `/proc/schedstat` newidle counters, which show the bad kernel attempting newidle balancing about 90x less often.
- `20260804-lancet-verified/` - the same kernel pair and record count, measured before the workload and scenario were simplified. Retained for comparison; its emitted JSONs carry 11 keys where the current code writes 13.
