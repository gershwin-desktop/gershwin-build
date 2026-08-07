/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#import "X11Support.h"
#import <X11/Xlib.h>
#import <X11/Xatom.h>
#import <X11/keysym.h>
#import <X11/XKBlib.h>
#include <unistd.h>

@implementation X11Support

static Display *display = NULL;

// How long to hold a synthetic button press before releasing it, so the press
// and release are not coalesced into a single zero-duration event.
static const useconds_t kPressHoldMicroseconds = 40000;  // 40 ms

// When typing a character by temporarily rebinding a spare keycode (the Unicode
// path), how long to let the keyboard-mapping change (MappingNotify) reach the
// target client before pressing the key, and to let it decode the press before
// we revert.
static const useconds_t kRemapSettleMicroseconds = 30000;  // 30 ms

// Xlib's default error handler calls exit() on any protocol error, which would
// take down this long-running automation server. A few codes are expected
// during automation — e.g. a BadWindow/BadDrawable/BadMatch from racing a window
// that closes mid-request — and are swallowed. Anything else is logged loudly
// but still tolerated, so genuine bugs stay visible without crashing the server.
static int NonFatalXError(Display *dpy, XErrorEvent *e) {
    switch (e->error_code) {
        case BadWindow:
        case BadDrawable:
        case BadMatch:
            NSDebugLLog(@"gwcomp", @"[X11Support] ignored transient X error %d (request %d)",
                        e->error_code, e->request_code);
            return 0;
        default:
            break;
    }
    char buf[256];
    XGetErrorText(dpy, e->error_code, buf, sizeof(buf));
    NSLog(@"[X11Support] X protocol error: %s (code %d, request %d) — continuing",
          buf, e->error_code, e->request_code);
    return 0;
}

+ (Display *)display {
    if (!display) {
        XSetErrorHandler(NonFatalXError);
        display = XOpenDisplay(NULL);
        if (!display) {
            NSDebugLLog(@"gwcomp", @"[X11Support] Failed to open X display");
        }
    }
    return display;
}

+ (void)cleanup {
    if (display) {
        XCloseDisplay(display);
        display = NULL;
    }
}

+ (NSArray *)windowList {
    Display *d = [self display];
    if (!d) return @[];

    Window root = DefaultRootWindow(d);
    Window parent;
    Window *children = NULL;
    unsigned int nchildren = 0;

    NSMutableArray *result = [NSMutableArray array];

    if (XQueryTree(d, root, &root, &parent, &children, &nchildren)) {
        for (unsigned int i = 0; i < nchildren; i++) {
            [result addObject:@(children[i])];
        }
        if (children) XFree(children);
    }

    return result;
}

