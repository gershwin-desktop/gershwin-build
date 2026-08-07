/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Executor + QueryEngine for the GNUstep UI Automation UITest (see UITest.h).
 *
 * The QueryEngine is the only component that talks to drive_ui / X11; every
 * interaction is a spawned `drive_ui` subprocess.  The executor walks the AST
 * and translates each UITestCommand into a semantic query answered by the engine
 * - no GNUstep-specific logic lives here.
 *
 * drive_ui takes a PID; the engine resolves an app name to that PID by
 * scanning the /tmp/driveui.<pid>.sock sockets and asking each for its app
 * name via the read-only `app` command added to the DriveUI bundle.
 */

#import "UITest.h"
#import <signal.h>
#import <unistd.h>

@implementation UITestQueryEngine

/* Node in the menu-title trie built from the DriveUI `menu` reply.  `raw` is
 * the whole tab-separated line of the item, kept so assertions can read the
 * state (checkmark), enabled flag and shortcut columns. */
typedef struct DDSMenuNode { NSString *title; int index; struct DDSMenuNode **kids; int nkids; NSString *raw; } DDSMenuNode;

static void DDSMenuNodeFree(DDSMenuNode *n)
{
  if (!n) return;
  for (int i = 0; i < n->nkids; i++) DDSMenuNodeFree(n->kids[i]);
  free(n->kids);
  [n->title release];
  [n->raw release];
  free(n);
}

- (id)initWithDriveTool:(NSString *)toolPath
{
  if ((self = [super init]))
    {
      pid_ = 0;
      appName_ = nil;
      driveTool_ = [toolPath copy];
      localizeCache_ = [[NSMutableDictionary alloc] init];
    }
  return self;
}
- (void)dealloc
{
  [appName_ release];
  [driveTool_ release];
  [localizeCache_ release];
  [super dealloc];
}
- (int)pid { return pid_; }
- (NSString *)appName { return appName_; }

/* Run a drive_ui invocation, wait for it, and return its stdout (nil if the
 * exit status was non-zero). */
- (NSString *)runCollect:(NSArray *)argv error:(NSString **)err
{
  return [self runTool: driveTool_ argv: argv error: err];
}

/* Run an arbitrary executable, wait for it, and return its stdout (nil if the
 * exit status was non-zero).
 *
 * The wait is bounded: a live app whose DriveUI socket server has a full
 * accept backlog can block drive_ui's connect() indefinitely, which would
 * otherwise hang a script (and the harness) forever.  A stalled subprocess is
 * terminated after the timeout and reported as an error.
 *
 * Each call runs in its own autorelease pool: drive_ui is spawned per query,
 * and a polling command (e.g. wait until) can make hundreds of queries, so
 * the pipes must be released immediately or the script exhausts the file
 * descriptor limit (EMFILE). */
- (NSString *)runTool:(NSString *)path argv:(NSArray *)argv error:(NSString **)err
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  NSString *result = nil;

  const double kRunToolTimeout = 30.0;
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath: path];
  [task setArguments: argv];
  NSPipe *outPipe = [NSPipe pipe];
  NSPipe *errPipe = [NSPipe pipe];
  [task setStandardOutput: outPipe];
  [task setStandardError: errPipe];
  [task launch];

  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: kRunToolTimeout];
  while ([task isRunning] && [[NSDate date] compare: deadline] == NSOrderedAscending)
    {
      usleep(100000);
    }
  BOOL timedOut = [task isRunning];
  if (timedOut)
    {
      [task terminate];
      [task waitUntilExit];
    }

  NSData *outData = nil;
  NSFileHandle *outHandle = [outPipe fileHandleForReading];
  NSFileHandle *errHandle = [errPipe fileHandleForReading];
  outData = [outHandle readDataToEndOfFile];
  NSString *out = [[[NSString alloc] initWithData: outData
    encoding: NSUTF8StringEncoding] autorelease];
  if (timedOut)
    {
      if (err)
        *err = [NSString stringWithFormat: @"%s timed out (stalled DriveUI socket?)",
          [[path lastPathComponent] UTF8String]];
      [task release];
      result = nil;
    }
  else if ([task terminationStatus] != 0)
    {
      NSData *errData = [errHandle readDataToEndOfFile];
      NSString *stderrStr = [[[NSString alloc] initWithData: errData
        encoding: NSUTF8StringEncoding] autorelease];
      if (err && [stderrStr length] > 0)
        *err = [stderrStr stringByTrimmingCharactersInSet:
          [NSCharacterSet newlineCharacterSet]];
      [task release];
      result = nil;
    }
  else
    {
      result = out;
      [task release];
    }

  /* Close the pipe descriptors now.  The pool drain below releases the pipes,
   * but the descriptors must not linger until then: a polling command can
   * spawn hundreds of drive_ui subprocesses and exhaust the fd limit
   * (EMFILE) if each one's pipes stay open. */
  [outHandle closeFile];
  [errHandle closeFile];

  [result retain];
  [pool drain];
  return [result autorelease];
}

/* Build the --pid argv for the current target app. */
- (NSArray *)argvForSubcommand:(NSString *)subcommand
{
  return [NSArray arrayWithObjects:
    [NSString stringWithFormat: @"--pid=%d", pid_], subcommand, nil];
}

/* Resolve an app name to a pid by scanning the /tmp/driveui.<pid>.sock
 * sockets (each answers the read-only `app` command).  Sockets whose pid is no
 * longer alive are skipped without connecting, so a pile of stale sockets from
 * long-dead apps cannot make activation take seconds per socket. */
- (BOOL)resolveApplication:(NSString *)name error:(NSString **)err
{
  NSString *tmp = @"/tmp";
  NSArray *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:
    tmp error: nil];
  NSInteger bestDist = NSIntegerMax, bestPid = 0;
  for (NSString *e in entries)
    {
      if (![e hasPrefix: @"driveui."] || ![e hasSuffix: @".sock"]) continue;
      NSString *pidStr = [e substringWithRange: NSMakeRange(8,
        [e length] - 8 - [@".sock" length])];
      int maybePid = [pidStr intValue];
      if (maybePid <= 0) continue;
      if (kill(maybePid, 0) != 0) continue;  /* stale socket, owner gone */
      NSString *out = [self runCollect: [NSArray arrayWithObjects:
        [NSString stringWithFormat: @"--pid=%d", maybePid], @"app", nil]
        error: nil];
      if (!out) continue;
      NSString *found = [out stringByTrimmingCharactersInSet:
        [NSCharacterSet newlineCharacterSet]];
      if ([found length] == 0) continue;
      if ([found isEqualToString: name])
        {
          pid_ = maybePid;
          appName_ = [name copy];
          return YES;
        }
      if ([found hasPrefix: name])
        {
          int dist = [found length] - [name length];
          if (dist < bestDist) { bestDist = dist; bestPid = maybePid; }
        }
    }
  if (bestPid > 0)
    {
      pid_ = bestPid;
      appName_ = [name copy];
      return YES;
    }
  if (err) *err = [NSString stringWithFormat:
    @"application '%@' not running (DriveUI bundle not loaded?)", name];
  return NO;
}

/* Apply an error; callers set *err with a human message. */
static void SetErr(NSString **err, NSString *m)
{
  if (err) *err = m;
}

/* Translate an English string to the app's current language, so UITest scripts
 * work regardless of locale.  Reads the app's own .strings via the bundle's
 * `localize` command (cached; falls back to the original string). */
