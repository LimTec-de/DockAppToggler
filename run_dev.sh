#!/bin/bash
set -e

# IMPORTANT: DockAppToggler must run as a real .app bundle. A bare `swift run`
# binary has no bundle identifier, and macOS will not give its menu-bar status
# items a slot — they overflow off-screen and the tray icon never appears.
# So we build a (debug) .app bundle and launch that instead.

cd "$(dirname "$0")"

APP_NAME="DockAppToggler"
APP=".build/${APP_NAME}.app"
CONTENTS="$APP/Contents"

swift package resolve
swift build

# (Re)assemble the bundle around the debug binary.
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

cp ".build/debug/${APP_NAME}" "$CONTENTS/MacOS/"
cp "Sources/${APP_NAME}/Info.plist" "$CONTENTS/"
echo "APPL????" > "$CONTENTS/PkgInfo"
cp Sources/${APP_NAME}/Resources/*.png "$CONTENTS/Resources/" 2>/dev/null || true
cp Sources/${APP_NAME}/Resources/icon.icns "$CONTENTS/Resources/" 2>/dev/null || true

# Bundle the Sparkle framework and fix its install name.
SPARKLE=$(find .build -name "Sparkle.framework" -type d | head -n 1)
if [ -n "$SPARKLE" ]; then
    ditto "$SPARKLE" "$CONTENTS/Frameworks/Sparkle.framework"
    install_name_tool -change \
        "@rpath/Sparkle.framework/Versions/B/Sparkle" \
        "@executable_path/../Frameworks/Sparkle.framework/Versions/B/Sparkle" \
        "$CONTENTS/MacOS/${APP_NAME}" 2>/dev/null || true
fi

# Sign with a stable self-signed certificate so the code-signing identity (and thus the
# TCC permission grants) stay the same across rebuilds — no more re-granting Accessibility,
# Screen Recording, etc. after every build. Falls back to ad-hoc if the cert is missing.
SIGN_IDENTITY="DockAppToggler Dev"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "Warning: signing certificate '$SIGN_IDENTITY' not found — falling back to ad-hoc (permissions will reset each build)."
    SIGN_IDENTITY="-"
fi
codesign --force --sign "$SIGN_IDENTITY" "$CONTENTS/Frameworks/Sparkle.framework" 2>/dev/null || true
codesign --force --sign "$SIGN_IDENTITY" "$APP" 2>/dev/null || true

# Relaunch.
pkill -f "/Applications/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
pkill -f "${APP}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
sleep 0.2
open "$APP"
echo "Launched $APP — if the tray icon needs Accessibility, grant it in System Settings."
