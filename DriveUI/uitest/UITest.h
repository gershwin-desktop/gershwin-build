/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * GNUstep UI Automation UITest (Executor.md) - lexer, AST, parser and executor.
 *
 * The interpreter is deliberately split along the doc's architecture:
 *   Lexer  -> tokens
 *   Parser -> AST (UITestCommand nodes)
 *   Executor -> walks the AST and translates each node into a semantic query
 *               answered by the QueryEngine (the drive_ui engine).
 * No GNUstep-specific logic lives in the executor; it only issues queries.
 */

#import <Foundation/Foundation.h>

/* ---------------------------------------------------------------------------
 * Lexer tokens.
 * ------------------------------------------------------------------------ */

typedef enum
{
  DSSTokenWord,      /* identifiers, roles, keys, durations, operators */
  DSSTokenString,    /* "..." (already unescaped) */
  DSSTokenNewline,   /* a command boundary */
  DSSTokenEOF
} DSSTokenType;

@interface DSSToken : NSObject
{
  DSSTokenType type_;
  NSString *text_;
  NSUInteger line_;
  NSUInteger col_;
}
- (id)initWithType:(DSSTokenType)t text:(NSString *)text line:(NSUInteger)line col:(NSUInteger)col;
@property (readonly) DSSTokenType type;
@property (readonly) NSString *text;
@property (readonly) NSUInteger line;
@property (readonly) NSUInteger col;
@end

@interface DSSLexer : NSObject
- (NSArray *)tokenize:(NSString *)source error:(NSString **)err;
@end

/* ---------------------------------------------------------------------------
 * AST nodes.
 * ------------------------------------------------------------------------ */

typedef enum
{
  DDSCmdActivate,
  DDSCmdActivateXWindow,
  DDSCmdLaunchApp,
  DDSCmdFocusWindow,
  DDSCmdCloseWindow,
  DDSCmdSelectMenu,
  DDSCmdSelectGlobalMenu,
  DDSCmdInvokeButton,
  DDSCmdClick,
  DDSCmdDoubleClick,
  DDSCmdRightClick,
  DDSCmdContextMenu,
  DDSCmdHover,
  DDSCmdScroll,
  DDSCmdDrag,
  DDSCmdType,
  DDSCmdClear,
  DDSCmdPress,
  DDSCmdRun,
  DDSCmdWait,
  DDSCmdWaitUntil,
  DDSCmdAssert,
  DDSCmdCapture,
  DDSCmdRecord,
  DDSCmdLog,
  DDSCmdSet,
  DDSCmdOptions,
  DDSCmdRepeat,
  DDSCmdIf,
  DDSCmdMacro,
  DDSCmdCall,
  DDSCmdSetCount
} UITestCommandType;

typedef enum
{
  DDSRoleAny,
  DDSRoleApplication,
  DDSRoleWindow,
  DDSRoleXWindow,
  DDSRoleDialog,
  DDSRoleModal,
  DDSRoleSidebar,
  DDSRoleSheet,
  DDSRoleButton,
  DDSRoleMenu,
  DDSRoleMenuItem,
  DDSRoleTextField,
  DDSRoleTextArea,
  DDSRoleCheckbox,
  DDSRoleRadio,
  DDSRolePopup,
  DDSRoleComboBox,
  DDSRoleTable,
  DDSRoleRow,
  DDSRoleColumn,
  DDSRoleList,
  DDSRoleImage,
  DDSRoleToolbar,
  DDSRoleTab,
  DDSRoleTabItem,
  DDSRoleSlider,
  DDSRoleProgress,
  DDSRoleLabel,
  DDSRoleIcon
} UITestRole;

NSString *UITestRoleClassName(UITestRole role);   /* maps a role to an ObjC class filter */
UITestRole UITestRoleFromName(NSString *name);    /* maps the UITest role keyword to UITestRole */

typedef enum
{
  DDSAssertExists,
  DDSAssertEnabled,
  DDSAssertChecked,
  DDSAssertContains,
  DDSAssertNotExists,
  DDSAssertFrameConstant,
  DDSAssertDocked,
  DDSAssertNotDocked,
  DDSAssertMenuExists,
  DDSAssertMenuNotExists,
  DDSAssertMenuChecked,
  DDSAssertMenuNotChecked,
  DDSAssertMenuEnabled,
  DDSAssertMenuDisabled,
  DDSAssertMenuShortcut,
  DDSAssertXWindowCount,
  DDSAssertMenuBar,
  DDSAssertMenuBarNot
} UITestAssertKind;

@interface UITestCommand : NSObject
{
  UITestCommandType type_;
  UITestRole role_;
  UITestAssertKind assertKind_;
  NSString *string_;       /* the quoted main string (title/text/path)   */
  NSString *string2_;      /* optional second string (e.g. assert target) */
  NSMutableArray *words_;  /* free-form word tokens for this command */
  NSMutableArray *body_;   /* sub-commands of a repeat/if/macro block    */
  NSMutableArray *elseBody_; /* sub-commands of an if block's else clause */
  NSUInteger line_;
  NSUInteger col_;
}
- (id)initWithType:(UITestCommandType)t line:(NSUInteger)line col:(NSUInteger)col;
@property UITestCommandType type;
@property UITestRole role;
@property UITestAssertKind assertKind;
@property (retain) NSString *string;
@property (retain) NSString *string2;
@property (readonly) NSMutableArray *words;
@property (readonly) NSMutableArray *body;
@property (readonly) NSMutableArray *elseBody;
@property NSUInteger line;
@property NSUInteger col;
@end

