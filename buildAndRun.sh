#!/bin/bash

# Exit on error
set -e

echo "🏗 Building DockAppToggler..."

# Clean previous build
rm -rf DockAppToggler.app

# Build the executable
swift build -c release

# Create app bundle structure
BUNDLE_DIR="DockAppToggler.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

# Create directories
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$FRAMEWORKS_DIR"

# Copy executable
cp .build/release/DockAppToggler "$MACOS_DIR/"

# Copy resources
cp Sources/DockAppToggler/Resources/* "$RESOURCES_DIR/"

# Copy Info.plist
cp Sources/DockAppToggler/Info.plist "$CONTENTS_DIR/"

# Copy Sparkle framework from SPM cache
SPARKLE_PATH=$(find .build -name "Sparkle.framework" -type d | head -n 1)
if [ -n "$SPARKLE_PATH" ]; then
    echo "📦 Copying Sparkle framework from: $SPARKLE_PATH"
    cp -R "$SPARKLE_PATH" "$FRAMEWORKS_DIR/"
else
    echo "❌ Error: Sparkle framework not found in build directory"
    exit 1
fi

# Set up correct framework path
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/DockAppToggler"

echo "✅ Build complete! App bundle created at $BUNDLE_DIR"

# Run the app
echo "🚀 Launching app..."
open "$BUNDLE_DIR" 