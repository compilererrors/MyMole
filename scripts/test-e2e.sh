#!/bin/bash
# UI or model-to-filesystem E2E. No user files, commands or real Trash.
set -euo pipefail
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$repo"
build=()
filter=AppEndToEndTests
ui=0
for option in "$@"; do
  case "$option" in
    --appstore) build=(--scratch-path .build/appstore-tests -Xswiftc -DAPPSTORE) ;;
    --ui) filter=UIInteractionEndToEndTests; ui=1 ;;
    *) echo 'Usage: scripts/test-e2e.sh [--appstore] [--ui]' >&2; exit 2 ;;
  esac
done
[ -z "${MYMOLE_GUARDED_TEST:-}" ] || { echo 'Start E2E tests outside another test run.' >&2; exit 2; }
[ -x /usr/bin/sandbox-exec ] || { echo 'E2E requires the macOS process sandbox.' >&2; exit 2; }
scripts/check-test-policy.sh
python3 -I scripts/check-ui-coverage.py sources
swift build --build-tests ${build[@]+"${build[@]}"}
bin=$(swift build --show-bin-path ${build[@]+"${build[@]}"})
test_targets=()
for target in MyMoleTests MyMolePackageTests; do
  if [ -x "$bin/$target.xctest/Contents/MacOS/$target" ]; then test_targets+=("$target"); fi
done
[ ${#test_targets[@]} -gt 0 ] || { echo 'E2E test bundle missing; the build did not produce it.' >&2; exit 1; }
helper="$(dirname "$(xcrun --find swift)")/../libexec/swift/pm/swiftpm-testing-helper"
helper="$(cd "$(dirname "$helper")" && pwd -P)/$(basename "$helper")"
root=$(mktemp -d /private/tmp/mymole-ui-smoke-e2e-XXXXXXXX)
outside=$(mktemp -d /private/tmp/mymole-e2e-canary-XXXXXXXX)
root_lease=$(python3 -I scripts/test-cleanup.py lease "$root")
outside_lease=$(python3 -I scripts/test-cleanup.py lease "$outside")
token=$(uuidgen)
test_name="mymole-e2e-${token//-/}"
if [ "$ui" = 1 ]; then
  host="$root/Synthetic UI Host.app/Contents"
  mkdir -p "$host/MacOS"
  cp "$helper" "$host/MacOS/$test_name"
  helper="$host/MacOS/$test_name"
  python3 -I - "$host/Info.plist" "$test_name" <<'PY'
import plistlib,sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({'CFBundleIdentifier':'com.example.mymole.synthetic-ui-host.'+sys.argv[2].removeprefix('mymole-e2e-').lower(),
                  'CFBundleExecutable':sys.argv[2], 'CFBundleName':'Synthetic UI Host',
                  'CFBundlePackageType':'APPL', 'NSPrincipalClass':'NSApplication'},stream)
PY
else
  cp "$helper" "$root/$test_name"
  helper="$root/$test_name"
fi
usertmp=$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P)
items="$usertmp/TemporaryItems"
mkdir -p "$items"
atomic_prefix="NSIRD_${test_name}_"
mkdir -m 700 "$root/home" "$root/trash" "$root/tmp" "$root/cache" "$root/cases"
lease=$(python3 -I - "$root" "$outside" "$token" <<'PY'
from pathlib import Path
import json,os,sys
root,outside=map(Path,sys.argv[1:3])
token=sys.argv[3]
(root/'.mymole-synthetic-run.json').write_text(json.dumps({'purpose':'mymole-synthetic-run','token':token}))
(outside/'sentinel').write_text(token)
print(json.dumps({str(p):[p.stat().st_dev,p.stat().st_ino,os.getuid()] for p in [root,outside]}))
PY
)
cleanup() {
  local result=$?
  trap - EXIT
  if python3 -I - "$root" "$outside" "$token" "$lease" "$items" "$atomic_prefix" <<'PY'
from pathlib import Path
import json,os,shutil,stat,sys
root,outside=map(Path,sys.argv[1:3])
token=sys.argv[3]
assert not root.is_symlink() and not outside.is_symlink()
lease=json.loads(sys.argv[4])
for p in [root,outside]:
    s=p.lstat()
    assert stat.S_ISDIR(s.st_mode) and [s.st_dev,s.st_ino,s.st_uid]==lease[str(p)]
    assert p.parent==Path('/private/tmp') and s.st_uid==os.getuid() and s.st_mode & 0o077==0
for p in [root/'.mymole-synthetic-run.json',outside/'sentinel']:
    s=p.lstat()
    assert stat.S_ISREG(s.st_mode) and s.st_uid==os.getuid() and s.st_mode & 0o077==0
assert json.loads((root/'.mymole-synthetic-run.json').read_text())=={'purpose':'mymole-synthetic-run','token':token}
assert (outside/'sentinel').read_text()==token
items=Path(sys.argv[5])
prefix=sys.argv[6]
assert prefix=='NSIRD_mymole-e2e-'+token.replace('-','')+'_'
for p in items.glob(prefix+'*'):
    s=p.lstat()
    assert stat.S_ISDIR(s.st_mode) and not p.is_symlink() and s.st_uid==os.getuid() and s.st_mode & 0o077==0
    shutil.rmtree(p)
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
home_dir=$(cd ~ && pwd -P)
quote() { local escaped=${1//\\/\\\\}; printf '"%s"' "${escaped//\"/\\\"}"; }
profile="$root/profile.sb"
{
  echo '(version 1)'
  echo '(allow default)'
  echo '(deny file-write*)'
  echo '(deny network* (remote ip))'
  echo '(deny appleevent-send)'
  echo '(deny process-exec)'
  echo "(allow process-exec (literal \"/bin/sh\") (literal \"/bin/bash\") (literal $(quote "$helper")))"
  echo '(deny file-read* (subpath "/Users") (subpath "/Volumes") (subpath "/private/tmp") (subpath "/private/var/folders"))'
  echo "(deny file-read* (subpath $(quote "$home_dir")))"
  # Path verification and dyld need directory metadata, never user contents.
  echo '(allow file-read-metadata)'
  # Descriptor-based safety checks open these ancestors without enumerating.
  echo '(allow file-read* (literal "/private/tmp") (literal "/tmp"))'
  echo "(allow file-read* (subpath $(quote "$bin")) (subpath $(quote "$root")) (subpath $(quote "${root#/private}")) (literal $(quote "$outside/sentinel")))"
  echo "(allow file-write* (subpath $(quote "$root")) (subpath $(quote "${root#/private}")) (literal \"/dev/null\"))"
  # Foundation stages atomic writes in NSIRD directories. A unique process
  # name confines that staging to this run's unguessable namespace.
  python3 -I - "$items" "$atomic_prefix" <<'PY'
import json,re,sys
items,prefix=sys.argv[1:]
for parent in {items,items.removeprefix('/private')}:
    print('(allow file-read* (literal '+json.dumps(parent)+'))')
    assert re.fullmatch(r'/[A-Za-z0-9_/-]+',parent) and re.fullmatch(r'[A-Za-z0-9_-]+',prefix)
    pattern='^'+parent+'/'+prefix+r'[^/]+(/.*)?$'
    print('(allow file-read* file-write* (regex #'+json.dumps(pattern)+'))')
PY
} > "$profile"
probe() { /usr/bin/sandbox-exec -f "$profile" /bin/sh -c "$1" >/dev/null 2>"$root/probe-error.txt"; }
# These are our own canaries. A broken sandbox never probes production data.
probe "exec 3>>'$outside/sentinel'" && { echo 'E2E refused: outside writes were allowed.' >&2; exit 1; }
probe "exec 3>'$root/tmp/allowed'" || { cat "$root/probe-error.txt" >&2; echo 'E2E refused: fixture writes were blocked.' >&2; exit 1; }
probe '/usr/bin/true' && { echo 'E2E refused: external programs were allowed.' >&2; exit 1; }
echo 'E2E guard verified: owned fixtures and nonce-bound atomic staging only; outside canary protected; external commands, Apple events and remote network blocked.'
developer=$(xcode-select -p)
filters=("$filter")
if [ "$ui" = 1 ]; then
  # Native tracking loops and focus state are process local. Give each UI
  # scenario a fresh AppKit instance, while retaining the strict file sandbox.
  python3 -I scripts/check-ui-coverage.py e2e-tests > "$root/scenarios"
  filters=()
  while IFS= read -r scenario; do filters+=("$scenario"); done < "$root/scenarios"
fi
: > "$root/ui-evidence"
result=0
for target in "${test_targets[@]}"; do
 for filter in "${filters[@]}"; do
  if TMPDIR="$root/tmp/" HOME="$root/home" CFFIXED_USER_HOME="$root/home" XDG_CACHE_HOME="$root/cache" \
    MYMOLE_GUARDED_TEST=1 MYMOLE_E2E=1 MYMOLE_UI_E2E="$ui" MYMOLE_E2E_ROOT="$root" MYMOLE_E2E_TOKEN="$token" MYMOLE_E2E_CANARY="$outside/sentinel" \
    PLATFORM="$developer/Platforms/MacOSX.platform/Developer" python3 -I "$repo/scripts/run-test-process.py" --timeout 90 /usr/bin/sandbox-exec -f "$profile" /bin/sh -c \
    'DYLD_FRAMEWORK_PATH="$PLATFORM/Library/Frameworks" DYLD_LIBRARY_PATH="$PLATFORM/usr/lib" exec "$@"' sh \
    "$helper" --test-bundle-path "$bin/$target.xctest/Contents/MacOS/$target" \
    --testing-library swift-testing --filter "$filter" --no-parallel \
    --event-stream-output-path "$root/$target.$filter.events.jsonl" | tee -a "$root/ui-evidence"; then
    python3 -I "$repo/scripts/check-test-events.py" "$root/$target.$filter.events.jsonl" --no-skips || result=1
  else
    result=1
  fi
 done
done
if [ "$ui" = 1 ]; then python3 -I scripts/check-ui-coverage.py e2e "$root/ui-evidence" || result=1; fi
exit "$result"
