#!/bin/bash
# Proves that check-test-policy.sh catches what it's meant to: each case
# plants one violation in a throwaway copy and expects a refusal.
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0
case_() {
    local name=$1 file=$2 text=$3 work
    work="$(mktemp -d)"
    mkdir -p "$work/scripts" "$work/Sources/Ok" "$work/Sources/MyMole/Privileged" "$work/Tests/OkTests" "$(dirname "$work/$file")"
    echo '#if !APPSTORE' > "$work/Sources/MyMole/Privileged/PrivilegedClient.swift"
    cp scripts/check-test-policy.sh "$work/scripts/"
    echo 'let x = 1' > "$work/Sources/Ok/Ok.swift"
    echo 'let y = 1' > "$work/Tests/OkTests/Ok.swift"
    printf '%s\n' "$text" > "$work/$file"
    if "$work/scripts/check-test-policy.sh" >/dev/null 2>&1; then
        echo "✗ not caught: $name"; fail=1
    else
        echo "✓ caught: $name"
    fi
    rm -rf "$work"
}
case_ "a program started outside the runner" Sources/Ok/Bad.swift 'let p = Process()'
case_ "a shell call" Sources/Ok/Bad.swift 'system("rm -rf x")'
case_ "a delete outside the safe places" Sources/Ok/Bad.swift 'try FileManager.default.removeItem(atPath: p)'
case_ "a rename outside Undo and staging" Sources/Ok/Bad.swift 'rename(a, b)'
case_ "a replace outside the safe places" Sources/Ok/Bad.swift 'try FileManager.default.replaceItemAt(a, withItemAt: b)'
case_ "a test moving to the real Trash, deep in a subfolder" Tests/OkTests/Deep/Er/T.swift 'let o = Trasher.move([p])'
case_ "a test using the system backend" Tests/OkTests/T.swift 'let b = TrashBackend.system'
case_ "a test reading the real home" Tests/OkTests/T.swift 'let h = FileManager.default.homeDirectoryForCurrentUser'
case_ "a test using a live store" Tests/OkTests/T.swift 'let u = CleanupLog.defaultURL'
case_ "a test writing preferences" Tests/OkTests/T.swift 'let d = UserDefaults(suiteName: "x")'
case_ "an administrator prompt outside the privileged client" Sources/Ok/Bad.swift 'let s = "do shell script x with administrator privileges"'
case_ "the container's home instead of the real one" Sources/Ok/Bad.swift 'let h = NSHomeDirectory()'
exit $fail