- (NSString *)localizeString:(NSString *)english
{
  if (english == nil || [english length] == 0 || pid_ == 0) return english;
  NSString *cached = [localizeCache_ objectForKey: english];
  if (cached) return cached;
  /* The app can be briefly busy (e.g. a browsing viewer laying out icons
   * after a view-mode switch), which makes the 1s read timeout fire even
   * though the translation exists.  Retry so a transient busy spell does not
   * leave the English string cached as "the translation". */
  NSString *localized = nil;
  for (int attempt = 0; attempt < 8; attempt++)
    {
      NSString *out = [self runCollect: [NSArray arrayWithObjects:
        [NSString stringWithFormat: @"--pid=%d", pid_], @"localize", english, nil]
        error: nil];
      if (out != nil)
        {
          localized = [out stringByTrimmingCharactersInSet:
            [NSCharacterSet newlineCharacterSet]];
          break;
        }
      usleep (250000);
    }
  if (localized == nil || [localized length] == 0) localized = english;
  [localizeCache_ setObject: localized forKey: english];
  return localized;
}

/* Case-insensitive substring match that also accepts the localized spelling of
 * the needle, so a UITest script can name a title/button in English or German and
 * still match a German-running UI. */
- (BOOL)title:(NSString *)title matches:(NSString *)segOrEnglish
{
  if ([title rangeOfString: segOrEnglish options: NSCaseInsensitiveSearch].location != NSNotFound)
    return YES;
  NSString *localized = [self localizeString: segOrEnglish];
  if (![localized isEqualToString: segOrEnglish] &&
      [title rangeOfString: localized options: NSCaseInsensitiveSearch].location != NSNotFound)
    return YES;
  return NO;
}

- (BOOL)activateXWindow:(NSString *)title error:(NSString **)err
{
  if (title == nil || [title length] == 0)
    { SetErr(err, @"activate xwindow needs a title"); return NO; }
  if (pid_ == 0)
    {
      /* No DriveUI target app; still need a pid for the argv.  Use any pid
       * (the xactivate command ignores it and scans the X display). */
      pid_ = [[NSProcessInfo processInfo] processIdentifier];
    }
  NSString *reply = [self runCollect: [NSArray arrayWithObjects:
    [NSString stringWithFormat: @"--pid=%d", pid_],
    @"xactivate", title, nil] error: err];
  return reply != nil;
}

/* Locate the .app bundle for a GNUstep application by searching the standard
 * install locations.  The binary lives inside the .app named after the app.
 * Falls back to a bare executable on PATH or in /usr/local/bin (for non-GNUstep
 * apps like GTK tools that have no .app bundle). */
- (NSString *)appPathForName:(NSString *)name
{
  NSArray *roots = [NSArray arrayWithObjects:
    @"/System/Applications/Utilities",
    @"/System/Applications",
    @"/System/Library/CoreServices/Applications",
    @"/System/Library/CoreServices/Applications/Utilities",
    @"/Local/Applications",
    [@"~/Applications" stringByExpandingTildeInPath],
    @"/Developer/Applications", nil];
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *root in roots)
    {
      NSString *app = [root stringByAppendingPathComponent:
        [name stringByAppendingString: @".app"]];
      BOOL isDir = NO;
      if ([fm fileExistsAtPath: app isDirectory: &isDir] && isDir)
        return app;
    }
  /* Bare executable on the conventional paths or PATH. */
  NSArray *binRoots = [NSArray arrayWithObjects:
    @"/usr/local/bin", @"/usr/bin", @"/bin", nil];
  for (NSString *root in binRoots)
    {
      NSString *bin = [root stringByAppendingPathComponent: name];
      if ([fm isExecutableFileAtPath: bin])
        return bin;
    }
  return nil;
}

/* Launch a GNUstep application by name and wait until its DriveUI socket
 * appears (resolveApplication: succeeds). */
- (BOOL)launchApplication:(NSString *)name error:(NSString **)err
{
  if (name == nil || [name length] == 0)
    { SetErr(err, @"launch application needs a name"); return NO; }
  if ([self resolveApplication: name error: nil])
    return YES;               /* already running - idempotent */
  NSString *path = [self appPathForName: name];
  if (path == nil)
    { SetErr(err, [NSString stringWithFormat: @"no %@.app found", name]); return NO; }
  NSString *binary = path;
  if ([[path pathExtension] isEqualToString: @"app"])
    binary = [path stringByAppendingPathComponent: name];
  if (![[NSFileManager defaultManager] isExecutableFileAtPath: binary])
    { SetErr(err, [NSString stringWithFormat: @"%@ is not executable", binary]); return NO; }
  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath: binary];
  [task setArguments: [NSArray array]];
  @try
    {
      [task launch];
    }
  @catch (NSException *e)
    {
      [task release];
      SetErr(err, [NSString stringWithFormat: @"failed to launch %@: %@", binary, [e reason]]);
      return NO;
    }
  pid_t launchedPid = [task processIdentifier];
  [task release];
  /* Wait for the app to be reachable.  GNUstep apps expose a DriveUI socket
   * (resolveApplication:); non-GNUstep apps (GTK etc.) never do, so a running
   * process is enough for them. */
  for (int i = 0; i < 75; i++)
    {
      if ([self resolveApplication: name error: nil]) return YES;
      if (kill(launchedPid, 0) != 0)
        { SetErr(err, [NSString stringWithFormat: @"'%@' exited during startup", name]); return NO; }
      if ([[NSFileManager defaultManager] fileExistsAtPath: binary]
          && [self appIsGNUstepApp: name] == NO)
        return YES;           /* non-GNUstep app: running process is enough */
      usleep (200000);
    }
  SetErr(err, [NSString stringWithFormat: @"'%@' did not start (DriveUI socket missing)", name]);
  return NO;
}

/* Does the named app load the DriveUI bundle (i.e. is it a GNUstep app that
 * will expose a DriveUI socket)?  Apps with a .app bundle in the standard
 * locations are treated as GNUstep; bare executables (/usr/local/bin/viking)
 * are not. */
- (BOOL)appIsGNUstepApp:(NSString *)name
{
  NSString *path = [self appPathForName: name];
  return (path != nil && [[path pathExtension] isEqualToString: @"app"]);
}

/* Does a snapshot row's class satisfy the UITest role's class filter?  A subclass
 * name (AboutWindow, GWDesktopWindow) does not contain "NSWindow", so window
 * roles match any class ending in "Window" as well. */
- (BOOL)class:(NSString *)lineClass matchesRoleClass:(NSString *)wantClass
{
  if (wantClass == nil || [wantClass length] == 0) return YES;
  if ([lineClass rangeOfString: wantClass].location != NSNotFound) return YES;
  /* A search field is an NSTextField subclass under a different name; let
   * scripts target it as a plain textfield. */
  if ([lineClass isEqualToString: @"NSSearchField"] &&
      [wantClass isEqualToString: @"NSTextField"]) return YES;
  if ([wantClass isEqualToString: @"NSWindow"] &&
      [lineClass hasSuffix: @"Window"]) return YES;
  return NO;
}

/* Raise + focus the app's main window by clicking it (activate).  The app is
 * already the resolved PID target; raising its frontmost window is best-effort
 * (some apps, e.g. a desktop, have no clickable title bar, and window facades
 * may not carry a screen frame). */
- (BOOL)activate:(NSString **)err
{
  NSArray *argv = [self argvForSubcommand: @"get_full_tree"];
  NSString *tree = [self runCollect: argv error: err];
  if (!tree) return NO;
  NSString *target = nil;
  for (NSString *line in [tree componentsSeparatedByString: @"\n"])
    {
      NSArray *f = [line componentsSeparatedByString: @"\t"];
      if ([f count] < 8) continue;
      if ([[f objectAtIndex: 6] isEqualToString: @"1"]) continue;   /* hidden */
      NSString *sf = [f objectAtIndex: 5];
      if ([sf length] == 0) continue;                              /* no frame to click */
      target = [f objectAtIndex: 7];
      break;
    }
  /* Nothing clickable to raise - the app is already our PID target, so this is
   * fine; the subsequent commands drive it directly. */
  if (target == nil) return YES;
  return [self clickObjectID: target button: 1 count: 1 error: err];
}

