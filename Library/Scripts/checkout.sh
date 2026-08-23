#!/bin/sh
set -e

# The upstream (non-Gershwin) libraries are pinned by default, so the tree we
# build is the tree Library/Patches/ was written against. Track their moving
# HEADs instead — e.g. to check whether a pin can be advanced — with:
#   PINNED=0 ./Library/Scripts/checkout.sh
# Gershwin's own repositories are never pinned; they always track their branch.
#
# Build against a feature branch where it exists (e.g. a "dev" channel) with:
#   BRANCH=dev ./Library/Scripts/checkout.sh
# For each repo that HAS the branch on its remote it is cloned/checked out;
# repos without it fall back to their default branch. Unset (the default)
# leaves behaviour identical to before.

PINNED="${PINNED:-1}"

# Repositories to skip cloning/updating, given as a space- or comma-separated
# list of repo names (e.g. SKIP_REPOS="gershwin-workspace"). Useful when the
# source tree for a repo is provided by other means, such as a CI checkout of
# the repo under test.
SKIP_REPOS="${SKIP_REPOS:-}"
SKIP_REPOS=$(printf '%s' "$SKIP_REPOS" | tr ',' ' ')

# Optional branch to prefer for every repo that has it (e.g. BRANCH=dev). A repo
# without the branch silently falls back to its default branch, so a partial
# rollout works. Independent of PINNED: the pinned upstream libs don't carry
# such a branch, so their pins are unaffected.
BRANCH="${BRANCH:-}"
ON_BRANCH=""     # repos actually placed on $BRANCH (for the end-of-run summary)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOS_DIR="$SCRIPT_DIR/../Sources"

REPOS="
https://github.com/apple/swift-corelibs-libdispatch.git
https://github.com/gnustep/libobjc2.git
https://github.com/gnustep/tools-make.git
https://github.com/gnustep/libs-base.git
https://github.com/gnustep/libs-gui.git
https://github.com/gnustep/libs-back.git
https://github.com/gnustep/libs-av.git
https://github.com/gnustep/libs-steptalk.git
https://github.com/gershwin-desktop/gershwin-system.git
https://github.com/gershwin-desktop/gershwin-workspace.git
https://github.com/gershwin-desktop/gershwin-systempreferences.git
https://github.com/gershwin-desktop/gershwin-eau-theme.git
https://github.com/gershwin-desktop/gershwin-terminal.git
https://github.com/gershwin-desktop/gershwin-textedit.git
https://github.com/gershwin-desktop/gershwin-windowmanager.git
https://github.com/gershwin-desktop/gershwin-components.git
https://github.com/gershwin-desktop/gershwin-assets.git
https://github.com/gershwin-desktop/docs.git
"

# Pinned commits, as "<repo name> <commit>". These are upstream libraries; we pin
# them so we don't develop against a moving target and so the patches under
# Library/Patches/ keep applying. Every entry here must be a non-Gershwin repo —
# Gershwin's own repositories track their branch and are deliberately absent.
# Refreshed 2026-07-26. Every patch under Library/Patches/ was dry-run against
# these commits. libs-gui is held a day behind its HEAD: dropdown-tracking.patch
# does not apply to the 2026-07-26 commits.
PINS="
libobjc2                    c9f4002
libs-back                   bbcc3de
libs-base                   5bda522
libs-gui                    8f804fd
swift-corelibs-libdispatch  95f592a
tools-make                  4e31a03
libs-av                     26566e2
libs-steptalk               2b57b46
"

# Echo the pinned commit for repo $1, or nothing if the repo is not pinned.
pin_for() {
    echo "$PINS" | while read -r _name _commit _rest; do
        if [ "$_name" = "$1" ]; then
            echo "$_commit"
            break
        fi
    done
}

mkdir -p "$REPOS_DIR"
cd "$REPOS_DIR"

