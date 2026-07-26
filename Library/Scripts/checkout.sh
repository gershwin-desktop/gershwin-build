#!/bin/sh
set -e

# Enable pinned commits with:
#   PINNED=1 ./Library/Scripts/checkout.sh
#
# Build against a feature branch where it exists (e.g. a "dev" channel) with:
#   BRANCH=dev ./Library/Scripts/checkout.sh
# For each repo that HAS the branch on its remote it is cloned/checked out;
# repos without it fall back to their default branch. Unset (the default)
# leaves behaviour identical to before.

PINNED="${PINNED:-0}"

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
"

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

    if [ -d "$NAME/.git" ]; then
        echo "Updating $NAME..."
        (
            cd "$NAME"
            git fetch --all --tags
            if [ -n "$USE_BRANCH" ]; then
                echo "  $NAME: checking out branch '$USE_BRANCH'"
                git checkout "$USE_BRANCH"
            fi
            if [ "$PINNED" -eq 0 ]; then
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

# Apply pinned commits if requested
if [ "$PINNED" -eq 1 ]; then
    echo "Checking out pinned commits..."

    checkout_commit() {
        REPO="$1"
        COMMIT="$2"
        (
            cd "$REPO"
            git checkout "$COMMIT"
        )
    }
    # These are upstream libraries, we pin them in order to not develop for a moving target
    checkout_commit libobjc2                     4148a3d
    checkout_commit libs-back                    bf3b3ce # Patch by okt
    checkout_commit libs-base                    caa0816
    checkout_commit libs-gui                     8be638c
    checkout_commit swift-corelibs-libdispatch   4876f91
    checkout_commit tools-make                   50cf961
    checkout_commit libs-steptalk                2b57b46

fi

# The following do not seeem to be causing showstoppers currently
# checkout_commit gershwin-windowmanager       1f3cc1c
# checkout_commit gershwin-components          3395d99
# checkout_commit gershwin-eau-theme           4babcb0
# checkout_commit gershwin-assets              4deb482
# checkout_commit gershwin-workspace           1bc3b98
# checkout_commit gershwin-system              cdeafb6
# checkout_commit gershwin-systempreferences   8d49f50
# checkout_commit gershwin-terminal            71124e3
# checkout_commit gershwin-textedit            3df6db8

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
