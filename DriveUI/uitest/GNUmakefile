include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = run_uitest

# Resolve app names via their X11 windows (_NET_WM_PID / WM_CLASS) using the
# shared X11Support helper, so name->pid never needs to probe /tmp sockets.
X11_CFLAGS := $(shell pkg-config --cflags x11 2>/dev/null)
X11_LIBS := $(shell pkg-config --libs x11 2>/dev/null)
ifeq ($(strip $(X11_LIBS)),)
X11_LIBS := -lX11
endif

ADDITIONAL_INCLUDE_DIRS += $(X11_CFLAGS) -I..
ADDITIONAL_LDFLAGS += $(X11_LIBS)

run_uitest_OBJC_FILES = main.m UITestParser.m UITestLexer.m UITestQueryEngine.m UITestExecutor.m ../X11Support.m
run_uitest_LIBRARIES = gnustep-base objc

include $(GNUSTEP_MAKEFILES)/tool.make

PREFIX ?= /
BINDIR ?= $(GNUSTEP_SYSTEM_TOOLS)
ifeq ($(BINDIR),)
BINDIR := /System/Library/Tools
endif

after-install::
	mkdir -p $(DESTDIR)$(BINDIR)
	install -m 0755 obj/run_uitest $(DESTDIR)$(BINDIR)/run_uitest

after-uninstall::
	rm -f $(DESTDIR)$(BINDIR)/run_uitest