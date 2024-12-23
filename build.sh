#!/bin/bash

# Clean previous build
rm -rf DockAppToggler.app

# get sparkle framework
swift package resolve

# Clean and build
swift build -c release

# Create app bundle structure
APP_NAME="DockAppToggler"
APP_DIR="$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

# Create directories
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$FRAMEWORKS_DIR"

# Copy executable
cp -f ".build/release/$APP_NAME" "$MACOS_DIR/"

# Copy Info.plist
cp -f "Sources/DockAppToggler/Info.plist" "$CONTENTS_DIR/"

# Copy resources
cp -f "Sources/DockAppToggler/Resources/icon.icns" "$RESOURCES_DIR/"

# Copy Sparkle framework from SPM cache
SPARKLE_PATH=$(find .build -name "Sparkle.framework" -type d | head -n 1)
if [ -n "$SPARKLE_PATH" ]; then
    echo "📦 Copying Sparkle framework from: $SPARKLE_PATH"
    cp -R "$SPARKLE_PATH" "$FRAMEWORKS_DIR/"
else
    echo "❌ Error: Sparkle framework not found in build directory"
    exit 1
fi

# Set permissions
chmod +x "$MACOS_DIR/$APP_NAME"

# Fix framework references
install_name_tool -change "@rpath/Sparkle.framework/Versions/B/Sparkle" "@executable_path/../Frameworks/Sparkle.framework/Versions/B/Sparkle" "$MACOS_DIR/$APP_NAME"

# Create PkgInfo file
echo "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Sign the Sparkle framework first
codesign --force --deep --sign - "$FRAMEWORKS_DIR/Sparkle.framework"

# Enable hardened runtime and sign with entitlements
codesign --force --deep --entitlements DockAppToggler.entitlements --sign - "$APP_DIR"

# Verify the app bundle
echo "🔍 Verifying app bundle..."
codesign -vv --deep --strict "$APP_DIR"
otool -L "$MACOS_DIR/$APP_NAME"

echo "✅ App bundle created at $APP_DIR"