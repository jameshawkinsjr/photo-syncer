#!/bin/bash
#
# Publishes a build for the app's updater (Settings › Updates): builds the disk
# image with scripts/make-dmg.sh, copies it into the release folder, and then
# announces it there in latest.json. Every Mac whose Photo Syncer points at that
# folder sees the new build, downloads it, and offers Install & Restart.
#
#   scripts/publish.sh
#   scripts/publish.sh --notes "What changed, in a line or two."
#
# The release folder ends up holding:
#
#   Photo-Syncer-<version>-<build>.dmg   one per published build
#   latest.json                          the newest one: version, build, file,
#                                        sha256, publishedAt and optional notes
#
# latest.json is written last, so a half-copied image is never announced.
# A build is only published if its build number (the git commit count, which
# scripts/build-app.sh stamps into the app) is higher than the published one:
# commit before publishing again. The version is for people, not compared.
#
# Environment:
#   RELEASE_DIR   The release folder: one every Mac can reach (iCloud Drive,
#                 Dropbox, a shared drive), for example
#                 "~/Dropbox/Photo Syncer Releases". It must already exist.
#                 Instead of setting this each time, put the path on the first
#                 line of a file named .release-dir in the repository root
#                 (gitignored, so your own path stays out of the repository).
#   NOTES         The same as --notes.
#   VERSION, CODESIGN_IDENTITY, BUNDLE_ID, NOTARY_PROFILE
#                 As for scripts/build-app.sh and scripts/make-dmg.sh.

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

NOTES="${NOTES:-}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --notes)
            if [ "$#" -lt 2 ]; then
                echo "--notes needs the text to publish." >&2
                exit 64
            fi
            NOTES="$2"
            shift 2
            ;;
        -h | --help)
            sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 64
            ;;
    esac
done

fail() {
    echo "$1" >&2
    exit 1
}

# Reads a top-level value from a JSON or property-list file.
read_value() {
    plutil -extract "$1" raw -o - "$2" 2>/dev/null
}

is_number() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

RELEASE_DIR="${RELEASE_DIR:-}"
if [ -z "$RELEASE_DIR" ] && [ -f .release-dir ]; then
    RELEASE_DIR="$(head -n 1 .release-dir)"
fi
if [ -z "$RELEASE_DIR" ]; then
    echo "Where should the build be published?" >&2
    echo "Set RELEASE_DIR, or put the folder's path in a file named .release-dir here, for example:" >&2
    echo "    echo \"~/Dropbox/Photo Syncer Releases\" > .release-dir" >&2
    exit 64
fi
case "$RELEASE_DIR" in
    "~") RELEASE_DIR="$HOME" ;;
    "~/"*) RELEASE_DIR="$HOME/${RELEASE_DIR#"~/"}" ;;
esac
RELEASE_DIR="${RELEASE_DIR%/}"
[ -d "$RELEASE_DIR" ] || fail "The release folder $RELEASE_DIR doesn't exist. Create it first (or check that its drive is connected)."
[ -w "$RELEASE_DIR" ] || fail "The release folder $RELEASE_DIR can't be written to."

LATEST="$RELEASE_DIR/latest.json"
PUBLISHED_BUILD=0
if [ -e "$LATEST" ]; then
    PUBLISHED_BUILD="$(read_value build "$LATEST" || true)"
    is_number "$PUBLISHED_BUILD" \
        || fail "$LATEST is there but its build number can't be read. Fix or remove it before publishing."
fi

# Refuse before spending a minute building, then again with the number the app really got.
refuse_unless_newer() {
    if [ "$1" -le "$PUBLISHED_BUILD" ]; then
        echo "Build $1 isn't newer than the published build $PUBLISHED_BUILD, so nothing was published." >&2
        echo "The build number is the git commit count: commit your changes, then publish." >&2
        exit 1
    fi
}
EXPECTED_BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
refuse_unless_newer "$EXPECTED_BUILD"

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "    Note: there are uncommitted changes; they'll be in this build." >&2
fi

scripts/make-dmg.sh

APP="$BUILD_DIR/$APP_NAME.app"
DMG="$BUILD_DIR/Photo-Syncer-$VERSION.dmg"
BUILD_NUMBER="$(read_value CFBundleVersion "$APP/Contents/Info.plist" || true)"
APP_VERSION="$(read_value CFBundleShortVersionString "$APP/Contents/Info.plist" || true)"
is_number "$BUILD_NUMBER" || fail "Couldn't read the build number from $APP."
[ -n "$APP_VERSION" ] || fail "Couldn't read the version from $APP."
[ -f "$DMG" ] || fail "$DMG wasn't built."
refuse_unless_newer "$BUILD_NUMBER"

SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
FILE="Photo-Syncer-$APP_VERSION-$BUILD_NUMBER.dmg"
PARTIAL_IMAGE="$RELEASE_DIR/.$FILE.partial"
PARTIAL_LATEST="$RELEASE_DIR/.latest.json.partial"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; rm -f "$PARTIAL_IMAGE" "$PARTIAL_LATEST"' EXIT

echo "==> Copying $FILE to $RELEASE_DIR"
cp "$DMG" "$PARTIAL_IMAGE"
[ "$(shasum -a 256 "$PARTIAL_IMAGE" | cut -d' ' -f1)" = "$SHA256" ] \
    || fail "The copy in the release folder doesn't match the image that was built; nothing was published."
mv -f "$PARTIAL_IMAGE" "$RELEASE_DIR/$FILE"

echo "==> Announcing it in latest.json"
# plutil escapes the text; it writes JSON from a property list, not from scratch.
plutil -create xml1 "$WORK/latest.plist"
plutil -insert version -string "$APP_VERSION" "$WORK/latest.plist"
plutil -insert build -integer "$BUILD_NUMBER" "$WORK/latest.plist"
plutil -insert file -string "$FILE" "$WORK/latest.plist"
plutil -insert sha256 -string "$SHA256" "$WORK/latest.plist"
plutil -insert publishedAt -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WORK/latest.plist"
if [ -n "$NOTES" ]; then
    plutil -insert notes -string "$NOTES" "$WORK/latest.plist"
fi
plutil -convert json -r -o "$PARTIAL_LATEST" "$WORK/latest.plist"
mv -f "$PARTIAL_LATEST" "$LATEST"

echo "==> Published version $APP_VERSION (build $BUILD_NUMBER)"
echo "    $RELEASE_DIR/$FILE"
echo "    sha256: $SHA256"
