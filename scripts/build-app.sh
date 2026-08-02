#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONFIGURATION=${CONFIGURATION:-release}
APP_DIR=${YUMYUM_APP_OUTPUT:-"$ROOT_DIR/.build/YumYum Agent.app"}
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

swift build --package-path "$ROOT_DIR" -c "$CONFIGURATION" --product YumYum
swift build --package-path "$ROOT_DIR" -c "$CONFIGURATION" --product yumyum-process-fixture
BIN_DIR=$(swift build --package-path "$ROOT_DIR" -c "$CONFIGURATION" --show-bin-path)

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
/usr/bin/install -m 755 "$BIN_DIR/YumYum" "$MACOS_DIR/YumYum"
/usr/bin/install \
    -m 755 \
    "$BIN_DIR/yumyum-process-fixture" \
    "$RESOURCES_DIR/yumyum-process-fixture"
/usr/bin/install -m 644 "$ROOT_DIR/AppBundle/Info.plist" "$CONTENTS_DIR/Info.plist"

/usr/bin/touch "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
