#!/bin/bash
#
# Publishes the committed code as a release for the app's updater (Settings ›
# Updates): builds the app, packs it in a disk image, copies that into the
# release folder and then announces it there in latest.json. Every Mac whose
# Photo Syncer looks at that folder sees the new build, downloads it, and offers
# Install & Restart. Then tags the commit v<version>-<build> and pushes the tag
# (a failed push only warns).
#
#   scripts/release.sh                       notes are the commit titles since the last release
#   scripts/release.sh --notes "What changed, in a line or two."
#
# Handoff's after-merge step runs this in its _release checkout of main.
#
# The release folder ends up holding:
#
#   Photo-Syncer-<version>-<build>.dmg   the newest three published builds
#   latest.json                          the newest one: version, build, file,
#                                        sha256, publishedAt and optional notes
#
# latest.json is written last, so a half-copied image is never announced.
# A build is only published if its build number (the git commit count, which
# scripts/build-app.sh stamps into the app) is higher than the published one:
# commit before releasing again. The version comes from the VERSION file; raise
# it for a new version number. It's for people, not compared.
#
# Environment:
#   RELEASE_DIR   The release folder. Defaults to the first line of a file named
#                 .release-dir in the repository root (gitignored, so your own
#                 path stays out of the repository), else releases/ in this
#                 Mac's Photo Syncer folder (~/Library/Application Support/Photo
#                 Syncer, or $PHOTO_SYNCER_HOME), which the app on this Mac reads
#                 when no other folder is chosen. To reach other Macs, use a
#                 folder they can all reach (iCloud Drive, Dropbox, a shared
#                 drive), for example "~/Dropbox/Photo Syncer Releases".
#   NOTES         The same as --notes.
#   VERSION, CODESIGN_IDENTITY, BUNDLE_ID
#                 As for scripts/build-app.sh.

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
            sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
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

if [ -n "$(git status --porcelain)" ]; then
    fail "Commit or stash your changes first: a release is built from the committed code."
fi

RELEASE_DIR="${RELEASE_DIR:-}"
if [ -z "$RELEASE_DIR" ] && [ -f .release-dir ]; then
    RELEASE_DIR="$(head -n 1 .release-dir)"
fi
case "$RELEASE_DIR" in
    "~") RELEASE_DIR="$HOME" ;;
    "~/"*) RELEASE_DIR="$HOME/${RELEASE_DIR#"~/"}" ;;
esac
if [ -z "$RELEASE_DIR" ]; then
    # Keep in step with Storage.defaultReleaseFolder.
    RELEASE_DIR="${PHOTO_SYNCER_HOME:-$HOME/Library/Application Support/Photo Syncer}/releases"
    mkdir -p "$RELEASE_DIR"
fi
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
        echo "The build number is the git commit count: commit your changes, then release." >&2
        exit 1
    fi
}
EXPECTED_BUILD="$(git rev-list --count HEAD)"
refuse_unless_newer "$EXPECTED_BUILD"

if [ -z "$NOTES" ]; then
    PREVIOUS="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
    NOTES="$(git log --no-merges --format='- %s' ${PREVIOUS:+$PREVIOUS..}HEAD | head -n 30)"
fi

scripts/build-app.sh

APP="$BUILD_DIR/$APP_NAME.app"
BUILD_NUMBER="$(read_value CFBundleVersion "$APP/Contents/Info.plist" || true)"
APP_VERSION="$(read_value CFBundleShortVersionString "$APP/Contents/Info.plist" || true)"
is_number "$BUILD_NUMBER" || fail "Couldn't read the build number from $APP."
[ -n "$APP_VERSION" ] || fail "Couldn't read the version from $APP."
refuse_unless_newer "$BUILD_NUMBER"

FILE="Photo-Syncer-$APP_VERSION-$BUILD_NUMBER.dmg"
DMG="$BUILD_DIR/$FILE"
PARTIAL_IMAGE="$RELEASE_DIR/.$FILE.partial"
PARTIAL_LATEST="$RELEASE_DIR/.latest.json.partial"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; rm -f "$PARTIAL_IMAGE" "$PARTIAL_LATEST"' EXIT

# A plain image, not make-dmg.sh's styled one: that step scripts Finder, which can stall
# waiting for a permission prompt when nobody is at the Mac. The updater only needs the app.
echo "==> Packing $FILE"
ditto "$APP" "$WORK/image/$APP_NAME.app"
rm -f "$DMG"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$WORK/image" -fs HFS+ -format UDZO -ov "$DMG"
SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

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
ls -t "$RELEASE_DIR"/Photo-Syncer-*.dmg | tail -n +4 | while IFS= read -r old; do rm -f "$old"; done

echo "==> Published version $APP_VERSION (build $BUILD_NUMBER)"
echo "    $RELEASE_DIR/$FILE"
echo "    sha256: $SHA256"

TAG="v$APP_VERSION-$BUILD_NUMBER"
if git tag -a "$TAG" -m "Photo Syncer $APP_VERSION ($BUILD_NUMBER)" && git push --quiet origin "refs/tags/$TAG"; then
    echo "==> Tagged and pushed $TAG"
else
    echo "    Couldn't tag or push $TAG; the release is published anyway. Push it later with: git push origin $TAG" >&2
fi
