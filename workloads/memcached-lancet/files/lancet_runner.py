#!/usr/bin/env python3

"""
Ported from an internal AWS benchmarking framework. Drives Lancet against caller-supplied agent
addresses over SSH; makes no cloud/EC2 assumptions (agents and the SSH key are
passed in as arguments).

This tool invokes Lancet for a list of given QPS. Before each invocation, it
kills the Lancet agents. It outputs a JSON with the following format:
{
    "qps1": "lancet_qps1_stdout",
    "qps2": "lancet_qps2_stdout",
    ...
}
"""

import argparse
import json
import logging
import subprocess
import sys
import time

from lancet_regexp import parseLancetDataOutput
from binarysearch import BinarySearch



LOG_FORMAT = "[%(asctime)s] %(funcName)20s %(levelname)5s - %(message)s"


LATENCY_AGENT_QPS = 4000    # Lancet -lqps: load applied by the latency agent
# First probe of the throughput search. Must exceed LATENCY_AGENT_QPS: the
# throughput agents are given (probe - LATENCY_AGENT_QPS) QPS, so a lower start
# leaves them ~0 and Lancet's agent controller divides by zero.
SEARCH_START_QPS = 10000
SEARCH_MULTIPLY = 10
LOAD_PATTERN = "fixed"      # Lancet -loadPattern
SAMPLE_RATE = 100           # Lancet sample rate, percent
SLO_TOLERANCE = 15          # allowed spread across runs before a result is rejected, percent


