#!/bin/sh

# patch.sh - Apply patches for one or more projects.
#
# Usage: patch.sh [<project> ...]
#
# With no arguments, patches all projects that have a patch
# subdirectory under Library/Patches/.  With arguments, patches
# only the named projects.  Each project's source tree is expected
# at ../Sources/<project> relative to Library/Patches/.
#
# Exits 0 if all patches succeeded, non-zero otherwise.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="$(cd "$SCRIPT_DIR/../Patches" && pwd)"

_apply_one() {
    project="$1"
    repo_dir="$(cd "$SCRIPT_DIR/../Sources/$project" && pwd)"
    patch_dir="$PATCH_DIR/$project"

    [ -d "$repo_dir" ] || return 0
    [ -d "$patch_dir" ] || return 0

    cd "$repo_dir" || return 0

    applied=0
    already=0
    failed=0

    for f in "$patch_dir"/*.patch; do
        [ -f "$f" ] || continue

        echo "  $(basename "$f")..."
        err=$(patch -p1 -N -t -i "$f" 2>&1 >/dev/null)
        if [ $? -eq 0 ]; then
            applied=$((applied + 1))
        elif patch -p1 -R -f --dry-run -t -i "$f" >/dev/null 2>&1; then
            already=$((already + 1))
        else
            echo "$err"
            failed=$((failed + 1))
        fi

        find "$repo_dir" -name '*.rej' -delete 2>/dev/null
        find "$repo_dir" -name '*.orig' -delete 2>/dev/null
    done

    if [ "$failed" -gt 0 ]; then
        echo "$project: failed"
        return 1
    elif [ "$applied" -gt 0 ]; then
        echo "$project: applied"
    else
        echo "$project: already applied"
    fi

    return 0
}

exit_status=0

if [ $# -eq 0 ]; then
    for d in "$PATCH_DIR"/*/; do
        [ -d "$d" ] || continue
        project="${d%/}"
        project="${project##*/}"
        _apply_one "$project" || exit_status=1
    done
else
    for project in "$@"; do
        _apply_one "$project" || exit_status=1
    done
fi

exit "$exit_status"
