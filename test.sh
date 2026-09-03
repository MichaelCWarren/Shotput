#!/bin/bash
# Runs the test suite. Use this, not bare `swift test`.
#
# Testing.framework ships with Command Line Tools but references itself and
# lib_TestingInterop.dylib through @rpath, and SwiftPM adds neither search
# path, so bare `swift test` dies at dlopen. These four flags supply them.
#
# Do NOT move these into Package.swift as linkerSettings: that builds, runs
# ZERO tests, and exits 0 — a suite that always passes. Verified.
#
# With full Xcode installed, plain `swift test` works and this script is
# unnecessary.
set -euo pipefail
DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"

if [ ! -d "$FW/Testing.framework" ]; then
  echo "No Testing.framework under $DEV — running plain swift test." >&2
  exec swift test "$@"
fi

exec swift test \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -F -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$@"
