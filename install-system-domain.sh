#!/bin/sh
set -e

if [ "$FROM_MAKEFILE" != "1" ]; then
    echo "This script must be run from the Makefile."
    exit 1
fi

. ./functions.sh
detect_platform
export_vars

export REPOS_DIR="$WORKDIR/repos"
export GNUSTEP_INSTALLATION_DOMAIN="SYSTEM"

cd "$REPOS_DIR/tools-make"
./configure \
  --with-config-file=/System/Library/Preferences/GNUstep.conf \
  --with-layout=gershwin \
  --with-library-combo=ng-gnu-gnu
$MAKE_CMD || exit 1
$MAKE_CMD install
$MAKE_CMD clean
$MAKE_CMD distclean

. /System/Library/Makefiles/GNUstep.sh

export GNUSTEP_INSTALLATION_DOMAIN="SYSTEM"


echo "Building/installing libobjc2..."
if [ -d "$REPOS_DIR/libobjc2/Build" ] ; then
  rm -rf "$REPOS_DIR/libobjc2/Build"
  mkdir -p "$REPOS_DIR/libobjc2/Build"
else
  mkdir -p "$REPOS_DIR/libobjc2/Build"
fi

cd "$REPOS_DIR/libobjc2/Build"

cmake .. \
  -DGNUSTEP_INSTALL_TYPE=SYSTEM \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DEMBEDDED_BLOCKS_RUNTIME=ON

"$MAKE_CMD" || exit 1
"$MAKE_CMD" install || exit 1

cd "$REPOS_DIR/libs-base"
./configure
$MAKE_CMD -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/libs-gui"
./configure
$MAKE_CMD -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/libs-back"
export fonts=no
./configure
$MAKE_CMD -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-globaldefaults"
mkdir -p /System/Library/Preferences/GlobalDefaults
cp -R System/Library/Preferences/GlobalDefaults/* /System/Library/Preferences/GlobalDefaults/

cd "$REPOS_DIR/gershwin-workspace"
./configure
$MAKE_CMD -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-systempreferences"
$MAKE_CMD -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-rik-theme"
$MAKE_CMD -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-universe-apps/Terminal"
# On glibc based Linux systems, -liconv should not be used as iconv is part of glibc
if [ $(uname) == "Linux" ] ; then
  sed -i -e 's|-liconv ||g' GNUmakefile.preamble
fi
$MAKE_CMD -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-universe-apps/TextEdit"
$MAKE_CMD -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean
