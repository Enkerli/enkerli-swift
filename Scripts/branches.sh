#!/bin/bash
#
# Switch every checkout in the suite to the same branch, together.
#
#   Scripts/branches.sh                # what branch is everything on?
#   Scripts/branches.sh features       # switch all of them, creating if needed
#   Scripts/branches.sh main
#
# ── Why this has to be all-or-nothing ───────────────────────────────────────
#
# Every plug-in repo depends on this package **by path** — `../enkerli-swift`,
# not by version — so there is exactly one copy of the foundation on disk and
# whichever branch it is on is the one every plug-in compiles against.
#
# That has a consequence worth stating before somebody discovers it: you cannot
# have MelGen on `main` and SwiftVane on `features` at the same time if the two
# branches of the package differ. The branch is a property of the *suite*, not
# of a repo.
#
# Which is also why there is one `features` branch per repo rather than a branch
# per feature. Per-feature branches would each need a matching package branch to
# build against, and the coordination cost lands on whoever is trying to hear a
# plug-in rather than on whoever wrote the feature.
#
# `main` stays the MVP: it is what gets played, and every claim in a README is
# about it. `features` is where build-back happens and where a claim is only as
# good as the last run.
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIBLINGS="$(cd "$HERE/.." && pwd)"
WANTED="${1:-}"

# The package first, always: a plug-in switched before the foundation it builds
# against is a plug-in that fails to compile for a reason nobody will guess.
repos=("$HERE")
while IFS= read -r plist; do
    repo="$(cd "$(dirname "$(dirname "$plist")")" && pwd)"
    name=$(plutil -extract NSExtension.NSExtensionAttributes.AudioComponents.0.name raw -o - "$plist" 2>/dev/null) || continue
    case "$name" in "Enkerli: "*) ;; *) continue ;; esac
    [ -d "$repo/.git" ] || continue
    case " ${repos[*]} " in *" $repo "*) ;; *) repos+=("$repo") ;; esac
done < <(find "$SIBLINGS" -maxdepth 4 -name Info.plist -path "*Extension*" 2>/dev/null | sort)

status=0

if [ -z "$WANTED" ]; then
    printf "%-24s %-16s %s\n" "REPO" "BRANCH" "STATE"
    for repo in "${repos[@]}"; do
        branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
        dirty=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        printf "%-24s %-16s %s\n" "$(basename "$repo")" "$branch" \
            "$([ "$dirty" = 0 ] && echo clean || echo "$dirty uncommitted")"
    done
    exit 0
fi

# Refuse to move anything while something is dirty. Switching branches under
# uncommitted work is how a feature ends up half on each side of the line.
blocked=0
for repo in "${repos[@]}"; do
    if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then
        echo "  DIRTY  $(basename "$repo") — commit or stash before switching"
        blocked=1
    fi
done
[ "$blocked" -eq 0 ] || { echo; echo "branches: nothing switched"; exit 1; }

for repo in "${repos[@]}"; do
    name="$(basename "$repo")"
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$WANTED"; then
        git -C "$repo" checkout -q "$WANTED" && echo "  ON     $name  $WANTED"
    else
        git -C "$repo" checkout -q -b "$WANTED" && echo "  NEW    $name  $WANTED"
    fi || { echo "  FAIL   $name"; status=1; }
done

echo
if [ $status -eq 0 ]; then echo "branches: all on $WANTED"; else echo "branches: FAILURES"; fi
exit $status
