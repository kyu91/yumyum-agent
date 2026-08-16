# AGENTS.md

This document is a work instruction that applies to the entire repository.

## Project purpose and product safety principles

YumYum Agent is a Swift/AppKit app that "feeds" the user's selected screen area or local file to the macOS floating pet and displays the response of a verified local CLI agent (Hermes, OpenCode, Codex, Claude Code) as a native speech bubble and chat transcript.

- The user must explicitly approve the action of changing the external state separately from the task just before execution. Previous approvals, comprehensive approvals, and approvals from other Task·approval·toolsets cannot be reused.
- The current product does not execute external changes. `ExternalChangeToolsetPolicy` is a default rejection, and `TaskApprovalGate` only implements a one-time approval model in memory and is not connected to the UI and Connector execution flow.
- Codex sign-in, sign-out, and account switching are the separate account-lifecycle exception: Settings requires a fresh, operation-specific confirmation, then `CodexLoginService` revalidates the exact selected executable before invocation. This must not become an agent-proposed external-change permission path.
- `session/request_permission` of Hermes ACP always responds to `cancelled` at present. This behavior is not mitigated until the approved UI and Task scope verification are connected to the actual execution path.
- Input is only delivered to the data explicitly selected by the user and the agent. In the case of blank input, invalid attachment, cancellation, permission refusal, or agent not selected, no request is created or sent.

## Technology stack and structure

- macOS 14 or later, Swift tools 6.0, Swift Package Manager
- UI: SwiftUI app lifecycle + AppKit `NSPanel`/`NSWindow`/`NSOpenPanel`; screen capture is ScreenCaptureKit
- Concurrency and state: Swift Concurrency(`actor`, `Task`, `AsyncThrowingStream`), Combine `ObservableObject`
- Testing: Mainly Swift Testing (`@Test`, `#expect`), some XCTest
- There is no external package dependency.

Main route:

- `Package.swift`: `YumYumCore` library, `YumYum` app, `yumyum-probe`, `yumyum-process-fixture`, `YumYumCoreTests` definition
- `Sources/YumYumCore/`: UI independent policy, state machine, input validation, agent discovery, selection, and execution, process and ACP transmission
- `Sources/YumYumApp/`: App entry point, floating pet, action/chat panel, capture UI
- `Sources/YumYumProbe/`: A diagnostic CLI that only runs `--version` on the specified Hermes absolute path.
- `Sources/YumYumProcessFixture/`: Critical fixture for process, streaming, and termination testing
- `Tests/YumYumCoreTests/`: Core and App internal policy and integration boundary testing
- `AppBundle/Info.plist`: Local `.app` bundle metadata
- `scripts/build-app.sh`: Assemble the release/debug executable file and fixture into the `.app` structure.
- `README.md`: Current implementation, execution, and manual verification standards
- `docs/product-spec.md`: Default English product specification, including current implementation status and target roadmap
- `YumYum-Agent-Product-Spec.ko.md`: Preserved Korean target-state source; current behavior remains subordinate to source/tests and then README
- `.gitignore`: `.DS_Store`, `.build/`, `.swiftpm/`, `DerivedData/`, excluding Xcode user status only

## Core architecture and execution flow

### Entry point to the app and UI

`YumYumApplication` is the entry point for `@main`. At the beginning, organize the remaining `YumYum-Capture-*` general files to `CaptureTemporaryFileCleanup.removeStaleFiles()` and create `YumYumAppViewModel`. Assemble `YumYumAppDelegate` as a floating pet, a global shortcut, `QuickMenuPanelController`, and `FeedWorkflow`, and wait for `AgentRuntime.close()` before exiting.

A right-click on the pet opens the action speech bubble; it has no keyboard shortcut. A left-click on the pet toggles the compact response speech bubble: while it is hidden, a click stages the current system clipboard into the chat draft, preferring files, then images, then text, and shows the bubble with its inline composer expanded and focused; while it is visible, a click hides it without touching the draft, and the next click reopens it showing whatever is still staged rather than reading the clipboard again. Files go through the same `FeedValidator` path as a Finder drop. Nothing is sent until the user submits the draft, so the clipboard content and any typed instruction travel as one request; an empty or unsupported clipboard stages nothing and opens no bubble, and a click is a no-op while a draft is already staged and unsent. The compact bubble renders a scrollable multi-turn transcript (`ResponseBubbleViewController`), not just the latest reply; it persists across close/reopen and only clears when the user explicitly starts a new session from the detailed chat window. A global shortcut performs the same clipboard-feed toggle as left-click; it is user-recordable in Settings (`ShortcutRecorderField`/`ClipboardFeedShortcut`, requiring at least one of ⌃/⌥/⌘) rather than a fixed preset, defaults to ⌥S, and is stored under the UserDefaults key `"YumYum.ClipboardFeedShortcut"`. The pet itself still has no action-bubble row or VoiceOver-focusable control. The order of actions and state transfer are owned by `ActionBubbleAction` and `ActionFlowStateMachine`, and `QuickMenuPanelController` reflects the effect in the AppKit UI. The chat status is owned by `ChatBubbleState`, and the asynchronous transmission lifetime is owned by `ChatBubbleSession`. Simply hiding the panel does not cancel the transmission, and only explicit cancellation cancels `Task`.

