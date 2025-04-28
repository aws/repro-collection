# Summary

The regression introduced by EEVDF is still present, at the same or worse levels than earlier kernel versions. When comparing with kernel 6.5.13 in default and `SCHED_BATCH` modes respectively, all kernels 6.12 and newer underperform severely, both in throughput (NOPM and TPM) and in latency measurements.

# Details

Tests were performed on a 32G RAM, 16-vCPU SUT, connected via TCP/IP to a 128G RAM, 64-vCPU load generator; both running the `repro-mysql-EEVDF-regression` reproducer scenario (mysql + hammerdb) with no manual configuration changes.

|Kernel|mode|score|TPM|latency avg (lower is better)|
|---|---|---|---|---|
|compared to 6.5.13 `default`:|||||
|6.12.25|default|-5.1%|-5.0%|+7.8%|
|6.13.12|default|-6.1%|-6.0%|+8.6%|
|6.14.4|default|-7.4%|-7.4%|+9.6%|
|6.15-rc4|default|-7.4%|-7.5%|+10.2%|
|compared to 6.5.13 `SCHED_BATCH`:|||||
|6.12.25|SCHED_BATCH|-8.1%|-8.1%|+8.7%|
|6.13.12|SCHED_BATCH|-7.8%|-7.7%|+8.3%|
|6.14.4|SCHED_BATCH|-7.9%|-7.9%|+8.3%|
|6.15-rc4|SCHED_BATCH|-10.6%|-10.6%|+11.8%|

## Scheduler stats

These stats were produced by `perf sched stats diff`:

### Kernel 6.5.13 default compared to 6.15-rc4 default:

```
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
sched_yield() count                                              :      199542,     138180  |   -30.75% |
Legacy counter can be ignored                                    :           0,          0  |     0.00% |
schedule() called                                                :     6050232,    5654101  |    -6.55% |
schedule() left the processor idle                               :     1048022,    1226028  |    16.98% |  (    17.32%,     21.68% )
try_to_wake_up() was called                                      :     4016913,    3696655  |    -7.97% |
try_to_wake_up() was called to wake up the local cpu             :     1736180,    1363332  |   -21.48% |  (    43.22%,     36.88% )
total runtime by tasks on this processor (in jiffies)            : 531050222644,509996068491  |    -3.96% |
total waittime by tasks on this processor (in jiffies)           : 757330247689,760362205701  |     0.40% |  (   142.61%,    149.09% )
total timeslices run on this cpu                                 :     4894216,    4349575  |   -11.13% |
----------------------------------------------------------------------------------------------------
CPU <ALL CPUS SUMMARY>, DOMAIN 0
----------------------------------------------------------------------------------------------------
DESC                                                                    COUNT1      COUNT2   PCT_CHANGE     AVG_JIFFIES1 AVG_JIFFIES2
----------------------------------------- <Category idle> ------------------------------------------
load_balance() count on cpu idle                                 :       15531,         10  |   -99.94% |  $        9.66,    15000.00 $
load_balance() found balanced on cpu idle                        :        6611,          9  |   -99.86% |  $       22.69,    16666.67 $
load_balance() move task failed on cpu idle                      :        6984,          0  |  -100.00% |  $       21.48,        0.00 $
imbalance sum on cpu idle                                        :       13302,         39  |   -99.71% |
pull_task() count on cpu idle                                    :        2516,          0  |  -100.00% |
pull_task() when target task was cache-hot on cpu idle           :           0,          0  |     0.00% |
load_balance() failed to find busier queue on cpu idle           :           3,          0  |  -100.00% |  $    50000.00,        0.00 $
load_balance() failed to find busier group on cpu idle           :        6607,          0  |  -100.00% |  $       22.70,        0.00 $
*load_balance() success count on cpu idle                        :        1936,          1  |   -99.95% |
*avg task pulled per successful lb attempt (cpu idle)            :        1.30,       0.00  |  -100.00% |
----------------------------------------- <Category busy> ------------------------------------------
load_balance() count on cpu busy                                 :           3,          0  |  -100.00% |  $    50000.00,        0.00 $
load_balance() found balanced on cpu busy                        :           1,          0  |  -100.00% |  $   150000.00,        0.00 $
load_balance() move task failed on cpu busy                      :           1,          9  |   800.00% |  $   150000.00,    16666.67 $
imbalance sum on cpu busy                                        :          57,      17399  | 30424.56% |
pull_task() count on cpu busy                                    :           2,       5886  | 294200.00% |
pull_task() when target task was cache-hot on cpu busy           :           0,       9575  |     0.00% |
load_balance() failed to find busier queue on cpu busy           :           0,      12702  |     0.00% |  $        0.00,       11.81 $
load_balance() failed to find busier group on cpu busy           :           1,          0  |  -100.00% |  $   150000.00,        0.00 $
*load_balance() success count on cpu busy                        :           1, 4294967287  | 429496728600.00% |
*avg task pulled per successful lb attempt (cpu busy)            :        2.00,       0.00  |  -100.00% |
---------------------------------------- <Category newidle> ----------------------------------------
load_balance() count on cpu newly idle                           :     1443994,      13064  |   -99.10% |  $        0.10,       11.48 $
load_balance() found balanced on cpu newly idle                  :      142456,          0  |  -100.00% |  $        1.05,        0.00 $
load_balance() move task failed on cpu newly idle                :      698289,       2954  |   -99.58% |  $        0.21,       50.78 $
imbalance sum on cpu newly idle                                  :     1693652,          0  |  -100.00% |
pull_task() count on cpu newly idle                              :      903401,         42  |  -100.00% |
pull_task() when target task was cache-hot on cpu newly idle     :          29,       5844  | 20051.72% |
load_balance() failed to find busier queue on cpu newly idle     :          96,    1488633  | 1550559.38% |  $     1562.50,        0.10 $
load_balance() failed to find busier group on cpu newly idle     :      120775,     185791  |    53.83% |  $        1.24,        0.81 $
*load_balance() success count on cpu newly idle                  :      603249,      10110  |   -98.32% |
*avg task pulled per successful lb attempt (cpu newly idle)      :        1.50,       0.00  |   -99.72% |
--------------------------------- <Category active_load_balance()> ---------------------------------
active_load_balance() count                                      :           0,     871226  |     0.00% |
active_load_balance() move task failed                           :           0,          0  |     0.00% |
active_load_balance() successfully moved a task                  :           0,          0  |     0.00% |
--------------------------------- <Category sched_balance_exec()> ----------------------------------
sbe_count is not used                                            :           0,    1716632  |     0.00% |
sbe_balanced is not used                                         :           0,          0  |     0.00% |
sbe_pushed is not used                                           :           0,     715096  |     0.00% |
--------------------------------- <Category sched_balance_fork()> ----------------------------------
sbf_count is not used                                            :           0,         51  |     0.00% |
sbf_balanced is not used                                         :           0,       2008  |     0.00% |
sbf_pushed is not used                                           :           0,     133188  |     0.00% |
------------------------------------------ <Wakeup Info> -------------------------------------------
try_to_wake_up() awoke a task that last ran on a diff cpu        :     2280728,          0  |  -100.00% |
try_to_wake_up() moved task because cache-cold on own cpu        :     1277147,          0  |  -100.00% |
try_to_wake_up() started passive balancing                       :           0,          0  |     0.00% |
----------------------------------------------------------------------------------------------------
```

