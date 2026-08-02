# YumYum Agent product specification

## Document and evidence control

This is the default English public product specification. It separates verified current behavior from target requirements. For current behavior, evidence precedence is: source and tests, then [`README.md`](../README.md), then this document. The complete preserved Korean target-state source is [`YumYum-Agent-Product-Spec.ko.md`](../YumYum-Agent-Product-Spec.ko.md); a target there is not current unless source and tests implement it.

## Product definition

YumYum Agent is a native macOS floating pet that sends user-selected screen regions or local files to an explicitly selected, verified local CLI agent and presents the streamed response in native speech bubbles and chat.

## Current implementation status

| Status | Scope |
|---|---|
| Implemented | Movable always-on-top pet; four-action quick menu; rectangular multi-display capture; multi-file picker and Finder file drop; one active request with busy rejection; streamed response bubble and shared chat transcript; follow-up, cancel, and retry; Hermes, OpenCode, Codex, and Claude Code discovery, explicit selection, and execution; editable app-owned Soul; live English/Korean switching; Light/Dark appearance; release packaging, GitHub workflow, signing, and notarization logic. |
| Partial | External-change policy and an in-memory one-time approval model exist, but no approval UI or connector execution wiring exists. Finder drop policy is automated, while actual Finder dispatch and hit testing remain manual checks. Capture cleanup after abnormal termination is best effort. |
| Not implemented | External state changes, approval execution UI, calendar actions, folders, clipboard paste, URL input, OCR, active-window accessibility context, masking preview/confirmation, FIFO queue, persistent history, answer copy, login item, App Store distribution, automatic updates, and verified Intel support. |

## Product principles

- Be present without interrupting the user's current app or stealing focus.
- Process only material the user explicitly selects.
- Keep YumYum Agent an interface to existing agents, not another model, tool runtime, or credential store.
- Make agent selection and data scope explicit; never silently fall back to another installation.
- Default deny external changes and protect credentials, paths, stderr, and tokens.
- Prefer native, lightweight macOS behavior and keep character motion subordinate to function and accessibility.

## Current user journeys

### First use and agent selection

1. The user installs and signs in to a supported CLI outside YumYum Agent.
2. YumYum Agent discovers only direct executables in fixed candidate directories or an exact absolute path supplied by the user.
3. Discovery runs the executable directly, without a shell, against bounded `--version` and agent-specific `--help` contracts.
4. The user explicitly selects one validated executable in **Settings → Agent**. YumYum Agent stores only its definition ID and exact path.
5. If that path later becomes invalid, sending stops and explicit reselection is required; YumYum Agent does not fall back.

### Quick capture

1. The user clicks the pet or presses `Control+Option+Space` and chooses **Capture**.
2. YumYum Agent hides its surfaces and shows selection overlays on all displays.
3. The user drags a rectangle at least 8 pt wide and high, or cancels.
4. A successful selection becomes a temporary PNG and is sent immediately as one input after validation and preview motion.
5. The pet shows thinking motion and a streaming response; completion opens a response bubble and retains the full exchange in chat.

### Choose or drop files

1. **Choose Files** opens a multi-select file panel; dropping multiple Finder files on the pet uses the same validator.
2. One selection or drop batch becomes one input, deduplicated in selection order, and sends immediately.
3. Invalid or wholly rejected input sends nothing. Folders and aliases are not expanded.

### Chat and follow-up

1. **Open Chat** shows the shared transcript, draft, pending attachments, and send controls.
2. Chat capture and file selection attach to the draft without sending; Return or **Send** submits explicitly.
3. A follow-up includes visible transcript context and the current turn. Local attachment paths are not placed in visible transcript text.
4. Hiding a panel does not cancel an active request. Only explicit cancel stops it; eligible failures can be retried.

Cancellation, denied permission, empty text with no attachment, invalid attachments, no selected agent, or an already-busy workflow creates or sends no new request.

## Supported local agents and connector boundaries

