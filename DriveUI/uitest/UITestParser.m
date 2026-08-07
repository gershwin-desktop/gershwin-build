/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * AST + parser for the GNUstep UI Automation UITest (see UITest.h / Executor.md).
 *
 * The parser consumes the lexer token stream one line (command) at a time and
 * emits UITestCommand nodes.  It owns the included-file handling and the
 * `set VAR=...` variable declarations, which live in UITestProgram.
 */

#import "UITest.h"

@implementation UITestCommand
- (id)initWithType:(UITestCommandType)t line:(NSUInteger)line col:(NSUInteger)col
{
  if ((self = [super init]))
    {
      type_ = t;
      role_ = DDSRoleAny;
      assertKind_ = DDSAssertExists;
      string_ = nil;
      string2_ = nil;
      words_ = [[NSMutableArray alloc] init];
      body_ = [[NSMutableArray alloc] init];
      elseBody_ = [[NSMutableArray alloc] init];
      line_ = line;
      col_ = col;
    }
  return self;
}
- (void)dealloc
{
  [string_ release];
  [string2_ release];
  [words_ release];
  [body_ release];
  [elseBody_ release];
  [super dealloc];
}
- (UITestCommandType)type { return type_; }
- (void)setType:(UITestCommandType)t { type_ = t; }
- (UITestRole)role { return role_; }
- (void)setRole:(UITestRole)r { role_ = r; }
- (UITestAssertKind)assertKind { return assertKind_; }
- (void)setAssertKind:(UITestAssertKind)k { assertKind_ = k; }
- (NSString *)string { return string_; }
- (void)setString:(NSString *)s { [s retain]; [string_ release]; string_ = s; }
- (NSString *)string2 { return string2_; }
- (void)setString2:(NSString *)s { [s retain]; [string2_ release]; string2_ = s; }
- (NSMutableArray *)words { return words_; }
- (NSMutableArray *)body { return body_; }
- (NSMutableArray *)elseBody { return elseBody_; }
- (NSUInteger)line { return line_; }
- (void)setLine:(NSUInteger)l { line_ = l; }
- (NSUInteger)col { return col_; }
- (void)setCol:(NSUInteger)c { col_ = c; }
@end

@implementation UITestProgram
- (id)init
{
  if ((self = [super init]))
    {
      commands_ = [[NSMutableArray alloc] init];
      variables_ = [[NSMutableDictionary alloc] init];
      currentDef_ = nil;
    }
  return self;
}
- (void)dealloc
{
  [commands_ release];
  [variables_ release];
  [currentDef_ release];
  [super dealloc];
}
- (NSMutableArray *)commands { return commands_; }
- (NSMutableDictionary *)variables { return variables_; }
- (NSString *)currentDef { return currentDef_; }
- (void)setCurrentDef:(NSString *)d { [d retain]; [currentDef_ release]; currentDef_ = d; }
@end

/* Maps a UITest object-type keyword to a UITestRole. */
UITestRole UITestRoleFromName(NSString *name)
{
  static NSDictionary *map = nil;
  if (!map)
    map = [[NSDictionary alloc] initWithObjectsAndKeys:
      @(DDSRoleApplication), @"application",
      @(DDSRoleWindow), @"window",
      @(DDSRoleXWindow), @"xwindow",
      @(DDSRoleDialog), @"dialog",
      @(DDSRoleModal), @"modal",
      @(DDSRoleSidebar), @"sidebar",
      @(DDSRoleSheet), @"sheet",
      @(DDSRoleButton), @"button",
      @(DDSRoleMenu), @"menu",
      @(DDSRoleMenuItem), @"menuitem",
      @(DDSRoleTextField), @"textfield",
      @(DDSRoleTextArea), @"textarea",
      @(DDSRoleCheckbox), @"checkbox",
      @(DDSRoleRadio), @"radio",
      @(DDSRolePopup), @"popup",
      @(DDSRoleComboBox), @"combobox",
      @(DDSRoleTable), @"table",
      @(DDSRoleRow), @"row",
      @(DDSRoleColumn), @"column",
      @(DDSRoleList), @"list",
      @(DDSRoleImage), @"image",
      @(DDSRoleToolbar), @"toolbar",
      @(DDSRoleTab), @"tab",
      @(DDSRoleTabItem), @"tabitem",
      @(DDSRoleSlider), @"slider",
      @(DDSRoleProgress), @"progress",
      @(DDSRoleLabel), @"label",
      @(DDSRoleIcon), @"icon",
      nil];
  NSNumber *n = [map objectForKey: [name lowercaseString]];
  return n ? (UITestRole)[n intValue] : DDSRoleAny;
}

