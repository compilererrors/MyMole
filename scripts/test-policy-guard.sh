#!/bin/bash
# Proves that check-test-policy.sh catches what it's meant to: each case
# plants one violation in a throwaway copy and expects a refusal.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
case_() {
    local name=$1 file=$2 text=$3 work cleanup_lease status=0
    work="$(mktemp -d "${TMPDIR:-/tmp}/mymole-policy-XXXXXX")"
    work="$(cd "$work" && pwd -P)"
    cleanup_lease=$(python3 -I scripts/test-cleanup.py lease "$work")
    mkdir -p "$work/scripts" "$work/Sources/Ok" "$work/Sources/MyMole/Privileged" "$work/Tests/OkTests" "$(dirname "$work/$file")"
    echo '#if !APPSTORE' > "$work/Sources/MyMole/Privileged/PrivilegedClient.swift"
    cp scripts/check-test-policy.sh "$work/scripts/"
    echo 'let x = 1' > "$work/Sources/Ok/Ok.swift"
    echo 'let y = 1' > "$work/Tests/OkTests/Ok.swift"
    if ! "$work/scripts/check-test-policy.sh" >/dev/null 2>&1; then
        echo "✗ clean fixture rejected: $name"
        python3 -I scripts/test-cleanup.py clean "$work" "$cleanup_lease"
        fail=1
        return
    fi
    printf '%s\n' "$text" > "$work/$file"
    "$work/scripts/check-test-policy.sh" >/dev/null 2>&1 || status=$?
    if [ "$status" -eq 1 ]; then
        echo "✓ caught: $name"
    else
        echo "✗ $name: exit $status, wanted 1"; fail=1
    fi
    python3 -I scripts/test-cleanup.py clean "$work" "$cleanup_lease"
}
case_ "a program started outside the runner" Sources/Ok/Bad.swift 'let p = Process()'
case_ "a shell call" Sources/Ok/Bad.swift 'system("echo synthetic")'
case_ "a delete outside the safe places" Sources/Ok/Bad.swift 'try FileManager.default.removeItem(atPath: p)'
case_ "a rename outside Undo and staging" Sources/Ok/Bad.swift 'rename(a, b)'
case_ "a replace outside the safe places" Sources/Ok/Bad.swift 'try FileManager.default.replaceItemAt(a, withItemAt: b)'
case_ "a test moving to the real Trash, deep in a subfolder" Tests/OkTests/Deep/Er/T.swift 'let o = Trasher.move([p])'
case_ "a test using the system backend" Tests/OkTests/T.swift 'let b = TrashBackend.system'
case_ "a test reading the real home" Tests/OkTests/T.swift 'let h = FileManager.default.homeDirectoryForCurrentUser'
case_ "a test using a live store" Tests/OkTests/T.swift 'let u = CleanupLog.defaultURL'
case_ "a test writing preferences" Tests/OkTests/T.swift 'let d = UserDefaults(suiteName: "x")'
case_ "a large test cannot hide real Trash calls through a short-circuited pipe" Tests/OkTests/T.swift "$(python3 -I -c 'print("let o = Trasher.move([p])\n" * 20000)')"
case_ "a private home in a test" Tests/OkTests/T.swift "$(printf '%s%s\n' 'let p = "/Users/' 'synthetic-private-example/Documents"')"
case_ "an administrator prompt outside the privileged client" Sources/Ok/Bad.swift 'let s = "do shell script x with administrator privileges"'
case_ "the container's home instead of the real one" Sources/Ok/Bad.swift 'let h = NSHomeDirectory()'
exit $fail
