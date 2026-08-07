/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* drive_ui - fast UI-tree inspection and driving CLI.
 *
 * Inspection comes from the DriveUI.bundle socket server (a per-PID
 * Unix-domain socket at /tmp/driveui.<pid>.sock): the widget tree is served
 * as one tab-separated line per item.  Driving (clicks, typing, pressing
 * Return) is done by simulating REAL X11 pointer and key events at the
 * widget's on-screen position - never by calling ObjC methods on the app - so
 * modal dialogs, key equivalents and text fields behave exactly as if a user
 * operated them, regardless of language.
 *
 *   drive_ui [--pid N] get_full_tree
 *   drive_ui [--pid N] find_widgets [--class C] [--text T] [--tag N] [--visible]
 *   drive_ui [--pid N] click <object_id> | --text <label> [--class C]
 *   drive_ui [--pid N] doubleclick <object_id> | --text <label> [--class C]
 *   drive_ui [--pid N] rightclick <object_id> | --text <label> [--class C]
 *   drive_ui [--pid N] hover <object_id>      (move pointer over the widget)
 *   drive_ui [--pid N] scroll <object_id> <dir> [n]
 *   drive_ui [--pid N] scroll <dir> [n]       (scroll at the current pointer)
 *   drive_ui [--pid N] drag <object_id> <dx> <dy>   (press + drag by dx,dy)
 *   drive_ui [--pid N] type <object_id> <text> | --text <label> <text> [--class C]
 *   drive_ui [--pid N] sendkeys <text>          (type into the focused field)
 *   drive_ui [--pid N] clear <object_id> | --text <label> [--class C]
 *   drive_ui [--pid N] focus <object_id> | --text <label> [--class C]
 *   drive_ui [--pid N] get <object_id> | --text <label> [--class C]
 *   drive_ui [--pid N] app                     (read-only: app name)
 *   drive_ui [--pid N] props <object_id>        (read-only: enabled/state)
 *   drive_ui [--pid N] menu                    (read-only: main menu tree)
 *   drive_ui [--pid N] menu_select "Top/Sub"   (perform menu item by title path)
 *   drive_ui [--pid N] menu_invoke <i0> <i1>.. (perform menu action by index)
 *   drive_ui [--pid N] localize <english>       (translate to app language)
 *   drive_ui [--pid N] assert <exists|not-exists|enabled|checked> [--class C] [--text T] [--tag N] [--visible]
 *   drive_ui [--pid N] assert contains --text <needle>
 *   drive_ui [--pid N] wait_until [--class C] [--text T] [--tag N] [--visible] [--timeout N] [--not-exists]
 *   drive_ui [--pid N] capture [<path>]         (screenshot root window to PNG)
 *   drive_ui [--pid N] press                     (press Return)
 *   drive_ui [--pid N] chord <mods> <key>        (e.g. chord control c)
 *
 * Snapshot fields: depth  class  text  tag  frame  screen_frame  hidden  object_id
 *
 * Because `text` is the displayed (localized) title/stringValue, widgets can be
 * located by their on-screen label; the driving commands then act at that
 * widget's screen position, so they work on any language.  `menu`, `menu_select`
 * and `menu_invoke` resolve and trigger menu items in-process on the app (fast,
 * localization-safe); `menu_select` accepts a slash-separated title path in
 * English or the localized spelling.  `assert` and `wait_until` are script
 * building blocks: they verify/poll the widget tree (visible widgets only) and
 * exit with a status a script can branch on.  `localize` maps an English string
 * to the app's current language so titles can be written in English for any
 * locale.
 */

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/poll.h>
#import <sys/time.h>
#import <unistd.h>
#import "X11Support.h"

#define DRIVE_UI_TOOL_TIMEOUT_MS 1000

static int ConnectToPid(int pid)
{
  NSString *path = [NSString stringWithFormat: @"/tmp/driveui.%d.sock", pid];
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, [path UTF8String], sizeof(addr.sun_path) - 1);

  if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0)
    {
      close(fd);
      return -1;
    }
  return fd;
}

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

/* Read the reply until EOF or the read timeout.  Sets *timedOut when the
 * socket produced nothing within the timeout window, so callers can surface a
 * stall instead of mistaking it for an empty answer. */
