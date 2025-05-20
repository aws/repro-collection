# Summary

The regression introduced by EEVDF is still present, at the same or worse levels than earlier kernel versions. When comparing with kernel 6.5.13 in default and `SCHED_BATCH` modes respectively, all kernels 6.12 and newer underperform severely, both in throughput (NOPM and TPM) and in latency measurements.

# Details

Tests were performed on a 32G RAM, 16-vCPU SUT, connected via TCP/IP to a 128G RAM, 64-vCPU load generator; both running the `repro-mysql-EEVDF-regression` reproducer scenario (mysql + hammerdb) with no manual configuration changes. All kernels built from tag, with CONFIG_HZ=250.

The VU count is now set to 128 (i.e. the recommended 8 * SUT_vCPUs) as opposed to 256 in previous tests.

What stands out:
- There is a performance inversion from VU=256 (6.15-rc3 now underperforms 6.15-rc4). This may be useful data for characterizing the regression.
- Kernel 6.14.7 is about the same as 6.14.6 in default mode, but slower in `SCHED_BATCH` mode (-7.1% vs -6.4%).
- Kernel 6.15-rc5 is faster than all other 6.15-rcX builds so far, especially in default mode.
- Kernel 6.15-rc7 is worse than 6.15-rc6 everywhere except for throughput in default mode.
- With either VU value, disabling `PLACE_LAG` and `RUN_TO_PARITY` no longer improves performance significantly on up to date kernels 6.12 and above.

|Kernel|mode|score|TPM|latency avg (lower is better)|score for NOPL+NORTP|Notes|
|---|---|---|---|---|---|---|
|compared to 6.5.13 `default`:|||||||
|6.6.91  |default|-5.7%|-5.7%| +9.9%|-2.6%||
|6.8.12  |default|-6.0%|-6.1%|+10.7%|-3.4%||
|6.12.29 |default|-6.8%|-6.7%| +9.5%|-8.0%||
|6.13.12 |default|-7.6%|-7.5%|+10.5%|-8.5%||
|6.14.7  |default|-7.0%|-7.1%| +9.8%|-9.8%||
|6.15-rc3|default|-8.5%|-8.5%|+11.7%|not tested|slowest rc build|
|6.15-rc4|default|-7.5%|-7.5%|+10.2%|not tested||
|6.15-rc5|default|-6.4%|-6.3%| +8.6%|not tested|fastest rc build|
|6.15-rc6|default|-7.5%|-7.6%|+10.4%|-9.0%||
|6.15-rc7|default|-7.8%|-7.8%|+11.1%|-8.5%||
|compared to 6.5.13 `SCHED_BATCH`:|||||||
|6.6.91  |SCHED_BATCH|-5.1%|-5.0%| +7.4%|||
|6.8.12  |SCHED_BATCH|-6.0%|-6.1%| +8.6%|||
|6.12.29 |SCHED_BATCH|-6.6%|-6.7%| +8.4%|||
|6.13.12 |SCHED_BATCH|-6.9%|-7.0%| +8.9%|||
|6.14.7  |SCHED_BATCH|-7.1%|-7.1%| +8.7%||worse than 6.14.6 (-6.4%)|
|6.15-rc3|SCHED_BATCH|-9.6%|-9.7%|+11.8%|||
|6.15-rc4|SCHED_BATCH|-7.0%|-7.1%| +8.6%|||
|6.15-rc5|SCHED_BATCH|-6.6%|-6.6%| +7.9%|||
|6.15-rc6|SCHED_BATCH|-6.6%|-6.8%| +8.4%|||
|6.15-rc7|SCHED_BATCH|-7.7%|-7.7%| +9.7%|||

## Scheduler stats

These stats were produced by `perf sched stats diff`:

### Kernel 6.15-rc4 default compared to 6.15-rc5 default:

