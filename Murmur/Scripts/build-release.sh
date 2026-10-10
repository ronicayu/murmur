#!/bin/bash
set -euo pipefail

# Build Murmur release app bundle with icon and proper Info.plist.
# The release workflow runs this same script, so a local build and a CI
# build produce the same bundle.
# Usage: ./Scripts/build-release.sh [version]
#   version  defaults to CFBundleShortVersionString in Info.plist; CI passes
#            the git tag without its leading "v".
# Output: dist/Murmur.app and dist/Murmur-<version>.dmg

cd "$(dirname "$0")/.."

VERSION="${1-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)}"
# The version ends up in a file name and in Info.plist.
if [[ ! "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]]; then
    echo "error: invalid version '$VERSION'" >&2
    exit 1
fi
echo "Building Murmur v${VERSION}..."

# 1. Build release binary
echo "→ Compiling..."
swift build -c release

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

# The speech engine runs in this helper process. Without it the app still
# works, with the engine inside its own process, and keeps gigabytes of
# memory for good; so a build without it is an error.
ENGINE="$(dirname "$BINARY")/MurmurEngine"
if [ ! -f "$ENGINE" ]; then
    echo "error: $ENGINE was not built" >&2
    exit 1
fi
cp "$ENGINE" "$APP/Contents/MacOS/MurmurEngine"

# Copy Info.plist, add icon key and stamp the version
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"

# Copy resources
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Copy SPM resource bundle if it exists (contains bundled resources)
BUNDLE=".build/arm64-apple-macosx/release/Murmur_Murmur.bundle"
if [ -d "$BUNDLE" ]; then
    cp -R "$BUNDLE" "$APP/Contents/Resources/"
fi

# 3. Ad-hoc sign with entitlements
echo "→ Signing..."
codesign --force --deep --sign - --entitlements Murmur.entitlements "$APP"

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
