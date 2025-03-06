#!/bin/bash

# Build script for DockAppToggler
# Rule applied: Script Organization - Clear sections with descriptive comments

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print status messages
print_status() {
    echo -e "${GREEN}==>${NC} $1"
}

print_error() {
    echo -e "${RED}Error:${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}Warning:${NC} $1"
}

# Check if running on macOS
if [ "$(uname)" != "Darwin" ]; then
    print_error "This script must be run on macOS"
    exit 1
fi

# Check for required tools
print_status "Checking required tools..."

if ! command -v swift &> /dev/null; then
    print_error "Swift is not installed. Please install Xcode and Xcode Command Line Tools"
    exit 1
fi

if ! command -v xcodebuild &> /dev/null; then
    print_error "xcodebuild is not installed. Please install Xcode Command Line Tools"
    exit 1
fi

# Set up build directories
BUILD_DIR="$(pwd)/.build"
APP_NAME="DockAppToggler"
APP_BUNDLE_PATH="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE_PATH/Contents"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

# Clean previous build
print_status "Cleaning previous build..."
rm -rf "$APP_BUNDLE_PATH"

# Create necessary directories
print_status "Creating app bundle structure..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$FRAMEWORKS_DIR"

# Build the Swift package
print_status "Building Swift package..."
swift package resolve

# Build for Apple Silicon (arm64)
print_status "Building for Apple Silicon (arm64)..."
if ! swift build -c release -Xswiftc "-swift-version" -Xswiftc "6" --arch arm64; then
    print_error "Swift build for arm64 failed"
    exit 1
fi

# Build for Intel (x86_64)
print_status "Building for Intel (x86_64)..."
if ! swift build -c release -Xswiftc "-swift-version" -Xswiftc "6" --arch x86_64; then
    print_error "Swift build for x86_64 failed"
    exit 1
fi

# Create universal binary
print_status "Creating universal binary..."
mkdir -p "$BUILD_DIR/universal/release"
lipo -create \
    "$BUILD_DIR/arm64-apple-macosx/release/$APP_NAME" \
    "$BUILD_DIR/x86_64-apple-macosx/release/$APP_NAME" \
    -output "$BUILD_DIR/universal/release/$APP_NAME"

# Copy binary to app bundle
print_status "Copying universal binary to app bundle..."
BINARY_PATH="$BUILD_DIR/universal/release/$APP_NAME"
if [ ! -f "$BINARY_PATH" ]; then
    print_error "Universal binary not found at: $BINARY_PATH"
    exit 1
fi
cp "$BINARY_PATH" "$MACOS_DIR/"

# Verify architecture support
print_status "Verifying architecture support..."
lipo -info "$MACOS_DIR/$APP_NAME"

# Copy resources and Info.plist
print_status "Copying resources and Info.plist..."
cp "Sources/$APP_NAME/Resources/icon.icns" "$RESOURCES_DIR/" 2>/dev/null || print_warning "icon.icns not found"
cp "Sources/$APP_NAME/Resources/icon.png" "$RESOURCES_DIR/" 2>/dev/null || print_warning "icon.png not found"
cp "Sources/$APP_NAME/Resources/trayicon.png" "$RESOURCES_DIR/" 2>/dev/null || print_warning "trayicon.png not found"
if ! cp "Sources/$APP_NAME/Info.plist" "$CONTENTS_DIR/"; then
    print_error "Info.plist not found"
    exit 1
fi

# Create PkgInfo file
print_status "Creating PkgInfo..."
echo "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Copy Sparkle framework
print_status "Copying Sparkle framework..."
SPARKLE_PATH=$(find .build -name "Sparkle.framework" -type d | head -n 1)
if [ -z "$SPARKLE_PATH" ]; then
    print_error "Sparkle framework not found"
    exit 1
fi
ditto --rsrc "$SPARKLE_PATH" "$FRAMEWORKS_DIR/Sparkle.framework"

# Update install name for Sparkle
print_status "Updating framework install name..."
install_name_tool -change "@rpath/Sparkle.framework/Versions/B/Sparkle" \
    "@executable_path/../Frameworks/Sparkle.framework/Versions/B/Sparkle" \
    "$MACOS_DIR/$APP_NAME"

# Set permissions
print_status "Setting permissions..."
chmod +x "$MACOS_DIR/$APP_NAME"

# Code sign the app if developer certificate is available
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    print_status "Code signing app bundle..."
    
    # Use project's entitlements file instead of creating temporary one
    ENTITLEMENTS_FILE="Sources/$APP_NAME/$APP_NAME.entitlements"
    
    # Sign Sparkle framework first
    codesign --force \
        --options runtime \
        --sign "Developer ID Application" \
        --timestamp \
        --deep \
        "$FRAMEWORKS_DIR/Sparkle.framework"
    
    # Sign the main app with hardened runtime and entitlements
    codesign --force \
        --options runtime \
        --entitlements "$ENTITLEMENTS_FILE" \
        --sign "Developer ID Application" \
        --timestamp \
        --deep \
        --strict \
        "$APP_BUNDLE_PATH"
else
    # Local signing with entitlements
    print_status "Signing app bundle for local use..."
    
    ENTITLEMENTS_FILE="Sources/$APP_NAME/$APP_NAME.entitlements"
    
    codesign --force \
        --options runtime \
        --entitlements "$ENTITLEMENTS_FILE" \
        --sign - \
        --deep \
        --strict \
        "$APP_BUNDLE_PATH"
        
    print_warning "No Developer ID certificate found. App signed for local use only."
fi

# Verify the app bundle
print_status "Verifying app bundle..."
if [ -d "$APP_BUNDLE_PATH" ]; then
    print_status "App bundle created successfully at: $APP_BUNDLE_PATH"
    
    # Optional: Copy to Applications folder
    read -p "Do you want to install the app to /Applications? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_status "Installing to /Applications..."
        if ! sudo cp -R "$APP_BUNDLE_PATH" "/Applications/"; then
            print_error "Failed to copy app to /Applications"
            exit 1
        fi
        print_status "Installation successful!"
        print_status "Launching app from /Applications..."
        print_status "Note: You may need to grant accessibility permissions in System Settings > Privacy & Security > Accessibility"
        open "/Applications/$APP_NAME.app"
    else
        print_status "Launching app from build directory..."
        print_status "Note: You may need to grant accessibility permissions in System Settings > Privacy & Security > Accessibility"
        if ! open "$APP_BUNDLE_PATH"; then
            print_error "Failed to launch app"
            exit 1
        fi
    fi
else
    print_error "App bundle creation failed"
    exit 1
fi

print_status "Build completed successfully!"