- (BOOL)focusMainWindow:(NSString **)err
{
  return [self activate: err];
}

/* Build arglist for find/click against a role+title. */
- (NSArray *)resolveArgsRole:(UITestRole)role title:(NSString *)title
{
  NSMutableArray *args = [NSMutableArray array];
  NSString *cls = UITestRoleClassName(role);
  if (cls) [args addObjectsFromArray: [NSArray arrayWithObjects: @"--class", cls, nil]];
  if (title)
    [args addObjectsFromArray: [NSArray arrayWithObjects: @"--text", title, nil]];
  return args;
}

/* Locate a matching widget's object_id via drive_ui find_widgets / get tree.
 * Returns the object_id line (field 8) or nil. */
- (NSString *)objectIDForRole:(UITestRole)role title:(NSString *)title
                  error:(NSString **)err
{
  NSMutableArray *argv = [NSMutableArray arrayWithArray:
    [self argvForSubcommand: @"get_full_tree"]];
  NSString *out = [self runCollect: argv error: err];
  if (!out) return nil;
  NSString *cls = UITestRoleClassName(role);
  for (NSString *line in [out componentsSeparatedByString: @"\n"])
    {
      NSArray *f = [line componentsSeparatedByString: @"\t"];
      if ([f count] < 8) continue;
      if ([[f objectAtIndex: 6] isEqualToString: @"1"]) continue;
      if (![self class: [f objectAtIndex: 1] matchesRoleClass: cls]) continue;
      if (title && ![self title: [f objectAtIndex: 2] matches: title]) continue;
      return [f objectAtIndex: 7];
    }
  SetErr(err, [NSString stringWithFormat: @"no widget matching role/title"]);
  return nil;
}

/* Return the on-screen frame string of the first visible window whose title
 * matches, e.g. "{x = 146; y = 630; width = 342; height = 179}", or nil.  The
 * tree's screen_frame column (index 5) carries the window's position on the
 * root window, which is what `assert window ... frame constant` compares. */
- (NSString *)frameOfWindowTitle:(NSString *)title error:(NSString **)err
{
  NSMutableArray *argv = [NSMutableArray arrayWithArray:
    [self argvForSubcommand: @"get_full_tree"]];
  NSString *out = [self runCollect: argv error: err];
  if (!out) return nil;
  for (NSString *line in [out componentsSeparatedByString: @"\n"])
    {
      NSArray *f = [line componentsSeparatedByString: @"\t"];
      if ([f count] < 8) continue;
      if ([[f objectAtIndex: 6] isEqualToString: @"1"]) continue;   /* hidden */
      if (![self class: [f objectAtIndex: 1] matchesRoleClass: @"NSWindow"]) continue;
      if (title && ![self title: [f objectAtIndex: 2] matches: title]) continue;
      NSString *sf = [f objectAtIndex: 5];
      if ([sf length] == 0) continue;                              /* no frame */
      return sf;
    }
  SetErr(err, [NSString stringWithFormat: @"no visible window matching '%@'",
    title ?: @"(any)"]);
  return nil;
}

/* Close a visible window by its (localized) title.  The bundle performs the
 * close in-process via performClose:, so it works even when the window was
 * never made key (the Close menu item would be disabled). */
- (BOOL)closeWindowTitle:(NSString *)title error:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no application target"); return NO; }
  if (title == nil || [title length] == 0)
    { SetErr(err, @"close window needs a title"); return NO; }
  NSMutableArray *argv = [NSMutableArray arrayWithArray:
    [self argvForSubcommand: @"close_window"]];
  [argv addObject: title];
  NSString *reply = [self runCollect: argv error: err];
  if (!reply) return NO;
  if ([reply hasPrefix: @"error:"])
    {
      SetErr(err, [reply stringByTrimmingCharactersInSet:
        [NSCharacterSet newlineCharacterSet]]);
      return NO;
    }
  return YES;
}

- (BOOL)clickRole:(UITestRole)role title:(NSString *)title
          button:(int)button count:(int)count error:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no target application"); return NO; }
  NSString *objID = [self objectIDForRole: role title: title error: err];
  if (!objID) return NO;
  return [self clickObjectID: objID button: button count: count error: err];
}

/* Return the title of the app's current modal window, or nil if none.  Lets
 * `wait until modal`, `assert modal` and `if modal` answer the "is a dialog
 * blocking right now" question without depending on the tree or on button
 * positions. */
- (NSString *)modalWindowTitle:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no application target"); return nil; }
  NSString *reply = nil;
  for (int attempt = 0; attempt < 8; attempt++)
    {
      reply = [self runCollect: [self argvForSubcommand: @"modal"]
        error: (attempt == 7) ? err : nil];
      if (reply != nil) break;
      usleep (250000);
    }
  if (!reply) return nil;
  reply = [reply stringByTrimmingCharactersInSet:
    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([reply isEqualToString: @"none"]) return nil;
  NSRange bar = [reply rangeOfString: @"|"];
  if (bar.location != NSNotFound)
    return [reply substringFromIndex: bar.location + 1];
  return reply;
}

/* Invoke a button of the current modal window by title ("OK", ...) or
 * "default" for the Return-equivalent button (drive_ui invoke_modal_button).
 * The 1s read timeout can fire while the modal alert's pulsing animation keeps
 * the app busy even though the action ran, so a timed-out or "no modal window"
 * reply is retried/treated as success. */
- (BOOL)invokeModalButton:(NSString *)which error:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no application target"); return NO; }
  if (which == nil || [which length] == 0) which = @"default";
  NSMutableArray *argv = [NSMutableArray arrayWithArray:
    [self argvForSubcommand: @"invoke_modal_button"]];
  [argv addObject: which];
  for (int attempt = 0; attempt < 3; attempt++)
    {
      NSString *reply = [self runCollect: argv error: err];
      if (reply == nil)
        {
          /* Timed out while the app was busy; the action may still have run. */
          usleep (500000);
          continue;
        }
      if ([reply hasPrefix: @"error:"])
        {
          if ([reply rangeOfString: @"no modal window"].location != NSNotFound)
            return YES;         /* already dismissed - success */
          SetErr(err, [reply stringByTrimmingCharactersInSet:
            [NSCharacterSet newlineCharacterSet]]);
          return NO;
        }
      return YES;
    }
  if (err && *err == nil)
    SetErr(err, @"invoke button timed out (app busy)");
  return NO;
}

/* Trigger an action on Menu.app's global menu bar (simulates clicking a menu
 * item).  Menu.app runs the global menu for the frontmost app; the UITest target
 * app just needs to be active.  Returns NO if Menu.app isn't running or the
 * item path isn't found. */
