#!/bin/sh
# Runs every test: the Swift unit tests and the Python hook tests.
# The extra flags let `swift test` find the Testing framework when only the
# Command Line Tools are installed (no full Xcode).
set -e
cd "$(dirname "$0")/.."
CLT="$(xcode-select -p)"
FLAGS=""
if [ -d "$CLT/Library/Developer/Frameworks/Testing.framework" ]; then
  FW="$CLT/Library/Developer/Frameworks"
  FLAGS="-Xswiftc -F -Xswiftc $FW -Xlinker -F -Xlinker $FW -Xlinker -rpath -Xlinker $FW -Xlinker -rpath -Xlinker $CLT/Library/Developer/usr/lib"
fi
swift test $FLAGS 2>&1 | grep -E '^(✘|error)|Test run with|Suite .* (passed|failed)' 
/usr/bin/python3 -m unittest discover -s tests -v
