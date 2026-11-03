#!/bin/bash
# Guarded test run: builds the tests, then runs them inside the macOS process
# sandbox. Network is denied, and every home folder is unreadable except this
# repository: agent history, settings, other projects and the Trash included.
# Writes are allowed only inside a fresh run folder and the package's build
# folder; tests move files into a "Trash" folder of their own. A test that
# reached for real user data would fail instead of acting.
# Usage: scripts/test-guarded.sh [--appstore | --sanitize=thread] [--filter <pattern>]
set -euo pipefail
umask 077

# A sanitizer changes the build; the run itself is guarded the same way.
build=()
if [ "${1:-}" = --sanitize=thread ]; then
  build=(--sanitize=thread)
  shift
elif [ "${1:-}" = --appstore ]; then
  # The App Store edition's code, built apart so the two never mix.
  build=(--scratch-path .build/appstore-tests -Xswiftc -DAPPSTORE)
  shift
fi

fail() { printf '%s\n' "$*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] && [ -x /usr/bin/sandbox-exec ] || fail "Guarded tests need macOS and its process sandbox."
[ -z "${MYMOLE_GUARDED_TEST:-}" ] || fail "Start guarded tests from a normal shell, not from inside another run."

repo=$(cd "$(dirname "$0")/.." && pwd -P)
home=$(cd ~ && pwd -P)
"$repo/scripts/check-test-policy.sh"

cd "$repo"
swift build --build-tests ${build[@]+"${build[@]}"}

root=$(mktemp -d "${TMPDIR:-/tmp}/mymole-guarded-test-XXXXXX")
root=$(cd "$root" && pwd -P)
trap 'rm -rf "$root"' EXIT
mkdir -m 700 "$root/tmp" "$root/cache"

usertmp=$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P)
quote() { local text=${1//\\/\\\\}; printf '"%s"' "${text//\"/\\\"}"; }
profile="$root/profile.sb"
{
  echo '(version 1)'
  echo '(allow default)'
  echo '(deny network* (remote ip))'
  echo '(deny file-write*)'
  # Foundation hands tests the user's own temporary folder whatever TMPDIR
  # says, so that one folder is writable too; the rest of /private/var/folders,
  # with every other process's caches, isn't.
  echo "(allow file-write* (subpath $(quote "$root")) (subpath $(quote "$repo/.build")) (subpath $(quote "$usertmp")) (subpath \"/dev\"))"
  # Every user's home is closed; only this repository is opened again (later
  # rules win), so agent history, settings and other projects stay out.
  echo '(deny file-read* (subpath "/Users"))'
  [ "${home#/Users/}" = "$home" ] && echo "(deny file-read* (subpath $(quote "$home")))"
  echo "(allow file-read* (subpath $(quote "$repo")) (literal \"/Users\") (literal $(quote "$home")))"
} > "$profile"

# The guard proves itself first: each probe must be refused.
sandboxed() { /usr/bin/sandbox-exec -f "$profile" /bin/sh -c "$1" >/dev/null 2>&1; }
probe="$home/.mymole-guard-probe-$$"
if sandboxed "touch '$probe'"; then rm -f "$probe"; fail "The sandbox let a test write to the home folder."; fi
if sandboxed "ls '$home/Documents'"; then fail "The sandbox let a test read the Documents folder."; fi
# Places a narrower list missed, probed by name only: listing them must fail.
for closed in .codex .claude .config Library/Preferences Workspace .Trash; do
  if [ -e "$home/$closed" ] && sandboxed "ls '$home/$closed'"; then fail "The sandbox let a test read ~/$closed."; fi
done
if sandboxed "touch '$home/.Trash/.mymole-guard-probe-$$'"; then fail "The sandbox let a test write to the Trash."; fi
sandboxed "ls '$repo/Package.swift'" || fail "The sandbox refused reading this repository."
if sandboxed "/usr/bin/nc -z -G 3 1.1.1.1 443"; then fail "The sandbox let a test reach the network."; fi
sandboxed "touch '$root/tmp/probe'" || fail "The sandbox refused writes to the run's own folder."
cachedir=$(getconf DARWIN_USER_CACHE_DIR)
if sandboxed "touch '$cachedir/.mymole-guard-probe-$$'"; then rm -f "$cachedir/.mymole-guard-probe-$$"; fail "The sandbox let a test write to the user's cache folder."; fi
echo "Guard: home reads (but this repository), home and Trash writes, and the network are refused; the run folder is writable."

# Each test bundle runs straight through Swift Testing's helper: building
# and package resolution stay outside, so nothing in the run needs to write
# to the toolchain's caches.
developer=$(xcode-select -p)
helper="$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper"
[ -x "$helper" ] || fail "Swift Testing's helper wasn't found in the toolchain."
bin=$(swift build --show-bin-path ${build[@]+"${build[@]}"})
# The helper loads each bundle after it starts, too late for the sanitizer
# runtime the bundle links; it's loaded into the helper from the start.
insert=""
if [ "${build[0]:-}" = --sanitize=thread ]; then
  insert=$(ls "$(dirname "$(xcrun --find clang)")"/../lib/clang/*/lib/darwin/libclang_rt.tsan_osx_dynamic.dylib 2>/dev/null | head -n 1)
  [ -n "$insert" ] || fail "The Thread Sanitizer runtime wasn't found in the toolchain."
fi
status=0
for dir in Tests/*/; do
  target=$(basename "$dir")
  bundle="$bin/$target.xctest/Contents/MacOS/$target"
  [ -x "$bundle" ] || fail "Test bundle missing for $target; the build didn't produce it."
  echo "== $target"
  # macOS drops DYLD_ variables when it starts a system program such as
  # sandbox-exec, so they're set inside, right before the helper starts.
  TMPDIR="$root/tmp/" MYMOLE_GUARDED_TEST=1 XDG_CACHE_HOME="$root/cache" PLATFORM="$developer/Platforms/MacOSX.platform/Developer" \
    INSERT="$insert" /usr/bin/sandbox-exec -f "$profile" /bin/sh -c \
    '[ -z "$INSERT" ] || export DYLD_INSERT_LIBRARIES="$INSERT"; DYLD_FRAMEWORK_PATH="$PLATFORM/Library/Frameworks" DYLD_LIBRARY_PATH="$PLATFORM/usr/lib" exec "$@"' sh \
    "$helper" --test-bundle-path "$bundle" --testing-library swift-testing "$@" ||
    status=1
done
exit $status