- (BOOL)triggerGlobalMenuPath:(NSString *)path error:(NSString **)err
{
  if (path == nil || [path length] == 0)
    { SetErr(err, @"select global menu needs a path (use \"Top/Sub\")"); return NO; }
  int menuPid = 0;
  NSString *menuName = @"Menu";
  NSString *tmp = @"/tmp";
  NSArray *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:
    tmp error: nil];
  for (NSString *e in entries)
    {
      if (![e hasPrefix: @"driveui."] || ![e hasSuffix: @".sock"]) continue;
      NSString *pidStr = [e substringWithRange: NSMakeRange(8,
        [e length] - 8 - [@".sock" length])];
      int maybePid = [pidStr intValue];
      if (maybePid <= 0) continue;
      if (kill(maybePid, 0) != 0) continue;
      NSString *a = [self runCollect: [NSArray arrayWithObjects:
        [NSString stringWithFormat: @"--pid=%d", maybePid], @"app", nil] error: nil];
      NSString *found = a ? [a stringByTrimmingCharactersInSet:
        [NSCharacterSet newlineCharacterSet]] : @"";
      if ([found isEqualToString: menuName])
        { menuPid = maybePid; break; }
    }
  if (menuPid <= 0)
    { SetErr(err, @"Menu.app is not running"); return NO; }
  NSArray *argv = [NSArray arrayWithObjects:
    [NSString stringWithFormat: @"--pid=%d", menuPid],
    @"menu_trigger", path, nil];
  NSString *reply = [self runCollect: argv error: err];
  if (!reply) return NO;
  if ([reply hasPrefix: @"error:"])
    {
      SetErr(err, [reply stringByTrimmingCharactersInSet:
        [NSCharacterSet newlineCharacterSet]]);
      return NO;
    }
  return YES;
}

/* Select a menu item by its title path, e.g. "About This Computer" or
 * "File/Open".  Resolution is in-process (the app's own main menu), so it is
 * fast and does not depend on the on-screen menu bar or X11 timing.
 *
 * The bundle's `menu` command returns one line per item:
 *   depth\tindex\ttitle\tenabled\thas_submenu
 * with submenu items listed directly after their parent at depth+1.  We build
 * a tree of (title -> index) and walk the UITest path through it; the resulting
 * index path is passed to `menu_invoke`, which performs the leaf item's
 * action (exactly what a real menu selection does). */
- (BOOL)selectMenuPath:(NSString *)path error:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no target application"); return NO; }
  if (path == nil || [path length] == 0)
    { SetErr(err, @"select menu needs a path (use \"Top/Sub\")"); return NO; }

  NSString *tree = [self runCollect: [self argvForSubcommand: @"menu"]
                              error: err];
  if (!tree) return NO;

  DDSMenuNode *root = calloc(1, sizeof(DDSMenuNode));
  root->title = @"";
  root->index = -1;

  /* parents[d] = the node whose submenu items sit at depth d.  parents[0] is
   * the virtual root holding the top-level bar items; a node with a submenu
   * becomes the parent of its children at depth+1.  Because the serialized
   * lines are ordered depth-first, setting parents[depth+1] when we see a
   * submenu node always yields the correct ancestor for the lines that follow.
   * max depth is bounded by the menu; 64 is far deeper than any real one. */
  DDSMenuNode *parents[64];
  memset(parents, 0, sizeof(parents));
  parents[0] = root;

  NSArray *lines = [tree componentsSeparatedByString: @"\n"];
  BOOL anyItem = NO;
  for (NSString *line in lines)
    {
      NSArray *f = [line componentsSeparatedByString: @"\t"];
      if ([f count] < 5) continue;
      int depth = [[f objectAtIndex: 0] intValue];
      int index = [[f objectAtIndex: 1] intValue];
      NSString *title = [f objectAtIndex: 2];
      BOOL hasSubmenu = [[f objectAtIndex: 4] isEqualToString: @"1"];
      if (depth < 0 || depth >= 64) continue;
      anyItem = YES;

      DDSMenuNode *parent = parents[depth];
      if (parent == NULL)
        {
          /* Depth jumped in a way we cannot interpret; skip this item. */
          continue;
        }
      parent->kids = realloc(parent->kids, sizeof(DDSMenuNode *) *
          (parent->nkids + 1));
      DDSMenuNode *node = calloc(1, sizeof(DDSMenuNode));
      node->title = [title copy];
      node->index = index;
      node->raw = [line copy];
      parent->kids[parent->nkids++] = node;

      if (hasSubmenu && depth + 1 < 64)
        parents[depth + 1] = node;
    }

  if (!anyItem)
    {
      /* A busy app can answer the menu query slowly (the 1s read timeout),
       * which surfaces as an empty dump - e.g. right after a view-mode switch
       * the browsing viewer is busy laying out icons.  Poll until the menu
       * comes back (up to ~10s); the menu is read-only and the poll is cheap. */
      for (int attempt = 0; attempt < 40 && !anyItem; attempt++)
        {
          usleep (250000);
          NSString *retryTree = [self runCollect:
            [self argvForSubcommand: @"menu"] error: nil];
          if (!retryTree) continue;
          DDSMenuNodeFree(root);
          root = calloc(1, sizeof(DDSMenuNode));
          root->title = @"";
          root->index = -1;
          memset(parents, 0, sizeof(parents));
          parents[0] = root;
          anyItem = NO;
          for (NSString *line in [retryTree componentsSeparatedByString: @"\n"])
            {
              NSArray *f = [line componentsSeparatedByString: @"\t"];
              if ([f count] < 5) continue;
              int depth = [[f objectAtIndex: 0] intValue];
              int index = [[f objectAtIndex: 1] intValue];
              NSString *title = [f objectAtIndex: 2];
              BOOL hasSubmenu = [[f objectAtIndex: 4] isEqualToString: @"1"];
              if (depth < 0 || depth >= 64) continue;
              anyItem = YES;
              DDSMenuNode *parent = parents[depth];
              if (parent == NULL) continue;
              parent->kids = realloc(parent->kids, sizeof(DDSMenuNode *) *
                  (parent->nkids + 1));
              DDSMenuNode *node = calloc(1, sizeof(DDSMenuNode));
              node->title = [title copy];
              node->index = index;
              node->raw = [line copy];
              parent->kids[parent->nkids++] = node;
              if (hasSubmenu && depth + 1 < 64)
                parents[depth + 1] = node;
            }
        }
    }

  if (!anyItem)
    {
      SetErr(err, @"application has no menu (DriveUI menu unsupported?)");
      DDSMenuNodeFree(root);
      return NO;
    }

  /* Walk the UITest path (split on "/") through the tree. */
  NSArray *segs = [path componentsSeparatedByString: @"/"];
  NSMutableArray *indices = [NSMutableArray array];
  DDSMenuNode *current = root;
  BOOL found = YES;
  for (NSString *seg in segs)
    {
      if ([seg length] == 0) continue;
      DDSMenuNode *match = NULL;
      for (int i = 0; i < current->nkids; i++)
        {
          DDSMenuNode *k = current->kids[i];
          if ([self title: k->title matches: seg])
            { match = k; break; }
        }
      if (match == NULL) { found = NO; break; }
      [indices addObject: @(match->index)];
      current = match;
    }

  if (!found || [indices count] == 0)
    {
      SetErr(err, [NSString stringWithFormat:
        @"menu item '%@' not found in '%@'", path, appName_ ?: @"app"]);
      DDSMenuNodeFree(root);
      return NO;
    }
  DDSMenuNodeFree(root);

  /* Perform the action by index path (menu_invoke takes integer args). */
  NSMutableArray *argv = [NSMutableArray arrayWithArray:
    [self argvForSubcommand: @"menu_invoke"]];
  for (NSNumber *idx in indices)
    [argv addObject: [idx stringValue]];
  NSString *reply = [self runCollect: argv error: err];
  if (!reply) return NO;
  if ([reply hasPrefix: @"error:"])
    {
      SetErr(err, [reply stringByTrimmingCharactersInSet:
        [NSCharacterSet newlineCharacterSet]]);
      return NO;
    }
  return YES;
}

