# Gershwin UI Test Framework

The Gershwin UI test framework drives the real desktop - opening windows,
choosing menu items, clicking buttons, pinning Dock icons - and verifies the
result, on the live X display.  Tests are written in the DriveUI automation
UITest (`.uitest` scripts) and run through the GNUstep test framework
(`gnustep-tests`) so their results integrate with the rest of the system's
test reporting.

This document covers the framework end to end: what the pieces are, how a
test is written, how tests are organized and run, and how to add tests to a
repository.  The UITest language itself is documented in
[`Executor.md`](Executor.md).

## Quick start

```sh
# Run the entire Gershwin test suite (all repos, one command):
/Developer/Library/Sources/run-tests.sh

# Run the UITest language test (the only script that lives with the harness):
cd DriveUI/uitest/Tests && gnustep-tests .

# Run one script by hand:
/System/Library/Tools/run_uitest \
  /Developer/Library/Sources/gershwin-workspace/Tests/about_this_computer.uitest
```

Scripts live in the `Tests/` directory of the repository that owns the
component they test (Menu tests in `gershwin-components/Menu/Tests/`, Workspace
tests in `gershwin-workspace/Tests/`, the UITest language test in the harness
dir).  The driver finds them all; to run a specific repository's scripts
directly, point `UITEST_SEARCH_DIRS` at its `Tests/` directory (see
[Selecting scripts](#44-selecting-scripts)).

A green run of the core UI suite reports every script as a passed test and
skips the `heavy` group (see [Selecting tests](#selecting-tests)):

```text
     16 Passed tests
      1 Skipped set
```

## 1. Architecture

The framework is a small chain of tools; nothing runs as a daemon and nothing
needs installation beyond what the Gershwin stack already ships.

### 1.1 Components

| Component | Location | Role |
|---|---|---|
| UI test scripts | `**/Tests/**/*.uitest` | Human-readable test programs |
| `run_uitest` | `/System/Library/Tools/run_uitest` | Runs one `.uitest` script; exit code 0-5 |
| `drive_ui` | `/System/Library/Tools/drive_ui` | Engine: talks to the app's DriveUI socket, synthesizes X11 input |
| DriveUI bundle | `DriveUI/DriveUI.bundle` | Loaded into each app (Eau theme, `GSAppKitUserBundles`); serves the widget tree and accepts actions over a per-PID Unix socket |
| Canonical harness | `DriveUI/uitest/Tests/` | A `gnustep-tests` suite whose one tool, `uitest_tests`, discovers and runs every `.uitest` script it is given |
| Cross-repo driver | `/Developer/Library/Sources/run-tests.sh` | Runs the test suites of every Gershwin repository and feeds all `.uitest` scripts to the harness |

### 1.2 How a test runs

```
.uitest script
      |
      v
run_uitest (parses UITest, walks commands)
      |
      v
drive_ui (one query per command)
      |                        \
      +-- Unix socket ---------> DriveUI bundle in the target app
      \-- X11 events ----------> the app's real windows, menus, Dock
      |
      v
exit code 0-5
```

The UITest says what the user wants (`click button "OK"`), not how.  The query
engine resolves widgets by on-screen title, checks state through the DriveUI
socket, and performs actions with real X11 pointer and key events, so tests
behave like a person using the machine.

### 1.3 The canonical harness

`gnustep-tests` only builds directories that contain source files plus a
`TestInfo` marker, so a directory of pure `.uitest` scripts is invisible to
it.  The canonical harness is the single compiled test tool that bridges the
two worlds:

- `TestInfo` - marks the suite, forces serial execution, sets defaults.
- `uitest_tests.m` - the test tool.  Reads `UITEST_SEARCH_DIRS` (a colon-separated
  list of directories, exported by the driver), recursively collects every
  `*.uitest` file under them, groups scripts by folder, and runs each one
  with `run_uitest`.
- `GNUmakefile` / `GNUmakefile.preamble` - build wiring (see
  [Build integration](#61-build-integration)).

Each script becomes one `PASS` testcase; a group is one `START_SET`.  Because
the harness is a normal `gnustep-tests` tool, its results appear in the same
`tests.sum` / `tests.log` reports as every other GNUstep test in the system.

## 2. Test layout

### 2.1 Where tests live

Each repository keeps its tests next to the code they cover, in that
repository's `Tests/` directory - tests for a component live in the
repository that owns the component.  Scripts sit directly in `Tests/` or in
grouping subfolders (`heavy/` is special, see below):

```
gershwin-components/DriveUI/uitest/Tests/
  TestInfo                     <- canonical harness (compiled suite)
  GNUmakefile
  GNUmakefile.preamble
  uitest_tests.m
  control/
    control_flow.uitest        <- UITest language test, lives with the harness

gershwin-components/Menu/Tests/          <- Menu.app tests, next to Menu/
  menu_assert.uitest
  menu_checkmark.uitest
  menu_follows_app.uitest
  processes_about.uitest
  heavy/                       <- gated, see below
    chrome_shortcuts.uitest
    viking_about.uitest

gershwin-workspace/Tests/                <- Workspace/Dock tests
  about_this_computer.uitest
  ueber_diesen_computer.uitest
  navigation.uitest
  find.uitest
  preferences.uitest
  window_placement.uitest
  views.uitest
  dock_pin_unpin.uitest
```

A repository that only ships `.uitest` scripts needs nothing but the scripts:
no `TestInfo`, no makefiles, no source files.  The cross-repo driver and the
canonical harness find them automatically (see [Adding tests](#7-adding-tests-to-a-repository)).

The two `.uitest`-only directories above (`Menu/Tests/`, `workspace/Tests/`)
are invisible to `gnustep-tests` itself (they contain no `.m` sources and no
`TestInfo`); the harness picks them up through `UITEST_SEARCH_DIRS`.

### 2.2 Grouping

The harness groups scripts by the directory they sit in and reports each
directory as one set, keyed by the path relative to `/Developer/Library/Sources`
(so equally named directories in different repositories never merge in the
log).  With the layout above, running the full suite reports four groups:
`gershwin-components/DriveUI/uitest/Tests/control`,
`gershwin-components/Menu/Tests` (plus its `heavy` group),
`gershwin-components/Menu/Tests/heavy`, and `gershwin-workspace/Tests`.
Grouping is by directory; the directory name *is* the group name.

### 2.3 The `heavy` gate

A subfolder named `heavy` is skipped as a whole unless the suite is run with
`UI_TEST_LEVEL=full`:

```sh
gnustep-tests .                       # core set: heavy/ is skipped
UI_TEST_LEVEL=full gnustep-tests .    # also runs heavy/
```

Put scripts that launch big external applications (Chrome, Viking) in
`heavy/` so the default run stays fast and hermetic.

## 3. Writing a test

Scripts are plain text, one command per line, `#` comments, double-quoted
strings, and a language-independent object/title vocabulary.  The full
language is in [`Executor.md`](Executor.md); this section covers the
conventions that make good *tests*, plus the commands that exist specifically
for testing.

### 3.1 Conventions

- **Be self-healing.**  Tests run repeatedly on a live desktop.  A test
  should undo what it does (close windows, unpin icons, quit apps it
  launched) and tolerate leftovers from an earlier interrupted run.  See the
  start of `dock/dock_pin_unpin.uitest` for the pattern:

  ```text
  # Self-healing start: if a previous run left Processes pinned, unpin it first.
  if icon "Processes" docked
    context menu "Processes" "Remove from Dock"
    wait 500ms
  end
  ```

- **Write titles in English.**  Titles are matched against the app's own
  translations, so an English-written script drives a German UI unchanged.
  Both `about_this_computer.uitest` and `ueber_diesen_computer.uitest` test
  the same panel.

- **Verify, don't just act.**  After every action that should have a visible
  result, `wait until` and `assert` it.  A script that only performs actions
  passes even when nothing worked.

- **Prefer `wait until` over fixed `wait`.**  `wait until` polls up to 30 s
  (or a `timeout Ns` you add) and passes the moment the condition holds;
  fixed sleeps are slower and fragile.

- **Name the target.**  `activate application "Workspace"` selects the target
  for later commands.  Menu actions on the global menu bar and Dock icon
  actions need the frontmost context to be right - see the Dock script, which
  switches to Workspace before touching the Dock.

### 3.2 Test-oriented commands

These commands exist for driving and asserting the desktop itself; they are
documented here because they are the building blocks of the shipped tests.

**Launching through the Run dialog**

```text
run "xterm"
run "/System/Applications/Utilities/Processes.app/Processes"
```

Opens the frontmost app's `Tools/Run...` dialog, types the command, and
presses Return.  The Run dialog belongs to Workspace, so `activate
application "Workspace"` first when it is not already the target.

**The global menu bar (Menu.app)**

```text
select global menu "Workspace/About This Computer"   # click through Menu.app
assert menu bar "Ablage"                             # top-level item present
assert not menu bar "Edit"                           # ...or absent
wait until menu bar "Workspace"
```

`assert menu bar` / `wait until menu bar` inspect the *global* menu bar that
Menu.app shows for the frontmost application - the thing a user actually
sees.  Use it to verify which application's menu is displayed.

**Menu item properties**

```text
assert menu item "File/New" exists
assert menu item "View/Show Status Bar" checked
assert menu item "Edit/Paste" shortcut "Cmd+V"
assert menu item "Window/Zoom" enabled
```

`assert menu item "Top/Sub" [exists|not exists|checked|not checked|enabled|
disabled|shortcut "Cmd+X"]` checks a property of an application menu item
addressed by title path.  Useful for pinning shortcuts and checkmark state
after an app switch.

**X window counts**

```text
assert xwindow "Process monitor" count = 1
wait until xwindow "Process monitor" count >= 1
setcount N = count xwindow "Process monitor"
assert xwindow "Process monitor" count = ${N}
```

`xwindow` counts X windows whose title contains the given string; the
operator is one of `=`, `>`, `>=`, `<`, `<=`, `!=`.  `setcount VAR = count
xwindow "Title"` records a count into a variable so later assertions can be
relative (e.g. "no *new* window opened").  Counts are cheap and work for
non-GNUstep windows too.

**Dock icons**

```text
assert icon "Processes" docked
assert not icon "Processes" docked
context menu "Processes" "Keep in Dock"
context menu "Processes" "Remove from Dock"
```

The Dock lives inside Workspace; `context menu` on an icon opens its
contextual menu and selects an item.

### 3.3 A complete annotated example

`dock/dock_pin_unpin.uitest` (trimmed):

```text
launch application "Processes"          # start the app under test
activate application "Workspace"        # Dock lives in Workspace
wait until icon "Processes"             # let the Dock catch up

if icon "Processes" docked              # self-healing: unpin leftovers
  context menu "Processes" "Remove from Dock"
  wait 500ms
end

context menu "Processes" "Keep in Dock"
assert icon "Processes" docked          # pinning worked

activate application "Processes"
select menu "Processes/Quit Processes"  # quit the app ...
wait until not exists window "Process monitor"
activate application "Workspace"
assert icon "Processes" docked          # ... but the pinned icon stays

context menu "Processes" "Remove from Dock"
wait until not exists icon "Processes"  # with the app gone, unpinning removes it
assert not exists icon "Processes"
```

## 4. Running tests

### 4.1 One script by hand

```sh
/System/Library/Tools/run_uitest \
  /Developer/Library/Sources/gershwin-workspace/Tests/about_this_computer.uitest
```

Exit code 0 means every command succeeded.  The command log goes to stderr;
a failing run shows exactly which command failed and why.  `run_uitest
--drive-tool /path/to/drive_ui` overrides the engine path.

### 4.2 The suite through gnustep-tests

The harness only runs the scripts it is told about (via `UITEST_SEARCH_DIRS`),
so a bare `gnustep-tests .` in the harness directory runs just the script
that lives there (the UITest language test):

```sh
cd DriveUI/uitest/Tests
gnustep-tests .                    # control_flow.uitest only
UITEST_SEARCH_DIRS="$GSTESTROOT:/path/to/other/repo/Tests" gnustep-tests .
UI_TEST_LEVEL=full UITEST_SEARCH_DIRS="..." gnustep-tests .
```

Results land in `tests.sum` (summary) and `tests.log` (detail) in the current
directory; previous runs are kept as `oldtests.*`.  For the full picture use
the cross-repo driver below - it sets `UITEST_SEARCH_DIRS` to every repository's
`Tests/` automatically.

### 4.3 The cross-repo driver

```sh
/Developer/Library/Sources/run-tests.sh                # every gershwin-* repo
/Developer/Library/Sources/run-tests.sh gershwin-workspace   # one repo
```

The driver is the one place that knows the repository layout.  It collects
every directory containing `.uitest` scripts into `UITEST_SEARCH_DIRS`, runs
`gnustep-tests .` in each repository that has classic (`TestInfo`) suites,
and ensures the canonical harness runs exactly once.  It exits non-zero if
any suite failed, so it can gate a build step.

### 4.4 Selecting scripts

The harness only runs scripts under the directories named in the
`UITEST_SEARCH_DIRS` environment variable (a colon-separated list).  The driver
exports it; when unset the harness falls back to its own `$GSTESTROOT` (the
harness directory, which today only holds the `control/` language test).

```sh
UITEST_SEARCH_DIRS=/Developer/Library/Sources/gershwin-workspace/Tests gnustep-tests .
```

Point it at a single group folder to run only that group:

```sh
UITEST_SEARCH_DIRS=DriveUI/uitest/Tests/control gnustep-tests .
```

### 4.5 Timeouts

`gnustep-tests` runs each test *file* under a 300 s `timeout` by default.  A
full `UI_TEST_LEVEL=full` run may approach this; raise it with
`gnustep-tests --timeout 600 .` when needed.

### 4.6 CPU watchdog

The harness guards every script against runaway desktop processes.  It has
caught two real bugs this way: a Menu.app spin (an evdev fd left with
`POLLERR|POLLHUP` on a deleted input device made `poll()` return instantly,
busy-looping at ~190% CPU) and a Workspace run-loop busy-cycle (`poll()` with
a 0 ms timeout thousands of times per second, ~20% CPU).

- **During a script** the harness samples Menu.app, Workspace and the `run_uitest`
  runner once per second and aborts the script if one stays above
  `UITEST_CPU_THRESHOLD` (default 90%) for `UITEST_CPU_SAMPLES` (default 5)
  consecutive samples.  On trigger it terminates the script, fails the test,
  and dumps the culprit's stack for diagnosis.
- **Between scripts** it verifies the desktop settles: Menu.app and Workspace
  must stay below `UITEST_CPU_IDLE` (default 15%) for three consecutive
  samples, otherwise the test fails with a diagnostic - this catches a
  busy-loop that persists with no test driving it.

Tune or disable with `UITEST_CPU_WATCH` (off|on), `UITEST_CPU_THRESHOLD`,
`UITEST_CPU_SAMPLES`, `UITEST_CPU_IDLE`.

## 5. Understanding results

### 5.1 `run_uitest` exit codes

```text
0  Success
1  Parse Error
2  Runtime Error
3  Timeout            (a wait until condition never held)
4  Accessibility Error (app not found, widget not found, action failed)
5  Assertion Failed    (an assert command did not hold)
```

The harness passes only exit code 0; anything else fails that testcase.

### 5.2 `gnustep-tests` summary

```text
Passed tests:      the individual PASS testcases (one per .uitest script)
Failed tests:      scripts that exited non-zero
Skipped sets:      groups skipped by SKIP() (e.g. prerequisites or heavy/)
```

A skipped group is not a failure.  A failed *set* (abandoned partway) and a
failed *file* (the harness itself crashed) are both real problems.

### 5.3 Skip vs fail semantics

- Missing environment or an optional tool -> the whole suite is skipped: no
  `$DISPLAY`, or `run_uitest` not installed, produce a single skipped
  "prerequisites" set.
- Hard prerequisites missing on a live desktop (Menu.app or Workspace not
  running) -> reported as failed tests: on a running desktop those processes
  are always present, so their absence is a regression, not a reason to skip.
- The `heavy` group is skipped unless `UI_TEST_LEVEL=full`.

## 6. GNUstep test framework integration

The harness is a plain `gnustep-tests` suite, so it inherits every feature
and constraint of the GNUstep test framework.

### 6.1 Build integration

- `TestInfo` is a shell script sourced before the build and before the run;
  it sets `SEQUENCE="*"` (see below) and exports defaults.
- `gnustep-tests` regenerates the directory's `GNUmakefile` from its own
  template whenever a `GNUmakefile.preamble` is present, so a hand-written
  `GNUmakefile` only applies to direct `gmake` builds.  Configuration that
  must reach the framework build goes in `GNUmakefile.preamble` - notably
  `NEEDS_GUI = yes`, because the framework's `Testing.h` references
  `NSDateFormatter` from the GUI libraries.  After a `gnustep-tests` run the
  generated `GNUmakefile` replaces the committed one; restore it with
  `git checkout -- <path>`.
- The harness is deliberately leak- and overrelease-free: the framework runs
  tests with `MALLOC_CHECK_=2` and zombie detection, and a crash counts as a
  failed file.

### 6.2 Serial execution

`SEQUENCE="*"` in `TestInfo` runs the tests sequentially.  Do not rely on
`gnustep-tests --sequential` (that only disables parallel *building*); the
run ordering comes from the `SEQUENCE` / `PARALLEL` variables in `TestInfo`.
UI tests must never run in parallel - they share one desktop.

### 6.3 Resources

`gnustep-tests` exports `GSTESTROOT` as the absolute path of the topmost
`TestInfo` directory.  The harness and `TestInfo` resolve every path from it
(or from `UITEST_SEARCH_DIRS`) and never from the current working directory,
which `gnustep-tests` changes while building and running.

### 6.4 Inside `uitest_tests.m`

1. **Prerequisites set** - skip the suite on missing `$DISPLAY` or
   `run_uitest`; fail on missing Menu.app / Workspace.
2. **Discovery** - walk every `UITEST_SEARCH_DIRS` entry recursively for
   `*.uitest` files.
3. **Grouping** - key scripts by their path relative to
   `/Developer/Library/Sources` minus the filename; a folder named `heavy`
   is its own group.
4. **Per-group set** - `START_SET` / `END_SET`; one `PASS(runScript(abs),
   ...)` per script.  `SKIP()` is used only to gate a whole group, never to
   skip a single script (it aborts the whole set).

## 7. Adding tests to a repository

1. Create a `Tests/` directory in the repository that owns the component (or
   reuse one) and drop `.uitest` scripts in, directly or in grouping
   subfolders.  Use a `heavy/` subfolder for scripts that launch Chrome /
   Viking.
2. Add **no build files**.  The scripts are discovered automatically by the
   driver and the harness.
3. Add `tests.sum`, `oldtests.sum`, `oldtests.log` to the repository's
   `.gitignore`.
4. Run the suite: `UITEST_SEARCH_DIRS=<repo>/Tests gnustep-tests .` from
   `DriveUI/uitest/Tests`, or just `run-tests.sh <repo>`.
5. Never kill the Workspace process from a test - it supervises the session
   and killing it logs the desktop out.  Menu.app may be restarted; Workspace
   must not.

## 8. Troubleshooting

| Symptom | Likely cause |
|---|---|
| Suite reports a single skipped "prerequisites" set | No `$DISPLAY` in the environment, or `run_uitest` not installed. Run from a desktop session. |
| `application 'Menu' not running (DriveUI bundle not loaded?)` | The app was started without the DriveUI bundle (`GSAppKitUserBundles`), or its per-PID socket is stale. Restart the app (Menu may be restarted; Workspace must not). |
| `activate application "Workspace"` times out (exit 3) | DriveUI socket for Workspace not responding. Usually transient after heavy churn; verify Workspace is running and the bundle is loaded. |
| A script passes alone but fails in the suite | Desktop state left over from an earlier run. Scripts are self-healing, but run the suite twice or restart Menu between full runs. |
| `make_gorm` tests fail via the driver | `make_gorm` is not built in the tree (`../obj/make_gorm` is missing). Build it before running the suite. |
| `GNUmakefile` shows modified after a run | Expected: `gnustep-tests` regenerates it. Restore with `git checkout -- <path>`. |
| Suite exceeds the 300 s timeout | Use `gnustep-tests --timeout 600 .`, or move slow scripts to `heavy/`. |

## 9. Reference

- UITest language and commands: [`Executor.md`](Executor.md)
- Canonical harness: `DriveUI/uitest/Tests/{TestInfo,GNUmakefile,GNUmakefile.preamble,uitest_tests.m}`
- Shipped tests:
  - UITest language: `DriveUI/uitest/Tests/control/control_flow.uitest`
  - Menu.app / global menu: `gershwin-components/Menu/Tests/*.uitest` (+ `heavy/` for the Chrome/Viking GTK tests)
  - Workspace / Dock: `gershwin-workspace/Tests/*.uitest`
- Cross-repo driver: `/Developer/Library/Sources/run-tests.sh`
- Test framework (upstream): `gnustep-tests`, `/System/Library/Makefiles/TestFramework/{Testing.h,README,examples}`
- Design spec: `~/Desktop/tests-spec.md`
