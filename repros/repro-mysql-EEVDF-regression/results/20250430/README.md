# Summary

Comparative run of kernel 6.15-rc4 with `/sys/kernel/debug/sched/base_slice_ns` set to 6ms, in both default and `SCHED_BATCH` mode.

# Details

Tests were performed on a 32G RAM, 16-vCPU SUT, connected via TCP/IP to a 128G RAM, 64-vCPU load generator; both running the `repro-mysql-EEVDF-regression` reproducer scenario (mysql + hammerdb) with no manual configuration changes.

Kernel 6.15-rc4 both in default and `SCHED_BATCH` mode and a 6ms base slice was compared to the previous run's data.

|Kernel|mode|score|TPM|latency avg (lower is better)|notes|
|---|---|---|---|---|---|
|6.15-rc4|default|+1.1%|+1.2%|-1.3%|compared to 6.15-rc4 3ms `default`|
|6.15-rc4|SCHED_BATCH|+2.9%|+2.9%|-2.7%|compared to 6.15-rc4 3ms `SCHED_BATCH`|

## Scheduler stats

These stats were produced by `perf sched stats diff`:

### Kernel 6.15-rc4 default, 3ms compared to 6ms base slice:

```
$ perf sched stats diff ../20250428/perf-k6.15.rc4-default.data perf-k6.15.rc4-default-6ms.data
Columns description
----------------------------------------------------------------------------------------------------
DESC                    -> Description of the field
COUNT                   -> Value of the field
PCT_CHANGE              -> Percent change with corresponding base value
AVG_JIFFIES             -> Avg time in jiffies between two consecutive occurrence of event
----------------------------------------------------------------------------------------------------
Time elapsed (in jiffies)                                        :      150000,     150000
----------------------------------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------
CPU <ALL CPUS SUMMARY>
----------------------------------------------------------------------------------------------------
DESC                                                                    COUNT1      COUNT2   PCT_CHANGE    PCT_CHANGE1 PCT_CHANGE2
----------------------------------------------------------------------------------------------------
sched_yield() count                                              :      138180,     146373  |     5.93% |
Legacy counter can be ignored                                    :           0,          0  |     0.00% |
schedule() called                                                :     5654101,    5723044  |     1.22% |
schedule() left the processor idle                               :     1226028,    1231886  |     0.48% |  (    21.68%,     21.53% )
try_to_wake_up() was called                                      :     3696655,    3738102  |     1.12% |
try_to_wake_up() was called to wake up the local cpu             :     1363332,    1377915  |     1.07% |  (    36.88%,     36.86% )
total runtime by tasks on this processor (in jiffies)            : 509996068491,511066738327  |     0.21% |
total waittime by tasks on this processor (in jiffies)           : 760362205701,764903176187  |     0.60% |  (   149.09%,    149.67% )
total timeslices run on this cpu                                 :     4349575,    4406813  |     1.32% |
----------------------------------------------------------------------------------------------------
CPU <ALL CPUS SUMMARY>, DOMAIN MC
----------------------------------------------------------------------------------------------------
DESC                                                                    COUNT1      COUNT2   PCT_CHANGE     AVG_JIFFIES1 AVG_JIFFIES2
----------------------------------------- <Category busy> ------------------------------------------
load_balance() count on cpu busy                                 :          10,         11  |    10.00% |  $    15000.00,    13636.36 $
load_balance() found balanced on cpu busy                        :           9,         11  |    22.22% |  $    16666.67,    13636.36 $
load_balance() move task failed on cpu busy                      :           0,          0  |     0.00% |  $        0.00,        0.00 $
imbalance in load on cpu busy                                    :          39,         17  |   -56.41% |
imbalance in utilization on cpu busy                             :           0,          0  |     0.00% |
imbalance in number of tasks on cpu busy                         :           0,          0  |     0.00% |
imbalance in misfit tasks on cpu busy                            :           0,          0  |     0.00% |
pull_task() count on cpu busy                                    :           0,          0  |     0.00% |
pull_task() when target task was cache-hot on cpu busy           :           0,          0  |     0.00% |
load_balance() failed to find busier queue on cpu busy           :           0,          0  |     0.00% |  $        0.00,        0.00 $
load_balance() failed to find busier group on cpu busy           :           9,         11  |    22.22% |  $    16666.67,    13636.36 $
*load_balance() success count on cpu busy                        :           1,          0  |  -100.00% |
*avg task pulled per successful lb attempt (cpu busy)            :        0.00,       0.00  |     0.00% |
----------------------------------------- <Category idle> ------------------------------------------
load_balance() count on cpu idle                                 :       17399,      17581  |     1.05% |  $        8.62,        8.53 $
load_balance() found balanced on cpu idle                        :        5886,       5795  |    -1.55% |  $       25.48,       25.88 $
load_balance() move task failed on cpu idle                      :        9575,       9819  |     2.55% |  $       15.67,       15.28 $
imbalance in load on cpu idle                                    :       12702,      11798  |    -7.12% |
imbalance in utilization on cpu idle                             :           0,          0  |     0.00% |
imbalance in number of tasks on cpu idle                         :       13064,      13392  |     2.51% |
imbalance in misfit tasks on cpu idle                            :           0,          0  |     0.00% |
pull_task() count on cpu idle                                    :        2954,       3005  |     1.73% |
pull_task() when target task was cache-hot on cpu idle           :           0,          0  |     0.00% |
load_balance() failed to find busier queue on cpu idle           :          42,         40  |    -4.76% |  $     3571.43,     3750.00 $
load_balance() failed to find busier group on cpu idle           :        5844,       5755  |    -1.52% |  $       25.67,       26.06 $
*load_balance() success count on cpu idle                        :        1938,       1967  |     1.50% |
*avg task pulled per successful lb attempt (cpu idle)            :        1.52,       1.53  |     0.23% |
---------------------------------------- <Category newidle> ----------------------------------------
load_balance() count on cpu newly idle                           :     1488633,    1499263  |     0.71% |  $        0.10,        0.10 $
load_balance() found balanced on cpu newly idle                  :      185791,     182950  |    -1.53% |  $        0.81,        0.82 $
load_balance() move task failed on cpu newly idle                :      871226,     879762  |     0.98% |  $        0.17,        0.17 $
imbalance in load on cpu newly idle                              :           0,          0  |     0.00% |
imbalance in utilization on cpu newly idle                       :           0,          0  |     0.00% |
imbalance in number of tasks on cpu newly idle                   :     1716632,    1736189  |     1.14% |
imbalance in misfit tasks on cpu newly idle                      :           0,          0  |     0.00% |
pull_task() count on cpu newly idle                              :      715096,     723345  |     1.15% |
pull_task() when target task was cache-hot on cpu newly idle     :          51,         50  |    -1.96% |
load_balance() failed to find busier queue on cpu newly idle     :        2008,       2047  |     1.94% |  $       74.70,       73.28 $
load_balance() failed to find busier group on cpu newly idle     :      133188,     130047  |    -2.36% |  $        1.13,        1.15 $
*load_balance() success count on cpu newly idle                  :      431616,     436551  |     1.14% |
*avg task pulled per successful lb attempt (cpu newly idle)      :        1.66,       1.66  |     0.01% |
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
try_to_wake_up() awoke a task that last ran on a diff cpu        :     2333320,    2360184  |     1.15% |
try_to_wake_up() moved task because cache-cold on own cpu        :     1037495,    1048220  |     1.03% |
try_to_wake_up() started passive balancing                       :           0,          0  |     0.00% |
----------------------------------------------------------------------------------------------------
```

