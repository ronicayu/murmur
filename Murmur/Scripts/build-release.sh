#!/bin/bash
set -euo pipefail

# Build Murmur release app bundle with icon and proper Info.plist
# Usage: ./Scripts/build-release.sh
# Output: dist/Murmur.app and dist/Murmur-<version>.dmg

cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
echo "Building Murmur v${VERSION}..."

# 1. Patch ORT + build release binary
echo "→ Patching ORT for Float16..."
bash Scripts/patch-ort-float16.sh
echo "→ Compiling..."
swift build -c release 2>&1 | tail -3

BINARY=".build/arm64-apple-macosx/release/Murmur"
if [ ! -f "$BINARY" ]; then
    BINARY=".build/release/Murmur"
fi

# 2. Assemble app bundle from scratch
APP="dist/Murmur.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP/Contents/MacOS/Murmur"

# Copy Info.plist and add icon key
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"

# Copy resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/transcribe.py "$APP/Contents/Resources/"
cp Resources/requirements.txt "$APP/Contents/Resources/"

# Copy SPM resource bundle if it exists (contains bundled resources)
BUNDLE=".build/arm64-apple-macosx/release/Murmur_Murmur.bundle"
if [ -d "$BUNDLE" ]; then
    cp -R "$BUNDLE" "$APP/Contents/Resources/"
fi

# 3. Ad-hoc sign
echo "→ Signing..."
codesign --force --deep --sign - "$APP"

# 4. Create DMG with Applications shortcut (drag-to-install)
echo "→ Creating DMG..."
rm -rf dist/dmg-stage
mkdir -p dist/dmg-stage
cp -R "$APP" dist/dmg-stage/
ln -s /Applications dist/dmg-stage/Applications

rm -f "dist/Murmur-${VERSION}.dmg"
hdiutil create -volname "Murmur" -srcfolder dist/dmg-stage \
    -ov -format UDZO "dist/Murmur-${VERSION}.dmg" 2>/dev/null
rm -rf dist/dmg-stage

echo ""
echo "Done!"
echo "  App:  $APP"
echo "  DMG:  dist/Murmur-${VERSION}.dmg  ($(du -h "dist/Murmur-${VERSION}.dmg" | cut -f1))"
echo ""
echo "To install: open the DMG and drag Murmur to Applications"
