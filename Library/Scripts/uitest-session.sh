#!/bin/bash
# Start the isolated UI-test desktop by hand, for running individual .uitest
# scripts without the full suite (run-uitests.sh).  Brings up Xvfb, a dbus
# session and Menu/WindowManager/Workspace for the test user on the virtual
# display, then sleeps so the desktop stays up while you drive it.
#
# Requires the test user to exist (run-uitests.sh creates it) and Xvfb.
#
# Usage (as root or with passwordless sudo):
#   sh Library/Scripts/uitest-session.sh
#   DISPLAY=:99 ... run_uitest --drive-tool drive_ui path/to/test.uitest
set -u

UITEST_ISOLATED_USER="${UITEST_ISOLATED_USER:-uitest}"
UITEST_ISOLATED_DISPLAY="${UITEST_ISOLATED_DISPLAY:-:99}"

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

if ! xdpyinfo -display "$UITEST_ISOLATED_DISPLAY" >/dev/null 2>&1; then
  echo "Starting Xvfb on $UITEST_ISOLATED_DISPLAY"
  start_bg Xvfb "$UITEST_ISOLATED_DISPLAY" -screen 0 1920x1080x24 -nolisten tcp -ac
  i=0
  while [ "$i" -lt 30 ]; do
    xdpyinfo -display "$UITEST_ISOLATED_DISPLAY" >/dev/null 2>&1 && break
    sleep 1
    i=$((i + 1))
  done
  xdpyinfo -display "$UITEST_ISOLATED_DISPLAY" >/dev/null 2>&1 || {
    echo "Xvfb did not come up on $UITEST_ISOLATED_DISPLAY" >&2; exit 1; }
fi

echo "Starting isolated desktop for $UITEST_ISOLATED_USER on $UITEST_ISOLATED_DISPLAY"
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
