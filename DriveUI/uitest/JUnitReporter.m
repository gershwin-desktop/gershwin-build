/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * JUnit result model and serializer (see JUnitReporter.h). GNUstep's
 * NSXMLDocument is not reliable enough to serialize a report on every
 * supported platform, so the serializer is a small self-contained writer with
 * explicit escaping (the specification permits this: section 8 "MAY use a
 * small internal XML serialization implementation"). Durations are formatted
 * in the C locale so a comma-decimal locale cannot corrupt the "1.203"
 * representation (spec section 21).
 */

#import "JUnitReporter.h"

@implementation GSUITestResult
- (NSString *)name { return name_; }
- (NSString *)className { return className_; }
- (double)duration { return duration_; }
- (GSUITestStatus)status { return status_; }
- (NSString *)message { return message_; }
- (NSString *)details { return details_; }
- (void)setName:(NSString *)name
{
  [name_ release];
  name_ = [name copy];
}
- (void)setClassName:(NSString *)name
{
  [className_ release];
  className_ = [name copy];
}
- (void)setDuration:(double)seconds { duration_ = seconds; }
- (void)setStatus:(GSUITestStatus)status { status_ = status; }
- (void)setMessage:(NSString *)message
{
  [message_ release];
  message_ = [message copy];
}
- (void)setDetails:(NSString *)details
{
  [details_ release];
  details_ = [details copy];
}
- (void)dealloc
{
  [name_ release];
  [className_ release];
  [message_ release];
  [details_ release];
  [super dealloc];
}
@end

/* Escape text node content: the five XML special characters only; newlines are
 * legal literal text in element content (spec section 8). */
static NSString *
xmlEscapeText(NSString *s)
{
  if (s == nil) return @"";
  NSMutableString *out = [NSMutableString stringWithCapacity: [s length]];
  NSUInteger len = [s length];
  for (NSUInteger i = 0; i < len; i++)
    {
      unichar c = [s characterAtIndex: i];
      switch (c)
        {
          case '&': [out appendString: @"&amp;"]; break;
          case '<': [out appendString: @"&lt;"]; break;
          case '>': [out appendString: @"&gt;"]; break;
          default:  [out appendFormat: @"%C", c];
        }
    }
  return out;
}

/* Escape an attribute value: the five special characters plus the whitespace
 * control characters, which XML requires as character references inside
 * attributes (spec section 8). */
static NSString *
xmlEscapeAttr(NSString *s)
{
  if (s == nil) return @"";
  NSMutableString *out = [NSMutableString stringWithCapacity: [s length]];
  NSUInteger len = [s length];
  for (NSUInteger i = 0; i < len; i++)
    {
      unichar c = [s characterAtIndex: i];
      switch (c)
        {
          case '&':  [out appendString: @"&amp;"]; break;
          case '<':  [out appendString: @"&lt;"]; break;
          case '>':  [out appendString: @"&gt;"]; break;
          case '"':  [out appendString: @"&quot;"]; break;
          case '\'': [out appendString: @"&apos;"]; break;
          case '\n': [out appendString: @"&#10;"]; break;
          case '\r': [out appendString: @"&#13;"]; break;
          case '\t': [out appendString: @"&#9;"]; break;
          default:   [out appendFormat: @"%C", c];
        }
    }
  return out;
}

/* Seconds with exactly three decimals and a '.' decimal separator, independent
 * of the process locale (spec section 21). The value is rounded to whole
 * milliseconds and formatted with integer conversions only, so no %f is
 * involved and a comma-decimal locale cannot corrupt the decimal point. */
static NSString *
formatSeconds(double s)
{
  long totalMillis = (long)llround(s * 1000.0);
  long secs = totalMillis / 1000;
  long millis = totalMillis % 1000;
  char buf[64];
  snprintf(buf, sizeof(buf), "%ld.%03ld", secs, millis);
  return [NSString stringWithUTF8String: buf];
}

static NSString *
testcaseXML(GSUITestResult *r)
{
  NSMutableString *s = [NSMutableString string];
  [s appendFormat: @"    <testcase classname=\"%@\" name=\"%@\" time=\"%@\"",
    xmlEscapeAttr([r className]), xmlEscapeAttr([r name]),
    formatSeconds([r duration])];
  switch ([r status])
    {
      case GSUITestStatusPassed:
        [s appendString: @"/>\n"];
        break;
      case GSUITestStatusFailed:
        [s appendFormat: @">\n      <failure message=\"%@\">%@</failure>\n"
          @"    </testcase>\n",
          xmlEscapeAttr([r message]), xmlEscapeText([r details])];
        break;
      case GSUITestStatusError:
        [s appendFormat: @">\n      <error message=\"%@\">%@</error>\n"
          @"    </testcase>\n",
          xmlEscapeAttr([r message]), xmlEscapeText([r details])];
        break;
      case GSUITestStatusSkipped:
        [s appendString: @">\n      <skipped/>\n    </testcase>\n"];
        break;
    }
  return s;
}

@implementation GSUITestJUnitReporter

- (NSString *)xmlStringWithResults:(NSArray *)results
                         suiteTime:(double)suiteSeconds
{
  int tests = 0, failures = 0, errors = 0, skipped = 0;
  for (GSUITestResult *r in results)
    {
      tests++;
      switch ([r status])
        {
          case GSUITestStatusPassed:  break;
          case GSUITestStatusFailed:  failures++; break;
          case GSUITestStatusError:   errors++; break;
          case GSUITestStatusSkipped: skipped++; break;
        }
    }
  NSMutableString *xml = [NSMutableString string];
  [xml appendString: @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
  [xml appendFormat: @"<testsuites name=\"GNUstep UI Tests\" tests=\"%d\" "
    @"failures=\"%d\" errors=\"%d\" skipped=\"%d\" time=\"%@\">\n",
    tests, failures, errors, skipped, formatSeconds(suiteSeconds)];
  NSUInteger i = 0;
  while (i < [results count])
    {
      NSString *cls = [[results objectAtIndex: i] className];
      int t = 0, f = 0, e = 0, s = 0;
      double gtime = 0.0;
      NSMutableString *cases = [NSMutableString string];
      while (i < [results count]
             && [[[results objectAtIndex: i] className] isEqualToString: cls])
        {
          GSUITestResult *r = [results objectAtIndex: i];
          t++;
          gtime += [r duration];
          switch ([r status])
            {
              case GSUITestStatusPassed:  break;
              case GSUITestStatusFailed:  f++; break;
              case GSUITestStatusError:   e++; break;
              case GSUITestStatusSkipped: s++; break;
            }
          [cases appendString: testcaseXML(r)];
          i++;
        }
      [xml appendFormat: @"  <testsuite name=\"%@\" tests=\"%d\" failures=\"%d\" "
        @"errors=\"%d\" skipped=\"%d\" time=\"%@\">\n%@  </testsuite>\n",
        xmlEscapeAttr(cls), t, f, e, s, formatSeconds(gtime), cases];
    }
  [xml appendString: @"</testsuites>\n"];
  return xml;
}

@end