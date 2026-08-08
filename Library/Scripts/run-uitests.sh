#!/bin/sh
# Run the DriveUI UI test suite against a built desktop.
#
# Requires the full Gershwin desktop built and installed to /System
# (make all), and the DriveUI tooling installed (make tooling) so that
# run_uitest, drive_ui and the uitest_tests harness are in /System/Library/Tools.
#
# Two session modes, selected with UITEST_SESSION:
#
#   session   (default)  run against the already-running desktop session of the
#                        current user, on its existing $DISPLAY.  This is the
#                        classic local workflow: the desktop is up, DriveUI is
#                        loaded, the tests just drive it.
#
#   isolated             run as a dedicated test user on a fresh virtual X
#                        display (Xvfb) with its own dbus bus and home, fully
#                        isolated from any logged-in session.  This is what CI
#                        and reproducible local runs use; the logged-in user's
#                        desktop is never touched.  The test user is created on
#                        demand (UITEST_ISOLATED_USER, default "uitest"); root
#                        (or passwordless sudo) is required to create it.
#
# Exit status is the harness's.
set -u

WORKDIR="$(cd "$(dirname "$0")/../.." && pwd)"
REPOS_DIR="${UITEST_REPOS_DIR:-$WORKDIR/Library/Sources}"
XVFB_PID=""

UITEST_SESSION="${UITEST_SESSION:-session}"
UITEST_ISOLATED_USER="${UITEST_ISOLATED_USER:-uitest}"
UITEST_ISOLATED_DISPLAY="${UITEST_ISOLATED_DISPLAY:-:99}"

# Start a background process that must outlive this shell.
start_bg()
{
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >/dev/null 2>&1 < /dev/null &
  else
    "$@" >/dev/null 2>&1 &
  fi
}

# 0. Fonts.  The Gershwin desktop fonts live in /System/Library/Fonts and are
#    indexed through fontconfig via /System/Library/Preferences/fonts.conf (the
#    same setup gershwin-system's Gershwin.sh exports).  A stock CI container's
#    fontconfig does not look there, so without this the desktop apps cannot
#    resolve any font and the UI tests fail on rendering/text.
ensure_fonts()
{
  export FONTCONFIG_PATH=/System/Library/Preferences
  export FONTCONFIG_FILE=$FONTCONFIG_PATH/fonts.conf
  if command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f /System/Library/Fonts >/dev/null 2>&1
  fi
}

# The desktop apps expose a DriveUI socket only when the DriveUI bundle is
# loaded into every app at startup (the GSAppKitUserBundles user default).
# Enable it for the run - preserving any prior value - and restore that value
# at the end so the user defaults are left as they were found.
APPKIT_BUNDLES_PRIOR=""
APPKIT_BUNDLES_HAD=0
enable_appkit_bundles()
{
  if ! command -v defaults >/dev/null 2>&1; then
    return
  fi
  if defaults read NSGlobalDomain GSAppKitUserBundles >/dev/null 2>&1; then
    APPKIT_BUNDLES_HAD=1
    _raw=$(defaults read NSGlobalDomain GSAppKitUserBundles)
    _arg="("
    for _p in $(printf '%s\n' "$_raw" | sed -n 's/^[[:space:]]*"\([^"]*\)",*[[:space:]]*$/\1/p')
    do
      _arg="$_arg\"$_p\","
    done
    APPKIT_BUNDLES_PRIOR="${_arg%,})"
  fi
  if printf '%s' "$APPKIT_BUNDLES_PRIOR" | grep -q 'DriveUI.bundle'; then
    _new="$APPKIT_BUNDLES_PRIOR"
  elif [ -n "$APPKIT_BUNDLES_PRIOR" ]; then
    _new="${APPKIT_BUNDLES_PRIOR%)},\"/System/Library/Bundles/DriveUI.bundle\")"
  else
    _new='("/System/Library/Bundles/DriveUI.bundle")'
  fi
  defaults write NSGlobalDomain GSAppKitUserBundles "$_new" >/dev/null 2>&1
}