for REPO in $REPOS; do
    NAME=$(basename "$REPO" .git)

    case " $SKIP_REPOS " in
        *" $NAME "*)
            echo "Skipping $NAME (in SKIP_REPOS)..."
            continue
            ;;
    esac

    # Resolve which branch to use for this repo. $BRANCH is generic — any branch
    # name works (e.g. BRANCH=dev, or a feature branch you want to test). Probed
    # in the parent shell (not a subshell) so we can print a summary at the end.
    # A repo that doesn't have the branch falls back to its default branch.
    USE_BRANCH=""
    if [ -n "$BRANCH" ]; then
        if git ls-remote --exit-code --heads "$REPO" "$BRANCH" >/dev/null 2>&1; then
            USE_BRANCH="$BRANCH"
            ON_BRANCH="$ON_BRANCH $NAME"
        else
            echo "  $NAME: no '$BRANCH' branch — using default branch"
        fi
    fi

    # Only a repo that is about to be moved onto a pin skips the pull; everything
    # else (all of Gershwin's own repos) still fast-forwards as it always did.
    PIN=""
    if [ "$PINNED" -eq 1 ]; then
        PIN=$(pin_for "$NAME")
    fi

    if [ -d "$NAME/.git" ]; then
        echo "Updating $NAME..."
        (
            cd "$NAME"
            git fetch --all --tags
            if [ -n "$USE_BRANCH" ]; then
                echo "  $NAME: checking out branch '$USE_BRANCH'"
                git checkout "$USE_BRANCH"
            fi
            if [ -z "$PIN" ]; then
                # An earlier pinned run leaves the repo on a detached HEAD, and
                # --ff-only then has no branch to advance. Put it back on its
                # default branch first, so PINNED=0 un-pins an existing tree
                # rather than silently leaving it at the old pin.
                if [ -z "$USE_BRANCH" ] && ! git symbolic-ref -q HEAD >/dev/null; then
                    DEFAULT_BRANCH=$(git symbolic-ref -q --short refs/remotes/origin/HEAD || true)
                    if [ -z "$DEFAULT_BRANCH" ]; then
                        git remote set-head origin -a >/dev/null 2>&1 || true
                        DEFAULT_BRANCH=$(git symbolic-ref -q --short refs/remotes/origin/HEAD || true)
                    fi
                    DEFAULT_BRANCH="${DEFAULT_BRANCH#origin/}"
                    if [ -n "$DEFAULT_BRANCH" ]; then
                        echo "  $NAME: detached — returning to '$DEFAULT_BRANCH'"
                        git checkout "$DEFAULT_BRANCH"
                    fi
                fi
                git pull --ff-only
            fi
        )
    else
        echo "Cloning $NAME..."
        if [ -n "$USE_BRANCH" ]; then
            echo "  $NAME: cloning branch '$USE_BRANCH'"
        fi
        git clone ${USE_BRANCH:+--branch "$USE_BRANCH"} "$REPO"
    fi
done

# Summary of which repos were placed on $BRANCH (only when BRANCH is in play).
if [ -n "$BRANCH" ]; then
    if [ -n "$ON_BRANCH" ]; then
        echo "Branch '$BRANCH' used for:$ON_BRANCH"
    else
        echo "No repository has a '$BRANCH' branch — all on their default branch."
    fi
fi

# Apply the pinned commits (the default; PINNED=0 opts out). A repo listed in
# SKIP_REPOS was never cloned here, so it has nothing to pin.
if [ "$PINNED" -eq 1 ]; then
    echo "Checking out pinned commits..."

    # Fed by redirection rather than a pipe so `set -e` still applies to the body.
    while read -r NAME COMMIT _rest; do
        [ -n "$NAME" ] || continue
        [ -d "$NAME/.git" ] || continue
        echo "  $NAME -> $COMMIT"
        (
            cd "$NAME"
            git checkout "$COMMIT"
        )
    done <<EOF
$PINS
EOF
fi

# Gershwin's own repositories are intentionally NOT in $PINS: pinning them would
# mean the build no longer picks up our own work. These commits are kept only as
# a record of a known-good set. Do not move them into $PINS.
# gershwin-windowmanager       1f3cc1c
# gershwin-components          3395d99
# gershwin-eau-theme           4babcb0
# gershwin-assets              4deb482
# gershwin-workspace           1bc3b98
# gershwin-system              cdeafb6
# gershwin-systempreferences   8d49f50
# gershwin-terminal            71124e3
# gershwin-textedit            3df6db8

# Lower CMake version requirements
# Use a temp-file approach for in-place sed to avoid -i portability issues
# across GNU/Linux, FreeBSD and OpenBSD.  All three support -E for ERE.
sed_inplace_ere() {
    _pat="$1"; _file="$2"
    _tmp="$(mktemp)"
    sed -E "$_pat" "$_file" > "$_tmp" && mv "$_tmp" "$_file"
}
sed_inplace_ere \
    's/cmake_minimum_required\(VERSION 3\.[0-9]+(\.\.\.3\.[0-9]+)?\)/cmake_minimum_required(VERSION 3.20...3.99)/g' \
    swift-corelibs-libdispatch/CMakeLists.txt

echo "Done."
