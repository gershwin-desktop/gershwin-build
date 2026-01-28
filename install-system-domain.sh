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

cd "$REPOS_DIR/gershwin-system"
$MAKE_CMD install
export GNUSTEP_INSTALLATION_DOMAIN="SYSTEM"

cd "$REPOS_DIR/gershwin-assets"
cp -R Library/* /System/Library/

# Patch libdispatch
echo "Patching libdispatch..."
( cd "$REPOS_DIR" && ./apply_swift-corelibs-libdispatch_patch.sh )

# Build libdispatch first - provides BlocksRuntime needed by tools-make configure
echo "Building/installing libdispatch..."
if [ -d "$REPOS_DIR/swift-corelibs-libdispatch/Build" ] ; then
  rm -rf "$REPOS_DIR/swift-corelibs-libdispatch/Build"
fi
mkdir -p "$REPOS_DIR/swift-corelibs-libdispatch/Build"

cd "$REPOS_DIR/swift-corelibs-libdispatch/Build"

cmake .. \
  -DCMAKE_INSTALL_PREFIX=/System/Library \
  -DCMAKE_INSTALL_LIBDIR=Libraries \
  -DINSTALL_DISPATCH_HEADERS_DIR=/System/Library/Headers/dispatch \
  -DINSTALL_BLOCK_HEADERS_DIR=/System/Library/Headers \
  -DINSTALL_OS_HEADERS_DIR=/System/Library/Headers/os \
  -DINSTALL_PRIVATE_HEADERS=ON \
  -DCMAKE_INSTALL_MANDIR=Documentation/man \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++

"$MAKE_CMD" -j"$CPUS" || exit 1
"$MAKE_CMD" install || exit 1

# Build tools-make - can now find _Block_copy in libdispatch's BlocksRuntime
# Use libobjc_LIBS=" " to prevent configure from adding -lobjc to link tests
echo "Building/installing tools-make..."
cd "$REPOS_DIR/tools-make"
git checkout feat/add-gershwin-layout
$MAKE_CMD distclean 2>/dev/null || true
./configure \
  --with-config-file=/System/Library/Preferences/GNUstep.conf \
  --with-layout=gershwin \
  --with-library-combo=ng-gnu-gnu \
  --with-objc-lib-flag=" " \
  LDFLAGS="-L/System/Library/Libraries" \
  CPPFLAGS="-I/System/Library/Headers" \
  libobjc_LIBS=" "
$MAKE_CMD || exit 1
$MAKE_CMD install

. /System/Library/Makefiles/GNUstep.sh

# Build libobjc2 - gnustep-config now available for paths
echo "Building/installing libobjc2..."
if [ -d "$REPOS_DIR/libobjc2/Build" ] ; then
  rm -rf "$REPOS_DIR/libobjc2/Build"
fi
mkdir -p "$REPOS_DIR/libobjc2/Build"

cd "$REPOS_DIR/libobjc2/Build"

cmake .. \
  -DGNUSTEP_INSTALL_TYPE=SYSTEM \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DEMBEDDED_BLOCKS_RUNTIME=OFF \
  -DBlocksRuntime_INCLUDE_DIR=/System/Library/Headers \
  -DBlocksRuntime_LIBRARIES=/System/Library/Libraries/libBlocksRuntime.so

"$MAKE_CMD" -j"$CPUS" || exit 1
"$MAKE_CMD" install || exit 1

export GNUSTEP_INSTALLATION_DOMAIN="SYSTEM"

# Patch libdispatch
echo "Patching libs-base..."
( cd "$REPOS_DIR" && ./apply_nsrunloop_patch.sh )

cd "$REPOS_DIR/libs-base"
./configure \
  --with-dispatch-include=/System/Library/Headers \
  --with-dispatch-library=/System/Library/Libraries
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

# Hook into tools-make to inject build time and git hash into Info-gnustep.plist files
cd "$REPOS_DIR/gershwin-components/plistupdate"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
sh -e ./setup-integration.sh
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-workspace"
git checkout feat/add-gershwin-layout
autoreconf -fi
./configure
$MAKE_CMD -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-systempreferences"
$MAKE_CMD -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-eau-theme"
$MAKE_CMD -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-terminal"
# On glibc based Linux systems, -liconv should not be used as iconv is part of glibc
# TODO: Port this fix to GNUmakefile.preamble properly
if [ "$(uname)" = "Linux" ] ; then
  sed -i -e 's|-liconv ||g' GNUmakefile.preamble
  $MAKE_CMD CPPFLAGS="-D__GNU__ -DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1 # Do not include termio.h which is outdated
else
  $MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
fi
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-textedit"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-windowmanager/XCBKit"
git checkout feat/add-gershwin-layout
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM -include unistd.h" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-windowmanager/WindowManager"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/Menu"
git checkout feat/add-gershwin-layout
./configure || exit 1
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/LoginWindow"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/appwrap"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/Display"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/Keyboard"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/GlobalShortcuts"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/Screenshot"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/Printers"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/Network"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/Sound"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/Sharing"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/Console"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/SudoAskPass"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/Processes"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

echo ""
echo "Done."
