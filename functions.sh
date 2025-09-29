#!/bin/sh

set -eux

# Detect platform and define tools accordingly
detect_platform() {
    # Detect OS_ID and OS_LIKE
    OS_ID=""
    OS_LIKE=""
    
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID=${ID:-}
        OS_LIKE=${ID_LIKE:-}
    else
        case "$(uname -s)" in
            FreeBSD)
                OS_ID=freebsd
                OS_LIKE=
                ;;
            *)
                printf '%s\n' "Unsupported or unknown OS." >&2
                exit 1
                ;;
        esac
    fi
    
    printf 'Detected OS: %s\n' "$OS_ID"
    
    # Map OS_ID / OS_LIKE to PLATFORM, MAKE_CMD, NPROC_CMD
    PLATFORM=""
    MAKE_CMD=""
    NPROC_CMD=""
    
    case "$OS_ID" in
        freebsd|ghostbsd)
            PLATFORM=$OS_ID
            MAKE_CMD=gmake
            NPROC_CMD='sysctl -n hw.ncpu'
            ;;
        arch)
            PLATFORM=arch
            MAKE_CMD=make
            NPROC_CMD=nproc
            ;;
        debian|ubuntu|linuxmint)
            PLATFORM=debian
            MAKE_CMD=make
            NPROC_CMD=nproc
            ;;
        *)
            if [ -n "$OS_LIKE" ]; then
                case "$OS_LIKE" in
                    debian*)
                        PLATFORM=debian
                        MAKE_CMD=make
                        NPROC_CMD=nproc
                        ;;
                    arch*)
                        PLATFORM=arch
                        MAKE_CMD=make
                        NPROC_CMD=nproc
                        ;;
                    freebsd*)
                        PLATFORM=freebsd
                        MAKE_CMD=gmake
                        NPROC_CMD='sysctl -n hw.ncpu'
                        ;;
                    *)
                        printf '%s\n' "Unsupported or unknown Linux distribution: $OS_ID (ID_LIKE=$OS_LIKE)" >&2
                        exit 1
                        ;;
                esac
            else
                printf '%s\n' "Unsupported or unknown OS: $OS_ID" >&2
                exit 1
            fi
            ;;
    esac
    
    printf 'Platform: %s\n' "$PLATFORM"
    printf 'Make command: %s\n' "$MAKE_CMD"
    printf 'Nproc command: %s\n' "$NPROC_CMD"
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