`YumYumAppDelegate` runs the one-time `LegacyPreferencesMigration` before loading preferences and owns the clipboard-feed global shortcut, theme, and live English/Korean switching. Language or theme changes must update the existing panels without resetting chat state, drafts, attachments, or scroll position.

The global shortcut's `NSEvent.addGlobalMonitorForEvents` keyDown path needs both Accessibility and Input Monitoring permission (macOS 10.15+); screen capture separately needs Screen Recording. `PermissionOnboardingView` re-checks all three live (`CGPreflightScreenCaptureAccess`, `AXIsProcessTrusted`, `CGPreflightListenEventAccess`) every time the settings window's content view appears, and the sheet auto-opens whenever any one is still missing — it is not a one-time gate, and it reappears on later launches until the user grants everything or it is skipped for that session via "나중에 하기". The Settings shortcut section also has a "권한 확인" (Check Permissions) button to reopen it manually at any time.

### Input and response

Capture is performed by `ScreenCaptureCoordinator` displaying a selection overlay on all screens and calculating at least 8pt and pixel fragments per display with `CaptureRegionPolicy`. macOS 15.2 and later uses a single-area API, while macOS 14~15.1 uses capture and synthesis per display. Successful captures retain a temporary PNG and the original screen coordinates.

File selection and capture are combined with `FeedInput`. `FeedValidator` only allows general files with absolute paths, removes duplicates, applies a 20MB limit per file, supports extensions, and blocks certificate file names/extensions. `FeedWorkflow` serializes the sequence of verification → preview animation → `PromptRequest` creation → streaming transmission → completion/failure/cancellation feedback, and organizes the input status and temporary files at all termination paths.

The response arrives in the UI as a snapshot/delta/completed stream from `PromptResponseEvent`. `ChatBubbleState` updates the transcript and the current streaming response, while `AssistantMarkdownRenderer` renders ongoing incomplete Markdown and completed Markdown differently. User display errors prevent path, token, and raw stderr exposure by passing through `UserFacingErrorRedactor`.

`SoulProfileStore` owns the normalized plaintext `~/Library/Application Support/YumYum/SOUL.md`. `AgentRuntime` injects Soul only into the first prompt of a new logical session, while the response-language directive is attached freshly on every send so a live language switch applies to the next first or resumed prompt; a session reset waits for the latest Soul draft to save. Do not add external Soul imports, hooks, command syntax, or secret content.

### Agent discovery, selection, execution

`AgentDiscovery` only checks the direct executable file of the fixed candidate directory and the exact absolute path added by the user. For each candidate, the `--version` and agent-specific `--help` parameters are directly passed without a shell, and a 2-second timeout, a cumulative output limit of 64KB, and a minimum environment are applied.

`AgentRegistry` only stores the definition ID and the exact execution path in `UserDefaultsAgentSelectionStore`. It verifies the selection path again just before sending, does not automatically backtrack if the selection path becomes invalid, and only stores the definition ID and the exact execution path in `UserDefaultsAgentSelectionStore`.

The transmission route is as follows.

`FeedWorkflow` → `AgentRuntime` → `AgentRegistry.validatedSelection()` → Implementation of selected `AgentConnecting` → `ProcessRunner` or `ACPProcessTransport`

- Hermes: `HermesACPConnector` → Long-term connection `ACPProcessTransport` → `HermesACPProtocolClient`; Use `initialize`, `session/new`, `session/prompt` and cancel the authorization request.
- OpenCode: Structured `opencode run --pure --format json`; The confirmed attachment is forwarded as `--file`.
- Codex: structured `codex exec` with read-only sandbox and untrusted approval policy. Images use `--image`; confirmed non-image attachments are listed only as local paths in standard input. Codex requires a verified signed-in state before selection and transmission.
- Claude Code: structured print execution of plan permission mode. Its logical session ID is held for the current runtime, starts with `--session-id`, and follows up with `--resume`; cancellation, failure, selection change, reset, or shutdown discards it.

