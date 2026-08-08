#!/bin/bash
# Start the isolated UI-test desktop by hand, for running individual .uitest
# scripts without the full suite (run-uitests.sh).  Brings up a virtual
# display, a dbus session and Menu/WindowManager/Workspace for the test user,
# then sleeps so the desktop stays up while you drive it.
#
# Two display modes:
#   headless (default)  Xvfb - no window, invisible to the user.
#   nested              Xephyr on your current display - the tests run in a
#                       window you can watch on screen.
#
# Requires the test user to exist (run-uitests.sh creates it).
#
# Usage (as root or with passwordless sudo):
#   sh Library/Scripts/uitest-session.sh [--nested]
#   DISPLAY=:99 ... run_uitest --drive-tool drive_ui path/to/test.uitest
set -u

# Let the isolated desktop dump core (the test user's own hard limit is 0) so
# a crash produces a core we can backtrace.
ulimit -Hc unlimited 2>/dev/null || true
ulimit -c unlimited 2>/dev/null || true

UITEST_ISOLATED_USER="${UITEST_ISOLATED_USER:-uitest}"
UITEST_ISOLATED_DISPLAY="${UITEST_ISOLATED_DISPLAY:-:99}"
UITEST_SESSION_MODE="${UITEST_SESSION_MODE:-headless}"

if [ "${1:-}" = "--nested" ]; then
  UITEST_SESSION_MODE=nested
fi

start_bg()
{
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >/dev/null 2>&1 < /dev/null &
  else
    "$@" >/dev/null 2>&1 &
  fi
}

run_as_user()
{
  _u="$1"; shift
  if command -v sudo >/dev/null 2>&1; then
    sudo -u "$_u" "$@"
    return $?
  fi
  if [ "$(id -u)" = "0" ]; then
    _cmd=""
    for _a in "$@"; do
      _esc=$(printf '%s' "$_a" | sed "s/'/'\\\\''/g")
      _cmd="$_cmd '$_esc'"
    done
    su -m "$_u" -c "$_cmd"
    return $?
  fi
  echo "error: need root or sudo to run as $_u" >&2
  return 1
}

if ! id "$UITEST_ISOLATED_USER" >/dev/null 2>&1; then
  echo "error: test user '$UITEST_ISOLATED_USER' does not exist" >&2
  exit 1
fi

# A killed session leaves a gdnc (DO name server) and GNUstepSecure temp state
# behind, and a fresh gdnc cannot lock the port names - the desktop components
# then fail with 'Failed to lock names for NSMessagePortNameServer'.  SIGKILL
# the test user and drop the stale name-server state before bringing the
# desktop up.
pkill -9 -u "$UITEST_ISOLATED_USER" 2>/dev/null || true
rm -rf /tmp/GNUstepSecure* 2>/dev/null || true
sleep 1

if ! xdpyinfo -display "$UITEST_ISOLATED_DISPLAY" >/dev/null 2>&1; then
  if [ "$UITEST_SESSION_MODE" = "nested" ]; then
    # Xephyr shows the virtual display in a window on the CURRENT display, so
    # you can watch the tests run.
    if ! command -v Xephyr >/dev/null 2>&1; then
      echo "error: Xephyr not installed (needed for --nested)" >&2
      exit 1
    fi
    echo "Starting Xephyr on $UITEST_ISOLATED_DISPLAY (visible on $DISPLAY)"
    start_bg Xephyr "$UITEST_ISOLATED_DISPLAY" -screen 800x600 -ac -nolisten tcp -noreset
  else
    echo "Starting Xvfb on $UITEST_ISOLATED_DISPLAY"
    start_bg Xvfb "$UITEST_ISOLATED_DISPLAY" -screen 0 1920x1080x24 -nolisten tcp -ac
  fi
  i=0
  while [ "$i" -lt 30 ]; do
    xdpyinfo -display "$UITEST_ISOLATED_DISPLAY" >/dev/null 2>&1 && break
    sleep 1
    i=$((i + 1))
  done
  xdpyinfo -display "$UITEST_ISOLATED_DISPLAY" >/dev/null 2>&1 || {
    echo "X server did not come up on $UITEST_ISOLATED_DISPLAY" >&2; exit 1; }
fi

echo "Starting isolated desktop for $UITEST_ISOLATED_USER on $UITEST_ISOLATED_DISPLAY"

# The desktop apps expose a DriveUI socket only when the DriveUI bundle is
# loaded at startup (the GSAppKitUserBundles user default).  Without it the
# tests cannot drive the desktop at all ('Workspace not running').
run_as_user "$UITEST_ISOLATED_USER" sh -c '
  defaults write NSGlobalDomain GSAppKitUserBundles \
    "(\"/System/Library/Bundles/DriveUI.bundle\")" >/dev/null 2>&1
'

run_as_user "$UITEST_ISOLATED_USER" sh -c '
  export DISPLAY="$1" HOME="/home/uitest"
  export GNUSTEP_SYSTEM_ROOT=/System GNUSTEP_LOCAL_ROOT=/Local GNUSTEP_NETWORK_ROOT=/Network
  export GNUSTEP_USER_ROOT="/home/uitest/.GNUstep"
  export FONTCONFIG_FILE=/System/Library/Preferences/fonts.conf FONTCONFIG_PATH=/System/Library/Preferences
  export PATH=/System/Library/Tools:/usr/bin:/bin
  . /System/Library/Makefiles/GNUstep.sh
  eval $(dbus-launch --sh-syntax)
  echo "$DBUS_SESSION_BUS_ADDRESS" > /tmp/uitest_dbus.txt
  /System/Library/CoreServices/Applications/Menu.app/Menu >/tmp/uitest_menu.log 2>&1 &
  /System/Library/CoreServices/Applications/WindowManager.app/WindowManager >/tmp/uitest_wm.log 2>&1 &
  /System/Applications/Workspace.app/Workspace >/tmp/uitest_ws.log 2>&1 &
' _ "$UITEST_ISOLATED_DISPLAY"

echo "Desktop starting; check /tmp/uitest_ws.log and /tmp/driveui.<ws-pid>.sock"
