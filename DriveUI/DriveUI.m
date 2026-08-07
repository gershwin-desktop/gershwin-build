/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* DriveUI - a tiny, DO-free UI snapshot server bundled into every GNUstep app.
 *
 * The socket server exposes ONLY read-only UI information (the widget tree and
 * widget text values) as fast tab-separated lines over a per-PID Unix-domain
 * socket - no DO, no JSON.  Driving (clicks, key presses, typing) is NOT done
 * here: it is simulated at the X11 level by the drive_ui command-line tool,
 * which resolves the widget's on-screen position from this snapshot and sends
 * real pointer/key events.  This keeps the host app side purely observational,
 * so nothing in it can wedge a modal loop or mis-trigger a GNUstep action.
 *
 * Loading: GNUstep GUI reads the GSAppKitUserBundles user default at NSApp
 * init and instantiates the principal class of each listed bundle.  Pointing
 * that default at this bundle makes every GUI app host a DriveUI server
 * without any per-app code.  The socket lives at
 * /tmp/driveui.<pid>.sock so drive_ui can target one app.
 *
 * Protocol: the client connects and sends one command line (fields separated
 * by tabs):
 *
 *   full                      -> whole tree, one line per item
 *   get <object_id>           -> the text/title/string of one widget
 *   app                       -> the app's process name (for run_uitest's
 *                                `activate application "Name"` resolution)
 *   props <object_id>         -> enabled=1|0 state=0|1 for one widget
 *   menu                      -> main menu tree: depth\tindex\ttitle\tenabled\thas_submenu
 *   menu_invoke <i> <j> ...   -> perform the menu item's action at that index path
 *
 * Snapshot fields (tab-separated): depth, class, text, tag, frame,
 * screen_frame, hidden, object_id.  `text` is the displayed (localized)
 * title/stringValue, so drive_ui can find widgets by their on-screen label and
 * then act on the id via X11 at the reported screen_frame.
 *
 * Robustness: the socket server runs on a dedicated background thread that
 * NEVER blocks on the main thread.  Each connection is packaged into a small
 * object and posted to the main thread (waitUntilDone:NO); the main thread
 * writes the reply and closes the connection itself.  Reads have a timeout,
 * every main-thread handler is wrapped in @try/@catch so a bad request can
 * never leave the app's main thread wedged, and SIGPIPE is ignored so writing
 * to a vanished client cannot kill the app.  A wedged, hanging, or crashing
 * client therefore never hangs or crashes the host application, and one slow
 * connection cannot stall the server thread (it keeps accepting new ones).
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/poll.h>
#import <signal.h>
#import <unistd.h>

#define DRIVEUI_READ_TIMEOUT_MS 5000

/* One pending client connection.  Posted to the main thread for servicing;
 * the main thread writes the reply and closes the fd. */
@interface DriveUIConnection : NSObject
{
  int _fd;
  NSArray *_args;
}
- (id)initWithFD:(int)fd args:(NSArray *)args;
- (int)fd;
- (NSArray *)args;
@end

@implementation DriveUIConnection

- (id)initWithFD:(int)fd args:(NSArray *)args
{
  self = [super init];
  if (self)
    {
      _fd = fd;
      _args = [args copy];
    }
  return self;
}

- (void)dealloc
{
  [_args release];
  [super dealloc];
}

- (int)fd { return _fd; }
- (NSArray *)args { return _args; }

@end

@interface DriveUI : NSObject
{
  NSArray *_snapshot;
}
- (void)serverLoop:(id)unused;
- (void)serviceConnection:(DriveUIConnection *)conn;
- (void)buildSnapshot:(id)unused;
 - (NSString *)textOfObject:(NSString *)objID;
 - (NSArray *)collectSnapshot;
 - (void)appendMenuLinesForMenu:(NSMenu *)menu depth:(int)depth into:(NSMutableString *)out;
 - (BOOL)resolveMenuIndexes:(NSArray *)indexes menu:(NSMenu **)outMenu
                      index:(NSInteger *)outIndex error:(NSString **)err;
- (void)addWindow:(NSWindow *)win depth:(int)depth into:(NSMutableArray *)items;
- (void)addView:(NSView *)view depth:(int)depth into:(NSMutableArray *)items;
- (NSString *)objectIDForObject:(id)obj;
- (id)objectForID:(NSString *)objID;
- (NSString *)snapshotLines;
@end

@implementation DriveUI

- (id)init
{
  self = [super init];
  if (self)
    {
      /* Writing to a socket whose client has gone away must not raise
       * SIGPIPE and kill the app. */
      signal(SIGPIPE, SIG_IGN);
      [NSThread detachNewThreadSelector: @selector(serverLoop:)
                               toTarget: self
                             withObject: nil];
    }
  return self;
}

- (void)dealloc
{
  [_snapshot release];
  [super dealloc];
}

/* ---- socket helpers ---- */

static void WriteAll(int fd, const char *bytes)
{
  size_t len = strlen(bytes);
  size_t off = 0;
  while (off < len)
    {
      ssize_t w = write(fd, bytes + off, len - off);
      if (w <= 0) break;
      off += (size_t)w;
    }
}

/* ---- socket server (background thread) ---- */

