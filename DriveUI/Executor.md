# GNUstep UI Automation UITest

`run_uitest` runs plain-language scripts that automate GNUstep
applications.  You describe what should happen (open a window, choose a menu
item, type text, check the result) and the tool drives the app's real UI on
your X display.

A complete example - open Workspace's "About This Computer" panel, verify it,
and save a screenshot:

```text
activate application "Workspace"
select menu "Workspace/About This Computer"
wait until window "About This Computer"
assert window "About This Computer"
assert text contains "Processor"
capture screenshot "/tmp/about_this_computer.png"
log "About panel shown"
```

Run it:

```text
run_uitest --drive-tool /System/Library/Tools/drive_ui script.uitest
```

The script exits `0` when every command succeeds and a non-zero code (see
Exit Codes) when something fails.

## Requirements

The target application must be running with the DriveUI bundle loaded (Eau
theme, `GSAppKitUserBundles`), `$DISPLAY` must point at your X session, and
`run_uitest` must find the `drive_ui` CLI (pass `--drive-tool` if it is not
`/System/Library/Tools/drive_ui`).

## Language basics

Each line is one command.  Blank lines are ignored.  Keywords are
case-insensitive.  Strings are double-quoted.

Comments begin with `#` and run to the end of the line:

```text
# Open the project dialog
select menu "File/Open"
```

### Strings and escapes

Inside double quotes the escapes `\\`, `\"`, `\n` and `\t` are supported:

```text
type "line one\nline two"
type "a \"quoted\" word"
```

### Durations

`wait` and `wait until` accept durations with an `ms`, `s`, or `m` suffix:

```text
wait 500ms
wait 2s
wait 5m
```

### Object types

Many commands accept an object type that scopes which widget is found:

```text
application   window     dialog    sheet    button
menu          menuitem   textfield textarea  checkbox
radio         popup      combobox  table    row
column        list       image     toolbar  tab
tabitem       slider     progress  label
```

Object types map to the widget's on-screen title or label, so you can name a
button or window by what the user sees.

### Scoping a widget to its window

When several windows carry widgets with the same label, add `in window "Title"`
to resolve the widget inside the named window instead of the first match
anywhere:

```text
click button "OK" in window "Save As"
wait until button "OK" in window "Save As"
assert button "OK" enabled in window "Save As"
clear textfield "Search" in window "Find"
hover button "Send" in window "Mail"
scroll table "Results" down 3 in window "Main"
drag window "Inspector" by 40 -20 in window "Main"
if window "Welcome" in window "App"
  log "has welcome"
end
```

The clause works on every command that targets a widget (`click`, `doubleclick`,
`rightclick`, `hover`, `clear`, `scroll`, `drag`, `wait until`, `assert`, `if`).
The window title may be written in English or in the running language, like
every other title.

### Action and verify in one line

`click` and `select menu` can carry their verification with them using
`and wait until` - perform the action, then wait (up to 30 s, or a `timeout`
you add) for the expected result:

```text
click button "Save" and wait until window "Saved"
click button "OK" and wait until not dialog "Loading" timeout 5s
select menu "File/Open" and wait until window "Open"
```

This is shorthand for the action followed by a `wait until`; it fails with a
timeout if the condition never holds.  The wait condition takes the same forms
as `wait until` (`not`, an object type, an optional `timeout Ns`).

### Language-independent names

Titles may be written in English or in the running language.  When a title is
not found as typed, the app's own translations are used, so a script works
whether Workspace runs in English, German, or any other shipped language:

```text
select menu "Workspace/About This Computer"      # German UI also works
wait until window "About This Computer"
```

## Commands

### activate application

```text
activate application "Workspace"
```

Resolves the app by name (matching its running process) and raises its
frontmost window if it has one.  Applications that have no clickable window,
such as a desktop, are still selected as the target for later commands.

### focus window

```text
focus window "Workspace"
```

Raises and focuses a window of the active application.

### select menu

```text
select menu "File/Open"
select menu "Tools/Go To"
select menu "Workspace/About This Computer"
```

Chooses a menu item.  Menu paths are separated with `/` and each segment may
be named in English or in the running language.  Selection is done in-process
on the application itself, so it is fast and does not depend on opening the
on-screen menu bar.

### click / doubleclick / rightclick

```text
click button "OK"
click checkbox "Remember"
doubleclick row "Document"
rightclick row "Project"
```

Performs the primary action on the matching widget using real pointer events
at its on-screen position.

### hover

```text
hover button "Send"
hover window "Details"
```

Moves the pointer over the widget without pressing a button - mouse-over
effects, tooltips, and hover menus.

### scroll

```text
scroll table "Results" down
scroll window "Preview" up 3
scroll left 2
```

