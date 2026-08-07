/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * run_uitest - command-line runner for the GNUstep UI Automation UITest.
 *
 * Usage: run_uitest [--drive-ui /path/to/drive_ui] script.uitest
 *
 * Parses the script into a UITestProgram, hands it to the UITestExecutor, and exits
 * with the UITest exit-code convention (see Executor.md section 20).
 */

#import <Foundation/Foundation.h>
#import <sys/time.h>
#import "UITest.h"

int main(int argc, const char *argv[])
{
  setenv("GNUSTEP_SYSTEM_ROOT", "/System", 1);
  setenv("GNUSTEP_LOCAL_ROOT", "/Local", 1);
  setenv("GNUSTEP_NETWORK_ROOT", "/Network", 1);
  setenv("GNUSTEP_USER_ROOT", "/Local/Users/admin/.GNUstep", 1);
  setbuf(stdout, NULL);

  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  NSString *driveTool = @"/System/Library/Tools/drive_ui";
  NSString *script = nil;
  for (int i = 1; i < argc; i++)
    {
      NSString *a = [NSString stringWithUTF8String: argv[i]];
      if ([a isEqualToString: @"--drive-tool"] && i + 1 < argc)
        driveTool = [NSString stringWithUTF8String: argv[++i]];
      else if ([a hasSuffix: @".uitest"] || script == nil)
        script = a;
    }

  if (!script)
    {
      fprintf(stderr,
        "Usage: run_uitest [--drive-tool /path/to/drive_ui] script.uitest\n");
      [pool release];
      return DDSParseError;
    }

  UITestParser *parser = [[[UITestParser alloc] init] autorelease];
  NSString *err = nil;
  UITestProgram *prog = [parser parseFile: script error: &err];
  if (!prog)
    {
      fprintf(stderr, "run_uitest: %s\n", [err UTF8String]);
      [pool release];
      return DDSParseError;
    }

  UITestQueryEngine *engine = [[[UITestQueryEngine alloc] initWithDriveTool: driveTool]
    autorelease];
  UITestExecutor *exec = [[[UITestExecutor alloc] initWithProgram: prog engine: engine]
    autorelease];
  struct timeval t0, t1;
  gettimeofday(&t0, NULL);
  int rc = [exec run];
  gettimeofday(&t1, NULL);
  double totalMs = (t1.tv_sec - t0.tv_sec) * 1000.0
    + (t1.tv_usec - t0.tv_usec) / 1000.0;

  /* Always print the timed command log so slow commands (e.g. a dialog-driven
   * select menu) are visible when tuning script speed. */
  if ([[exec log] length] > 0)
    fprintf(stderr, "%s\n", [[exec log] UTF8String]);
  fprintf(stderr, "[uitest] total %.0f ms (%s)\n", totalMs,
    rc == 0 ? "ok" : "failed");
  [pool release];
  return rc;
}