/* Assert a property of a main-menu item addressed by a title path (same tree
 * walk as selectMenuPath:, but read-only).  The item's raw line carries the
 * columns emitted by the bundle's `menu` command:
 *   depth\tindex\ttitle\tenabled\thas_submenu\tstate\tkey_equiv\tmods\tshortcut
 * `kind` is one of the DDSAssertMenu* kinds; `shortcut` is the expected
 * readable "Cmd+Shift+T" form for DDSAssertMenuShortcut. */
- (BOOL)assertMenuItemPath:(NSString *)path kind:(UITestAssertKind)kind
                  shortcut:(NSString *)expectedShortcut error:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no application target"); return NO; }
  if (path == nil || [path length] == 0)
    { SetErr(err, @"menu item assert needs a path (use \"Top/Sub\")"); return NO; }

  NSString *tree = [self runCollect: [self argvForSubcommand: @"menu"]
                              error: err];
  if (!tree) return NO;

  DDSMenuNode *root = calloc(1, sizeof(DDSMenuNode));
  root->title = @"";
  root->index = -1;
  DDSMenuNode *parents[64];
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
      DDSMenuNode *parent = parents[depth];
      if (parent == NULL) continue;
      parent->kids = realloc(parent->kids, sizeof(DDSMenuNode *) *
          (parent->nkids + 1));
      DDSMenuNode *node = calloc(1, sizeof(DDSMenuNode));
      node->title = [title copy];
      node->index = index;
      node->raw = [line copy];
      parent->kids[parent->nkids++] = node;
      if (hasSubmenu && depth + 1 < 64)
        parents[depth + 1] = node;
    }

  if (!anyItem)
    {
      SetErr(err, @"application has no menu (DriveUI menu unsupported?)");
      DDSMenuNodeFree(root);
      return NO;
    }

  NSArray *segs = [path componentsSeparatedByString: @"/"];
  DDSMenuNode *current = root;
  BOOL found = YES;
  for (NSString *seg in segs)
    {
      if ([seg length] == 0) continue;
      DDSMenuNode *match = NULL;
      for (int i = 0; i < current->nkids; i++)
        {
          DDSMenuNode *k = current->kids[i];
          if ([self title: k->title matches: seg])
            { match = k; break; }
        }
      if (match == NULL) { found = NO; break; }
      current = match;
    }

  if (!found)
    {
      if (kind == DDSAssertMenuNotExists)
        {
          DDSMenuNodeFree(root);
          return YES;   /* expected to be absent - passed */
        }
      SetErr(err, [NSString stringWithFormat:
        @"menu item '%@' not found in '%@'", path, appName_ ?: @"app"]);
      DDSMenuNodeFree(root);
      return NO;
    }

  /* Read the item's columns: state (checkmark), enabled, shortcut. */
  NSArray *fields = [current->raw componentsSeparatedByString: @"\t"];
  int state = ([fields count] > 5) ? [[fields objectAtIndex: 5] intValue] : 0;
  BOOL enabled = ([fields count] > 3) && [[fields objectAtIndex: 3] isEqualToString: @"1"];
  NSString *shortcut = ([fields count] > 8) ? [fields objectAtIndex: 8] : @"";
  DDSMenuNodeFree(root);

  switch (kind)
    {
      case DDSAssertMenuExists:
        break;
      case DDSAssertMenuNotExists:
        SetErr(err, @"assert failed: menu item unexpectedly present");
        return NO;
      case DDSAssertMenuChecked:
        if (state != 1) /* NSOnState */
          { SetErr(err, @"assert failed: menu item is not checked"); return NO; }
        break;
      case DDSAssertMenuNotChecked:
        if (state == 1) /* NSOnState */
          { SetErr(err, @"assert failed: menu item is checked"); return NO; }
        break;
      case DDSAssertMenuEnabled:
        if (!enabled)
          { SetErr(err, @"assert failed: menu item is disabled"); return NO; }
        break;
      case DDSAssertMenuDisabled:
        if (enabled)
          { SetErr(err, @"assert failed: menu item is enabled"); return NO; }
        break;
      case DDSAssertMenuShortcut:
        if (![shortcut isEqualToString: expectedShortcut ?: @""])
          {
            SetErr(err, [NSString stringWithFormat:
              @"assert failed: menu item shortcut is '%@', expected '%@'",
              shortcut, expectedShortcut ?: @""]);
            return NO;
          }
        break;
      default:
        SetErr(err, @"internal: not a menu-item assertion");
        return NO;
    }
  return YES;
}

- (int)countXWindowsWithTitle:(NSString *)title error:(NSString **)err
{
  if (title == nil || [title length] == 0)
    { SetErr(err, @"count xwindow needs a title"); return -1; }
  NSString *reply = [self runCollect: [NSArray arrayWithObjects:
    [NSString stringWithFormat: @"--pid=%d", pid_],
    @"xwindow_count", title, nil] error: err];
  if (!reply) return -1;
  return [reply intValue];
}

- (BOOL)assertXWindowCount:(NSString *)title op:(NSString *)op
                  expected:(int)expected error:(NSString **)err
{
  if (title == nil || [title length] == 0)
    { SetErr(err, @"assert xwindow count needs a title"); return NO; }
  int count = [self countXWindowsWithTitle: title error: err];
  if (count < 0) return NO;

  BOOL ok = NO;
  if ([op isEqualToString: @"="]) ok = (count == expected);
  else if ([op isEqualToString: @">"]) ok = (count > expected);
  else if ([op isEqualToString: @">="]) ok = (count >= expected);
  else if ([op isEqualToString: @"<"]) ok = (count < expected);
  else if ([op isEqualToString: @"<="]) ok = (count <= expected);
  else if ([op isEqualToString: @"!="]) ok = (count != expected);
  else { SetErr(err, [NSString stringWithFormat: @"bad count operator '%@'", op]); return NO; }

  if (!ok)
    {
      SetErr(err, [NSString stringWithFormat:
        @"assert failed: %d windows match '%@' (expected %@ %d)",
        count, title, op, expected]);
      return NO;
    }
  return YES;
}

/* Resolve Menu.app's pid by scanning the DriveUI sockets. */
- (int)menuAppPID
{
  NSString *tmp = @"/tmp";
  NSArray *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:
    tmp error: nil];
  for (NSString *e in entries)
    {
      if (![e hasPrefix: @"driveui."] || ![e hasSuffix: @".sock"]) continue;
      NSString *pidStr = [e substringWithRange: NSMakeRange(8,
        [e length] - 8 - [@".sock" length])];
      int maybePid = [pidStr intValue];
      if (maybePid <= 0) continue;
      if (kill(maybePid, 0) != 0) continue;
      NSString *a = [self runCollect: [NSArray arrayWithObjects:
        [NSString stringWithFormat: @"--pid=%d", maybePid], @"app", nil] error: nil];
      NSString *found = a ? [a stringByTrimmingCharactersInSet:
        [NSCharacterSet newlineCharacterSet]] : @"";
      if ([found isEqualToString: @"Menu"])
        return maybePid;
    }
  return 0;
}

/* Check whether Menu.app's global menu bar currently has a top-level item
 * whose (localized) title matches `title`.  Menu.app shows the menu of the
 * frontmost app, so this tells the test which app's menu is on screen. */