- (void)serverLoop:(id)unused
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  pid_t pid = [[NSProcessInfo processInfo] processIdentifier];
  NSString *sockPath = [NSString stringWithFormat: @"/tmp/driveui.%d.sock", pid];

  unlink([sockPath UTF8String]);

  int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (lfd < 0)
    {
      [pool release];
      return;
    }

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, [sockPath UTF8String], sizeof(addr.sun_path) - 1);

  if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0
      || listen(lfd, 8) < 0)
    {
      close(lfd);
      [pool release];
      return;
    }
  chmod([sockPath UTF8String], 0666);

  for (;;)
    {
      NSAutoreleasePool *cpool = [[NSAutoreleasePool alloc] init];

      int cfd = accept(lfd, NULL, NULL);
      if (cfd < 0)
        {
          [cpool release];
          continue;
        }

      /* Wait for the command line with a timeout, so a client that connects
       * and sends nothing cannot block this thread forever. */
      struct pollfd pfd;
      pfd.fd = cfd;
      pfd.events = POLLIN;
      int pr = poll(&pfd, 1, DRIVEUI_READ_TIMEOUT_MS);

      if (pr > 0)
        {
          char buf[16384];
          ssize_t n = read(cfd, buf, sizeof(buf) - 1);
          if (n > 0)
            {
              buf[n] = 0;
              NSString *line = [NSString stringWithUTF8String: buf];
              NSArray *lines = [line componentsSeparatedByString: @"\n"];
              NSString *cmdline = [lines count] > 0 ? [lines objectAtIndex: 0] : @"";
              NSArray *args = [cmdline componentsSeparatedByString: @"\t"];

              /* Package the connection and ask the main thread to service it.
               * waitUntilDone:NO means the server thread never blocks: the
               * main thread owns the fd from here on, writes the reply, and
               * closes it.  If the main thread is momentarily busy, the
               * client just waits - the server thread keeps accepting.
               *
               * Post in the modal + event-tracking modes as well as the
               * default one: a modal dialog (e.g. Go To Folder) runs the main
               * run loop in NSModalPanelRunLoopMode, and the default
               * performSelectorOnMainThread: only covers NSDefaultRunLoopMode
               * + NSConnectionReplyMode, so the connection would never be
               * serviced while a modal is up. */
               DriveUIConnection *conn =
                 [[[DriveUIConnection alloc] initWithFD: cfd args: args] autorelease];
               [self performSelectorOnMainThread: @selector(serviceConnection:)
                                      withObject: conn
                                   waitUntilDone: NO
                                           modes: [NSArray arrayWithObjects:
                                                    NSDefaultRunLoopMode,
                                                    NSModalPanelRunLoopMode,
                                                    NSEventTrackingRunLoopMode,
                                                    nil]];
               [cpool release];
               continue;  /* main thread owns cfd from here on */
            }
        }

      close(cfd);
      [cpool release];
    }

  close(lfd);
  [pool release];
}

/* ---- connection servicing (main thread) ---- */

