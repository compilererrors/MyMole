#!/usr/bin/env python3
"""Bound the lifetime of our own child, including a blocked UI main thread."""
import argparse
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command or not 0 < args.timeout <= 3600:
        parser.error("a command and a timeout in (0, 3600] are required")
    # Popen owns the child and is its only reaper. An exited, unreaped child
    # retains its PID, so timeout handling cannot target a reused user PID.
    child = subprocess.Popen(args.command)
    try:
        return child.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        print("Owned test process exceeded its wall-clock deadline.", file=sys.stderr, flush=True)
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        return 124


if __name__ == "__main__":
    sys.exit(main())
