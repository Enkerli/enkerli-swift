#!/bin/bash
#
# The transport addresses are written down twice. Do they agree?
#
#   Scripts/check-transport.sh
#
# `Sources/Kernel/include/PluginParameterAddresses.h` is what the render thread
# acts on. `Sources/AUHost/TransportParameters.swift` restates the same three
# numbers, because `AUHost` deliberately does not depend on `Kernel` — a synth
# links `AUHost` and must not drag the MIDI kernel in with it.
#
# That duplication is the price of the layering and this is the receipt. A
# mismatch would be silent and horrible: a host would show a "Play" control, a
# person would automate it, and the kernel would receive a value at an address
# it does not know.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEADER="$HERE/Sources/Kernel/include/PluginParameterAddresses.h"
SWIFT="$HERE/Sources/AUHost/TransportParameters.swift"

status=0
for pair in "playMelody:play" "playbackDirection:direction" "hostSync:hostSync"; do
    c_name="${pair%%:*}"
    swift_name="${pair##*:}"
    c_value=$(grep -oE "^[[:space:]]*$c_name = [0-9]+" "$HEADER" | grep -oE "[0-9]+$")
    swift_value=$(grep -oE "case $swift_name = [0-9]+" "$SWIFT" | grep -oE "[0-9]+$")
    if [ -z "$c_value" ] || [ -z "$swift_value" ]; then
        echo "  FAIL  $c_name — could not read it from both files"
        status=1
    elif [ "$c_value" = "$swift_value" ]; then
        echo "  PASS  $c_name = $c_value in both"
    else
        echo "  FAIL  $c_name is $c_value in the kernel and $swift_value in AUHost —"
        echo "        a host would show the control and the kernel would never hear it"
        status=1
    fi
done

# And the identifiers, which are what a host saves automation against. A renamed
# identifier does not break the address, but it does orphan every automation
# lane a person has already drawn.
for name in playMelody playbackDirection hostSync; do
    if grep -q "\"$name\"" "$SWIFT"; then
        echo "  PASS  $name keeps its identifier"
    else
        echo "  FAIL  $name is not the identifier AUHost declares — existing"
        echo "        automation lanes in saved sessions would be orphaned"
        status=1
    fi
done

echo
if [ $status -eq 0 ]; then echo "transport: OK"; else echo "transport: FAILURES"; fi
exit $status
