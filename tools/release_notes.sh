#!/bin/bash
#
# Prints the CHANGELOG.md entry for one version, for its GitHub Release.
#
#     tools/release_notes.sh 1.2.0
#
# Fails if CHANGELOG.md has no entry for that version, so a release can't go out
# without one.

set -euo pipefail

version="${1:?usage: $0 <version>}"
changelog="$(dirname "$0")/../CHANGELOG.md"

notes="$(awk -v heading="## [$version]" '
    index($0, heading) == 1 { found = 1; next }
    found && /^## \[/ { exit }
    found && /^\[[0-9]/ { exit }
    found { print }
' "$changelog")"

# Drop blank lines at the start and the end.
notes="$(printf '%s\n' "$notes" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"

if [ -z "$notes" ]; then
    echo "error: CHANGELOG.md has no entry for $version. Add one before releasing." >&2
    exit 1
fi
printf '%s\n' "$notes"
