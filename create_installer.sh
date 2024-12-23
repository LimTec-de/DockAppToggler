#!/bin/bash

# Exit on error
set -e

# Configuration
APP_NAME="DockAppToggler"
VERSION=$(grep -A 1 'CFBundleShortVersionString' Sources/DockAppToggler/Info.plist | grep string | sed -E 's/<[^>]+>//g' | tr -d ' \t')
BUILD_NUMBER=$(grep -A 1 'CFBundleVersion' Sources/DockAppToggler/Info.plist | grep string | sed -E 's/<[^>]+>//g' | tr -d ' \t')
PKG_NAME="${APP_NAME}_${VERSION}.pkg"
ZIP_NAME="${APP_NAME}_${VERSION}.zip"

# First build the app
./build.sh

# Create a clean directory for the release
rm -rf "release"
mkdir -p "release"

# Create zip archive of the app (needed for Sparkle)
ditto -c -k --keepParent "$APP_NAME.app" "release/$ZIP_NAME"

# Create temporary directory for package
TEMP_DIR=$(mktemp -d)
mkdir -p "$TEMP_DIR/Applications"

# Copy app to temporary directory
cp -R "$APP_NAME.app" "$TEMP_DIR/Applications/"

# Create installer package
echo "📦 Creating installer package..."
pkgbuild \
    --root "$TEMP_DIR" \
    --component-plist "package.plist" \
    --identifier "com.limtec.dockapptoggler" \
    --version "$VERSION" \
    --install-location "/" \
    "release/$PKG_NAME"

# Clean up
rm -rf "$TEMP_DIR"

# Find Sparkle tools
SPARKLE_PATH=".build/artifacts/sparkle/Sparkle/bin/"

if [ ! -f "$SPARKLE_PATH/generate_appcast" ]; then
    echo "❌ Error: Sparkle tools not found in $SPARKLE_PATH"
    exit 1
fi

# Generate appcast
echo "📝 Generating appcast..."
"$SPARKLE_PATH/generate_appcast" \
    "release" \
    --download-url-prefix "https://github.com/LimTec-de/DockAppToggler/releases/download/v$VERSION/"

echo "✅ Created installer package at release/$PKG_NAME"
echo "✅ Created zip archive at release/$ZIP_NAME" 