+ (NSDictionary *)windowInfo:(unsigned long)xid {
    Display *d = [self display];
    if (!d) return nil;

    Window w = (Window)xid;
    XWindowAttributes attrs;
    if (!XGetWindowAttributes(d, w, &attrs)) {
        return nil;
    }

    // Get Property: _NET_WM_NAME or WM_NAME
    NSString *title = @"";
    char *name = NULL;
    if (XFetchName(d, w, &name) && name) {
        title = [NSString stringWithUTF8String:name];
        XFree(name);
    }
    // Chromium and other modern apps set only _NET_WM_NAME (UTF-8), not WM_NAME.
    if ([title length] == 0) {
        Atom netName = XInternAtom(d, "_NET_WM_NAME", True);
        if (netName != None) {
            Atom actualType;
            int actualFormat;
            unsigned long nItems;
            unsigned long bytesAfter;
            unsigned char *propName = NULL;
            if (XGetWindowProperty(d, w, netName, 0, 256, False,
                                   XInternAtom(d, "UTF8_STRING", False),
                                   &actualType, &actualFormat, &nItems,
                                   &bytesAfter, &propName) == Success) {
                if (propName) {
                    title = [NSString stringWithUTF8String:(const char *)propName];
                    XFree(propName);
                }
            }
        }
    }

    // Get PID: _NET_WM_PID
    unsigned long pid = 0;
    Atom atomPID = XInternAtom(d, "_NET_WM_PID", True);
    if (atomPID != None) {
        Atom actualType;
        int actualFormat;
        unsigned long nItems;
        unsigned long bytesAfter;
        unsigned char *propPID = NULL;
        if (XGetWindowProperty(d, w, atomPID, 0, 1, False, XA_CARDINAL,
                               &actualType, &actualFormat, &nItems, &bytesAfter, &propPID) == Success) {
            if (propPID) {
                pid = *((unsigned long *)propPID);
                XFree(propPID);
            }
        }
    }

    // Get _NET_WM_WINDOW_TYPE (EWMH).  The first atom in the list names the
    // window's role; internal window-manager windows (tooltips, menus, docks,
    // notifications, splashes) carry a non-normal type, which lets the
    // whole-display scan skip them.
    NSString *netWmType = @"";
    Atom atomType = XInternAtom(d, "_NET_WM_WINDOW_TYPE", True);
    if (atomType != None) {
        Atom actualType;
        int actualFormat;
        unsigned long nItems;
        unsigned long bytesAfter;
        unsigned char *propType = NULL;
        if (XGetWindowProperty(d, w, atomType, 0, 16, False, XA_ATOM,
                               &actualType, &actualFormat, &nItems, &bytesAfter, &propType) == Success) {
            if (propType && nItems > 0) {
                Atom *atoms = (Atom *)propType;
                char *name = XGetAtomName(d, atoms[0]);
                if (name) {
                    netWmType = [NSString stringWithUTF8String:name];
                    XFree(name);
                }
            }
            if (propType) XFree(propType);
        }
    }

    // WM_STATE is set by the window manager on the windows it manages.
    // Chromium keeps unmanaged internal helper windows (which look like normal
    // toplevels but are not WM-managed); excluding them keeps whole-display
    // scans and the menu's active-window tracking off them.  GNUstep windows
    // under the Gershwin WM may lack WM_STATE but always carry
    // _GNUSTEP_WM_ATTR, so accept either.
    BOOL wmManaged = NO;
    Atom atomWMState = XInternAtom(d, "WM_STATE", True);
    if (atomWMState != None) {
        Atom actualType;
        int actualFormat;
        unsigned long nItems;
        unsigned long bytesAfter;
        unsigned char *prop = NULL;
        if (XGetWindowProperty(d, w, atomWMState, 0, 1, False, AnyPropertyType,
                               &actualType, &actualFormat, &nItems, &bytesAfter, &prop) == Success) {
            wmManaged = (prop != NULL);
            if (prop) XFree(prop);
        }
    }
    if (!wmManaged) {
        Atom gsAtom = XInternAtom(d, "_GNUSTEP_WM_ATTR", True);
        if (gsAtom != None) {
            Atom actualType;
            int actualFormat;
            unsigned long nItems;
            unsigned long bytesAfter;
            unsigned char *prop = NULL;
            if (XGetWindowProperty(d, w, gsAtom, 0, 1, False, AnyPropertyType,
                                   &actualType, &actualFormat, &nItems, &bytesAfter, &prop) == Success) {
                wmManaged = (prop != NULL);
                if (prop) XFree(prop);
            }
        }
    }

    return @{
        @"id": @(w),
        @"x": @(attrs.x),
        @"y": @(attrs.y),
        @"width": @(attrs.width),
        @"height": @(attrs.height),
        @"map_state": @(attrs.map_state), // IsViewable=2
        @"title": title,
        @"pid": @(pid),
        @"override_redirect": @(attrs.override_redirect ? YES : NO),
        @"net_wm_type": netWmType,
        @"wm_managed": @(wmManaged)
    };
}

/* True if the dictionary from windowInfo: describes a real top-level
 * application window worth matching in a whole-display scan (per ICCCM/EWMH):
 * mapped, not override-redirect, and not one of the window-manager-internal
 * types (dock, tooltip, menu, notification, splash, desktop, ...).  Windows
 * with no _NET_WM_WINDOW_TYPE are assumed to be normal applications.  No
 * WM_STATE requirement: GNUstep windows do not carry it under the Gershwin
 * window manager. */
+ (BOOL)isAppWindow:(NSDictionary *)info {
    if (!info) return NO;
    if ([[info objectForKey: @"map_state"] intValue] != 2) return NO; // IsViewable
    if ([[info objectForKey: @"override_redirect"] boolValue]) return NO;
    if (![[info objectForKey: @"wm_managed"] boolValue]) return NO; // WM-managed or GNUstep
    NSString *type = [info objectForKey: @"net_wm_type"] ?: @"";
    if ([type length] == 0) return YES;
    if ([type hasPrefix: @"_NET_WM_WINDOW_TYPE_NORMAL"]
        || [type hasPrefix: @"_NET_WM_WINDOW_TYPE_DIALOG"]
        || [type hasPrefix: @"_NET_WM_WINDOW_TYPE_UTILITY"])
        return YES;
    return NO;
}

