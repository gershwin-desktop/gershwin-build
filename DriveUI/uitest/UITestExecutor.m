/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Executor for the GNUstep UI Automation UITest (see UITest.h / Executor.md).
 *
 * Walks UITestProgram.commands sequentially, translating each UITestCommand into a
 * semantic query on the UITestQueryEngine.  Contains no GNUstep-specific logic;
 * all accessibility lives in the engine.  Implements the on_error policy and
 * produces a per-command timed log (Executor.md sections 15/19).
 *
 * Durations ("100ms", "2s", "5m") are parsed here to seconds.
 */

#import "UITest.h"

@implementation UITestExecutor

- (id)initWithProgram:(UITestProgram *)program engine:(UITestQueryEngine *)engine
{
  if ((self = [super init]))
    {
      program_ = [program retain];
      engine_ = [engine retain];
      policy_ = @"stop";
      retryCount_ = 0;
      log_ = [[NSMutableString alloc] init];
      macros_ = [[NSMutableDictionary alloc] init];
      frameRefs_ = [[NSMutableDictionary alloc] init];
      /* Register every macro definition before running, so `call` works even
       * when the definition textually follows the call site (or lives inside
       * a block).  Nested blocks are walked recursively. */
      [self collectMacrosInto: macros_ from: program_.commands];
    }
  return self;
}
- (void)dealloc
{
  [program_ release];
  [engine_ release];
  [policy_ release];
  [log_ release];
  [macros_ release];
  [frameRefs_ release];
  [super dealloc];
}
- (NSString *)log { return log_; }

- (void)collectMacrosInto:(NSMutableDictionary *)macros
                    from:(NSArray *)commands
{
  for (UITestCommand *cmd in commands)
    {
      if (cmd.type == DDSCmdMacro && cmd.string)
        [macros setObject: cmd.body ?: [NSArray array] forKey: cmd.string];
      [self collectMacrosInto: macros from: cmd.body];
      [self collectMacrosInto: macros from: cmd.elseBody];
    }
}

/* Parse a duration "100ms"/"2s"/"5m" to seconds. */
 + (double)durationForString:(NSString *)s
{
  if (!s) return 0;
  if ([s hasSuffix: @"ms"]) return [[s substringToIndex: [s length] - 2] doubleValue] / 1000.0;
  if ([s hasSuffix: @"s"])  return [[s substringToIndex: [s length] - 1] doubleValue];
  if ([s hasSuffix: @"m"])  return [[s substringToIndex: [s length] - 1] doubleValue] * 60.0;
  return [s doubleValue];
}

/* Substitute ${VAR} references with the current value of a runtime variable
 * (set via setcount); unknown variables expand to an empty string.  Static
 * `set VAR="value"` variables were already expanded at parse time. */
- (NSString *)expandVariables:(NSString *)s
{
  if (s == nil) return nil;
  for (NSString *key in [program_.variables allKeys])
    {
      NSString *placeholder = [NSString stringWithFormat: @"${%@}", key];
      if ([s rangeOfString: placeholder].location != NSNotFound)
        s = [s stringByReplacingOccurrencesOfString: placeholder
          withString: [program_.variables objectForKey: key]];
    }
  return s;
}

static void SleepSeconds(double sec)
{
  if (sec <= 0) return;
  struct timespec ts;
  ts.tv_sec = (time_t)sec;
  ts.tv_nsec = (long)((sec - (double)ts.tv_sec) * 1e9);
  nanosleep(&ts, NULL);
}

