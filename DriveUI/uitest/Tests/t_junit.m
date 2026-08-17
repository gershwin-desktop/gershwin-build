/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * t_junit - ObjectTesting coverage for the JUnit result model and serializer
 * (DriveUI/uitest/JUnitReporter.m), following probonopd's uitest.md
 * specification. The tests are named after the spec rules they prove:
 * structure (5-7), escaping (8), duration/timing (21), determinism (21).
 */

#import <Foundation/Foundation.h>
#import "Testing.h"
#import "../JUnitReporter.h"

static GSUITestResult *
makeResult(NSString *cls, NSString *name, GSUITestStatus st, double dur,
           NSString *msg, NSString *details)
{
  GSUITestResult *r = [[[GSUITestResult alloc] init] autorelease];
  [r setClassName: cls];
  [r setName: name];
  [r setStatus: st];
  [r setDuration: dur];
  [r setMessage: msg];
  [r setDetails: details];
  return r;
}

int
main(void)
{
  NSAutoreleasePool *arp = [[NSAutoreleasePool alloc] init];
  GSUITestJUnitReporter *rep = [[[GSUITestJUnitReporter alloc] init]
    autorelease];
  NSString *xml;
  NSRange r;

  /* --- spec section 5/6: document structure and aggregate counts --- */
  {
    NSArray *rs = [NSArray arrayWithObjects:
      makeResult(@"MenuTests", @"menu_assert.uitest", GSUITestStatusPassed,
        1.203, nil, nil),
      nil];
    xml = [rep xmlStringWithResults: rs suiteTime: 1.203];
    PASS([xml hasPrefix: @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"],
      "document starts with the UTF-8 XML declaration");
    r = [xml rangeOfString: @"<testsuites name=\"GNUstep UI Tests\" "
      @"tests=\"1\" failures=\"0\" errors=\"0\" skipped=\"0\" time=\"1.203\">"];
    PASS(r.location != NSNotFound, "testsuites carries the run aggregates");
    r = [xml rangeOfString: @"<testsuite name=\"MenuTests\" tests=\"1\" "
      @"failures=\"0\" errors=\"0\" skipped=\"0\" time=\"1.203\">"];
    PASS(r.location != NSNotFound, "testsuite carries its own aggregates");
    r = [xml rangeOfString: @"<testcase classname=\"MenuTests\" "
      @"name=\"menu_assert.uitest\" time=\"1.203\"/>"];
    PASS(r.location != NSNotFound, "a passing testcase is self-closing");
  }

  /* --- spec section 7: failure / error / skipped testcases --- */
  {
    NSArray *rs = [NSArray arrayWithObjects:
      makeResult(@"LoginTests", @"testBadPassword", GSUITestStatusFailed,
        1.417, @"Expected login error to be displayed",
        @"Expected login error to be displayed.\nActual UI state did not "
        @"contain the error message."),
      makeResult(@"LoginTests", @"testLaunch", GSUITestStatusError,
        0.502, @"Application launch failed",
        @"Application did not present its main window within the timeout."),
      makeResult(@"LoginTests", @"testBiometric", GSUITestStatusSkipped,
        0.001, nil, nil),
      nil];
    xml = [rep xmlStringWithResults: rs suiteTime: 2.500];
    r = [xml rangeOfString: @"<failure message=\"Expected login error to be "
      @"displayed\">Expected login error to be displayed.\nActual UI state "
      @"did not contain the error message.</failure>"];
    PASS(r.location != NSNotFound,
      "a failed test is a <failure> with message and multiline details");
    r = [xml rangeOfString: @"<error message=\"Application launch failed\">"
      @"Application did not present its main window within the timeout."
      @"</error>"];
    PASS(r.location != NSNotFound, "an errored test is an <error>");
    r = [xml rangeOfString: @"<skipped/>"];
    PASS(r.location != NSNotFound, "a skipped test is a <skipped/>");
    r = [xml rangeOfString: @"tests=\"3\" failures=\"1\" errors=\"1\" "
      @"skipped=\"1\""];
    PASS(r.location != NSNotFound, "aggregates reflect all three statuses");
    /* A successful test must not carry a failure or error element. */
    NSArray *ok = [NSArray arrayWithObjects:
      makeResult(@"X", @"a", GSUITestStatusPassed, 0.1, @"not used", @"not used"),
      nil];
    NSString *okXml = [rep xmlStringWithResults: ok suiteTime: 0.1];
    PASS([okXml rangeOfString: @"<failure"].location == NSNotFound
         && [okXml rangeOfString: @"<error"].location == NSNotFound,
      "a passing test has no failure or error element");
  }

  /* --- spec section 8: XML escaping --- */
  {
    NSArray *rs = [NSArray arrayWithObjects:
      makeResult(@"A&B<\"C>", @"a<b&c>d", GSUITestStatusFailed, 0.001,
        @"bad <tag> & \"quoted\" 'apos'", @"line1\nline2 & <tag>"),
      nil];
    xml = [rep xmlStringWithResults: rs suiteTime: 0.001];
    r = [xml rangeOfString: @"classname=\"A&amp;B&lt;&quot;C&gt;\" "
      @"name=\"a&lt;b&amp;c&gt;d\""];
    PASS(r.location != NSNotFound,
      "classname/name escape & < > and \"");
    r = [xml rangeOfString: @"message=\"bad &lt;tag&gt; &amp; &quot;quoted&quot; "
      @"&apos;apos&apos;\""];
    PASS(r.location != NSNotFound, "attribute escapes all five XML specials");
    r = [xml rangeOfString: @"line1\nline2 &amp; &lt;tag&gt;</failure>"];
    PASS(r.location != NSNotFound,
      "text content keeps newlines literal and escapes & and <");
  }

  /* --- spec section 8: newlines in attributes are character references --- */
  {
    NSArray *rs = [NSArray arrayWithObjects:
      makeResult(@"G", @"n", GSUITestStatusError, 0.001,
        @"first line\nsecond line", nil),
      nil];
    xml = [rep xmlStringWithResults: rs suiteTime: 0.001];
    r = [xml rangeOfString: @"message=\"first line&#10;second line\""];
    PASS(r.location != NSNotFound,
      "a newline in an attribute becomes a character reference");
  }

  /* --- spec section 21: millisecond durations, locale-independent --- */
  {
    NSArray *rs = [NSArray arrayWithObjects:
      makeResult(@"T", @"t1", GSUITestStatusPassed, 1.0, nil, nil),
      makeResult(@"T", @"t2", GSUITestStatusPassed, 1.2034, nil, nil),
      makeResult(@"T", @"t3", GSUITestStatusPassed, 0.0004, nil, nil),
      nil];
    xml = [rep xmlStringWithResults: rs suiteTime: 8.34];
    PASS([xml rangeOfString: @"time=\"1.000\""].location != NSNotFound,
      "whole seconds render with three decimals");
    PASS([xml rangeOfString: @"time=\"1.203\""].location != NSNotFound,
      "fractional seconds are rounded to milliseconds");
    PASS([xml rangeOfString: @"time=\"0.000\""].location != NSNotFound
         || [xml rangeOfString: @"time=\"0.001\""].location != NSNotFound,
      "sub-millisecond duration still renders a three-decimal time");
    PASS([xml rangeOfString: @"time=\"8.340\""].location != NSNotFound,
      "suite time uses three decimals");
    PASS([xml rangeOfString: @","].location == NSNotFound,
      "no locale comma appears anywhere in the document");
  }

  /* --- spec section 21: deterministic ordering --- */
  {
    NSArray *rs = [NSArray arrayWithObjects:
      makeResult(@"GroupA", @"a1", GSUITestStatusPassed, 0.1, nil, nil),
      makeResult(@"GroupB", @"b1", GSUITestStatusFailed, 0.2, @"m", @"d"),
      makeResult(@"GroupB", @"b2", GSUITestStatusPassed, 0.3, nil, nil),
      nil];
    NSString *x1 = [rep xmlStringWithResults: rs suiteTime: 0.6];
    NSString *x2 = [rep xmlStringWithResults: rs suiteTime: 0.6];
    PASS([x1 isEqualToString: x2], "same input yields identical output");

    /* Contiguous equal classnames form one suite; a suite boundary splits. */
    r = [xml rangeOfString: @"<testsuite name=\"T\""];
    /* x1 must contain exactly two suites in input order. */
    NSUInteger suites = 0;
    NSRange scan = NSMakeRange(0, [x1 length]);
    while (scan.location < [x1 length])
      {
        NSRange hit = [x1 rangeOfString: @"<testsuite " options: 0
          range: scan];
        if (hit.location == NSNotFound) break;
        suites++;
        scan.location = hit.location + hit.length;
        scan.length = [x1 length] - scan.location;
      }
    PASS(suites == 2, "one <testsuite> per distinct classname, in run order");
    PASS([x1 rangeOfString: @"<testsuite name=\"GroupA\""].location
         < [x1 rangeOfString: @"<testsuite name=\"GroupB\""].location,
      "suites are serialized in the order they were collected");
  }

  /* --- empty run: a report with no tests is still valid --- */
  {
    xml = [rep xmlStringWithResults: [NSArray array] suiteTime: 0.0];
    PASS([xml rangeOfString: @"tests=\"0\" failures=\"0\" errors=\"0\" "
      @"skipped=\"0\""].location != NSNotFound,
      "an empty run produces a valid zero-count report");
  }

  [arp release];
  return 0;
}