/* A parsed program: an ordered list of commands plus declared variables. */
@interface UITestProgram : NSObject
{
  NSMutableArray *commands_;
  NSMutableDictionary *variables_;
  NSString *currentDef_;
}
@property (readonly) NSMutableArray *commands;
@property (readonly) NSMutableDictionary *variables;
@property (retain) NSString *currentDef;
@end

@interface UITestParser : NSObject
{
  NSMutableArray *blockStack_; /* nested repeat/if/macro block contexts */
}
- (UITestProgram *)parseFile:(NSString *)path error:(NSString **)err;
- (UITestProgram *)parseString:(NSString *)text sourceName:(NSString *)name
                     program:(UITestProgram *)prog error:(NSString **)err;
@end

/* ---------------------------------------------------------------------------
 * Executor + QueryEngine.
 * ------------------------------------------------------------------------ */

typedef enum
{
  DDSSuccess = 0,
  DDSParseError = 1,
  DDSRuntimeError = 2,
  DDSTimeout = 3,
  DDSAccessibilityError = 4,
  DDSAssertFailed = 5
} DDSExitCode;

@class UITestExecutor;

/* The QueryEngine hides all drive_ui/X11 interaction from the executor.
 * The UITest executor only translates AST nodes into these semantic calls. */
@interface UITestQueryEngine : NSObject
{
  int pid_;          /* target app pid (0 until resolveApplication:) */
  NSString *appName_;
  NSString *driveTool_; /* path to the drive_ui binary */
  NSMutableDictionary *localizeCache_; /* english -> localized, per app */
}
- (id)initWithDriveTool:(NSString *)toolPath;
- (BOOL)resolveApplication:(NSString *)name error:(NSString **)err;
- (BOOL)activate:(NSString **)err;                      /* raise + focus main window */
- (BOOL)activateXWindow:(NSString *)title error:(NSString **)err;
- (BOOL)launchApplication:(NSString *)name error:(NSString **)err;
- (BOOL)focusMainWindow:(NSString **)err;
- (int)pid;
- (NSString *)appName;

- (BOOL)doesWidgetExist:(UITestRole)role title:(NSString *)title
           contains:(NSString *)needle error:(NSString **)err;
- (NSString *)frameOfWindowTitle:(NSString *)title error:(NSString **)err;
- (BOOL)closeWindowTitle:(NSString *)title error:(NSString **)err;
- (BOOL)invokeModalButton:(NSString *)which error:(NSString **)err;
- (BOOL)clickRole:(UITestRole)role title:(NSString *)title
          button:(int)button count:(int)count error:(NSString **)err;
- (BOOL)hoverRole:(UITestRole)role title:(NSString *)title error:(NSString **)err;
- (BOOL)contextMenuRole:(UITestRole)role title:(NSString *)title
              itemTitle:(NSString *)itemTitle error:(NSString **)err;
- (BOOL)scrollRole:(UITestRole)role title:(NSString *)title
        direction:(NSString *)direction amount:(int)amount error:(NSString **)err;
- (BOOL)dragRole:(UITestRole)role title:(NSString *)title
            byX:(double)dx byY:(double)dy error:(NSString **)err;
- (BOOL)selectMenuPath:(NSString *)path error:(NSString **)err;
- (BOOL)assertMenuItemPath:(NSString *)path kind:(UITestAssertKind)kind
                  shortcut:(NSString *)shortcut error:(NSString **)err;
- (BOOL)assertXWindowCount:(NSString *)title op:(NSString *)op
                  expected:(int)expected error:(NSString **)err;
- (BOOL)menuBarHasItem:(NSString *)title exists:(BOOL)exists error:(NSString **)err;
- (int)countXWindowsWithTitle:(NSString *)title error:(NSString **)err;
- (BOOL)triggerGlobalMenuPath:(NSString *)path error:(NSString **)err;
- (BOOL)runCommandInRunDialog:(NSString *)command error:(NSString **)err;
- (NSString *)localizeString:(NSString *)english;
- (BOOL)type:(NSString *)text error:(NSString **)err;
- (BOOL)clearRole:(UITestRole)role title:(NSString *)title error:(NSString **)err;
- (BOOL)pressKeyCombo:(NSString *)combo error:(NSString **)err;

/* Dump the current visible widget tree as text (used by `record`).  Returns
 * nil if there is no target application. */
- (NSString *)widgetTreeText;

/* Read the live properties (enabled/checked) of the widget matching role+title.
 * Both out params may be NULL.  Uses drive_ui's read-only `props` command. */
- (BOOL)propsForRole:(UITestRole)role title:(NSString *)title
             enabled:(BOOL *)enabled checked:(BOOL *)checked error:(NSString **)err;

/* Capture the current screen to an X11 window shot.  path may be nil for a
 * default filename; returns the file written via `outPath`. */
- (BOOL)captureScreenshotToPath:(NSString *)path outPath:(NSString **)outPath
                          error:(NSString **)err;

- (BOOL)assertRole:(UITestRole)role title:(NSString *)title kind:(UITestAssertKind)kind
        needle:(NSString *)needle error:(NSString **)err;
@end

/* Walks UITestProgram.commands sequentially, applying the error policy. */
@interface UITestExecutor : NSObject
{
  UITestProgram *program_;
  UITestQueryEngine *engine_;
  NSString *policy_;      /* stop/continue/retry */
  int retryCount_;
  NSMutableString *log_;
  NSMutableDictionary *macros_; /* macro name -> body (built before running) */
  NSMutableDictionary *frameRefs_; /* window title -> first observed frame */
}
- (id)initWithProgram:(UITestProgram *)program engine:(UITestQueryEngine *)engine;
- (int)run;
@property (readonly) NSString *log;
@end