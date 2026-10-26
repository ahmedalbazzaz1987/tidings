#!/bin/bash
# Double-click to build a release zip for GitHub (Apple Silicon + Intel).
cd "$(dirname "$0")"
./build.sh --release 2>&1 | tee build.log
echo
echo "Upload this file to a new GitHub release:"
ls -1 build/Tidings-*.zip
open build
echo
read -n 1 -s -r -p "Press any key to close this window…"
