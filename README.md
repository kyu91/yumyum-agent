# YumYum Agent

[English](README.md) *(current)* | [한국어](README.ko.md)

YumYum Agent is a Swift/AppKit macOS app that lets you “feed” a selected screen area or local file to a floating pet and read responses from an installed local CLI agent in native bubbles and chat.

> **Unsigned developer preview:** the [latest Unsigned Preview release](https://github.com/kyu91/yumyum-agent/releases/latest) is available as a public prerelease. It is **not Developer ID signed or Apple notarized**.

## Features

- One validated flow for staging the clipboard into chat drafts, screen captures, file selection, Finder drops, and chat input
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

This **Unsigned Preview** is not Developer ID signed or Apple notarized. Download it only from the [official releases page](https://github.com/kyu91/yumyum-agent/releases/latest).

1. Download `YumYum-Agent-<version>-macOS.dmg`.
2. Open the DMG.
3. Drag **YumYum.app** to **Applications**.
4. Launch **YumYum.app** once. If macOS blocks it, acknowledge or close the warning.
5. Open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway**.
6. Authenticate if prompted, then confirm **Open**.

Button names and warning text can vary by macOS version. macOS may also request Screen Recording, Input Monitoring, or Accessibility permission for app features. Clean-machine Gatekeeper behavior and Intel hardware execution remain unverified even though both architecture slices are present.

### Optional: verify the SHA-256 checksum (recommended)

Download both `YumYum-Agent-<version>-macOS.dmg` and `YumYum-Agent-<version>-macOS.dmg.sha256` to **Downloads**, or place both files in the same folder. If they are in Downloads, run:

```sh
cd ~/Downloads && shasum -a 256 -c YumYum-Agent-<version>-macOS.dmg.sha256
```

Local developers can explicitly create and verify an unsigned DMG:

```sh
./scripts/package-release.sh --unsigned
./scripts/test-release.sh .build/release/YumYum-Agent-<version>-macOS.dmg
```

## Build and run from source

```sh
swift build
swift test
./scripts/build-app.sh
open ".build/YumYum.app"
```

The script creates a local release `.build/YumYum.app` by default. Use `CONFIGURATION=debug ./scripts/build-app.sh` for a debug bundle.

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
2. Open **Settings → Agent**, choose an agent to connect, then use **Find and register**. YumYum checks safe default locations, verifies its local command contract, and selects it as the default when ready. If it is not found, use **Install guide**; use **Choose directly** only when the executable is elsewhere. Codex must be signed in before it can become the default.
3. If needed, grant Screen Recording, Input Monitoring, or Accessibility permission in macOS Settings.
4. Right-click the pet or press `Control+Option+Space` to open the action bubble; left-click the pet to toggle the compact response bubble — the first click stages the clipboard into the chat draft, preferring files, then an image, then text, and opens the bubble with its inline composer ready, while a click while it is open just hides it (the draft stays put) and the next click reopens it without re-reading the clipboard. Add any instruction, then press Return to send the staged clipboard content and instruction together. This is a mouse-only gesture; there is no action-bubble or keyboard equivalent.

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
- In **Soul**, confirm `soul-response-style` exposes Urgent/Normal/Relaxed in English and 급함/보통/느긋함 in Korean, defaults to Normal, and VoiceOver explains that it changes response directness, context, and detail rather than processing speed.
- Switch to Korean mid-conversation and send a follow-up without resetting the session; confirm the agent's reply comes back in Korean. Switch back to English and confirm the next reply is English.
- Quit and relaunch to confirm the explicit language choice persists.
- With no stored choice, verify Korean is selected only when the first resolved macOS preferred language is Korean; all other cases use English.

## Manual pet interaction verification

- Confirm left-drag still moves the pet without staging the clipboard, while right-click never moves the window; right-click opens the action bubble and left-click shows the compact response bubble with the clipboard staged in the chat draft without sending until Return. Staged images show a thumbnail with a remove control. Clicking the pet again while the bubble is open hides it without touching the draft; clicking once more reopens it showing the same staged content instead of reading the clipboard again.

## Manual agent setup verification

- **Agent** always shows `agent-setup-card` at the top with an agent picker, **Find and register**, and **Install guide**, so more agents can be registered even after one is already selected; **Hidden agents** appears there too whenever a previously removed agent is available to restore.
- Each agent row shows its **Install guide**, including available installations.
- Finding a valid supported agent verifies it locally and selects it as the default; Codex remains unselected until its ChatGPT sign-in succeeds.
- Removing an agent hides it from YumYum without deleting its executable; restore it from the **Hidden agents** menu or by finding and registering it again.
- Remove two agents, register one again with **Find and register**, and confirm the other remains under **Hidden agents** and can be restored from there.

## Contributing

- [Contributing guide](CONTRIBUTING.md)
- [Security policy](SECURITY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Changelog](CHANGELOG.md)
- [Release status](docs/release.md)

## License

[Apache License 2.0](LICENSE)