Emits wheel steps over a widget (scrolling it if it is scrollable), or - with
no widget - over the current pointer position.  Direction is
`up`/`down`/`left`/`right`; the optional trailing number is the step count
(default 1).

### drag

```text
drag window "Inspector" by 40 -20
drag slider "Volume" by -30 0
drag row "Document" by 0 60
```

Presses button 1 at the widget and drags it by the given pixel offset
(moving windows and sliders, adjusting scrollbars, drag-and-drop).

### type

```text
type "/tmp/project"
```

Types text as key events into the currently focused editable control.  Click
the field first if it is not already focused:

```text
click textfield "Name"
type "Alice"
```

### clear

```text
clear textfield "Search"
```

Clears an editable control: focuses it, selects all, and deletes.

### press

```text
press Enter
press Escape
press Tab
press Ctrl+C
press Cmd+Q
```

Presses a key or a key combination.  GNUstep's Command key is the left Alt
key in X11, so `Cmd+...` presses Alt.

### wait

```text
wait 2s
wait 500ms
```

Pauses execution for a fixed duration.

### wait until

```text
wait until window "Workspace"
wait until button "OK"
wait until not exists dialog "Loading"
```

Waits until a widget exists (or, with `not exists`, disappears).  The default
timeout is 30 seconds; override it with `timeout`:

```text
wait until button "OK" timeout 60s
```

### assert

```text
assert window "Workspace"
assert button "Save" enabled
assert checkbox "Remember" checked
assert text contains "Complete"
assert not exists dialog "Loading"
```

Checks that a condition holds and stops the script with an assertion error if
it does not.  `text contains` searches the visible text of every widget.

`frame constant` asserts that a window's on-screen frame (position and size)
is identical to the frame first observed for that title in this run: the first
observation is the reference and passes, every later one must match it exactly.
Use it to pin window placement across repeated opens.

```text
assert window "Workspace" frame constant
```

### close window

```text
close window "About This Computer"
```

Closes a visible window by its title, regardless of which window currently
holds key focus (the Close menu item is disabled when the target was never
made key).  The close is performed in-process via `performClose:`.

### capture screenshot

```text
capture screenshot
capture screenshot "workspace.png"
```

Captures the whole screen to a PNG.  Without a filename the screenshot is
written to `/tmp/run_uitest-<timestamp>.png`.

### log

```text
log "Workspace loaded"
```

Writes a message to the execution log.

### record

```text
record
record "after-install"
```

Dumps the current on-screen widget tree (class, title and state of every
visible widget) to the execution log.  Useful for inspecting what is actually
on screen - the textual complement of `capture screenshot` (which saves a
PNG).

## Blocks and control flow

`repeat`, `if`/`else` and `macro` open a block that runs a list of commands
until the matching `end`.  Blocks nest to any depth.  The closing `end` may
name the block it closes (`end if`, `end repeat`, `end macro`) for clarity.

### repeat

```text
repeat 3
  click button "Try"
end
```

Runs the block a fixed number of times.  The count may be a variable:

```text
set ATTEMPTS="3"
repeat ${ATTEMPTS}
  click button "Try"
end
```

### if / else

```text
if window "Welcome"
  click button "Continue"
end

if not button "Update"
  log "No update available"
else
  click button "Update"
end
```

Runs the block when a widget exists (or, with `not`, when it does not), the
`else` clause otherwise.  Titles are language-independent, as elsewhere.

### macro / call

```text
macro open_about
  select menu "Workspace/About This Computer"
  wait until window "About This Computer"
  assert window "About This Computer"
end

call open_about
```

`macro NAME ... end` defines a named, reusable block of commands; `call NAME`
runs it wherever needed.  A macro may be called even before its definition
appears, and its commands may themselves use blocks.

## Variables

`set` declares a variable; `${NAME}` expands it anywhere on later lines.
Variables are expanded while the script is parsed.

```text
set PROJECT="/tmp/project"
set OPEN_WITH="ProjectCenter"

activate application "${OPEN_WITH}"
select menu "File/Open"
type "${PROJECT}"
```

## Includes

```text
include "common.uitest"
```

Loads another script (resolved relative to the including file) at that point.

## Error handling

By default execution stops at the first failing command, the error is
reported, and a non-zero exit code is returned.  The `on_error` command
changes this:

```text
on_error stop          # default: stop at the first failure
on_error continue      # keep going, report each failure
on_error retry 3       # retry the failing command up to 3 times
```

## How a script runs

The parser reads the script into a list of commands.  The executor runs them
one by one.  Each command is turned into a semantic query answered by the
query engine, which talks to the target application's DriveUI socket and
drives the UI with real X11 events.  The script never deals with object
pointers, coordinates, or widget trees.

