#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
if [ "${EXPECTED_BUNDLE_ID+x}" = x ]; then
    EXPECTED_BUNDLE_ID=$EXPECTED_BUNDLE_ID
else
    EXPECTED_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT_DIR/AppBundle/Info.plist")
fi
[ -n "$EXPECTED_BUNDLE_ID" ] || { printf 'Expected bundle identifier is empty\n' >&2; exit 1; }

[ "$#" -eq 1 ] || { printf 'Usage: %s /path/to/YumYum-Agent-X.Y.Z-macOS.dmg\n' "$0" >&2; exit 2; }
DMG_PATH=$1
CHECKSUM_PATH="$DMG_PATH.sha256"
NAME=$(basename "$DMG_PATH")
VERSION=$(printf '%s\n' "$NAME" | sed -n 's/^YumYum-Agent-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)-macOS\.dmg$/\1/p')
[ -n "$VERSION" ] || { printf 'Invalid artifact name: %s\n' "$NAME" >&2; exit 1; }

(cd "$(dirname "$DMG_PATH")" && /usr/bin/shasum -a 256 -c "$(basename "$CHECKSUM_PATH")")
MOUNT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yumyum-verify.XXXXXX")
cleanup() {
    STATUS=$?
    trap - EXIT HUP INT TERM
    /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
    rmdir "$MOUNT_DIR" 2>/dev/null || true
    exit "$STATUS"
}
trap cleanup EXIT HUP INT TERM
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG_PATH" -quiet

APP="$MOUNT_DIR/YumYum Agent.app"
PLIST="$APP/Contents/Info.plist"
test -L "$MOUNT_DIR/Applications"
test "$(readlink "$MOUNT_DIR/Applications")" = /Applications
test -x "$APP/Contents/MacOS/YumYum"
test -x "$APP/Contents/Resources/yumyum-process-fixture"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$PLIST")" = 'YumYum Agent'
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")" = YumYum
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = "$EXPECTED_BUNDLE_ID"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$VERSION"

APP_ARCHS=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/YumYum")
FIXTURE_ARCHS=$(/usr/bin/lipo -archs "$APP/Contents/Resources/yumyum-process-fixture")
[ "$APP_ARCHS" = "$FIXTURE_ARCHS" ]
if [ -n "${EXPECTED_ARCHITECTURES:-}" ]; then
    for ARCH in $EXPECTED_ARCHITECTURES; do
        /usr/bin/lipo "$APP/Contents/MacOS/YumYum" -verify_arch "$ARCH"
        /usr/bin/lipo "$APP/Contents/Resources/yumyum-process-fixture" -verify_arch "$ARCH"
    done
fi
if [ "${SIGNED_RELEASE:-false}" = true ]; then
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
    /usr/bin/codesign --verify --strict --verbose=2 "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
fi
printf 'Verified %s\nArchitectures: %s\n' "$DMG_PATH" "$APP_ARCHS"
