# Release readiness

YumYum Agent 0.1.0 is published as the prerelease [YumYum Agent 0.1.0 — Unsigned Preview](https://github.com/kyu91/yumyum-agent/releases/tag/v0.1.0). It is not a draft and contains exactly `YumYum-Agent-0.1.0-macOS.dmg` and `YumYum-Agent-0.1.0-macOS.dmg.sha256`. It is not Developer ID signed or Apple notarized; clean-machine Gatekeeper behavior and Intel hardware execution remain unverified.

## Current source gate

```sh
swift build
swift test
./scripts/build-app.sh
ARCHITECTURES='arm64 x86_64' ./scripts/package-release.sh --version 0.1.0 --unsigned
EXPECTED_ARCHITECTURES='arm64 x86_64' ./scripts/test-release.sh .build/release/YumYum-Agent-0.1.0-macOS.dmg
git diff --check
```

The DMG contains `YumYum.app` and an `/Applications` symlink. Its `.sha256` file uses `shasum -a 256` format. Packaging remains signed by default and refuses unsigned output unless `--unsigned` is explicit. The permanent identity is `io.github.kyu91.yumyumagent`.

## Release paths

The published unsigned prerelease was produced by the manual [Unsigned Release workflow](https://github.com/kyu91/yumyum-agent/actions/workflows/unsigned-release.yml). The published assets were subsequently downloaded; their checksum, DMG mount, and `x86_64` and `arm64` slices were verified.

Both workflows require an existing strict `vX.Y.Z` tag and its exact 40-character commit SHA. They check out `refs/tags/<tag>` with full history and require the tag commit, checked-out HEAD, supplied commit, and `v<CFBundleShortVersionString>` to match. Neither workflow runs on tag push.

First merge and push the workflow files to the default branch. Then tag that exact commit and manually dispatch the selected workflow from the default branch, supplying the tag and the same commit SHA.

- `.github/workflows/unsigned-release.yml` uses macOS 26/Xcode 26.6, builds and tests, explicitly passes `--unsigned`, verifies both `arm64` and `x86_64` slices and SHA-256, then uploads only the DMG and `.sha256`. The publish job alone has `contents: write`. It creates or reuses only an unsigned prerelease draft, replaces both draft assets on rerun, and publishes only after both uploads succeed. It never reads Apple secrets or signs/notarizes anything. Release text is in [`unsigned-release-notes.md`](unsigned-release-notes.md).
- `.github/workflows/release.yml` remains fail-closed signed production release automation. It validates the permanent bundle ID, requires all six Apple secrets, signs the fixture, app, and DMG, notarizes, staples, Gatekeeper-assesses, creates a draft, uploads exactly the DMG and checksum, and publishes only after success. It has no unsigned fallback.

Signed releases require these repository secrets:

- `APPLE_DEVELOPER_ID_P12_BASE64`
- `APPLE_DEVELOPER_ID_P12_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`
- `APPLE_NOTARY_PRIVATE_KEY_BASE64`

Temporary certificate/key material and the temporary keychain are removed with `always()`. Secrets must never be printed or committed.

The published DMG has been downloaded, checksum-verified, mounted, and confirmed to contain `x86_64` and `arm64` slices. Signed/notarized output, clean-machine Gatekeeper verification, and Intel hardware execution remain unverified.