## Logging

Every command is logged with its wall-clock time and duration:

```text
00.001 activate application "Workspace"
  SUCCESS  12 ms
00.024 click button "Open"
  SUCCESS  5 ms
```

## Exit Codes

```text
0  Success
1  Parse Error
2  Runtime Error
3  Timeout
4  Accessibility Error (app not found, widget not found, action failed)
5  Assertion Failed
```

## Worked examples

Open the About panel in English and in German, then close it again:

```text
activate application "Workspace"
select menu "Workspace/About This Computer"
wait until window "About This Computer"
assert text contains "Processor"
capture screenshot "/tmp/about_this_computer.png"
press Escape
```

German equivalent (works on an English-running Workspace too):

```text
activate application "Workspace"
select menu "Workspace/Über diesen Computer"
wait until window "Über diesen Computer"
assert text contains "Prozessor"
capture screenshot "/tmp/about_this_computer_de.png"
press Escape
```

Find `../workspace/Tests/about_this_computer.uitest` and
`../workspace/Tests/ueber_diesen_computer.uitest` in the Workspace repository
for these ready to run.

Control flow needs no running application, so
`Tests/control/control_flow.uitest` demonstrates `repeat`, `if/else` and
`macro`/`call` straight away:

```text
macro report
  if not window "example-window-nx"
    log "target window present"
  else
    log "target window absent"
  end
end

repeat 3
  log "attempt"
end
```

## Stable selectors and diagnostics

For agentic driving, `drive_ui` exposes selectors with stability grades, layout
diagnostics, ancestry, and structured output - the pieces a coding agent uses
to locate a widget, act on it, and *prove* the result instead of guessing from
a screenshot.

### Snapshot columns

`get_full_tree` and every resolved row now carry two extra fields:

```text
depth  class  text  tag  frame  screen_frame  hidden  object_id  window  stability
```

- `window` - the title of the owning window (empty for the app row).  Use it to
  scope a search when several windows share a label.
- `stability` - a handle-quality grade for choosing selectors that survive
  restarts:
  - `high` - the app row, or a view with a non-zero `tag` (an authored
    identifier the app chose, not display text)
  - `medium` - a window row (structural; the title may be translated)
  - `low` - a plain view, addressable only by its (translated) display text

Persist `high`/`medium` selectors (class + tag, or window title) across test
runs; treat `low` text matches as one-shot and re-query rather than storing.

### select

`select` resolves a compound selector and reports how stable the match is.
A unique match prints the row and a `stability=... window="..."` hint; an
ambiguous match prints every candidate (with its window and stability) and
exits 2, so a script can tell "not found" (1) from "unclear which" (2):

```sh
drive_ui --pid N select --class NSButton --text Dismiss --visible
drive_ui --pid N select --tag 1000 --window "Save As"
drive_ui --pid N select --class NSButton --text OK --index 1
```

Use `--window <title>` and `--index <n>` to pick one of several candidates.

### scroll_into_view

`scroll_into_view <object_id>` wheels toward an instantiated but clipped or
scrolled-out widget until its center is inside its owning window.  Run it when
a click/read resolves a row whose center is outside the window's frame (the
virtualized-row / clipped-target case), then retry the action:

```sh
drive_ui --pid N scroll_into_view <object_id>
drive_ui --pid N click <object_id>
```

### diagnose and parents

`diagnose` runs layout checks on a resolved widget - zero-size frame, hidden,
off-screen window, or a widget whose screen position lies outside its owning
window (the clipped / scrolled-out case that breaks click-by-center):

```sh
drive_ui --pid N diagnose --class EauAlertPanel
drive_ui --pid N diagnose --text "Save As" --window "Main"
```

`parents <object_id>` reports a widget's view/window ancestry and its class
hierarchy - the nesting and true class that the flat snapshot hides:

```sh
drive_ui --pid N parents <object_id>
```

### Structured output

`get_full_tree --json` emits the whole tree as a JSON array of objects (titles
with quotes/newlines come out escaped and parseable), and `get_many` reads the
text of several widgets in one command:

```sh
drive_ui --pid N get_full_tree --json
drive_ui --pid N get_many <object_id> <object_id> ...
```

Prefer these structured forms over `capture screenshot` when a test or agent
must *verify* something: the tree and its properties are exact, while a PNG
only shows what a screenshot seems to show.

## Design principles

The UITest expresses intent: `click button "OK"` means "find the button the user
sees as OK and press it".  Scripts never name coordinates, object IDs, or
widget hierarchies.  The executor and query engine isolate all GNUstep and X11
details, so scripts stay short, readable, and stable across applications.
