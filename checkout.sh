#!/bin/sh

set -e

REPOS="
https://github.com/gnustep/libobjc2.git
https://github.com/gnustep/tools-make.git
https://github.com/gnustep/libs-base.git
https://github.com/gershwin-desktop/libs-gui.git
https://github.com/gnustep/libs-back.git
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
