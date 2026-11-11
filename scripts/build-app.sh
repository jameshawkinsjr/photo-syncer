#!/bin/bash
#
# Builds "Photo Syncer.app" into ./build.
#
#   scripts/build-app.sh              build the app
#   scripts/build-app.sh --install    build, then copy it to /Applications
#   scripts/build-app.sh --open       build, then launch it
#
# Environment (see scripts/common.sh):
#   CODESIGN_IDENTITY   Signing identity to use. Defaults to the first
#                       "Developer ID Application" certificate in your keychain,
#                       then the first "Apple Development" one, then
#                       "Photo Syncer Local Signing" (scripts/make-signing-cert.sh),
#                       or ad-hoc ("-") if there is none.
#   BUNDLE_ID           Bundle identifier (default: com.photosyncer.PhotoSyncer).
#   VERSION             Version string (default: 1.0.0).
#
# Why signing matters: macOS ties the Photos permission to the app's signature.
# With a real certificate the permission survives rebuilds. An ad-hoc signature
# changes on every build, so macOS asks for Photos access again after a rebuild.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="$BUILD_DIR/$APP_NAME.app"

INSTALL=0
OPEN=0
for argument in "$@"; do
    case "$argument" in
        --install) INSTALL=1 ;;
        --open) OPEN=1 ;;
        -h | --help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $argument" >&2
            exit 64
            ;;
    esac
done

echo "==> Compiling (release)"
choose_sdk
swift build -c release
BINARY="$(swift build -c release --show-bin-path)/$EXECUTABLE"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"

echo "==> Drawing the icon"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

IDENTITY="$(signing_identity)"
if [ "$IDENTITY" != "-" ]; then
    echo "==> Signing with a certificate from your keychain"
    # The hardened runtime needs the Photos entitlement to read the library.
    SIGN_FLAGS=(--options runtime --entitlements Resources/PhotoSyncer.entitlements)
    if is_developer_id "$IDENTITY"; then
        SIGN_FLAGS+=(--timestamp)
    fi
    if ! codesign --force --sign "$IDENTITY" "${SIGN_FLAGS[@]}" "$APP"; then
        echo "    Certificate signing failed; falling back to an ad-hoc signature." >&2
        codesign --force --sign - --entitlements Resources/PhotoSyncer.entitlements "$APP"
    fi
else
    echo "==> Signing ad-hoc (no signing certificate found)"
    codesign --force --sign - --entitlements Resources/PhotoSyncer.entitlements "$APP"
fi
codesign --verify --strict "$APP"

echo "==> Built $APP"

if [ "$INSTALL" = 1 ]; then
    DESTINATION="/Applications/$APP_NAME.app"
    echo "==> Installing to $DESTINATION"
    rm -rf "$DESTINATION"
    ditto "$APP" "$DESTINATION"
    APP="$DESTINATION"
fi

if [ "$OPEN" = 1 ]; then
    open "$APP"
fi