```
Columns description
----------------------------------------------------------------------------------------------------
DESC			-> Description of the field
COUNT			-> Value of the field
PCT_CHANGE		-> Percent change with corresponding base value
AVG_JIFFIES		-> Avg time in jiffies between two consecutive occurrence of event
----------------------------------------------------------------------------------------------------
Time elapsed (in jiffies)                                        :      150000,     150001
----------------------------------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------
CPU <ALL CPUS SUMMARY>
----------------------------------------------------------------------------------------------------
DESC                                                                    COUNT1      COUNT2   PCT_CHANGE    PCT_CHANGE1 PCT_CHANGE2
----------------------------------------------------------------------------------------------------
sched_yield() count                                              :      123856,     147550  |    19.13% |
Legacy counter can be ignored                                    :           0,          0  |     0.00% |
schedule() called                                                :     5672409,    5833811  |     2.85% |
schedule() left the processor idle                               :     1241494,    1270163  |     2.31% |  (    21.89%,     21.77% )
try_to_wake_up() was called                                      :     3700719,    3795701  |     2.57% |
try_to_wake_up() was called to wake up the local cpu             :     1359655,    1343525  |    -1.19% |  (    36.74%,     35.40% )
total runtime by tasks on this processor (in jiffies)            : 502703938454,503665168743  |     0.19% |
total waittime by tasks on this processor (in jiffies)           : 691506143477,691759755053  |     0.04% |  (   137.56%,    137.35% )
total timeslices run on this cpu                                 :     4357670,    4470652  |     2.59% |
----------------------------------------------------------------------------------------------------
CPU <ALL CPUS SUMMARY>, DOMAIN MC
----------------------------------------------------------------------------------------------------
DESC                                                                    COUNT1      COUNT2   PCT_CHANGE     AVG_JIFFIES1 AVG_JIFFIES2
----------------------------------------- <Category busy> ------------------------------------------
load_balance() count on cpu busy                                 :           2,          5  |   150.00% |  $    75000.00,    30000.20 $
load_balance() found balanced on cpu busy                        :           1,          2  |   100.00% |  $   150000.00,    75000.50 $
load_balance() move task failed on cpu busy                      :           0,          1  |     0.00% |  $        0.00,   150001.00 $
imbalance in load on cpu busy                                    :         132,        153  |    15.91% |
imbalance in utilization on cpu busy                             :           0,          0  |     0.00% |
imbalance in number of tasks on cpu busy                         :           0,          0  |     0.00% |
imbalance in misfit tasks on cpu busy                            :           0,          0  |     0.00% |
pull_task() count on cpu busy                                    :           0,          2  |     0.00% |
pull_task() when target task was cache-hot on cpu busy           :           0,          0  |     0.00% |
load_balance() failed to find busier queue on cpu busy           :           0,          0  |     0.00% |  $        0.00,        0.00 $
load_balance() failed to find busier group on cpu busy           :           1,          2  |   100.00% |  $   150000.00,    75000.50 $
*load_balance() success count on cpu busy                        :           1,          2  |   100.00% |
*avg task pulled per successful lb attempt (cpu busy)            :        0.00,       1.00  |     0.00% |
----------------------------------------- <Category idle> ------------------------------------------
load_balance() count on cpu idle                                 :       16402,      16133  |    -1.64% |  $        9.15,        9.30 $
load_balance() found balanced on cpu idle                        :        6411,       6643  |     3.62% |  $       23.40,       22.58 $
load_balance() move task failed on cpu idle                      :        8328,       7854  |    -5.69% |  $       18.01,       19.10 $
imbalance in load on cpu idle                                    :        4551,       3564  |   -21.69% |
imbalance in utilization on cpu idle                             :           0,          0  |     0.00% |
imbalance in number of tasks on cpu idle                         :       11317,      10845  |    -4.17% |
imbalance in misfit tasks on cpu idle                            :           0,          0  |     0.00% |
pull_task() count on cpu idle                                    :        2460,       2441  |    -0.77% |
pull_task() when target task was cache-hot on cpu idle           :           0,          0  |     0.00% |
load_balance() failed to find busier queue on cpu idle           :          21,         17  |   -19.05% |  $     7142.86,     8823.59 $
load_balance() failed to find busier group on cpu idle           :        6389,       6626  |     3.71% |  $       23.48,       22.64 $
*load_balance() success count on cpu idle                        :        1663,       1636  |    -1.62% |
*avg task pulled per successful lb attempt (cpu idle)            :        1.48,       1.49  |     0.87% |
---------------------------------------- <Category newidle> ----------------------------------------
load_balance() count on cpu newly idle                           :     1519026,    1571885  |     3.48% |  $        0.10,        0.10 $
load_balance() found balanced on cpu newly idle                  :      218229,     239054  |     9.54% |  $        0.69,        0.63 $
load_balance() move task failed on cpu newly idle                :      843436,     847900  |     0.53% |  $        0.18,        0.18 $
imbalance in load on cpu newly idle                              :           0,          0  |     0.00% |
imbalance in utilization on cpu newly idle                       :           0,          0  |     0.00% |
imbalance in number of tasks on cpu newly idle                   :     1725493,    1801243  |     4.39% |
imbalance in misfit tasks on cpu newly idle                      :           0,          0  |     0.00% |
pull_task() count on cpu newly idle                              :      739546,     796683  |     7.73% |
pull_task() when target task was cache-hot on cpu newly idle     :          62,         54  |   -12.90% |
load_balance() failed to find busier queue on cpu newly idle     :        2171,       2182  |     0.51% |  $       69.09,       68.74 $
load_balance() failed to find busier group on cpu newly idle     :      165649,     179342  |     8.27% |  $        0.91,        0.84 $
*load_balance() success count on cpu newly idle                  :      457361,     484931  |     6.03% |
*avg task pulled per successful lb attempt (cpu newly idle)      :        1.62,       1.64  |     1.60% |
--------------------------------- <Category active_load_balance()> ---------------------------------
active_load_balance() count                                      :           0,          0  |     0.00% |
active_load_balance() move task failed                           :           0,          0  |     0.00% |
active_load_balance() successfully moved a task                  :           0,          0  |     0.00% |
--------------------------------- <Category sched_balance_exec()> ----------------------------------
sbe_count is not used                                            :           0,          0  |     0.00% |
sbe_balanced is not used                                         :           0,          0  |     0.00% |
sbe_pushed is not used                                           :           0,          0  |     0.00% |
--------------------------------- <Category sched_balance_fork()> ----------------------------------
sbf_count is not used                                            :           0,          0  |     0.00% |
sbf_balanced is not used                                         :           0,          0  |     0.00% |
sbf_pushed is not used                                           :           0,          0  |     0.00% |
------------------------------------------ <Wakeup Info> -------------------------------------------
try_to_wake_up() awoke a task that last ran on a diff cpu        :     2341061,    2452173  |     4.75% |
try_to_wake_up() moved task because cache-cold on own cpu        :     1032435,    1063644  |     3.02% |
try_to_wake_up() started passive balancing                       :           0,          0  |     0.00% |
----------------------------------------------------------------------------------------------------
```

