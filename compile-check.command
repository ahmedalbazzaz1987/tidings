#!/bin/bash
cd "$(dirname "$0")"
./build.sh > build.log 2>&1
echo "EXIT=$?" >> build.log