- (void)serviceConnection:(DriveUIConnection *)conn
{
  NSAutoreleasePool *cpool = [[NSAutoreleasePool alloc] init];

  int fd = [conn fd];
  NSArray *parts = [conn args];

  if (fd >= 0)
    {
      @try
        {
          NSString *cmd = ([parts count] > 0) ? [parts objectAtIndex: 0] : @"";

          if ([cmd isEqualToString: @"full"])
            {
              [self buildSnapshot: nil];
              NSString *lines = [self snapshotLines];
              if (lines) WriteAll(fd, [lines UTF8String]);
            }
          else if ([cmd isEqualToString: @"get"])
            {
              NSString *objID = ([parts count] > 1) ? [parts objectAtIndex: 1] : nil;
              NSString *text = [self textOfObject: objID];
              if (text == nil) text = @"error:no object";
              NSString *reply = [text stringByAppendingString: @"\n"];
              WriteAll(fd, [reply UTF8String]);
            }
          else if ([cmd isEqualToString: @"app"])
            {
              /* Read-only app identity, for run_uitest to resolve "activate
               * application <name>" to the matching DriveUI socket/PID. */
              NSString *name = [[NSProcessInfo processInfo] processName];
              if ([name length] == 0) name = @"unknown";
              NSString *reply = [name stringByAppendingString: @"\n"];
              WriteAll(fd, [reply UTF8String]);
            }
          else if ([cmd isEqualToString: @"windows"])
            {
              /* Read-only: the titles of all VISIBLE windows, one per line.
               * Much cheaper than the full tree: window existence checks
               * (wait until/assert window) do not need to walk every widget. */
              NSMutableString *reply = [NSMutableString string];
              NSArray *wins = [[NSApp windows] copy];
              for (NSWindow *win in wins)
                {
                  @try
                    {
                      if ([win isVisible])
                        {
                          NSString *t = [win title] ?: @"";
                          [reply appendFormat: @"%@\n", t];
                        }
                    }
                  @catch (NSException *e) { }
                }
              [wins release];
              WriteAll(fd, [reply UTF8String]);
            }
          else if ([cmd isEqualToString: @"menubar"])
            {
              /* Read-only: the top-level items of a menu bar (an NSMenuView
               * that is a descendant of a visible window), one per line:
               *   title<TAB>screen-center-x<TAB>screen-center-y
               * Lets scripts click the real menu bar items (e.g. Menu.app's
               * global menu) with X11 events.  Screen coords are top-down
               * (the bundle converts from GNUstep bottom-up). */
              NSMutableString *reply = [[NSMutableString alloc] initWithCapacity: 512];
              CGFloat sh = [[NSScreen mainScreen] frame].size.height;
              NSArray *wins = [[NSApp windows] copy];
              for (NSWindow *win in wins)
                {
                  if (![win isVisible]) continue;
                  [self appendMenuBarItemsForView: [win contentView]
                                           screenHeight: sh
                                              into: reply];
                }
              [wins release];
              WriteAll(fd, [reply UTF8String]);
              [reply release];
            }
          else if ([cmd isEqualToString: @"menu_tree"])
            {
              /* Debug: dump the titles of every menu bar NSMenuView's menu. */
              NSMutableString *reply = [[NSMutableString alloc] initWithCapacity: 512];
              NSArray *wins = [[NSApp windows] copy];
              for (NSWindow *win in wins)
                {
                  if (![win isVisible]) continue;
                  NSMutableArray *mvs = [NSMutableArray array];
                  [self collectMenuViews: [win contentView] into: mvs];
                  for (NSMenuView *mv in mvs)
                    {
                      [reply appendString: @"=== menu ===\n"];
                      [self appendMenuTree: [mv menu] depth: 0 into: reply];
                    }
                }
              [wins release];
              WriteAll(fd, [reply UTF8String]);
              [reply release];
            }
          else if ([cmd isEqualToString: @"menu_trigger"])
            {
              /* menu_trigger <Top/Sub/...> - simulate a click on a menu bar
               * item by dispatching its action in-process (the same path a
               * real selection uses).  Walks the menu of every menu-bar
               * NSMenuView.  Reply "ok" or "error:...". */
              NSString *path = ([parts count] > 1) ? [parts objectAtIndex: 1] : nil;
              if (path == nil || [path length] == 0)
                {
                  WriteAll(fd, "error:menu_trigger needs a title path\n");
                }
              else
                {
                  NSArray *segs = [path componentsSeparatedByString: @"/"];
                  NSMutableArray *menuViews = [NSMutableArray array];
                  NSArray *wins = [[NSApp windows] copy];
                  for (NSWindow *win in wins)
                    {
                      if (![win isVisible]) continue;
                      [self collectMenuViews: [win contentView] into: menuViews];
                    }
                  [wins release];
                  BOOL done = NO;
                  for (NSMenuView *mv in menuViews)
                    {
                      if ([self triggerMenuPath: segs inMenu: [mv menu]])
                        { done = YES; break; }
                    }
                  WriteAll(fd, done ? "ok\n" : "error:menu path not found\n");
                }
            }
          else if ([cmd isEqualToString: @"context_menu"])
            {
              /* context_menu <object_id> <Item Title> - build the context menu
               * of the given widget (menuForEvent:) and dispatch the action of
               * the item whose title matches, in-process (the same path a real
               * right-click then selection uses).  Needed because popup-menu
               * items are drawn by an NSMenuView and do not appear as views in
               * the widget tree, so they cannot be clicked by position.  Reply
               * "ok" or "error:...". */
              NSString *objID = ([parts count] > 1) ? [parts objectAtIndex: 1] : nil;
              NSString *want = ([parts count] > 2) ? [parts objectAtIndex: 2] : nil;
              if (objID == nil || want == nil || [want length] == 0)
                {
                  WriteAll(fd, "error:context_menu needs <object_id> <title>\n");
                }
              else
                {
                  id obj = [self objectForID: objID];
                  BOOL done = NO;
                  if (obj != nil && [obj respondsToSelector: @selector(menuForEvent:)])
                    {
                      @try
                        {
                          NSMenu *menu = [obj menuForEvent: nil];
                          if (menu != nil)
                            done = [self triggerMenuPath:
                              [NSArray arrayWithObject: want] inMenu: menu];
                        }
                      @catch (NSException *e) { }
                    }
                  WriteAll(fd, done ? "ok\n" : "error:context menu item not found\n");
                }
            }
          else if ([cmd isEqualToString: @"modal"])
            {
              /* Report the app's current modal window, if any.  This lets
               * scripts detect dialogs/alerts that block interaction and
               * dismiss them before continuing.  Reply is
               * "none" or "<Class>|<title>". */
              NSString *reply = @"none\n";
              NSWindow *mw = [NSApp modalWindow];
              if (mw != nil)
                {
                  NSString *title = [mw title] ?: @"";
                  reply = [NSString stringWithFormat: @"%@|%@\n",
                    NSStringFromClass ([mw class]), title];
                }
              WriteAll(fd, [reply UTF8String]);
            }
          else if ([cmd isEqualToString: @"dismiss_modal"])
            {
              /* Convenience: dismiss the current modal alert by invoking its
               * default button (the user-facing command is
               * `invoke_modal_button default`). */
              NSString *reply = [self invokeModalButton: @"default"];
              WriteAll(fd, [reply UTF8String]);
            }
          else if ([cmd isEqualToString: @"invoke_modal_button"])
            {
              /* Invoke a button of the current modal window in-process, by its
               * displayed title or "default" for the Return-equivalent button.
               * Modal alerts (NSRunAlertPanel / NSAlert) block until a button
               * is clicked; performClick drives the button's real action
               * (which for an alert calls [NSApp stopModalWithCode:] and ends
               * the session), and is immune to the coordinate drift that makes
               * outside clicks unreliable.  Reply "ok" or "error:<reason>". */
              NSString *which = ([parts count] > 1) ? [parts objectAtIndex: 1] : @"default";
              NSString *reply = [self invokeModalButton: which];
              WriteAll(fd, [reply UTF8String]);
            }
          else if ([cmd isEqualToString: @"props"])
            {
              /* Read-only control properties for run_uitest assertions
               * (enabled/checked): enabled=1|0  state=0|1 (NSOffState/NSOnState). */
              NSString *objID = ([parts count] > 1) ? [parts objectAtIndex: 1] : nil;
              id obj = [self objectForID: objID];
              int enabled = 1, state = 0;
              if (obj != nil)
                {
                  @try {
                    if ([obj isKindOfClass: [NSControl class]])
                      {
                        enabled = [(NSControl *)obj isEnabled] ? 1 : 0;
                        /* state is on NSButton/NSMenuButton, not NSControl;
                         * read via KVC so we need no per-class import. */
                        @try {
                          NSNumber *st = [(NSControl *)obj valueForKey: @"state"];
                          if (st) state = ([st intValue] == NSOnState) ? 1 : 0;
                        } @catch (NSException *e) { }
                      }
                    else if ([obj isKindOfClass: [NSWindow class]])
                      {
                        enabled = [(NSWindow *)obj isVisible] ? 1 : 0;
                      }
                    else if ([obj isKindOfClass: [NSView class]])
                      {
                        enabled = [(NSView *)obj isHidden] ? 0 : 1;
                      }
                    /* Icon views (DockIcon in the Workspace Dock) expose their
                     * docked state via -isDocked; surface it for assertions. */
                    if ([obj respondsToSelector: @selector(isDocked)])
                      {
                        @try {
                          id d = [obj valueForKey: @"docked"];
                          state = [d boolValue] ? 1 : 0;
                        } @catch (NSException *e) { }
                      }
                  } @catch (NSException *e) { }
                }
              NSString *reply = [NSString stringWithFormat: @"enabled=%d state=%d\n",
                enabled, state];
              WriteAll(fd, [reply UTF8String]);
            }
          else if ([cmd isEqualToString: @"menu"])
            {
              /* Read-only: serialize the app's main menu as one line per item:
               * depth\tindex\ttitle\tenabled\thas_submenu\tstate\tkey_equiv\
               * modifier_mask\tshortcut, recursing into each submenu (a
               * submenu's items follow their parent at depth+1).  The top-level
               * bar is driven by the app's own [NSApp mainMenu], so menu titles
               * are the real (localized) item titles.  `state` is the checkmark
               * (NSOnState=1); `shortcut` is the readable "Cmd+Shift+T" form. */
              NSMutableString *out = [NSMutableString string];
              [self appendMenuLinesForMenu: [NSApp mainMenu] depth: 0 into: out];
              if ([out length] == 0) [out appendString: @"(no menu)\n"];
              WriteAll(fd, [out UTF8String]);
            }
          else if ([cmd isEqualToString: @"menu_invoke"])
            {
              /* menu_invoke <i0> <i1> ... - perform the leaf menu item's
               * action in-process (the equivalent of a real selection), by
               * index path: each index selects an item in the current menu;
               * intermediate items must have a submenu which becomes the next
               * menu.  Replies "ok" on success. */
              NSMutableArray *indexes = [NSMutableArray array];
              for (NSUInteger i = 1; i < [parts count]; i++)
                {
                  NSNumber *idx = @([[parts objectAtIndex: i] intValue]);
                  [indexes addObject: idx];
                }
              if ([indexes count] == 0)
                {
                  WriteAll(fd, "error:menu_invoke needs at least one index\n");
                }
              else
                {
                  /* Resolve the item first; only reply "ok" once the path is
                   * known valid.  The action itself is then fired after the
                   * reply is flushed: a leaf action that opens a modal dialog
                   * (e.g. Go To Folder) would otherwise block the main thread
                   * until the dialog closes, making the client time out after
                   * its 10s read.  With the reply already out, the client can
                   * keep driving the dialog while it is up. */
                  NSMenu *menu = nil;
                  NSInteger idx = 0;
                  NSString *menuErr = nil;
                  if ([self resolveMenuIndexes: indexes menu: &menu
                                         index: &idx error: &menuErr])
                    {
                      /* Write the reply and close the connection before firing
                       * the action: a leaf action that opens a modal dialog
                       * (e.g. Go To Folder) blocks the main thread until the
                       * dialog closes, so holding the fd open would make the
                       * client wait for EOF past its read timeout.  The action
                       * then runs on the main thread as usual; other commands
                       * are still serviced because serviceConnection: is posted
                       * in the modal run loop mode too.  The @finally below
                       * re-closes the (already closed) fd, which is harmless. */
                      WriteAll(fd, "ok\n");
                      close(fd);
                      @try
                        {
                          [menu performActionForItemAtIndex: idx];
                        }
                      @catch (NSException *e)
                        {
                          /* The selection fired; a failure inside the action
                           * (e.g. in its modal loop) is the app's business. */
                        }
                    }
                  else
                    {
                      NSString *r = [NSString stringWithFormat: @"error:%@\n",
                        menuErr ?: @"invoke failed"];
                      WriteAll(fd, [r UTF8String]);
                    }
                }
            }
          else if ([cmd isEqualToString: @"close_window"])
            {
              /* Close a window by its (localized) title.  Performed in-process
               * via performClose:, so it works regardless of which window is
               * key - the Close menu item is disabled when the viewer window
               * was not made key, which a synthetic dialog flow cannot
               * guarantee.  Matching is a case-insensitive substring match
               * against the title, or against its English/localized twin. */
              NSString *needle = ([parts count] > 1) ? [parts objectAtIndex: 1] : nil;
              BOOL closed = NO;
              if ([needle length] > 0)
                {
                  NSArray *wins = [[NSApp windows] copy];
                  for (NSWindow *win in wins)
                    {
                      @try
                        {
                          NSString *t = [win title] ?: @"";
                          if (![win isVisible]) continue;
                          if ([t rangeOfString: needle
                            options: NSCaseInsensitiveSearch].location != NSNotFound)
                            {
                              [win performClose: self];
                              closed = YES;
                              break;
                            }
                          /* Accept the localized spelling of the needle. */
                          NSBundle *b = [NSBundle mainBundle];
                          NSString *loc = [b localizedStringForKey: needle
                            value: needle table: nil];
                          if (![loc isEqualToString: needle] &&
                              [t rangeOfString: loc
                                options: NSCaseInsensitiveSearch].location != NSNotFound)
                            {
                              [win performClose: self];
                              closed = YES;
                              break;
                            }
                        }
                      @catch (NSException *e) { }
                    }
                  [wins release];
                }
              NSString *reply = closed
                ? @"ok\n"
                : [NSString stringWithFormat:
                    @"error:no visible window matching '%@'\n", needle ?: @"(none)"];
              WriteAll(fd, [reply UTF8String]);
            }
          else if ([cmd isEqualToString: @"localize"])
            {
              /* Read-only: translate an English UI string to the app's current
               * language, so UITest scripts can be written in English and still
               * match a localized (e.g. German) UI.  The GNUstep `_(...)`
               * macro keys its .strings tables by the English string, so
               * localizedStringForKey: with the English key + English default
               * returns the live translated title. */
              NSString *key = ([parts count] > 1) ? [parts objectAtIndex: 1] : nil;
              NSString *result = key ?: @"";
              if ([key length] > 0)
                {
                  NSBundle *b = [NSBundle mainBundle];
                  NSString *localized = [b localizedStringForKey: key
                                                           value: key
                                                           table: nil];
                  if ([localized length] > 0) result = localized;
                }
              NSString *reply = [result stringByAppendingString: @"\n"];
              WriteAll(fd, [reply UTF8String]);
            }
          else
            {
              NSString *err = [NSString stringWithFormat: @"error:unknown command %@\n", cmd];
              WriteAll(fd, [err UTF8String]);
            }
        }
      @catch (NSException *e)
        {
          NSString *err = [NSString stringWithFormat: @"error:exception %@\n", e];
          WriteAll(fd, [err UTF8String]);
        }
      @finally
        {
          close(fd);
        }
    }

  [cpool release];
}

