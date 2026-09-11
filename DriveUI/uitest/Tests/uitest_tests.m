/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * uitest_tests - GNUstep test framework harness that runs every DriveUI
 * UI test script (*.uitest) found under UITEST_SEARCH_DIRS (a colon-separated
 * list of directories exported by TestInfo or the cross-repo driver
 * /Developer/Library/Sources/run-tests.sh).  Each script is run with
 * run_uitest; an exit status of 0 is a pass.
 *
 * Scripts are grouped for the log by the directory they live in, keyed by
 * their path relative to /Developer/Library/Sources so that identically
 * named folders in different repositories stay separate.  A "heavy"
 * directory is its own group, skipped as a whole unless UI_TEST_LEVEL=full.
 *
 * A CPU watchdog guards every script against runaway processes: while a
 * script runs it samples Menu.app, Workspace and the runner, and aborts the
 * script if one pegs the CPU (a spin / busy-loop, cf. the Menu evdev
 * POLLHUP spin and the Workspace run-loop busy-cycle).  After each script it
 * re-checks that the desktop has settled, so a busy-loop that persists with
 * no driver is caught too.  On trigger it captures the culprit's stack for
 * diagnosis.  Tunable via UITEST_CPU_WATCH (off/on),
 * UITEST_CPU_THRESHOLD (percent, default 90), UITEST_CPU_SAMPLES (default 5)
 * and UITEST_CPU_IDLE (percent, default 15).
 *
 * The same watchdog also watches the health of the desktop: Menu.app,
 * WindowManager (and Workspace, when it is installed/running) must stay
 * alive the whole time a script runs and between scripts.  If one exits, the
 * running script is aborted and the failure is reported as a desktop crash
 * rather than a test bug.
 */

#import <stdlib.h>
#import <string.h>
#import <time.h>
#import <unistd.h>
#import <pthread.h>
#import <sys/wait.h>
#import "Testing.h"
#import <Foundation/Foundation.h>
/* The run_uitest exit-code contract (DDSParseError/DDSRuntimeError/...): the
 * harness maps a script's exit status to a JUnit failure vs error below. */
#import "../UITest.h"
/* The JUnit result model and serializer (spec reporter architecture). */
#import "../JUnitReporter.h"

static NSString *runner = @"/System/Library/Tools/run_uitest";
static NSString *sourcesRoot = @"/Developer/Library/Sources";

/* ---------------------------------------------------------------------------
 * CPU watchdog helpers.
 * ------------------------------------------------------------------------ */

typedef struct
{
  unsigned long long lastJiffies;
  double lastTime;
  BOOL valid;
} CPUWatchSample;

/* Parse ps -o time= output ([[DD-]HH:]MM[:SS] or a bare seconds value) into
 * cumulative seconds.  Returns -1 on garbage.  Used on platforms without
 * /proc, where the cumulative CPU time has to come from `ps`. */
#if !defined(__linux__)
static double
parseCpuTime(const char *s)
{
  double days = 0;
  const char *dash = strchr(s, '-');
  if (dash)
    {
      days = atof(s);
      s = dash + 1;
    }
  double a = 0, b = 0, c = 0;
  int n = sscanf(s, "%lf:%lf:%lf", &a, &b, &c);
  switch (n)
    {
      case 1: return days * 86400.0 + a;
      case 2: return days * 86400.0 + a * 60.0 + b;
      case 3: return days * 86400.0 + a * 3600.0 + b * 60.0 + c;
      default: return -1.0;
    }
}

/* Cumulative CPU seconds of pid via `ps -o time=`; -1 if the process is
 * gone.  `ps -o time=` is portable across Linux and the BSDs. */
static double
cumulativeCpuSeconds(pid_t pid)
{
  char cmd[96];
  snprintf(cmd, sizeof(cmd), "ps -o time= -p %d", pid);
  FILE *fp = popen(cmd, "r");
  if (!fp)
    {
      return -1.0;
    }
  char line[64];
  if (!fgets(line, sizeof(line), fp))
    {
      pclose(fp);
      return -1.0;
    }
  pclose(fp);
  char *p = line;
  while (*p == ' ' || *p == '\t')
    {
      p++;
    }
  size_t n = strlen(p);
  while (n > 0 && (p[n-1] == '\n' || p[n-1] == ' ' || p[n-1] == '\t'))
    {
      p[--n] = '\0';
    }
  if (*p == '\0')
    {
      return -1.0;
    }
  return parseCpuTime(p);
}
#endif  /* !defined(__linux__) */

/* Read the total CPU time of pid as a jiffies-like counter.  On Linux this
 * is the exact utime+stime from /proc/<pid>/stat; on the BSDs (no /proc by
 * default) it is the cumulative CPU seconds from `ps -o time=` scaled by
 * USER_HZ.  The two agree to within one tick, and the hz factor cancels in
 * the percent computation, so both platforms measure the same thing.
 * Returns NO if the process is gone or unreadable. */
static BOOL
readCpuJiffies(pid_t pid, unsigned long long *out)
{
#if defined(__linux__)
  char path[64];
  snprintf(path, sizeof(path), "/proc/%d/stat", pid);
  FILE *fp = fopen(path, "r");
  if (!fp)
    {
      return NO;
    }
  unsigned long long utime, stime;
  int n = fscanf(fp, "%*d (%*[^)]) %*c %*d %*d %*d %*d %*d %*d %*d %*d "
    "%*d %*d %*d %llu %llu", &utime, &stime);
  fclose(fp);
  if (n != 2)
    {
      return NO;
    }
  *out = utime + stime;
  return YES;
#else
  double seconds = cumulativeCpuSeconds(pid);
  if (seconds < 0.0)
    {
      return NO;
    }
  long hz = sysconf(_SC_CLK_TCK);
  *out = (unsigned long long)(seconds * (hz > 0 ? hz : 100));
  return YES;
#endif
}

