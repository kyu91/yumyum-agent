# Release readiness

YumYum Agent 0.1.0 remains a developer preview. The local unsigned packaging path and tag-only GitHub Actions pipeline are implemented; an actual Developer ID signed, notarized, clean-machine release has not been produced or published.

## Current source gate

```sh
swift build
swift test
./scripts/build-app.sh
./scripts/package-release.sh --unsigned
./scripts/test-release.sh .build/release/YumYum-Agent-0.1.0-macOS.dmg
git diff --check
```

Only when `swift test` cannot find `Testing` under standalone Command Line Tools, run the [full fallback command](../README.md#build-and-run-from-source); it must also pass. The fallback does not apply to other failures.

The DMG contains `YumYum Agent.app` and an `/Applications` symlink. Its portable checksum file contains `SHA-256  filename` in `shasum -a 256` format. Local unsigned packaging keeps `CFBundleIdentifier=kr.yumyum.phase0`; the release workflow rejects that placeholder before signing or publishing. Choose and update a permanent reverse-DNS bundle ID before the first release.

`scripts/package-release.sh` refuses unsigned output unless `--unsigned` is explicit. Signed mode signs the fixture, app, and compressed read-only UDZO DMG in that order with timestamps; executables and the app use hardened runtime. It verifies the DMG signature before notarization, then staples, validates, and Gatekeeper-assesses it. No entitlements are used because the current code has not established a requirement for them.

## Tag release

`.github/workflows/release.yml` runs only for `v*` tags and requires the tag to equal `v<CFBundleShortVersionString>`. Full Xcode builds `arm64` and `x86_64` separately; `lipo` creates and verifies both slices in the app executable and fixture. A successful run publishes only:

- `YumYum-Agent-<version>-macOS.dmg`
- `YumYum-Agent-<version>-macOS.dmg.sha256`

Configure these GitHub Actions repository secrets before creating a tag:

- `APPLE_DEVELOPER_ID_P12_BASE64`
- `APPLE_DEVELOPER_ID_P12_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`
- `APPLE_NOTARY_PRIVATE_KEY_BASE64`

The workflow creates its own temporary keychain password and temporary `.p8` file and removes both signing files and the keychain with `always()`. Secrets must never be printed or committed.

This Apple Silicon Command Line Tools host built and mounted a local unsigned Universal DMG, checksum-verified it, and proved `x86_64` and `arm64` slices in both the app executable and fixture. Signed/notarized output, Gatekeeper assessment, clean-machine verification, and Intel hardware execution remain unverified.

## Blocking gates for the first public release

- Decide the permanent public bundle ID; the pipeline currently preserves `kr.yumyum.phase0`.
- Assign ownership, custody, and rotation for the Developer ID Application certificate.
- Configure and validate the six GitHub Actions secrets above.
- Document TCC permissions such as Screen Recording, Input Monitoring, and Accessibility, and verify on a clean machine.
- Verify installation, first launch, CLI discovery, capture, Intel execution, VoiceOver, and Reduce Motion in a clean macOS account.
- Define withdrawal, replacement, user notification, and rollback policy for failed releases.
