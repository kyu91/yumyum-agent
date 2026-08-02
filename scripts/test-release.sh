#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yumyum-release-test.XXXXXX")
cleanup() {
    STATUS=$?
    trap - EXIT HUP INT TERM
    rm -rf "$TEST_DIR"
    exit "$STATUS"
}
trap cleanup EXIT HUP INT TERM

expect_failure() {
    set +e
    (set -e; "$@") >/dev/null 2>&1
    STATUS=$?
    set -e
    if [ "$STATUS" -eq 0 ]; then
        printf 'Expected failure: %s\n' "$*" >&2
        exit 1
    fi
}

line_number() {
    grep -nF "$2" "$1" | sed -n '1s/:.*//p'
}

check_sources() {
    CHECK_ROOT=$1
    BUILD="$CHECK_ROOT/scripts/build-app.sh"
    VERIFY="$CHECK_ROOT/scripts/verify-release.sh"
    PACKAGE="$CHECK_ROOT/scripts/package-release.sh"
    WORKFLOW="$CHECK_ROOT/.github/workflows/release.yml"

    grep -Fq 'ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)' "$VERIFY"
    grep -Fq "Print :CFBundleIdentifier' \"\$ROOT_DIR/AppBundle/Info.plist\"" "$VERIFY"
    grep -Fq '= "$EXPECTED_BUNDLE_ID"' "$VERIFY"
    ! grep -Fq '= kr.yumyum.phase0' "$VERIFY" || return 1

    CHECKOUT='actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2'
    [ "$(grep -Fc "$CHECKOUT" "$WORKFLOW")" -eq 2 ]
    [ "$(grep -Fc 'ref: ${{ github.sha }}' "$WORKFLOW")" -eq 2 ] || return 1
    [ "$(grep -Fc 'git rev-parse "refs/tags/${GITHUB_REF_NAME}^{commit}"' "$WORKFLOW")" -eq 3 ] || return 1
    [ "$(grep -Fc 'runs-on: macos-26' "$WORKFLOW")" -eq 2 ] || return 1
    XCODE_SELECT='sudo xcode-select -s /Applications/Xcode_26.6.app/Contents/Developer'
    [ "$(grep -Fc "$XCODE_SELECT" "$WORKFLOW")" -eq 2 ] || return 1
    [ "$(grep -Fc 'xcodebuild -version' "$WORKFLOW")" -eq 4 ] || return 1
    [ "$(grep -Fc 'test "$XCODE_VERSION" = 26.6' "$WORKFLOW")" -eq 2 ] || return 1
    [ "$(grep -Fc 'test "$SWIFT_MAJOR" -ge 6' "$WORKFLOW")" -eq 2 ] || return 1
    FIRST_SELECT_LINE=$(grep -nF "$XCODE_SELECT" "$WORKFLOW" | sed -n '1s/:.*//p')
    SECOND_SELECT_LINE=$(grep -nF "$XCODE_SELECT" "$WORKFLOW" | sed -n '2s/:.*//p')
    BUILD_LINE=$(line_number "$WORKFLOW" 'swift build')
    SIGN_LINE=$(line_number "$WORKFLOW" 'Import Developer ID certificate')
    [ "$FIRST_SELECT_LINE" -lt "$BUILD_LINE" ] && [ "$SECOND_SELECT_LINE" -lt "$SIGN_LINE" ] || return 1
    ! grep -Fq 'actions/checkout@v4' "$WORKFLOW"
    TAG_LINE=$(line_number "$WORKFLOW" 'git rev-parse "refs/tags/${GITHUB_REF_NAME}^{commit}"')
    CREATE_LINE=$(line_number "$WORKFLOW" 'gh release create "$GITHUB_REF_NAME"')
    UPLOAD_LINE=$(line_number "$WORKFLOW" 'gh release upload "$GITHUB_REF_NAME"')
    PUBLISH_LINE=$(line_number "$WORKFLOW" 'gh release edit "$GITHUB_REF_NAME" --draft=false')
    [ -n "$TAG_LINE" ] && [ "$TAG_LINE" -lt "$CREATE_LINE" ]
    [ "$CREATE_LINE" -lt "$UPLOAD_LINE" ] && [ "$UPLOAD_LINE" -lt "$PUBLISH_LINE" ] || return 1
    grep -Fq '[ "$BUNDLE_ID" = kr.yumyum.phase0 ]' "$WORKFLOW" || return 1
    grep -Fq 'Choose and update a permanent reverse-DNS CFBundleIdentifier before the first release.' "$WORKFLOW"

    STAPLE_LINE=$(line_number "$PACKAGE" 'xcrun stapler staple "$DMG_PATH"')
    CHECKSUM_LINE=$(line_number "$PACKAGE" '/usr/bin/shasum -a 256 "$DMG_NAME"')
    [ "$STAPLE_LINE" -lt "$CHECKSUM_LINE" ] || return 1
    grep -Fq '/usr/bin/lipo -create "$UNIVERSAL_DIR/app-arm64" "$UNIVERSAL_DIR/app-x86_64"' "$BUILD" || return 1
    grep -Fq '/usr/bin/lipo -create "$UNIVERSAL_DIR/fixture-arm64" "$UNIVERSAL_DIR/fixture-x86_64"' "$BUILD"
    grep -Fq "*\" \$ARCH \"*) printf 'Duplicate architecture:" "$BUILD"
    ! grep -Fq 'lipo -create $APP_INPUTS' "$BUILD" || return 1
}

