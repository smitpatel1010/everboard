#!/bin/bash
# Builds Everboard.app from the SwiftPM product, signs it and (optionally) installs it.
# Usage: scripts/build-app.sh [debug|release] [--install]
#
# Signing: macOS only delivers notifications to properly signed apps. The script uses, in order:
#   $EVERBOARD_SIGN_IDENTITY, a keychain identity named "Everboard Local", an "Apple Development" identity,
#   and falls back to ad-hoc signing (app works; notifications fall back to in-app banners).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="Everboard"
BUNDLE_ID="local.everboard.mac"
APP="build/${APP_NAME}.app"
INSTALL_DIR="$HOME/Applications"

swift build -c "$CONFIG" --product "$APP_NAME"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (GRDB ships a privacy manifest).
for b in "$BIN_DIR"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

IDENTITY="${EVERBOARD_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDS="$(security find-identity -p codesigning 2>/dev/null || true)"
    if grep -q '"Everboard Local"' <<<"$IDS"; then IDENTITY="Everboard Local"
    elif grep -q '"Apple Development' <<<"$IDS"; then IDENTITY="$(grep -o '"Apple Development[^"]*"' <<<"$IDS" | head -1 | tr -d '"')"
    fi
fi
if [ -n "$IDENTITY" ]; then
    codesign --force --deep --options runtime --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
    echo "Signed ad-hoc (no 'Everboard Local' certificate found — notifications will use in-app banners)"
fi
echo "Built $APP"

if [[ "${2:-}" == "--install" ]]; then
    mkdir -p "$INSTALL_DIR"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.5
    rm -rf "$INSTALL_DIR/${APP_NAME}.app"
    cp -R "$APP" "$INSTALL_DIR/"
    echo "Installed to $INSTALL_DIR/${APP_NAME}.app"
fi
