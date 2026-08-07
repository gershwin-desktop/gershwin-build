include $(GNUSTEP_MAKEFILES)/common.make

TOOL_NAME = run_uitest

run_uitest_OBJC_FILES = main.m UITestParser.m UITestLexer.m UITestQueryEngine.m UITestExecutor.m
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