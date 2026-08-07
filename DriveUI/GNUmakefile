include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = DriveUI
BUNDLE_EXTENSION = .bundle

DriveUI_OBJC_FILES = DriveUI.m
DriveUI_PRINCIPAL_CLASS = DriveUI
DriveUI_LIBRARIES = gnustep-base gnustep-gui objc

include $(GNUSTEP_MAKEFILES)/bundle.make

PREFIX ?= /
BUNDLEDIR ?= $(GNUSTEP_SYSTEM_LIBRARY)/Bundles
ifeq ($(BUNDLEDIR),)
BUNDLEDIR := /System/Library/Bundles
endif

after-install::
	mkdir -p $(DESTDIR)$(BUNDLEDIR)
	cp -R DriveUI.bundle $(DESTDIR)$(BUNDLEDIR)/DriveUI.bundle

after-uninstall::
	rm -rf $(DESTDIR)$(BUNDLEDIR)/DriveUI.bundle
