#!/bin/bash
# Double-click to upload the source code to github.com/ahmedalbazzaz1987/tidings.
cd "$(dirname "$0")"
REMOTE="https://github.com/ahmedalbazzaz1987/tidings.git"
VERSION="$(tr -d '[:space:]' < VERSION)"
if [ ! -d .git ]; then
  git init -b main
  git remote add origin "$REMOTE"
  git fetch origin main && git reset --soft origin/main 2>/dev/null || true
fi
git add -A
git commit -m "Tidings $VERSION" || echo "Nothing new to commit."
git push -u origin main
echo
echo "Done. Source is at https://github.com/ahmedalbazzaz1987/tidings"
read -n 1 -s -r -p "Press any key to close this window…"
