# Shared settings for the build scripts. Sourced, not executed.
#
# Environment:
#   CODESIGN_IDENTITY   Signing identity to use. Defaults to the first
#                       "Developer ID Application" certificate in your keychain,
#                       then the first "Apple Development" one, then
#                       "Photo Syncer Local Signing" (scripts/make-signing-cert.sh),
#                       or ad-hoc ("-") if there is none.
#   BUNDLE_ID           Bundle identifier (default: com.photosyncer.PhotoSyncer).
#   VERSION             Version string (default: 1.0.0).

APP_NAME="Photo Syncer"
EXECUTABLE="PhotoSyncer"
BUNDLE_ID="${BUNDLE_ID:-com.photosyncer.PhotoSyncer}"
VERSION="${VERSION:-1.0.0}"
BUILD_DIR="build"
# The self-signed certificate scripts/make-signing-cert.sh creates.
LOCAL_SIGNING_NAME="Photo Syncer Local Signing"

# With only the Command Line Tools installed, the macOS 27 SDK's SwiftUI needs a
# macro plugin (SwiftUIMacros) that ships with Xcode, not with the tools. Build
# against the newest macOS 26 SDK instead when that's the case.
choose_sdk() {
    local clt=/Library/Developer/CommandLineTools
    if [ -n "${SDKROOT:-}" ] || [ "$(xcode-select -p)" != "$clt" ]; then
        return
    fi
    if [ -e "$clt/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
        return
    fi
    local sdk
    sdk="$(ls -d "$clt"/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)"
    if [ -n "$sdk" ]; then
        export SDKROOT="$sdk"
        echo "    Using $(basename "$sdk") (the Command Line Tools lack SwiftUI's macro plugin for newer SDKs)"
    fi
}

# Prints the code-signing identity to use; "-" means ad-hoc.
signing_identity() {
    if [ -n "${CODESIGN_IDENTITY:-}" ]; then
        echo "$CODESIGN_IDENTITY"
        return
    fi
    local identities identity
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    identity="$(echo "$identities" | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
    if [ -z "$identity" ]; then
        identity="$(echo "$identities" | awk -F'"' '/Apple Development/ { print $2; exit }')"
    fi
    # A self-signed certificate isn't "valid" (nothing trusts it), so look for it among all
    # identities. Signing with it is fine: it keeps the signature the same across builds.
    if [ -z "$identity" ] && security find-identity -p codesigning 2>/dev/null | grep -q "\"$LOCAL_SIGNING_NAME\""; then
        identity="$LOCAL_SIGNING_NAME"
    fi
    echo "${identity:--}"
}

# True when the identity is a Developer ID certificate, i.e. one Gatekeeper
# trusts for apps distributed outside the App Store.
is_developer_id() {
    case "$1" in
        "Developer ID Application"*) return 0 ;;
        *) return 1 ;;
    esac
}
