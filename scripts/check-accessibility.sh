#!/bin/bash
# Points at buttons whose label is only a picture and that have no name
# for VoiceOver nearby (`accessibilityLabel`, a `Label`, or text). Prints
# file and line only. A check for the obvious misses, not a full audit.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$repo"
status=0
while IFS= read -r file; do
  awk -v f="$file" '
    /Button[^(]*\{|Button\(action:/ { start = NR; buf = "" }
    start && NR - start <= 6 { buf = buf $0 "\n" }
    start && NR - start == 6 {
      if (buf ~ /label: *\{ *Image\(systemName:/ && buf !~ /accessibilityLabel|Label\(|Text\(/) { print f ":" start; bad = 1 }
      start = 0
    }
    END { exit bad }
  ' "$file" || status=1
done < <(find Sources/MyMole -name '*.swift' | sort)
[ $status -eq 0 ] && echo "Accessibility: every picture-only button has a name."
exit $status
