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

# 0. Fonts.  The Gershwin desktop fonts live in /System/Library/Fonts and are
#    indexed through fontconfig via /System/Library/Preferences/fonts.conf (the
#    same setup gershwin-system's Gershwin.sh exports).  A stock CI container's
#    fontconfig does not look there, so without this the desktop apps cannot
#    resolve any font and the UI tests fail on rendering/text.  Set the config
#    before anything that launches a Gershwin app so the whole tree inherits it.
export FONTCONFIG_PATH=/System/Library/Preferences
export FONTCONFIG_FILE=$FONTCONFIG_PATH/fonts.conf
if command -v fc-cache >/dev/null 2>&1; then
  fc-cache -f /System/Library/Fonts >/dev/null 2>&1
fi

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

# 3. Collect the Tests/ directories that belong to the built components.  Each
#    component ships its uitest scripts under its own Tests/ directory (nested
#    inside the component repo, e.g. gershwin-components/Menu/Tests), so walk
#    the checked-out repos for .uitest files.  Drop directories nested inside
#    another collected one (e.g. Menu/Tests/heavy is covered by Menu/Tests) so
#    the harness does not enumerate a script twice.
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