### Kernel 6.15-rc4 `SCHED_BATCH`, 3ms compared to 6ms base slice:

```
$ perf sched stats diff ../20250428/perf-k6.15.rc4-batch.data perf-k6.15.rc4-batch-6ms.data
Columns description
----------------------------------------------------------------------------------------------------
DESC                    -> Description of the field
COUNT                   -> Value of the field
PCT_CHANGE              -> Percent change with corresponding base value
AVG_JIFFIES             -> Avg time in jiffies between two consecutive occurrence of event
----------------------------------------------------------------------------------------------------
Time elapsed (in jiffies)                                        :      150001,     150000
----------------------------------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------
CPU <ALL CPUS SUMMARY>
----------------------------------------------------------------------------------------------------
DESC                                                                    COUNT1      COUNT2   PCT_CHANGE    PCT_CHANGE1 PCT_CHANGE2
----------------------------------------------------------------------------------------------------
sched_yield() count                                              :       29543,      33984  |    15.03% |
Legacy counter can be ignored                                    :           0,          0  |     0.00% |
schedule() called                                                :     4541104,    4589593  |     1.07% |
schedule() left the processor idle                               :     1199491,    1205788  |     0.52% |  (    26.41%,     26.27% )
try_to_wake_up() was called                                      :     3262913,    3299111  |     1.11% |
try_to_wake_up() was called to wake up the local cpu             :     1100871,    1107838  |     0.63% |  (    33.74%,     33.58% )
total runtime by tasks on this processor (in jiffies)            : 489863365873,492750779631  |     0.59% |
total waittime by tasks on this processor (in jiffies)           : 839379864797,860994973744  |     2.58% |  (   171.35%,    174.73% )
total timeslices run on this cpu                                 :     3324022,    3362825  |     1.17% |
----------------------------------------------------------------------------------------------------
CPU <ALL CPUS SUMMARY>, DOMAIN MC
----------------------------------------------------------------------------------------------------
DESC                                                                    COUNT1      COUNT2   PCT_CHANGE     AVG_JIFFIES1 AVG_JIFFIES2
----------------------------------------- <Category busy> ------------------------------------------
load_balance() count on cpu busy                                 :           0,         19  |     0.00% |  $        0.00,     7894.74 $
load_balance() found balanced on cpu busy                        :           0,         19  |     0.00% |  $        0.00,     7894.74 $
load_balance() move task failed on cpu busy                      :           0,          0  |     0.00% |  $        0.00,        0.00 $
imbalance in load on cpu busy                                    :           2,         10  |   400.00% |
imbalance in utilization on cpu busy                             :           0,          0  |     0.00% |
imbalance in number of tasks on cpu busy                         :           0,          0  |     0.00% |
imbalance in misfit tasks on cpu busy                            :           0,          0  |     0.00% |
pull_task() count on cpu busy                                    :           0,          0  |     0.00% |
pull_task() when target task was cache-hot on cpu busy           :           0,          0  |     0.00% |
load_balance() failed to find busier queue on cpu busy           :           0,          0  |     0.00% |  $        0.00,        0.00 $
load_balance() failed to find busier group on cpu busy           :           0,         19  |     0.00% |  $        0.00,     7894.74 $
*load_balance() success count on cpu busy                        :           0,          0  |     0.00% |
*avg task pulled per successful lb attempt (cpu busy)            :        0.00,       0.00  |     0.00% |
----------------------------------------- <Category idle> ------------------------------------------
load_balance() count on cpu idle                                 :       19212,      20157  |     4.92% |  $        7.81,        7.44 $
load_balance() found balanced on cpu idle                        :        9990,      10388  |     3.98% |  $       15.02,       14.44 $
load_balance() move task failed on cpu idle                      :        7622,       8148  |     6.90% |  $       19.68,       18.41 $
imbalance in load on cpu idle                                    :       10449,      10511  |     0.59% |
imbalance in utilization on cpu idle                             :           0,          0  |     0.00% |
imbalance in number of tasks on cpu idle                         :       10480,      11094  |     5.86% |
imbalance in misfit tasks on cpu idle                            :           0,          0  |     0.00% |
pull_task() count on cpu idle                                    :        2465,       2523  |     2.35% |
pull_task() when target task was cache-hot on cpu idle           :           0,          0  |     0.00% |
load_balance() failed to find busier queue on cpu idle           :          38,         37  |    -2.63% |  $     3947.39,     4054.05 $
load_balance() failed to find busier group on cpu idle           :        9952,      10351  |     4.01% |  $       15.07,       14.49 $
*load_balance() success count on cpu idle                        :        1600,       1621  |     1.31% |
*avg task pulled per successful lb attempt (cpu idle)            :        1.54,       1.56  |     1.03% |
---------------------------------------- <Category newidle> ----------------------------------------
load_balance() count on cpu newly idle                           :     1349966,    1350545  |     0.04% |  $        0.11,        0.11 $
load_balance() found balanced on cpu newly idle                  :      207597,     195741  |    -5.71% |  $        0.72,        0.77 $
load_balance() move task failed on cpu newly idle                :      680405,     691459  |     1.62% |  $        0.22,        0.22 $
imbalance in load on cpu newly idle                              :           0,          0  |     0.00% |
imbalance in utilization on cpu newly idle                       :           0,          0  |     0.00% |
imbalance in number of tasks on cpu newly idle                   :     1607732,    1629743  |     1.37% |
imbalance in misfit tasks on cpu newly idle                      :           0,          0  |     0.00% |
pull_task() count on cpu newly idle                              :      828504,     838557  |     1.21% |
pull_task() when target task was cache-hot on cpu newly idle     :          25,         27  |     8.00% |
load_balance() failed to find busier queue on cpu newly idle     :        2159,       2224  |     3.01% |  $       69.48,       67.45 $
load_balance() failed to find busier group on cpu newly idle     :      158370,     146125  |    -7.73% |  $        0.95,        1.03 $
*load_balance() success count on cpu newly idle                  :      461964,     463345  |     0.30% |
*avg task pulled per successful lb attempt (cpu newly idle)      :        1.79,       1.81  |     0.91% |
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
try_to_wake_up() awoke a task that last ran on a diff cpu        :     2162041,    2191272  |     1.35% |
try_to_wake_up() moved task because cache-cold on own cpu        :      882978,     885036  |     0.23% |
try_to_wake_up() started passive balancing                       :           0,          0  |     0.00% |
----------------------------------------------------------------------------------------------------
```

## Raw data

Perf.data files collected with `perf sched stats record` are available for examination in the same directory as this README. Individual reports generated with `perf sched stats report` are also available under the same path.

|Kernel|base slice|default||batch||
|---|---|---|---|---|---|
|6.15-rc4|3ms|[report](../20250428/perf-k6.15.rc4-default.report)|[raw](../20250428/perf-k6.15.rc4-default.data)|[report](../20250428/perf-k6.15.rc4-batch.report)|[raw](../20250428/perf-k6.15.rc4-batch.data)|
|6.15-rc4|6ms|[report](perf-k6.15.rc4-default-6ms.report)|[raw](perf-k6.15.rc4-default-6ms.data)|[report](perf-k6.15.rc4-batch-6ms.report)|[raw](perf-k6.15.rc4-batch-6ms.data)|
