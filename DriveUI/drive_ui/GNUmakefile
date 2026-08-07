include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = drive_ui

# X11 input simulation via X11Support (vendored here; it used to live in
# UIBridge/Server, which is being retired).  Injects synthetic XSendEvent
# events, so it needs only core Xlib plus the XKB client API.  Discover flags
# with pkg-config so this builds on Linux and the BSDs.
X11_PKGS := x11
X11_CFLAGS := $(shell pkg-config --cflags $(X11_PKGS) 2>/dev/null)
X11_LIBS := $(shell pkg-config --libs $(X11_PKGS) 2>/dev/null)
ifeq ($(strip $(X11_LIBS)),)
X11_LIBS := -lX11
endif

ADDITIONAL_INCLUDE_DIRS += $(X11_CFLAGS) -I..
ADDITIONAL_LDFLAGS += $(X11_LIBS)

drive_ui_OBJC_FILES = main.m ../X11Support.m
drive_ui_LIBRARIES = gnustep-base gnustep-gui objc

include $(GNUSTEP_MAKEFILES)/tool.make

PREFIX ?= /
BINDIR ?= $(GNUSTEP_SYSTEM_TOOLS)
ifeq ($(BINDIR),)
BINDIR := /System/Library/Tools
endif

after-install::
	mkdir -p $(DESTDIR)$(BINDIR)
	install -m 0755 obj/drive_ui $(DESTDIR)$(BINDIR)/drive_ui

after-uninstall::
	rm -f $(DESTDIR)$(BINDIR)/drive_ui
