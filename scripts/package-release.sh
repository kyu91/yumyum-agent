#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PLIST="$ROOT_DIR/AppBundle/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
UNSIGNED=false

usage() {
    printf 'Usage: %s [--version X.Y.Z] [--unsigned]\n' "$0"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; VERSION=$2; shift 2 ;;
        --unsigned) UNSIGNED=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

case "$VERSION" in
    ''|*[!0-9.]*|.*|*.) printf 'Invalid semantic version: %s\n' "$VERSION" >&2; exit 1 ;;
esac
[ "$(printf '%s' "$VERSION" | awk -F. 'NF == 3 && $1 ~ /^(0|[1-9][0-9]*)$/ && $2 ~ /^(0|[1-9][0-9]*)$/ && $3 ~ /^(0|[1-9][0-9]*)$/ { print "yes" }')" = yes ] || {
    printf 'Invalid semantic version: %s\n' "$VERSION" >&2
    exit 1
}
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
[ "$VERSION" = "$PLIST_VERSION" ] || {
    printf 'Version %s does not match Info.plist version %s\n' "$VERSION" "$PLIST_VERSION" >&2
    exit 1
}

if [ "$UNSIGNED" = false ]; then
    : "${APPLE_SIGNING_IDENTITY:?APPLE_SIGNING_IDENTITY is required; pass --unsigned for local unsigned output}"
    : "${APPLE_NOTARY_KEY_ID:?APPLE_NOTARY_KEY_ID is required}"
    : "${APPLE_NOTARY_ISSUER_ID:?APPLE_NOTARY_ISSUER_ID is required}"
    : "${APPLE_NOTARY_PRIVATE_KEY_PATH:?APPLE_NOTARY_PRIVATE_KEY_PATH is required}"
    [ -f "$APPLE_NOTARY_PRIVATE_KEY_PATH" ] || { printf 'Notary private key file is missing\n' >&2; exit 1; }
fi

OUTPUT_DIR=${YUMYUM_RELEASE_OUTPUT:-"$ROOT_DIR/.build/release"}
APP_DIR="$ROOT_DIR/.build/YumYum.app"
DMG_NAME="YumYum-Agent-$VERSION-macOS.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yumyum-release.XXXXXX")
cleanup() {
    STATUS=$?
    trap - EXIT HUP INT TERM
    if mount | grep -Fq "$STAGING_DIR/mount"; then
        /usr/bin/hdiutil detach "$STAGING_DIR/mount" -quiet || true
    fi
    rm -rf "$STAGING_DIR"
    exit "$STATUS"
}
trap cleanup EXIT HUP INT TERM

rm -rf "$APP_DIR"
ARCHITECTURES=${ARCHITECTURES:-} CONFIGURATION=release YUMYUM_APP_OUTPUT="$APP_DIR" "$SCRIPT_DIR/build-app.sh"

if [ "$UNSIGNED" = false ]; then
    /usr/bin/codesign --force --timestamp --options runtime --sign "$APPLE_SIGNING_IDENTITY" "$APP_DIR/Contents/Resources/yumyum-process-fixture"
    /usr/bin/codesign --force --timestamp --options runtime --sign "$APPLE_SIGNING_IDENTITY" "$APP_DIR"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

mkdir -p "$OUTPUT_DIR" "$STAGING_DIR/dmg"
/usr/bin/ditto "$APP_DIR" "$STAGING_DIR/dmg/YumYum.app"
/bin/ln -s /Applications "$STAGING_DIR/dmg/Applications"
rm -f "$DMG_PATH" "$CHECKSUM_PATH"
/usr/bin/hdiutil create -fs HFS+ -format UDZO -volname "YumYum Agent $VERSION" -srcfolder "$STAGING_DIR/dmg" "$DMG_PATH"

if [ "$UNSIGNED" = false ]; then
    /usr/bin/codesign --force --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$DMG_PATH"
    /usr/bin/codesign --verify --strict --verbose=2 "$DMG_PATH"
    xcrun notarytool submit "$DMG_PATH" --key "$APPLE_NOTARY_PRIVATE_KEY_PATH" --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
fi

(cd "$OUTPUT_DIR" && /usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
printf '%s\n%s\n' "$DMG_PATH" "$CHECKSUM_PATH"
