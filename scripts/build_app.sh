#!/bin/bash
set -e

# Configuration
APP_NAME="SoundsSource"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
CONFIGURATION="release"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -d|--debug) CONFIGURATION="debug"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
done

echo "=== Building SoundsSource ($CONFIGURATION) ==="
swift build -c "$CONFIGURATION"

# Create bundle directory structure
echo "=== Assembling App Bundle ==="
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary and plist
BINARY_PATH=".build/$CONFIGURATION/$APP_NAME"
if [ ! -f "$BINARY_PATH" ]; then
    # SPM sometimes puts executables in apple/Products
    BINARY_PATH=$(find .build -name "$APP_NAME" -type f | head -n 1)
fi

if [ -z "$BINARY_PATH" ] || [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Compiled binary not found."
    exit 1
fi

cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Sign bundle with entitlements (ad-hoc signing for local execution)
echo "=== Code Signing App Bundle ==="
codesign --force --sign - --entitlements entitlements.plist "$APP_BUNDLE"

echo "=== Build Complete: $APP_BUNDLE ==="
