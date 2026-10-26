#!/bin/bash
# Double-click once. Creates a private signing certificate so macOS stops asking
# for Keychain access after every Tidings update, then rebuilds and reinstalls.
cd "$(dirname "$0")"
chmod +x setup-signing.sh build.sh
./setup-signing.sh
echo
echo "Rebuilding Tidings with the new signature…"
./build.sh --install 2>&1 | tee build.log
echo
read -n 1 -s -r -p "Press any key to close this window…"
