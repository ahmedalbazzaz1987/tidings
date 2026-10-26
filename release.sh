#!/bin/bash
# Publishes a new version to GitHub Releases (the in-app updater picks it up).
#   ./release.sh 1.0.1 "What changed"
# Needs the GitHub CLI:  brew install gh && gh auth login
set -euo pipefail
cd "$(dirname "$0")"
NEW="${1:?Usage: ./release.sh <version> [notes]}"
NOTES="${2:-Tidings $NEW}"
echo "$NEW" > VERSION
./build.sh --release
git add -A
git commit -m "Release $NEW" || true
git tag -f "v$NEW"
git push origin HEAD --tags
gh release create "v$NEW" "build/Tidings-$NEW.zip" --title "Tidings $NEW" --notes "$NOTES"
echo "✓ Published v$NEW — running copies of Tidings will offer the update."
