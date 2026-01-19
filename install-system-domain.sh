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
mkdir -p /System/Library
cp -R Library/* /System/Library/
. /System/Library/Preferences/GNUstep.conf
export GNUSTEP_INSTALLATION_DOMAIN="SYSTEM"

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
$MAKE_CMD distclean 2>/dev/null || true
./configure \
  --enable-importing-config-file \
  --with-config-file=/System/Library/Preferences/GNUstep.conf \
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
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM -include unistd.h" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-windowmanager/WindowManager"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-components/Menu"
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

# Fonts
FONTS=/System/Library/Fonts
mkdir -p "$FONTS"

# Luxi Sans, same author as Lucida Grande (it lacks the Command key symbol)
cd "$REPOS_DIR/xorg__font__bh-ttf"
cp luxis*.ttf "$FONTS"/ || exit 1
cp COPYRIGHT.BH "$FONTS"/ || exit 1

# GhostScript equivalents for PostScript Level 1 and 2 fonts like Helvetica
cd "$REPOS_DIR/urw-base35-fonts"
cp fonts/*.otf "$FONTS"/ || exit 1
cp -r fontconfig /System/Library/Preferences/Fontconfig || exit 1
# Use fixed Nimbus Sans from protamail/NimbusSans (replaces URW version)
# See: https://github.com/ArtifexSoftware/urw-base35-fonts/issues/25
rm -f "$FONTS"/NimbusSans*.otf
cd "$REPOS_DIR/NimbusSans"
cp NimbusSans*.ttf "$FONTS"/ || exit 1

# Inter (it has the Command key symbol)
cd "$REPOS_DIR/CTAN_Inter/inter/texmf/fonts/opentype/public/inter"
cp Inter-Regular.otf "$FONTS"/ || exit 1
cp Inter-Italic.otf "$FONTS"/ || exit 1
cp Inter-Medium.otf "$FONTS"/ || exit 1
cp Inter-MediumItalic.otf "$FONTS"/ || exit 1
cp Inter-Bold.otf "$FONTS"/ || exit 1
cp Inter-BoldItalic.otf "$FONTS"/ || exit 1

# Source Code Pro (Monospaced font for coding)
cd "$REPOS_DIR/source-code-pro"
cp OTF/SourceCodePro-Regular.otf "$FONTS"/ || exit 1
cp OTF/SourceCodePro-Medium.otf "$FONTS"/ || exit 1
cp OTF/SourceCodePro-Bold.otf "$FONTS"/ || exit 1

find "$FONTS"