// True if the window carries _GNUSTEP_WM_ATTR. GNUstep sets this on every content
// window it creates, unconditionally (XGServerWindow.m), so it is the reliable
// marker of "a window the GNUstep backend will recognise" — unlike _NET_WM_PID,
// which is only set under an EWMH window manager and is also copied onto the frame.
static Bool HasGNUstepAttr(Display *d, Window w) {
    static Atom attr = None;
    if (attr == None) attr = XInternAtom(d, "_GNUSTEP_WM_ATTR", False);
    Atom type; int fmt; unsigned long n, after; unsigned char *data = NULL;
    if (XGetWindowProperty(d, w, attr, 0, 1, False, AnyPropertyType,
                           &type, &fmt, &n, &after, &data) != Success)
        return False;
    Bool has = (type != None);
    if (data) XFree(data);
    return has;
}

// Resolve the GNUstep content window under root point (x,y) and the point in that
// window's coordinates. Descends from root with XTranslateCoordinates to the
// deepest window under the point, remembering the deepest one bearing
// _GNUSTEP_WM_ATTR (the actual GNUstep window, not the reparenting WM frame).
// Falls back to the leaf window if none qualifies (bare server / non-GNUstep app).
static Window ResolveWindowAt(Display *d, int x, int y, int *outX, int *outY) {
    Window root = DefaultRootWindow(d);
    Window cur = root, chosen = None;
    int curX = x, curY = y, chX = x, chY = y;
    for (;;) {
        Window child = None;
        int dx = 0, dy = 0;
        if (!XTranslateCoordinates(d, root, cur, x, y, &dx, &dy, &child))
            break;
        curX = dx; curY = dy;                 // point in cur's coordinates
        if (cur != root && HasGNUstepAttr(d, cur)) {
            chosen = cur; chX = curX; chY = curY;
        }
        if (child == None) break;
        cur = child;
    }
    if (chosen == None) { chosen = cur; chX = curX; chY = curY; }
    *outX = chX; *outY = chY;
    return chosen;
}

// First GNUstep content window at or below w (depth first), or None.
static Window FindGNUstepWindowBelow(Display *d, Window w) {
    if (HasGNUstepAttr(d, w)) return w;
    Window root, parent, *kids = NULL;
    unsigned int n = 0;
    Window found = None;
    if (XQueryTree(d, w, &root, &parent, &kids, &n)) {
        for (unsigned int i = 0; i < n && found == None; i++)
            found = FindGNUstepWindowBelow(d, kids[i]);
        if (kids) XFree(kids);
    }
    return found;
}

// The GNUstep window that should receive keyboard input.  Keys are injected as
// XSendEvent events addressed to this window (not XTEST): the target app is
// usually not the X input-focus owner in a window-managed desktop, and XTEST
// keys would go to whatever holds focus.  X delivers the event to the client
// owning the addressed window, and GNUstep then routes it to its own key window
// (XGServerEvent.m:2231).  Prefer the input-focus window, descending into it
// for the GNUstep child when the frame itself holds focus; fall back to the
// window under the pointer.
static Window ResolveKeyTarget(Display *d) {
    Window focus = None;
    int revert = 0;
    XGetInputFocus(d, &focus, &revert);
    if (focus != None && focus != PointerRoot) {
        Window w = FindGNUstepWindowBelow(d, focus);
        if (w != None) return w;
    }
    Window root = DefaultRootWindow(d), r, child;
    int rx = 0, ry = 0, wx = 0, wy = 0;
    unsigned int mask = 0;
    if (XQueryPointer(d, root, &r, &child, &rx, &ry, &wx, &wy, &mask)) {
        int ox, oy;
        Window w = ResolveWindowAt(d, rx, ry, &ox, &oy);
        if (w != None) return w;
    }
    return focus;
}