static NSString *CommandName(UITestCommandType t)
{
  switch (t)
    {
      case DDSCmdActivate:    return @"activate application";
      case DDSCmdActivateXWindow: return @"activate xwindow";
      case DDSCmdLaunchApp:   return @"launch application";
      case DDSCmdFocusWindow: return @"focus window";
      case DDSCmdCloseWindow: return @"close window";
      case DDSCmdSelectMenu:  return @"select menu";
      case DDSCmdSelectGlobalMenu: return @"select global menu";
      case DDSCmdInvokeButton: return @"invoke button";
      case DDSCmdClick:       return @"click";
      case DDSCmdDoubleClick: return @"doubleclick";
      case DDSCmdRightClick:  return @"rightclick";
      case DDSCmdContextMenu: return @"context menu";
      case DDSCmdHover:       return @"hover";
      case DDSCmdScroll:      return @"scroll";
      case DDSCmdDrag:        return @"drag";
      case DDSCmdType:        return @"type";
      case DDSCmdClear:       return @"clear";
      case DDSCmdPress:       return @"press";
      case DDSCmdRun:         return @"run";
      case DDSCmdWait:        return @"wait";
      case DDSCmdWaitUntil:   return @"wait until";
      case DDSCmdAssert:      return @"assert";
      case DDSCmdCapture:     return @"capture screenshot";
      case DDSCmdRecord:      return @"record";
      case DDSCmdLog:         return @"log";
      case DDSCmdOptions:     return @"on_error";
      case DDSCmdRepeat:      return @"repeat";
      case DDSCmdIf:          return @"if";
      case DDSCmdMacro:       return @"macro";
      case DDSCmdCall:        return @"call";
      default:                return @"?";
    }
}

- (NSString *)formatCommand:(UITestCommand *)cmd
{
  NSMutableString *s = [NSMutableString stringWithString: CommandName(cmd.type)];
  if ((cmd.type == DDSCmdClick || cmd.type == DDSCmdDoubleClick ||
       cmd.type == DDSCmdRightClick || cmd.type == DDSCmdClear ||
       cmd.type == DDSCmdHover || cmd.type == DDSCmdDrag) &&
      cmd.role != DDSRoleAny)
    {
      [s appendFormat: @" %@", [[UITestRoleClassName(cmd.role) lowercaseString]
        stringByReplacingOccurrencesOfString: @"ns" withString: @"ns"]];
    }
  if (cmd.type == DDSCmdScroll && cmd.role != DDSRoleAny)
    [s appendFormat: @" %@", [[UITestRoleClassName(cmd.role) lowercaseString]
      stringByReplacingOccurrencesOfString: @"ns" withString: @"ns"]];
  if (cmd.string) [s appendFormat: @" \"%@\"", cmd.string];
  if (cmd.type == DDSCmdRepeat && [[cmd words] count] > 0)
    [s appendFormat: @" %@", [[cmd words] objectAtIndex: 0]];
  if (cmd.type == DDSCmdScroll && [[cmd words] count] > 0)
    {
      [s appendFormat: @" %@", [[cmd words] objectAtIndex: 0]];
      if ([[cmd words] count] > 1)
        [s appendFormat: @" %@", [[cmd words] objectAtIndex: 1]];
    }
  if (cmd.type == DDSCmdDrag && [[cmd words] count] > 0)
    {
      [s appendFormat: @" by %@", [[cmd words] objectAtIndex: 0]];
      if ([[cmd words] count] > 1) [s appendFormat: @" %@", [[cmd words] objectAtIndex: 1]];
    }
  return s;
}

/* Execute one command.  On success returns 0; otherwise an exit code and
 * reason.  This is the Executor.md "execute(node)" step. */
