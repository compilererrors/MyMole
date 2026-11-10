#!/usr/bin/env python3
"""Require completed test functions, rather than a successful all-skipped run."""
import json
import sys
from pathlib import Path


def completed(path, no_skips=False):
    tests = {}
    started, ended, cases, skipped = set(), set(), set(), set()
    run_started = run_ended = False
    with Path(path).open() as stream:
        for line in stream:
            record = json.loads(line)
            payload = record["payload"]
            kind = payload["kind"]
            if record["kind"] == "test":
                tests[payload["id"]] = payload
            elif record["kind"] == "event":
                test_id = payload.get("testID")
                if kind == "runStarted":
                    run_started = True
                elif kind == "runEnded":
                    run_ended = True
                elif kind == "testStarted":
                    started.add(test_id)
                elif kind == "testEnded":
                    ended.add(test_id)
                elif kind == "testCaseEnded":
                    cases.add(test_id)
                elif kind == "testSkipped":
                    skipped.add(test_id)
    if not run_started or not run_ended or started != ended:
        raise ValueError("The event stream is incomplete.")
    if no_skips and skipped:
        raise ValueError("This run must not skip any tests.")
    if any(test_id not in tests for test_id in started):
        raise ValueError("The event stream contains an unidentified test.")
    return sum(
        test_id in started and test_id not in skipped
        and test["kind"] == "function"
        and (not test.get("isParameterized", False) or test_id in cases)
        for test_id, test in tests.items()
    )


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--no-skips"):
        sys.exit("Usage: check-test-events.py <event-stream> [--no-skips]")
    try:
        count = completed(sys.argv[1], no_skips=len(sys.argv) == 3)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Cannot verify test execution: {type(error).__name__}.", file=sys.stderr)
        sys.exit(2)
    if count == 0:
        print("No test functions actually completed.", file=sys.stderr)
        sys.exit(69)
    print(f"Verified execution of {count} test functions.")
