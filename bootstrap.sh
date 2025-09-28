#!/bin/sh

# Check if the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
elif [ "$(uname -s)" = "FreeBSD" ]; then
    OS_ID="freebsd"
else
    echo "Unsupported or unknown OS."
    exit 1
fi

echo "Detected OS: $OS_ID"

REQUIREMENTS_FILE="requirements/${OS_ID}.txt"

if [ ! -f "$REQUIREMENTS_FILE" ]; then
    echo "No requirements file found for OS: $OS_ID"
    echo "Expected: $REQUIREMENTS_FILE"
    exit 1
fi

echo "Checking packages in: $REQUIREMENTS_FILE"

missing=""

case "$OS_ID" in
  arch)
    while IFS= read -r pkg || [ -n "$pkg" ]; do
      [ -z "$pkg" ] && continue
      if ! pacman -Qi "$pkg" >/dev/null 2>&1; then
        missing="$missing $pkg"
      fi
    done < "$REQUIREMENTS_FILE"

    if [ -n "$missing" ]; then
      echo "Installing:$missing"
      pacman -S --noconfirm $missing
    else
      echo "All required packages are already installed."
    fi
    ;;

  freebsd)
    while IFS= read -r pkg || [ -n "$pkg" ]; do
      [ -z "$pkg" ] && continue
      if ! pkg info "$pkg" >/dev/null 2>&1; then
        missing="$missing $pkg"
      fi
    done < "$REQUIREMENTS_FILE"

    if [ -n "$missing" ]; then
      echo "Installing:$missing"
      pkg install -y $missing
    else
      echo "All required packages are already installed."
    fi
    ;;

  ghostbsd)
    while IFS= read -r pkg || [ -n "$pkg" ]; do
      [ -z "$pkg" ] && continue
      if ! pkg info "$pkg" >/dev/null 2>&1; then
        missing="$missing $pkg"
      fi
    done < "$REQUIREMENTS_FILE"

    if [ -n "$missing" ]; then
      echo "Installing:$missing"
      pkg install -y $missing
    else
      echo "All required packages are already installed."
    fi
    ;;

  *)
    echo "Unsupported OS for package checking: $OS_ID"
    exit 1
    ;;
esac
