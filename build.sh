#!/bin/bash

# Exit on error
set -e

echo "🏗 Building DockAppToggler..."

# ensure Sparkle is resolved
swift package resolve

# Build the executable
swift build -c release --product DockAppToggler

# Create app bundle structure
BUNDLE_DIR="DockAppToggler.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Create directories
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable
cp .build/release/DockAppToggler "$MACOS_DIR/"

# Copy resources
cp Sources/DockAppToggler/Resources/* "$RESOURCES_DIR/"

# Copy Info.plist
cp Sources/DockAppToggler/Info.plist "$CONTENTS_DIR/"

echo "✅ Build complete! App bundle created at $BUNDLE_DIR"

# Run the app
echo "🚀 Launching app..."
open "$BUNDLE_DIR" 