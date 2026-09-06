#!/bin/bash
#
# Every plug-in on this foundation has a section in GAPS.md.
#
#   Scripts/check-gaps.sh
#
# What this can check is omission, and only omission. Whether a gap list is
# TRUE is not mechanically knowable — but a plug-in arriving with no list at all
# is, and that is the failure this file is most likely to have: the sixth
# plug-in gets built in an afternoon and its gaps are in somebody's head.
#
# A plug-in is any sibling checkout with an `Info.plist` declaring an
# AudioComponent whose manufacturer is ours. Same discovery the identity check
# uses, for the same reason: the set of plug-ins is a fact about the disk, not a
# list to keep in step by hand. The AU *type* comes from the plist too — seven
# of these are `aumi` MIDI processors and one is an `aumu` instrument.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIBLINGS="$(cd "$HERE/.." && pwd)"
GAPS="$HERE/GAPS.md"

status=0
found=0

[ -f "$GAPS" ] || { echo "FAIL: no GAPS.md in $HERE"; exit 1; }

while IFS= read -r plist; do
    repo="$(basename "$(dirname "$(dirname "$plist")")")"
    name=$(plutil -extract NSExtension.NSExtensionAttributes.AudioComponents.0.name raw -o - "$plist" 2>/dev/null) || continue
    code=$(plutil -extract NSExtension.NSExtensionAttributes.AudioComponents.0.subtype raw -o - "$plist" 2>/dev/null) || continue
    # The TYPE, not the string "aumi". This assumed every plug-in in the suite
    # was a MIDI processor, which was true until the synth arrived — and the
    # failure it produced was "SwiftVane has no section" when the section was
    # right there under `aumu Vayn`. A check that names the thing it is looking
    # for should look for the thing, not for the thing it expects.
    type=$(plutil -extract NSExtension.NSExtensionAttributes.AudioComponents.0.type raw -o - "$plist" 2>/dev/null) || continue
    case "$name" in "Enkerli: "*) ;; *) continue ;; esac
    product="${name#Enkerli: }"
    found=$((found + 1))

    if grep -q "^### $product — \`$type $code\`" "$GAPS"; then
        echo "  PASS  $product ($code) has a section"
    else
        echo "  FAIL  $product ($code) has no section in GAPS.md — a plug-in with"
        echo "        no written gaps has them anyway. Add:  ### $product — \`$type $code\`"
        status=1
    fi
done < <(find "$SIBLINGS" -maxdepth 4 -name Info.plist -path "*Extension*" 2>/dev/null | sort)

if [ "$found" -eq 0 ]; then
    echo "  SKIP  no sibling plug-ins found beside $HERE — NOT CHECKED"
fi

echo
if [ $status -eq 0 ]; then echo "gaps: OK"; else echo "gaps: FAILURES"; fi
exit $status