static double
nowSeconds(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* CPU percent of pid since the previous sample (0.0 on the first call).
 * Returns -1 when the process is gone. */
static double
cpuPercentSince(pid_t pid, CPUWatchSample *st)
{
  unsigned long long jiffies;
  if (!readCpuJiffies(pid, &jiffies))
    {
      st->valid = NO;
      return -1.0;
    }
  double now = nowSeconds();
  if (st->valid && now > st->lastTime)
    {
      double dj = (double)(jiffies - st->lastJiffies);
      double dt = now - st->lastTime;
      double hz = (double)sysconf(_SC_CLK_TCK);
      st->lastJiffies = jiffies;
      st->lastTime = now;
      return (hz > 0.0 && dt > 0.0) ? (100.0 * dj / dt / hz) : 0.0;
    }
  st->valid = YES;
  st->lastJiffies = jiffies;
  st->lastTime = now;
  return 0.0;
}

/* First pid matching a process name (pgrep -x), or 0. */
static pid_t
pidOfName(NSString *name)
{
  FILE *fp = popen([[NSString stringWithFormat:@"pgrep -x %@", name]
    UTF8String], "r");
  if (!fp)
    {
      return 0;
    }
  char line[64];
  pid_t pid = 0;
  if (fgets(line, sizeof(line), fp))
    {
      pid = (pid_t)atoi(line);
    }
  pclose(fp);
  return pid;
}

/* Best-effort diagnostic: dump the head of a process stack to stderr.
 * Bounded so a wedged process cannot stall the suite.  gstack is a gdb
 * wrapper on Linux; the BSDs use gdb batch directly.  OpenBSD restricts
 * ptrace ('Operation not permitted'), so gdb yields nothing there and we
 * fall back to ktrace/kdump, and always print the ps wait-channel first -
 * that works on every platform and shows whether the process is spinning in
 * userspace (R, wchan '-') or blocked in a syscall. */
static void
captureStack(pid_t pid, const char *label)
{
  /* Wait-channel/state: works everywhere without ptrace.  A process in state
   * R with wchan '-' is actively spinning in userspace. */
  char wcmd[128];
  snprintf(wcmd, sizeof(wcmd),
    "ps -o pid,stat,wchan,command -p %d 2>/dev/null", pid);
  FILE *wfp = popen(wcmd, "r");
  if (wfp)
    {
      char wline[256];
      fprintf(stderr, "--- %s (pid %d) state ---\n", label, pid);
      while (fgets(wline, sizeof(wline), wfp))
        {
          fprintf(stderr, "%s", wline);
        }
      pclose(wfp);
    }

  char cmd[256];
  const char *tool = "gdb";
  if (system("command -v gstack >/dev/null 2>&1") == 0)
    {
      tool = "gstack";
      snprintf(cmd, sizeof(cmd), "timeout 3 gstack %d | head -40", pid);
    }
  else if (system("command -v pstack >/dev/null 2>&1") == 0)
    {
      tool = "pstack";
      snprintf(cmd, sizeof(cmd), "timeout 3 pstack %d | head -40", pid);
    }
  else
    {
      tool = "gdb";
      snprintf(cmd, sizeof(cmd),
        "timeout 3 gdb -batch -p %d -ex 'thread apply all bt 8' "
        "-ex detach -ex quit | head -40", pid);
    }
  FILE *fp = popen(cmd, "r");
  if (!fp)
    {
      fprintf(stderr, "--- %s (pid %d) stack: popen failed ---\n", label, pid);
      return;
    }
  char line[256];
  fprintf(stderr, "--- %s (pid %d) stack (via %s) ---\n", label, pid, tool);
  int n = 0;
  while (fgets(line, sizeof(line), fp) && n < 40)
    {
      fprintf(stderr, "%s", line);
      n++;
    }
  if (n == 0)
    {
      fprintf(stderr, "    (empty - %s produced no output)\n", tool);
    }
  pclose(fp);

  /* ktrace/kdump (OpenBSD): attach for a second and dump the syscall stream -
   * shows exactly what a userspace spin is doing (e.g. a repeated
   * read/poll/gettimeofday).  Works where ptrace is restricted. */
  if (system("command -v kdump >/dev/null 2>&1") == 0
      && system("command -v ktrace >/dev/null 2>&1") == 0)
    {
      char kcmd[256];
      snprintf(kcmd, sizeof(kcmd),
        "ktrace -p %d -f /tmp/uitest_ktrace 2>/dev/null; sleep 1; "
        "ktrace -c -p %d 2>/dev/null; kdump -f /tmp/uitest_ktrace 2>/dev/null "
        "| head -60", pid, pid);
      FILE *kfp = popen(kcmd, "r");
      if (kfp)
        {
          char kline[256];
          fprintf(stderr, "--- %s (pid %d) ktrace ---\n", label, pid);
          int kn = 0;
          while (fgets(kline, sizeof(kline), kfp) && kn < 60)
            {
              fprintf(stderr, "%s", kline);
              kn++;
            }
          if (kn == 0)
            fprintf(stderr, "    (empty - ktrace produced no output)\n");
          pclose(kfp);
        }
      unlink("/tmp/uitest_ktrace");
    }
}

typedef struct
{
  NSTask *task;                  /* the running script task (aborted on trip) */
  pid_t watchPids[4];            /* Menu, Workspace, WindowManager, runner */
  const char *watchNames[4];
  const char *watchPgrepNames[4]; /* process names for pid re-resolution */
  int watchCount;
  double threshold;              /* average percent over the window to trip */
  int windowSize;                /* rolling-average window (samples) */
  CPUWatchSample sample[4];
  double window[4][16];          /* ring of recent CPU% per process */
  int windowCount[4];
  int windowIdx[4];
  double windowSum[4];
  double deadline;               /* epoch seconds; 0 disables the wall-clock trip */
  double deadlineLimit;          /* configured limit in seconds (for the reason) */
  volatile BOOL stopped;         /* main thread set after waitUntilExit */
  volatile BOOL triggered;
  int culpritIndex;
  char reason[256];
  volatile BOOL healthTrip;      /* a desktop component exited (not a CPU spin) */
} CPUWatchdog;

/* Push a CPU% reading into the process's rolling window.  The rolling
 * average (rather than consecutive samples) catches both sustained spins and
 * intermittent-but-recurring high CPU that would otherwise reset a "N in a
 * row" counter (e.g. Menu.app busy-looping at ~50% on and off). */
static void
pushWindow(CPUWatchdog *w, int i, double pct)
{
  if (w->windowCount[i] < w->windowSize)
    {
      w->windowSum[i] += pct;
      w->window[i][w->windowIdx[i]] = pct;
      w->windowIdx[i] = (w->windowIdx[i] + 1) % w->windowSize;
      w->windowCount[i]++;
    }
  else
    {
      int old = w->windowIdx[i];
      w->windowSum[i] += pct - w->window[i][old];
      w->window[i][old] = pct;
      w->windowIdx[i] = (old + 1) % w->windowSize;
    }
}

static void *
watchdogMain(void *arg)
{
  CPUWatchdog *w = (CPUWatchdog *)arg;
  /* The health checks resolve processes by name (NSString + popen); a plain
   * pthread has no autorelease pool, and leaking one pool's worth per second
   * for the whole suite is enough to crash this thread - which would silently
   * disable the watchdog.  Drain a pool on every pass. */
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
  /* Warm up the per-process samples so every in-loop reading is a real CPU
   * delta (the first cpuPercentSince: call only establishes a baseline). */
  for (int i = 0; i < w->watchCount; i++)
    {
      if (w->watchPids[i] > 0)
        {
          cpuPercentSince(w->watchPids[i], &w->sample[i]);
        }
    }
  while (!w->stopped)
    {
      [pool release];
      pool = [[NSAutoreleasePool alloc] init];
      int worst = -1;
      double worstAvg = 0.0;
      /* The runner (run_uitest, the last entry) is deliberately EXCLUDED from
       * the CPU trip: driving a test means spawning drive_ui subprocesses and
       * polling, so it is legitimately busy - on a slow VM (QEMU BSD CI) it
       * regularly spikes well past any sane threshold while doing its job, and
       * tripping on it killed otherwise-fine tests.  It is still health-watched
       * above (the loop uses watchCount-1 so the runner is skipped there too,
       * but a vanished runner is caught by the task exit status anyway). */
      for (int i = 0; i < w->watchCount - 1; i++)
        {
          if (w->watchPids[i] <= 0)
            {
              continue;
            }
          double pct = cpuPercentSince(w->watchPids[i], &w->sample[i]);
          if (pct < 0.0)
            {
              continue;          /* process gone */
            }
          pushWindow(w, i, pct);
          /* Only consider a process for the CPU trip once its rolling window
           * is FULL.  Tripping on a partially-filled window means a single
           * 1s burst above the threshold fails the test - which on a slow
           * QEMU VM (framing a window, a birth/close animation, a full-screen
           * damage repaint) is legitimate work, not a spin.  A genuine
           * sustained spin holds every slot of the window above the
           * threshold, so requiring a full window still catches it. */
          if (w->windowCount[i] >= w->windowSize)
            {
              double avg = w->windowSum[i] / w->windowCount[i];
              if (avg > worstAvg)
                {
                  worstAvg = avg;
                  worst = i;
                }
            }
        }

      /* Health: a desktop component (Menu, Workspace, WindowManager - not the
       * runner, which exits when the script ends) must stay alive the whole
       * time a script runs.  If one exits, give the desktop a short window to
       * respawn it (Menu restarts itself); only then declare it dead. */
      for (int i = 0; i < w->watchCount - 1; i++)
        {
          pid_t pid = w->watchPids[i];
          if (pid <= 0)
            {
              continue;          /* Workspace not installed/running: skip */
            }
          if (kill(pid, 0) == 0)
            {
              continue;          /* alive */
            }
          pid_t newPid = 0;
          for (int tries = 0; tries < 4 && !w->stopped; tries++)
            {
              newPid = pidOfName([NSString stringWithUTF8String:
                w->watchPgrepNames[i]]);
              if (newPid > 0)
                {
                  break;
                }
              usleep(500000);
            }
          if (newPid > 0)
            {
              w->watchPids[i] = newPid;   /* restarted - keep watching */
              continue;
            }
          snprintf(w->reason, sizeof(w->reason),
            "health watchdog: %s exited while a test was running (pid %d)",
            w->watchNames[i], pid);
          w->culpritIndex = i;
          w->healthTrip = YES;
          w->triggered = YES;
          [w->task terminate];
          break;
        }

      if (worst >= 0 && worstAvg >= w->threshold)
        {
          snprintf(w->reason, sizeof(w->reason),
            "CPU watchdog: %s at %.0f%% CPU (avg over %d s, threshold %.0f%%)",
            w->watchNames[worst], worstAvg, w->windowCount[worst],
            w->threshold);
          w->culpritIndex = worst;
          w->triggered = YES;
          [w->task terminate];
          break;
        }
      /* Wall-clock deadline: a wedged-but-alive desktop (e.g. a stalled
       * DriveUI socket) spins neither the CPU nor the health checks, so a
       * test could otherwise grind through timeouts until the CI job cap
       * kills everything.  Trip at the deadline so a stuck test fails fast
       * instead. */
      if (w->deadline > 0.0 && nowSeconds() >= w->deadline)
        {
          snprintf(w->reason, sizeof(w->reason),
            "test exceeded wall-clock deadline of %.0f s",
            w->deadlineLimit);
          w->culpritIndex = -1;
          w->triggered = YES;
          [w->task terminate];
          break;
        }
      if (w->triggered)
        {
          break;
        }
      usleep(1000000);
    }
  return NULL;
}

/* ---------------------------------------------------------------------------
 * Script running.
 * ------------------------------------------------------------------------ */

static BOOL
fileExists(NSString *path)
{
  return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

/* Tail of a log file (the desktop components' stderr), used to surface the
 * crash reason a health-watchdog trip left behind.  Returns nil when the
 * file is absent or empty. */
static NSString *
lastLinesOfLog(NSString *path, int lines)
{
  NSData *data = [NSData dataWithContentsOfFile: path];
  if (!data) return nil;
  NSString *text = [[NSString alloc] initWithData: data
    encoding: NSUTF8StringEncoding];
  if ([text length] == 0)
    {
      [text release];
      return nil;
    }
  NSArray *all = [text componentsSeparatedByString: @"\n"];
  NSUInteger n = [all count];
  NSUInteger from = (n > (NSUInteger)lines) ? (n - (NSUInteger)lines) : 0;
  NSArray *tail = [all subarrayWithRange: NSMakeRange(from, n - from)];
  NSString *joined = [tail componentsJoinedByString: @"\n"];
  [text release];
  return joined;
}

static BOOL
processRunning(NSString *name)
{
  NSString *cmd = [NSString stringWithFormat:@"pgrep -x %@ >/dev/null 2>&1",
    name];
  return WEXITSTATUS(system([cmd UTF8String])) == 0;
}

/* Path to an installed app bundle's executable, or nil.  Used to make a
 * desktop component optional: the suite runs on desktops that ship without,
 * say, Workspace, so its presence must not be a hard prerequisite. */
static NSString *
appPath(NSString *name)
{
  NSArray *roots = [NSArray arrayWithObjects:
    @"/System/Applications/Utilities",
    @"/System/Applications",
    @"/System/Library/CoreServices/Applications",
    @"/System/Library/CoreServices/Applications/Utilities",
    @"/Local/Applications",
    @"/Developer/Applications", nil];
  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *root in roots)
    {
      NSString *app = [root stringByAppendingPathComponent:
        [name stringByAppendingString: @".app"]];
      BOOL isDir = NO;
      if ([fm fileExistsAtPath: app isDirectory: &isDir] && isDir)
        {
          return [app stringByAppendingPathComponent: name];
        }
    }
  return nil;
}

static BOOL
appInstalled(NSString *name)
{
  return appPath(name) != nil;
}

/* Start Workspace before a test if it is installed but not running (a test
 * that exercises the desktop should not be tripped up by a Workspace that
 * died earlier in the suite).  Returns YES when Workspace is up afterwards. */
static BOOL
launchWorkspaceIfNeeded(void)
{
  if (!appInstalled(@"Workspace"))
    {
      return NO;
    }
  if (processRunning(@"Workspace"))
    {
      return YES;
    }
  NSString *bin = appPath(@"Workspace");
  NSLog(@"starting Workspace before test: %@", bin);
  NSString *cmd = [NSString stringWithFormat:
    @"setsid %@ </dev/null >/tmp/uitest_workspace.log 2>&1 &", bin];
  system([cmd UTF8String]);
  for (int i = 0; i < 25; i++)
    {
      if (processRunning(@"Workspace"))
        {
          return YES;
        }
      usleep(200000);
    }
  NSLog(@"Workspace did not come up after being started");
  return NO;
}

/* After a script the desktop should settle; a process still pegged means a
 * stuck busy-loop with no driver.  Returns YES when healthy. */
static BOOL
checkSettled(double idleThreshold)
{
  pid_t menuPid = pidOfName(@"Menu");
  pid_t wsPid = pidOfName(@"Workspace");
  pid_t wmPid = pidOfName(@"WindowManager");
  CPUWatchSample m, w, wm;
  memset(&m, 0, sizeof(m));
  memset(&w, 0, sizeof(w));
  memset(&wm, 0, sizeof(wm));
  int mOver = 0, wOver = 0, wmOver = 0;
  /* Four samples: the first is a CPU baseline, so three real measurements. */
  for (int i = 0; i < 4; i++)
    {
      if (menuPid > 0 && cpuPercentSince(menuPid, &m) >= idleThreshold)
        {
          mOver++;
        }
      if (wsPid > 0 && cpuPercentSince(wsPid, &w) >= idleThreshold)
        {
          wOver++;
        }
      if (wmPid > 0 && cpuPercentSince(wmPid, &wm) >= idleThreshold)
        {
          wmOver++;
        }
      usleep(1000000);
    }
  BOOL ok = YES;
  /* Health: a desktop component that vanished (or was never up) is a crash
   * worth surfacing.  Resolve by name rather than the sample pids so a
   * component that died before checkSettled ran is still reported. */
  if (processRunning(@"Menu") == NO)
    {
      NSLog(@"health watchdog: Menu.app is not running (exited)");
      ok = NO;
    }
  if (appInstalled(@"Workspace") && processRunning(@"Workspace") == NO)
    {
      NSLog(@"health watchdog: Workspace is not running (exited)");
      ok = NO;
    }
  if (processRunning(@"WindowManager") == NO)
    {
      NSLog(@"health watchdog: WindowManager is not running (exited)");
      ok = NO;
    }
  if (mOver >= 3)
    {
      NSLog(@"CPU watchdog: Menu.app still pegged (>=%.0f%%) with no test driving it - stuck spin?",
        idleThreshold);
      captureStack(menuPid, "Menu");
      ok = NO;
    }
  if (wOver >= 3)
    {
      NSLog(@"CPU watchdog: Workspace still pegged (>=%.0f%%) with no test driving it - stuck busy-loop?",
        idleThreshold);
      captureStack(wsPid, "Workspace");
      ok = NO;
    }
  if (wmOver >= 3)
    {
      NSLog(@"CPU watchdog: WindowManager still pegged (>=%.0f%%) with no test driving it - stuck?",
        idleThreshold);
      captureStack(wmPid, "WindowManager");
      ok = NO;
    }
  return ok;
}

/* After each script, report the windows currently mapped and visible on
 * screen (xdotool search --onlyvisible, a suite prerequisite), so leftover
 * windows from an earlier test or an unclosed window in a failing test are
 * visible in the harness log.  One line per window: "id<TAB>pid<TAB>name". */
static void
reportMappedWindows(NSString *label)
{
  FILE *fp = popen(
    "DISPLAY=${DISPLAY:-:0} xdotool search --onlyvisible --name \".*\" 2>/dev/null"
    " | while read -r w; do"
    "   n=$(DISPLAY=${DISPLAY:-:0} xdotool getwindowname \"$w\" 2>/dev/null);"
    "   p=$(DISPLAY=${DISPLAY:-:0} xdotool getwindowpid \"$w\" 2>/dev/null);"
    "   printf '%s\\t%s\\t%s\\n' \"$w\" \"$p\" \"$n\";"
    " done",
    "r");
  if (fp == NULL)
    {
      return;
    }
  fprintf(stderr, "[windows after %s]\n", [label UTF8String]);
  char buf[512];
  while (fgets(buf, sizeof(buf), fp) != NULL)
    {
      fprintf(stderr, "  %s", buf);
    }
  pclose(fp);
}

static BOOL
runScript(NSString *abs, GSUITestResult *result)
{
  if (!fileExists(abs))
    {
      NSLog(@"UITest script missing: %@", abs);
      [result setStatus: GSUITestStatusError];
      [result setMessage: @"script missing"];
      [result setDetails: abs];
      return NO;
    }

  /* Pre-test setup: Workspace (when installed) must be up before the test so
   * a desktop crash earlier in the suite does not cascade into this one.  The
   * watchdog then fails the test if it exits while the script runs. */
  launchWorkspaceIfNeeded();

  double t0 = nowSeconds();

  BOOL watch = YES;
  /* Per-process CPU, as percent of ONE core (100% = a single core pegged).
   * A desktop component legitimately uses a core on a slow VM (QEMU BSD CI,
   * nested X) while rendering or answering DO queries, so the in-test trip is
   * set high enough to only catch a genuine sustained spin near 100%, and the
   * between-test settle check uses a higher floor than the old 15% - a healthy
   * but busy desktop on a slow VM would otherwise be flagged as a stuck loop
   * and the whole suite would fail after the first test.  The in-test trip
   * additionally requires the process's whole rolling window to be filled, so
   * a single 1s burst (window birth animation, full-screen damage repaint)
   * cannot fail a test - only a spin sustained across the whole window can.
   * Both stay tunable. */
  double threshold = 95.0;
  double idle = 95.0;
  int window = 4;
  /* Fail-fast wall-clock cap per script.  A wedged-but-alive desktop (stalled
   * DriveUI socket) trips neither the CPU nor the health watchdog, so without
   * this a stuck test would grind until the CI job's overall cap (240 min)
   * kills it.  The default is generous enough for the slowest legit script
   * (window_placement takes ~90s on the QEMU FreeBSD CI) but turns a hang
   * into a clean per-test error in about a minute. */
  double deadline = 120.0;
  const char *env;
  if ((env = getenv("UITEST_CPU_WATCH")) != NULL && strcmp(env, "off") == 0)
    {
      watch = NO;
    }
  if ((env = getenv("UITEST_CPU_THRESHOLD")) != NULL && *env != '\0')
    {
      threshold = atof(env);
    }
  if ((env = getenv("UITEST_CPU_SAMPLES")) != NULL && *env != '\0')
    {
      window = atoi(env);
    }
  if ((env = getenv("UITEST_CPU_IDLE")) != NULL && *env != '\0')
    {
      idle = atof(env);
    }
  if ((env = getenv("UITEST_TEST_TIMEOUT")) != NULL && *env != '\0')
    {
      deadline = atof(env);
    }

  NSTask *task = [[NSTask alloc] init];
  [task setLaunchPath:runner];
  [task setArguments:[NSArray arrayWithObject:abs]];

  /* Redirect stderr to a temp file rather than a pipe: scripts launch apps
   * (Processes, ...) that inherit the stderr fd and outlive the task,
   * so reading a pipe to EOF would deadlock.  A file's contents are complete
   * on disk regardless of who still holds the fd. */
  char tmpl[] = "/tmp/uitest_err_XXXXXX";
  int errFd = mkstemp(tmpl);
  if (errFd < 0)
    {
      [task release];
      NSLog(@"%s: cannot create stderr temp file", [abs UTF8String]);
      [result setStatus: GSUITestStatusError];
      [result setMessage: @"cannot create stderr temp file"];
      [result setDetails: abs];
      return NO;
    }
  NSString *errPath = [NSString stringWithUTF8String:tmpl];
  NSFileHandle *errOut = [[NSFileHandle alloc] initWithFileDescriptor: errFd
    closeOnDealloc: YES];
  [task setStandardError: errOut];
  [task launch];        /* a launch failure raises; PASS records it */

  pthread_t thr;
  CPUWatchdog watchdog;
  memset(&watchdog, 0, sizeof(watchdog));
  if (watch)
    {
      watchdog.task = task;
      watchdog.watchPids[0] = pidOfName(@"Menu");
      watchdog.watchNames[0] = "Menu.app";
      watchdog.watchPgrepNames[0] = "Menu";
      watchdog.watchPids[1] = pidOfName(@"Workspace");
      watchdog.watchNames[1] = "Workspace";
      watchdog.watchPgrepNames[1] = "Workspace";
      watchdog.watchPids[2] = pidOfName(@"WindowManager");
      watchdog.watchNames[2] = "WindowManager";
      watchdog.watchPgrepNames[2] = "WindowManager";
      watchdog.watchPids[3] = (pid_t)[task processIdentifier];
      watchdog.watchNames[3] = "run_uitest";
      watchdog.watchPgrepNames[3] = "run_uitest";
      watchdog.watchCount = 4;
      watchdog.threshold = threshold;
      watchdog.windowSize = window;
      watchdog.deadline = nowSeconds() + deadline;
      watchdog.deadlineLimit = deadline;
      /* Make the watch visible in the log once, so a silent pid-resolution
       * failure (e.g. pgrep missing from PATH) cannot go unnoticed. */
      if (getenv("UITEST_VERBOSE") != NULL)
        NSLog(@"CPU watchdog on: Menu=%d Workspace=%d WindowManager=%d "
          "runner=%d (threshold %.0f%%, window %d s, health watch on)",
          watchdog.watchPids[0], watchdog.watchPids[1], watchdog.watchPids[2],
          watchdog.watchPids[3], threshold, window);
      pthread_create(&thr, NULL, watchdogMain, &watchdog);
    }

  [task waitUntilExit];
  if (watch)
    {
      watchdog.stopped = YES;
      pthread_join(thr, NULL);
    }

  int status = [task terminationStatus];
  BOOL aborted = watchdog.triggered;
  double elapsed = nowSeconds() - t0;
  [result setDuration: elapsed];

  if (aborted)
    {
      /* A CPU/health trip is an infrastructure failure (a wedged desktop
       * component or a crash), not a test assertion - report it as an error. */
      NSLog(@"%s: %s", [abs UTF8String], watchdog.reason);
      [result setStatus: GSUITestStatusError];
      [result setMessage: [NSString stringWithUTF8String: watchdog.reason]];
      [result setDetails: [NSString stringWithUTF8String: watchdog.reason]];
      /* A CPU trip can still be diagnosed by its stack; a health trip has no
       * process left to attach to, and a deadline trip has no single culprit. */
      if (!watchdog.healthTrip && watchdog.culpritIndex >= 0)
        {
          captureStack(watchdog.watchPids[watchdog.culpritIndex],
            watchdog.watchNames[watchdog.culpritIndex]);
        }
      /* A health trip means a desktop component died: its own stderr (the
       * session logs from run-uitests.sh/uitest-session.sh) usually holds the
       * crash reason (a GNUstep exception or a signal handler note), so append
       * its tail to the details for the report.  The runner re-spawns
       * Workspace itself to /tmp/uitest_workspace.log too, so look at both. */
      if (watchdog.healthTrip)
        {
          NSString *tail = lastLinesOfLog(@"/tmp/uitest_ws.log", 30);
          if ([tail length] > 0)
            {
              [result setDetails: [[result details]
                stringByAppendingFormat: @"\n--- Workspace stderr tail ---\n%@", tail]];
            }
        }
    }
  else if (status != 0)
    {
      /* run_uitest prints one clean "UITEST FAIL <script> (<ms>)" line on
       * stdout, plus the detailed command log on stderr.  Show the structured
       * log (per-command SUCCESS/failure + the result line) but drop the
       * timestamped noise the launched apps spew on stderr - that is not part
       * of the test result. The filtered lines double as the JUnit failure
       * details; the last one is the short message. */
      NSData *data = [NSData dataWithContentsOfFile: errPath];
      NSString *msg = [[NSString alloc] initWithData:data
        encoding:NSUTF8StringEncoding];
      NSMutableString *details = [NSMutableString string];
      NSString *lastLine = nil;
      if (msg)
        {
          for (NSString *line in [msg componentsSeparatedByString: @"\n"])
            {
              if ([line length] == 0) continue;
              if ([line hasPrefix: @"2026-"]
                  || [line hasPrefix: @"Loading "]
                  || [line hasPrefix: @" INFO:"]
                  || [line hasPrefix: @"Loaded '"])
                continue;
              fprintf(stderr, "    %s\n", [line UTF8String]);
              if ([details length] > 0) [details appendString: @"\n"];
              [details appendString: line];
              lastLine = line;
            }
        }
      [result setMessage: lastLine
        ?: [NSString stringWithFormat: @"script failed (exit %d)", status]];
      [result setDetails: details];
      /* A parse or runtime error means the script could not be carried out
       * (a harness/test-definition problem); a timeout or a failed assertion
       * means it ran but the expected UI condition did not hold. */
      [result setStatus: (status == DDSParseError || status == DDSRuntimeError)
        ? GSUITestStatusError : GSUITestStatusFailed];
      NSLog(@"%s failed (exit %d)", [abs UTF8String], status);
      [msg release];
    }
  [errOut release];
  unlink([errPath UTF8String]);
  [task release];

  if (aborted)
    {
      return NO;
    }
  if (watch)
    {
      /* The desktop must return to idle between scripts; a process still
       * pegged here is a stuck spin that would corrupt every later test. */
      if (!checkSettled(idle))
        {
          NSLog(@"%s: desktop did not settle after the script", [abs UTF8String]);
          [result setStatus: GSUITestStatusError];
          [result setMessage: @"desktop did not settle after the script"];
          [result setDetails: @"a desktop component stayed pegged with no test driving it"];
          return NO;
        }
    }
  /* Only a genuinely clean run (no watchdog trip, no failure exit, no
   * settle problem) is a pass; the failure/abort/settle paths above already
   * recorded their status and must not be overwritten. */
  if (status == 0)
    {
      [result setStatus: GSUITestStatusPassed];
    }
  reportMappedWindows([abs lastPathComponent]);
  return status == 0;
}

/* UITEST_SEARCH_DIRS (set by TestInfo or the cross-repo driver) is a
 * colon-separated list of directories to scan.  Fall back to $GSTESTROOT.
 */
static NSArray *
searchDirs(void)
{
  const char *env = getenv("UITEST_SEARCH_DIRS");
  NSMutableArray *dirs = [NSMutableArray array];
  if (env != NULL)
    {
      for (NSString *part in [[NSString stringWithUTF8String:env]
        componentsSeparatedByString:@":"])
        {
          if ([part length] > 0)
            {
              [dirs addObject:part];
            }
        }
    }
  if ([dirs count] == 0)
    {
      const char *root = getenv("GSTESTROOT");
      NSString *base = root ? [NSString stringWithUTF8String:root] : @".";
      [dirs addObject:[base stringByStandardizingPath]];
    }
  return dirs;
}

/* Recursively collect *.uitest files (paths relative to root) under root. */
static NSArray *
collectScripts(NSString *root)
{
  NSMutableArray *scripts = [NSMutableArray array];
  NSDirectoryEnumerator *it = [[NSFileManager defaultManager]
    enumeratorAtPath:root];
  NSString *rel;
  while ((rel = [it nextObject]) != nil)
    {
      if ([[rel pathExtension] isEqualToString:@"uitest"])
        {
          [scripts addObject:rel];
        }
    }
  return [scripts sortedArrayUsingSelector:@selector(compare:)];
}

/* Path relative to the sources root, for unambiguous log messages. */
static NSString *
displayPath(NSString *abs)
{
  NSString *prefix = [sourcesRoot stringByAppendingString:@"/"];
  if ([abs hasPrefix:prefix])
    {
      return [abs substringFromIndex:[prefix length]];
    }
  return abs;
}

/* Write the JUnit report: print the XML on stdout (for tooling that captures
 * it) and, when UITEST_JUNIT_OUTPUT names a file, write it there too so CI
 * can collect it as an artifact.  A skipped suite still emits a report (with
 * the skip recorded) so CI consumers always find a junit.xml. */
static void
writeJUnitReport(NSArray *results, double suiteSeconds)
{
  GSUITestJUnitReporter *reporter = [[[GSUITestJUnitReporter alloc] init]
    autorelease];
  NSString *junit = [reporter xmlStringWithResults: results
    suiteTime: suiteSeconds];

  /* The JUnit report is the machine-readable result: print it last, on
   * stdout, so CI tooling can capture it (e.g. run-uitests.sh redirects it to
   * a file) without parsing the human-oriented PASS/FAIL lines.  Printed
   * before the pool is released: the report is autoreleased. */
  printf("%s", [junit UTF8String]);
  const char *outEnv = getenv("UITEST_JUNIT_OUTPUT");
  if (outEnv != NULL && *outEnv != '\0')
    {
      NSString *outPath = [NSString stringWithUTF8String: outEnv];
      NSString *dir = [outPath stringByDeletingLastPathComponent];
      if ([dir length] > 0)
        {
          [[NSFileManager defaultManager] createDirectoryAtPath: dir
            withIntermediateDirectories: YES attributes: nil error: NULL];
        }
      NSError *werr = nil;
      if ([junit writeToFile: outPath atomically: YES
        encoding: NSUTF8StringEncoding error: &werr])
        {
          fprintf(stderr, "JUnit report written to %s\n", [outPath UTF8String]);
        }
      else
        {
          fprintf(stderr, "JUnit report: cannot write %s: %s\n",
            [outPath UTF8String],
            werr ? [[werr localizedDescription] UTF8String] : "unknown error");
        }
    }
}

int
main()
{
  CREATE_AUTORELEASE_POOL(pool);
  BOOL suite = YES;
  BOOL full = NO;

  /* Whole-suite gating.  SKIP() only works inside a set and aborts the
   * whole set (see Testing.h and example9.m), so the prerequisites are one
   * set at the top.  DISPLAY/run_uitest missing -> skip the suite;
   * Menu/Workspace not running on a live desktop -> hard failures. */
  START_SET("prerequisites")
  if (getenv("DISPLAY") == NULL)
    {
      suite = NO;
      SKIP("no DISPLAY - the UI tests need a desktop session.\nRun them with gnustep-tests on a running Gershwin desktop.")
    }
  if (suite && !fileExists(runner))
    {
      suite = NO;
      SKIP("run_uitest is not installed.\nInstall the DriveUI tools to run the UI tests.")
    }
  if (suite && system("command -v xdotool >/dev/null 2>&1") != 0)
    {
      suite = NO;
      SKIP("xdotool is not on PATH.\nReal key events for global grabs (Cmd+Space etc.) need it; install it (e.g. via bootstrap.sh) to run the UI tests.")
    }
  if (suite)
    {
      BOOL menuRunning = processRunning(@"Menu");
      BOOL wsInstalled = appInstalled(@"Workspace");
      const char *wsMsg = wsInstalled
        ? "Workspace is available (started before each test if needed)"
        : "Workspace not installed (skipped)";
      PASS(menuRunning, "Menu.app is running");
      PASS(YES, "%s", wsMsg);
      if (!menuRunning)
        {
          suite = NO;
        }
    }
  END_SET("prerequisites")

  if (!suite)
    {
      /* The suite was skipped (missing prerequisite).  Still emit a JUnit
       * report with the skip recorded so CI consumers find a junit.xml even
       * when nothing ran. */
      NSMutableArray *results = [NSMutableArray array];
      GSUITestResult *r = [[GSUITestResult alloc] init];
      [r setClassName: @"prerequisites"];
      [r setName: @"uitest suite"];
      [r setDuration: 0.001];
      [r setStatus: GSUITestStatusSkipped];
      [r setMessage: @"suite skipped (missing prerequisite)"];
      [results addObject:r];
      [r release];
      writeJUnitReport(results, 0.0);
      RELEASE(pool);
      return 0;
    }

  if (getenv("UI_TEST_LEVEL") != NULL
    && strcmp(getenv("UI_TEST_LEVEL"), "full") == 0)
    {
      full = YES;
    }

  /* Group scripts by the directory they live in, keyed by the path relative
   * to /Developer/Library/Sources so identical folder names in different
   * repositories stay separate. */
  NSMutableDictionary *groups = [NSMutableDictionary dictionary];
  for (NSString *root in searchDirs())
    {
      for (NSString *rel in collectScripts(root))
        {
          NSString *abs = [root stringByAppendingPathComponent:rel];
          NSString *key =
            [displayPath(abs) stringByDeletingLastPathComponent];
          NSMutableArray *list = [groups objectForKey:key];
          if (list == nil)
            {
              list = [NSMutableArray array];
              [groups setObject:list forKey:key];
            }
          [list addObject:abs];
        }
    }
  PASS([groups count] > 0, "found at least one UITest script");

  int failures = 0;
  int run = 0;
  double suiteStart = nowSeconds();
  NSMutableArray *results = [NSMutableArray array];
  for (NSString *group in
    [[groups allKeys] sortedArrayUsingSelector:@selector(compare:)])
    {
      if ([[group pathComponents] containsObject:@"heavy"] && !full)
        {
          const char *gname = [group UTF8String];
          START_SET(gname)
          SKIP("scripts under 'heavy' need UI_TEST_LEVEL=full.\nThese scripts launch external apps (Chrome, Viking); run with 'UI_TEST_LEVEL=full gnustep-tests .' to enable them.")
          END_SET(gname)
          /* Skipped tests are still part of the report, so the JUnit counts
           * match what a CI consumer expects to see. */
          for (NSString *abs in [groups objectForKey:group])
            {
              GSUITestResult *r = [[GSUITestResult alloc] init];
              [r setClassName: group];
              [r setName: displayPath(abs)];
              [r setDuration: 0.001];
              [r setStatus: GSUITestStatusSkipped];
              [r setMessage: @"scripts under 'heavy' need UI_TEST_LEVEL=full"];
              [results addObject:r];
              [r release];
            }
          continue;
        }
      const char *gname = [group UTF8String];
      START_SET(gname)
      for (NSString *abs in [groups objectForKey:group])
        {
          GSUITestResult *r = [[GSUITestResult alloc] init];
          [r setClassName: group];
          [r setName: displayPath(abs)];
          BOOL ok = runScript(abs, r);
          PASS(ok, "%s", [displayPath(abs) UTF8String]);
          run++;
          if (!ok)
            {
              failures++;
            }
          [results addObject:r];
          [r release];
        }
      END_SET(gname)
    }

  double suiteSeconds = nowSeconds() - suiteStart;
  writeJUnitReport(results, suiteSeconds);

  /* One clean, greppable summary line: the harness exit status gates 'make
   * test' / CI, and this is the at-a-glance PASS/FAIL count for humans. */
  fprintf(stderr, "UITEST SUMMARY: %d run, %d failed, %d passed\n",
    run, failures, run - failures);

  RELEASE(pool);
  /* A failed uitest must fail the process: 'make test' in gershwin-developer
   * (and any CI wrapper) gates on the exit status. */
  return failures > 0 ? 1 : 0;
}
