/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Lexer for the GNUstep UI Automation UITest (see UITest.h / Executor.md).
 *
 * The language is line-oriented: each line is one command.  Comments run from
 * '#' to end of line.  Strings are double-quoted and support the escapes
 * \\ \" \n \t.  Everything else is a Word token (keywords, roles, keys,
 * durations, identifiers) - duration parsing happens in the parser/executor.
 */

#import "UITest.h"

@implementation DSSToken
- (id)initWithType:(DSSTokenType)t text:(NSString *)text line:(NSUInteger)line col:(NSUInteger)col
{
  if ((self = [super init]))
    {
      type_ = t;
      text_ = [text copy];
      line_ = line;
      col_ = col;
    }
  return self;
}
- (DSSTokenType)type { return type_; }
- (NSString *)text { return text_; }
- (NSUInteger)line { return line_; }
- (NSUInteger)col { return col_; }
@end

@implementation DSSLexer

static void SkipToEOL(NSString *src, NSUInteger *idx, NSUInteger *line, NSUInteger *col)
{
  while (*idx < [src length])
    {
      unichar c = [src characterAtIndex: *idx];
      if (c == '\n') { break; }
      (*idx)++;
      (*col)++;
    }
}

- (NSArray *)tokenize:(NSString *)source error:(NSString **)err
{
  NSMutableArray *tokens = [NSMutableArray array];
  NSUInteger idx = 0, line = 1, col = 1;
  NSUInteger len = [source length];

  while (idx < len)
    {
      unichar c = [source characterAtIndex: idx];

      /* whitespace (other than newline) */
      if (c == ' ' || c == '\t' || c == '\r')
        {
          idx++;
          col++;
          continue;
        }
      /* comment */
      if (c == '#')
        {
          SkipToEOL(source, &idx, &line, &col);
          continue;
        }
      /* newline ends the current command */
      if (c == '\n')
        {
          [tokens addObject: [[[DSSToken alloc] initWithType: DSSTokenNewline
            text: @"\n" line: line col: col] autorelease]];
          idx++;
          line++;
          col = 1;
          continue;
        }
      /* string literal */
      if (c == '"')
        {
          NSUInteger startLine = line, startCol = col;
          idx++;
          col++;
          NSMutableString *str = [NSMutableString string];
          BOOL closed = NO;
          while (idx < len)
            {
              c = [source characterAtIndex: idx];
              if (c == '\\')
                {
                  idx++;
                  col++;
                  if (idx >= len) break;
                  unichar e = [source characterAtIndex: idx];
                  if (e == 'n') [str appendString: @"\n"];
                  else if (e == 't') [str appendString: @"\t"];
                  else if (e == '\\') [str appendString: @"\\"];
                  else if (e == '"') [str appendString: @"\""];
                  else { [str appendFormat: @"%C", e]; }
                  idx++;
                  col++;
                }
              else if (c == '"')
                {
                  idx++;
                  col++;
                  closed = YES;
                  break;
                }
              else if (c == '\n')
                {
                  if (err) *err = [NSString stringWithFormat: @"%lu:%lu: unterminated string",
                    (unsigned long)line, (unsigned long)col];
                  return nil;
                }
              else
                {
                  [str appendFormat: @"%C", c];
                  idx++;
                  col++;
                }
            }
          if (!closed)
            {
              if (err) *err = [NSString stringWithFormat: @"%lu:%lu: unterminated string",
                (unsigned long)startLine, (unsigned long)startCol];
              return nil;
            }
          [tokens addObject: [[[DSSToken alloc] initWithType: DSSTokenString
            text: str line: startLine col: startCol] autorelease]];
          continue;
        }
      /* word: any run of non-space, non-quote, non-newline characters */
      {
        NSUInteger startLine = line, startCol = col;
        NSMutableString *word = [NSMutableString string];
        while (idx < len)
          {
            c = [source characterAtIndex: idx];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '"' || c == '#')
              break;
            [word appendFormat: @"%C", c];
            idx++;
            col++;
          }
        if ([word length] == 0)
          {
            if (err) *err = [NSString stringWithFormat: @"%lu:%lu: unexpected character '%C'",
              (unsigned long)line, (unsigned long)col, c];
            return nil;
          }
        [tokens addObject: [[[DSSToken alloc] initWithType: DSSTokenWord
          text: word line: startLine col: startCol] autorelease]];
      }
    }

  [tokens addObject: [[[DSSToken alloc] initWithType: DSSTokenEOF text: @"<eof>"
    line: line col: col] autorelease]];
  return tokens;
}

@end