/* Maps a role to the ObjC class substring used to filter drive_ui snapshots.
 * Snapshots carry the real ObjC class name in field 2, so we match a prefix. */
NSString *UITestRoleClassName(UITestRole role)
{
  switch (role)
    {
      case DDSRoleWindow:  case DDSRoleDialog:  case DDSRoleSheet:
        return @"NSWindow";
      case DDSRoleModal:
        /* `modal` is not a widget class in the tree; it is answered by the
         * engine's modal query, so the class filter is never matched against
         * a tree row. */
        return @"!Modal!";
      case DDSRoleXWindow:
        /* `xwindow` is answered by a whole-X-display scan (any app, GNUstep
         * or not), not the target app's widget tree. */
        return @"!XWindow!";
      case DDSRoleSidebar:
        return @"GWViewerSidebar";
      case DDSRoleButton:                       return @"NSButton";
      case DDSRoleMenu:                         return @"NSMenu";
      case DDSRoleMenuItem:                     return @"NSMenuItem";
      case DDSRoleTextField:                    return @"NSTextField";
      case DDSRoleTextArea:                     return @"NSTextView";
      case DDSRoleCheckbox:                     return @"NSButton";
      case DDSRoleRadio:                        return @"NSButton";
      case DDSRolePopup:                        return @"NSPopUpButton";
      case DDSRoleComboBox:                     return @"NSComboBox";
      case DDSRoleTable:                        return @"NSTableView";
      case DDSRoleRow:                          return @"NSTableViewRow"; /* approximate */
      case DDSRoleColumn:                       return @"NSTableColumn";
      case DDSRoleList:                         return @"NSTableView";
      case DDSRoleImage:                        return @"NSImageView";
      case DDSRoleToolbar:                      return @"NSToolbar";
      case DDSRoleTab:        case DDSRoleTabItem:  return @"NSTabView";
      case DDSRoleSlider:                       return @"NSSlider";
      case DDSRoleProgress:                     return @"NSProgressIndicator";
case DDSRoleLabel:                        return @"NSTextField";
      case DDSRoleIcon:                          return @"DockIcon";
      default:                                  return nil;
    }
}

/* A nested block being parsed (repeat/if/macro).  type_ names the block
 * keyword, target_ is the array receiving the block's commands (the `then`
 * body of an if, or its else body after `else`), and elseSeen_ tracks whether
 * an if block has consumed its `else` clause. */
@interface DDSBlockCtx : NSObject
{
  NSString *type_;
  NSMutableArray *target_;
  NSMutableArray *elseTarget_; /* an if block's else body (nil otherwise) */
  BOOL elseSeen_ : 1;
}
- (id)initWithType:(NSString *)type target:(NSMutableArray *)target
         elseTarget:(NSMutableArray *)elseTarget;
@property (copy) NSString *type;
@property (retain) NSMutableArray *target;
@property (retain) NSMutableArray *elseTarget;
@property BOOL elseSeen;
@end

@implementation DDSBlockCtx
- (id)initWithType:(NSString *)type target:(NSMutableArray *)target
         elseTarget:(NSMutableArray *)elseTarget
{
  if ((self = [super init]))
    {
      type_ = [type copy];
      target_ = [target retain];
      elseTarget_ = [elseTarget retain];
      elseSeen_ = NO;
    }
  return self;
}
- (void)dealloc
{
  [type_ release];
  [target_ release];
  [elseTarget_ release];
  [super dealloc];
}
- (NSString *)type { return type_; }
- (void)setType:(NSString *)t { [t retain]; [type_ release]; type_ = t; }
- (NSMutableArray *)target { return target_; }
- (void)setTarget:(NSMutableArray *)t { [t retain]; [target_ release]; target_ = t; }
- (NSMutableArray *)elseTarget { return elseTarget_; }
- (void)setElseTarget:(NSMutableArray *)t { [t retain]; [elseTarget_ release]; elseTarget_ = t; }
- (BOOL)elseSeen { return elseSeen_; }
- (void)setElseSeen:(BOOL)b { elseSeen_ = b; }
@end

@implementation UITestParser

