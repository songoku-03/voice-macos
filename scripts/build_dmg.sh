#!/bin/bash
set -e

# Builds SoundsSource.app, then packages it into a drag-to-install .dmg
# (app + an /Applications shortcut, like a typical Mac installer).

APP_NAME="SoundsSource"
VOL_NAME="SoundsSource"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_PATH="${BUILD_DIR}/${APP_NAME}.dmg"
STAGING="${BUILD_DIR}/dmg_staging"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Build the signed .app bundle (release).
echo "=== Building app bundle ==="
"$SCRIPT_DIR/build_app.sh"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: $APP_BUNDLE not found after build."
    exit 1
fi

# 2. Stage the bundle + an Applications symlink for drag-to-install.
echo "=== Staging DMG contents ==="
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 3. Build a compressed DMG.
echo "=== Creating DMG ==="
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING"

echo "=== DMG Complete: $DMG_PATH ==="
echo "Size: $(du -h "$DMG_PATH" | cut -f1)"
