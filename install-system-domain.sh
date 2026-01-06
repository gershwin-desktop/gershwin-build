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

cd "$REPOS_DIR/gershwin-system"
cp -R Library/* /System/Library/

cd "$REPOS_DIR/gershwin-workspace"
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

cd "$REPOS_DIR/gershwin-dbuskit"
./configure	
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-xcbkit"
$MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM -include unistd.h" -j"$CPUS" || exit 1
$MAKE_CMD install
$MAKE_CMD clean

cd "$REPOS_DIR/gershwin-uroswm"
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
