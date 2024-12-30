#!/bin/bash

# Exit on error
set -e

echo "🔨 Building DockAppToggler..."

# Clean any previous build
rm -rf DockAppToggler.app

# Resolve dependencies and build
swift package resolve
swift build -c release

# Create app bundle
mkdir -p DockAppToggler.app/Contents/{MacOS,Resources,Frameworks}
cp .build/release/DockAppToggler DockAppToggler.app/Contents/MacOS/
cp Sources/DockAppToggler/Info.plist DockAppToggler.app/Contents/
cp Sources/DockAppToggler/Resources/icon.icns DockAppToggler.app/Contents/Resources/

# Create PkgInfo file
echo "APPL????" > DockAppToggler.app/Contents/PkgInfo

# Set executable permissions
chmod +x DockAppToggler.app/Contents/MacOS/DockAppToggler

# Copy Sparkle framework using ditto to preserve symlinks
SPARKLE_PATH=$(find .build -name "Sparkle.framework" -type d | head -n 1)
if [ -z "$SPARKLE_PATH" ]; then
  echo "❌ Error: Sparkle framework not found"
  exit 1
fi
ditto --rsrc "$SPARKLE_PATH" DockAppToggler.app/Contents/Frameworks/Sparkle.framework

# Update install name
install_name_tool -change "@rpath/Sparkle.framework/Versions/B/Sparkle" "@executable_path/../Frameworks/Sparkle.framework/Versions/B/Sparkle" DockAppToggler.app/Contents/MacOS/DockAppToggler

# Create DMG
echo "📦 Creating DMG..."
mkdir -p dmg_root
cp -R DockAppToggler.app dmg_root/
ln -s /Applications dmg_root/Applications

hdiutil create -volname "DockAppToggler" \
  -srcfolder dmg_root \
  -ov \
  -format UDZO \
  -fs HFS+ \
  -imagekey zlib-level=9 \
  DockAppToggler.dmg

# Clean up
rm -rf dmg_root

echo "✅ Build complete!"
echo "📱 App bundle created at: DockAppToggler.app"
echo "💿 DMG created at: DockAppToggler.dmg"
echo "🚀 To run the app, double-click DockAppToggler.app or run: open DockAppToggler.app"
