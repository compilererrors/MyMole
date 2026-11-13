#!/usr/bin/env python3
"""Negative checks: incomplete or fabricated UI reports must fail the gate."""
import copy
import importlib.util
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("ui_coverage", Path(__file__).with_name("check-ui-coverage.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class CoverageGuardTests(unittest.TestCase):
    def setUp(self):
        self.config = guard.inventory()
        self.lines = [f"ui-bench {name} n={value['minimumSamples']} p50=0.001ms p95=0.002ms p99=0.003ms max=0.004ms over33ms=0 budget={value['budgetMilliseconds']:.3f}ms cpu_p95=0.002ms gate=wall"
                      for name, value in self.config["benchmarks"].items()]

    def report(self):
        return "\n".join(self.lines)

    def test_complete_report_and_source_inventory(self):
        guard.sources(self.config)
        self.assertEqual(guard.benchmarks(self.config, self.report()), len(self.lines))

    def test_missing_and_duplicate_metrics_are_refused(self):
        for text in ["\n".join(self.lines[1:]), self.report() + "\n" + self.lines[0]]:
            with self.assertRaises(ValueError):
                guard.benchmarks(self.config, text)

    def test_invalid_samples_and_budget_changes_are_refused(self):
        for change in [self.lines[0].replace("n=1", "n=0"), self.lines[0].replace("budget=1000.000", "budget=1001.000")]:
            with self.assertRaises(ValueError):
                guard.benchmarks(self.config, "\n".join([change] + self.lines[1:]))

    def test_nonfinite_and_out_of_order_measurements_are_refused(self):
        for value in ["nan", "inf", "-1", "2000"]:
            with self.assertRaises(ValueError):
                guard.benchmarks(self.config, self.report().replace("p95=0.002ms", f"p95={value}ms", 1))

    def test_cpu_and_stall_failures_are_refused(self):
        for change in [self.lines[0].replace("gate=wall", "gate=thread-cpu").replace("cpu_p95=0.002", "cpu_p95=nan"),
                       self.lines[0].replace("gate=wall", "gate=wall-liveness").replace("max=0.004", "max=1001")]:
            with self.assertRaises(ValueError):
                guard.benchmarks(self.config, "\n".join([change] + self.lines[1:]))

    def test_missing_or_duplicate_e2e_evidence_is_refused(self):
        lines = ["ui-e2e " + name for name in self.config["e2eTests"].values()]
        self.assertEqual(guard.e2e(self.config, "\n".join(lines)), len(lines))
        for altered in [lines[1:], lines + lines[:1]]:
            with self.assertRaises(ValueError):
                guard.e2e(self.config, "\n".join(altered))

    def test_new_handlers_or_unregistered_tests_are_refused(self):
        for key in ["adjustmentSources", "benchmarkTests", "e2eTests"]:
            altered = copy.deepcopy(self.config)
            altered[key] = {} if isinstance(altered[key], dict) else []
            with self.assertRaises(ValueError):
                guard.sources(altered)


if __name__ == "__main__":
    unittest.main()
