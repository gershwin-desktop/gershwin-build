/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * JUnit result model and serializer for the GNUstep UI test suite, following
 * probonopd's uitest.md specification (gist 0985bd8ca3d0431f4d4f3ab139994b78).
 *
 * The model (GSUITestResult) is framework-neutral: a test run produces
 * results, reporters consume them. GSUITestJUnitReporter serializes a list
 * of results into one JUnit XML document (spec sections 5-8, 21).
 */

#import <Foundation/Foundation.h>

typedef enum
{
  GSUITestStatusPassed,
  GSUITestStatusFailed,
  GSUITestStatusSkipped,
  GSUITestStatusError
} GSUITestStatus;

/* One test (a .uitest script) and its outcome. */
@interface GSUITestResult : NSObject
{
  NSString *name_;       /* test name, e.g. the script path */
  NSString *className_;  /* test suite/group the test belongs to */
  double duration_;      /* elapsed wall time in seconds */
  GSUITestStatus status_;
  NSString *message_;    /* short one-line summary */
  NSString *details_;    /* extended diagnostic text (may be multiline) */
}
- (NSString *)name;
- (NSString *)className;
- (double)duration;
- (GSUITestStatus)status;
- (NSString *)message;
- (NSString *)details;
- (void)setName:(NSString *)name;
- (void)setClassName:(NSString *)name;
- (void)setDuration:(double)seconds;
- (void)setStatus:(GSUITestStatus)status;
- (void)setMessage:(NSString *)message;
- (void)setDetails:(NSString *)details;
@end

/* Serializes collected GSUITestResult objects into one JUnit XML document. */
@interface GSUITestJUnitReporter : NSObject

/* Build the full XML document (with declaration) for the given results.
 * Results must be ordered group by group (they are, coming from the harness);
 * contiguous equal classnames form one <testsuite>. suiteTime is the elapsed
 * wall-clock time of the whole run, reported on the <testsuites> element. */
- (NSString *)xmlStringWithResults:(NSArray *)results
                         suiteTime:(double)suiteSeconds;

@end