restore_appkit_bundles()
{
  if ! command -v defaults >/dev/null 2>&1; then
    return
  fi
  if [ "$APPKIT_BUNDLES_HAD" = 1 ]; then
    defaults write NSGlobalDomain GSAppKitUserBundles "$APPKIT_BUNDLES_PRIOR" >/dev/null 2>&1 || true
  else
    defaults delete NSGlobalDomain GSAppKitUserBundles >/dev/null 2>&1 || true
  fi
}

# Start a desktop component (Menu / WindowManager / Workspace) if it is not
# already running.  $1 = the user the session runs as (empty = current user).
# Restarting an already-running instance is avoided in session mode so the
# logged-in desktop is not disturbed.
start_desktop_component()
{
  run_user="$1"
  name="$2"
  bin="$3"
  if pgrep -x "$name" >/dev/null 2>&1; then
    return 0
  fi
  if [ -x "$bin" ]; then
    if [ -n "$run_user" ]; then
      start_bg sudo -u "$run_user" "$bin"
    else
      start_bg "$bin"
    fi
  else
    echo "Warning: $name binary not found at $bin" >&2
  fi
}

# Run a command in the session.  In isolated mode this is sudo to the test
# user with the isolated environment.
session_run()
{
  if [ "$UITEST_SESSION" = "isolated" ]; then
    sudo -u "$UITEST_ISOLATED_USER" env DISPLAY="$UITEST_ISOLATED_DISPLAY" \
      HOME="/home/$UITEST_ISOLATED_USER" \
      GNUSTEP_SYSTEM_ROOT=/System GNUSTEP_LOCAL_ROOT=/Local \
      GNUSTEP_NETWORK_ROOT=/Network \
      GNUSTEP_USER_ROOT="/home/$UITEST_ISOLATED_USER/.GNUstep" \
      FONTCONFIG_FILE=/System/Library/Preferences/fonts.conf \
      FONTCONFIG_PATH=/System/Library/Preferences \
      PATH=/System/Library/Tools:/usr/bin:/bin \
      "$@"
  else
    "$@"
  fi
}

# ---------------------------------------------------------------------------
# Session setup
# ---------------------------------------------------------------------------

if [ "$UITEST_SESSION" = "isolated" ]; then
  # Create the test user on demand (root or passwordless sudo required).
  if ! id "$UITEST_ISOLATED_USER" >/dev/null 2>&1; then
    echo "Creating test user '$UITEST_ISOLATED_USER'"
    useradd -m -s /bin/bash "$UITEST_ISOLATED_USER"
  fi

  # A fresh virtual display, open to local connections.
  if ! xdpyinfo -display "$UITEST_ISOLATED_DISPLAY" >/dev/null 2>&1; then
    echo "Starting Xvfb on $UITEST_ISOLATED_DISPLAY"
    start_bg Xvfb "$UITEST_ISOLATED_DISPLAY" -screen 0 1920x1080x24 -nolisten tcp -ac
    XVFB_PID=$!
    i=0
    while [ "$i" -lt 30 ]; do
      xdpyinfo -display "$UITEST_ISOLATED_DISPLAY" >/dev/null 2>&1 && break
      sleep 1
      i=$((i + 1))
    done
    xdpyinfo -display "$UITEST_ISOLATED_DISPLAY" >/dev/null 2>&1 || {
      echo "Xvfb did not come up on $UITEST_ISOLATED_DISPLAY" >&2; exit 1; }
  fi
  export DISPLAY="$UITEST_ISOLATED_DISPLAY"

  # The test user needs the DriveUI bundle default and the fontconfig setup.
  session_run sh -c 'defaults write NSGlobalDomain GSAppKitUserBundles \
    "(\"/System/Library/Bundles/DriveUI.bundle\")" >/dev/null 2>&1'

  # Desktop + dbus session for the test user.
  session_run sh -c '
    . /System/Library/Makefiles/GNUstep.sh
    eval $(dbus-launch --sh-syntax)
    /System/Library/CoreServices/Applications/Menu.app/Menu >/tmp/uitest_menu.log 2>&1 &
    /System/Library/CoreServices/Applications/WindowManager.app/WindowManager >/tmp/uitest_wm.log 2>&1 &
    /System/Applications/Workspace.app/Workspace >/tmp/uitest_ws.log 2>&1 &
  '

