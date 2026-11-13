#!/bin/bash
# Guarded test run: builds the tests, then runs them inside the macOS process
# sandbox. Network is denied, and every home folder is unreadable except this
# repository: agent history, settings, other projects and the Trash included.
# Writes are allowed only inside a fresh run folder and the package's build
# folder; tests move files into a "Trash" folder of their own. A test that
# reached for real user data would fail instead of acting.
# Usage: scripts/test-guarded.sh [--appstore] [--release | --sanitize=thread] [--filter <pattern>]
set -euo pipefail
umask 077

# A sanitizer changes the build; the run itself is guarded the same way.
build=()
test_edition=direct
test_configuration=debug
while [ "$#" -gt 0 ]; do
  case "$1" in
    --appstore) test_edition=appstore ;;
    --release) test_configuration=release ;;
    --sanitize=thread) test_configuration=thread ;;
    *) break ;;
  esac
  shift
done
if [ "$test_configuration" = thread ]; then build=(--sanitize=thread); fi
if [ "$test_configuration" = release ]; then build=(-c release -Xswiftc -enable-testing); fi
if [ "$test_edition" = appstore ]; then
  test_scratch=.build/appstore-tests
  [ "$test_configuration" != release ] || test_scratch=.build/appstore-release-tests
  build+=(--scratch-path "$test_scratch" -Xswiftc -DAPPSTORE)
elif [ "$test_configuration" = release ]; then
  build+=(--scratch-path .build/release-tests)
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
outside=$(mktemp -d /private/tmp/mymole-guard-canary-XXXXXXXX)
root_lease=$(python3 -I scripts/test-cleanup.py lease "$root")
outside_lease=$(python3 -I scripts/test-cleanup.py lease "$outside")
lease=$(python3 -I - "$root" "$outside" <<'PY'
import json,os,sys
print(json.dumps({p:[os.lstat(p).st_dev,os.lstat(p).st_ino,os.getuid()] for p in sys.argv[1:]}))
PY
)
cleanup() {
  local result=$?
  trap - EXIT
  if python3 -I - "$root" "$outside" "$lease" <<'PY'
import json,os,shutil,stat,sys
lease=json.loads(sys.argv[3])
for path in sys.argv[1:3]:
    s=os.lstat(path)
    assert stat.S_ISDIR(s.st_mode) and [s.st_dev,s.st_ino,s.st_uid]==lease[path]
    assert s.st_uid==os.getuid() and s.st_mode & 0o077==0
sentinel=os.path.join(sys.argv[2],'sentinel')
s=os.lstat(sentinel)
assert stat.S_ISREG(s.st_mode) and s.st_uid==os.getuid() and s.st_mode & 0o077==0
with open(sentinel,'rb') as f: assert f.read()==b'synthetic canary'
PY
  then
    python3 -I scripts/test-cleanup.py clean "$root" "$root_lease" || result=1
    python3 -I scripts/test-cleanup.py clean "$outside" "$outside_lease" || result=1
  else
    result=1
  fi
  exit "$result"
}
trap cleanup EXIT
mkdir -m 700 "$root/tmp" "$root/cache"
printf 'synthetic canary' > "$outside/sentinel"

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
  echo "(deny file-read* (subpath $(quote "$outside")))"
  [ "${home#/Users/}" = "$home" ] && echo "(deny file-read* (subpath $(quote "$home")))"
  echo "(allow file-read* (subpath $(quote "$repo")) (literal \"/Users\") (literal $(quote "$home")))"
} > "$profile"

# Probe only our own canary, never user files or a real network endpoint.
sandboxed() { /usr/bin/sandbox-exec -f "$profile" /bin/sh -c "$1" >/dev/null 2>&1; }
if sandboxed "exec 3>>'$outside/sentinel'"; then fail "The sandbox let a test write outside its run folder."; fi
if sandboxed "exec 3<'$outside/sentinel'"; then fail "The sandbox let a test read its closed canary."; fi
sandboxed "ls '$repo/Package.swift'" || fail "The sandbox refused reading this repository."
sandboxed "touch '$root/tmp/probe'" || fail "The sandbox refused writes to the run's own folder."
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
matched=0
test_ui_home=""
test_deadline=600
if [ "${MYMOLE_UI_BENCHMARK:-}" = 1 ]; then
  mkdir -m 700 "$root/ui-home"
  test_ui_home="$root/ui-home"
  test_deadline=180
fi
targets=()
# SwiftPM can link one package test bundle or separate target bundles.
# Run every supported product present so an older layout cannot hide a newer one.
combined="$bin/MyMolePackageTests.xctest/Contents/MacOS/MyMolePackageTests"
[ ! -x "$combined" ] || targets+=(MyMolePackageTests)
for dir in Tests/*/; do
  target=$(basename "$dir")
  bundle="$bin/$target.xctest/Contents/MacOS/$target"
  if [ -x "$bundle" ]; then
    targets+=("$target")
  elif [ ! -x "$combined" ]; then
    fail "Test bundle missing for $target; the build didn't produce it."
  fi
done
for target in "${targets[@]}"; do
  bundle="$bin/$target.xctest/Contents/MacOS/$target"
  parallel=()
  if [ "$target" = MyMolePackageTests ]; then
    # Blocking fixtures from all modules can exhaust the cooperative pool.
    # Serial cases still exercise the concurrency each individual test creates.
    parallel=(--no-parallel)
    for argument in "$@"; do
      case "$argument" in --parallel | --no-parallel) parallel=(); break ;; esac
    done
  fi
  echo "== $target"
  # macOS drops DYLD_ variables when it starts a system program such as
  # sandbox-exec, so they're set inside, right before the helper starts.
  if TMPDIR="$root/tmp/" MYMOLE_GUARDED_TEST=1 XDG_CACHE_HOME="$root/cache" PLATFORM="$developer/Platforms/MacOSX.platform/Developer" \
    INSERT="$insert" TEST_UI_HOME="$test_ui_home" python3 -I "$repo/scripts/run-test-process.py" --timeout "$test_deadline" /usr/bin/sandbox-exec -f "$profile" /bin/sh -c \
    '[ -z "$TEST_UI_HOME" ] || export HOME="$TEST_UI_HOME" CFFIXED_USER_HOME="$TEST_UI_HOME"; [ -z "$INSERT" ] || export DYLD_INSERT_LIBRARIES="$INSERT"; DYLD_FRAMEWORK_PATH="$PLATFORM/Library/Frameworks" DYLD_LIBRARY_PATH="$PLATFORM/usr/lib" exec "$@"' sh \
    "$helper" --test-bundle-path "$bundle" --testing-library swift-testing ${parallel[@]+"${parallel[@]}"} "$@" \
    --event-stream-output-path "$root/$target.events.jsonl"; then
    verified=0
    python3 -I "$repo/scripts/check-test-events.py" "$root/$target.events.jsonl" || verified=$?
    case "$verified" in
      0) matched=$((matched + 1)) ;;
      69) echo "No active tests in $target." ;;
      *) status=1 ;;
    esac
  else
    code=$?
    # Swift Testing's no-tests exit is expected for a filter that matches
    # another bundle. Every other error, including a failed test, stays fatal.
    if [ "$code" = 69 ]; then
      echo "No matching tests in $target."
    else
      echo "$target failed (exit $code)." >&2
      matched=$((matched + 1))
      status=1
    fi
  fi
done
[ "$matched" -gt 0 ] || fail "No test functions actually ran; check the filter and disabled suites."
exit $status
