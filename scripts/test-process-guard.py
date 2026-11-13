#!/usr/bin/env python3
"""Only newly created, disposable Python children are used by this check."""
import subprocess
import sys
from pathlib import Path

runner = str(Path(__file__).with_name("run-test-process.py"))
prefix = [sys.executable, "-I", runner, "--timeout", "0.15", sys.executable, "-I", "-c"]
completed = subprocess.run(prefix + ["raise SystemExit(17)"], capture_output=True)
assert completed.returncode == 17
timed_out = subprocess.run(prefix + ["import time; time.sleep(30)"], capture_output=True, timeout=10)
assert timed_out.returncode == 124 and b"wall-clock deadline" in timed_out.stderr
print("Owned-process watchdog: exit propagation and blocked-child timeout verified.")
