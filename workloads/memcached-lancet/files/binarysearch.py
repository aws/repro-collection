#!/usr/bin/env python3
# Binary search over a QPS list to find the max rate under a latency SLO.
# Ported from an internal AWS benchmarking framework (topology-agnostic; no infra assumptions).
import logging
import sys


LOG_FORMAT = "[%(asctime)s] %(funcName)s %(levelname)s - %(message)s"


class BinarySearch:
    """A class used to perform binary search"""

    def __init__(self, run_benchmark_fnc, slo: float, args, debug: bool = False):
        """Parameters"""
        self.run_benchmark_fnc = run_benchmark_fnc
        self.args = args
        self.slo = float(slo)
        self.debug = debug
        # Set by binary_search() to the list of offered rates ABOVE the converged
        # answer whose measurement failed. Non-empty means the answer is bounded
        # by a failure rather than by a real SLO violation, so the true maximum
        # may be higher. Callers must check this before trusting the result.
        self.failure_bounded = []

        # Setup logging
        if self.debug or self.args.debug:
            logging.basicConfig(format=LOG_FORMAT, stream=sys.stderr, level=logging.DEBUG)

    def binary_search(self, rps_list: list) -> (int, dict, dict):
        """Performs a binary search on the points provided (list) to find the highest datapoint that satisfies the SLO"""

        slo = self.slo
        debug = self.debug
        min = 0
        max = len(rps_list) - 1

        results = {}
        outputs = {}
        loop = True
        # Offered rates whose measurement FAILED (as opposed to exceeding the
        # SLO). The two are indistinguishable in `results` -- both appear as None --
        # but they mean opposite things: an SLO violation is a real upper bound,
        # while a failed probe is missing information. Converging on a lower rate
        # because a probe failed silently understates the result, so the caller is
        # told when the answer is bounded by a failure.
        failed_probes = []

        # Check if the qps list is empty
        if len(rps_list) < 2:
            logging.debug("QPS list has less than two elements, exiting...")
            return -1, results, outputs

        res = -1
        while min <= max and loop is True:
            target = min + (max - min) // 2
            logging.debug(
                f"Enter in function (target:{rps_list[target]} qps, min:{rps_list[min]} qps, "
                f"max:{rps_list[max]} qps, res:{res}, results:{self.sort_dict(results)})"
            )

            # Run benchmark
            if rps_list[target] not in results:
                value, outputs[rps_list[target]] = self.run_benchmark_fnc(self.args, rps_list[target]).run()
                if value > 0:
                    results[rps_list[target]] = float(value)
                    logging.debug(f"benchmark results {rps_list[target]} = {results[rps_list[target]]}")
                else:
                    # value <= 0 means the run failed (run_benchmark returns
                    # -1.0), NOT that the SLO was exceeded. Record it so the
                    # caller can tell a failure-bounded answer from a real one.
                    results[rps_list[target]] = None
                    failed_probes.append(rps_list[target])
                    logging.debug(
                        f"benchmark FAILED at {rps_list[target]} qps (value={value}); "
                        "treating as an upper bound, but the result will be flagged"
                    )
                    max = target - 1

            if results[rps_list[target]] is not None:
                if results[rps_list[target]] == slo:
                    if min == max:
                        res = target
                        loop = False
                        logging.debug("Min is equal to Max, exiting...")
                        continue
                    else:
                        res = target
                        max = target
                elif results[rps_list[target]] > slo:
                    max = target - 1
                else:
                    res = target
                    min = target + 1

        target = res

        if target == -1:
            logging.debug(
                f"Not able to find value in the range (target:{target} qps, min:{min} qps, "
                f"max:{max} qps, res:{res}, results:{self.sort_dict(results)})"
            )
            return -1, self.sort_dict(results), self.sort_dict(outputs)

        if debug:
            logging.debug(
                f"Return from function {rps_list[target]} qps (target:{target}, min:{min} qps, max:{max} qps, "
                f"res:{res}), results:{self.sort_dict(results)})"
            )
        # A converged answer whose search space was bounded by a FAILED probe is
        # not trustworthy: the true maximum may be higher and we simply could not
        # measure it. Surface that instead of returning a confident lower number.
        if failed_probes and any(q > rps_list[target] for q in failed_probes):
            logging.debug(
                f"Converged on {rps_list[target]} qps, but probe(s) at "
                f"{sorted(q for q in failed_probes if q > rps_list[target])} FAILED to "
                "measure -- the true maximum may be higher"
            )
            self.failure_bounded = sorted(q for q in failed_probes if q > rps_list[target])
        return rps_list[target], self.sort_dict(results), self.sort_dict(outputs)

    def search_max_qps(self, qps_start=1000, multiply_factor=10) -> (int, int):
        """Parameters"""

        run = True
        qps = qps_start
        min_qps = 1
        max_qps = None

        while run:
            latency_result, _ = self.run_benchmark_fnc(self.args, qps).run()
            logging.debug(f"Latency result for {qps} qps is {latency_result}")
            if float(latency_result) < 0 or float(latency_result) > float(self.slo):
                run = False
                max_qps = int(qps)
            else:
                min_qps = qps
                qps = qps * multiply_factor

        logging.debug(f"Found throughput range: {min_qps}:{max_qps}")
        return min_qps, max_qps

    def sort_dict(self, d: dict):
        return dict(sorted(d.items()))
