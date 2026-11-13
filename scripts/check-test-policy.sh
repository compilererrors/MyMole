#!/bin/bash
# Checks that tests can't reach real user data: no hard-coded home paths, no
# live default locations for stores and logs, and no real cleanup run. And
# that the app moves and deletes only through the places built for it.
# Prints file names only, never file contents.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$repo"
failed=0
fail() { printf '%s\n' "$*" >&2; failed=1; }

# Every test file, in any folder under Tests.
while IFS= read -r file; do
  name=${file#Tests/}
  # Live stores and logs live in the real Application Support folder.
  grep -qE '\.default(URL|Base)\b' "$file" && fail "Tests must pass their own store and log locations: $name"
  # Real home folders, except as fake strings that are never touched.
  grep -oE '"/Users/[^/"]+' "$file" | grep -vE '"/Users/(synthetic|me|other)$' >/dev/null &&
    fail "Tests must name only synthetic home folders: $name"
  # The real home folder only as a string: to show it's protected or how it's written.
  grep -qE 'NSHomeDirectory\(\)|Home\.path' "$file" && ! grep -qE 'isProtected|Breakable\.path' "$file" &&
    fail "Tests may use the real home folder only as a string: $name"
  # Real system programs run only through injected runners.
  grep -qE 'CommandRunner\.live\b|MaintenanceEngine\(role: *\.(user|root)\)$' "$file" && fail "Tests must inject a command runner: $name"
  grep -qE 'SystemCleanRules\.(scan|remove)\(\)' "$file" && fail "System cleanup tests must use their own roots: $name"
  # Moves go to a test's own "Trash" folder; the real Trash only in the test that's off unless asked for.
  grep -nE 'Trasher\.(move|moveToTrash)\(' "$file" | grep -v 'backend' | grep . >/dev/null && ! grep -q 'MYMOLE_REAL_TRASH' "$file" &&
    fail "Tests must move into their own Trash folder (backend:): $name"
  grep -qE 'TrashBackend\.system|backend: *\.system' "$file" && fail "Tests must not use the system Trash backend: $name"
  grep -qE 'homeDirectoryForCurrentUser' "$file" && fail "Tests must not use the real home folder: $name"
  [ "$name" != MyMoleTests/TestDefaults.swift ] && grep -qE 'UserDefaults(\.standard|\(suiteName)|@AppStorage' "$file" &&
    fail "Tests must not write preferences; macOS keeps them in the real home folder: $name"
done < <(find Tests -name '*.swift' | sort)

# Every move to the Trash goes through Trasher's gate, and only known
# places delete: the helper's staging and safe removal, MyMole's own
# snapshot store, and emptying the Trash.
only() {
  local pattern=$1 file allowed; shift
  # ONLY_EXCEPT names lines that match but are no file operation.
  for file in $( (grep -rnE "$pattern" Sources || true) | grep -vE "${ONLY_EXCEPT:-^$}" | cut -d: -f1 | sort -u); do
    allowed=0
    for ok in "$@"; do [ "$file" = "$ok" ] && allowed=1; done
    [ $allowed = 1 ] || fail "Only $* may use $pattern: $file"
  done
}
only 'trashItem\(' Sources/StorageKit/Trash.swift
only '\.recycle\(' Sources/MyMole/Uninstall/AppsModel.swift
# NSToolbar's removeItem(at:) takes an item off the window's toolbar.
ONLY_EXCEPT='^[^:]+:[0-9]+: *toolbar\.removeItem\(at: ' only '(removeItem|moveItem|replaceItem)\(at(Path)?:|replaceItemAt\(|(^|[^a-zA-Z_.])(unlink|unlinkat|rmdir|removefile)\(' Sources/StorageKit/Trash.swift Sources/StorageKit/Snapshot.swift \
  Sources/StorageKit/TrashEmpty.swift Sources/StorageKit/SpillTable.swift \
  Sources/PrivilegedKit/SystemCleanup.swift Sources/PrivilegedKit/SecureRemove.swift Sources/PrivilegedKit/Staging.swift Sources/PrivilegedKit/SystemLeftovers.swift \
  Sources/PrivilegedKit/ApplicationTrash.swift
# Renames move things too: Undo, staging, and the helper's exact app/Trash move.
only '(^|[^a-zA-Z_.])(rename|renamex_np|renameat|renameatx_np)\(' Sources/StorageKit/Trash.swift Sources/PrivilegedKit/Staging.swift Sources/PrivilegedKit/ApplicationTrash.swift
# Root is asked for in one place only, and never in the App Store edition.
only 'administrator privileges|/usr/bin/osascript|NSAppleScript' Sources/MyMole/Privileged/PrivilegedClient.swift
only 'AEDeterminePermissionToAutomateTarget|AESendMessage' Sources/MyMole/Access/FinderAppTrash.swift
grep -q '#if !APPSTORE' Sources/MyMole/Privileged/PrivilegedClient.swift ||
  fail "The administrator prompt must be left out of the App Store edition (#if !APPSTORE)."
# The sandboxed edition's home is the user's real one, not the container.
only 'NSHomeDirectory\(\)' Sources/StorageKit/Home.swift
# Programs start only through the command runner and the process list reader.
only 'Process\(\)|posix_spawn|NSTask|(^|[^a-zA-Z_.])(system|popen|execv|execve|fork)\(' Sources/StorageKit/CommandRunner.swift Sources/SystemKit/SystemReaders.swift

if [ $failed = 0 ]; then echo 'Test policy: tests use their own folders, stores, runners, roots and Trash; moves, renames, deletions and programs go only through their own places.'; fi
exit $failed
