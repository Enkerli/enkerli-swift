#!/bin/bash
#
# The kernel, compiled and run outside Xcode and outside SwiftPM.
#
# The render thread is C++ and neither test runner reaches it: `swift test`
# builds the Swift targets, and the Xcode test targets in the plug-in repos
# cannot see a package's C++ at all. So this is the check that means something
# about the one file in this package that runs under a real-time constraint.
#
#   Scripts/check-kernel.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

status=0
for harness in "$HERE"/Tests/Kernel/*-main.mm; do
    name="$(basename "$harness" -main.mm)"
    clang++ -std=c++20 -fobjc-arc -x objective-c++ "$harness" \
        -framework Foundation -framework AudioToolbox -framework CoreMIDI \
        -o "$BUILD/$name" || { echo "FAIL: $name did not compile"; status=1; continue; }
    "$BUILD/$name" || status=1
done

echo
if [ $status -eq 0 ]; then echo "kernel: OK"; else echo "kernel: FAILURES"; fi
exit $status