CLI starts with the exact execution URL and argv without going through the shell. The execution of general agents maintains a 120-second timeout and a combined stdout/stderr limit of 2MB. It preserves the reuse, reset after cancellation, and stale generation suppression behavior of Codex/Claude sessions.

## Development, build, test, execution

Run from the storage root.

```sh
swift build
swift test
./scripts/build-app.sh
open ".build/YumYum.app"
```

`scripts/build-app.sh` creates the default release bundle as `.build/YumYum.app`. The debug bundle is as follows.

```sh
CONFIGURATION=debug ./scripts/build-app.sh
```

Only use the full regression command in the README when the `Testing` module search path cannot be found in the independent Command Line Tools environment.

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

Version of the specified Hermes executable file probe:

```sh
swift run yumyum-probe --hermes /absolute/path/to/hermes
```

Probes and model responses that require the actual path and external CLI login/network status are not treated as automatic validation commands. Since there are no formatter or linter settings in the repository, no non-existent inspection commands are added.

## Code style and existing patterns

- It follows the import order of existing files, 4-space indentation, trailing comma, and line break style as they are.
- The public API is limited to `public`, and the implementation details are restricted to the internal type of `private`/file. Existing protocols (`ProcessRunning`, `AgentConnecting`, `FeedSubmitting`, `FeedFeedback`) and policy types are reused rather than new abstractions.
- UI and status changes are used for `@MainActor`, shared variable asynchronous status is used for `actor`, and synchronous locking wrappers are used for `@unchecked Sendable` only if necessary.
- Execution policies, layouts, and state transitions are left to Core's value types/state machines, while AppKit controllers focus on applying effects and calling frameworks.
- The process execution uses `ProcessCommand`/`ProcessRunner`. It does not add shell strings, `which`, arbitrary `PATH` navigation, or recursive search of the home directory.
- For user errors, do not directly display the raw `error.localizedDescription`, stderr, or local path, but use `UserFacingErrorRedactor`.
- The names of implementation and testing use English to describe the behavior. Comments are only used when there is a reason why the code alone does not reveal it.
- Does not add refactoring outside the scope of the request, new dependencies, deployment settings, or future abstractions.

## Testing and verification requirements

- Bug correction: First add the minimum test that reproduces the failure, then correct it and run the entire `swift test`.
- Function changes are verified with Swift Testing against Core policies/states. If they are connected to existing XCTest-based process regressions, the `PhaseZeroXCTests` pattern is maintained.
- Agent/process changes verify the correct executable URL, argv, minimum environment, timeout, output limit, unused shell, cancellation/forced termination, and stream drain.
- ACP changes verify initialization/session reuse, permission cancellation, cancellation notification, connection abandonment and reconnection after timeout, and stale event suppression.
- Codex authentication changes verify fresh confirmation/cancellation, exact executable revalidation, status, timeout, and no process launch after a cancelled or stale approval.
- Soul, localization, theme, and legacy preference migration changes verify latest-draft persistence before session reset, no duplicate Soul on follow-up, live UI-state preservation, and one-time migration behavior.
- Input/chat changes are verified to be sent exactly once, busy rejection, transcript context, attachment path exposure prevention, retry/cancel, and temporary file organization of all paths.
- Capture changes verify four-way drag, minimum area, negative/vertical screen coordinates, mixed scale, display boundary synthesis, and delayed callback suppression after cancellation.
- UI/accessibility changes are checked manually in the README and the relevant items are checked on the actual macOS. In particular, VoiceOver, Reduce Motion, multi-display, and focus levitation are not completed by unit testing alone.
- Minimum verification before completion:

```sh
swift test
git diff --check
git status --short --untracked-files=all
```

If you change the app bundle or package settings, `swift build` and `./scripts/build-app.sh` will also be executed.

## Precautions for each change area