- (BOOL)menuBarHasItem:(NSString *)title exists:(BOOL)exists error:(NSString **)err
{
  if (title == nil || [title length] == 0)
    { SetErr(err, @"menu bar assertion needs a title"); return NO; }
  int menuPid = [self menuAppPID];
  if (menuPid <= 0)
    { SetErr(err, @"Menu.app is not running"); return NO; }
  NSString *reply = [self runCollect: [NSArray arrayWithObjects:
    [NSString stringWithFormat: @"--pid=%d", menuPid], @"menubar", nil]
    error: err];
  if (!reply) return NO;

  BOOL found = NO;
  for (NSString *line in [reply componentsSeparatedByString: @"\n"])
    {
      NSArray *f = [line componentsSeparatedByString: @"\t"];
      if ([f count] == 0) continue;
      NSString *itemTitle = [f objectAtIndex: 0];
      if ([self title: itemTitle matches: title])
        { found = YES; break; }
    }
  if (found != exists)
    {
      SetErr(err, [NSString stringWithFormat:
        @"assert failed: menu bar %@ '%@'", exists ? @"has no" : @"unexpectedly has", title]);
      return NO;
    }
  return YES;
}

/* Launch a command/app through the target app's Run... dialog: open the
 * dialog (its "Run..." menu item), click the CompletionField so it really has
 * the X focus, type the command, and press Return.  Used to start helper apps
 * for tests the same way a user would. */
- (BOOL)runCommandInRunDialog:(NSString *)command error:(NSString **)err
{
  if (command == nil || [command length] == 0)
    { SetErr(err, @"run needs a command"); return NO; }
  if (pid_ == 0)
    { SetErr(err, @"run needs a target application (the one with the Run menu)"); return NO; }

  if (![self selectMenuPath: @"Tools/Run..." error: err])
    return NO;
  usleep (250000);   /* let the dialog open and take focus */

  /* Find the CompletionField in the FRONTMOST visible window (the Run dialog
   * itself; the Workspace also has a preferences CompletionField, so pick the
   * one whose window is a visible dialog near the top of the screen). */
  NSString *tree = [self runCollect: [self argvForSubcommand: @"get_full_tree"]
                              error: err];
  if (!tree) return NO;
  NSString *fieldID = nil;
  CGFloat bestY = -1;
  for (NSString *line in [tree componentsSeparatedByString: @"\n"])
    {
      NSArray *f = [line componentsSeparatedByString: @"\t"];
      if ([f count] < 8) continue;
      if (![[f objectAtIndex: 1] isEqualToString: @"CompletionField"]) continue;
      NSRect r = NSRectFromString([f objectAtIndex: 5]);
      if (r.size.width <= 0) continue;
      if ([f count] > 6 && [[f objectAtIndex: 6] isEqualToString: @"1"]) continue;
      /* Prefer the top-most CompletionField (the Run dialog sits at the top). */
      if (r.origin.y > bestY)
        { bestY = (CGFloat)r.origin.y; fieldID = [f objectAtIndex: 7]; }
    }
  if (fieldID == nil)
    { SetErr(err, @"run: no CompletionField found (Run dialog not open?)"); return NO; }

  NSArray *clickArg = [NSArray arrayWithObjects:
    [NSString stringWithFormat: @"--pid=%d", pid_], @"click", fieldID, nil];
  [self runCollect: clickArg error: nil];

  NSArray *typeArg = [NSArray arrayWithObjects:
    [NSString stringWithFormat: @"--pid=%d", pid_], @"sendkeys", command, nil];
  [self runCollect: typeArg error: nil];

  NSArray *pressArg = [NSArray arrayWithObjects:
    [NSString stringWithFormat: @"--pid=%d", pid_], @"press", nil];
  return [self runCollect: pressArg error: err] != nil;
}

/* Click/double-click/right-click an object by its ID with real X11 events. */
- (BOOL)clickObjectID:(NSString *)objID button:(int)button count:(int)count
                error:(NSString **)err
{
  NSString *cmd = (count == 2) ? @"doubleclick" : ((button == 3) ? @"rightclick" : @"click");
  NSMutableArray *args = [NSMutableArray arrayWithArray:
    [self argvForSubcommand: cmd]];
  [args addObject: objID];
  if ([self runCollect: args error: err]) return YES;
  return NO;
}

- (BOOL)hoverRole:(UITestRole)role title:(NSString *)title error:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no target application"); return NO; }
  /* `hover` needs no widget resolution convenience here because drive_ui
   * resolves the id to a screen position and moves the real pointer over it;
   * we only hand it the id. */
  NSString *objID = [self objectIDForRole: role title: title error: err];
  if (!objID) return NO;
  NSMutableArray *args = [NSMutableArray arrayWithArray:
    [self argvForSubcommand: @"hover"]];
  [args addObject: objID];
  return [self runCollect: args error: err] != nil;
}

- (BOOL)contextMenuRole:(UITestRole)role title:(NSString *)title
              itemTitle:(NSString *)itemTitle error:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no target application"); return NO; }
  NSString *objID = [self objectIDForRole: role title: title error: err];
  if (!objID) return NO;
  NSMutableArray *args = [NSMutableArray arrayWithArray:
    [self argvForSubcommand: @"context_menu"]];
  [args addObject: objID];
  [args addObject: itemTitle];
  NSString *reply = [self runCollect: args error: err];
  if (reply == nil) return NO;
  if ([reply hasPrefix: @"ok"])
    return YES;
  SetErr(err, reply ? [reply stringByTrimmingCharactersInSet:
    [NSCharacterSet newlineCharacterSet]] : @"context menu failed");
  return NO;
}

- (BOOL)scrollRole:(UITestRole)role title:(NSString *)title
        direction:(NSString *)direction amount:(int)amount error:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no target application"); return NO; }
  NSMutableArray *args = [NSMutableArray arrayWithArray:
    [self argvForSubcommand: @"scroll"]];
  if (role != DDSRoleAny)
    {
      NSString *objID = [self objectIDForRole: role title: title error: err];
      if (!objID) return NO;
      [args addObject: objID];
    }
  /* Without a target widget drive_ui scrolls at the current pointer position. */
  if (direction) [args addObject: direction];
  [args addObject: [NSString stringWithFormat: @"%d", amount]];
  return [self runCollect: args error: err] != nil;
}

- (BOOL)dragRole:(UITestRole)role title:(NSString *)title
            byX:(double)dx byY:(double)dy error:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no target application"); return NO; }
  NSString *objID = [self objectIDForRole: role title: title error: err];
  if (!objID) return NO;
  NSMutableArray *args = [NSMutableArray arrayWithArray:
    [self argvForSubcommand: @"drag"]];
  [args addObject: objID];
  [args addObject: [NSString stringWithFormat: @"%g", dx]];
  [args addObject: [NSString stringWithFormat: @"%g", dy]];
  return [self runCollect: args error: err] != nil;
}

- (NSString *)widgetTreeText
{
  if (pid_ == 0) return nil;
  return [self runCollect: [self argvForSubcommand: @"get_full_tree"] error: nil];
}

- (BOOL)type:(NSString *)text error:(NSString **)err
{
  /* sendkeys types into the focused field directly; it is a global X11
   * action, so no target app is strictly needed. */
  NSString *out = [self runCollect: [NSArray arrayWithObjects:
    [NSString stringWithFormat: @"--pid=%d", pid_], @"sendkeys", text, nil]
    error: err];
  return out != nil;
}

- (BOOL)clearRole:(UITestRole)role title:(NSString *)title error:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no application target"); return NO; }
  NSString *objID = [self objectIDForRole: role title: title error: err];
  if (!objID) return NO;
  NSMutableArray *args = [NSMutableArray arrayWithArray:
    [self argvForSubcommand: @"clear"]];
  [args addObject: objID];
  return [self runCollect: args error: err] != nil;
}

