#!/bin/sh
# Builds Debug into ./build and prints only diagnostics.
cd "$(dirname "$0")/.." && xcodegen generate >/dev/null && \
xcodebuild -project Stickspace.xcodeproj -scheme Stickspace -configuration Debug -derivedDataPath build build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)|The following build commands failed" -A3 | grep -v "iOSSimulator"
