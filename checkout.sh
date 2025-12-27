#!/bin/sh

set -e

REPOS="
https://github.com/gnustep/libobjc2.git
https://github.com/gershwin-desktop/tools-make.git
https://github.com/gershwin-desktop/libs-base.git
https://github.com/gershwin-desktop/libs-gui.git
https://github.com/gershwin-desktop/libs-back.git
https://github.com/gershwin-desktop/gershwin-system.git
https://github.com/gershwin-desktop/gershwin-workspace.git
https://github.com/gershwin-desktop/gershwin-systempreferences.git
https://github.com/gershwin-desktop/gershwin-rik-theme.git
https://github.com/gershwin-desktop/gershwin-terminal.git
https://github.com/gershwin-desktop/gershwin-textedit.git
https://github.com/gershwin-desktop/gershwin-dbuskit.git
https://github.com/gershwin-desktop/gershwin-xcbkit.git
https://github.com/gershwin-desktop/gershwin-uroswm.git
https://github.com/gershwin-desktop/gershwin-components.git
https://github.com/ArtifexSoftware/urw-base35-fonts.git
https://github.com/protamail/NimbusSans.git
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
