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
    SIGNED="$CHECK_ROOT/.github/workflows/release.yml"
    UNSIGNED="$CHECK_ROOT/.github/workflows/unsigned-release.yml"

    grep -Fq 'ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)' "$VERIFY"
    grep -Fq "Print :CFBundleIdentifier' \"\$ROOT_DIR/AppBundle/Info.plist\"" "$VERIFY"
    grep -Fq '= "$EXPECTED_BUNDLE_ID"' "$VERIFY"
    ! grep -Fq '= kr.yumyum.phase0' "$VERIFY" || return 1

    for WORKFLOW in "$SIGNED" "$UNSIGNED"; do
        grep -Fq 'workflow_dispatch:' "$WORKFLOW"
        ! grep -Fq 'push:' "$WORKFLOW" || return 1
        grep -Fq 'ref: refs/tags/${{ inputs.tag }}' "$WORKFLOW"
        grep -Fq 'fetch-depth: 0' "$WORKFLOW"
        grep -Fq "grep -Eq '^v(0|[1-9][0-9]*)" "$WORKFLOW"
        grep -Fq "grep -Eq '^[0-9a-f]{40}$'" "$WORKFLOW"
        grep -Fq 'test "$TAG_COMMIT" = "$RELEASE_COMMIT"' "$WORKFLOW"
        grep -Fq 'test "$(git rev-parse HEAD)" = "$RELEASE_COMMIT"' "$WORKFLOW"
        grep -Fq 'test "$RELEASE_TAG" = "v${VERSION}"' "$WORKFLOW"
        grep -Fq 'test "$BUNDLE_ID" = io.github.kyu91.yumyumagent' "$WORKFLOW" || \
            grep -Fq "Print :CFBundleIdentifier' AppBundle/Info.plist)\" = io.github.kyu91.yumyumagent" "$WORKFLOW"
        grep -Fq 'runs-on: macos-26' "$WORKFLOW"
        grep -Fq 'sudo xcode-select -s /Applications/Xcode_26.6.app/Contents/Developer' "$WORKFLOW"
        grep -Fq 'test "$XCODE_VERSION" = 26.6' "$WORKFLOW"
    done

    ! grep -Fq -- '--unsigned' "$SIGNED" || return 1
    [ "$(grep -Fc '${{ secrets.' "$SIGNED")" -eq 6 ] || return 1
    grep -Fq 'xcrun notarytool submit' "$PACKAGE"
    grep -Fq 'xcrun stapler staple' "$PACKAGE"
    grep -Fq '/usr/sbin/spctl --assess' "$PACKAGE"
    grep -Fq 'if: always()' "$SIGNED"
    grep -Fq -- "--jq 'select(.isDraft == true and .isPrerelease == false) | \"reusable\"'" "$SIGNED"
    grep -Fq 'test "$RELEASE_STATE" = reusable' "$SIGNED"
    grep -Fq 'select(all(.name == \"$DMG_NAME\" or .name == \"$CHECKSUM_NAME\")) | \"allowed-assets\"' "$SIGNED"
    grep -Fq 'test "$ASSET_STATE" = allowed-assets' "$SIGNED"
    grep -Fq 'select(length == 2 and ([.[] | select(.name == \"$DMG_NAME\")] | length) == 1 and ([.[] | select(.name == \"$CHECKSUM_NAME\")] | length) == 1) | \"exact-assets\"' "$SIGNED"
    grep -Fq '| \"exact-assets\"' "$SIGNED"
    grep -Fq 'test "$ASSET_STATE" = exact-assets' "$SIGNED"
    grep -Fq 'gh release edit "$RELEASE_TAG" --draft=false --prerelease=false' "$SIGNED"
    grep -Fq '[ "$BUNDLE_ID" = kr.yumyum.phase0 ]' "$SIGNED"
    grep -Fq "''|.*|*.|*..*|*[!A-Za-z0-9.-]*) echo 'CFBundleIdentifier is empty or invalid.'" "$SIGNED"
    SIGNED_REUSABLE_ASSET_LINE=$(line_number "$SIGNED" 'test "$ASSET_STATE" = allowed-assets')
    SIGNED_UPLOAD_LINE=$(line_number "$SIGNED" 'gh release upload "$RELEASE_TAG"')
    SIGNED_EXACT_ASSET_LINE=$(line_number "$SIGNED" 'test "$ASSET_STATE" = exact-assets')
    SIGNED_PUBLISH_LINE=$(line_number "$SIGNED" 'gh release edit "$RELEASE_TAG" --draft=false --prerelease=false')
    [ "$SIGNED_REUSABLE_ASSET_LINE" -lt "$SIGNED_UPLOAD_LINE" ] || return 1
    [ "$SIGNED_UPLOAD_LINE" -lt "$SIGNED_EXACT_ASSET_LINE" ] && [ "$SIGNED_EXACT_ASSET_LINE" -lt "$SIGNED_PUBLISH_LINE" ] || return 1

    grep -Fq "ARCHITECTURES='arm64 x86_64' ./scripts/package-release.sh --version \"\$VERSION\" --unsigned" "$UNSIGNED"
    grep -Fq "EXPECTED_ARCHITECTURES='arm64 x86_64'" "$UNSIGNED"
    grep -Fq 'contents: write' "$UNSIGNED"
    [ "$(grep -Fc 'contents: write' "$UNSIGNED")" -eq 1 ] || return 1
    ! grep -Fq '${{ secrets.' "$UNSIGNED" || return 1
    ! grep -Eq 'APPLE_|codesign|notarytool|stapler|spctl' "$UNSIGNED" || return 1
    grep -Fq -- '--prerelease' "$UNSIGNED"
    grep -Fq -- '--draft' "$UNSIGNED"
    grep -Fq -- "--jq 'select(.isDraft == true and .isPrerelease == true) | \"reusable\"'" "$UNSIGNED"
    grep -Fq 'test "$RELEASE_STATE" = reusable' "$UNSIGNED"
    grep -Fq '| \"allowed-assets\"' "$UNSIGNED"
    grep -Fq 'test "$ASSET_STATE" = allowed-assets' "$UNSIGNED"
    grep -Fq 'select(length == 2 and (' "$UNSIGNED"
    grep -Fq '| \"exact-assets\"' "$UNSIGNED"
    grep -Fq 'test "$ASSET_STATE" = exact-assets' "$UNSIGNED"
    grep -Fq 'mkdir "$STAGING"' "$UNSIGNED"
    grep -Fq 'cp ".build/release/YumYum-Agent-${VERSION}-macOS.dmg" "$STAGING/"' "$UNSIGNED"
    grep -Fq 'cp ".build/release/YumYum-Agent-${VERSION}-macOS.dmg.sha256" "$STAGING/"' "$UNSIGNED"
    ! grep -Fq 'YumYum-Agent-*-macOS' "$UNSIGNED" || return 1
    grep -Fq 'sed "s/<version>/$VERSION/g" docs/unsigned-release-notes.md > "$NOTES"' "$UNSIGNED"
    grep -Fq "! grep -Fq '<version>' \"\$NOTES\"" "$UNSIGNED"
    [ "$(grep -Fc -- '--notes-file "$NOTES"' "$UNSIGNED")" -eq 2 ] || return 1
    grep -Fq 'gh release upload "$RELEASE_TAG" "$DMG" "$CHECKSUM" --clobber' "$UNSIGNED"
    ! grep -Eq 'uses: actions/(checkout|upload-artifact|download-artifact)@v[0-9]' "$UNSIGNED" || return 1
    REUSABLE_ASSET_LINE=$(line_number "$UNSIGNED" 'test "$ASSET_STATE" = allowed-assets')
    UPLOAD_LINE=$(line_number "$UNSIGNED" 'gh release upload "$RELEASE_TAG" "$DMG" "$CHECKSUM" --clobber')
    EXACT_ASSET_LINE=$(line_number "$UNSIGNED" 'test "$ASSET_STATE" = exact-assets')
    PUBLISH_LINE=$(line_number "$UNSIGNED" 'gh release edit "$RELEASE_TAG" --draft=false --prerelease')
    [ "$REUSABLE_ASSET_LINE" -lt "$UPLOAD_LINE" ] || return 1
    [ "$UPLOAD_LINE" -lt "$EXACT_ASSET_LINE" ] && [ "$EXACT_ASSET_LINE" -lt "$PUBLISH_LINE" ] || return 1

    STAPLE_LINE=$(line_number "$PACKAGE" 'xcrun stapler staple "$DMG_PATH"')
    CHECKSUM_LINE=$(line_number "$PACKAGE" '/usr/bin/shasum -a 256 "$DMG_NAME"')
    [ "$STAPLE_LINE" -lt "$CHECKSUM_LINE" ] || return 1
    grep -Fq '/usr/bin/lipo -create "$UNIVERSAL_DIR/app-arm64" "$UNIVERSAL_DIR/app-x86_64"' "$BUILD"
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
cp "$ROOT_DIR/.github/workflows/release.yml" "$ROOT_DIR/.github/workflows/unsigned-release.yml" "$TEST_DIR/source/.github/workflows/"

