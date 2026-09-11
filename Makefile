check_root:
	@if [ `id -u` -ne 0 ]; then \
		echo "This Makefile must be run as root or with sudo."; \
		exit 1; \
	fi

install: system

system: check_root
	@if [ -d "/System/Applications" ]; then \
		echo "Gershwin System Domain appears to be already installed."; \
	else \
		echo "Installing GNUstep System Domain..."; \
		FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh all; \
	fi

# Granular build targets. Each builds a single component from
# Library/Sources, assuming the core libraries are already installed
# (run "make corelibs" first). Useful for per-repo CI.
corelibs: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh corelibs

workspace: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh workspace

systempreferences: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh systempreferences

eau-theme: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh eau-theme

terminal: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh terminal

textedit: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh textedit

windowmanager: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh windowmanager

components: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh components

# DriveUI tooling (bundle, drive_ui, run_uitest, uitest_tests harness).
tooling: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh tooling

# Build the DriveUI tooling and run the UI test suite against a built desktop
# (Menu/Workspace/WindowManager must be installed; run "make all" first).
test: check_root
	@FROM_MAKEFILE=1 sh ./Library/Scripts/install-system-domain.sh test

uninstall: check_root
	@if [ -d "/usr/lib/system" ]; then \
	  echo "NextBSD system detected. Performing selective uninstall..."; \
	  if [ -d "/System/Applications" ]; then \
	    rm -rf /System/Applications; \
	    echo "Removed /System/Applications"; \
	  fi; \
	  for dir in /System/Library/*/; do \
	    name=$$(basename "$$dir"); \
	    case "$$name" in \
	      Caches|Extensions|LaunchDaemons) \
	        echo "Keeping /System/Library/$$name";; \
	      *) \
	        rm -rf "$$dir"; \
	        echo "Removed /System/Library/$$name";; \
	    esac; \
	  done; \
	  echo "Selective uninstall complete."; \
	elif [ -d "/System/Library" ]; then \
	  rm -rf /System >/dev/null 2>&1 || true; \
	  echo "Removed GNUstep System Domain /System"; \
	  echo "Uninstallation complete: /System"; \
	else \
	  echo "GNUstep appears to be already uninstalled. Nothing was removed."; \
	fi