### Kernel 6.15-rc3 default compared to 6.15-rc4 default:

```
Columns description
----------------------------------------------------------------------------------------------------
DESC			-> Description of the field
COUNT			-> Value of the field
PCT_CHANGE		-> Percent change with corresponding base value
AVG_JIFFIES		-> Avg time in jiffies between two consecutive occurrence of event
----------------------------------------------------------------------------------------------------
Time elapsed (in jiffies)                                        :      150001,     150000
----------------------------------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------
CPU <ALL CPUS SUMMARY>
----------------------------------------------------------------------------------------------------
DESC                                                                    COUNT1      COUNT2   PCT_CHANGE    PCT_CHANGE1 PCT_CHANGE2
----------------------------------------------------------------------------------------------------
sched_yield() count                                              :      125665,     123856  |    -1.44% |
Legacy counter can be ignored                                    :           0,          0  |     0.00% |
schedule() called                                                :     5617123,    5672409  |     0.98% |
schedule() left the processor idle                               :     1248745,    1241494  |    -0.58% |  (    22.23%,     21.89% )
try_to_wake_up() was called                                      :     3653487,    3700719  |     1.29% |
try_to_wake_up() was called to wake up the local cpu             :     1318494,    1359655  |     3.12% |  (    36.09%,     36.74% )
total runtime by tasks on this processor (in jiffies)            : 500169085075,502703938454  |     0.51% |
total waittime by tasks on this processor (in jiffies)           : 682076372156,691506143477  |     1.38% |  (   136.37%,    137.56% )
total timeslices run on this cpu                                 :     4293527,    4357670  |     1.49% |
----------------------------------------------------------------------------------------------------
CPU <ALL CPUS SUMMARY>, DOMAIN MC
----------------------------------------------------------------------------------------------------
DESC                                                                    COUNT1      COUNT2   PCT_CHANGE     AVG_JIFFIES1 AVG_JIFFIES2
----------------------------------------- <Category busy> ------------------------------------------
load_balance() count on cpu busy                                 :          21,          2  |   -90.48% |  $     7142.90,    75000.00 $
load_balance() found balanced on cpu busy                        :          20,          1  |   -95.00% |  $     7500.05,   150000.00 $
load_balance() move task failed on cpu busy                      :           0,          0  |     0.00% |  $        0.00,        0.00 $
imbalance in load on cpu busy                                    :         107,        132  |    23.36% |
imbalance in utilization on cpu busy                             :           0,          0  |     0.00% |
imbalance in number of tasks on cpu busy                         :           0,          0  |     0.00% |
imbalance in misfit tasks on cpu busy                            :           0,          0  |     0.00% |
pull_task() count on cpu busy                                    :           0,          0  |     0.00% |
pull_task() when target task was cache-hot on cpu busy           :           0,          0  |     0.00% |
load_balance() failed to find busier queue on cpu busy           :           0,          0  |     0.00% |  $        0.00,        0.00 $
load_balance() failed to find busier group on cpu busy           :          20,          1  |   -95.00% |  $     7500.05,   150000.00 $
*load_balance() success count on cpu busy                        :           1,          1  |     0.00% |
*avg task pulled per successful lb attempt (cpu busy)            :        0.00,       0.00  |     0.00% |
----------------------------------------- <Category idle> ------------------------------------------
load_balance() count on cpu idle                                 :       17537,      16402  |    -6.47% |  $        8.55,        9.15 $
load_balance() found balanced on cpu idle                        :        7160,       6411  |   -10.46% |  $       20.95,       23.40 $
load_balance() move task failed on cpu idle                      :        8685,       8328  |    -4.11% |  $       17.27,       18.01 $
imbalance in load on cpu idle                                    :        4122,       4551  |    10.41% |
imbalance in utilization on cpu idle                             :           0,          0  |     0.00% |
imbalance in number of tasks on cpu idle                         :       11751,      11317  |    -3.69% |
imbalance in misfit tasks on cpu idle                            :           0,          0  |     0.00% |
pull_task() count on cpu idle                                    :        2506,       2460  |    -1.84% |
pull_task() when target task was cache-hot on cpu idle           :           0,          0  |     0.00% |
load_balance() failed to find busier queue on cpu idle           :          19,         21  |    10.53% |  $     7894.79,     7142.86 $
load_balance() failed to find busier group on cpu idle           :        7141,       6389  |   -10.53% |  $       21.01,       23.48 $
*load_balance() success count on cpu idle                        :        1692,       1663  |    -1.71% |
*avg task pulled per successful lb attempt (cpu idle)            :        1.48,       1.48  |    -0.12% |
---------------------------------------- <Category newidle> ----------------------------------------
load_balance() count on cpu newly idle                           :     1506544,    1519026  |     0.83% |  $        0.10,        0.10 $
load_balance() found balanced on cpu newly idle                  :      235740,     218229  |    -7.43% |  $        0.64,        0.69 $
load_balance() move task failed on cpu newly idle                :      824966,     843436  |     2.24% |  $        0.18,        0.18 $
imbalance in load on cpu newly idle                              :           0,          0  |     0.00% |
imbalance in utilization on cpu newly idle                       :           0,          0  |     0.00% |
imbalance in number of tasks on cpu newly idle                   :     1693153,    1725493  |     1.91% |
imbalance in misfit tasks on cpu newly idle                      :           0,          0  |     0.00% |
pull_task() count on cpu newly idle                              :      726559,     739546  |     1.79% |
pull_task() when target task was cache-hot on cpu newly idle     :          66,         62  |    -6.06% |
load_balance() failed to find busier queue on cpu newly idle     :        2085,       2171  |     4.12% |  $       71.94,       69.09 $
load_balance() failed to find busier group on cpu newly idle     :      180593,     165649  |    -8.27% |  $        0.83,        0.91 $
*load_balance() success count on cpu newly idle                  :      445838,     457361  |     2.58% |
*avg task pulled per successful lb attempt (cpu newly idle)      :        1.63,       1.62  |    -0.78% |
--------------------------------- <Category active_load_balance()> ---------------------------------
active_load_balance() count                                      :           0,          0  |     0.00% |
active_load_balance() move task failed                           :           0,          0  |     0.00% |
active_load_balance() successfully moved a task                  :           0,          0  |     0.00% |
--------------------------------- <Category sched_balance_exec()> ----------------------------------
sbe_count is not used                                            :           0,          0  |     0.00% |
sbe_balanced is not used                                         :           0,          0  |     0.00% |
sbe_pushed is not used                                           :           0,          0  |     0.00% |
--------------------------------- <Category sched_balance_fork()> ----------------------------------
sbf_count is not used                                            :           0,          0  |     0.00% |
sbf_balanced is not used                                         :           0,          0  |     0.00% |
sbf_pushed is not used                                           :           0,          0  |     0.00% |
------------------------------------------ <Wakeup Info> -------------------------------------------
try_to_wake_up() awoke a task that last ran on a diff cpu        :     2334992,    2341061  |     0.26% |
try_to_wake_up() moved task because cache-cold on own cpu        :     1015295,    1032435  |     1.69% |
try_to_wake_up() started passive balancing                       :           0,          0  |     0.00% |
----------------------------------------------------------------------------------------------------
```

