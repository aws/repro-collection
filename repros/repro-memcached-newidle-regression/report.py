#!/usr/bin/env python3

import json
import sys

if len(sys.argv) < 3:
    print("Usage: report.py <results-bad.json> <results-good.json>")
    sys.exit(1)

# Both sides must describe the same experiment. Results files are named by variant
# and are not removed by --restart, so a leftover file from an earlier run -- maybe
# at a different dataset size -- would otherwise be compared against a fresh one
# and reported as a real regression.
SAME = ("records", "value_size", "set_to_get_ratio", "slo_parameter", "slo_value_us", "protocol")

results = {}
for f in sys.argv[1:3]:
    try:
        results[f] = json.load(open(f))
    except Exception as exc:
        print(f"INVALID: cannot read {f}: {exc}")
        sys.exit(1)

bad, good = (results[f] for f in sys.argv[1:3])

print("BAD  (culprit present) max QPS under SLO: %s" % (bad.get("score") or ["N/A"])[0])
print("GOOD (culprit absent)  max QPS under SLO: %s" % (good.get("score") or ["N/A"])[0])

diffs = [f"{k}: {bad.get(k)!r} vs {good.get(k)!r}" for k in SAME if bad.get(k) != good.get(k)]
if diffs:
    print("INVALID: the two runs do not describe the same experiment (" + "; ".join(diffs) + ")")
    print("Delete results-*.json and measure both variants again.")
    sys.exit(1)

# A missing or zero score means that variant failed to measure. Computing a
# percentage from it would turn a failed run into a headline result: 0 against a
# healthy variant reads as a -100% regression.
try:
    b, g = float(bad["score"][0]), float(good["score"][0])
except (KeyError, IndexError, TypeError, ValueError):
    print("INVALID: one or both variants produced no score; no delta computed.")
    sys.exit(1)
if b <= 0 or g <= 0:
    print("INVALID: a non-positive score is not a measurement; no delta computed.")
    sys.exit(1)

print(f"regression: {(b / g - 1) * 100:+.1f}% (bad vs good)")