// A real X server timestamp. GNUstep compares successive click times to detect
// multi-clicks (XGServerEvent.m:433); CurrentTime (0) would make every click look
// like a first click, so we round-trip a zero-length property append on a private
// window and read the timestamp the server stamps on the resulting PropertyNotify.
static Bool MatchTimestamp(Display *d, XEvent *e, XPointer arg) {
    return (e->type == PropertyNotify && e->xproperty.atom == *(Atom *)arg) ? True : False;
}
static Time ServerTime(Display *d) {
    static Window win = None;
    static Atom atom = None;
    if (win == None) {
        win = XCreateWindow(d, DefaultRootWindow(d), -10, -10, 1, 1, 0,
                            CopyFromParent, InputOnly, CopyFromParent, 0, NULL);
        XSelectInput(d, win, PropertyChangeMask);
        atom = XInternAtom(d, "_UIBRIDGE_TIMESTAMP", False);
    }
    XChangeProperty(d, win, atom, XA_CARDINAL, 8, PropModeAppend,
                    (unsigned char *)"", 0);
    XEvent e;
    XIfEvent(d, &e, MatchTimestamp, (XPointer)&atom);
    return e.xproperty.time;
}

// Pointer/key input is injected with XSendEvent events addressed to the
// GNUstep window that should receive them (see ResolveWindowAt / ResolveKeyTarget).
// Synthetic send_event events are NOT filtered by GNUstep's X backend when they
// name a GNUstep content window, so this needs no XTEST extension and works on
// every X server.  The earlier claim that clicks on modal alert buttons were
// dropped turned out to be a coordinate bug (the Y flip), not event filtering.
static void SendButton(Display *d, Window w, int wx, int wy, int rx, int ry,
                       Bool press, unsigned int button, unsigned int state, Time t) {
    XEvent e;
    memset(&e, 0, sizeof(e));
    e.type = press ? ButtonPress : ButtonRelease;
    e.xbutton.send_event = True;
    e.xbutton.display = d;
    e.xbutton.window = w;
    e.xbutton.root = DefaultRootWindow(d);
    e.xbutton.subwindow = None;
    e.xbutton.time = t;
    e.xbutton.x = wx; e.xbutton.y = wy;
    e.xbutton.x_root = rx; e.xbutton.y_root = ry;
    e.xbutton.state = state;
    e.xbutton.button = button;
    e.xbutton.same_screen = True;
    XSendEvent(d, w, True, press ? ButtonPressMask : ButtonReleaseMask, &e);
}

// Send a synthetic key event addressed to a specific GNUstep window.  This is
// how typing is injected (see ResolveKeyTarget): it works without the app
// holding the X input focus, which a window-managed desktop rarely guarantees.
static void SendKey(Display *d, Window w, KeyCode code,
                    Bool press, unsigned int state, Time t) {
    XEvent e;
    memset(&e, 0, sizeof(e));
    e.type = press ? KeyPress : KeyRelease;
    e.xkey.send_event = True;
    e.xkey.display = d;
    e.xkey.window = w;
    e.xkey.root = DefaultRootWindow(d);
    e.xkey.subwindow = None;
    e.xkey.time = t;
    e.xkey.x = 1; e.xkey.y = 1;
    e.xkey.x_root = 0; e.xkey.y_root = 0;
    e.xkey.state = state;
    e.xkey.keycode = code;
    e.xkey.same_screen = True;
    XSendEvent(d, w, True, press ? KeyPressMask : KeyReleaseMask, &e);
}

+ (void)simulateMouseMoveTo:(NSPoint)point {
    Display *d = [self display];
    if (!d) return;
    // Move the real pointer so callers can position the cursor (hover) and so a
    // subsequent click lands at the window under this location. Assumes screen 0.
    Window root = DefaultRootWindow(d);
    XWarpPointer(d, None, root, 0, 0, 0, 0, (int)point.x, (int)point.y);
    XSync(d, False);
}

+ (unsigned long)findWindowWithTitle:(NSString *)title {
    if (title == nil || [title length] == 0) return 0;
    for (NSNumber *wid in [self windowList]) {
        NSDictionary *info = [self windowInfo: [wid unsignedLongValue]];
        if (![self isAppWindow: info]) continue;
        NSString *t = [info objectForKey: @"title"] ?: @"";
        if ([t rangeOfString: title options: NSCaseInsensitiveSearch].location
              != NSNotFound)
            return [wid unsignedLongValue];
    }
    return 0;
}

/* Count the top-level application windows (see isAppWindow:) whose title
 * contains `title` (case-insensitive). */
+ (NSUInteger)countWindowsWithTitle:(NSString *)title {
    if (title == nil || [title length] == 0) return 0;
    NSUInteger count = 0;
    for (NSNumber *wid in [self windowList]) {
        NSDictionary *info = [self windowInfo: [wid unsignedLongValue]];
        if (![self isAppWindow: info]) continue;
        NSString *t = [info objectForKey: @"title"] ?: @"";
        if ([t rangeOfString: title options: NSCaseInsensitiveSearch].location
              != NSNotFound)
            count++;
    }
    return count;
}

