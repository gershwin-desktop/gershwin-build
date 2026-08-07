#!/bin/sh
# Run the DriveUI UI test suite against a built desktop.
#
# Requires the full Gershwin desktop built and installed to /System
# (make all), and the DriveUI tooling installed (make tooling) so that
# run_uitest, drive_ui and the uitest_tests harness are in /System/Library/Tools.
#
# Headless CI has no X server: if none answers on $DISPLAY, an Xvfb server is
# started.  Menu, WindowManager and Workspace are started (on that display) if
# they are not already running, then every .uitest script found under the
# checked-out repositories' Tests/ directories is run through the uitest_tests
# harness.  Exit status is the harness's.
set -u

WORKDIR="$(cd "$(dirname "$0")/../.." && pwd)"
REPOS_DIR="$WORKDIR/Library/Sources"
XVFB_PID=""

# Start a background process that must outlive this shell.  setsid detaches it
# into its own session so a wrapper shell (GitHub Actions) cannot reap it; plain
# '&' would leave it in the shell's process group.
start_bg()
{
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >/dev/null 2>&1 < /dev/null &
  else
    "$@" >/dev/null 2>&1 &
  fi
}

# 1. X server.  Reuse an existing DISPLAY if it answers; otherwise start Xvfb.
if [ -z "${DISPLAY:-}" ] || ! xdpyinfo >/dev/null 2>&1; then
  export DISPLAY=:99
  echo "No usable X server, starting Xvfb on :99"
  start_bg Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp
  XVFB_PID=$!
  i=0
  while [ "$i" -lt 30 ]; do
    xdpyinfo >/dev/null 2>&1 && break
    sleep 1
    i=$((i + 1))
  done
  xdpyinfo >/dev/null 2>&1 || { echo "Xvfb did not come up" >&2; exit 1; }
fi

# 2. Desktop components (the harness hard-requires Menu; Workspace and
#    WindowManager must be up for the desktop tests to be meaningful).
MENU=/System/Library/CoreServices/Applications/Menu.app/Menu
WM=/System/Library/CoreServices/Applications/WindowManager.app/WindowManager
WS=/System/Applications/Workspace.app/Workspace

for name_bin in "Menu:$MENU" "WindowManager:$WM" "Workspace:$WS"
do
  name="${name_bin%%:*}"
  bin="${name_bin#*:}"
  if ! pgrep -x "$name" >/dev/null 2>&1; then
    if [ -x "$bin" ]; then
      echo "Starting $name"
      start_bg "$bin"
    else
      echo "Warning: $name binary not found at $bin" >&2
    fi
  fi
done

# Let the desktop settle.
sleep 5

# 3. Collect every repository's Tests/ directory that contains .uitest scripts,
#    plus the DriveUI control test shipped with the harness.
UITEST_SEARCH_DIRS=""
for dir in "$REPOS_DIR"/gershwin-*/Tests "$WORKDIR/DriveUI/uitest/Tests/control"
do
  if [ -d "$dir" ] && find "$dir" -name '*.uitest' 2>/dev/null | grep -q .
  then
    UITEST_SEARCH_DIRS="$UITEST_SEARCH_DIRS${UITEST_SEARCH_DIRS:+:}$dir"
  fi
done
export UITEST_SEARCH_DIRS
export UI_TEST_LEVEL="${UI_TEST_LEVEL:-core}"
echo "UITEST_SEARCH_DIRS=$UITEST_SEARCH_DIRS"

if [ -z "$UITEST_SEARCH_DIRS" ]; then
  echo "No .uitest scripts found" >&2
  exit 0
fi

# 4. Run the harness.
HARNESS=/System/Library/Tools/uitest_tests
if [ ! -x "$HARNESS" ]; then
  echo "uitest_tests harness not installed (run 'make tooling')" >&2
  exit 1
fi

"$HARNESS"
rc=$?

if [ -n "$XVFB_PID" ]; then
  kill "$XVFB_PID" 2>/dev/null
fi
exit $rc
