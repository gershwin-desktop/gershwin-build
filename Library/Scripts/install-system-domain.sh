#!/bin/sh
set -e

if [ "$FROM_MAKEFILE" != "1" ]; then
    echo "This script must be run from the Makefile."
    exit 1
fi

export PATH="${PATH}:$(cd "$(dirname "$0")" && pwd -P)"
. ./Library/Scripts/functions.sh
detect_platform
export_vars

export REPOS_DIR="$WORKDIR/Library/Sources"

# Detect NextBSD - libdispatch is provided by the base system
if [ -d "/usr/lib/system" ]; then
  NEXTBSD=1
  echo "NextBSD detected: base ships a HAVE_MACH libdispatch in /usr/lib/system (daemons);"
  echo "  the Gershwin domain builds its own non-Mach libdispatch into /System/Library/Libraries"
  # config.guess does not recognize NextBSD; tell configure we are FreeBSD
  ARCH=$(uname -m)
  case "$ARCH" in
    amd64) ARCH="x86_64" ;;
  esac
  BUILD_FLAG="--build=${ARCH}-nextbsd-freebsd"
  CMAKE_SYSTEM_FLAG="-DCMAKE_SYSTEM_NAME=FreeBSD"
else
  NEXTBSD=0
  BUILD_FLAG=""
  CMAKE_SYSTEM_FLAG=""
fi

# On OpenBSD, X11 headers/libs live under /usr/X11R6, which clang does not search
# by default. Export the flags once here so they apply to every build stage:
#   - CFLAGS/OBJCFLAGS/CPPFLAGS let the compilers (and autoconf configure scripts)
#     find the X11 headers.
#   - LDFLAGS and LIBRARY_PATH let the linker find libX11 regardless of how a given
#     package's makefiles handle link flags.
if [ "$(uname -s)" = "OpenBSD" ]; then
  export CFLAGS="${CFLAGS:+$CFLAGS }-I/usr/X11R6/include"
  export OBJCFLAGS="${OBJCFLAGS:+$OBJCFLAGS }-I/usr/X11R6/include"
  export CPPFLAGS="${CPPFLAGS:+$CPPFLAGS }-I/usr/X11R6/include"
  export LDFLAGS="${LDFLAGS:+$LDFLAGS }-L/usr/X11R6/lib"
  export LIBRARY_PATH="/usr/X11R6/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
fi

# Source the GNUstep environment, which is installed by the corelibs stage via
# tools-make.  The corelibs stage sources it itself at the right moment, so this
# is only used by the individual app/component stages when they are run on their
# own (e.g. "make workspace" in CI after "make corelibs").
ensure_gnustep_env() {
  if [ ! -f /System/Library/Makefiles/GNUstep.sh ]; then
    echo "GNUstep environment not found at /System/Library/Makefiles/GNUstep.sh."
    echo "Build the core libraries first:  make corelibs"
    exit 1
  fi
  . /System/Library/Makefiles/GNUstep.sh
  export GNUSTEP_INSTALLATION_DOMAIN="SYSTEM"
}