/* ---- text readout (main thread) ---- */

- (NSString *)textOfObject:(NSString *)objID
{
  id obj = [self objectForID: objID];
  if (obj == nil) return nil;

  @try {
    if ([obj isKindOfClass: [NSTextField class]]) {
      return [(NSTextField *)obj stringValue] ?: @"";
    }
    if ([obj isKindOfClass: [NSTextView class]]) {
      return [(NSTextView *)obj string] ?: @"";
    }
    if ([obj respondsToSelector: @selector(stringValue)]) {
      id s = [obj performSelector: @selector(stringValue)];
      if (s && [s isKindOfClass: [NSString class]]) return s;
    }
    if ([obj respondsToSelector: @selector(title)]) {
      id t = [obj performSelector: @selector(title)];
      if (t && [t isKindOfClass: [NSString class]]) return t;
    }
  } @catch (NSException *e) { }

  return @"";
}

/* ---- menu introspection (main thread) ---- */

/* Render an NSMenuItem's key equivalent (shortcut) as a readable ASCII
 * string, e.g. "Cmd+Shift+T" or "Ctrl+W".  GNUstep's Command key is the Alt
 * key on a Linux keyboard, but the mask bit is NSCommandKeyMask - the label
 * keeps the semantic modifier name so tests can assert on what the menu item
 * declares.  Special keys get readable names. */
