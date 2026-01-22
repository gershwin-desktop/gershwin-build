#!/bin/sh

# Script to apply the swift-corelibs-libdispatch patch
# This patch fixes the libdispatch timer spin issue on FreeBSD

set -e  # Exit on any error

PATCH_FILE="swift-corelibs-libdispatch.patch"
REPO_DIR="swift-corelibs-libdispatch"

echo "Applying patch: $PATCH_FILE to repository: $REPO_DIR"
echo "Working directory: $(pwd)"

if [ ! -f "$PATCH_FILE" ]; then
    echo "Error: Patch file '$PATCH_FILE' not found in current directory."
    exit 1
fi

if [ ! -d "$REPO_DIR" ]; then
    echo "Error: Repository directory '$REPO_DIR' not found."
    exit 1
fi

cd "$REPO_DIR"

echo "Entering directory: $REPO_DIR"

# Check if patch is already applied by looking for patched content
if grep -q "LIBDISPATCH_TIMER_MIN_DELAY_MS" src/event/event_kevent.c 2>/dev/null; then
    echo "Patch already applied, skipping."
    exit 0
fi

echo "Applying patch..."
if patch -p1 -N < "../$PATCH_FILE"; then
    echo "Patch applied successfully."
else
    # patch -N returns non-zero if already applied, check if that's the case
    if grep -q "LIBDISPATCH_TIMER_MIN_DELAY_MS" src/event/event_kevent.c 2>/dev/null; then
        echo "Patch was already partially applied."
        exit 0
    fi
    echo "Error: Failed to apply patch."
    exit 1
fi

echo "Patch application complete."