/* Like findWindowWithTitle: but also matches non-application windows (e.g.
 * the desktop, which is _NET_WM_WINDOW_TYPE_DESKTOP) as long as they are
 * viewable and not override-redirect.  Used when ACTIVATING a window to switch
 * focus; counting/existence checks keep the stricter isAppWindow filter. */
+ (unsigned long)findViewableWindowWithTitle:(NSString *)title {
    if (title == nil || [title length] == 0) return 0;
    for (NSNumber *wid in [self windowList]) {
        NSDictionary *info = [self windowInfo: [wid unsignedLongValue]];
        if (!info) continue;
        if ([[info objectForKey: @"map_state"] intValue] != 2) continue; /* IsViewable */
        if ([[info objectForKey: @"override_redirect"] boolValue]) continue;
        NSString *t = [info objectForKey: @"title"] ?: @"";
        if ([t rangeOfString: title options: NSCaseInsensitiveSearch].location
              != NSNotFound)
            return [wid unsignedLongValue];
    }
    return 0;
}

+ (int)screenHeight {
    Display *d = [self display];
    if (!d) return 0;
    return DisplayHeight(d, DefaultScreen(d));
}

+ (void)setFocusToPID:(int)pid {
    Display *d = [self display];
    if (!d || pid <= 0) return;
    for (NSNumber *wid in [self windowList]) {
        NSDictionary *info = [self windowInfo: [wid unsignedLongValue]];
        if (!info || [[info objectForKey: @"pid"] intValue] != pid) continue;
        Window top = (Window)[wid unsignedLongValue];
        /* The top-level window may be the WM frame; the GNUstep backend
         * recognises its own content window (which carries _GNUSTEP_WM_ATTR)
         * and routes key events delivered to it to its key window. */
        Window gs = FindGNUstepWindowBelow(d, top);
        if (gs == None) continue;
        XSetInputFocus(d, gs, RevertToPointerRoot, CurrentTime);
        XSync(d, False);
        return;
    }
}

+ (void)simulateClick:(int)button {
    Display *d = [self display];
    if (!d) return;
    Window root = DefaultRootWindow(d), r, child;
    int rx = 0, ry = 0, wx = 0, wy = 0;
    unsigned int mask = 0;
    if (!XQueryPointer(d, root, &r, &child, &rx, &ry, &wx, &wy, &mask)) return;

    int tx, ty;
    Window target = ResolveWindowAt(d, rx, ry, &tx, &ty);
    Time t = ServerTime(d);
    unsigned int bmask = (button == 1) ? Button1Mask :
                         (button == 2) ? Button2Mask :
                         (button == 3) ? Button3Mask : 0;
    SendButton(d, target, tx, ty, rx, ry, True, (unsigned int)button, 0, t);
    XFlush(d);
    usleep(kPressHoldMicroseconds);  // hold so press/release aren't coalesced
    SendButton(d, target, tx, ty, rx, ry, False, (unsigned int)button, bmask, t + 1);
    XSync(d, False);
}

// Press button 1 where the pointer is now, move it smoothly in ~12 steps by
// the pixel delta, then release over the end position.  The real pointer
// motion (XWarpPointer generates genuine MotionNotify events) is what GNUstep
// app treats as the drag; press and release are sent as synthetic button
// events to the GNUstep window under each position.
+ (void)simulateDragBy:(NSPoint)delta {
    Display *d = [self display];
    if (!d) return;
    Window root = DefaultRootWindow(d), r, child;
    int rx = 0, ry = 0, wx = 0, wy = 0;
    unsigned int mask = 0;
    if (!XQueryPointer(d, root, &r, &child, &rx, &ry, &wx, &wy, &mask)) return;

    int tx = 0, ty = 0;
    Window target = ResolveWindowAt(d, rx, ry, &tx, &ty);
    Time t = ServerTime(d);
    SendButton(d, target, tx, ty, rx, ry, True, 1, 0, t);
    XFlush(d);
    usleep(kPressHoldMicroseconds);

    const int steps = 12;
    for (int i = 1; i <= steps; i++) {
        double frac = (double)i / steps;
        int nx = rx + (int)lround(delta.x * frac);
        int ny = ry + (int)lround(delta.y * frac);
        XWarpPointer(d, None, root, 0, 0, 0, 0, nx, ny);
        XSync(d, False);
        usleep(12000);
    }

    // Release over the final position, resolving the window there so a drag
    // that crosses windows ends at the target (drag-and-drop semantics).
    int frx = 0, fry = 0, ftx = 0, fty = 0;
    XQueryPointer(d, root, &r, &child, &frx, &fry, &wx, &wy, &mask);
    Window ftarget = ResolveWindowAt(d, frx, fry, &ftx, &fty);
    SendButton(d, ftarget, ftx, fty, frx, fry, False, 1, Button1Mask, t + 1);
    XSync(d, False);
}