expect_failure "$SCRIPT_DIR/package-release.sh" --version invalid --unsigned
expect_failure "$SCRIPT_DIR/package-release.sh" --version 9.9.9 --unsigned
expect_failure env -u APPLE_SIGNING_IDENTITY -u APPLE_NOTARY_KEY_ID -u APPLE_NOTARY_ISSUER_ID -u APPLE_NOTARY_PRIVATE_KEY_PATH "$SCRIPT_DIR/package-release.sh"
expect_failure env EXPECTED_BUNDLE_ID= "$SCRIPT_DIR/verify-release.sh" "$TEST_DIR/missing.dmg"
expect_failure env ARCHITECTURES='arm64 arm64' YUMYUM_APP_OUTPUT="$TEST_DIR/output path/YumYum Agent.app" "$SCRIPT_DIR/build-app.sh"

check_sources "$ROOT_DIR"
mkdir -p "$TEST_DIR/source/scripts" "$TEST_DIR/source/.github/workflows"
cp "$SCRIPT_DIR/build-app.sh" "$SCRIPT_DIR/verify-release.sh" "$SCRIPT_DIR/package-release.sh" "$TEST_DIR/source/scripts/"
cp "$ROOT_DIR/.github/workflows/release.yml" "$TEST_DIR/source/.github/workflows/"

mutate_and_reject() {
    MUTATION=$1
    rm -rf "$TEST_DIR/mutated"
    cp -R "$TEST_DIR/source" "$TEST_DIR/mutated"
    sh -c "$MUTATION"
    expect_failure check_sources "$TEST_DIR/mutated"
}

mutate_and_reject "printf '%s\n' 'test bundle = kr.yumyum.phase0' >> '$TEST_DIR/mutated/scripts/verify-release.sh'"
mutate_and_reject "sed -i '' '/ref: \${{ github.sha }}/d' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' 's/runs-on: macos-26/runs-on: macos-14/' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' '/sudo xcode-select/d' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' 's/test \"\$XCODE_VERSION\" = 26.6/test \"\$XCODE_VERSION\" = 16.2/' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' '/git rev-parse \"refs\/tags\//d' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' '/gh release edit .*--draft=false/{h;d;}; /gh release upload/{x;p;x;}' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' '/xcrun stapler staple/d' '$TEST_DIR/mutated/scripts/package-release.sh'; printf '%s\n' 'xcrun stapler staple \"\$DMG_PATH\"' >> '$TEST_DIR/mutated/scripts/package-release.sh'"
mutate_and_reject "sed -i '' 's|/usr/bin/lipo -create \"\$UNIVERSAL_DIR/app-arm64\" \"\$UNIVERSAL_DIR/app-x86_64\"|/usr/bin/lipo -create \$APP_INPUTS|' '$TEST_DIR/mutated/scripts/build-app.sh'"
mutate_and_reject "sed -i '' '/\[ \"\$BUNDLE_ID\" = kr.yumyum.phase0 \]/d' '$TEST_DIR/mutated/.github/workflows/release.yml'"

if [ -f "$ROOT_DIR/.build/release-arm64/arm64-apple-macosx/release/YumYum" ] && [ -f "$ROOT_DIR/.build/release-x86_64/x86_64-apple-macosx/release/YumYum" ]; then
    cp "$ROOT_DIR/.build/release-arm64/arm64-apple-macosx/release/YumYum" "$TEST_DIR/arm input"
    cp "$ROOT_DIR/.build/release-x86_64/x86_64-apple-macosx/release/YumYum" "$TEST_DIR/intel input"
    /usr/bin/lipo -create "$TEST_DIR/arm input" "$TEST_DIR/intel input" -output "$TEST_DIR/universal output"
    /usr/bin/lipo "$TEST_DIR/universal output" -verify_arch arm64 x86_64
fi

if [ "$#" -eq 1 ]; then
    "$SCRIPT_DIR/verify-release.sh" "$1"
elif [ "$#" -ne 0 ]; then
    printf 'Usage: %s [release.dmg]\n' "$0" >&2
    exit 2
fi
printf 'Release checks passed\n'