- (int)execute:(UITestCommand *)cmd reason:(NSString **)reason
{
  NSString *err = nil;
  NSDate *start = nil;
  int rc = 0;

  /* free-form duration timeout for wait-until is carried in words[0] (the
   * parser stores only the duration token after the "timeout" keyword).  The
   * count form (assertKind == DDSAssertXWindowCount) puts its operator and
   * operand in words instead, so it keeps the default timeout. */
  double cTimeout = 30.0;
  if (cmd.type == DDSCmdWaitUntil && [[cmd words] count] > 0
      && cmd.assertKind != DDSAssertXWindowCount)
    {
      NSString *durTok = [[cmd words] objectAtIndex: 0];
      cTimeout = [durTok doubleValue];
    }
  (void)cTimeout;

  start = [NSDate date];
  switch (cmd.type)
    {
    case DDSCmdActivate:
      if ([engine_ resolveApplication: cmd.string error: &err] &&
          [engine_ activate: &err]) rc = 0;
      else rc = DDSAccessibilityError;
      break;
    case DDSCmdActivateXWindow:
      rc = ([engine_ activateXWindow: cmd.string error: &err])
        ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdLaunchApp:
      rc = ([engine_ launchApplication: cmd.string error: &err])
        ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdFocusWindow:
      if ([engine_ pid] == 0)
        rc = ([engine_ resolveApplication: cmd.string error: &err])
          ? 0 : DDSAccessibilityError;
      else rc = ([engine_ focusMainWindow: &err]) ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdCloseWindow:
      if ([engine_ pid] == 0)
        { err = @"close window needs a target application"; rc = 2; break; }
      rc = ([engine_ closeWindowTitle: cmd.string error: &err])
        ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdInvokeButton:
      if ([engine_ pid] == 0)
        { err = @"invoke button needs a target application"; rc = 2; break; }
      rc = ([engine_ invokeModalButton: cmd.string error: &err])
        ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdSelectMenu:
      if (!cmd.string) { err = @"select menu needs a path (use \"Top/Sub\")"; rc = 1; break; }
      rc = ([engine_ selectMenuPath: cmd.string error: &err])
        ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdSelectGlobalMenu:
      if (!cmd.string) { err = @"select global menu needs a path (use \"Top/Sub\")"; rc = 1; break; }
      rc = ([engine_ triggerGlobalMenuPath: cmd.string error: &err])
        ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdClick:
    case DDSCmdDoubleClick:
    case DDSCmdRightClick:
      {
        int btn = (cmd.type == DDSCmdRightClick) ? 3 : 1;
        int cnt = (cmd.type == DDSCmdDoubleClick) ? 2 : 1;
        rc = [engine_ clickRole: cmd.role title: cmd.string button: btn
          count: cnt error: &err] ? 0 : DDSAccessibilityError;
      }
      break;
    case DDSCmdHover:
      rc = [engine_ hoverRole: cmd.role title: cmd.string error: &err]
        ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdContextMenu:
      if (!cmd.string || !cmd.string2)
        { err = @"context menu needs \"Widget\" \"Item Title\""; rc = 1; break; }
      rc = ([engine_ contextMenuRole: cmd.role title: cmd.string
          itemTitle: cmd.string2 error: &err]) ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdScroll:
      {
        NSString *dir = ([[cmd words] count] > 0) ? [[cmd words] objectAtIndex: 0] : @"down";
        int amount = 1;
        if ([[cmd words] count] > 1) amount = [[[cmd words] objectAtIndex: 1] intValue];
        rc = [engine_ scrollRole: cmd.role title: cmd.string direction: dir
          amount: amount error: &err] ? 0 : DDSAccessibilityError;
      }
      break;
    case DDSCmdDrag:
      {
        double dx = 0, dy = 0;
        NSArray *w = [cmd words];
        NSUInteger idx = 0;
        if ([w count] > 0 && [[w objectAtIndex: 0] isEqualToString: @"by"]) idx = 1;
        if ([w count] > idx) dx = [[w objectAtIndex: idx] doubleValue];
        if ([w count] > idx + 1) dy = [[w objectAtIndex: idx + 1] doubleValue];
        if (dx == 0 && dy == 0)
          {
            err = @"drag needs an offset (e.g. drag window \"...\" by 30 20)";
            rc = 1;
            break;
          }
        rc = [engine_ dragRole: cmd.role title: cmd.string byX: dx byY: dy
          error: &err] ? 0 : DDSAccessibilityError;
      }
      break;
    case DDSCmdType:
      rc = [engine_ type: cmd.string error: &err] ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdClear:
      rc = [engine_ clearRole: cmd.role title: cmd.string error: &err]
        ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdPress:
      /* `press` with no argument means Return (the common submit action). */
      rc = [engine_ pressKeyCombo: cmd.string ?: @"Return" error: &err]
        ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdRun:
      rc = [engine_ runCommandInRunDialog: cmd.string error: &err]
        ? 0 : DDSAccessibilityError;
      break;
    case DDSCmdWait:
      SleepSeconds([UITestExecutor durationForString: cmd.string]);
      rc = 0;
      break;
    case DDSCmdWaitUntil:
      {
        double to = cTimeout;
        BOOL ok = NO;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: to];
        while ([[NSDate date] compare: deadline] == NSOrderedAscending)
          {
            if (cmd.assertKind == DDSAssertXWindowCount)
              {
                NSString *op = ([cmd.words count] > 0) ? [cmd.words objectAtIndex: 0] : @"=";
                NSString *expectedStr = [self expandVariables: [cmd.words lastObject]];
                int expected = [expectedStr intValue];
                ok = [engine_ assertXWindowCount: cmd.string op: op expected: expected
                  error: nil];
              }
            else if (cmd.assertKind == DDSAssertMenuBar || cmd.assertKind == DDSAssertMenuBarNot)
              {
                ok = [engine_ menuBarHasItem: cmd.string
                  exists: (cmd.assertKind == DDSAssertMenuBar) error: nil];
              }
            else
              {
                BOOL present = [engine_ doesWidgetExist: cmd.role title: cmd.string
                  contains: nil error: &err];
                ok = (cmd.assertKind == DDSAssertNotExists) ? !present : present;
              }
            if (ok) break;
            usleep(100000);
          }
        rc = ok ? 0 : DDSTimeout;
        if (!ok) err = @"timed out waiting for condition";
      }
      break;
    case DDSCmdSetCount:
      {
        /* setcount VAR = count xwindow "Title" - store the window count at
         * runtime so later comparisons can be relative. */
        NSString *var = cmd.string;
        NSString *title = cmd.string2;
        if (var == nil || [var length] == 0 || title == nil)
          { err = @"setcount needs VAR and a title"; rc = 1; break; }
        int count = [engine_ countXWindowsWithTitle: title error: &err];
        if (count < 0) { rc = 1; break; }
        [program_.variables setObject: [NSString stringWithFormat: @"%d", count]
                               forKey: var];
        rc = 0;
      }
      break;
    case DDSCmdAssert:
      if ([engine_ pid] == 0) { err = @"assert needs a target application"; rc = 2; break; }
      if (cmd.assertKind == DDSAssertFrameConstant)
        {
          NSString *e2 = nil;
          rc = [self assertFrameConstantForWindow: cmd.string error: &e2]
            ? 0 : DDSAssertFailed;
          err = e2;
        }
      else if (cmd.assertKind == DDSAssertMenuExists
               || cmd.assertKind == DDSAssertMenuNotExists
               || cmd.assertKind == DDSAssertMenuChecked
               || cmd.assertKind == DDSAssertMenuNotChecked
               || cmd.assertKind == DDSAssertMenuEnabled
               || cmd.assertKind == DDSAssertMenuDisabled
               || cmd.assertKind == DDSAssertMenuShortcut)
        {
          NSString *e2 = nil;
          rc = [engine_ assertMenuItemPath: cmd.string kind: cmd.assertKind
            shortcut: cmd.string2 error: &e2] ? 0 : DDSAssertFailed;
          err = e2;
        }
      else if (cmd.assertKind == DDSAssertXWindowCount)
        {
          NSString *op = ([cmd.words count] > 0) ? [cmd.words objectAtIndex: 0] : @"=";
          NSString *expectedStr = [self expandVariables: [cmd.words lastObject]];
          int expected = [expectedStr intValue];
          NSString *e2 = nil;
          rc = [engine_ assertXWindowCount: cmd.string op: op expected: expected
            error: &e2] ? 0 : DDSAssertFailed;
          err = e2;
        }
      else if (cmd.assertKind == DDSAssertMenuBar || cmd.assertKind == DDSAssertMenuBarNot)
        {
          NSString *e2 = nil;
          rc = [engine_ menuBarHasItem: cmd.string
            exists: (cmd.assertKind == DDSAssertMenuBar) error: &e2]
            ? 0 : DDSAssertFailed;
          err = e2;
        }
      else
        rc = [engine_ assertRole: cmd.role title: cmd.string kind: cmd.assertKind
          needle: cmd.string error: &err] ? 0 : DDSAssertFailed;
      break;
    case DDSCmdCapture:
      {
        NSString *outPath = nil;
        rc = [engine_ captureScreenshotToPath: cmd.string outPath: &outPath
          error: &err] ? 0 : DDSAccessibilityError;
        if (rc == 0 && outPath)
          fprintf(stderr, "[uitest] screenshot saved to %s\n", [outPath UTF8String]);
      }
      break;
    case DDSCmdRecord:
      {
        /* Capture the on-screen widget state into the execution log: a
         * read-only dump of the visible tree, complementing `capture
         * screenshot` (which saves a PNG). */
        NSString *tree = [engine_ widgetTreeText];
        if (!tree) { rc = DDSAccessibilityError; break; }
        NSString *label = cmd.string ?: @"";
        fprintf(stderr, "[uitest] record %s\n%s\n", [label UTF8String], [tree UTF8String]);
      }
      rc = 0;
      break;
    case DDSCmdRepeat:
      {
        int count = ([[cmd words] count] > 0) ? [[[cmd words] objectAtIndex: 0] intValue] : 0;
        int bodyRc = 0;
        for (int i = 0; i < count; i++)
          {
            bodyRc = [self runSequence: cmd.body applyPolicy: NO];
            if (bodyRc != 0) break;
          }
        rc = bodyRc;
      }
      break;
    case DDSCmdIf:
      {
        if (cmd.assertKind == DDSAssertDocked
            || cmd.assertKind == DDSAssertNotDocked)
          {
            BOOL state = [engine_ assertRole: cmd.role title: cmd.string
              kind: cmd.assertKind needle: nil error: &err];
            BOOL takeThen = state;
            rc = takeThen
              ? [self runSequence: cmd.body applyPolicy: NO]
              : [self runSequence: cmd.elseBody ?: [NSArray array] applyPolicy: NO];
            break;
          }
        if (cmd.assertKind == DDSAssertMenuExists
            || cmd.assertKind == DDSAssertMenuNotExists
            || cmd.assertKind == DDSAssertMenuChecked
            || cmd.assertKind == DDSAssertMenuNotChecked
            || cmd.assertKind == DDSAssertMenuEnabled
            || cmd.assertKind == DDSAssertMenuDisabled
            || cmd.assertKind == DDSAssertMenuShortcut)
          {
            BOOL state = [engine_ assertMenuItemPath: cmd.string
              kind: cmd.assertKind shortcut: cmd.string2 error: &err];
            BOOL takeThen = state;
            rc = takeThen
              ? [self runSequence: cmd.body applyPolicy: NO]
              : [self runSequence: cmd.elseBody ?: [NSArray array] applyPolicy: NO];
            break;
          }
        BOOL present = [engine_ doesWidgetExist: cmd.role title: cmd.string
          contains: nil error: &err];
        BOOL takeThen = (cmd.assertKind == DDSAssertNotExists) ? !present : present;
        rc = takeThen
          ? [self runSequence: cmd.body applyPolicy: NO]
          : [self runSequence: cmd.elseBody ?: [NSArray array] applyPolicy: NO];
      }
      break;
    case DDSCmdMacro:
      /* Macro definitions are registered up front (see initWithProgram:), so
       * reaching the definition itself is a no-op. */
      rc = 0;
      break;
    case DDSCmdCall:
      {
        NSArray *body = cmd.string ? [macros_ objectForKey: cmd.string] : nil;
        if (!body)
          {
            err = [NSString stringWithFormat: @"call: no macro named '%@'",
              cmd.string ?: @"(unnamed)"];
            rc = 1;
            break;
          }
        rc = [self runSequence: body applyPolicy: NO];
      }
      break;
    case DDSCmdLog:
      fprintf(stderr, "[uitest] %s\n", [cmd.string ?: @"" UTF8String]);
      rc = 0;
      break;
    case DDSCmdOptions:
      if ([[cmd words] count] > 0)
        policy_ = [[cmd words] objectAtIndex: 0];
      retryCount_ = 0;
      if ([[cmd words] count] > 1)
        retryCount_ = [[[cmd words] objectAtIndex: 1] intValue];
      rc = 0;
      break;
    default:
      rc = 1;
      err = @"unhandled command";
    }

  double ms = -[start timeIntervalSinceNow] * 1000.0;
  if ([log_ length]) [log_ appendString: @"\n"];
  if (rc == 0)
    [log_ appendFormat: @"%.3f %@\n  SUCCESS  %.0f ms", ms / 1000.0,
      [self formatCommand: cmd], ms];
  else
    [log_ appendFormat: @"%.3f %@\n  %@  %.0f ms", ms / 1000.0,
      [self formatCommand: cmd], err ?: @"runtime error", ms];
  if (reason) *reason = err;
  return rc;
}