- (UITestProgram *)parseFile:(NSString *)path error:(NSString **)err
{
  NSString *text = [NSString stringWithContentsOfFile: path
    encoding: NSUTF8StringEncoding error: nil];
  if (!text)
    {
      text = [NSString stringWithContentsOfFile: path
        encoding: NSISOLatin1StringEncoding error: nil];
    }
  if (!text)
    {
      if (err) *err = [NSString stringWithFormat: @"cannot read script file %@", path];
      return nil;
    }
  UITestProgram *prog = [[[UITestProgram alloc] init] autorelease];
  if (![self parseString: text sourceName: path program: prog error: err])
    return nil;
  return prog;
}

- (UITestProgram *)parseString:(NSString *)text sourceName:(NSString *)name
                     program:(UITestProgram *)prog error:(NSString **)err
{
  if (!blockStack_) blockStack_ = [[NSMutableArray alloc] init];
  NSArray *lines = [text componentsSeparatedByString: @"\n"];
  NSUInteger lineNo = 0;
  for (NSString *rawLine in lines)
    {
      lineNo++;
      NSString *line = rawLine;
      NSRange hash = [line rangeOfString: @"#"];
      if (hash.location != NSNotFound)
        line = [line substringToIndex: hash.location];
      line = [line stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]];
      if ([line length] == 0) continue;

      if ([line hasPrefix: @"include "])
        {
          NSString *incPath = [line substringFromIndex: [@"include " length]];
          incPath = [incPath stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
          if ([incPath hasPrefix: @"\""] && [incPath hasSuffix: @"\""]
              && [incPath length] >= 2)
            incPath = [incPath substringWithRange: NSMakeRange(1, [incPath length] - 2)];
          NSString *dir = [name stringByDeletingLastPathComponent];
          NSString *full = [dir stringByAppendingPathComponent: incPath];
          NSString *incText = [NSString stringWithContentsOfFile: full
            encoding: NSUTF8StringEncoding error: nil];
          if (!incText)
            {
              if (err) *err = [NSString stringWithFormat: @"%@:%lu: cannot include %@",
                name, (unsigned long)lineNo, incPath];
              return nil;
            }
          if (![self parseString: incText sourceName: full program: prog error: err])
            return nil;
          continue;
        }

      if ([line hasPrefix: @"setcount "])
        {
          /* setcount VAR = count xwindow "Title" - store the current count of
           * X windows whose name contains "Title" into the runtime variable
           * VAR (usable in later `assert xwindow "Title" count <op> ${VAR}`
           * and `wait until ...` comparisons). */
          NSString *rest = [line substringFromIndex: [@"setcount " length]];
          NSRange eq = [rest rangeOfString: @"="];
          if (eq.location == NSNotFound || eq.location == 0)
            {
              if (err) *err = [NSString stringWithFormat: @"%@:%lu: malformed setcount (need VAR = count xwindow \"Title\")",
                name, (unsigned long)lineNo];
              return nil;
            }
          NSString *var = [[rest substringToIndex: eq.location]
            stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
          NSString *val = [[rest substringFromIndex: eq.location + 1]
            stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
          if (![val hasPrefix: @"count xwindow "])
            {
              if (err) *err = [NSString stringWithFormat: @"%@:%lu: setcount needs `count xwindow \"Title\"`",
                name, (unsigned long)lineNo];
              return nil;
            }
          NSString *titleExpr = [val substringFromIndex: [@"count xwindow " length]];
          titleExpr = [titleExpr stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
          if ([titleExpr hasPrefix: @"\""] && [titleExpr hasSuffix: @"\""] && [titleExpr length] >= 2)
            titleExpr = [titleExpr substringWithRange: NSMakeRange(1, [titleExpr length] - 2)];
          UITestCommand *cmd = [[[UITestCommand alloc] initWithType: DDSCmdSetCount
            line: lineNo col: 1] autorelease];
          cmd.string = var;
          cmd.string2 = titleExpr;
          [[prog commands] addObject: cmd];
          continue;
        }

      if ([line hasPrefix: @"set "])
        {
          /* set VAR="value" - a variable declaration. */
          NSString *rest = [line substringFromIndex: [@"set " length]];
          NSRange eq = [rest rangeOfString: @"="];
          if (eq.location == NSNotFound || eq.location == 0)
            {
              if (err) *err = [NSString stringWithFormat: @"%@:%lu: malformed set (need VAR=\"value\")",
                name, (unsigned long)lineNo];
              return nil;
            }
          NSString *var = [[rest substringToIndex: eq.location]
            stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
          NSString *val = [[rest substringFromIndex: eq.location + 1]
            stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
          if ([val hasPrefix: @"\""] && [val hasSuffix: @"\""] && [val length] >= 2)
            val = [val substringWithRange: NSMakeRange(1, [val length] - 2)];
          val = [val stringByReplacingOccurrencesOfString: @"\\\"" withString: @"\""];
          val = [val stringByReplacingOccurrencesOfString: @"\\\\" withString: @"\\"];
          [[prog variables] setObject: val forKey: var];
          continue;
        }

      /* Expand ${VAR} references before tokenising so quoted strings that
       * contain variables are handled uniformly. */
      for (NSString *key in [[prog variables] allKeys])
        {
          NSString *placeholder = [NSString stringWithFormat: @"${%@}", key];
          line = [line stringByReplacingOccurrencesOfString: placeholder
            withString: [[prog variables] objectForKey: key]];
        }

      /* Regular command line: split into words and quoted strings, honouring
       * embedded spaces inside quotes (e.g. type "to the moon"). */
      NSScanner *scanner = [NSScanner scannerWithString: line];
      NSMutableArray *words = [NSMutableArray array];
      NSString *str1 = nil;
      NSString *str2 = nil;
      [scanner setCharactersToBeSkipped: [NSCharacterSet whitespaceCharacterSet]];
      while ([scanner isAtEnd] == NO)
        {
          NSString *tok = nil;
          if ([scanner scanString: @"\"" intoString: NULL])
            {
              NSMutableString *acc = [NSMutableString string];
              NSString *piece = nil;
              while ([scanner scanUpToString: @"\"" intoString: &piece])
                [acc appendString: piece];
              if ([scanner isAtEnd])  /* unterminated quote */
                {
                  if (err) *err = [NSString stringWithFormat: @"%@:%lu: unterminated string",
                    name, (unsigned long)lineNo];
                  return nil;
                }
              [scanner scanString: @"\"" intoString: NULL];  /* consume closing quote */
              /* handle struggled escapes */
              NSString *s = [[[acc copy] autorelease]
                stringByReplacingOccurrencesOfString: @"\\\"" withString: @"\""];
              s = [s stringByReplacingOccurrencesOfString: @"\\\\" withString: @"\\"];
              if (!str1) str1 = s;
              else if (!str2) str2 = s;
            }
          else if ([scanner scanUpToString: @"\"" intoString: &tok])
            {
              /* tok may contain a trailing quote that begins a quoted string;
               * trim any (no inner spaces expected in unquoted tokens). */
              tok = [tok stringByReplacingOccurrencesOfString: @"\"" withString: @""];
              NSArray *sub = [tok componentsSeparatedByCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
              [words addObjectsFromArray: sub];
            }
        }
      [words removeObject: @""];

      NSString *kw = [words count] > 0 ? [[words objectAtIndex: 0] lowercaseString] : nil;
      if (kw == nil)
        {
          if (err) *err = [NSString stringWithFormat: @"%@:%lu: empty command",
            name, (unsigned long)lineNo];
          return nil;
        }
      [words removeObjectAtIndex: 0];

      /* The array the current command lands in: the innermost open block's
       * body, or the top level of the program. */
      NSMutableArray *target = prog.commands;
      DDSBlockCtx *top = [blockStack_ lastObject];
      if (top) target = top.target;

      /* Block keywords manage the parser stack and produce no command. */
      if ([kw isEqualToString: @"end"])
        {
          if ([blockStack_ count] == 0)
            {
              if (err) *err = [NSString stringWithFormat: @"%@:%lu: end without a matching block",
                name, (unsigned long)lineNo];
              return nil;
            }
          if ([words count] > 0)
            {
              NSString *closing = [[words objectAtIndex: 0] lowercaseString];
              NSString *openType = [top.type lowercaseString];
              if (![closing isEqualToString: openType])
                {
                  if (err) *err = [NSString stringWithFormat:
                    @"%@:%lu: 'end %@' does not close '%@' block",
                    name, (unsigned long)lineNo, closing, top.type];
                  return nil;
                }
            }
          [blockStack_ removeLastObject];
          continue;
        }
      else if ([kw isEqualToString: @"else"])
        {
          if (![top.type isEqualToString: @"if"] || top.elseSeen)
            {
              if (err) *err = [NSString stringWithFormat: @"%@:%lu: else outside an if block",
                name, (unsigned long)lineNo];
              return nil;
            }
          if ([words count] > 0)
            {
              if (err) *err = [NSString stringWithFormat:
                @"%@:%lu: unexpected tokens after else", name, (unsigned long)lineNo];
              return nil;
            }
          top.target = top.elseTarget;
          top.elseSeen = YES;
          continue;
        }

      UITestCommand *cmd = nil;
      if ([kw isEqualToString: @"activate"])
        {
          /* activate application "X" (DriveUI app) or activate xwindow "Title"
           * (any X window, e.g. a non-GNUstep app). */
          if ([words count] > 0 &&
              [[words objectAtIndex: 0] isEqualToString: @"xwindow"])
            {
              cmd = [[[UITestCommand alloc] initWithType: DDSCmdActivateXWindow
                line: lineNo col: 1] autorelease];
              cmd.string = str1;
            }
          else
            {
              cmd = [[[UITestCommand alloc] initWithType: DDSCmdActivate
                line: lineNo col: 1] autorelease];
              cmd.string = str1;
            }
        }
      else if ([kw isEqualToString: @"launch"])
        {
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdLaunchApp
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"focus"])
        {
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdFocusWindow
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"close"])
        {
          /* close window "Title" - close a visible window by title, regardless
           * of which window currently holds key focus. */
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdCloseWindow
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"invoke"])
        {
          /* invoke button "OK" / invoke default button - invoke a button of
           * the current modal dialog by title, or its default (Return)
           * button.  Explicit alternative to dismiss dialog. */
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdInvokeButton
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"select"])
        {
          /* select menu "Top/Sub" - in-app menu; or "select global menu" -
           * Menu.app's global menu bar (simulates clicking its items). */
          if ([words count] > 0 &&
              [[words objectAtIndex: 0] isEqualToString: @"global"])
            {
              cmd = [[[UITestCommand alloc] initWithType: DDSCmdSelectGlobalMenu
                line: lineNo col: 1] autorelease];
              cmd.string = str1;
            }
          else
            {
              cmd = [[[UITestCommand alloc] initWithType: DDSCmdSelectMenu
                line: lineNo col: 1] autorelease];
              cmd.string = str1;
            }
        }
      else if ([kw isEqualToString: @"click"])
        {
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdClick
            line: lineNo col: 1] autorelease];
          cmd.role = ([words count] > 0) ? UITestRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
          if ([words count] > 0) [words removeObjectAtIndex: 0];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"doubleclick"])
        {
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdDoubleClick
            line: lineNo col: 1] autorelease];
          cmd.role = ([words count] > 0) ? UITestRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
          if ([words count] > 0) [words removeObjectAtIndex: 0];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"context"])
        {
          /* context menu "AppName" "Item Title" - dispatch the named item of
           * the widget's context menu in-process. */
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdContextMenu
            line: lineNo col: 1] autorelease];
          if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"menu"])
            {
              if ([words count] > 1) cmd.role = UITestRoleFromName([words objectAtIndex: 1]);
            }
          else if ([words count] > 0)
            cmd.role = UITestRoleFromName([words objectAtIndex: 0]);
          cmd.string = str1;
          cmd.string2 = str2;
        }
      else if ([kw isEqualToString: @"rightclick"])
        {
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdRightClick
            line: lineNo col: 1] autorelease];
          cmd.role = ([words count] > 0) ? UITestRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
          if ([words count] > 0) [words removeObjectAtIndex: 0];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"type"])
        {
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdType
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"clear"])
        {
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdClear
            line: lineNo col: 1] autorelease];
          cmd.role = ([words count] > 0) ? UITestRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
          if ([words count] > 0) [words removeObjectAtIndex: 0];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"press"])
        {
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdPress
            line: lineNo col: 1] autorelease];
          cmd.string = ([words count] > 0) ? [words objectAtIndex: 0] : str1;
        }
      else if ([kw isEqualToString: @"run"])
        {
          /* run "command" - launch a command/app through the target app's
           * Run... dialog (opens it, types the command, presses Return). */
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdRun
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"wait"])
        {
          if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"until"])
            {
              cmd = [[[UITestCommand alloc] initWithType: DDSCmdWaitUntil
                line: lineNo col: 1] autorelease];
              [words removeObjectAtIndex: 0];
              if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"not"])
                {
                  cmd.assertKind = DDSAssertNotExists;
                  [words removeObjectAtIndex: 0];
                }
              if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"exists"])
                [words removeObjectAtIndex: 0];
              cmd.role = ([words count] > 0) ? UITestRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
              if ([words count] > 0) [words removeObjectAtIndex: 0];
              cmd.string = str1;
              /* wait until menu bar "Title" [not] */
              if ([words count] >= 1 && [[words objectAtIndex: 0] isEqualToString: @"bar"])
                {
                  cmd.assertKind = (cmd.assertKind == DDSAssertNotExists)
                    ? DDSAssertMenuBarNot : DDSAssertMenuBar;
                  [words removeObjectAtIndex: 0];
                }
              /* wait until xwindow "Title" count <op> <N> */
              else if ([words count] >= 3 && [[words objectAtIndex: 0] isEqualToString: @"count"])
                {
                  cmd.assertKind = DDSAssertXWindowCount;
                  [cmd.words addObject: [words objectAtIndex: 1]];
                  [cmd.words addObject: [words objectAtIndex: 2]];
                }
              /* optional trailing timeout 30s / 100ms */
              if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"timeout"])
                {
                  if ([words count] > 1)
                    [cmd.words addObject: [words objectAtIndex: 1]];
                }
            }
          else
            {
              cmd = [[[UITestCommand alloc] initWithType: DDSCmdWait
                line: lineNo col: 1] autorelease];
              cmd.string = ([words count] > 0) ? [words objectAtIndex: 0] : nil;
            }
        }
      else if ([kw isEqualToString: @"assert"])
        {
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdAssert
            line: lineNo col: 1] autorelease];
          if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"not"])
            {
              cmd.assertKind = DDSAssertNotExists;
              [words removeObjectAtIndex: 0];
            }
          if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"exists"])
            [words removeObjectAtIndex: 0];
          /* assert text contains "..." */
          if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"text"])
            {
              [words removeObjectAtIndex: 0];
              if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"contains"])
                {
                  cmd.assertKind = DDSAssertContains;
                  [words removeObjectAtIndex: 0];
                  cmd.string = str1;
                }
            }
          else
            {
              /* assert menu bar "Title" - asserts a top-level item of Menu.app's
               * global menu bar (what the frontmost app's menu looks like). */
              if ([words count] >= 2 &&
                  [[words objectAtIndex: 0] isEqualToString: @"menu"] &&
                  [[words objectAtIndex: 1] isEqualToString: @"bar"])
                {
                  [words removeObjectsInRange: NSMakeRange(0, 2)];
                  cmd.string = str1;
                  cmd.assertKind = (cmd.assertKind == DDSAssertNotExists)
                    ? DDSAssertMenuBarNot : DDSAssertMenuBar;
                }
              /* assert menu item "Top/Sub" [exists|not exists|checked|not
               * checked|enabled|disabled|shortcut "Cmd+O"] - asserts a
               * property of a main-menu item addressed by title path. */
              else if ([words count] >= 2 &&
                  [[words objectAtIndex: 0] isEqualToString: @"menu"] &&
                  [[words objectAtIndex: 1] isEqualToString: @"item"])
                {
                  [words removeObjectsInRange: NSMakeRange(0, 2)];
                  cmd.string = str1;
                  cmd.assertKind = (cmd.assertKind == DDSAssertNotExists)
                    ? DDSAssertMenuNotExists : DDSAssertMenuExists;
                  if ([words count] > 0)
                    {
                      NSString *prop = [[words objectAtIndex: 0] lowercaseString];
                      if ([prop isEqualToString: @"checked"])
                        cmd.assertKind = DDSAssertMenuChecked;
                      else if ([prop isEqualToString: @"not"] && [words count] > 1 &&
                               [[[words objectAtIndex: 1] lowercaseString]
                                 isEqualToString: @"checked"])
                        cmd.assertKind = DDSAssertMenuNotChecked;
                      else if ([prop isEqualToString: @"enabled"])
                        cmd.assertKind = DDSAssertMenuEnabled;
                      else if ([prop isEqualToString: @"disabled"])
                        cmd.assertKind = DDSAssertMenuDisabled;
                      else if ([prop isEqualToString: @"shortcut"])
                        { cmd.assertKind = DDSAssertMenuShortcut; cmd.string2 = str2; }
                    }
                }
              else
                {
              cmd.role = ([words count] > 0) ? UITestRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
              if ([words count] > 0) [words removeObjectAtIndex: 0];
              cmd.string = str1;
              if ([words count] > 0)
                {
                  NSString *prop = [[words objectAtIndex: 0] lowercaseString];
                  if ([prop isEqualToString: @"enabled"]) cmd.assertKind = DDSAssertEnabled;
                  else if ([prop isEqualToString: @"checked"]) cmd.assertKind = DDSAssertChecked;
                  else if ([prop isEqualToString: @"docked"])
                    cmd.assertKind = DDSAssertDocked;
                  else if ([prop isEqualToString: @"not"] && [words count] > 1 &&
                           [[[words objectAtIndex: 1] lowercaseString]
                             isEqualToString: @"docked"])
                    cmd.assertKind = DDSAssertNotDocked;
                  else if ([prop isEqualToString: @"frame"] &&
                           [words count] > 1 &&
                           [[[words objectAtIndex: 1] lowercaseString]
                             isEqualToString: @"constant"])
                    cmd.assertKind = DDSAssertFrameConstant;
                  else if ([prop isEqualToString: @"count"] && [words count] >= 3)
                    {
                      /* assert xwindow "Title" count <op> <N> - compare the
                       * number of X windows whose name contains "Title"
                       * against N.  op is one of =, >, >=, <, <=, !=. */
                      cmd.assertKind = DDSAssertXWindowCount;
                      [cmd.words addObject: [words objectAtIndex: 1]];
                      [cmd.words addObject: [words objectAtIndex: 2]];
                    }
                }
                }
            }
        }
      else if ([kw isEqualToString: @"capture"])
        {
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdCapture
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"log"])
        {
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdLog
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"on_error"])
        {
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdOptions
            line: lineNo col: 1] autorelease];
          [cmd.words addObjectsFromArray: words];
        }
      else if ([kw isEqualToString: @"hover"])
        {
          /* hover [role] "title" - move the pointer over the widget. */
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdHover
            line: lineNo col: 1] autorelease];
          cmd.role = ([words count] > 0) ? UITestRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
          if ([words count] > 0) [words removeObjectAtIndex: 0];
          cmd.string = str1;
        }
      else if ([kw isEqualToString: @"scroll"])
        {
          /* scroll [role] "title" <up|down|left|right> [amount]
           * or: scroll <up|down|left|right> [amount]  (scroll at the pointer) */
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdScroll
            line: lineNo col: 1] autorelease];
          if ([words count] > 0)
            {
              NSString *first = [[words objectAtIndex: 0] lowercaseString];
              if ([first isEqualToString: @"up"] || [first isEqualToString: @"down"]
                  || [first isEqualToString: @"left"] || [first isEqualToString: @"right"])
                {
                  /* no target widget: scroll at the current pointer position */
                  cmd.role = DDSRoleAny;
                  [cmd.words addObject: first];
                  [words removeObjectAtIndex: 0];
                  if ([words count] > 0) [cmd.words addObject: [words objectAtIndex: 0]];
                }
              else
                {
                  cmd.role = UITestRoleFromName(first);
                  if (cmd.role != DDSRoleAny) [words removeObjectAtIndex: 0];
                  cmd.string = str1;
                  if ([words count] > 0) [cmd.words addObject: [[words objectAtIndex: 0] lowercaseString]];
                  if ([words count] > 1) [cmd.words addObject: [words objectAtIndex: 1]];
                }
            }
        }
      else if ([kw isEqualToString: @"drag"])
        {
          /* drag [role] "title" [by] <dx> <dy> - press at the widget and drag
           * it by the given pixel offset. */
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdDrag
            line: lineNo col: 1] autorelease];
          cmd.role = ([words count] > 0) ? UITestRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
          if ([words count] > 0 && cmd.role != DDSRoleAny)
            [words removeObjectAtIndex: 0];
          cmd.string = str1;
          if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"by"])
            [words removeObjectAtIndex: 0];
          if ([words count] > 0) [cmd.words addObject: [words objectAtIndex: 0]];
          if ([words count] > 1) [cmd.words addObject: [words objectAtIndex: 1]];
        }
      else if ([kw isEqualToString: @"repeat"])
        {
          if ([words count] == 0)
            {
              if (err) *err = [NSString stringWithFormat: @"%@:%lu: repeat needs a count",
                name, (unsigned long)lineNo];
              return nil;
            }
          int count = [[words objectAtIndex: 0] intValue];
          if (count <= 0)
            {
              if (err) *err = [NSString stringWithFormat: @"%@:%lu: repeat count must be positive",
                name, (unsigned long)lineNo];
              return nil;
            }
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdRepeat
            line: lineNo col: 1] autorelease];
          [cmd.words addObject: [words objectAtIndex: 0]];
          [blockStack_ addObject: [[[DDSBlockCtx alloc] initWithType: @"repeat"
            target: cmd.body elseTarget: nil] autorelease]];
        }
      else if ([kw isEqualToString: @"if"])
        {
          /* if [not] [exists] [role] "title" [docked|not docked]
           *    menu item "Top/Sub" checked|not checked|enabled|disabled|shortcut "X" */
          BOOL isMenuItem = NO;
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdIf
            line: lineNo col: 1] autorelease];
          if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"not"])
            {
              cmd.assertKind = DDSAssertNotExists;
              [words removeObjectAtIndex: 0];
            }
          if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"exists"])
            [words removeObjectAtIndex: 0];
          if ([words count] >= 2 &&
              [[words objectAtIndex: 0] isEqualToString: @"menu"] &&
              [[words objectAtIndex: 1] isEqualToString: @"item"])
            {
              isMenuItem = YES;
              [words removeObjectsInRange: NSMakeRange(0, 2)];
              cmd.string = str1;
              cmd.assertKind = (cmd.assertKind == DDSAssertNotExists)
                ? DDSAssertMenuNotExists : DDSAssertMenuExists;
              if ([words count] > 0)
                {
                  NSString *prop = [[words objectAtIndex: 0] lowercaseString];
                  if ([prop isEqualToString: @"checked"])
                    cmd.assertKind = DDSAssertMenuChecked;
                  else if ([prop isEqualToString: @"not"] && [words count] > 1 &&
                           [[[words objectAtIndex: 1] lowercaseString]
                             isEqualToString: @"checked"])
                    cmd.assertKind = DDSAssertMenuNotChecked;
                  else if ([prop isEqualToString: @"enabled"])
                    cmd.assertKind = DDSAssertMenuEnabled;
                  else if ([prop isEqualToString: @"disabled"])
                    cmd.assertKind = DDSAssertMenuDisabled;
                  else if ([prop isEqualToString: @"shortcut"])
                    { cmd.assertKind = DDSAssertMenuShortcut; cmd.string2 = str2; }
                }
            }
          if (!isMenuItem)
            {
              cmd.role = ([words count] > 0) ? UITestRoleFromName([words objectAtIndex: 0]) : DDSRoleAny;
              if ([words count] > 0) [words removeObjectAtIndex: 0];
              cmd.string = str1;
              /* optional docked-state condition */
              if ([words count] > 0 && [[words objectAtIndex: 0] isEqualToString: @"docked"])
                cmd.assertKind = DDSAssertDocked;
              else if ([words count] > 1 &&
                       [[words objectAtIndex: 0] isEqualToString: @"not"] &&
                       [[words objectAtIndex: 1] isEqualToString: @"docked"])
                cmd.assertKind = DDSAssertNotDocked;
            }
          [blockStack_ addObject: [[[DDSBlockCtx alloc] initWithType: @"if"
            target: cmd.body elseTarget: cmd.elseBody] autorelease]];
        }
      else if ([kw isEqualToString: @"macro"])
        {
          /* macro NAME ... end - define a named, reusable block. */
          NSString *macroName = ([words count] > 0) ? [words objectAtIndex: 0] : str1;
          if ([macroName length] == 0)
            {
              if (err) *err = [NSString stringWithFormat: @"%@:%lu: macro needs a name",
                name, (unsigned long)lineNo];
              return nil;
            }
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdMacro
            line: lineNo col: 1] autorelease];
          cmd.string = macroName;
          [blockStack_ addObject: [[[DDSBlockCtx alloc] initWithType: @"macro"
            target: cmd.body elseTarget: nil] autorelease]];
        }
      else if ([kw isEqualToString: @"call"])
        {
          NSString *macroName = ([words count] > 0) ? [words objectAtIndex: 0] : str1;
          if ([macroName length] == 0)
            {
              if (err) *err = [NSString stringWithFormat: @"%@:%lu: call needs a macro name",
                name, (unsigned long)lineNo];
              return nil;
            }
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdCall
            line: lineNo col: 1] autorelease];
          cmd.string = macroName;
        }
      else if ([kw isEqualToString: @"record"])
        {
          cmd = [[[UITestCommand alloc] initWithType: DDSCmdRecord
            line: lineNo col: 1] autorelease];
          cmd.string = str1;
        }
      else
        {
          if (err) *err = [NSString stringWithFormat: @"%@:%lu: unknown command '%@'",
            name, (unsigned long)lineNo, kw];
          return nil;
        }

      [target addObject: cmd];
    }

  if ([blockStack_ count] > 0)
    {
      DDSBlockCtx *open = [blockStack_ lastObject];
      if (err) *err = [NSString stringWithFormat: @"%@:%d: unterminated '%@' block (missing end)",
        name, 0, open.type];
      return nil;
    }
  return prog;
}

@end