- `ActionFlowPolicy`, `ChatBubbleState`, `ChatBubbleSession`: prevents stale generation/submission results from being mixed into the new UI. Preserves the current behavior of not automatically reopening actions/chats after cancellation, permission refusal, or failure, and only restoring pets.
- `FeedWorkflow`, `FeedValidator`: Do not create `PromptRequest` before verification. Do not weaken file restrictions, certificate blocking, deduplication, single transmission, or temporary capture organization.
- `AgentDiscovery`, `AgentSelection`: Re-verify the exact absolute path and local help contract. Even if the selected path disappears, it will not automatically switch to another installation.
- `AgentRuntime`, `StructuredCLIStreaming`: Only use the actual confirmed argv in each CLI. Do not abstract or add unconfirmed flags by adding the difference in attachment support.
- `SoulProfile`, `YumYumAppViewModel`: Preserve normalization, latest-draft-wins persistence, first-session-only injection, and save-before-reset behavior. Soul remains app-owned plaintext and must not accept secrets or executable directives.
- `CodexLoginService`, `AppLocalization`, `LegacyPreferencesMigration`: Keep authentication actions behind their own fresh confirmation and exact-path revalidation. Preserve live language/theme state and the one-time, known-key-only migration boundary.
- `PermissionOnboardingView`: Keep the auto-show gate computed fresh from live permission state on every appearance, not from a persisted "already shown" flag. Do not weaken the Screen Recording/Accessibility/Input Monitoring row checks, their System Settings deep links, or the "권한 확인" manual reopen path in Settings.
- `GlobalShortcutController`, `ClipboardFeedShortcut`, `ShortcutRecorderField`: The recorder must reject a combo with no modifier from ⌃/⌥/⌘ (Shift-only or bare key). Do not reintroduce a fixed-preset-only picker; preserve legacy raw-value migration in `ClipboardFeedShortcut.load(defaults:)` so existing users' saved shortcut still resolves.
- `HermesACPTransport`: ACP v1 JSON-RPC order, connection/session reuse, permission `cancelled`, 2MB budget reset, preserves process termination and reconnection to the next request in case of timeout/cancel.
- `ProcessRunner`: Continuously drain stdout/stderr at the same time and prevent child deadlock even after reaching the output limit. When timeout/cancel, terminate and kill if necessary. Even if a descendant grabs the pipe, it does not wait for the child to terminate directly.
- `ScreenCaptureCoordinator`, `CaptureRegionPolicy`: Maintains API branch by macOS version and AppKit/ScreenCaptureKit coordinate system conversion. Hides all YumYum Agent surfaces before capturing and keeps the source rect of the result as the starting point of the preview.
- `FloatingPetWindowController`, panel controller: Corrects the pet drag position and all speech bubbles within the display `visibleFrame`. Preserves the order of the action four rows, 248pt width, keyboard movement, and VoiceOver label; staged draft attachments stay removable from the response bubble and show a real image thumbnail when the file decodes. The compact bubble's transcript must keep surviving close/reopen and only clear on an explicit new session — do not make `prepareForTermination`/close paths reset `ChatBubbleState`.
- Markdown/Response UI: Hides incomplete delimiters while streaming and maintains block/inline style and original line breaks when completed. Both the compact bubble and the detailed chat window scroll their own transcript internally past a max height rather than growing the panel unbounded.
- `Package.swift`, `AppBundle`, `scripts/build-app.sh`: the fixture must be included in the app Resources. The current bundle is for local development and the signing, notarization, and sandbox distribution have not been verified.

## Security, personal information, certificate authentication, external side effects

- Do not put API keys, tokens, passwords, account information, and personal identification information in source, test fixture, documents, and logs.
- Does not read or copy Keychain, CLI login files, or token files. The existing authentication and network behavior of the executed CLI are the boundaries of that CLI.
- Do not send files, folders, symlinks, unsupported extensions, or blocked credential files that have not been selected.
- Does not expose the local absolute path, raw stderr, or string in the form of a token to the user display message and transcript. Only when the Connector requires a path input does it pass the user-selected path in the current request in a limited manner.
- To add external change tools or allow permission responses, the independent approval UI, Task/approval/toolset matching, one-time consume, cancellation/refusal path must be implemented and validated together. It cannot be made to run with only some of them implemented.
- Network calls, package additions, remote service linking, and telemetry are not added without the user's explicit request.

## Session continuity

Keep every result in the repository, not in the conversation. A conclusion that exists only in an agent's chat history is lost the moment that session ends. Write findings into source, tests, or a commit as you reach them.

When asked to hand off, write `docs/handoff.md`: current state, decisions already settled, and remaining work — written so the next session can continue from that file alone, not as a transcript summary. It is a scratch file; do not commit it.

## Git work rules

- Work in the current work tree and do not create a separate worktree.
- Check `git status --short --untracked-files=all` before and after the work and preserve the existing user changes.
- Only the minimum range directly connected to the requested file is modified. Irrelevant format changes, dead code deletion, and product commits are not made.
- `.build/`, `.swiftpm/`, `DerivedData/`, `.DS_Store`, do not commit Xcode user status.
- Irreversible operations (file deletion, forced push, history rewrite) require prior approval.
- Commits are created automatically once a change passes verification (build/tests, `git diff --check`), without asking first each time; this is a low-risk, local, reversible action. Pushes, branches, tags, and other remote changes still require explicit request.
- Before completing, check the `git diff --check` and the entire status, and report the failed verification with the reason.