static NSString *ReadAll(int fd, BOOL *timedOut)
{
  if (timedOut) *timedOut = NO;
  NSMutableData *data = [NSMutableData data];
  char buf[4096];
  for (;;)
    {
      struct pollfd pfd;
      pfd.fd = fd;
      pfd.events = POLLIN;
      int pr = poll(&pfd, 1, DRIVE_UI_TOOL_TIMEOUT_MS);
      if (pr < 0) break;
      if (pr == 0)
        {
          if (timedOut) *timedOut = YES;
          break;
        }
      ssize_t n = read(fd, buf, sizeof(buf));
      if (n <= 0) break;
      [data appendBytes: buf length: (NSUInteger)n];
    }
  return [[[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding] autorelease];
}

/* Log a round-trip that was slow or stalled, so command latencies and blocked
 * replies are visible when tuning drive_ui's performance. */
static void LogCommandTiming(NSString *cmdline, double ms, BOOL timedOut)
{
  if (timedOut)
    {
      fprintf(stderr, "drive_ui: TIMEOUT waiting %.0f ms for reply to '%s'\n",
        ms, [cmdline UTF8String]);
    }
  else if (ms > 250.0)
    {
      fprintf(stderr, "drive_ui: slow round-trip %.0f ms for '%s'\n",
        ms, [cmdline UTF8String]);
    }
}

/* Send a command line to the app and return the raw reply. */
static NSString *SendCommand(int pid, NSString *cmdline)
{
  int fd = ConnectToPid(pid);
  if (fd < 0)
    {
      fprintf(stderr, "drive_ui: no DriveUI socket for pid=%d (is DriveUI.bundle loaded?)\n", pid);
      return nil;
    }
  struct timeval t0, t1;
  gettimeofday(&t0, NULL);
  NSString *line = [cmdline stringByAppendingString: @"\n"];
  WriteAll(fd, [line UTF8String]);
  BOOL timedOut = NO;
  NSString *reply = ReadAll(fd, &timedOut);
  close(fd);
  gettimeofday(&t1, NULL);
  double ms = (t1.tv_sec - t0.tv_sec) * 1000.0
    + (t1.tv_usec - t0.tv_usec) / 1000.0;
  LogCommandTiming(cmdline, ms, timedOut);
  return reply;
}

static NSString *FetchTree(int pid)
{
  return SendCommand(pid, @"full");
}

static NSArray *ParseTree(NSString *out)
{
  NSMutableArray *rows = [NSMutableArray array];
  if (!out) return rows;
  for (NSString *line in [out componentsSeparatedByString: @"\n"])
    {
      if ([line length] == 0) continue;
      [rows addObject: [line componentsSeparatedByString: @"\t"]];
    }
  return rows;
}

static void PrintRow(NSArray *f)
{
  NSMutableString *s = [NSMutableString string];
  for (NSUInteger i = 0; i < [f count]; i++)
    {
      if (i > 0) [s appendString: @"\t"];
      [s appendString: [f objectAtIndex: i]];
    }
  printf("%s\n", [s UTF8String]);
}

static void PrintMatching(NSString *out, NSString *wantClass, NSString *wantText,
                          NSNumber *wantTag, BOOL wantVisible)
{
  for (NSArray *f in ParseTree(out))
    {
      if ([f count] < 8) continue;
      NSString *cls = [f objectAtIndex: 1];
      NSString *text = [f objectAtIndex: 2];
      NSString *tagStr = [f objectAtIndex: 3];
      NSString *hiddenStr = [f objectAtIndex: 6];

      if (wantVisible && [hiddenStr isEqualToString: @"1"]) continue;
      if (wantClass && [cls rangeOfString: wantClass options: NSCaseInsensitiveSearch].location == NSNotFound) continue;
      if (wantText && [text rangeOfString: wantText options: NSCaseInsensitiveSearch].location == NSNotFound) continue;
      if (wantTag && [tagStr intValue] != [wantTag intValue]) continue;

      PrintRow(f);
    }
}

/* Resolve a widget to a row by (optionally class-scoped) localized text. */
static NSArray *ResolveRow(NSArray *rows, NSString *wantClass, NSString *wantText, BOOL wantVisible)
{
  if (!wantText) return nil;
  for (NSArray *f in rows)
    {
      if ([f count] < 8) continue;
      NSString *cls = [f objectAtIndex: 1];
      NSString *text = [f objectAtIndex: 2];
      NSString *hiddenStr = [f objectAtIndex: 6];
      if (wantVisible && [hiddenStr isEqualToString: @"1"]) continue;
      if (wantClass && [cls rangeOfString: wantClass options: NSCaseInsensitiveSearch].location == NSNotFound) continue;
      if ([text rangeOfString: wantText options: NSCaseInsensitiveSearch].location == NSNotFound) continue;
      return f;
    }
  return nil;
}

/* Resolve a widget row by object_id. */
static NSArray *ResolveRowByID(NSArray *rows, NSString *objID)
{
  if (!objID) return nil;
  for (NSArray *f in rows)
    {
      if ([f count] < 8) continue;
      if ([[f objectAtIndex: 7] isEqualToString: objID]) return f;
    }
  return nil;
}

/* Translate an English UI string to the app's current language via the
 * bundle's `localize` command, so title paths and widget labels can be
 * written in English and still match a localized (e.g. German) UI. */
static NSString *LocalizeString(int pid, NSString *english)
{
  if (english == nil || [english length] == 0) return english;
  NSString *out = SendCommand(pid, [NSString stringWithFormat: @"localize\t%@", english]);
  NSString *localized = out ? [out stringByTrimmingCharactersInSet:
    [NSCharacterSet newlineCharacterSet]] : english;
  return ([localized length] > 0) ? localized : english;
}

/* Case-insensitive substring match that also accepts the localized spelling
 * of the needle (mirrors the UITest's title:matches:). */
static BOOL TitleMatches(int pid, NSString *title, NSString *segOrEnglish)
{
  if ([title rangeOfString: segOrEnglish options: NSCaseInsensitiveSearch].location != NSNotFound)
    return YES;
  NSString *localized = LocalizeString(pid, segOrEnglish);
  if (![localized isEqualToString: segOrEnglish] &&
      [title rangeOfString: localized options: NSCaseInsensitiveSearch].location != NSNotFound)
    return YES;
  return NO;
}

/* Node in the menu-title trie built from the `menu` tree, so a slash-separated
 * title path ("Edit/Copy") can be resolved to the menu_invoke index path. */
typedef struct DriveUIMenuNode { NSString *title; int index; struct DriveUIMenuNode **kids; int nkids; } DriveUIMenuNode;

static void DriveUIMenuNodeFree(DriveUIMenuNode *n)
{
  if (!n) return;
  for (int i = 0; i < n->nkids; i++) DriveUIMenuNodeFree(n->kids[i]);
  free(n->kids);
  [n->title release];
  free(n);
}

/* Resolve a menu path like "Edit/Copy" (any segment may be English or the
 * localized spelling) against the serialized menu tree and perform the leaf
 * item's action in-process via menu_invoke.  Returns 0 on success, non-zero
 * with a message on stderr otherwise. */
static int MenuSelect(int pid, NSString *path)
{
  if (path == nil || [path length] == 0)
    {
      fprintf(stderr, "drive_ui: menu_select needs a path (use \"Top/Sub\")\n");
      return 1;
    }
  NSString *tree = SendCommand(pid, @"menu");
  if (tree == nil)
    {
      fprintf(stderr, "drive_ui: cannot read menu tree\n");
      return 1;
    }

  DriveUIMenuNode *root = calloc(1, sizeof(DriveUIMenuNode));
  root->title = @"";
  root->index = -1;

  /* parents[d] = the node whose submenu items sit at depth d; parents[0] is the
   * virtual root holding the top-level bar items.  Because the serialized
   * lines are ordered depth-first, setting parents[depth+1] when we see a
   * submenu node always yields the correct ancestor for the lines that follow. */
  DriveUIMenuNode *parents[64];
  memset(parents, 0, sizeof(parents));
  parents[0] = root;

  BOOL anyItem = NO;
  for (NSString *line in [tree componentsSeparatedByString: @"\n"])
    {
      NSArray *f = [line componentsSeparatedByString: @"\t"];
      if ([f count] < 5) continue;
      int depth = [[f objectAtIndex: 0] intValue];
      int index = [[f objectAtIndex: 1] intValue];
      NSString *title = [f objectAtIndex: 2];
      BOOL hasSubmenu = [[f objectAtIndex: 4] isEqualToString: @"1"];
      if (depth < 0 || depth >= 64) continue;
      anyItem = YES;

      DriveUIMenuNode *parent = parents[depth];
      if (parent == NULL) continue;
      parent->kids = realloc(parent->kids, sizeof(DriveUIMenuNode *) * (parent->nkids + 1));
      DriveUIMenuNode *node = calloc(1, sizeof(DriveUIMenuNode));
      node->title = [title copy];
      node->index = index;
      parent->kids[parent->nkids++] = node;

      if (hasSubmenu && depth + 1 < 64) parents[depth + 1] = node;
    }

  if (!anyItem)
    {
      fprintf(stderr, "drive_ui: application has no menu (DriveUI menu unsupported?)\n");
      DriveUIMenuNodeFree(root);
      return 1;
    }

  NSArray *segs = [path componentsSeparatedByString: @"/"];
  NSMutableArray *indices = [NSMutableArray array];
  DriveUIMenuNode *current = root;
  BOOL found = YES;
  for (NSString *seg in segs)
    {
      if ([seg length] == 0) continue;
      DriveUIMenuNode *match = NULL;
      for (int i = 0; i < current->nkids; i++)
        {
          if (TitleMatches(pid, current->kids[i]->title, seg))
            { match = current->kids[i]; break; }
        }
      if (match == NULL) { found = NO; break; }
      [indices addObject: @(match->index)];
      current = match;
    }

  if (!found || [indices count] == 0)
    {
      fprintf(stderr, "drive_ui: menu item '%s' not found\n", [path UTF8String]);
      DriveUIMenuNodeFree(root);
      return 1;
    }
  DriveUIMenuNodeFree(root);

  NSMutableArray *tokens = [NSMutableArray arrayWithObject: @"menu_invoke"];
  for (NSNumber *idx in indices) [tokens addObject: [idx stringValue]];
  NSString *reply = SendCommand(pid, [tokens componentsJoinedByString: @"\t"]);
  if (reply == nil) return 1;
  if ([reply hasPrefix: @"error:"])
    {
      fprintf(stderr, "drive_ui: %s", [[reply stringByTrimmingCharactersInSet:
        [NSCharacterSet newlineCharacterSet]] UTF8String]);
      return 1;
    }
  return 0;
}

/* Match a snapshot row against --class/--text/--tag filters.  Text matching is
 * the localized substring match used for title paths.  Returns YES if the row
 * satisfies all supplied filters. */
static BOOL RowMatches(int pid, NSArray *f, NSString *wantClass, NSString *wText,
                       NSNumber *wantTag, BOOL wantVisible)
{
  if ([f count] < 8) return NO;
  NSString *cls = [f objectAtIndex: 1];
  NSString *text = [f objectAtIndex: 2];
  NSString *tagStr = [f objectAtIndex: 3];
  NSString *hiddenStr = [f objectAtIndex: 6];
  if (wantVisible && [hiddenStr isEqualToString: @"1"]) return NO;
  if (wantClass && [cls rangeOfString: wantClass options: NSCaseInsensitiveSearch].location == NSNotFound) return NO;
  if (wantTag && [tagStr intValue] != [wantTag intValue]) return NO;
  if (wText && TitleMatches(pid, text, wText) == NO) return NO;
  return YES;
}

/* Assert a condition about the widget tree.  Returns 0 if the assertion holds,
 * 1 otherwise (a message is printed to stderr).  Kinds:
 *   exists      - a matching visible widget is present
 *   not-exists  - no matching visible widget is present
 *   enabled     - the matching widget exists and is enabled
 *   checked     - the matching widget exists and is checked
 *   contains    - some visible widget's text contains the --text needle */
static int AssertWidgets(int pid, NSString *wantClass, NSString *wantText,
                         NSNumber *wantTag, BOOL wantVisible,
                         NSString *kind, NSString *needle)
{
  NSString *tree = FetchTree(pid);
  if (tree == nil)
    {
      fprintf(stderr, "drive_ui: assert failed: cannot read widget tree\n");
      return 1;
    }
  NSArray *rows = ParseTree(tree);

  if ([kind isEqualToString: @"contains"])
    {
      if (needle == nil || [needle length] == 0)
        {
          fprintf(stderr, "drive_ui: assert contains needs --text <needle>\n");
          return 1;
        }
      for (NSArray *f in rows)
        {
          if ([f count] < 8) continue;
          if ([[f objectAtIndex: 6] isEqualToString: @"1"]) continue;
          if ([[f objectAtIndex: 2] rangeOfString: needle options: NSCaseInsensitiveSearch].location != NSNotFound)
            return 0;
        }
      fprintf(stderr, "drive_ui: assert failed: text '%s' not found\n", [needle UTF8String]);
      return 1;
    }

  NSArray *match = nil;
  for (NSArray *f in rows)
    {
      if (RowMatches(pid, f, wantClass, wantText, wantTag, wantVisible))
        { match = f; break; }
    }

  if ([kind isEqualToString: @"exists"])
    {
      if (match) return 0;
      fprintf(stderr, "drive_ui: assert failed: widget not found\n");
      return 1;
    }
  if ([kind isEqualToString: @"not-exists"])
    {
      if (!match) return 0;
      fprintf(stderr, "drive_ui: assert failed: widget unexpectedly present\n");
      return 1;
    }
  if ([kind isEqualToString: @"enabled"] || [kind isEqualToString: @"checked"])
    {
      if (!match)
        {
          fprintf(stderr, "drive_ui: assert failed: widget not found\n");
          return 1;
        }
      NSString *reply = SendCommand(pid, [NSString stringWithFormat: @"props\t%@",
        [match objectAtIndex: 7]]);
      BOOL enabled = NO, checked = NO;
      if (reply)
        {
          /* props reply is "enabled=1 state=0" or similar. */
          for (NSString *tok in [reply componentsSeparatedByString: @" "])
            {
              NSArray *kv = [tok componentsSeparatedByString: @"="];
              if ([kv count] != 2) continue;
              if ([[kv objectAtIndex: 0] isEqualToString: @"enabled"])
                enabled = [[kv objectAtIndex: 1] isEqualToString: @"1"];
              else if ([[kv objectAtIndex: 0] isEqualToString: @"state"])
                checked = [[kv objectAtIndex: 1] isEqualToString: @"1"];
            }
        }
      if ([kind isEqualToString: @"enabled"] && !enabled)
        {
          fprintf(stderr, "drive_ui: assert failed: widget is disabled\n");
          return 1;
        }
      if ([kind isEqualToString: @"checked"] && !checked)
        {
          fprintf(stderr, "drive_ui: assert failed: widget is not checked\n");
          return 1;
        }
      return 0;
    }

  fprintf(stderr, "drive_ui: unknown assert kind '%s'\n", [kind UTF8String]);
  return 1;
}

/* Poll the widget tree until a condition holds or the timeout (seconds)
 * elapses.  Mirrors the UITest's `wait until`.  Returns 0 on success, 2 on
 * timeout. */
static int WaitUntil(int pid, NSString *wantClass, NSString *wantText,
                     NSNumber *wantTag, BOOL wantVisible, double timeout,
                     BOOL wantNotExists)
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: timeout];
  while ([[NSDate date] compare: deadline] == NSOrderedAscending)
    {
      NSString *tree = FetchTree(pid);
      if (tree)
        {
          BOOL present = NO;
          for (NSArray *f in ParseTree(tree))
            {
              if (RowMatches(pid, f, wantClass, wantText, wantTag, wantVisible))
                { present = YES; break; }
            }
          BOOL ok = wantNotExists ? !present : present;
          if (ok) return 0;
        }
      usleep(100000);
    }
  fprintf(stderr, "drive_ui: timed out waiting for widget%s\n",
          wantNotExists ? " to disappear" : "");
  return 2;
}