| Agent | Current connector contract | Attachment boundary |
|---|---|---|
| Hermes | Long-lived `hermes acp`, ACP v1 `initialize` / `session/new` / `session/prompt`; permission requests return `cancelled` | Validated prompt content and supported file blocks |
| OpenCode | `opencode run --pure --format json` | Validated attachments via `--file` |
| Codex | `codex exec` with read-only sandbox and untrusted approval policy | Images only via `--image` |
| Claude Code | Structured print execution, plan permission mode, non-persistent process sessions | Prompt contract only; no invented attachment flags |

All processes use the exact executable URL and argv without a shell. General connector runs have a 120-second timeout and a combined 2 MB stdout/stderr limit. Each CLI owns authentication, network access, model-provider processing, and response quality; YumYum Agent does not read its login files or tokens.

## Input, attachment, and capture constraints

- Current inputs are typed text, explicitly selected rectangular captures, and explicitly selected regular local files.
- Files must use absolute paths, be readable regular files, and be no larger than 20 MB each.
- Duplicate paths are removed. Folders, symlinks, aliases, unsupported extensions, known credential names/extensions, and invalid inputs are rejected.
- Capture spans multiple displays, including mixed scale and negative coordinates. macOS 15.2 or later uses the single-area path; macOS 14 through 15.1 captures display fragments and composites them.
- Temporary capture PNGs are removed on completion, cancellation, and failure; stale regular `YumYum-Capture-*` files receive best-effort cleanup at next launch.
- Folder traversal, clipboard input, URLs, OCR, masking previews, and active-window context are roadmap items, not current behavior.

## Chat and session behavior

The response stream carries snapshot, delta, and completion events. The UI keeps one shared transcript plus the current streaming response, renders incomplete Markdown defensively, and renders completed Markdown with its final structure and line breaks. Long responses scroll inside the document surface.

Hermes keeps an ACP connection and logical session while valid. Codex and Claude preserve their verified logical-session behavior across follow-ups. Cancellation, timeout, or invalid session state resets the affected connector as required, and generation checks suppress late events from stale requests. A new logical session receives Soul once; ordinary follow-ups do not duplicate it.

## Soul behavior

YumYum Agent owns the plaintext file `~/Library/Application Support/YumYum/SOUL.md`. Settings edit a fixed, bounded profile format for name, user address, role/identity, personality, speaking style, and dislikes/avoidances. On save, whitespace is normalized; each field is limited to 2,000 characters and the complete profile to 12,000 characters.

Soul is injected only into the first prompt of a new logical session and has lower priority than safety, privacy, approval, attachment, and external-change policy. It has no hooks, includes, environment expansion, network access, or command execution syntax. External Soul import is not implemented. See the [Soul format](soul-format.md).

## Localization behavior

The interface supports English and Korean. The language selector displays `English` and `한국어`, applies changes immediately without relaunch or state reset, and persists the explicit choice. With no stored choice, Korean is selected only when the first resolved macOS preferred language is Korean; otherwise English is used. Product names, CLI names, paths, argv, code, and protocol values remain unchanged.

## Privacy, security, and external changes

- YumYum Agent sends no telemetry and does not read Keychain, CLI login files, or token files.
- Only the selected input, necessary conversation context, and Soul at the defined session boundary are passed to the selected local CLI. That CLI may use the network under its own configuration.
- Known credentials are blocked. User-facing errors and transcript content redact local paths, token-like strings, and raw stderr.
- `ExternalChangeToolsetPolicy` denies external-change toolsets by default. `TaskApprovalGate` is only an in-memory one-time model and is not connected to UI or connector execution.
- Hermes `session/request_permission` always returns `cancelled`. Current connectors are analysis-only and cannot perform YumYum Agent-authorized external changes.
- Any future external change requires a separate execution-time approval bound to the exact task, approval, and toolset, consumed once. Previous, blanket, or cross-task approval must never be reused.

## Current architecture and main paths

`FeedWorkflow` → `AgentRuntime` → `AgentRegistry.validatedSelection()` → selected `AgentConnecting` implementation → `ProcessRunner` or `ACPProcessTransport`