- (BOOL)pressKeyCombo:(NSString *)combo error:(NSString **)err
{
  /* A modifier chord (Cmd+Q, Ctrl+C, ...) is a menu shortcut in GNUstep, but
   * synthesized X11 key events cannot set GNUstep's tracked modifier state
   * (XSendEvent does not update the server keymap), so the app's key-equivalent
   * handling never fires.  When a target app is set, resolve the chord to its
   * menu item by shortcut and perform the action in-process instead - this is
   * what makes `press "Cmd+Q"` quit an app.  Fall back to synthesizing a plain
   * key press otherwise. */
  NSArray *parts = [combo componentsSeparatedByString: @"+"];
  if (parts.count > 1 && pid_ != 0)
    {
      NSString *expected = [self canonicalShortcutForParts: parts];
      if (expected != nil
          && [self performMenuItemWithShortcut: expected error: err])
        return YES;
    }
  /* Global X11 key action - no target app required. */
  /* combo like "Enter", "Escape", "Ctrl+C", "Cmd+Q". */
  NSMutableArray *args = [NSMutableArray arrayWithArray:
    [self argvForSubcommand: (parts.count > 1) ? @"chord" : @"press"]];
  if (parts.count > 1)
    {
      for (NSUInteger i = 0; i < [parts count] - 1; i++)
        [args addObject: [self normalizeMod: [parts objectAtIndex: i]]];
      [args addObject: [self normalizeKey: [parts lastObject]]];
    }
  else
    [args addObject: [parts lastObject]];
  NSString *out = [self runCollect: args error: err];
  return out != nil;
}

/* Canonical form of a shortcut for matching: sorted canonical modifiers and a
 * lowercased key, e.g. "Cmd+Q" and "Alt+Q" both become "cmd:q". */
- (NSString *)canonicalShortcutForParts:(NSArray *)parts
{
  if ([parts count] < 2) return nil;
  NSMutableArray *mods = [NSMutableArray array];
  for (NSUInteger i = 0; i < [parts count] - 1; i++)
    {
      NSString *m = [[parts objectAtIndex: i] lowercaseString];
      if ([m isEqualToString: @"cmd"] || [m isEqualToString: @"command"]
        || [m isEqualToString: @"meta"] || [m isEqualToString: @"alt"])
        [mods addObject: @"cmd"];
      else if ([m isEqualToString: @"ctrl"] || [m isEqualToString: @"control"])
        [mods addObject: @"ctrl"];
      else if ([m isEqualToString: @"shift"])
        [mods addObject: @"shift"];
      else
        [mods addObject: m];
    }
  [mods sortUsingSelector: @selector(compare:)];
  NSString *key = [[parts lastObject] lowercaseString];
  return [NSString stringWithFormat: @"%@:%@",
    [mods componentsJoinedByString: @"+"], key];
}

/* Walk the target app's menu tree, find the item whose key-equivalent
 * shortcut matches, and perform it via menu_invoke.  Returns NO (with *err)
 * if no item matches. */
- (BOOL)performMenuItemWithShortcut:(NSString *)expected error:(NSString **)err
{
  NSString *tree = [self runCollect: [self argvForSubcommand: @"menu"]
                              error: err];
  if (!tree) return NO;

  NSMutableArray *path = [NSMutableArray array];
  NSArray *lines = [tree componentsSeparatedByString: @"\n"];
  for (NSString *line in lines)
    {
      NSArray *f = [line componentsSeparatedByString: @"\t"];
      if ([f count] < 9) continue;
      int depth = [[f objectAtIndex: 0] intValue];
      int index = [[f objectAtIndex: 1] intValue];
      BOOL hasSubmenu = [[f objectAtIndex: 4] isEqualToString: @"1"];
      NSString *shortcut = [f objectAtIndex: 8];
      if (depth < 0 || depth > 64) continue;

      /* path holds the indexes of the ancestors at depths 0..depth-1. */
      while ([path count] > (NSUInteger)depth)
        [path removeLastObject];

      NSArray *scParts = [shortcut componentsSeparatedByString: @"+"];
      if ([scParts count] > 1)
        {
          NSString *scCanon = [self canonicalShortcutForParts: scParts];
          if (scCanon != nil && [scCanon isEqualToString: expected])
            {
              NSMutableArray *argv = [NSMutableArray arrayWithArray:
                [self argvForSubcommand: @"menu_invoke"]];
              for (NSNumber *p in path)
                [argv addObject: [p stringValue]];
              [argv addObject: [NSString stringWithFormat: @"%d", index]];
              NSString *reply = [self runCollect: argv error: err];
              if (!reply) return NO;
              if ([reply hasPrefix: @"error:"])
                {
                  if (err)
                    *err = [reply stringByTrimmingCharactersInSet:
                      [NSCharacterSet newlineCharacterSet]];
                  return NO;
                }
              return YES;
            }
        }

      if (hasSubmenu)
        [path addObject: @(index)];
    }
  if (err)
    *err = [NSString stringWithFormat: @"no menu item with shortcut '%@'",
      expected];
  return NO;
}

/* Translate a UITest key to the key name drive_ui's X11Support expects. */
- (NSString *)normalizeKey:(NSString *)key
{
  NSString *k = [key lowercaseString];
  if ([k isEqualToString: @"enter"] || [k isEqualToString: @"return"])
    return @"Return";
  if ([k isEqualToString: @"esc"] || [k isEqualToString: @"escape"])
    return @"Escape";
  if ([k isEqualToString: @"tab"]) return @"Tab";
  if ([k isEqualToString: @"backspace"]) return @"BackSpace";
  if ([k isEqualToString: @"del"] || [k isEqualToString: @"delete"])
    return @"Delete";
  if ([k isEqualToString: @"up"]) return @"Up";
  if ([k isEqualToString: @"down"]) return @"Down";
  if ([k isEqualToString: @"left"]) return @"Left";
  if ([k isEqualToString: @"right"]) return @"Right";
  if (k.length == 1)
    {
      unichar c = [k characterAtIndex: 0];
      if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) return key;
    }
  return key;
}

- (NSString *)normalizeMod:(NSString *)mod
{
  NSString *m = [mod lowercaseString];
  /* GNUstep Command maps to Left Alt in drive_ui's X11 simulation. */
  if ([m isEqualToString: @"cmd"] || [m isEqualToString: @"command"] ||
      [m isEqualToString: @"meta"] || [m isEqualToString: @"alt"])
    return @"alt";
  if ([m isEqualToString: @"ctrl"] || [m isEqualToString: @"control"]) return @"control";
  if ([m isEqualToString: @"shift"]) return @"shift";
  if ([m isEqualToString: @"super"]) return @"super";
  if ([m isEqualToString: @"win"]) return @"super";
  return m;
}