/* Capture a screenshot of the whole root window to <path> (default
 * /tmp/drive_ui-<timestamp>.png) via ffmpeg x11grab - the same backend the
 * Screenshot component uses. */
static int CaptureScreenshot(NSString *path)
{
  NSString *target = path;
  if (target == nil || [target length] == 0)
    {
      NSDateFormatter *fmt = [[[NSDateFormatter alloc] init] autorelease];
      [fmt setDateFormat: @"yyyyMMdd-HHmmss"];
      target = [NSString stringWithFormat: @"/tmp/drive_ui-%@.png",
        [fmt stringFromDate: [NSDate date]]];
    }
  NSString *display = [[NSProcessInfo processInfo] environment][@"DISPLAY"];
  if (display == nil || [display length] == 0) display = @":0";

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath: @"/bin/ffmpeg"];
  [task setArguments: [NSArray arrayWithObjects:
    @"-f", @"x11grab", @"-i", display, @"-frames:v", @"1",
    @"-update", @"1", @"-y", @"-loglevel", @"error", target, nil]];
  /* Silence ffmpeg so the only stdout is the saved path (a script-friendly
   * interface).  A pipe is set up even though we never read it: without one,
   * NSTask inherits our stdout and the ffmpeg banner would leak through. */
  NSPipe *devnull = [NSPipe pipe];
  [task setStandardOutput: devnull];
  [task setStandardError: devnull];
  [task launch];
  [task waitUntilExit];
  int rc = [task terminationStatus];
  [task release];

  if (rc != 0)
    {
      fprintf(stderr, "drive_ui: screenshot failed (ffmpeg)\n");
      return 1;
    }
  printf("%s\n", [target UTF8String]);
  return 0;
}

