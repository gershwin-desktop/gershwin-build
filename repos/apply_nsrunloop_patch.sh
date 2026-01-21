#!/bin/sh

# Script to apply the NSRunLoop.m patch
# This patch adds dispatch main queue draining to prevent dispatch source spinning

set -e  # Exit on any error

PATCH_FILE="nsrunloop.patch"
REPO_DIR="libs-base"

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
echo "Applying patch with verbose output..."

if patch -p1 -v < "../$PATCH_FILE"; then
    echo "Patch applied successfully."
else
    echo "Error: Failed to apply patch."
    exit 1
fi

echo "Patch application complete."