static NSString *ShortcutForItem(NSMenuItem *item)
{
  if (item == nil) return @"";
  NSString *key = [item keyEquivalent] ?: @"";
  if ([key length] == 0) return @"";

  NSString *keyName = key;
  unichar c = [key characterAtIndex: 0];
  if ([key length] == 1)
    {
      if (c == '\r') keyName = @"Return";
      else if (c == '\n') keyName = @"Enter";
      else if (c == '\t') keyName = @"Tab";
      else if (c == ' ') keyName = @"Space";
      else if (c == 0x1b) keyName = @"Esc";
      else if (c == 0x7f) keyName = @"Delete";
      else if (c == 0x03) keyName = @"Enter";
      else if ([[NSCharacterSet lowercaseLetterCharacterSet] characterIsMember: c])
        keyName = [[key uppercaseString] copy];
    }

  NSMutableArray *mods = [NSMutableArray array];
  NSUInteger mask = [item keyEquivalentModifierMask];
  if (mask & NSCommandKeyMask) [mods addObject: @"Cmd"];
  if (mask & NSAlternateKeyMask) [mods addObject: @"Alt"];
  if (mask & NSControlKeyMask) [mods addObject: @"Ctrl"];
  if (mask & NSShiftKeyMask) [mods addObject: @"Shift"];

  if ([mods count] == 0) return keyName;
  [mods addObject: keyName];
  return [mods componentsJoinedByString: @"+"];
}

/* Recursively serialize a menu: one tab-separated line per item
 * (depth, index, title, enabled, has_submenu, state, key_equivalent,
 * modifier_mask, shortcut), submenu items following their parent.  `state`
 * is the checkmark: NSOnState=1, NSOffState=0, NSMixedState=2.
 * `key_equivalent` is the raw key string (e.g. "c", "t", "\r"); `shortcut`
 * is the readable "Cmd+Shift+T" form.  All accessors are @try-wrapped so a
 * foreign/wedged menu cannot crash the host. */
- (void)appendMenuLinesForMenu:(NSMenu *)menu depth:(int)depth
                         into:(NSMutableString *)out
{
  @try
    {
      NSInteger n = [menu numberOfItems];
      for (NSInteger i = 0; i < n; i++)
        {
          NSMenuItem *item = [menu itemAtIndex: i];
          NSString *title = item ? ([item title] ?: @"") : @"";
          BOOL enabled = [item isEnabled] ? YES : NO;
          BOOL hasSubmenu = [item submenu] != nil;
          NSInteger state = [item state];
          NSString *key = (item ? ([item keyEquivalent] ?: @"") : @"");
          NSUInteger mask = item ? [item keyEquivalentModifierMask] : 0;
          NSString *shortcut = ShortcutForItem(item);
          [out appendFormat: @"%d\t%ld\t%@\t%d\t%d\t%ld\t%@\t%lu\t%@\n",
            depth, (long)i, title, enabled ? 1 : 0, hasSubmenu ? 1 : 0,
            (long)state, key, (unsigned long)mask, shortcut];
          if (hasSubmenu)
            [self appendMenuLinesForMenu: [item submenu] depth: depth + 1
                                   into: out];
        }
    }
  @catch (NSException *e)
    {
      /* Skip any item that misbehaves; the rest of the tree still comes out. */
    }
}

/* Perform the action of the menu item addressed by the given index path,
 * where each non-final index must resolve to an item with a submenu.  Runs on
 * the main thread (the socket is serviced there) so the action fires exactly
 * as a real menu selection would. */
