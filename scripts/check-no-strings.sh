#!/bin/bash
# Fails unless the binary could be read and none of its strings match the
# pattern. The strings are written to a file first, so a binary that can't
# be read fails instead of passing for one with nothing to find, and an
# early match can't cut the read short.
# Usage: scripts/check-no-strings.sh <binary> <extended regex>
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <binary> <pattern>" >&2; exit 64; }
binary="$1"
pattern="$2"
cleanup_tool="$(cd "$(dirname "$0")" && pwd -P)/test-cleanup.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/mymole-binary-check-XXXXXX")"
work="$(cd "$work" && pwd -P)"
cleanup_lease=$(python3 -I "$cleanup_tool" lease "$work")
out="$work/strings"
trap 'cleanup_result=$?; trap - EXIT; python3 -I "$cleanup_tool" clean "$work" "$cleanup_lease" || cleanup_result=1; exit "$cleanup_result"' EXIT

if ! strings -a "$binary" > "$out"; then
    echo "✗ couldn't read the strings of $binary" >&2
    exit 2
fi
if [ ! -s "$out" ]; then
    echo "✗ no strings read from $binary" >&2
    exit 2
fi
status=0
grep -Eq -- "$pattern" "$out" || status=$?
case $status in
    0) echo "✗ $binary contains: $(grep -Eo -- "$pattern" "$out" | sort -u | tr '\n' ' ')" >&2; exit 1 ;;
    1) echo "✓ $binary has none of: $pattern" ;;
    *) echo "✗ couldn't search the strings of $binary" >&2; exit 2 ;;
esac