### Kernel 6.15-rc3 `SCHED_BATCH` compared to 6.15-rc4 `SCHED_BATCH`:

```
Columns description
----------------------------------------------------------------------------------------------------
DESC			-> Description of the field
COUNT			-> Value of the field
PCT_CHANGE		-> Percent change with corresponding base value
AVG_JIFFIES		-> Avg time in jiffies between two consecutive occurrence of event
----------------------------------------------------------------------------------------------------
Time elapsed (in jiffies)                                        :      150001,     150001
----------------------------------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------
CPU <ALL CPUS SUMMARY>
----------------------------------------------------------------------------------------------------
DESC                                                                    COUNT1      COUNT2   PCT_CHANGE    PCT_CHANGE1 PCT_CHANGE2
----------------------------------------------------------------------------------------------------
sched_yield() count                                              :       31819,      37634  |    18.28% |
Legacy counter can be ignored                                    :           0,          0  |     0.00% |
schedule() called                                                :     4447618,    4605437  |     3.55% |
schedule() left the processor idle                               :     1164163,    1209197  |     3.87% |  (    26.17%,     26.26% )
try_to_wake_up() was called                                      :     3200364,    3308255  |     3.37% |
try_to_wake_up() was called to wake up the local cpu             :     1076423,    1123733  |     4.40% |  (    33.63%,     33.97% )
total runtime by tasks on this processor (in jiffies)            : 488918643472,486778270260  |    -0.44% |
total waittime by tasks on this processor (in jiffies)           : 796729444367,788750211687  |    -1.00% |  (   162.96%,    162.03% )
total timeslices run on this cpu                                 :     3265781,    3374611  |     3.33% |
----------------------------------------------------------------------------------------------------
CPU <ALL CPUS SUMMARY>, DOMAIN MC
----------------------------------------------------------------------------------------------------
DESC                                                                    COUNT1      COUNT2   PCT_CHANGE     AVG_JIFFIES1 AVG_JIFFIES2
----------------------------------------- <Category busy> ------------------------------------------
load_balance() count on cpu busy                                 :          20,          0  |  -100.00% |  $     7500.05,        0.00 $
load_balance() found balanced on cpu busy                        :          19,          0  |  -100.00% |  $     7894.79,        0.00 $
load_balance() move task failed on cpu busy                      :           0,          0  |     0.00% |  $        0.00,        0.00 $
imbalance in load on cpu busy                                    :          28,         17  |   -39.29% |
imbalance in utilization on cpu busy                             :           0,          0  |     0.00% |
imbalance in number of tasks on cpu busy                         :           0,          0  |     0.00% |
imbalance in misfit tasks on cpu busy                            :           0,          0  |     0.00% |
pull_task() count on cpu busy                                    :           0,          0  |     0.00% |
pull_task() when target task was cache-hot on cpu busy           :           0,          0  |     0.00% |
load_balance() failed to find busier queue on cpu busy           :           0,          0  |     0.00% |  $        0.00,        0.00 $
load_balance() failed to find busier group on cpu busy           :          19,          0  |  -100.00% |  $     7894.79,        0.00 $
*load_balance() success count on cpu busy                        :           1,          0  |  -100.00% |
*avg task pulled per successful lb attempt (cpu busy)            :        0.00,       0.00  |     0.00% |
----------------------------------------- <Category idle> ------------------------------------------
load_balance() count on cpu idle                                 :       19124,      18671  |    -2.37% |  $        7.84,        8.03 $
load_balance() found balanced on cpu idle                        :       10844,      10866  |     0.20% |  $       13.83,       13.80 $
load_balance() move task failed on cpu idle                      :        6867,       6488  |    -5.52% |  $       21.84,       23.12 $
imbalance in load on cpu idle                                    :        3878,       3404  |   -12.22% |
imbalance in utilization on cpu idle                             :           0,          0  |     0.00% |
imbalance in number of tasks on cpu idle                         :        9384,       8867  |    -5.51% |
imbalance in misfit tasks on cpu idle                            :           0,          0  |     0.00% |
pull_task() count on cpu idle                                    :        2129,       2003  |    -5.92% |
pull_task() when target task was cache-hot on cpu idle           :           0,          0  |     0.00% |
load_balance() failed to find busier queue on cpu idle           :          21,         19  |    -9.52% |  $     7142.90,     7894.79 $
load_balance() failed to find busier group on cpu idle           :       10823,      10846  |     0.21% |  $       13.86,       13.83 $
*load_balance() success count on cpu idle                        :        1413,       1317  |    -6.79% |
*avg task pulled per successful lb attempt (cpu idle)            :        1.51,       1.52  |     0.94% |
---------------------------------------- <Category newidle> ----------------------------------------
load_balance() count on cpu newly idle                           :     1336379,    1386268  |     3.73% |  $        0.11,        0.11 $
load_balance() found balanced on cpu newly idle                  :      232426,     234840  |     1.04% |  $        0.65,        0.64 $
load_balance() move task failed on cpu newly idle                :      637131,     664185  |     4.25% |  $        0.24,        0.23 $
imbalance in load on cpu newly idle                              :           0,          0  |     0.00% |
imbalance in utilization on cpu newly idle                       :           0,          0  |     0.00% |
imbalance in number of tasks on cpu newly idle                   :     1572587,    1636355  |     4.05% |
imbalance in misfit tasks on cpu newly idle                      :           0,          0  |     0.00% |
pull_task() count on cpu newly idle                              :      831938,     861956  |     3.61% |
pull_task() when target task was cache-hot on cpu newly idle     :          33,         33  |     0.00% |
load_balance() failed to find busier queue on cpu newly idle     :        2143,       2325  |     8.49% |  $       70.00,       64.52 $
load_balance() failed to find busier group on cpu newly idle     :      181014,     185630  |     2.55% |  $        0.83,        0.81 $
*load_balance() success count on cpu newly idle                  :      466822,     487243  |     4.37% |
*avg task pulled per successful lb attempt (cpu newly idle)      :        1.78,       1.77  |    -0.73% |
--------------------------------- <Category active_load_balance()> ---------------------------------
active_load_balance() count                                      :           0,          0  |     0.00% |
active_load_balance() move task failed                           :           0,          0  |     0.00% |
active_load_balance() successfully moved a task                  :           0,          0  |     0.00% |
--------------------------------- <Category sched_balance_exec()> ----------------------------------
sbe_count is not used                                            :           0,          0  |     0.00% |
sbe_balanced is not used                                         :           0,          0  |     0.00% |
sbe_pushed is not used                                           :           0,          0  |     0.00% |
--------------------------------- <Category sched_balance_fork()> ----------------------------------
sbf_count is not used                                            :           0,          0  |     0.00% |
sbf_balanced is not used                                         :           0,          0  |     0.00% |
sbf_pushed is not used                                           :           0,          0  |     0.00% |
------------------------------------------ <Wakeup Info> -------------------------------------------
try_to_wake_up() awoke a task that last ran on a diff cpu        :     2123938,    2184521  |     2.85% |
try_to_wake_up() moved task because cache-cold on own cpu        :      847969,     887286  |     4.64% |
try_to_wake_up() started passive balancing                       :           0,          0  |     0.00% |
----------------------------------------------------------------------------------------------------
```