build_corelibs() {
  cd "$REPOS_DIR/gershwin-system"
  $MAKE_CMD install
  export GNUSTEP_INSTALLATION_DOMAIN="SYSTEM"

  cd "$REPOS_DIR/gershwin-assets"
  cp -R Library/* /System/Library/

  # Patch libdispatch (FreeBSD timer-spin fix; harmless on other platforms).
  echo "Patching libdispatch..."
  patch.sh swift-corelibs-libdispatch

  # Gershwin apps must link the portable, NON-Mach libdispatch. On stock
  # FreeBSD/Linux this happens automatically (no <mach/mach.h> present, so the
  # HAVE_MACH code is never compiled). NextBSD, however, ships libmach's
  # <mach/mach.h> system-wide, so libdispatch's `#if __has_include(<mach/mach.h>)`
  # guards auto-enable the Darwin Mach/QoS (direct-knote) event backend. That
  # backend is wrong for FreeBSD's kqueue (0x0100 == EV_FORCEONESHOT; udata is not
  # part of knote identity) and breaks GNUstep's fd-based dispatch sources — most
  # visibly, the global menu's WindowMonitor never tracks the frontmost app.
  # So on NextBSD we force those guards off to reproduce the stock non-Mach build
  # and install it to /System/Library/Libraries, which Gershwin binaries' RUNPATH
  # resolves ahead of /usr/lib/system. The NextBSD base's HAVE_MACH libdispatch in
  # /usr/lib/system is left in place for the system daemons (launchd/XPC/notifyd).
  DISPATCH_EXTRA_FLAGS=""
  if [ "$NEXTBSD" -eq 1 ]; then
    echo "NextBSD: forcing non-Mach libdispatch for the Gershwin domain"
    ( cd "$REPOS_DIR/swift-corelibs-libdispatch" && \
      grep -rl "__has_include(<mach/mach.h>)" . 2>/dev/null | grep -vE "/\.git/|/Build/" | \
      xargs -r sed -i.nbsdbak "s#__has_include(<mach/mach.h>)#0#g" )
    DISPATCH_EXTRA_FLAGS="-DHAVE_MACH=OFF"
  fi

  # Build libdispatch first - provides BlocksRuntime needed by tools-make configure
  echo "Building/installing libdispatch..."
  if [ -d "$REPOS_DIR/swift-corelibs-libdispatch/Build" ] ; then
    rm -rf "$REPOS_DIR/swift-corelibs-libdispatch/Build"
  fi
  mkdir -p "$REPOS_DIR/swift-corelibs-libdispatch/Build"

  cd "$REPOS_DIR/swift-corelibs-libdispatch/Build"

  # $CMAKE_SYSTEM_FLAG (-DCMAKE_SYSTEM_NAME=FreeBSD on NextBSD, empty elsewhere):
  # without it CMake can't match NextBSD's uname to a platform module, so it never
  # sets CMAKE_SHARED_LIBRARY_SONAME_C_FLAG and emits libBlocksRuntime.so with no
  # SONAME — which makes libdispatch record a build-relative NEEDED
  # (../libBlocksRuntime.so) that fails to load. Telling CMake it's FreeBSD lets it
  # set the soname itself, exactly like the base and libobjc2 builds do.
  cmake .. \
    $CMAKE_SYSTEM_FLAG \
    -DCMAKE_INSTALL_PREFIX=/System/Library \
    -DCMAKE_INSTALL_LIBDIR=Libraries \
    -DINSTALL_DISPATCH_HEADERS_DIR=/System/Library/Headers/dispatch \
    -DINSTALL_BLOCK_HEADERS_DIR=/System/Library/Headers \
    -DINSTALL_OS_HEADERS_DIR=/System/Library/Headers/os \
    -DINSTALL_PRIVATE_HEADERS=ON \
    -DCMAKE_INSTALL_MANDIR=Documentation/man \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    $DISPATCH_EXTRA_FLAGS

  "$MAKE_CMD" -j"$CPUS" || exit 1
  "$MAKE_CMD" install || exit 1

  # Build tools-make - can now find _Block_copy in libdispatch's BlocksRuntime
  # Use libobjc_LIBS=" " to prevent configure from adding -lobjc to link tests
  echo "Building/installing tools-make..."
  cd "$REPOS_DIR/tools-make"
  $MAKE_CMD distclean 2>/dev/null || true
  # $BUILD_FLAG is --build=<arch>-nextbsd-freebsd on NextBSD (config.guess can't
  # recognize NextBSD's uname), empty elsewhere — harmless on FreeBSD/Linux.
  ./configure \
    $BUILD_FLAG \
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

  cd "$REPOS_DIR/libs-base"

  # Patch libs-base (64-bit _4CF main-queue handle fix for Apple libdispatch).
  echo "Patching libs-base..."
  patch.sh libs-base

  if [ "$NEXTBSD" -eq 1 ]; then
    # NextBSD ships libdns_sd (the mDNSResponder DNS-SD client) in
    # /usr/lib/system, which is on binaries' runtime RUNPATH but is NOT a
    # default link-time search dir. Without -L/usr/lib/system, libs-base
    # configure's AC_CHECK_LIB(dns_sd, DNSServiceBrowse) link test fails, so
    # HAVE_MDNS is set to 0 and NSNetServiceBrowser/NSNetService are built with
    # NO zeroconf backend: their +allocWithZone: then returns nil and the
    # [[NSNetServiceBrowser alloc] init] in the Network view SIGSEGVs
    # (Workspace, NetworkBrowser, RemoteDesktop). Adding the -L makes the mDNS
    # backend detect+link. /System/Library/Libraries is listed FIRST so
    # dispatch/objc/BlocksRuntime keep linking from the Gershwin (non-Mach)
    # domain; /usr/lib/system is only for the base-only libdns_sd. Runtime
    # dispatch resolution is unchanged (governed by RUNPATH, verified via ldd).
    ./configure \
      $BUILD_FLAG \
      --with-dispatch-include=/usr/include \
      --with-dispatch-library=/System/Library/Libraries \
      --with-zeroconf-api=mdns \
      LDFLAGS="-L/System/Library/Libraries -L/usr/lib/system"
  else
    ./configure \
      --with-dispatch-include=/System/Library/Headers \
      --with-dispatch-library=/System/Library/Libraries
  fi
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean

  # Patch libs-gui
  echo "Patching libs-gui..."
  patch.sh libs-gui

  cd "$REPOS_DIR/libs-gui"
  ./configure $BUILD_FLAG
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean

  # Patch libs-back
  echo "Patching libs-back..."
  patch.sh libs-back # https://github.com/gnustep/libs-back/issues/74

  cd "$REPOS_DIR/libs-back"
  export fonts=no
  ./configure $BUILD_FLAG
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean

  # Hook into tools-make to inject build time and git hash into Info-gnustep.plist files
  cd "$REPOS_DIR/gershwin-components/plistupdate"
  $MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
  $MAKE_CMD install
  sh -e ./setup-integration.sh
  $MAKE_CMD clean

  # Patch libs-av
  echo "Patching libs-av..."
  patch.sh libs-av # https://github.com/gnustep/libs-av/pull/1

  cd "$REPOS_DIR/libs-av"
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_workspace() {
  cd "$REPOS_DIR/gershwin-workspace"
  # OpenBSD ships autoconf and automake with version-suffixed binaries;
  # autoreconf needs these env vars to pick the right versions.
  if [ "$(uname -s)" = "OpenBSD" ]; then
    export AUTOCONF_VERSION
    export AUTOMAKE_VERSION
    AUTOCONF_VERSION=$(ls /usr/local/bin/autoconf-* 2>/dev/null | sed 's|.*/autoconf-||' | sort -V | tail -1)
    AUTOMAKE_VERSION=$(ls /usr/local/bin/automake-* 2>/dev/null | sed 's|.*/automake-||' | sort -V | tail -1)
    echo "Using AUTOCONF_VERSION=$AUTOCONF_VERSION AUTOMAKE_VERSION=$AUTOMAKE_VERSION"
  fi
  autoreconf -fi
  ./configure $BUILD_FLAG
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_systempreferences() {
  cd "$REPOS_DIR/gershwin-systempreferences"
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_eau_theme() {
  cd "$REPOS_DIR/gershwin-eau-theme"
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_terminal() {
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
}

build_textedit() {
  cd "$REPOS_DIR/gershwin-textedit"
  $MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_windowmanager() {
  cd "$REPOS_DIR/gershwin-windowmanager/"
  $MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_components() {
  # Components with a .DISABLED file in their directory will not be built
  cd "$REPOS_DIR/gershwin-components/"
  $MAKE_CMD CPPFLAGS="-DGNUSTEP_INSTALL_TYPE=SYSTEM" -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
}

build_driveui() {
  # DriveUI tooling (the runtime DriveUI.bundle, the drive_ui CLI and the
  # run_uitest / uitest_tests harness) lives in this repository rather than
  # under Library/Sources, so build it from here.  Each piece is installed
  # separately; the bundle and the tools must end up in /System before the
  # desktop is started for "make test".
  cd "$WORKDIR/DriveUI"
  $MAKE_CMD -j"$CPUS" || exit 1
  $MAKE_CMD install
  $MAKE_CMD clean
  ( cd drive_ui && $MAKE_CMD -j"$CPUS" && $MAKE_CMD install && $MAKE_CMD clean ) || exit 1
  ( cd uitest && $MAKE_CMD -j"$CPUS" && $MAKE_CMD install && $MAKE_CMD clean ) || exit 1
  ( cd uitest/Tests && $MAKE_CMD -j"$CPUS" && $MAKE_CMD install && $MAKE_CMD clean ) || exit 1
}

# UI-test scripts can launch helper apps by name ("launch application X"),
# but run_uitest only starts apps found in the standard .app locations, and
# the isolated session runs as a dedicated test user whose HOME differs from
# this install's.  Fixture apps are therefore installed into
# /System/Library/CoreServices/Applications, next to other system helpers
# that users do not launch manually (Menu, ...), where every user's
# run_uitest finds them.  The <app>_INSTALL_DIR override on the command line
# beats any value the fixture's own GNUmakefile sets.
build_ui_test_fixtures() {
  ensure_gnustep_env
  if [ -d "$REPOS_DIR/gershwin-eau-theme/Test" ]; then
    ( cd "$REPOS_DIR/gershwin-eau-theme/Test" && \
      $MAKE_CMD alerttest_INSTALL_DIR="/System/Library/CoreServices/Applications" install && \
      $MAKE_CMD clean ) || exit 1
  fi
}

# Dispatch on the requested target.  Default "all" reproduces the original
# end-to-end System Domain install in the exact same order.
TARGET="${1:-all}"
case "$TARGET" in
  corelibs)
    build_corelibs
    ;;
  workspace)
    ensure_gnustep_env
    # gershwin-workspace's MDIndexing prefPane links the PreferencePanes
    # framework (installed by gershwin-systempreferences); build that first
    # so <PreferencePanes/PreferencePanes.h> resolves.
    build_systempreferences
    build_workspace
    ;;
  systempreferences)
    ensure_gnustep_env
    build_systempreferences
    ;;
  eau-theme)
    ensure_gnustep_env
    build_eau_theme
    ;;
  terminal)
    ensure_gnustep_env
    build_terminal
    ;;
  textedit)
    ensure_gnustep_env
    build_textedit
    ;;
  windowmanager)
    ensure_gnustep_env
    build_windowmanager
    ;;
  components)
    ensure_gnustep_env
    build_components
    ;;
  tooling)
    ensure_gnustep_env
    build_driveui
    ;;
  test)
    ensure_gnustep_env
    build_driveui
    build_ui_test_fixtures
    # CI containers have no X session, so run the suite on a fresh virtual
    # display as a dedicated test user rather than the default "session" mode.
    UITEST_SESSION=isolated sh "$WORKDIR/Library/Scripts/run-uitests.sh"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "UI tests failed (exit $rc)" >&2
      exit "$rc"
    fi
    ;;
  all)
    build_corelibs
    # workspace's MDIndexing prefPane depends on the PreferencePanes
    # framework, so systempreferences must be built first.
    build_systempreferences
    build_workspace
    build_eau_theme
    build_terminal
    build_textedit
    build_windowmanager
    build_components
    build_driveui
    ;;
  *)
    echo "Unknown target: $TARGET"
    echo "Valid targets: corelibs workspace systempreferences eau-theme terminal textedit windowmanager components tooling test all"
    exit 1
    ;;
esac

echo ""
echo "Done."
