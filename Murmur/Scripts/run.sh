#!/bin/bash
# Wraps the swift build output into a .app bundle so MenuBarExtra works.

set -e
cd "$(dirname "$0")/.."

APP_NAME="Murmur"
BUILD_DIR=".build/debug"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Build first
swift build

# Create .app structure
mkdir -p "$MACOS" "$RESOURCES"
cp "$BUILD_DIR/$APP_NAME" "$MACOS/$APP_NAME"
cp Info.plist "$CONTENTS/Info.plist"
cp Murmur.entitlements "$CONTENTS/" 2>/dev/null || true

# Copy resources
cp Resources/transcribe.py "$RESOURCES/" 2>/dev/null || true

# Copy the resource bundle if it exists
if [ -d "$BUILD_DIR/Murmur_Murmur.bundle" ]; then
    cp -R "$BUILD_DIR/Murmur_Murmur.bundle" "$RESOURCES/"
fi

echo "Built: $APP_DIR"
echo "Launching..."
open "$APP_DIR"