// Emit wheel (or tilt) steps at the current pointer location.  Up/down/left/
// right are X buttons 4/5/6/7; each is a press/release addressed to the
// GNUstep window under the pointer, mirroring a real wheel notch so controls
// (scroll bars, NSScroller) advance by one unit per step.
+ (void)simulateScrollWheel:(NSString *)direction count:(int)count {
    Display *d = [self display];
    if (!d) return;
    NSString *dir = [direction lowercaseString];
    unsigned int button = 5;  /* down */
    if ([dir isEqualToString: @"up"]) button = 4;
    else if ([dir isEqualToString: @"left"]) button = 6;
    else if ([dir isEqualToString: @"right"]) button = 7;
    if (count <= 0) count = 1;

    Window root = DefaultRootWindow(d), r, child;
    int rx = 0, ry = 0, wx = 0, wy = 0;
    unsigned int mask = 0;
    if (!XQueryPointer(d, root, &r, &child, &rx, &ry, &wx, &wy, &mask)) return;

    int tx = 0, ty = 0;
    Window target = ResolveWindowAt(d, rx, ry, &tx, &ty);
    Time t = ServerTime(d);
    for (int i = 0; i < count; i++) {
        SendButton(d, target, tx, ty, rx, ry, True, button, 0, t); t++;
        XFlush(d);
        usleep(kPressHoldMicroseconds);
        SendButton(d, target, tx, ty, rx, ry, False, button, 0, t); t++;
        XSync(d, False);
        usleep(kPressHoldMicroseconds);
    }
}

+ (void)activateWindow:(unsigned long)xid {
    Display *d = [self display];
    if (!d || xid == 0) return;
    Window w = (Window)xid;
    Window root = DefaultRootWindow(d);

    // Standard EWMH request: ask the window manager to activate the window.
    // Source indication 2 ("pager") is the value WMs honour for automation; it
    // bypasses the focus-stealing prevention that ignores an application's own
    // (source 1) activation requests.
    Atom netActive = XInternAtom(d, "_NET_ACTIVE_WINDOW", False);
    XEvent e;
    memset(&e, 0, sizeof(e));
    e.type = ClientMessage;
    e.xclient.window = w;
    e.xclient.message_type = netActive;
    e.xclient.format = 32;
    e.xclient.data.l[0] = 2;            // source indication: pager / automation
    e.xclient.data.l[1] = CurrentTime;
    XSendEvent(d, root, False, SubstructureRedirectMask | SubstructureNotifyMask, &e);

    // Also update _NET_ACTIVE_WINDOW directly.  Some window managers (or the
    // bare-server case) never apply the ClientMessage, so Menu.app's
    // active-window tracking (which reads the property) would keep reporting
    // the previously active window.
    XChangeProperty(d, root, netActive, XA_WINDOW, 32, PropModeReplace,
                    (unsigned char *)&w, 1);

    // Fallback for WMs that ignore EWMH (or a bare server with no WM): raise the
    // top-level frame (walk up to the child of root) and set input focus on the
    // client window directly.
    Window cur = w, parent = w, retRoot = root, *children = NULL;
    unsigned int n = 0;
    while (XQueryTree(d, cur, &retRoot, &parent, &children, &n)) {
        if (children) { XFree(children); children = NULL; }
        if (parent == retRoot || parent == 0) break;
        cur = parent;
    }
    XRaiseWindow(d, cur);
    XSetInputFocus(d, w, RevertToParent, CurrentTime);
    XFlush(d);
}

