#!/bin/bash
set -e

# Check if required environment variables are set
required_vars=(
    "ASC_ISSUER_ID"
    "ASC_KEY_CONTENT"
    "ASC_KEY_ID"
    "BUILD_CERTIFICATE_BASE64"
    "KEYCHAIN_PASSWORD"
    "P12_PASSWORD"
    "TEAM_ID"
)

for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: Required environment variable $var is not set"
        exit 1
    fi
done

echo "Setting up keychain..."
# Create a temporary keychain
KEYCHAIN_NAME="build.keychain"
KEYCHAIN_PATH="$HOME/Library/Keychains/$KEYCHAIN_NAME-db"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
security set-keychain-settings -t 3600 -l "$KEYCHAIN_NAME"

# Add the temporary keychain to the search list
KEYCHAIN_LIST="$(security list-keychains -d user)"
security list-keychains -d user -s "$KEYCHAIN_NAME" ${KEYCHAIN_LIST}

# Import the certificate to keychain
echo "Importing certificate..."
echo "$BUILD_CERTIFICATE_BASE64" | base64 --decode > certificate.p12
security import certificate.p12 -k "$KEYCHAIN_NAME" -P "$P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

# Build the app
echo "Building app..."
npm run build

# Find the .app file
APP_PATH=$(find . -name "*.app" -type d | head -n 1)
if [ -z "$APP_PATH" ]; then
    echo "Error: Could not find .app bundle"
    exit 1
fi

# Sign the app
echo "Signing app..."
codesign --force --options runtime --sign "Developer ID Application: $TEAM_ID" "$APP_PATH" --deep --strict

# Create temporary file for auth keys
echo "Setting up notarization credentials..."
PRIVATE_KEY_PATH=$(mktemp)
echo "$ASC_KEY_CONTENT" > "$PRIVATE_KEY_PATH"

# Create ZIP for notarization
ZIP_PATH="${APP_PATH%.*}.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Submitting for notarization..."
xcrun notarytool submit "$ZIP_PATH" \
    --key "$PRIVATE_KEY_PATH" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" \
    --wait

# Cleanup
echo "Cleaning up..."
rm -f certificate.p12 "$PRIVATE_KEY_PATH"
# Restore the original keychain list
security list-keychains -d user -s ${KEYCHAIN_LIST}
security delete-keychain "$KEYCHAIN_NAME"

echo "Build, signing, and notarization completed successfully!" 