- (BOOL)resolveMenuIndexes:(NSArray *)indexes menu:(NSMenu **)outMenu
                     index:(NSInteger *)outIndex error:(NSString **)err
{
  NSMenu *menu = [NSApp mainMenu];
  if (menu == nil)
    {
      if (err) *err = @"no main menu";
      return NO;
    }
  NSUInteger count = [indexes count];
  if (count == 0)
    {
      if (err) *err = @"empty index path";
      return NO;
    }
  for (NSUInteger k = 0; k < count; k++)
    {
      NSInteger idx = [[indexes objectAtIndex: k] integerValue];
      @try
        {
          NSMenuItem *item = [menu itemAtIndex: idx];
          if (item == nil)
            {
              if (err) *err = [NSString stringWithFormat:
                @"menu index %ld out of range", (long)idx];
              return NO;
            }
          if (k == count - 1)
            {
              if (outMenu) *outMenu = menu;
              if (outIndex) *outIndex = idx;
              return YES;
            }
          NSMenu *sub = [item submenu];
          if (sub == nil)
            {
              if (err) *err = [NSString stringWithFormat:
                @"menu item %ld has no submenu", (long)idx];
              return NO;
            }
          menu = sub;
        }
      @catch (NSException *e)
        {
          if (err) *err = [NSString stringWithFormat: @"menu invoke exception: %@", e];
          return NO;
        }
    }
  return NO;
}

/* ---- snapshot builder (main thread) ---- */

- (void)buildSnapshot:(id)unused
{
  NSArray *fresh = [self collectSnapshot];
  [_snapshot release];
  _snapshot = [fresh retain];
}

- (NSArray *)collectSnapshot
{
  NSMutableArray *items = [NSMutableArray array];

  @try
    {
      [items addObject: [self itemForApp]];

      for (NSWindow *win in [NSApp windows])
        {
          [self addWindow: win depth: 1 into: items];
        }
    }
  @catch (NSException *e)
    {
      /* Never let a bad view take down the snapshot. */
    }

  return items;
}

- (NSArray *)itemForApp
{
  return [NSArray arrayWithObjects:
            [NSNumber numberWithInt: 0],
            @"NSApplication",
            @"",
            @"",
            @"",
            @"",
            @"0",
            [self objectIDForObject: NSApp],
            nil];
}

- (void)addWindow:(NSWindow *)win depth:(int)depth into:(NSMutableArray *)items
{
  @try
    {
      /* `[win frame]` is already in screen coordinates, so it doubles as the
       * screen_frame that lets driving commands (click/hover/scroll/drag)
       * resolve an on-screen position for the window itself. */
      NSString *screenFrame = [win isVisible]
        ? NSStringFromRect([win frame]) : @"";
      [items addObject: [NSArray arrayWithObjects:
                          [NSNumber numberWithInt: depth],
                          NSStringFromClass([win class]),
                          [win title] ?: @"",
                          @"",
                          NSStringFromRect([win frame]),
                          screenFrame,
                          [NSNumber numberWithInt: [win isVisible] ? 0 : 1],
                          [self objectIDForObject: win],
                          nil]];

      [self addView: [win contentView] depth: depth + 1 into: items];
    }
  @catch (NSException *e) { }
}

- (void)addView:(NSView *)view depth:(int)depth into:(NSMutableArray *)items
{
  if (view == nil) return;

  @try
    {
      NSString *text = @"";
      if ([view isKindOfClass: [NSTextField class]]) {
        /* Empty text fields (e.g. a search field with nothing typed yet) fall
         * back to their placeholder so scripts can still name them. */
        text = [(NSTextField *)view stringValue] ?: @"";
        if ([text length] == 0) {
          id ph = [[(NSTextField *)view cell] placeholderString];
          if (ph && [ph isKindOfClass: [NSString class]] && [ph length] > 0)
            text = ph;
        }
      } else if ([view respondsToSelector: @selector(title)]) {
        id t = [view performSelector: @selector(title)];
        if (t && [t isKindOfClass: [NSString class]] && [t length] > 0) text = t;
      } else if ([view respondsToSelector: @selector(stringValue)]) {
        id s = [view performSelector: @selector(stringValue)];
        if (s && [s isKindOfClass: [NSString class]]) text = s;
      } else if ([view respondsToSelector: @selector(appName)]) {
        /* Icon views (e.g. DockIcon in the Workspace Dock) identify
         * themselves by their app name; expose it as the searchable text. */
        id n = [view performSelector: @selector(appName)];
        if (n && [n isKindOfClass: [NSString class]] && [n length] > 0) text = n;
      }

      NSString *screenFrame = @"";
      NSWindow *w = [view window];
      if (w) {
        NSRect sf = [w convertRectToScreen: [view convertRect: [view bounds] toView: nil]];
        screenFrame = NSStringFromRect(sf);
      }

      /* A subview of a hidden (or orderOut'd) window is not on screen even
       * though [view isHidden] is NO; inherit the window's visibility so
       * `wait until not exists button ...` resolves a dismissed dialog. */
      BOOL viewHidden = [view isHidden];
      NSWindow *ownWin = [view window];
      if (ownWin && ![ownWin isVisible])
        {
          viewHidden = YES;
        }

      [items addObject: [NSArray arrayWithObjects:
                          [NSNumber numberWithInt: depth],
                          NSStringFromClass([view class]),
                          text,
                          [NSNumber numberWithInt: [view isKindOfClass: [NSControl class]]
                                               ? (int)[(NSControl *)view tag] : 0],
                          NSStringFromRect([view frame]),
                          screenFrame,
                          [NSNumber numberWithInt: viewHidden ? 1 : 0],
                          [self objectIDForObject: view],
                          nil]];

      if ([view isKindOfClass: [NSTableView class]])
        {
          /* Table rows are not subviews, so they never appear in a plain
           * subview walk; enumerate them so scripts can click them by the
           * text shown in the first column. */
          [self addTableRows: (NSTableView *)view depth: depth + 1 into: items];
        }

      for (NSView *sub in [view subviews])
        {
          [self addView: sub depth: depth + 1 into: items];
        }
    }
  @catch (NSException *e) { }
}

