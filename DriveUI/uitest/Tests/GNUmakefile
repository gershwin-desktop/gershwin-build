# __GENERATED__ makefile marker
#

include $(GNUSTEP_MAKEFILES)/common.make
GNUSTEP_INSTALLATION_DOMAIN = SYSTEM

GNUSTEP_OBJ_DIR=./obj

# uitest_tests - the canonical DriveUI UI test harness.  Builds and runs every
# .uitest script found under UITEST_SEARCH_DIRS; it is installed to
# /System/Library/Tools so gershwin-developer's "make test" can invoke it on a
# built desktop (see Library/Scripts/run-uitests.sh).
TOOL_NAME = uitest_tests

ADDITIONAL_CPPFLAGS += -I$(GNUSTEP_MAKEFILES)/TestFramework

ADDITIONAL_OBJCFLAGS += -Wno-deprecated
ADDITIONAL_OBJCCFLAGS += -Wno-deprecated

uitest_tests_OBJC_FILES=uitest_tests.m
uitest_tests_LIBRARIES = gnustep-gui gnustep-base objc

include $(GNUSTEP_MAKEFILES)/tool.make

PREFIX ?= /
BINDIR ?= $(GNUSTEP_SYSTEM_TOOLS)
ifeq ($(BINDIR),)
BINDIR := /System/Library/Tools
endif

after-install::
	mkdir -p $(DESTDIR)$(BINDIR)
	install -m 0755 obj/uitest_tests $(DESTDIR)$(BINDIR)/uitest_tests

after-uninstall::
	rm -f $(DESTDIR)$(BINDIR)/uitest_tests

after-clean::
	rm -f core core.* *.core \
	test_*.out test_*.err \
	tests.log tests.sum oldtests.log oldtests.sum