- (BOOL)doesWidgetExist:(UITestRole)role title:(NSString *)title
           contains:(NSString *)needle error:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no application target"); return NO; }
  if (role == DDSRoleModal)
    {
      /* `modal` is answered by the app's modal state, not the widget tree. */
      NSString *mt = [self modalWindowTitle: err];
      if (mt == nil) return NO;
      if (needle && ![self title: mt matches: needle]) return NO;
      return YES;
    }
  if (role == DDSRoleXWindow)
    {
      /* `xwindow` scans the whole X display for a window title, so it works
       * for non-GNUstep apps (e.g. a GTK app) that have no widget tree. */
      for (int attempt = 0; attempt < 8; attempt++)
        {
          NSString *reply = [self runCollect: [NSArray arrayWithObjects:
            [NSString stringWithFormat: @"--pid=%d", pid_],
            @"xwindow", title ?: @"", nil]
            error: (attempt == 7) ? err : nil];
          if (reply != nil)
            return [reply hasPrefix: @"1"];
          usleep (100000);
        }
      return NO;
    }
  if (role == DDSRoleWindow && needle == nil && title != nil)
    {
      /* Window existence is answered by the app's visible-window list, which
       * is far cheaper than building the full widget tree (a folder viewer
       * has hundreds of widgets).  The app can be transiently busy, so retry
       * a few times. */
      for (int attempt = 0; attempt < 8; attempt++)
        {
          NSString *list = [self runCollect: [self argvForSubcommand: @"windows"]
            error: (attempt == 7) ? err : nil];
          if (list != nil)
            {
              for (NSString *line in [list componentsSeparatedByString: @"\n"])
                {
                  if ([self title: line matches: title]) return YES;
                }
              return NO;
            }
          usleep (250000);
        }
      return NO;
    }
  NSString *cls = UITestRoleClassName(role);
  /* The app can be transiently busy (a wedge from window churn, or a heavy
   * layout), which makes the 1s read timeout fire even though the widget is
   * there.  Retry the tree fetch a few times so a busy spell does not turn an
   * `assert` into a spurious "widget not found". */
  NSString *tree = nil;
  for (int attempt = 0; attempt < 8; attempt++)
    {
      tree = [self runCollect: [self argvForSubcommand: @"get_full_tree"]
        error: (attempt == 7) ? err : nil];
      if (tree != nil) break;
      usleep (250000);
    }
  if (!tree) return NO;
  for (NSString *line in [tree componentsSeparatedByString: @"\n"])
    {
      NSArray *f = [line componentsSeparatedByString: @"\t"];
      if ([f count] < 8) continue;
      NSString *lineCls = [f objectAtIndex: 1];
      NSString *lineText = [f objectAtIndex: 2];
      NSString *hidden = [f objectAtIndex: 6];
      if ([hidden isEqualToString: @"1"]) continue;
      if (![self class: lineCls matchesRoleClass: cls]) continue;
      if (title && ![self title: lineText matches: title]) continue;
      if (needle)
        {
          if ([self title: lineText matches: needle] == NO) continue;
        }
      return YES;
    }
  return NO;
}

- (BOOL)assertRole:(UITestRole)role title:(NSString *)title kind:(UITestAssertKind)kind
        needle:(NSString *)needle error:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no application target"); return NO; }
  BOOL exists = (kind == DDSAssertContains)
    ? [self doesWidgetExist: DDSRoleAny title: nil contains: needle error: err]
    : [self doesWidget: role title: title error: err];
  switch (kind)
    {
      case DDSAssertExists:
        if (!exists) { SetErr(err, [NSString stringWithFormat:
          @"assert failed: widget not found"]); return NO; }
        break;
      case DDSAssertNotExists:
        if (exists) { SetErr(err, @"assert failed: widget unexpectedly present"); return NO; }
        break;
      case DDSAssertContains:
        if (!exists) { SetErr(err, @"assert failed: text not found"); return NO; }
        break;
      case DDSAssertFrameConstant:
        /* Handled by the executor's frame-constant check, which keeps the
         * per-run reference frame; this switch case exists only so the enum
         * stays exhaustive. */
        return YES;
      case DDSAssertEnabled:
      case DDSAssertChecked:
      case DDSAssertDocked:
      case DDSAssertNotDocked:
      {
        if (!exists) { SetErr(err, @"assert failed: widget not found"); return NO; }
        BOOL enabled = NO, checked = NO;
        if (![self propsForRole: role title: title enabled: &enabled
                        checked: &checked error: err])
          { if (err && *err == nil) SetErr(err, @"assert failed: cannot read widget state"); return NO; }
        if (kind == DDSAssertEnabled && !enabled)
          { SetErr(err, @"assert failed: widget is disabled"); return NO; }
        if (kind == DDSAssertChecked && !checked)
          { SetErr(err, @"assert failed: widget is not checked"); return NO; }
        if (kind == DDSAssertDocked && !checked)
          { SetErr(err, @"assert failed: widget is not docked"); return NO; }
        if (kind == DDSAssertNotDocked && checked)
          { SetErr(err, @"assert failed: widget is docked"); return NO; }
        break;
      }
      default:
        /* The DDSAssertMenu* kinds are handled by assertMenuItemPath:; they
         * never reach this widget assertion. */
        SetErr(err, @"assert failed: unknown assertion kind");
        return NO;
    }
  return YES;
}

/* Internal helper: does a widget matching role+title exist right now? */
- (BOOL)doesWidget:(UITestRole)role title:(NSString *)title error:(NSString **)err
{
  return [self doesWidgetExist: role title: title contains: nil error: err];
}

/* Parse a "enabled=1 state=0" reply from drive_ui's props command. */
- (BOOL)parsePropsReply:(NSString *)reply enabled:(BOOL *)enabled
                checked:(BOOL *)checked
{
  if (!reply) return NO;
  if (enabled) *enabled = NO;
  if (checked) *checked = NO;
  BOOL foundEnabled = NO, foundChecked = NO;
  NSArray *pairs = [[reply stringByTrimmingCharactersInSet:
    [NSCharacterSet newlineCharacterSet]]
    componentsSeparatedByString: @" "];
  for (NSString *pair in pairs)
    {
      NSArray *kv = [pair componentsSeparatedByString: @"="];
      if ([kv count] != 2) continue;
      NSString *key = [kv objectAtIndex: 0];
      int val = [[kv objectAtIndex: 1] intValue];
      if ([key isEqualToString: @"enabled"])
        {
          if (enabled) *enabled = (val == 1);
          foundEnabled = YES;
        }
      else if ([key isEqualToString: @"state"])
        {
          if (checked) *checked = (val == 1);
          foundChecked = YES;
        }
    }
  return foundEnabled || foundChecked;
}

- (BOOL)propsForRole:(UITestRole)role title:(NSString *)title
             enabled:(BOOL *)enabled checked:(BOOL *)checked error:(NSString **)err
{
  if (pid_ == 0) { SetErr(err, @"no application target"); return NO; }
  NSString *objID = [self objectIDForRole: role title: title error: err];
  if (!objID) return NO;
  NSArray *argv = [NSArray arrayWithObjects:
    [NSString stringWithFormat: @"--pid=%d", pid_], @"props", objID, nil];
  NSString *out = [self runCollect: argv error: err];
  if (!out) return NO;
  if (![self parsePropsReply: out enabled: enabled checked: checked])
    {
      SetErr(err, @"props: malformed reply");
      return NO;
    }
  return YES;
}

- (BOOL)captureScreenshotToPath:(NSString *)path outPath:(NSString **)outPath
                          error:(NSString **)err
{
  NSString *target = path;
  if (target == nil || [target length] == 0)
    {
      /* default name: /tmp/run_uitest-<timestamp>.png */
      NSDateFormatter *fmt = [[[NSDateFormatter alloc] init] autorelease];
      [fmt setDateFormat: @"yyyyMMdd-HHmmss"];
      target = [NSString stringWithFormat: @"/tmp/run_uitest-%@.png",
        [fmt stringFromDate: [NSDate date]]];
    }
  if (outPath) *outPath = target;

  /* ffmpeg's x11grab is our screen-capture backend (the same approach the
   * Screenshot component takes for X11); it is always present on systems with
   * libav.  Capture the whole root window so hidden/off-screen state does not
   * matter. */
  NSString *display = [[NSProcessInfo processInfo] environment][@"DISPLAY"];
  if (display == nil || [display length] == 0) display = @":0";
  NSArray *argv = [NSArray arrayWithObjects:
    @"-f", @"x11grab",
    @"-i", display,
    @"-frames:v", @"1",
    @"-update", @"1",
    @"-y", target, nil];
  if ([self runTool: @"/bin/ffmpeg" argv: argv error: err] == nil)
    {
      if (err) *err = [NSString stringWithFormat: @"screenshot failed (ffmpeg): %@", *err ?: @""];
      return NO;
    }
  return YES;
}

@end