### Kernel 6.5.13 `SCHED_BATCH` compared to 6.15-rc4 `SCHED_BATCH`:

```
Columns description
----------------------------------------------------------------------------------------------------
DESC                    -> Description of the field
COUNT                   -> Value of the field
PCT_CHANGE              -> Percent change with corresponding base value
AVG_JIFFIES             -> Avg time in jiffies between two consecutive occurrence of event
----------------------------------------------------------------------------------------------------
Time elapsed (in jiffies)                                        :      150000,     150001
----------------------------------------------------------------------------------------------------

----------------------------------------------------------------------------------------------------
CPU <ALL CPUS SUMMARY>
----------------------------------------------------------------------------------------------------
DESC                                                                    COUNT1      COUNT2   PCT_CHANGE    PCT_CHANGE1 PCT_CHANGE2
----------------------------------------------------------------------------------------------------
sched_yield() count                                              :       26986,      29543  |     9.48% |
Legacy counter can be ignored                                    :           0,          0  |     0.00% |
schedule() called                                                :     4523560,    4541104  |     0.39% |
schedule() left the processor idle                               :      927704,    1199491  |    29.30% |  (    20.51%,     26.41% )
try_to_wake_up() was called                                      :     3503516,    3262913  |    -6.87% |
try_to_wake_up() was called to wake up the local cpu             :     1408750,    1100871  |   -21.85% |  (    40.21%,     33.74% )
total runtime by tasks on this processor (in jiffies)            : 526207251119,489863365873  |    -6.91% |
total waittime by tasks on this processor (in jiffies)           : 904571763522,839379864797  |    -7.21% |  (   171.90%,    171.35% )
total timeslices run on this cpu                                 :     3583244,    3324022  |    -7.23% |
----------------------------------------------------------------------------------------------------
CPU <ALL CPUS SUMMARY>, DOMAIN 0
----------------------------------------------------------------------------------------------------
DESC                                                                    COUNT1      COUNT2   PCT_CHANGE     AVG_JIFFIES1 AVG_JIFFIES2
----------------------------------------- <Category idle> ------------------------------------------
load_balance() count on cpu idle                                 :       17557,          0  |  -100.00% |  $        8.54,        0.00 $
load_balance() found balanced on cpu idle                        :       12404,          0  |  -100.00% |  $       12.09,        0.00 $
load_balance() move task failed on cpu idle                      :        3627,          0  |  -100.00% |  $       41.36,        0.00 $
imbalance sum on cpu idle                                        :        7903,          2  |   -99.97% |
pull_task() count on cpu idle                                    :        1988,          0  |  -100.00% |
pull_task() when target task was cache-hot on cpu idle           :           0,          0  |     0.00% |
load_balance() failed to find busier queue on cpu idle           :           2,          0  |  -100.00% |  $    75000.00,        0.00 $
load_balance() failed to find busier group on cpu idle           :       12401,          0  |  -100.00% |  $       12.10,        0.00 $
*load_balance() success count on cpu idle                        :        1526,          0  |  -100.00% |
*avg task pulled per successful lb attempt (cpu idle)            :        1.30,       0.00  |  -100.00% |
----------------------------------------- <Category busy> ------------------------------------------
load_balance() count on cpu busy                                 :           1,          0  |  -100.00% |  $   150000.00,        0.00 $
load_balance() found balanced on cpu busy                        :           0,          0  |     0.00% |  $        0.00,        0.00 $
load_balance() move task failed on cpu busy                      :           0,          0  |     0.00% |  $        0.00,        0.00 $
imbalance sum on cpu busy                                        :          21,      19212  | 91385.71% |
pull_task() count on cpu busy                                    :           1,       9990  | 998900.00% |
pull_task() when target task was cache-hot on cpu busy           :           0,       7622  |     0.00% |
load_balance() failed to find busier queue on cpu busy           :           0,      10449  |     0.00% |  $        0.00,       14.36 $
load_balance() failed to find busier group on cpu busy           :           0,          0  |     0.00% |  $        0.00,        0.00 $
*load_balance() success count on cpu busy                        :           1,          0  |  -100.00% |
*avg task pulled per successful lb attempt (cpu busy)            :        1.00,       0.00  |  -100.00% |
---------------------------------------- <Category newidle> ----------------------------------------
load_balance() count on cpu newly idle                           :     1203440,      10480  |   -99.13% |  $        0.12,       14.31 $
load_balance() found balanced on cpu newly idle                  :      116440,          0  |  -100.00% |  $        1.29,        0.00 $
load_balance() move task failed on cpu newly idle                :      434564,       2465  |   -99.43% |  $        0.35,       60.85 $
imbalance sum on cpu newly idle                                  :     1559584,          0  |  -100.00% |
pull_task() count on cpu newly idle                              :     1064902,         38  |  -100.00% |
pull_task() when target task was cache-hot on cpu newly idle     :          13,       9952  | 76453.85% |
load_balance() failed to find busier queue on cpu newly idle     :          83,    1349966  | 1626365.06% |  $     1807.23,        0.11 $
load_balance() failed to find busier group on cpu newly idle     :       96802,     207597  |   114.46% |  $        1.55,        0.72 $
*load_balance() success count on cpu newly idle                  :      652436,       8015  |   -98.77% |
*avg task pulled per successful lb attempt (cpu newly idle)      :        1.63,       0.00  |   -99.71% |
--------------------------------- <Category active_load_balance()> ---------------------------------
active_load_balance() count                                      :           0,     680405  |     0.00% |
active_load_balance() move task failed                           :           0,          0  |     0.00% |
active_load_balance() successfully moved a task                  :           0,          0  |     0.00% |
--------------------------------- <Category sched_balance_exec()> ----------------------------------
sbe_count is not used                                            :           0,    1607732  |     0.00% |
sbe_balanced is not used                                         :           0,          0  |     0.00% |
sbe_pushed is not used                                           :           0,     828504  |     0.00% |
--------------------------------- <Category sched_balance_fork()> ----------------------------------
sbf_count is not used                                            :           0,         25  |     0.00% |
sbf_balanced is not used                                         :           0,       2159  |     0.00% |
sbf_pushed is not used                                           :           0,     158370  |     0.00% |
------------------------------------------ <Wakeup Info> -------------------------------------------
try_to_wake_up() awoke a task that last ran on a diff cpu        :     2094766,          0  |  -100.00% |
try_to_wake_up() moved task because cache-cold on own cpu        :     1065374,          0  |  -100.00% |
try_to_wake_up() started passive balancing                       :           0,          0  |     0.00% |
----------------------------------------------------------------------------------------------------
```

## Raw data

Perf.data files collected with `perf sched stats record` are available for examination in the same directory as this README. Individual reports generated with `perf sched stats report` are also available under the same path.

|Kernel|default||batch||
|---|---|---|---|---|
|6.5.13|[report](perf-k6.5.13-default.report)|[raw](perf-k6.5.13-default.data)|[report](perf-k6.5.13-batch.report)|[raw](perf-k6.5.13-batch.data)|
|6.12.25|[report](perf-k6.12.25-default.report)|[raw](perf-k6.12.25-default.data)|[report](perf-k6.12.25-batch.report)|[raw](perf-k6.12.25-batch.data)|
|6.14.4|[report](perf-k6.14.4-default.report)|[raw](perf-k6.14.4-default.data)|[report](perf-k6.14.4-batch.report)|[raw](perf-k6.14.4-batch.data)|
|6.15-rc4|[report](perf-k6.15.rc4-default.report)|[raw](perf-k6.15.rc4-default.data)|[report](perf-k6.15.rc4-batch.report)|[raw](perf-k6.15.rc4-batch.data)|
