#!/bin/bash
# Double-click to build Tidings and install it in /Applications.
# Output is also saved to build.log so problems can be diagnosed.
cd "$(dirname "$0")"
set -o pipefail
./build.sh --install 2>&1 | tee build.log
echo "EXIT=$?" >> build.log
echo
read -n 1 -s -r -p "Press any key to close this window…"