## Raw data

Perf.data files collected with `perf sched stats record` are available for examination in the same directory as this README. Individual reports generated with `perf sched stats report` are also available under the same path.

|Kernel|default||batch||
|---|---|---|---|---|
|6.5.13|[report](perf-k6.5.13-default.report)|[raw](perf-k6.5.13-default.data)|[report](perf-k6.5.13-batch.report)|[raw](perf-k6.5.13-batch.data)|
|6.6.91|[report](perf-k6.6.91-default.report)|[raw](perf-k6.6.91-default.data)|[report](perf-k6.6.91-batch.report)|[raw](perf-k6.6.91-batch.data)|
|6.8.12|[report](perf-k6.8.12-default.report)|[raw](perf-k6.8.12-default.data)|[report](perf-k6.8.12-batch.report)|[raw](perf-k6.8.12-batch.data)|
|6.12.29|[report](perf-k6.12.29-default.report)|[raw](perf-k6.12.29-default.data)|[report](perf-k6.12.29-batch.report)|[raw](perf-k6.12.29-batch.data)|
|6.13.12|[report](perf-k6.13.12-default.report)|[raw](perf-k6.13.12-default.data)|[report](perf-k6.13.12-batch.report)|[raw](perf-k6.13.12-batch.data)|
|6.14.7|[report](perf-k6.14.7-default.report)|[raw](perf-k6.14.7-default.data)|[report](perf-k6.14.7-batch.report)|[raw](perf-k6.14.7-batch.data)|
|6.15-rc3|[report](perf-k6.15.rc3-default.report)|[raw](perf-k6.15.rc3-default.data)|[report](perf-k6.15.rc3-batch.report)|[raw](perf-k6.15.rc3-batch.data)|
|6.15-rc4|[report](perf-k6.15.rc4-default.report)|[raw](perf-k6.15.rc4-default.data)|[report](perf-k6.15.rc4-batch.report)|[raw](perf-k6.15.rc4-batch.data)|
|6.15-rc5|[report](perf-k6.15.rc5-default.report)|[raw](perf-k6.15.rc5-default.data)|[report](perf-k6.15.rc5-batch.report)|[raw](perf-k6.15.rc5-batch.data)|
|6.15-rc6|[report](perf-k6.15.rc6-default.report)|[raw](perf-k6.15.rc6-default.data)|[report](perf-k6.15.rc6-batch.report)|[raw](perf-k6.15.rc6-batch.data)|
|6.15-rc7|[report](perf-k6.15.rc7-default.report)|[raw](perf-k6.15.rc7-default.data)|[report](perf-k6.15.rc7-batch.report)|[raw](perf-k6.15.rc7-batch.data)|
