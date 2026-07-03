#!/bin/bash
# Install KernelSU kernel + matching modules into an AVD
# Usage: ./install-avd.sh <artifact-dir> <avd-name>
# Example: ./install-avd.sh ./6.1.162-android14-2026-03-x86_64 ksu_test

set -e

ARTIFACT_DIR="${1:-.}"
AVD_NAME="${2:-ksu_test}"

# Convert ARTIFACT_DIR to absolute path so it survives 'cd'
if command -v realpath >/dev/null 2>&1; then
  ARTIFACT_DIR=$(realpath "$ARTIFACT_DIR")
else
  # fallback for Mac/old environments
  ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"
fi

# Check dependencies
for cmd in cpio gzip file lz4; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo "ERROR: Required command '$cmd' is not installed."
    echo "Please install it first (e.g., 'sudo apt-get install $cmd' on Ubuntu/WSL)."
    exit 1
  fi
done

# Detect WSL and user profiles
WIN_USER=""
WSL_USER=""
WIN_LOCALAPPDATA=""
WSL_LOCALAPPDATA=""
if command -v wslpath >/dev/null 2>&1; then
  WIN_USER=$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n')
  [ -n "$WIN_USER" ] && WSL_USER=$(wslpath "$WIN_USER" 2>/dev/null)
  WIN_LOCALAPPDATA=$(cmd.exe /c "echo %LOCALAPPDATA%" 2>/dev/null | tr -d '\r\n')
  [ -n "$WIN_LOCALAPPDATA" ] && WSL_LOCALAPPDATA=$(wslpath "$WIN_LOCALAPPDATA" 2>/dev/null)
fi

# Find AVD path
AVD_DIR=""
for p in "$ANDROID_AVD_HOME/${AVD_NAME}.avd" "$HOME/.android/avd/${AVD_NAME}.avd" "$USERPROFILE/.android/avd/${AVD_NAME}.avd" "$WSL_USER/.android/avd/${AVD_NAME}.avd"; do
  [ -d "$p" ] && AVD_DIR="$p" && break
done

if [ -z "$AVD_DIR" ]; then
  echo "ERROR: AVD directory not found for $AVD_NAME"
  exit 1
fi

# Find system image path from config.ini
SYSDIR=$(grep "image.sysdir.1" "$AVD_DIR/config.ini" | cut -d= -f2 | tr -d '[:space:]' | tr '\\' '/')
SDK_ROOT=""
for p in "$ANDROID_SDK_ROOT" "$ANDROID_HOME" "$LOCALAPPDATA/Android/Sdk" "$HOME/Android/Sdk" "$USERPROFILE/AppData/Local/Android/Sdk" "$WSL_LOCALAPPDATA/Android/Sdk" "$WSL_USER/AppData/Local/Android/Sdk"; do
  if [ -d "$p" ] && [ -f "$p/$SYSDIR/ramdisk.img" ]; then
    SDK_ROOT="$p"
    break
  fi
done

if [ -z "$SDK_ROOT" ]; then
  echo "ERROR: Android SDK containing $SYSDIR/ramdisk.img not found"
  exit 1
fi
SYSIMG="$SDK_ROOT/$SYSDIR"

echo "=== AVD KernelSU Installer ==="
echo "Artifact: $ARTIFACT_DIR"
echo "AVD: $AVD_NAME"
echo "AVD Dir: $AVD_DIR"
echo "System Image: $SYSIMG"

# Check for kernel
if [ -f "$ARTIFACT_DIR/bzImage" ]; then
  KERNEL="$ARTIFACT_DIR/bzImage"
elif [ -f "$ARTIFACT_DIR/Image" ]; then
  KERNEL="$ARTIFACT_DIR/Image"
else
  echo "ERROR: No kernel found in $ARTIFACT_DIR"
  exit 1
fi

# Check for ramdisk
RAMDISK="$SYSIMG/ramdisk.img"
if [ ! -f "$RAMDISK" ]; then
  echo "ERROR: ramdisk.img not found at $RAMDISK"
  exit 1
fi

# Backup original ramdisk
if [ ! -f "$AVD_DIR/ramdisk.img.bak" ]; then
  echo "Backing up original ramdisk..."
  cp "$RAMDISK" "$AVD_DIR/ramdisk.img.bak"
fi

# Repack ramdisk with our modules
echo "Repacking ramdisk with matching modules..."
TMPDIR=$(mktemp -d)
cd "$TMPDIR"


# Replace modules with our matching ones
MODULES_SRC=""
if [ -d "$ARTIFACT_DIR/modules" ] && ls "$ARTIFACT_DIR/modules"/*.ko >/dev/null 2>&1; then
  MODULES_SRC="$ARTIFACT_DIR/modules"
elif ls "$ARTIFACT_DIR"/*.ko >/dev/null 2>&1; then
  MODULES_SRC="$ARTIFACT_DIR"
fi

if [ -n "$MODULES_SRC" ]; then
  echo "Creating modules overlay..."
  mkdir -p overlay/lib/modules
  
  for ko in "$MODULES_SRC"/*.ko; do
    BASENAME=$(basename "$ko")
    cp "$ko" "overlay/lib/modules/$BASENAME"
    echo "  Injected: $BASENAME"
  done

  # Also copy or generate modules.load
  if [ -f "$MODULES_SRC/modules.load" ]; then
    cp "$MODULES_SRC/modules.load" "overlay/lib/modules/modules.load"
  else
    ls overlay/lib/modules/*.ko 2>/dev/null | xargs -n1 basename > overlay/lib/modules/modules.load 2>/dev/null || true
  fi
  
  echo "Packing modules into overlay CPIO..."
  cd overlay
  find . | cpio -o -H newc 2>/dev/null | gzip > ../modules.cpio.gz
  cd ..
  
  echo "Appending modules overlay to ramdisk..."
  cat "$RAMDISK" modules.cpio.gz > "$AVD_DIR/ramdisk-ksu.img"
else
  echo "WARNING: No kernel modules (*.ko) found in $ARTIFACT_DIR or $ARTIFACT_DIR/modules"
  cp "$RAMDISK" "$AVD_DIR/ramdisk-ksu.img"
fi

cd "$WORKSPACE_DIR"
rm -rf "$TMPDIR"

# Copy kernel
echo "Copying kernel..."
cp "$KERNEL" "$AVD_DIR/kernel-ksu"

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Run your AVD with:"
echo "  emulator -avd $AVD_NAME -kernel $AVD_DIR/kernel-ksu -ramdisk $AVD_DIR/ramdisk-ksu.img -no-snapshot-load -show-kernel"
echo ""
