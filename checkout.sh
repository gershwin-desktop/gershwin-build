#!/bin/sh

set -e

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
https://github.com/gershwin-desktop/gershwin-dbuskit.git
https://github.com/gershwin-desktop/gershwin-windowmanager.git
https://github.com/gershwin-desktop/gershwin-components.git
https://github.com/gershwin-desktop/gershwin-assets.git
"

mkdir -p repos
cd repos

for REPO in $REPOS; do
    NAME=$(basename "$REPO" .git)
    if [ -d "$NAME/.git" ]; then
        echo "Updating $NAME..."
        cd "$NAME"
        git pull --ff-only
        cd ..
    else
        echo "Cloning $NAME..."
        git clone "$REPO"
    fi
done

# Lower CMake version requirements
sed -i -E 's/cmake_minimum_required\(VERSION 3\.[0-9]+(\.\.\.3\.[0-9]+)?\)/cmake_minimum_required(VERSION 3.20...3.99)/g' swift-corelibs-libdispatch/CMakeLists.txt
