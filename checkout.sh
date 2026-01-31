#!/bin/sh
set -e

# Enable pinned commits with:
#   PINNED=1 ./checkout.sh

PINNED="${PINNED:-0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPOS_DIR="$SCRIPT_DIR/repos"

REPOS="
https://github.com/apple/swift-corelibs-libdispatch.git
https://github.com/gnustep/libobjc2.git
https://github.com/gnustep/tools-make.git
https://github.com/gnustep/libs-base.git
https://github.com/gnustep/libs-gui.git
https://github.com/gnustep/libs-back.git
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

    if [ -d "$NAME/.git" ]; then
        echo "Updating $NAME..."
        (
            cd "$NAME"
            git fetch --all --tags
            if [ "$PINNED" -eq 0 ]; then
                git pull --ff-only
            fi
        )
    else
        echo "Cloning $NAME..."
        git clone "$REPO"
    fi
done

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
    checkout_commit libobjc2                     4148a3d
    checkout_commit libs-back                    bf3b3ce // Patch by okt
    checkout_commit libs-base                    050c6cc
    checkout_commit libs-gui                     8be638c
    checkout_commit swift-corelibs-libdispatch   ac3302c
    checkout_commit tools-make                   8964f83
    checkout_commit gershwin-components          3395d99
    checkout_commit gershwin-eau-theme           4babcb0
fi

# The following do not seeem to be causing the issue and are hence no longer pinned for the moment
# checkout_commit gershwin-workspace           1bc3b98
# checkout_commit gershwin-windowmanager       1f3cc1c
# checkout_commit gershwin-assets              4deb482
# checkout_commit gershwin-system              cdeafb6
# The following seem unlikely to be causing the issue
# checkout_commit gershwin-systempreferences   8d49f50
# checkout_commit gershwin-terminal            71124e3
# checkout_commit gershwin-textedit            3df6db8

# Lower CMake version requirements
sed -i -E \
's/cmake_minimum_required\(VERSION 3\.[0-9]+(\.\.\.3\.[0-9]+)?\)/cmake_minimum_required(VERSION 3.20...3.99)/g' \
swift-corelibs-libdispatch/CMakeLists.txt

echo "Done."
