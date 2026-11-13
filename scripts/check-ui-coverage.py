#!/usr/bin/env python3
"""Require the UI interaction inventory, completed scenarios and every KPI."""
import json
import math
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def inventory():
    return json.loads((REPO / "Tests/UIInteractionCoverage.json").read_text())


def sources(config):
    found = {}
    for path in sorted((REPO / "Sources/MyMole").rglob("*.swift")):
        text = path.read_text()
        counts = {name: len(re.findall(pattern, text)) for name, pattern in config["sourcePatterns"].items() if re.search(pattern, text)}
        if counts:
            found[str(path.relative_to(REPO))] = counts
    if found != config["adjustmentSources"]:
        raise ValueError("UI adjustment handlers changed: update the inventory and its behavioral/KPI coverage.")
    for file, key in [("UIResponsivenessBenchmarkTests.swift", "benchmarkTests"), ("UIInteractionEndToEndTests.swift", "e2eTests")]:
        functions = re.findall(r"@Test(?:\([^\n]*\))?\s+func (\w+)", (REPO / "Tests/MyMoleTests" / file).read_text())
        if set(functions) != set(config[key]) or len(functions) != len(config[key]):
            raise ValueError("UI scenario inventory differs from its test functions: " + file)


def benchmarks(config, text):
    found = {}
    for line in text.splitlines():
        if not line.startswith("ui-bench "):
            continue
        name = line.split()[1]
        if name in found:
            raise ValueError("Duplicate KPI: " + name)
        found[name] = dict(re.findall(r"([a-zA-Z0-9_]+)=([^ ]+)", line))
    if set(found) != set(config["benchmarks"]):
        missing = sorted(set(config["benchmarks"]) - set(found))
        extra = sorted(set(found) - set(config["benchmarks"]))
        raise ValueError("KPI inventory mismatch; missing=" + repr(missing) + ", unexpected=" + repr(extra))
    for name, expected in config["benchmarks"].items():
        values = found[name]
        numbers = {key: float(values[key].removesuffix("ms")) for key in ["p50", "p95", "p99", "max", "budget"]}
        if not all(math.isfinite(value) and value >= 0 for value in numbers.values()):
            raise ValueError("Non-finite KPI: " + name)
        if int(values["n"]) < expected["minimumSamples"] or abs(numbers["budget"] - expected["budgetMilliseconds"]) > 0.001:
            raise ValueError("KPI sample count or budget changed: " + name)
        if not numbers["p50"] <= numbers["p95"] <= numbers["p99"] <= numbers["max"]:
            raise ValueError("Invalid KPI percentiles: " + name)
        gate = values["gate"]
        if gate == "wall":
            p99_limit = 33.3 if name.endswith("frame-delivery") else max(numbers["budget"] * 2, 33.3)
            if numbers["p95"] > numbers["budget"] or numbers["p99"] > p99_limit:
                raise ValueError("Wall-time budget exceeded: " + name)
        elif gate == "thread-cpu":
            cpu = float(values["cpu_p95"].removesuffix("ms"))
            if not math.isfinite(cpu) or not 0 < cpu <= numbers["budget"]:
                raise ValueError("CPU budget exceeded: " + name)
        elif gate == "wall-liveness":
            if numbers["max"] >= (100 if name.endswith("frame-delivery") else 1000):
                raise ValueError("Presentation stopped: " + name)
        else:
            raise ValueError("Unknown KPI gate: " + name)
        if numbers["budget"] < 100 and numbers["max"] >= 100:
            raise ValueError("Interactive wall-clock stall: " + name)
    return len(found)


def e2e(config, text):
    found = re.findall(r"^ui-e2e ([\w.-]+)$", text, re.M)
    expected = list(config["e2eTests"].values())
    if len(found) != len(expected) or set(found) != set(expected):
        raise ValueError("UI E2E evidence missing or duplicated.")
    return len(found)


def main():
    config = inventory()
    mode = sys.argv[1]
    if mode == "sources":
        sources(config)
        print("UI adjustment inventory and scenario registration verified.")
    elif mode in ("benchmark-tests", "e2e-tests"):
        print("\n".join(config["benchmarkTests" if mode == "benchmark-tests" else "e2eTests"]))
    elif mode in ("benchmarks", "e2e"):
        text = Path(sys.argv[2]).read_text()
        count = benchmarks(config, text) if mode == "benchmarks" else e2e(config, text)
        print(f"Verified {count} required UI {mode} results.")
    else:
        raise ValueError("Unknown UI coverage check.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        print("UI coverage refused: " + str(error), file=sys.stderr)
        sys.exit(1)