/* Emit one tree entry per table row (first-column text + on-screen rect) so
 * driving commands can resolve and click rows by their visible label. */
- (void)addTableRows:(NSTableView *)tv depth:(int)depth into:(NSMutableArray *)items
{
  @try
    {
      NSInteger numRows = [tv numberOfRows];
      if (numRows == 0) return;
      NSRange visible = [tv rowsInRect: [tv bounds]];
      NSWindow *w = [tv window];
      for (NSInteger r = 0; r < numRows; r++)
        {
          BOOL isVisible = (r >= (NSInteger)visible.location
                            && r < (NSInteger)(visible.location + visible.length));
          NSString *rowText = @"";
          /* Cell-based tables give per-row text through the data source;
           * preparedCellAtColumn:row: can return a stale shared cell. */
          id ds = [tv dataSource];
          if (ds && [ds respondsToSelector: @selector(tableView:objectValueForTableColumn:row:)])
            {
              NSArray *cols = [tv tableColumns];
              NSTableColumn *col = ([cols count] > 0) ? [cols objectAtIndex: 0] : nil;
              if (col)
                {
                  id value = [ds tableView: tv
                     objectValueForTableColumn: col
                                           row: r];
                  if ([value isKindOfClass: [NSString class]]) rowText = value;
                }
            }
          if ([rowText length] == 0)
            {
              NSCell *cell = [tv preparedCellAtColumn: 0 row: r];
              if (cell) rowText = [cell stringValue] ?: @"";
            }

          NSString *screenFrame = @"";
          if (w && isVisible)
            {
              NSRect rowRect = [tv rectOfRow: r];
              NSRect screenRect = [w convertRectToScreen: [tv convertRect: rowRect toView: nil]];
              screenFrame = NSStringFromRect(screenRect);
            }

          [items addObject: [NSArray arrayWithObjects:
                              [NSNumber numberWithInt: depth],
                              @"NSTableViewRow",
                              rowText,
                              [NSNumber numberWithInt: 0],
                              NSStringFromRect([tv rectOfRow: r]),
                              screenFrame,
                              [NSNumber numberWithInt: isVisible ? 0 : 1],
                              [NSString stringWithFormat: @"row:%p:%ld", tv, (long)r],
                              nil]];
        }
    }
  @catch (NSException *e) { }
}

- (NSString *)objectIDForObject:(id)obj
{
  return obj ? [NSString stringWithFormat: @"objc:%p", obj] : @"-";
}

- (id)objectForID:(NSString *)objID
{
  if (objID == nil || ![objID hasPrefix: @"objc:"]) return nil;
  unsigned long long ptrVal;
  NSScanner *scanner = [NSScanner scannerWithString: [objID substringFromIndex: 5]];
  if ([scanner scanHexLongLong: &ptrVal])
    return (__bridge id)(void *)ptrVal;
  return nil;
}

/* Recursively append a menu's titles as indented lines (debug helper), with
 * the shortcut (if any) after the title. */
- (void)appendMenuTree:(NSMenu *)menu depth:(int)depth into:(NSMutableString *)out
{
  for (NSMenuItem *item in [menu itemArray])
    {
      for (int i = 0; i < depth; i++) [out appendString: @"  "];
      NSString *title = [item title] ?: @"";
      NSString *sc = ShortcutForItem(item);
      if ([sc length] > 0)
        title = [NSString stringWithFormat: @"%@  [%@]", title, sc];
      [out appendFormat: @"%@%@\n", [item isSeparatorItem] ? @"-" : @"", title];
      if ([item submenu] != nil)
        [self appendMenuTree: [item submenu] depth: depth + 1 into: out];
    }
}

/* Collect every button in the view's subtree (depth-first). */
- (void)collectButtons:(NSView *)view into:(NSMutableArray *)out
{
  if (view == nil) return;
  if ([view isKindOfClass: [NSButton class]])
    [out addObject: view];
  for (NSView *sub in [view subviews])
    [self collectButtons: sub into: out];
}

/* Collect all menu-bar NSMenuViews in the view's subtree (depth-first). */
- (void)collectMenuViews:(NSView *)view into:(NSMutableArray *)out
{
  if (view == nil) return;
  if ([view isKindOfClass: [NSMenuView class]])
    {
      [out addObject: view];
      return;
    }
  for (NSView *sub in [view subviews])
    [self collectMenuViews: sub into: out];
}

/* Does a menu title match the requested (possibly English) title?  Tries the
 * raw title and the app's localized spelling. */
- (BOOL)menuTitle:(NSString *)title matches:(NSString *)want
{
  if ([title rangeOfString: want options: NSCaseInsensitiveSearch].location != NSNotFound)
    return YES;
  NSString *loc = [[NSBundle mainBundle] localizedStringForKey: want
                            value: want table: nil];
  if (![loc isEqualToString: want] &&
      [title rangeOfString: loc options: NSCaseInsensitiveSearch].location != NSNotFound)
    return YES;
  return NO;
}

/* Walk a menu by title path and invoke the leaf item's action (the same
 * dispatch a real click performs).  Returns YES if the path was found. */
- (BOOL)triggerMenuPath:(NSArray *)segs inMenu:(NSMenu *)menu
{
  if (menu == nil || [segs count] == 0) return NO;
  NSString *want = [segs objectAtIndex: 0];
  for (NSMenuItem *item in [menu itemArray])
    {
      if ([item isSeparatorItem]) continue;
      if (![self menuTitle: [item title] ?: @"" matches: want]) continue;
      if ([segs count] == 1)
        {
          @try
            {
              [NSApp sendAction: [item action] to: [item target] from: item];
            }
          @catch (NSException *e)
            {
            }
          return YES;
        }
      if ([item submenu] != nil)
        {
          NSArray *rest = [segs subarrayWithRange:
            NSMakeRange (1, [segs count] - 1)];
          if ([self triggerMenuPath: rest inMenu: [item submenu]])
            return YES;
        }
    }
  return NO;
}