/* Assert that a window's on-screen frame is identical to the one first
 * observed for that title in this run: the first observation is the reference
 * and passes, every later one must match it exactly.  Used to pin window
 * placement across repeated opens (e.g. a viewer window must open at the same
 * position every time). */
- (BOOL)assertFrameConstantForWindow:(NSString *)title error:(NSString **)err
{
  NSString *frame = [engine_ frameOfWindowTitle: title error: err];
  if (!frame) return NO;
  NSString *ref = [frameRefs_ objectForKey: title];
  if (!ref)
    {
      [frameRefs_ setObject: frame forKey: title];
      fprintf(stderr, "[uitest] frame of window '%s' recorded: %s\n",
        [title UTF8String], [frame UTF8String]);
      return YES;
    }
  /* Compare with a small tolerance: the window manager can round a restored
   * frame by a pixel or two, so an exact string match would flake on
   * placement that is in fact stable.  A mismatch beyond 2px is a real
   * placement regression. */
  NSRect a = NSRectFromString (ref);
  NSRect b = NSRectFromString (frame);
  BOOL same = (fabs (NSMinX (a) - NSMinX (b)) <= 2.0
               && fabs (NSMinY (a) - NSMinY (b)) <= 2.0
               && fabs (NSWidth (a) - NSWidth (b)) <= 2.0
               && fabs (NSHeight (a) - NSHeight (b)) <= 2.0);
  if (same)
    {
      fprintf(stderr, "[uitest] frame of window '%s' stable: %s\n",
        [title UTF8String], [frame UTF8String]);
      return YES;
    }
  if (err) *err = [NSString stringWithFormat:
    @"frame of window '%@' changed (was %@, now %s)",
    title, ref, [frame UTF8String]];
  return NO;
}

