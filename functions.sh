#!/bin/sh

# Detect platform and define tools accordingly
detect_platform() {
    OS=$(uname -s)
    case "$OS" in
        FreeBSD)
            PLATFORM="freebsd"
            MAKE_CMD="gmake"
            NPROC_CMD="sysctl -n hw.ncpu"
            ;;
        GhostBSD)
            PLATFORM="ghostbsd"
            MAKE_CMD="gmake"
            NPROC_CMD="sysctl -n hw.ncpu"
            ;;
        Linux)
            if [ -f /etc/arch-release ]; then
                PLATFORM="arch"
                MAKE_CMD="make"
                NPROC_CMD="nproc"
            elif  [ -f /etc/debian-release ]; then
                PLATFORM="debian"
                MAKE_CMD="make"
                NPROC_CMD="nproc"
            else
                echo "Unsupported Linux distribution"
                exit 1
            fi
            ;;
        *)
            echo "Unsupported OS: $OS"
            exit 1
            ;;
    esac
}

# Determine CPU count for parallel builds
get_cpu_count() {
    CPU_COUNT=$($NPROC_CMD 2>/dev/null)
    if [ -z "$CPU_COUNT" ]; then
        CPU_COUNT=1
    fi
    echo "$CPU_COUNT"
}

# Export shared environment
export_vars() {
    export WORKDIR="$(pwd)"
    export REPOS_DIR="$WORKDIR/repos"
    export CPUS="$(get_cpu_count)"
    echo "Detected platform: $PLATFORM"
    echo "WORKDIR is set to: $WORKDIR"
    echo "REPOS_DIR is set to: $REPOS_DIR"
    echo "CPUS is set to: $CPUS"
}

# Prevent this script from being run directly
if [ "${0##*/}" = "functions.sh" ]; then
    echo "This script is a library and must be sourced, not executed directly."
    exit 1
fi
