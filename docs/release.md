# Release readiness

YumYum Agent 0.1.0 is a source-build developer preview. Developer ID signing, hardened runtime, notarization, distribution checksums, and release automation are **not implemented**.

## Current source gate

```sh
swift build
swift test
./scripts/build-app.sh
git diff --check
```

Only when `swift test` cannot find `Testing` under standalone Command Line Tools, run the [full fallback command](../README.md#build-and-run-from-source); it must also pass. The fallback does not apply to other failures.

The bundle must contain `Contents/MacOS/YumYum`, `Contents/Resources/yumyum-process-fixture`, and `Contents/Info.plist`. The fixture exists for process diagnostics and regression boundaries.

## Decisions required before release

- Keep bundle ID `kr.yumyum.phase0` or choose a public ID.
- Define and verify Apple Silicon-only, Intel, or universal binary support.
- Assign ownership, custody, and rotation for the Developer ID Application certificate.
- Define hardened runtime, required entitlements, and app sandbox strategy.
- Document TCC permissions such as Screen Recording, Input Monitoring, and Accessibility, and verify on a clean machine.
- Decide whether the fixture is needed and assess exposure risk in a distribution bundle.
- Choose ZIP/DMG format, notarization/stapling, SHA-256 checksums, and verification guidance.
- Verify installation, first launch, CLI discovery, capture, VoiceOver, and Reduce Motion in a clean macOS account.
- Define withdrawal, replacement, user notification, and rollback policy for failed releases.

A future flow should be: clean source gate → release archive → Developer ID signing → hardened runtime/entitlement verification → notarization/stapling → clean-machine verification → checksum publication. Never put credentials in the repository or CI logs.
