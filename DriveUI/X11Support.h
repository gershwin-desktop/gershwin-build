/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import <Foundation/Foundation.h>

@interface X11Support : NSObject

// Discovery
+ (NSArray *)windowList;
+ (NSDictionary *)windowInfo:(unsigned long)xid;

// Input Simulation
+ (void)simulateMouseMoveTo:(NSPoint)point;
+ (void)simulateClick:(int)button; // 1=left, 2=middle, 3=right
+ (void)simulateKeyStroke:(NSString *)keyString;

// Press button 1 at the current pointer position and drag by the given pixel
// offset, releasing over the end position (moving windows, sliders,
// scrollbars, drag-and-drop).
+ (void)simulateDragBy:(NSPoint)delta;

// Emit `count` wheel steps at the current pointer position.  direction is one
// of "up"/"down"/"left"/"right" (X buttons 4/5/6/7).
+ (void)simulateScrollWheel:(NSString *)direction count:(int)count;

// Raise + focus a window so subsequent keyboard input is delivered to it rather
// than an occluding window. Needed because the desktop usually has overlapping
// windows.
+ (void)activateWindow:(unsigned long)xid;

// Send a single key with zero or more modifiers held (e.g. Control+c, or just
// Return) — for shortcuts and menu accelerators that plain text typing cannot
// express. Modifier names: "control"/"ctrl", "alt"/"meta", "shift",
// "super"/"win". The key is either a single character or an X keysym name such
// as "Return", "Left" or "F5".
+ (void)simulateChordWithModifiers:(NSArray *)modifiers key:(NSString *)key;

// Pixel height of screen 0, for converting GNUstep's bottom-origin screen
// coordinates to X11's top-origin root coordinates before injecting input.
+ (int)screenHeight;

// Give the X input focus to a mapped window belonging to the given process, so
// subsequently injected key events reach that application.  In a window-managed
// desktop the target app is usually NOT the input-focus owner (focus often
// stays on the terminal), and key injection needs the focus on the app for
// GNUstep to route the events to its key window.
+ (void)setFocusToPID:(int)pid;

// Find a top-level X window whose name contains `title` (case-insensitive).
// Works for any app, GNUstep or not.  Only real application windows are
// considered (mapped, not override-redirect, normal/dialog/utility type per
// ICCCM/EWMH), so window-manager-internal windows are excluded.  Returns the
// window id or 0.
+ (unsigned long)findWindowWithTitle:(NSString *)title;

// Count the application windows (same filtering as findWindowWithTitle:)
// whose name contains `title`.
+ (NSUInteger)countWindowsWithTitle:(NSString *)title;

// Like findWindowWithTitle: but also matches viewable non-application windows
// (e.g. the desktop); used when activating a window to switch focus.
+ (unsigned long)findViewableWindowWithTitle:(NSString *)title;

// True if a windowInfo: dictionary describes a real top-level application
// window (ICCCM/EWMH filter used by the whole-display scans).
+ (BOOL)isAppWindow:(NSDictionary *)info;

@end
