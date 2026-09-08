#!/bin/bash
# Refresh the vendored MeetingScribe core from a local checkout of the upstream package.
# Usage: scripts/sync-meetingscribe-kit.sh [path to upstream checkout, default ../Транскрибация]
set -euo pipefail

UPSTREAM="${1:-../Транскрибация}"
KIT="$(cd "$(dirname "$0")/.." && pwd)/MeetingScribeKit"
[[ -f "$UPSTREAM/Package.swift" ]] || { echo "error: upstream package not found at $UPSTREAM" >&2; exit 1; }

# Tracked sources only (no tests, CLI, private samples); Package.swift and README.md in the copy are our own.
git -C "$UPSTREAM" ls-files Sources App/MeetingScribeUI \
  | grep -v '^Sources/CLI/' \
  | rsync -a --delete --files-from=- "$UPSTREAM/" "$KIT/"
cp "$UPSTREAM/App/MeetingScribe/Localizable.xcstrings" "$KIT/Localizable.xcstrings"
echo "Synced $(git -C "$UPSTREAM" rev-parse --short HEAD) from $UPSTREAM into $KIT"
echo "Now run: scripts/merge-meetingscribe-strings.py"
