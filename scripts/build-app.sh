#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONFIGURATION=${CONFIGURATION:-release}
ARCHITECTURES=${ARCHITECTURES:-}
APP_DIR=${YUMYUM_APP_OUTPUT:-"$ROOT_DIR/.build/YumYum.app"}
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [ -z "$ARCHITECTURES" ]; then
    swift build --package-path "$ROOT_DIR" -c "$CONFIGURATION" --product YumYum
    swift build --package-path "$ROOT_DIR" -c "$CONFIGURATION" --product yumyum-process-fixture
    BIN_DIR=$(swift build --package-path "$ROOT_DIR" -c "$CONFIGURATION" --show-bin-path)
    /usr/bin/install -m 755 "$BIN_DIR/YumYum" "$MACOS_DIR/YumYum"
    /usr/bin/install -m 755 "$BIN_DIR/yumyum-process-fixture" "$RESOURCES_DIR/yumyum-process-fixture"
else
    UNIVERSAL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yumyum-universal.XXXXXX")
    cleanup() {
        STATUS=$?
        trap - EXIT HUP INT TERM
        rm -rf "$UNIVERSAL_DIR"
        exit "$STATUS"
    }
    trap cleanup EXIT HUP INT TERM
    ARCH_COUNT=0
    for ARCH in $ARCHITECTURES; do
        case "$ARCH" in
            arm64|x86_64) ;;
            *) printf 'Unsupported architecture: %s\n' "$ARCH" >&2; exit 1 ;;
        esac
        case " ${SEEN_ARCHITECTURES:-} " in
            *" $ARCH "*) printf 'Duplicate architecture: %s\n' "$ARCH" >&2; exit 1 ;;
        esac
        SEEN_ARCHITECTURES="${SEEN_ARCHITECTURES:-} $ARCH"
        ARCH_COUNT=$((ARCH_COUNT + 1))
        [ "$ARCH_COUNT" -le 2 ] || { printf 'Too many architectures\n' >&2; exit 1; }
        SCRATCH_DIR="$ROOT_DIR/.build/release-$ARCH"
        TRIPLE="$ARCH-apple-macosx14.0"
        swift build --package-path "$ROOT_DIR" --scratch-path "$SCRATCH_DIR" -c "$CONFIGURATION" --triple "$TRIPLE" --product YumYum
        swift build --package-path "$ROOT_DIR" --scratch-path "$SCRATCH_DIR" -c "$CONFIGURATION" --triple "$TRIPLE" --product yumyum-process-fixture
        BIN_DIR=$(swift build --package-path "$ROOT_DIR" --scratch-path "$SCRATCH_DIR" -c "$CONFIGURATION" --triple "$TRIPLE" --show-bin-path)
        /usr/bin/install -m 755 "$BIN_DIR/YumYum" "$UNIVERSAL_DIR/app-$ARCH"
        /usr/bin/install -m 755 "$BIN_DIR/yumyum-process-fixture" "$UNIVERSAL_DIR/fixture-$ARCH"
    done
    [ "$ARCH_COUNT" -gt 0 ] || { printf 'No architectures requested\n' >&2; exit 1; }
    if [ "$ARCH_COUNT" -eq 1 ]; then
        /usr/bin/install -m 755 "$UNIVERSAL_DIR/app-$ARCH" "$MACOS_DIR/YumYum"
        /usr/bin/install -m 755 "$UNIVERSAL_DIR/fixture-$ARCH" "$RESOURCES_DIR/yumyum-process-fixture"
    else
        /usr/bin/lipo -create "$UNIVERSAL_DIR/app-arm64" "$UNIVERSAL_DIR/app-x86_64" -output "$MACOS_DIR/YumYum"
        /usr/bin/lipo -create "$UNIVERSAL_DIR/fixture-arm64" "$UNIVERSAL_DIR/fixture-x86_64" -output "$RESOURCES_DIR/yumyum-process-fixture"
    fi
    /bin/chmod 755 "$MACOS_DIR/YumYum" "$RESOURCES_DIR/yumyum-process-fixture"
    for ARCH in $ARCHITECTURES; do
        /usr/bin/lipo "$MACOS_DIR/YumYum" -verify_arch "$ARCH"
        /usr/bin/lipo "$RESOURCES_DIR/yumyum-process-fixture" -verify_arch "$ARCH"
    done
fi
/usr/bin/install -m 644 "$ROOT_DIR/AppBundle/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/bin/install -m 644 "$ROOT_DIR/AppBundle/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
/usr/bin/install -m 644 "$ROOT_DIR/AppBundle/MenuBarMascot.png" "$RESOURCES_DIR/MenuBarMascot.png"
/usr/bin/install -m 644 "$ROOT_DIR/AppBundle/MenuBarMascot@2x.png" "$RESOURCES_DIR/MenuBarMascot@2x.png"
for icon in "$ROOT_DIR"/AppBundle/AgentIcons/*.png; do
    /usr/bin/install -m 644 "$icon" "$RESOURCES_DIR/$(basename "$icon")"
done

/usr/bin/touch "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
