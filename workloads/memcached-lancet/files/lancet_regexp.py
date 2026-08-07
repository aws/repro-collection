#! /usr/bin/env python3
# Parser for Lancet's stdout (QPS + latency percentiles).
# Ported from an internal AWS benchmarking framework (pure text parsing; no infra assumptions).
import re
from collections import defaultdict

QPS = "qps"

LAT_AVG = "latency_avg"
LAT_50 = "latency_p50"
LAT_90 = "latency_p90"
LAT_95 = "latency_p95"
LAT_99 = "latency_p99"
LAT_99_9 = "latency_p99_9"
LAT_99_99 = "latency_p99_99"
LAT_99_999 = "latency_p99_999"
LAT_99_9999 = "latency_p99_9999"

LANCET_QPS = "lancet_qps"   # the OFFERED rate; is_rps_in_range compares achieved vs offered

NUM = "[0-9.e+]+"

# Example: 181979	13998.180026599612	1.8132178068166696e+06	941649.6220439855
QPS_REGEX = re.compile(rf"(?P<request_count>{NUM})\s+(?P<{QPS}>{NUM})\s+(?P<rx_bandwidth>{NUM})\s+(?P<tx_bandwidth>{NUM})")

# Example: 176.714	155.113(154.074, 156.186)	252.06(247.557, 258.013)	315.208(306.368, 323.353)	470.777(448.66, 493.744)	790.903(706.712, 11071.951)	11072.033(4757.922, 0)	11814.333(11896.811, 0)	11888.563(11896.811, 0) # noqa E501
LATENCY_REGEX = re.compile(
    rf"(?P<{LAT_AVG}>{NUM})\s+(?P<{LAT_50}>{NUM})\(.*\)\s+(?P<{LAT_90}>{NUM})\(.*\)\s+(?P<{LAT_95}>{NUM})\(.*\)\s+(?P<{LAT_99}>{NUM})\(.*\)\s+(?P<{LAT_99_9}>{NUM})\(.*\)\s+(?P<{LAT_99_99}>{NUM})\(.*\)\s+(?P<{LAT_99_999}>{NUM})\(.*\)\s+(?P<{LAT_99_9999}>{NUM})"  # noqa E501
)


# Percentile cells with their confidence bounds: `value(low, high)`.
LATENCY_CI_REGEX = re.compile(r"([0-9.]+)\(([0-9.]+),\s*([0-9.]+)\)")


def parseLancetDataOutput(runs: list) -> dict:
    """Parse the winning run's Lancet stdout into {metric: [values]}."""
    data = defaultdict(list)
    for run in runs:
        for offered, output in run.items():
            # The offered rate the caller asked for. is_rps_in_range needs it to
            # reject a probe whose achieved throughput drifted from the request;
            # without it every probe is treated as a failure.
            data[LANCET_QPS].append(int(offered))
            for line in output.split("\n"):
                match = QPS_REGEX.match(line)
                if match:
                    for k, v in match.groupdict().items():
                        data[k].append(float(v))
                    continue
                match = LATENCY_REGEX.match(line)
                if match:
                    for k, v in match.groupdict().items():
                        data[k].append(float(v))
                    # A second "Aggregate Latency" block follows that we do not
                    # want; stop at the first match.
                    break
    return data