// The keysym for a control char or, for printable ASCII/Latin-1, the codepoint
// itself (those keysyms equal the Unicode value). Returns NoSymbol if the
// character has no single keysym this way (e.g. emoji / CJK).
static KeySym KeysymForChar(unichar c) {
    switch (c) {
        case '\n': case '\r': return XK_Return;
        case '\t': return XK_Tab;
        case 0x1b: return XK_Escape;
        case 0x08: case 0x7f: return XK_BackSpace;
    }
    if (c >= 0x20 && c <= 0xff) return (KeySym)c;
    return NoSymbol;
}

// Type an arbitrary Unicode scalar that has no key on the active layout by
// temporarily binding it to an unused keycode, sending a press/release addressed
// to the target window, then restoring that keycode — the technique xdotool uses
// for general text. GNUstep refreshes its keymap on the MappingNotify our remap
// triggers (XGServerEvent.m:1499), then decodes the synthetic press to the bound
// codepoint. X maps a codepoint to the keysym 0x01000000 + codepoint.
static void TypeUnicodeScalar(Display *d, Window target, uint32_t scalar, Time *t) {
    int minKc = 0, maxKc = 0;
    XDisplayKeycodes(d, &minKc, &maxKc);
    int per = 0;
    KeySym *map = XGetKeyboardMapping(d, minKc, maxKc - minKc + 1, &per);
    if (!map || per <= 0) { if (map) XFree(map); return; }

    // Find a keycode whose every level is unbound, searching from the top of the
    // range where spares usually live.
    int spare = 0;
    for (int kc = maxKc; kc >= minKc && spare == 0; kc--) {
        Bool unbound = True;
        for (int l = 0; l < per; l++) {
            if (map[(kc - minKc) * per + l] != NoSymbol) { unbound = False; break; }
        }
        if (unbound) spare = kc;
    }
    if (spare == 0) {
        NSDebugLLog(@"gwcomp", @"[X11Support] no spare keycode to type U+%04X", scalar);
        XFree(map);
        return;
    }

    // X keysym for the scalar: codepoints U+0000..U+00FF are their own keysym
    // (Latin-1); U+0100 and above use the 0x01000000 direct-Unicode encoding.
    KeySym uni = (scalar <= 0xff) ? (KeySym)scalar : (0x01000000 | scalar);
    KeySym bind[2] = { uni, uni };  // levels 0 and 1 both map to the scalar
    XChangeKeyboardMapping(d, spare, 2, bind, 1);
    XSync(d, False);
    usleep(kRemapSettleMicroseconds);   // let the target client refresh its keymap

    SendKey(d, target, (KeyCode)spare, True, 0, *t); (*t)++;
    SendKey(d, target, (KeyCode)spare, False, 0, *t); (*t)++;
    XSync(d, False);
    usleep(kRemapSettleMicroseconds);   // let it decode the press before we revert

    // Restore the keycode's original (unbound) mapping.
    XChangeKeyboardMapping(d, spare, per, &map[(spare - minKc) * per], 1);
    XSync(d, False);
    XFree(map);
}

+ (void)simulateKeyStroke:(NSString *)keyString {
    Display *d = [self display];
    if (!d) return;
    Window target = ResolveKeyTarget(d);
    if (target == None) return;

    Time t = ServerTime(d);
    NSUInteger len = [keyString length];
    for (NSUInteger i = 0; i < len; i++) {
        unichar c = [keyString characterAtIndex:i];
        uint32_t scalar = c;
        // Combine a UTF-16 surrogate pair into one Unicode scalar (e.g. emoji).
        if (c >= 0xd800 && c <= 0xdbff && i + 1 < len) {
            unichar lo = [keyString characterAtIndex:i + 1];
            if (lo >= 0xdc00 && lo <= 0xdfff) {
                scalar = 0x10000 + (((uint32_t)c - 0xd800) << 10) + ((uint32_t)lo - 0xdc00);
                i++;
            }
        }

        // Fast path: characters that exist on the active layout are typed
        // directly. When the character sits on the keycode's shifted level, set
        // ShiftMask in the event's state so GNUstep's character lookup picks the
        // shifted symbol (so 'A', '!', '?', ':' come out right, not their twin).
        // XKeysymToKeycode finds a keycode that yields the character at any
        // level, so only trust the result when that keycode actually produces
        // the character unshifted or shifted. A character that needs a higher
        // level (e.g. '~' is level 4 on the German layout, whose bare key types
        // '+') must fall through to the Unicode remap path instead of pressing
        // the bare key and getting its level-0 twin.
        KeySym sym = (scalar <= 0xffff) ? KeysymForChar((unichar)scalar) : NoSymbol;
        KeyCode code = (sym != NoSymbol) ? XKeysymToKeycode(d, sym) : 0;
        if (code != 0) {
            KeySym lvl0 = XkbKeycodeToKeysym(d, code, 0, 0);
            KeySym lvl1 = XkbKeycodeToKeysym(d, code, 0, 1);
            if (lvl0 == sym || lvl1 == sym) {
                unsigned int st = (lvl0 == sym) ? 0 : ShiftMask;
                SendKey(d, target, code, True, st, t); t++;
                SendKey(d, target, code, False, st, t); t++;
                XFlush(d);
                continue;
            }
        }

        // Slow path: any other scalar (accented Latin not on this layout, CJK,
        // emoji) via a temporary keymap remap.
        TypeUnicodeScalar(d, target, scalar, &t);
    }
    XSync(d, False);
}

