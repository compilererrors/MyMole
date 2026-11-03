#!/bin/bash
# Proves that check-no-strings.sh fails when the binary can't be read and
# finds a forbidden string wherever it is, under the shell CI uses. Uses
# only its own temporary folder.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
expect() {
    local want="$1" label="$2"; shift 2
    local got=0
    scripts/check-no-strings.sh "$@" >/dev/null 2>&1 || got=$?
    if [ "$got" -eq "$want" ]; then echo "✓ $label"; else echo "✗ $label: exit $got, wanted $want"; fail=1; fi
}

filler() { for _ in $(seq 1 "$1"); do echo "ordinary synthetic text line"; done; }
{ echo FORBIDDEN_MARK; filler 200000; } > "$work/start"
{ filler 100000; echo FORBIDDEN_MARK; filler 100000; } > "$work/middle"
{ filler 200000; echo FORBIDDEN_MARK; } > "$work/end"
filler 1000 > "$work/clean"
: > "$work/empty"

expect 2 "a missing binary fails" "$work/missing" FORBIDDEN_MARK
expect 2 "an empty binary fails" "$work/empty" FORBIDDEN_MARK
expect 1 "a match at the start is found" "$work/start" FORBIDDEN_MARK
expect 1 "a match in the middle is found" "$work/middle" FORBIDDEN_MARK
expect 1 "a match at the end is found" "$work/end" FORBIDDEN_MARK
expect 0 "a clean binary passes" "$work/clean" FORBIDDEN_MARK
expect 1 "any of several patterns is found" "$work/middle" 'osascript|FORBIDDEN_MARK'

exit $fail