else
  # Session mode: use the current display; fail loudly if there is none.
  : "${DISPLAY:?no DISPLAY and UITEST_SESSION=session needs a running X session}"
  xdpyinfo >/dev/null 2>&1 || {
    echo "$DISPLAY is not reachable; use UITEST_SESSION=isolated for a virtual session" >&2
    exit 1
  }
  ensure_fonts
  enable_appkit_bundles
  start_desktop_component "" "Menu" "/System/Library/CoreServices/Applications/Menu.app/Menu"
  start_desktop_component "" "WindowManager" "/System/Library/CoreServices/Applications/WindowManager.app/WindowManager"
  start_desktop_component "" "Workspace" "/System/Applications/Workspace.app/Workspace"
fi

# Let the desktop settle.
sleep 5

# ---------------------------------------------------------------------------
# Collect the Tests/ directories that belong to the built components.
# ---------------------------------------------------------------------------
RAW_DIRS=$(for repo in "$REPOS_DIR"/gershwin-*
  do
    if [ -d "$repo" ]; then
      files=$(find "$repo" -name '*.uitest' -type f 2>/dev/null)
      if [ -n "$files" ]; then
        echo "$files" | xargs -n1 dirname
      fi
    fi
  done | sort -u)

UITEST_SEARCH_DIRS=""
for d in $RAW_DIRS
do
  nested=0
  for o in $RAW_DIRS
  do
    [ "$d" = "$o" ] && continue
    case "$d" in
      "$o"/*) nested=1 ;;
    esac
  done
  if [ "$nested" -eq 0 ]; then
    UITEST_SEARCH_DIRS="$UITEST_SEARCH_DIRS${UITEST_SEARCH_DIRS:+:}$d"
  fi
done

# The DriveUI control test ships with the harness.
CONTROL="$WORKDIR/DriveUI/uitest/Tests/control"
if [ -d "$CONTROL" ]; then
  UITEST_SEARCH_DIRS="$UITEST_SEARCH_DIRS${UITEST_SEARCH_DIRS:+:}$CONTROL"
fi

export UITEST_SEARCH_DIRS
export UI_TEST_LEVEL="${UI_TEST_LEVEL:-core}"
echo "UITEST_SEARCH_DIRS=$UITEST_SEARCH_DIRS"

if [ -z "$UITEST_SEARCH_DIRS" ]; then
  echo "No .uitest scripts found" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Run the harness.
# ---------------------------------------------------------------------------
HARNESS=/System/Library/Tools/uitest_tests
if [ ! -x "$HARNESS" ]; then
  echo "uitest_tests harness not installed (run 'make tooling')" >&2
  exit 1
fi

session_run env UITEST_SEARCH_DIRS="$UITEST_SEARCH_DIRS" UI_TEST_LEVEL="$UI_TEST_LEVEL" \
  "$HARNESS"
rc=$?

restore_appkit_bundles

# Leave a clean slate: the isolated desktop (Menu, WindowManager, Workspace,
# plus any app the tests launched) stays alive because SIGTERM does not stop
# it (the Workspace ignores it), so without this the next isolated run would
# reuse stale processes and sockets.  SIGKILL the whole test user instead.
if [ "$UITEST_SESSION" = "isolated" ]; then
  sudo pkill -9 -u "$UITEST_ISOLATED_USER" 2>/dev/null || true
  sleep 1
fi

if [ -n "$XVFB_PID" ]; then
  kill "$XVFB_PID" 2>/dev/null
fi
exit $rc