class LancetRunner:
    """A class used to run Lancet benchmarks for a given datapoint (QPS)."""

    def __init__(self, args, qps, max_retries=2) -> None:
        """Parameters"""
        self.args = args
        self.qps = qps
        self.max_retries = max_retries

        # Setup logging
        if args.debug:
            logging.basicConfig(format=LOG_FORMAT, stream=sys.stderr, level=logging.DEBUG)

    def run(self) -> (float, list):
        """Runs Lancet for a given datapoint (QPS) and returns the average across repetitions (or -1.0 if it fails)"""

        values, outputs = self.run_benchmark(self.args.num_runs)

        # If Lancet failed, return -1.0
        if values == [-1.0]:
            return -1.0, outputs

        # Calculate average
        average = round(sum(values) / len(values), 2)
        logging.debug(f"Values after outlier removal for {self.qps} qps " f"(avg: {average}): {values}")

        return average, outputs

    def run_benchmark(self, num_runs: int) -> (list, list):
        """Runs Lancet for a given number of repetitions and returns a list of values and a list stdout outputs"""
        outputs = []
        values = []

        failed = False
        retries = 0
        i = 0
        while i < num_runs and retries < (self.max_retries * num_runs):
            o, f = self.run_lancet()
            output = {self.qps: o}

            # Parse results to get single value
            data = self.parse_lancet_results([output])
            if f is True or not self.is_rps_in_range(data):
                failed = True
                retries = retries + 1
                continue

            i = i + 1
            failed = False
            outputs.append(output)

            # check if it needs to run an extra benchmark
            if i >= num_runs:
                data = self.parse_lancet_results(outputs)
                all_values = data[self.args.bs_slo_parameter]
                values, outputs, is_within_tolerance = self.evaluate_results(all_values, outputs)

                if not is_within_tolerance:
                    logging.debug("Values not in tolerance, triggering a new run")
                    num_runs = num_runs + 1

        if failed:
            return [-1.0], outputs

        return values, outputs

    def is_rps_in_range(self, data: dict) -> bool:
        """Checks if the RPS value is in the range of the desired one"""

        if "lancet_qps" not in data or "qps" not in data:
            return False

        # Check if throughput is in range with the desired one
        distance = round((100 * abs(data["qps"][0] - self.qps) / self.qps), 2)

        logging.debug(
            f"QPS check: lancet_qps: {data['lancet_qps'][0]}, qps: {round(data['qps'][0], 2)}, "
            f"distance: {distance}%, {self.args.bs_slo_parameter}: {data[self.args.bs_slo_parameter][0]}"
        )

        if distance > int(self.args.qps_tolerance):
            logging.warning(
                f"QPS value is not within {self.args.qps_tolerance}% of the one provided. "
                f"Provided: {self.qps} Actual: {round(data['qps'][0], 2)} ({distance}%)"
            )
            return False

        return True

    def parse_lancet_results(self, outputs: list) -> dict:
        """Parses Lancet results and returns a dictionary of data"""
        return dict(parseLancetDataOutput(outputs))

    def evaluate_results(self, values: list, outputs: list) -> (list, list, bool):
        """Evaluates results and variance is bigger than threshold, trigger a new run"""

        if len(values) < 2:
            logging.debug(f"number of values: ({len(values)}) less than 2. Skipping evaluation results.")
            return values, outputs, True

        if len(values) > 2:
            v, o = self.remove_outliers(values, outputs)
            return v, o, True

        # Calculate values distance in percentage
        is_within_tolerance = True
        distance = round((abs(values[0] - values[1]) / values[0]) * 100, 2)
        logging.debug(f"values for {self.qps} qps are {distance}% apart")

        if distance > SLO_TOLERANCE:
            is_within_tolerance = False

        return values, outputs, is_within_tolerance

    def remove_outliers(self, values: list, outputs: list, threshold: float = 1.0) -> (list, list):
        """Detect and remove possible outliers from list (default: 1 standard deviations away)"""

        if len(values) < 3:
            logging.debug(f"Only {len(values)}. Skipping outlier detection")
            return values, outputs

        # Calculate the mean and standard deviation of the values
        mean = sum(values) / len(values)
        std = (sum([(x - mean) ** 2 for x in values]) / len(values)) ** 0.5
        logging.debug(
            f"values for {self.qps} qps: {values}, mean: {round(mean, 2)}, std: {round(std, 2)}, "
            f"deviation: {round(threshold * std, 2)}"
        )

        # Remove outliers values
        return_values = []
        return_outputs = []
        for x in range(0, len(values)):
            if abs(values[x] - mean) <= threshold * std:
                return_values.append(values[x])
                return_outputs.append(outputs[x])

        return return_values, return_outputs

    def run_lancet(self) -> (str, bool):
        """Run the lancet command and returns Lancet output and if it fails the execution"""

        args = self.args
        agents = args.load_agents.split(",") + args.lt_agents.split(",")

        for agent in agents:
            subprocess.call(
                [
                    "ssh",
                    "-o",
                    "UserKnownHostsFile=/dev/null",
                    "-o",
                    "StrictHostKeyChecking=no",
                    "-o",
                    "LogLevel=quiet",
                    "-i",
                    args.private_key,
                    agent,
                    "sudo pkill -9 lancet",
                ],
                stdout=subprocess.DEVNULL,
            )
        time.sleep(1)

        qps = max(int(self.qps - LATENCY_AGENT_QPS), 1)
        runtime = LATENCY_AGENT_QPS * args.run_length * SAMPLE_RATE / 100
        load_pattern = f"{LOAD_PATTERN}:{qps}:{round(runtime)}:{SAMPLE_RATE}"
        command = args.command + [
            "-privateKey",
            args.private_key,
            "-loadAgents",
            args.load_agents,
            "-ltAgents",
            args.lt_agents,
            "-lqps",
            str(LATENCY_AGENT_QPS),
            "-loadPattern",
            load_pattern,
        ]
        proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = proc.communicate(None)
        if proc.returncode == 0:
            return stdout.decode("ascii"), False
        else:
            print("Lancet failed (rc={})".format(proc.returncode), file=sys.stderr)
            print("command line {}".format(" ".join(command)), file=sys.stderr)
            print("stdout {}".format(stdout.decode("ascii")), file=sys.stderr)
            print("stderr {}".format(stderr.decode("ascii")), file=sys.stderr)
            return "", True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--num-runs", type=int, default=10, help="How many times to run a single experiment (default 10).")
    parser.add_argument("--bs-slo-value", type=int, default=1000, help="SLO ceiling in microseconds.")
    parser.add_argument("--bs-slo-parameter", default="latency_p99", help="Which percentile the SLO applies to.")
    parser.add_argument("--bs-granularity", type=int, default=1000, help="Search granularity in QPS (default 1000).")
    parser.add_argument("--qps-tolerance", type=int, default=10, help="Allowed achieved-vs-offered QPS gap, in percent.")
    parser.add_argument("--load-agents", required=True)
    parser.add_argument("--lt-agents", required=True)
    parser.add_argument("--private-key", required=True)
    parser.add_argument("--run-length", type=int, default=300, help="Benchmark length in seconds.")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    if args.debug:
        logging.basicConfig(format=LOG_FORMAT, stream=sys.stderr, level=logging.DEBUG)

    # num_runs divides the summed values deep inside a run, so a bad value
    # surfaces as a traceback after minutes of load rather than a usage error.
    if SEARCH_START_QPS <= LATENCY_AGENT_QPS:
        print("SEARCH_START_QPS ({}) must exceed LATENCY_AGENT_QPS ({}), or the "
              "throughput agents get no load".format(SEARCH_START_QPS, LATENCY_AGENT_QPS),
              file=sys.stderr)
        return 2
    if args.num_runs < 1:
        print("--num-runs must be at least 1, got {}".format(args.num_runs), file=sys.stderr)
        return 2

    bs = BinarySearch(LancetRunner, args.bs_slo_value, args, args.debug)
    qps_min, qps_max = bs.search_max_qps(qps_start=SEARCH_START_QPS, multiply_factor=SEARCH_MULTIPLY)
    qps_min = LATENCY_AGENT_QPS + args.bs_granularity if qps_min < 2 else qps_min
    qps_list = list(range(qps_min, qps_max, args.bs_granularity))
    logging.debug(f"Binary search in range {qps_min}:{qps_max}, granularity {args.bs_granularity}.")

    value, results, outputs = bs.binary_search(qps_list)
    if value == -1:
        print(f"No offered rate met the SLO ({args.bs_slo_parameter} <= {args.bs_slo_value}us): "
              f"{results}", file=sys.stderr)
        print(json.dumps([]))
        return 1

    # A value whose search was bounded by a FAILED probe (an agent died, Lancet
    # could not run) is not a measurement of the maximum: the true maximum may be
    # higher and we never reached it. Reporting it would understate the result.
    if getattr(bs, "failure_bounded", None):
        print("Binary search converged on %s qps, but the probe(s) at %s failed to measure "
              "rather than exceeding the SLO, so the true maximum may be higher. Refusing "
              "to report a failure-bounded result."
              % (value, ", ".join(str(q) for q in bs.failure_bounded)), file=sys.stderr)
        print(json.dumps([]))
        return 1

    print(json.dumps([outputs[value][0]]))
    return 0

if __name__ == "__main__":
    sys.exit(main())