// Map a modifier name to its left-hand keysym; NoSymbol if unrecognised.
static KeySym ModifierKeysym(NSString *name) {
    NSString *m = [name lowercaseString];
    if ([m isEqualToString:@"control"] || [m isEqualToString:@"ctrl"]) return XK_Control_L;
    if ([m isEqualToString:@"alt"] || [m isEqualToString:@"meta"]) return XK_Alt_L;
    if ([m isEqualToString:@"shift"]) return XK_Shift_L;
    if ([m isEqualToString:@"super"] || [m isEqualToString:@"win"]) return XK_Super_L;
    return NoSymbol;
}

// The X modifier-mask bit (ShiftMask, ControlMask, Mod1Mask…) bound to a modifier
// keysym, by scanning the modifier map; 0 if unbound. Used so a chord's character
// is looked up at the right shift level (GNUstep's character lookup honours the
// event state, even though its *modifier flags* come from tracked key presses).
static unsigned int ModMaskForKeysym(Display *d, KeySym sym) {
    KeyCode target = XKeysymToKeycode(d, sym);
    if (target == 0) return 0;
    XModifierKeymap *mm = XGetModifierMapping(d);
    if (!mm) return 0;
    unsigned int mask = 0;
    for (int i = 0; i < 8 && mask == 0; i++) {
        for (int j = 0; j < mm->max_keypermod; j++) {
            if (mm->modifiermap[i * mm->max_keypermod + j] == target) {
                mask = (1u << i);
                break;
            }
        }
    }
    XFreeModifiermap(mm);
    return mask;
}

// Resolve a chord key string to a keysym: a single character via KeysymForChar,
// otherwise an X keysym name ("Return", "Left", "F5", "Tab").
static KeySym ChordKeysym(NSString *key) {
    if ([key length] == 1) {
        KeySym s = KeysymForChar([key characterAtIndex:0]);
        if (s != NoSymbol) return s;
    }
    return XStringToKeysym([key UTF8String]);
}

+ (void)simulateChordWithModifiers:(NSArray *)modifiers key:(NSString *)key {
    Display *d = [self display];
    if (!d) return;

    KeySym ksym = ChordKeysym(key);
    if (ksym == NoSymbol) {
        NSDebugLLog(@"gwcomp", @"[X11Support] unknown chord key '%@'", key);
        return;
    }
    KeyCode code = XKeysymToKeycode(d, ksym);
    if (code == 0) return;

    Window target = ResolveKeyTarget(d);
    if (target == None) return;
    Time t = ServerTime(d);

    // Press the modifiers (so GNUstep tracks them and reports the right modifier
    // flags), accumulating their state mask so the key's character is looked up at
    // the correct shift level; tap the key; release the modifiers in reverse.
    KeyCode held[8];
    unsigned int state = 0;
    NSUInteger n = 0;
    for (id name in modifiers) {
        if (n >= 8 || ![name isKindOfClass:[NSString class]]) continue;
        KeySym ms = ModifierKeysym(name);
        if (ms == NoSymbol) continue;
        KeyCode mc = XKeysymToKeycode(d, ms);
        if (mc == 0) continue;
        state |= ModMaskForKeysym(d, ms);
        held[n++] = mc;
        SendKey(d, target, mc, True, 0, t); t++;
    }
    SendKey(d, target, code, True, state, t); t++;
    SendKey(d, target, code, False, state, t); t++;
    for (NSUInteger i = n; i > 0; i--) {
        SendKey(d, target, held[i - 1], False, 0, t); t++;
    }
    XSync(d, False);
}

@end
