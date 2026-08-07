#!/usr/bin/env python3
"""Reduce lancet_runner.py output to a single achieved-QPS score.

Exits non-zero with a message when the input holds no trustworthy run, so a
failed or empty measurement cannot be mistaken for a real score of 0.

Usage: lancet_score.py <lancet_out.json> [slo_parameter]
"""

import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lancet_regexp import parseLancetDataOutput, LATENCY_CI_REGEX  # noqa: E402

# Smallest sample count for which Lancet can compute an in-range upper CI bound,
# and the percentile's column in the latency row. Lancet derives intervals from
# order statistics (USENIX ATC '19, formulas 1-2) and substitutes 0 when the upper
# index falls outside the sample array, so a percentile whose CI upper bound is 0
# was never measured -- it is an index overflow, not a latency.
_PCTL = {  # name: (column in the latency row, percentile)
    "latency_p50": (0, 0.5), "latency_p90": (1, 0.9), "latency_p95": (2, 0.95),
    "latency_p99": (3, 0.99), "latency_p99_9": (4, 0.999),
    "latency_p99_99": (5, 0.9999), "latency_p99_999": (6, 0.99999),
    "latency_p99_9999": (7, 0.999999),
}


def _min_samples(p, eta=1.96):
    n = 1
    while n < 20000000:
        if math.ceil(n * p + eta * math.sqrt(n * p * (1 - p))) + 1 < n:
            return n
        n += 1
    return None


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    slo_param = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "latency_p99"
    col, pctl = _PCTL.get(slo_param, (3, 0.99))
    need = _min_samples(pctl)

    with open(sys.argv[1]) as f:
        payload = f.read().strip()
    if not payload:
        print("No Lancet output to score: {} is empty".format(sys.argv[1]), file=sys.stderr)
        return 1

    runs = json.loads(payload)
    if not runs:
        # lancet_runner prints [] when the search found no point under the SLO.
        print("Lancet returned no qualifying run: the search found no offered "
              "rate meeting the SLO", file=sys.stderr)
        return 1

    qps = dict(parseLancetDataOutput(runs)).get("qps", [])
    if not qps:
        print("Could not parse an achieved QPS out of the Lancet output; the "
              "format may have changed", file=sys.stderr)
        return 1

    # The scored percentile must rest on enough samples to be real. Deliberately
    # NOT gated on `Overall IA check`: that sums per-agent inter-arrival passes,
    # and a dedicated latency agent (-a 1) records no transmit timestamps, so it
    # reports "No tx samples" and sums to 0 on every run of this topology --
    # including known-good ones. Gating on it would reject every measurement.
    decoded = "\n".join(str(v) for run in runs for v in run.values())
    counts = [int(m) for m in re.findall(r"There are (\d+) samples", decoded)]
    if not counts:
        print("Refusing to score: the latency agent reported no sample count", file=sys.stderr)
        return 1
    if min(counts) < need:
        print("Refusing to score: only {} latency samples, but {} are needed "
              "before {} has an in-range confidence interval. Raise "
              "LANCET_RUN_LENGTH or score a lower percentile.".format(
                  min(counts), need, slo_param), file=sys.stderr)
        return 1

    print(round(max(qps)))
    # On stderr so the score line stays machine-readable. A single number hides
    # whether the measurement was tight or marginal, and a 0 upper bound means the
    # interval overflowed and was never really computed.
    cells = re.findall(LATENCY_CI_REGEX, decoded)
    if col < len(cells):
        val, lo, hi = (float(x) for x in cells[col])
        if hi == 0:
            print("CI-NOTE {}={}us with an OVERFLOWED confidence interval "
                  "(upper bound reported as 0)".format(slo_param, val), file=sys.stderr)
        else:
            print("CI-NOTE {}={}us 95% CI [{}, {}]us (width {:.1f}us, {:.2f}% "
                  "of the value)".format(slo_param, val, lo, hi, hi - lo,
                                         100.0 * (hi - lo) / val if val else 0.0),
                  file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
