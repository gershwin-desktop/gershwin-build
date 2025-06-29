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
export NGSTEP_INSTALLATION_DOMAIN="SYSTEM"

mkdir -p /System/Library/Preferences
cp $WORKDIR/GNUstep.conf /System/Library/Preferences
. /System/Library/Preferences/GNUstep.conf

cd "$REPOS_DIR/tools-make"
./configure \
  --enable-importing-config-file \
  --with-config-file=/System/Library/Preferences/GNUstep.conf \
  --with-library-combo=ng-gnu-gnu
$MAKE_CMD || exit 1
$MAKE_CMD install
$MAKE_CMD clean
$MAKE_CMD distclean

. /System/Library/Makefiles/GNUstep.sh

mkdir -p "$REPOS_DIR/libobjc2/Build"
cd "$REPOS_DIR/libobjc2/Build"
cmake .. \
  -DGNUSTEP_INSTALL_TYPE=SYSTEM \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++
$MAKE_CMD -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

export GNUSTEP_INSTALLATION_DOMAIN="SYSTEM"

cd "$REPOS_DIR/libs-base"
./configure --with-installation-domain=SYSTEM
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

cd "$REPOS_DIR/gershwin-workspace"
./configure
$MAKE_CMD
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-systempreferences"
$MAKE_CMD
$MAKE_CMD install
$MAKE_CMD clean