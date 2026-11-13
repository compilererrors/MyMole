#!/bin/bash
# Collects the interface's phrases into Localization/Localizable.xcstrings,
# the string catalog a translation starts from. The compiler lists every
# phrase the code hands to a localizing API (SwiftUI's text views, the
# shared views, String(localized:)) for both editions, and
# xcstringstool merges them into the catalog. English is the source
# language and needs no entries of its own; a phrase no longer in the code
# is dropped unless it has been translated.
# Usage: scripts/sync-strings.sh [--check]
#   --check  fails if the catalog isn't in step with the code, changing nothing
set -euo pipefail

fail() { printf '%s\n' "$*" >&2; exit 1; }
repo=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$repo"
catalog=Localization/Localizable.xcstrings
check=0
[ "${1:-}" = --check ] && check=1
xcrun --find xcstringstool >/dev/null 2>&1 || fail "xcstringstool is part of Xcode; install Xcode to sync the strings."

# Each Swift file names its own list, so two files of one name would mix.
dupes=$(find Sources -name '*.swift' -exec basename {} \; | sort | uniq -d)
[ -z "$dupes" ] || fail "Swift files share a name, so their phrases would mix: $dupes"

work=$(mktemp -d "${TMPDIR:-/tmp}/mymole-strings-XXXXXX")
work=$(cd "$work" && pwd -P)
cleanup_lease=$(python3 -I scripts/test-cleanup.py lease "$work")
trap 'cleanup_result=$?; trap - EXIT; python3 -I scripts/test-cleanup.py clean "$work" "$cleanup_lease" || cleanup_result=1; exit "$cleanup_result"' EXIT

# Builds of their own, kept between runs: a file compiles again only when it
# changed, so its list from an earlier run still holds. Lists of files that
# no longer exist are dropped.
collect() {
  local name=$1; shift
  local data=".build/strings-$name/stringsdata"
  mkdir -p "$data"
  swift build --product MyMole --scratch-path ".build/strings-$name" \
    -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$repo/$data" "$@" \
    > "$work/build-$name.log" 2>&1 || { tail -20 "$work/build-$name.log"; fail "The $name build failed."; }
  for f in "$data"/*.stringsdata; do
    [ -e "$f" ] || continue
    base=$(basename "$f" .stringsdata)
    [ -n "$(find Sources -name "$base.swift" -print -quit)" ] || { continue; }
    cp "$f" "$work/$name-$base.stringsdata"
  done
}
collect direct
collect appstore -Xswiftc -DAPPSTORE

mkdir -p "$work/out"
if [ -f "$catalog" ]; then
  cp "$catalog" "$work/out/Localizable.xcstrings"
else
  printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n\n  },\n  "version" : "1.0"\n}\n' > "$work/out/Localizable.xcstrings"
fi
xcrun xcstringstool sync "$work/out/Localizable.xcstrings" --stringsdata "$work"/*.stringsdata

# A phrase gone from the code goes from the catalog too, unless translated.
python3 -I - "$work/out/Localizable.xcstrings" <<'EOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cat = json.load(f)
cat["strings"] = {
    k: v for k, v in cat["strings"].items()
    if not (v.get("extractionState") == "stale" and not v.get("localizations"))
}
with open(path, "w") as f:
    json.dump(cat, f, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    f.write("\n")
EOF

count=$(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["strings"]))' "$work/out/Localizable.xcstrings")
if [ $check = 1 ]; then
  [ -f "$catalog" ] || fail "There's no $catalog yet. Run scripts/sync-strings.sh."
  cmp -s "$catalog" "$work/out/Localizable.xcstrings" ||
    fail "$catalog isn't in step with the code. Run scripts/sync-strings.sh and include the change."
  echo "Strings: $catalog holds all $count phrases of the code."
else
  mkdir -p "$(dirname "$catalog")"
  cp "$work/out/Localizable.xcstrings" "$catalog"
  echo "Strings: $count phrases in $catalog."
fi