- `Package.swift`: Swift 6 package, macOS 14 minimum, core library, app, probe, process fixture, and tests.
- `Sources/YumYumCore/`: policies, validation, state machines, discovery/selection, connectors, process/ACP transport, Soul, and localization.
- `Sources/YumYumApp/`: SwiftUI lifecycle with AppKit pet, panels, file picker, and ScreenCaptureKit UI.
- `Sources/YumYumProbe/`: bounded `hermes --version` diagnostic for an explicit absolute path.
- `Sources/YumYumProcessFixture/`: deterministic process and termination fixture.
- `Tests/YumYumCoreTests/`: policy, state, connector, capture, process, and integration-boundary tests.
- `AppBundle/Info.plist`, `scripts/build-app.sh`, `scripts/package-release.sh`, `scripts/verify-release.sh`, and `.github/workflows/release.yml`: bundle metadata, Universal app/UDZO DMG packaging, verification, signing/notarization logic, and tag release automation.

## Platform and performance status

Verified facts: the package requires macOS 14 or later and Swift tools 6.0; the app is native SwiftUI/AppKit/ScreenCaptureKit with no external package dependency; the permanent bundle ID is `io.github.kyu91.yumyumagent`; release packaging, workflow, signing, and notarization logic are implemented; and a local unsigned Universal compressed read-only UDZO DMG has been built, checksum-checked, mounted, and architecture-verified. Actual Developer ID signing/notarization, GitHub publication, Intel hardware execution, Gatekeeper assessment, and clean-machine verification remain unverified and block a public release. App Store distribution and automatic updates remain separate future work.

Targets, not verified guarantees: primary validation across macOS 14, 15, and 26 on Apple Silicon; idle CPU near 0%; idle memory approximately 30–70 MB; no YumYum Agent telemetry or idle network; capture, OCR, and vision work only on demand; low-frequency or static idle animation; first UI feedback within 100 ms; capture preview within 300 ms; streaming visible when the connector supports it; cancellation feedback within 200 ms; no focus theft; stable 8-hour operation. These targets require measured release evidence before being claimed as achieved.

## Acceptance gates

### Automated current gate

Run from the repository root:

```sh
swift test
git diff --check
git status --short --untracked-files=all
```

Tests cover policy and state transitions, exact CLI executable/argv contracts, discovery limits, no-shell execution, output and timeout limits, cancellation/termination and stream draining, ACP ordering/session reuse/permission cancellation/reconnection/stale suppression, input validation and single-send behavior, transcript/path redaction, Soul/session boundaries, localization, multi-display capture geometry, and temporary-file cleanup paths.

### Manual current gate

On real supported macOS hardware, verify pet drag and visible-frame containment, keyboard navigation and VoiceOver labels, no unexpected focus theft, Reduce Motion, Light/Dark appearance, capture permission and cancellation, mixed-scale multi-display capture, actual Finder drop dispatch/hit testing, global shortcut behavior, live language switching and persistence, file-panel behavior, long-response scrolling, and supported CLIs using real installed paths and their own sign-in/network state.

The implemented release scripts do not constitute evidence of actual Developer ID signing/notarization. A signed/notarized artifact, GitHub publication, Intel hardware execution, Gatekeeper assessment, and clean-machine verification remain blocking release gates. App Store delivery and automatic updates are distinct future distribution work.

## Target roadmap

Roadmap categories, all non-current unless promoted by source and tests:

1. **Broader explicit input:** clipboard text/images, folders with local enumeration and exclusions, URLs, OCR, active-window accessibility context, scope preview, and privacy masking.
2. **Work management:** `FoodItem` / `Meal` / `Task` lifecycle, FIFO queue, persistent user-controlled history, copy/export, and richer recovery.
3. **External actions:** calendar proposal as the first target, exact execution-time approval UI, task/toolset matching, one-time consumption, refusal/cancellation, and auditable result states.
4. **Productization:** onboarding, permission guidance, login item, performance measurement, accessibility completion, signing, hardened runtime, notarization, distribution packaging, and update strategy.
5. **Later extensions:** additional verified connectors, optional Hermes Desktop integration, routing, long-term screen memory, proactive suggestions, and pet customization.

The roadmap does not authorize background capture, credential access, unapproved external changes, silent agent fallback, or expansion of the current data scope.
