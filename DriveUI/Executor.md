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

## Design principles

The UITest expresses intent: `click button "OK"` means "find the button the user
sees as OK and press it".  Scripts never name coordinates, object IDs, or
widget hierarchies.  The executor and query engine isolate all GNUstep and X11
details, so scripts stay short, readable, and stable across applications.