/* Recursively walk a view subtree for menu bars (NSMenuView) and append their
 * top-level items as "title\tx\ty" lines, with x/y the item's on-screen centre
 * in top-down X11 coordinates.  `screenHeight` is the screen height used to
 * flip GNUstep's bottom-up origin. */
- (void)appendMenuBarItemsForView:(NSView *)view
                     screenHeight:(CGFloat)screenHeight
                             into:(NSMutableString *)out
{
  if (view == nil) return;
  @try
    {
      if ([view isKindOfClass: [NSMenuView class]])
        {
          NSMenuView *mv = (NSMenuView *)view;
          NSWindow *win = [mv window];
          NSMenu *menu = [mv menu];
          if (win != nil && menu != nil)
            {
              NSArray *items = [menu itemArray];
              NSInteger n = [menu numberOfItems];
              NSLog(@"[MENUBAR] NSMenuView %p win=%@ items=%ld", mv, win, (long)n);
              for (NSInteger i = 0; i < n && i < (NSInteger)[items count]; i++)
                {
                  NSMenuItem *item = [items objectAtIndex: i];
                  if ([item isSeparatorItem]) continue;
                  NSRect r = [mv rectOfItemAtIndex: i];
                  NSRect sr = [win convertRectToScreen:
                    [mv convertRect: r toView: nil]];
                  CGFloat cx = NSMidX (sr);
                  CGFloat cy = screenHeight - NSMidY (sr);
                  [out appendFormat: @"%@\t%.0f\t%.0f\n",
                    [item title] ?: @"", cx, cy];
                }
            }
          /* A menu bar may have multiple NSMenuViews (app + system areas);
           * do not recurse into its subviews. */
          return;
        }
    }
  @catch (NSException *e)
    {
      return;
    }
  for (NSView *sub in [view subviews])
    [self appendMenuBarItemsForView: sub screenHeight: screenHeight into: out];
}

/* Find an NSButton in the view's subtree.  If title is nil, prefer the
 * button whose key equivalent is Return (the modal default button), falling
 * back to the first button.  If title is non-nil, match the button's
 * displayed title against it (English or localized). */
- (NSButton *)findButtonInView:(NSView *)view title:(NSString *)title
{
  NSMutableArray *buttons = [NSMutableArray array];
  [self collectButtons: view into: buttons];
  for (NSButton *b in buttons)
    {
      if (title != nil)
        {
          NSString *bt = [b title] ?: @"";
          NSString *loc = [[NSBundle mainBundle] localizedStringForKey: title
                            value: title table: nil];
          if ([bt rangeOfString: title options: NSCaseInsensitiveSearch].location
                != NSNotFound
              || ([loc isEqualToString: title] == NO
                  && [bt rangeOfString: loc options: NSCaseInsensitiveSearch].location
                       != NSNotFound))
            return b;
        }
      else if ([[b keyEquivalent] isEqualToString: @"\r"])
        {
          return b;              /* the default button wins */
        }
    }
  if (title == nil && [buttons count] > 0)
    return [buttons objectAtIndex: 0];
  return nil;
}

/* Invoke a button of the current modal window in-process.  `which` is a
 * displayed button title (English or localized) or "default".  On success the
 * reply is "ok|<cx>|<cy>", where (cx,cy) is the modal window's frame center in
 * GNUstep screen coordinates (origin bottom-left) - the caller clicks there
 * with a real XTEST event to wake the modal run loop, which is parked in
 * DPSPeekEvent and only notices stopModalWithCode: once a real X event arrives
 * (NSApplication.m).  Returns "error:<reason>\n" on failure. */
- (NSString *)invokeModalButton:(NSString *)which
{
  NSWindow *mw = [NSApp modalWindow];
  if (mw == nil)
    return @"error:no modal window\n";
  NSString *wantTitle = nil;
  if (which != nil
      && [[which lowercaseString] isEqualToString: @"default"] == NO)
    wantTitle = which;
  NSButton *btn = [self findButtonInView: [mw contentView] title: wantTitle];
  if (btn == nil)
    return [NSString stringWithFormat: @"error:no button '%@' in modal window\n",
                     which ?: @"default"];
  @try
    {
      [btn performClick: nil];
      /* The Eau alert defers stopModal to a timer (performSelector:afterDelay:)
       * that the modal run loop may not process promptly, leaving the session
       * parked in DPSPeekEvent.  Set the stop state now so the caller's wake
       * click - a real X event arriving on the app's socket - makes
       * runModalForWindow: re-check and exit immediately.  A second
       * stopModalWithCode: from the deferred selector is a no-op. */
      [NSApp stopModal];
    }
  @catch (NSException *e)
    {
      return [NSString stringWithFormat: @"error:performClick threw %@\n", e];
    }
  NSRect f = [mw frame];
  return [NSString stringWithFormat: @"ok|%.0f|%.0f\n",
    NSMidX (f), NSMidY (f)];
}

- (NSString *)snapshotLines
{
  NSMutableString *out = [NSMutableString string];
  for (NSArray *row in _snapshot)
    {
      [out appendFormat: @"%d\t%@\t%@\t%@\t%@\t%@\t%@\t%@\n",
         [[row objectAtIndex: 0] intValue],
         [row objectAtIndex: 1],
         [row objectAtIndex: 2],
         [row objectAtIndex: 3],
         [row objectAtIndex: 4],
         [row objectAtIndex: 5],
         [row objectAtIndex: 6],
         [row objectAtIndex: 7]];
    }
  return out;
}

@end
