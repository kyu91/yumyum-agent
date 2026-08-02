# YumYum Agent

[English](README.md) *(current)* | [한국어](README.ko.md)

YumYum Agent is a Swift/AppKit macOS app that lets you “feed” a selected screen area or local file to a floating pet and read responses from an installed local CLI agent in native bubbles and chat.

> **Unsigned developer preview (0.1.0):** [YumYum Agent 0.1.0 — Unsigned Preview](https://github.com/kyu91/yumyum-agent/releases/tag/v0.1.0) is available as a prerelease. It is **not Developer ID signed or Apple notarized**.

## Features

- One validated flow for screen captures, file selection, Finder drops, and chat input
- Streaming responses, transcript continuity, cancellation and retry, with Reduce Motion and VoiceOver support
- CLI discovery and revalidation using exact executable paths and local `--version`/`--help` contracts
- App-owned `SOUL.md` response customization subordinate to safety and privacy policies
- Default-deny external changes; Hermes permission requests are always cancelled
- English and Korean interface with immediate switching in **Settings → General → Language**

## Requirements

- macOS 14 or later
- Xcode or Command Line Tools with Swift 6.0 or later
- One supported CLI below, installed and signed in separately

This Apple Silicon Command Line Tools host has built and mounted a local unsigned Universal DMG, verified its checksum, and proven `x86_64` and `arm64` slices in both the app executable and fixture. Signed/notarized distribution, Gatekeeper assessment, clean-machine verification, and Intel hardware execution remain unverified.

## Download and install

Download both `YumYum-Agent-0.1.0-macOS.dmg` and `YumYum-Agent-0.1.0-macOS.dmg.sha256` from the [v0.1.0 release](https://github.com/kyu91/yumyum-agent/releases/tag/v0.1.0). This **Unsigned Preview** is not Developer ID signed or Apple notarized. Trust only assets from the official repository and verify them in the same directory:

```sh
shasum -a 256 -c YumYum-Agent-0.1.0-macOS.dmg.sha256
```

Open the DMG, drag the app to **Applications**, then Control-click/right-click it and choose **Open**. If blocked, use **System Settings → Privacy & Security → Open Anyway**; warning text varies. Never disable Gatekeeper globally. macOS privacy permissions may still be requested. Clean-machine Gatekeeper behavior and Intel hardware execution remain unverified even though both architecture slices are present.

Local developers can explicitly create and verify an unsigned DMG:

```sh
./scripts/package-release.sh --unsigned
./scripts/test-release.sh .build/release/YumYum-Agent-0.1.0-macOS.dmg
```

## Build and run from source

```sh
swift build
swift test
./scripts/build-app.sh
open ".build/YumYum Agent.app"
```

The script creates a local release `.build/YumYum Agent.app` by default. Use `CONFIGURATION=debug ./scripts/build-app.sh` for a debug bundle.

Only when standalone Command Line Tools cannot find the `Testing` module, run this full regression command:

```sh
swift test \
  -Xswiftc -F \
  -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath \
  -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
```

## First use

1. Install a supported CLI and complete its own sign-in flow.
2. Run YumYum Agent and explicitly select a discovered executable in **Settings → Agent**.
3. If needed, grant Screen Recording, Input Monitoring, or Accessibility permission in macOS Settings.
4. Click the pet or press `Control+Option+Space` to capture, choose files, or chat.

Cancellation, denied permission, empty input, invalid attachments, and no agent selection never send a request. Each file is limited to 20 MB; folders, symlinks, aliases, unsupported formats, and known credential files are rejected.

## Supported local CLIs

| CLI | Verified execution boundary |
|---|---|
| Hermes | `hermes acp` / ACP v1; every permission request returns `cancelled` |
| OpenCode | `opencode run --pure --format json` |
| Codex | `codex exec`, read-only sandbox, untrusted approval |
| Claude Code | Structured print execution, plan permission mode |

These names are trademarks used only to describe compatibility. YumYum Agent is independent of these vendors and does not claim sponsorship or endorsement. Each CLI owns its sign-in, network requests, model-provider processing, and results.

## Privacy and Soul

YumYum Agent sends no telemetry and does not read Keychain or CLI sign-in files. The first request passes only user-selected text, files, or captures to the selected CLI. Follow-up requests also include transcript text and context, but local attachment paths are excluded from visible transcript text. The CLI may use the network according to its own configuration. Soul is stored in plaintext at `~/Library/Application Support/YumYum/SOUL.md` and is injected into the first prompt of a new logical session below safety policies in priority.

The public app identity is `io.github.kyu91.yumyumagent`. On its first launch after this migration is introduced, YumYum Agent checks the `kr.yumyum.phase0` preview preferences once and copies only its language, theme, shortcut, and selected-agent preferences when the corresponding new preference is absent. It does not check again on later launches, delete the preview preferences, or migrate Soul, credentials, paths outside the selected-agent preference, or macOS privacy permissions.

See [Privacy](PRIVACY.md) and the [Soul format](docs/soul-format.md).

The default English product reference is the [product specification](docs/product-spec.md). The [preserved Korean specification](YumYum-Agent-Product-Spec.ko.md) is the complete target-state source and does not override current source, tests, or this README.

## Safety boundaries and limitations

- Current connectors are analysis-only. External-change UI and execution wiring are not implemented.
- Local builds and **Unsigned Preview** DMGs are not signed or notarized. No App Store build or automatic updates are provided.
- Real model responses depend on the external CLI installation, sign-in, network, and provider state.
- Screen capture supports rectangular selection only. The global shortcut may require macOS privacy permission.
- Regular `YumYum-Capture-*` files left by abnormal termination are cleaned up at the next app launch on a best-effort basis.

## Manual localization verification

- In **General**, confirm `settings-language-picker` exposes `English` and `한국어`.
- Switch languages while settings, Soul drafts, agent state, chat, attachments, and panels are populated; labels must update without relaunch and state or scroll position must not reset.
- Quit and relaunch to confirm the explicit language choice persists.
- With no stored choice, verify Korean is selected only when the first resolved macOS preferred language is Korean; all other cases use English.

## Contributing

- [Contributing guide](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Changelog](CHANGELOG.md)
- [Release status](docs/release.md)

## License

[Apache License 2.0](LICENSE)