mutate_and_reject() {
    MUTATION=$1
    rm -rf "$TEST_DIR/mutated"
    cp -R "$TEST_DIR/source" "$TEST_DIR/mutated"
    cp -R "$TEST_DIR/mutated" "$TEST_DIR/before"
    sh -c "$MUTATION"
    ! diff -qr "$TEST_DIR/before" "$TEST_DIR/mutated" >/dev/null || {
        printf 'Mutation changed no files: %s\n' "$MUTATION" >&2
        exit 1
    }
    rm -rf "$TEST_DIR/before"
    expect_failure check_sources "$TEST_DIR/mutated"
}

mutate_and_reject "printf '%s\n' 'test bundle = kr.yumyum.phase0' >> '$TEST_DIR/mutated/scripts/verify-release.sh'"
mutate_and_reject "sed -i '' '/workflow_dispatch:/d' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' '/workflow_dispatch:/d' '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' '/test \"\$TAG_COMMIT\" = \"\$RELEASE_COMMIT\"/d' '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' 's/ --unsigned//' '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' '/EXPECTED_ARCHITECTURES=/d' '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' 's/select(.isDraft == true and .isPrerelease == false)/select(.isDraft == true)/' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' 's/test \"\$RELEASE_STATE\" = reusable/test -n \"\$RELEASE_STATE\"/' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' '/allowed-assets/d' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' 's/or .name ==/or true or .name ==/' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' 's/length == 2/length >= 1/' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' '/test \"\$ASSET_STATE\" = exact-assets/d' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' 's/select(.isDraft == true and .isPrerelease == true)/select(.isDraft == true)/' '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' 's/test \"\$RELEASE_STATE\" = reusable/test -n \"\$RELEASE_STATE\"/' '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' '/allowed-assets/d' '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' 's/length == 2/length >= 1/' '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' '/test \"\$ASSET_STATE\" = exact-assets/d' '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' 's|YumYum-Agent-\${{ steps.prepare.outputs.version }}-macOS.dmg|YumYum-Agent-*-macOS.dmg|' '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' '/sed \"s\/<version>\//d' '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' \"/! grep -Fq '<version>'/d\" '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' 's/ --draft=false --prerelease/ --draft=false/' '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "printf '%s\n' 'value: \${{ secrets.TEST }}' >> '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' 's/\"\$DMG\" \"\$CHECKSUM\"/\"\$DMG\"/' '$TEST_DIR/mutated/.github/workflows/unsigned-release.yml'"
mutate_and_reject "sed -i '' '/test \"\$BUNDLE_ID\" = io.github.kyu91.yumyumagent/d' '$TEST_DIR/mutated/.github/workflows/release.yml'"
mutate_and_reject "sed -i '' '/xcrun stapler staple/d' '$TEST_DIR/mutated/scripts/package-release.sh'; printf '%s\n' 'xcrun stapler staple \"\$DMG_PATH\"' >> '$TEST_DIR/mutated/scripts/package-release.sh'"

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