/* Given a snapshot row, return the center of its screen_frame (used for
 * clicking/typing), or NSZeroPoint if unavailable.  The snapshot's screen_frame
 * is in GNUstep screen coordinates (origin at the BOTTOM-left of screen 0), but
 * the X11 pointer we inject into is top-left origin, so the Y coordinate is
 * flipped here. */
static NSPoint CenterOfRow(NSArray *f)
{
  if ([f count] < 6) return NSZeroPoint;
  NSString *sf = [f objectAtIndex: 5];
  if ([sf length] == 0) return NSZeroPoint;
  NSRect r = NSRectFromString(sf);
  if (r.size.width <= 0 || r.size.height <= 0) return NSZeroPoint;
  int sh = [X11Support screenHeight];
  if (sh <= 0) return NSZeroPoint;
  return NSMakePoint(NSMidX(r), sh - NSMidY(r));
}

static void Usage(void)
{
  printf("Usage:\n");
  printf("  drive_ui [--pid N] get_full_tree\n");
  printf("  drive_ui [--pid N] find_widgets [--class C] [--text T] [--tag N] [--visible]\n");
  printf("  drive_ui [--pid N] click <object_id> | --text <label> [--class C]\n");
  printf("  drive_ui [--pid N] doubleclick <object_id> | --text <label> [--class C]\n");
  printf("  drive_ui [--pid N] rightclick <object_id> | --text <label> [--class C]\n");
  printf("  drive_ui [--pid N] hover <object_id>          (move pointer over it)\n");
  printf("  drive_ui [--pid N] scroll <object_id> <dir> [n]   (dir=up/down/left/right)\n");
  printf("  drive_ui [--pid N] scroll <dir> [n]           (scroll at pointer)\n");
  printf("  drive_ui [--pid N] drag <object_id> <dx> <dy> (press + drag by dx,dy)\n");
  printf("  drive_ui [--pid N] type <object_id> <text> | --text <label> <text> [--class C]\n");
  printf("  drive_ui [--pid N] sendkeys <text>          (type into focused field)\n");
  printf("  drive_ui [--pid N] clear <object_id> | --text <label> [--class C]\n");
  printf("  drive_ui [--pid N] focus <object_id> | --text <label> [--class C]\n");
  printf("  drive_ui [--pid N] get <object_id> | --text <label> [--class C]\n");
  printf("  drive_ui [--pid N] app                       (read-only: app name)\n");
  printf("  drive_ui [--pid N] props <object_id>          (read-only: props)\n");
  printf("  drive_ui [--pid N] menu                       (read-only: main menu tree)\n");
  printf("  drive_ui [--pid N] menu_select \"Top/Sub\"     (perform menu item by title path)\n");
  printf("  drive_ui [--pid N] menu_invoke <i0> <i1> ...  (perform menu action by index)\n");
  printf("  drive_ui [--pid N] localize <english>          (translate to app language)\n");
  printf("  drive_ui [--pid N] assert [--class C] [--text T] [--tag N] [--visible] <exists|not-exists|enabled|checked>\n");
  printf("  drive_ui [--pid N] assert contains --text <needle>\n");
  printf("  drive_ui [--pid N] wait_until [--class C] [--text T] [--tag N] [--visible] [--timeout N] [--not-exists]\n");
  printf("  drive_ui [--pid N] capture [<path>]           (screenshot root window to PNG)\n");
  printf("  drive_ui [--pid N] press                     (press Return)\n");
  printf("  drive_ui [--pid N] chord <mods> <key>        (e.g. chord control c)\n");
  printf("  drive_ui [--pid N] modal                     (report current modal window: none or Class|title)\n");
  printf("Snapshot: depth\\tclass\\ttext\\ttag\\tframe\\tscreen_frame\\thidden\\tobject_id\n");
  printf("Actions simulate real X11 pointer/key events at the widget position,\n");
  printf("so they work on localized UIs and in modal dialogs.\n");
}

