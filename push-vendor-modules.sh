#!/bin/bash
# Pushes the remaining kernel modules to the running AVD's vendor partition

set -e

ARTIFACT_DIR="${1:-.}"

# Check for adb
if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found. Ensure Android SDK platform-tools is in PATH."
  exit 1
fi

# Find modules dir
MODULES_SRC=""
if [ -d "$ARTIFACT_DIR/modules" ]; then
  MODULES_SRC="$ARTIFACT_DIR/modules"
elif ls "$ARTIFACT_DIR"/*.ko >/dev/null 2>&1; then
  MODULES_SRC="$ARTIFACT_DIR"
else
  echo "ERROR: No modules found in $ARTIFACT_DIR"
  exit 1
fi

echo "=== Pushing vendor modules ==="
echo "Waiting for device to become available (it may be bootlooping or showing a black screen)..."
adb wait-for-device

echo "Restarting adbd as root..."
adb root || true
sleep 2

echo "Remounting partitions as writable..."
adb remount || true
sleep 2

echo "Pushing modules..."
# Push all the modules to vendor
for ko in "$MODULES_SRC"/*.ko; do
  BASENAME=$(basename "$ko")
  adb push "$ko" "/vendor/lib/modules/$BASENAME" || true
done

# We also need to fix up the vendor modules.dep!
# We can do this by pushing the correct modules.load and modules.dep over to vendor.
# First, generate a flattened modules.dep locally and push it.
TMPDIR=$(mktemp -d)
cp "$MODULES_SRC"/*.ko "$TMPDIR/" 2>/dev/null || true
ls "$TMPDIR"/*.ko 2>/dev/null | xargs -n1 basename > "$TMPDIR/modules.load"
while read -r mod; do
  echo "$mod:" >> "$TMPDIR/modules.dep"
done < "$TMPDIR/modules.load"

adb push "$TMPDIR/modules.load" "/vendor/lib/modules/modules.load" || true
adb push "$TMPDIR/modules.dep" "/vendor/lib/modules/modules.dep" || true

rm -rf "$TMPDIR"

echo "Done! You must reboot the AVD for changes to take effect."
echo "Use: adb reboot"