/* Walk a command sequence, applying the error policy only at the top level
 * (a nested repeat/if/macro body propagates its first failure up to the
 * surrounding sequence, which then reacts to it). */
- (int)runSequence:(NSArray *)commands applyPolicy:(BOOL)applyPolicy
{
  int rc = 0;
  int retries = 0;
  for (UITestCommand *cmd in commands)
    {
      /* Each command runs in its own autorelease pool: every drive_ui
       * subprocess spawns pipes and file handles, and without a drain those
       * fds accumulate for the whole script and a long one (e.g.
       * menu_follows_app) exhausts the file-descriptor limit (EMFILE). */
      @autoreleasepool
        {
          NSString *reason = nil;
          rc = [self execute: cmd reason: &reason];
          if (rc != 0)
            {
              if (!applyPolicy) return rc;
              if ([policy_ caseInsensitiveCompare: @"continue"] == NSOrderedSame)
                continue;
              else if ([policy_ caseInsensitiveCompare: @"retry"] == NSOrderedSame &&
                       retries < retryCount_)
                {
                  retries++;
                  /* re-run the failed command */
                  rc = [self execute: cmd reason: &reason];
                  if (rc == 0) { retries = 0; continue; }
                  return rc;
                }
              return rc;  /* stop (default) */
            }
          retries = 0;
        }
    }
  return 0;
}

- (int)run
{
  return [self runSequence: program_.commands applyPolicy: YES];
}

@end