int main(int argc, const char *argv[])
{
  setenv("GNUSTEP_SYSTEM_ROOT", "/System", 1);
  setenv("GNUSTEP_LOCAL_ROOT", "/Local", 1);
  setenv("GNUSTEP_NETWORK_ROOT", "/Network", 1);
  const char *ldpath = getenv("LD_LIBRARY_PATH");
  NSString *ldpathStr = ldpath ? [NSString stringWithUTF8String: ldpath] : @"";
  NSMutableArray *parts = [NSMutableArray arrayWithObjects: @"/System/Library/Libraries", @"/Local/Library/Libraries", nil];
  if ([ldpathStr length] > 0) [parts addObject: ldpathStr];
  setenv("LD_LIBRARY_PATH", [[parts componentsJoinedByString: @":"] UTF8String], 1);
  setbuf(stdout, NULL);

  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  int pid = 0;
  NSMutableArray *args = [NSMutableArray array];
  for (int i = 1; i < argc; i++)
    {
      NSString *arg = [NSString stringWithUTF8String: argv[i]];
      if ([arg isEqualToString: @"--pid"] && i + 1 < argc)
        pid = atoi(argv[++i]);
      else if ([arg hasPrefix: @"--pid="])
        pid = atoi([arg UTF8String] + 6);
      else
        [args addObject: arg];
    }

  if ([args count] == 0)
    {
      Usage();
      [pool release];
      return 1;
    }

  NSString *command = [args objectAtIndex: 0];

  NSString *wantClass = nil, *wantText = nil, *idArg = nil;
  NSNumber *wantTag = nil;
  BOOL wantVisible = NO;

  for (NSUInteger i = 1; i < [args count]; i++)
    {
      NSString *a = [args objectAtIndex: i];
      if ([a isEqualToString: @"--class"] && i + 1 < [args count]) wantClass = [args objectAtIndex: ++i];
      else if ([a isEqualToString: @"--text"] && i + 1 < [args count]) wantText = [args objectAtIndex: ++i];
      else if ([a isEqualToString: @"--tag"] && i + 1 < [args count]) wantTag = @(atoi([(NSString *)[args objectAtIndex: ++i] UTF8String]));
      else if ([a isEqualToString: @"--visible"]) wantVisible = YES;
      else if ([a hasPrefix: @"objc:"] || [a hasPrefix: @"row:"]) idArg = a;
    }

  if ([command isEqualToString: @"get_full_tree"])
    {
      NSString *tree = FetchTree(pid);
      if (tree) printf("%s", [tree UTF8String]);
    }
  else if ([command isEqualToString: @"find_widgets"])
    {
      if (!wantClass && !wantText && !wantTag && !wantVisible)
        {
          fprintf(stderr, "drive_ui: find_widgets needs --class, --text, --tag or --visible\n");
          [pool release];
          return 1;
        }
      NSString *tree = FetchTree(pid);
      PrintMatching(tree, wantClass, wantText, wantTag, wantVisible);
    }
  else if ([command isEqualToString: @"get"])
    {
      /* get is read-only: ask the bundle for the widget's current text. */
      NSString *target = idArg;
      if (target == nil)
        {
          if (wantText == nil)
            {
              fprintf(stderr, "drive_ui: get needs <object_id> or --text <label>\n");
              [pool release];
              return 1;
            }
          NSString *tree = FetchTree(pid);
          NSArray *row = ResolveRow(ParseTree(tree), wantClass, wantText, wantVisible);
          if (row == nil)
            {
              fprintf(stderr, "drive_ui: no widget matching text '%s'\n", [wantText UTF8String]);
              [pool release];
              return 1;
            }
          target = [row objectAtIndex: 7];
        }
      NSString *reply = SendCommand(pid, [NSString stringWithFormat: @"get\t%@", target]);
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"app"])
    {
      /* Read-only: return the app name the snapshot belongs to. */
      NSString *reply = SendCommand(pid, @"app");
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"windows"])
    {
      /* Read-only: titles of visible windows (cheap alternative to the tree). */
      NSString *reply = SendCommand(pid, @"windows");
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"menubar"])
    {
      /* Read-only: top-level menu bar items as title\tx\ty (screen centres). */
      NSString *reply = SendCommand(pid, @"menubar");
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"menu_tree"])
    {
      /* Debug: dump the menu bar menus' titles. */
      NSString *reply = SendCommand(pid, @"menu_tree");
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"xwindow"])
    {
      /* xwindow <title> - scan the X display for any top-level window whose
       * name contains <title> (works for non-GNUstep apps too).  Prints 1 if
       * found, 0 if not. */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *title = ([positionals count] > 0) ? [positionals objectAtIndex: 0] : nil;
      if (title == nil || [title length] == 0)
        {
          fprintf(stderr, "drive_ui: xwindow needs <title>\n");
          [pool release];
          return 1;
        }
      unsigned long wid = [X11Support findWindowWithTitle: title];
      printf("%d\n", wid ? 1 : 0);
    }
  else if ([command isEqualToString: @"xwindow_count"])
    {
      /* xwindow_count <title> - count the top-level application windows
       * whose name contains <title> (ICCCM/EWMH-filtered, so window-manager
       * internals are excluded).  Prints the number. */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *title = ([positionals count] > 0) ? [positionals objectAtIndex: 0] : nil;
      if (title == nil || [title length] == 0)
        {
          fprintf(stderr, "drive_ui: xwindow_count needs <title>\n");
          [pool release];
          return 1;
        }
      printf("%lu\n", (unsigned long)[X11Support countWindowsWithTitle: title]);
    }
  else if ([command isEqualToString: @"xactivate"])
    {
      /* xactivate <title> - raise + focus the first top-level X window whose
       * name contains <title> (for apps without a DriveUI socket, e.g. GTK). */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *title = ([positionals count] > 0) ? [positionals objectAtIndex: 0] : nil;
      if (title == nil || [title length] == 0)
        {
          fprintf(stderr, "drive_ui: xactivate needs <title>\n");
          [pool release];
          return 1;
        }
      unsigned long wid = [X11Support findViewableWindowWithTitle: title];
      if (wid == 0)
        {
          fprintf(stderr, "drive_ui: xactivate: no window titled '%s'\n",
                  [title UTF8String]);
          [pool release];
          return 1;
        }
      [X11Support activateWindow: wid];
      [pool release];
      return 0;
    }
  else if ([command isEqualToString: @"click_menubar"])
    {
      /* click_menubar <title> - real X11 click on a top-level menu bar item,
       * so scripts can open the app's global menu and then click its items
       * (which appear as a normal menu window in the tree). */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *title = ([positionals count] > 0) ? [positionals objectAtIndex: 0] : nil;
      if (title == nil || [title length] == 0)
        {
          fprintf(stderr, "drive_ui: click_menubar needs <title>\n");
          [pool release];
          return 1;
        }
      NSString *list = SendCommand(pid, @"menubar");
      BOOL clicked = NO;
      for (NSString *line in [list componentsSeparatedByString: @"\n"])
        {
          NSArray *f = [line componentsSeparatedByString: @"\t"];
          if ([f count] < 3) continue;
          if ([[f objectAtIndex: 0] rangeOfString: title
            options: NSCaseInsensitiveSearch].location == NSNotFound) continue;
          double x = [[f objectAtIndex: 1] doubleValue];
          double y = [[f objectAtIndex: 2] doubleValue];
          [X11Support simulateMouseMoveTo: NSMakePoint (x, y)];
          usleep (50000);
          [X11Support simulateClick: 1];
          clicked = YES;
          break;
        }
      if (!clicked)
        {
          fprintf(stderr, "drive_ui: click_menubar: no item '%s' in menu bar\n",
                  [title UTF8String]);
          [pool release];
          return 1;
        }
    }
  else if ([command isEqualToString: @"menu_trigger"])
    {
      /* menu_trigger "Top/Sub" - dispatch a menu bar item's action in-process
       * (same path a real click uses).  Simpler and more reliable than a
       * synthetic drag through Menu.app's custom-drawn menu. */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *path = ([positionals count] > 0) ? [positionals objectAtIndex: 0] : nil;
      if (path == nil || [path length] == 0)
        {
          fprintf(stderr, "drive_ui: menu_trigger needs \"Top/Sub\"\n");
          [pool release];
          return 1;
        }
      NSString *reply = SendCommand(pid, [NSString stringWithFormat:
        @"menu_trigger\t%@", path]);
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"context_menu"])
    {
      /* context_menu <object_id> <Item Title> - build the widget's context
       * menu and dispatch the matching item's action in-process. */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      if ([positionals count] < 2)
        {
          fprintf(stderr, "drive_ui: context_menu needs <object_id> <title>\n");
          [pool release];
          return 1;
        }
      NSString *reply = SendCommand(pid, [NSString stringWithFormat:
        @"context_menu\t%@\t%@", [positionals objectAtIndex: 0],
        [positionals objectAtIndex: 1]]);
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"modal"])
    {
      /* Read-only: report the app's current modal window ("none" if none).
       * Lets scripts detect dialogs/alerts that block interaction. */
      NSString *reply = SendCommand(pid, @"modal");
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"dismiss_modal"])
    {
      /* End the current modal session in-process (invoke its default button).
       * Prints "ok" or an error. */
      NSString *reply = SendCommand(pid, @"dismiss_modal");
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"invoke_modal_button"])
    {
      /* invoke_modal_button <title|default> - invoke a button of the current
       * modal window by title, or "default" for the Return-equivalent one.
       * The bundle performs the click in-process and replies
       * "ok|<cx>|<cy>"; we then XTEST-click the modal window's center.  The
       * click is a real X event that wakes the modal run loop (parked in
       * DPSPeekEvent), which otherwise would not notice the stop code the
       * button action set and would stay up. */
      NSString *which = ([args count] > 1) ? [args objectAtIndex: 1] : @"default";
      NSString *reply = SendCommand(pid, [NSString stringWithFormat:
        @"invoke_modal_button\t%@", which]);
      if (reply && [reply hasPrefix: @"ok"])
        {
          NSArray *f = [[reply stringByTrimmingCharactersInSet:
            [NSCharacterSet newlineCharacterSet]]
            componentsSeparatedByString: @"|"];
          if ([f count] == 3)
            {
              double cx = [[f objectAtIndex: 1] doubleValue];
              double cy = [[f objectAtIndex: 2] doubleValue];
              int sh = [X11Support screenHeight];
              if (sh > 0)
                {
                  /* Wake the modal loop with a real click on the panel.  The
                   * panel centre is clear of the buttons and the message field
                   * is non-editable, so it is harmless. */
                  [X11Support simulateMouseMoveTo:
                    NSMakePoint (cx, sh - cy)];
                  usleep (50000);
                  [X11Support simulateClick: 1];
                  /* Let the deferred stop + runModal teardown run. */
                  usleep (300000);
                }
            }
          printf("ok\n");
        }
      else if (reply)
        {
          printf("%s", [reply UTF8String]);
        }
      else
        {
          fprintf(stderr, "drive_ui: invoke_modal_button: no reply\n");
          [pool release];
          return 1;
        }
    }
  else if ([command isEqualToString: @"props"])
    {
      /* Read-only: return enabled/state/hidden of an object. */
      if (idArg == nil)
        {
          fprintf(stderr, "drive_ui: props needs <object_id>\n");
          [pool release];
          return 1;
        }
      NSString *reply = SendCommand(pid, [NSString stringWithFormat: @"props\t%@", idArg]);
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"close_window"])
    {
      /* close_window <title> - close a visible window by (localized) title,
       * in-process via performClose:.  Replies "ok" or "error:...". */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      if ([positionals count] == 0)
        {
          fprintf(stderr, "drive_ui: close_window needs <title>\n");
          [pool release];
          return 1;
        }
      NSString *title = [positionals componentsJoinedByString: @" "];
      NSString *reply = SendCommand(pid, [NSString stringWithFormat: @"close_window\t%@",
        title]);
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"menu"])
    {
      /* Read-only: dump the app's main menu tree
       * (depth\tindex\ttitle\tenabled\has_submenu\tstate\tkey_equiv\
       *  modifier_mask\tshortcut). */
      NSString *reply = SendCommand(pid, @"menu");
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"menu_invoke"])
    {
      /* menu_invoke <i0> <i1> ... - perform the leaf menu item's action
       * in-process by index path; the bundle replies "ok" or "error:...". */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      if ([positionals count] == 0)
        {
          fprintf(stderr, "drive_ui: menu_invoke needs at least one index\n");
          [pool release];
          return 1;
        }
      NSMutableArray *tokens = [NSMutableArray arrayWithObject: @"menu_invoke"];
      [tokens addObjectsFromArray: positionals];
      NSString *reply = SendCommand(pid, [tokens componentsJoinedByString: @"\t"]);
      if (reply)
        {
          printf("%s", [reply UTF8String]);
          if ([reply hasPrefix: @"error:"])
            {
              [pool release];
              return 1;
            }
        }
    }
  else if ([command isEqualToString: @"localize"])
    {
      /* Read-only: translate an English string to the app's current language. */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *key = ([positionals count] > 0) ? [positionals objectAtIndex: 0] : nil;
      if (key == nil)
        {
          fprintf(stderr, "drive_ui: localize needs a string\n");
          [pool release];
          return 1;
        }
      NSString *reply = SendCommand(pid, [NSString stringWithFormat: @"localize\t%@", key]);
      if (reply) printf("%s", [reply UTF8String]);
    }
  else if ([command isEqualToString: @"menu_select"])
    {
      /* menu_select "Top/Sub" - resolve a localized title path against the
       * menu tree and perform the leaf item's action in-process. */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *path = ([positionals count] > 0) ? [positionals objectAtIndex: 0] : nil;
      int rc = MenuSelect(pid, path);
      [pool release];
      return rc;
    }
  else if ([command isEqualToString: @"assert"])
    {
      /* assert [--class C] [--text T] [--tag N] [--visible] <kind>
       *   kinds: exists | not-exists | enabled | checked | contains
       *   `contains` takes the needle in --text. */
      NSString *kind = nil, *needle = nil;
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      if ([positionals count] > 0) kind = [positionals objectAtIndex: 0];
      if ([kind isEqualToString: @"contains"]) needle = wantText;
      if (kind == nil || !([kind isEqualToString: @"exists"]
            || [kind isEqualToString: @"not-exists"]
            || [kind isEqualToString: @"enabled"]
            || [kind isEqualToString: @"checked"]
            || [kind isEqualToString: @"contains"]))
        {
          fprintf(stderr, "drive_ui: assert needs exists|not-exists|enabled|checked|contains\n");
          [pool release];
          return 1;
        }
      if ([kind isEqualToString: @"contains"] && (needle == nil || [needle length] == 0))
        {
          fprintf(stderr, "drive_ui: assert contains needs --text <needle>\n");
          [pool release];
          return 1;
        }
      int rc = AssertWidgets(pid, wantClass, wantText, wantTag, wantVisible,
                             kind, needle);
      [pool release];
      return rc;
    }
  else if ([command isEqualToString: @"wait_until"])
    {
      /* wait_until [--class C] [--text T] [--tag N] [--visible] [--timeout N] [--not-exists] */
      double timeout = 10.0;
      BOOL wantNotExists = NO;
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a isEqualToString: @"--timeout"] && i + 1 < [args count])
            { timeout = [[args objectAtIndex: ++i] doubleValue]; continue; }
          if ([a isEqualToString: @"--not-exists"]) { wantNotExists = YES; continue; }
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      if (wantText == nil && wantClass == nil && wantTag == nil && !wantVisible)
        {
          fprintf(stderr, "drive_ui: wait_until needs --text, --class, --tag or --visible\n");
          [pool release];
          return 1;
        }
      int rc = WaitUntil(pid, wantClass, wantText, wantTag, wantVisible,
                         timeout, wantNotExists);
      [pool release];
      return rc;
    }
  else if ([command isEqualToString: @"capture"])
    {
      /* capture [<path>] - screenshot the root window to a PNG. */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *path = ([positionals count] > 0) ? [positionals objectAtIndex: 0] : nil;
      int rc = CaptureScreenshot(path);
      [pool release];
      return rc;
    }
  else if ([command isEqualToString: @"click"] || [command isEqualToString: @"focus"]
           || [command isEqualToString: @"doubleclick"] || [command isEqualToString: @"rightclick"])
    {
      /* Resolve the widget's screen position and click there with the real
       * X11 pointer - the app receives genuine mouse events, so this works in
       * modal dialogs and on any widget. */
      int button = ([command isEqualToString: @"rightclick"]) ? 3 : 1;
      int count = ([command isEqualToString: @"doubleclick"]) ? 2 : 1;

      NSArray *treeRows = ParseTree(FetchTree(pid));
      NSArray *row = nil;

      if (idArg)
        row = ResolveRowByID(treeRows, idArg);
      else if (wantText)
        row = ResolveRow(treeRows, wantClass, wantText, YES);

      if (row == nil)
        {
          fprintf(stderr, "drive_ui: %s: widget not found (object_id or --text)\n", [command UTF8String]);
          [pool release];
          return 1;
        }

      NSPoint c = CenterOfRow(row);
      if (c.x == 0 && c.y == 0)
        {
          fprintf(stderr, "drive_ui: %s: widget has no usable screen_frame\n", [command UTF8String]);
          [pool release];
          return 1;
        }

      [X11Support simulateMouseMoveTo: c];
      usleep(50000);  /* let the pointer motion settle */
      for (int i = 0; i < count; i++)
        {
          [X11Support simulateClick: button];
          if (count > 1) usleep(60000);  /* let a double-click register as such */
        }
    }
  else if ([command isEqualToString: @"click_at"])
    {
      /* click_at <x> <y> [button] [count] - click a raw screen position with
       * the real X11 pointer.  Used for window chrome (close/miniaturize
       * boxes) that is drawn by the window server and has no widget row. */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      if ([positionals count] < 2)
        {
          fprintf(stderr, "drive_ui: click_at needs <x> <y>\n");
          [pool release];
          return 1;
        }
      double x = [[positionals objectAtIndex: 0] doubleValue];
      double y = [[positionals objectAtIndex: 1] doubleValue];
      int button = ([positionals count] > 2) ? [[positionals objectAtIndex: 2] intValue] : 1;
      int count = ([positionals count] > 3) ? [[positionals objectAtIndex: 3] intValue] : 1;
      NSPoint c = NSMakePoint(x, y);
      [X11Support simulateMouseMoveTo: c];
      usleep(50000);  /* let the pointer motion settle */
      for (int i = 0; i < count; i++)
        {
          [X11Support simulateClick: button];
          if (count > 1) usleep(60000);
        }
    }
  else if ([command isEqualToString: @"hover"])
    {
      /* hover <object_id> - move the real pointer over the widget's center
       * without clicking (mouse-over effects, tooltips, hover menus). */
      if (idArg == nil)
        {
          fprintf(stderr, "drive_ui: hover needs <object_id>\n");
          [pool release];
          return 1;
        }
      NSArray *row = ResolveRowByID(ParseTree(FetchTree(pid)), idArg);
      if (row == nil)
        {
          fprintf(stderr, "drive_ui: hover: widget not found\n");
          [pool release];
          return 1;
        }
      NSPoint c = CenterOfRow(row);
      if (c.x == 0 && c.y == 0)
        {
          fprintf(stderr, "drive_ui: hover: widget has no usable screen_frame\n");
          [pool release];
          return 1;
        }
      [X11Support simulateMouseMoveTo: c];
      usleep(40000);  /* let the pointer motion settle */
    }
  else if ([command isEqualToString: @"scroll"])
    {
      /* scroll [<object_id>] <up|down|left|right> [amount]
       * With an object_id the pointer is first moved over the widget, so a
       * scrollable control scrolls itself; without one the wheel turns at the
       * current pointer position. */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *target = nil;
      if ([positionals count] > 0 && [[positionals objectAtIndex: 0] hasPrefix: @"objc:"])
        {
          target = [positionals objectAtIndex: 0];
          [positionals removeObjectAtIndex: 0];
        }
      if ([positionals count] == 0)
        {
          fprintf(stderr, "drive_ui: scroll needs a direction (up/down/left/right)\n");
          [pool release];
          return 1;
        }
      NSString *dir = [positionals objectAtIndex: 0];
      int amount = 1;
      if ([positionals count] > 1) amount = atoi([[positionals objectAtIndex: 1] UTF8String]);
      if (amount <= 0) amount = 1;

      if (target)
        {
          NSArray *row = ResolveRowByID(ParseTree(FetchTree(pid)), target);
          if (row == nil)
            {
              fprintf(stderr, "drive_ui: scroll: widget not found\n");
              [pool release];
              return 1;
            }
          NSPoint c = CenterOfRow(row);
          if (c.x == 0 && c.y == 0)
            {
              fprintf(stderr, "drive_ui: scroll: widget has no usable screen_frame\n");
              [pool release];
              return 1;
            }
          [X11Support simulateMouseMoveTo: c];
          usleep(40000);
        }
      [X11Support simulateScrollWheel: dir count: amount];
    }
  else if ([command isEqualToString: @"drag"])
    {
      /* drag <object_id> <dx> <dy> - press button 1 at the widget's center and
       * drag by the given pixel offset (moving windows, sliders, scrollbars,
       * drag-and-drop). */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      if ([positionals count] < 3)
        {
          fprintf(stderr, "drive_ui: drag needs <object_id> <dx> <dy>\n");
          [pool release];
          return 1;
        }
      NSString *target = [positionals objectAtIndex: 0];
      double dx = atof([[positionals objectAtIndex: 1] UTF8String]);
      double dy = atof([[positionals objectAtIndex: 2] UTF8String]);

      NSArray *row = ResolveRowByID(ParseTree(FetchTree(pid)), target);
      if (row == nil)
        {
          fprintf(stderr, "drive_ui: drag: widget not found\n");
          [pool release];
          return 1;
        }
      NSPoint c = CenterOfRow(row);
      if (c.x == 0 && c.y == 0)
        {
          fprintf(stderr, "drive_ui: drag: widget has no usable screen_frame\n");
          [pool release];
          return 1;
        }
      [X11Support simulateMouseMoveTo: c];
      usleep(40000);
      [X11Support simulateDragBy: NSMakePoint(dx, dy)];
    }
  else if ([command isEqualToString: @"press"])
    {
      /* Press Return via a real X11 key event. */
      [X11Support setFocusToPID: pid];
      [X11Support simulateChordWithModifiers: [NSArray array] key: @"Return"];
    }
  else if ([command isEqualToString: @"sendkeys"])
    {
      /* sendkeys <text> - type text into the currently focused field without
       * clicking first (used by run_uitest `type "..."`, which types into the
       * focused editable control). */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *value = ([positionals count] > 0) ? [positionals objectAtIndex: 0] : nil;
      if (value == nil)
        {
          fprintf(stderr, "drive_ui: sendkeys needs <text>\n");
          [pool release];
          return 1;
        }
      [X11Support setFocusToPID: pid];
      for (NSUInteger i = 0; i < [value length]; i++)
        {
          NSString *ch = [value substringWithRange: NSMakeRange(i, 1)];
          [X11Support simulateKeyStroke: ch];
        }
    }
  else if ([command isEqualToString: @"clear"])
    {
      /* Click the field, select all, then delete - clears an editable area. */
      NSArray *treeRows = ParseTree(FetchTree(pid));
      NSArray *row = nil;
      if (idArg)
        row = ResolveRowByID(treeRows, idArg);
      else if (wantText)
        row = ResolveRow(treeRows, wantClass, wantText, YES);
      if (row == nil)
        {
          fprintf(stderr, "drive_ui: clear: widget not found\n");
          [pool release];
          return 1;
        }
      NSPoint c = CenterOfRow(row);
      if (c.x == 0 && c.y == 0)
        {
          fprintf(stderr, "drive_ui: clear: widget has no usable screen_frame\n");
          [pool release];
          return 1;
        }
      [X11Support simulateMouseMoveTo: c];
      usleep(50000);
      [X11Support simulateClick: 1];
      usleep(50000);
      /* Select all (GNUstep Command is Left Alt) then delete. */
      [X11Support simulateChordWithModifiers: [NSArray arrayWithObject: @"alt"] key: @"a"];
      usleep(50000);
      [X11Support simulateChordWithModifiers: [NSArray array] key: @"BackSpace"];
    }
  else if ([command isEqualToString: @"chord"])
    {
      /* chord <mods> <key>  e.g. "chord control c" or "chord shift Return" */
      NSMutableArray *mods = [NSMutableArray array];
      NSString *key = nil;
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if (i + 1 < [args count] && (i + 2 == [args count])) key = [args objectAtIndex: i + 1];
          else if (![a isEqualToString: command]) [mods addObject: a];
        }
      if (key == nil && [mods count] > 0) { key = [mods lastObject]; [mods removeLastObject]; }
      if (key == nil)
        {
          fprintf(stderr, "drive_ui: chord needs <mods> <key>\n");
          [pool release];
          return 1;
        }
      [X11Support setFocusToPID: pid];
      [X11Support simulateChordWithModifiers: mods key: key];
    }
  else if ([command isEqualToString: @"type"])
    {
      /* Click the target field (to focus it), then type the text as real key
       * events.  This is exactly what a user would do, so it works on any
       * text control (NSTextField, NSTextView, CompletionField, ...). */
      NSMutableArray *positionals = [NSMutableArray array];
      for (NSUInteger i = 1; i < [args count]; i++)
        {
          NSString *a = [args objectAtIndex: i];
          if ([a hasPrefix: @"--"]) { i++; continue; }
          [positionals addObject: a];
        }
      NSString *value = nil, *label = nil;
      NSString *target = nil;
      if ([positionals count] >= 2)
        {
          NSString *first = [positionals objectAtIndex: 0];
          if ([first hasPrefix: @"objc:"]) { target = first; }
          else { label = first; }
          value = [positionals objectAtIndex: [positionals count] - 1];
        }
      if (value == nil)
        {
          fprintf(stderr, "drive_ui: type needs <object_id> <text> or --text <label> <text>\n");
          [pool release];
          return 1;
        }

      NSArray *treeRows = ParseTree(FetchTree(pid));
      NSArray *row = nil;
      if (target)
        row = ResolveRowByID(treeRows, target);
      else
        {
          NSString *needle = label ? label : wantText;
          if (needle == nil)
            {
              fprintf(stderr, "drive_ui: type needs a target object_id or label\n");
              [pool release];
              return 1;
            }
          row = ResolveRow(treeRows, wantClass, needle, YES);
        }

      if (row == nil)
        {
          fprintf(stderr, "drive_ui: type: widget not found\n");
          [pool release];
          return 1;
        }

      NSPoint c = CenterOfRow(row);
      if (c.x == 0 && c.y == 0)
        {
          fprintf(stderr, "drive_ui: type: widget has no usable screen_frame\n");
          [pool release];
          return 1;
        }

      /* Focus the field with a real click, then type. */
      [X11Support setFocusToPID: pid];
      [X11Support simulateMouseMoveTo: c];
      usleep(50000);
      [X11Support simulateClick: 1];
      usleep(50000);

      for (NSUInteger i = 0; i < [value length]; i++)
        {
          NSString *ch = [value substringWithRange: NSMakeRange(i, 1)];
          [X11Support simulateKeyStroke: ch];
        }
    }
  else
    {
      fprintf(stderr, "drive_ui: unknown command '%s'\n", [command UTF8String]);
      Usage();
      [pool release];
      return 1;
    }

  [pool release];
  return 0;
}
