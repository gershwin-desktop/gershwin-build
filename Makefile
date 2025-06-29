check_root:
	@if [ `id -u` -ne 0 ]; then \
		echo "This Makefile must be run as root or with sudo."; \
		exit 1; \
	fi

install: system

system: check_root
	@if [ -d "/System" ]; then \
		echo "GNUstep System Domain appears to be already installed."; \
	else \
		echo "Installing GNUstep System Domain..."; \
		FROM_MAKEFILE=1 sh ./install-system-domain.sh; \
	fi

uninstall: check_root
	@removed=""; \
	if [ -d "/System" ]; then \
	  rm -rf /System; \
	  removed="$$removed /System"; \
	  echo "Removed GNUstep System Domain /System"; \
	fi; \
	if [ -n "$$removed" ]; then \
	  echo "Uninstallation complete: $$removed"; \
	else \
	  echo "GNUstep appears to be already uninstalled. Nothing was removed."; \
	fi