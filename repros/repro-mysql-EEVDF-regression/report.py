#!/usr/bin/env python3

import json
import sys

if len(sys.argv) < 3:
    print("Usage: report.py <baseline> <file1.json> <...>")
    print("File names should be in the form 'results-kX.Y.Z-foo.json'")
    print("Example: report.py 6.5.13-default results-k*.json")
    sys.exit(1)

BASELINE=sys.argv[1]

def process(key, field):
    if len(results[key][field]) == 0:
        return "N/A"
    result = f"{results[key][field][0]}"
    if BASELINE in results and results[BASELINE][field]:
        percent = (results[key][field][0] / results[BASELINE][field][0] - 1) * 100
        result += f" ({'+' if percent >= 0 else ''}{percent:.1f}%)"
    return result

results = {}
for f in sys.argv[2:]:
    key = f[9:-5]
    exec("null=None;true=True;false=False;results[key]={}".format(open(f).read()))

if BASELINE not in results:
    print(f"Baseline results {BASELINE} not found, skipping comparative percentages")
else:
    print(f"Comparative percentages relative to: {BASELINE}")

print('|Kernel|config|score|TPM|latency avg|notes|')
print('|---|---|---|---|---|---|')
for key in results:
    kernel=key.split('-')
    print(f"|{kernel[0]}|{'-'.join(kernel[1:])}|{process(key,'score')}|{process(key,'tpm')}|{process(key,'latency_avg')}|{'baseline' if key==BASELINE else ''}|")
