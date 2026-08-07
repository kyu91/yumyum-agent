# Changelog

All notable changes to this project will be documented here.

## [Unreleased]

## [0.4.0]

- Make agent chat replies follow the app's language setting instead of only the UI chrome.
- Feed the pet by left-clicking it: stages clipboard text, an image, or a file into the chat draft (or drag a file onto it) and opens a compact reply bubble with an image thumbnail and a remove control; nothing sends until you add an instruction and press Return, and clicking the pet again closes the bubble without discarding what's staged.
- Fix hidden agents becoming permanently unrestorable after registering a different removed agent back.
- Fix the agent process PATH to resolve interpreters installed under either Homebrew prefix.

## [0.3.0]

- Show the connected agent as a headband icon on the floating pet.
- Streamline agent discovery and registration; declutter the agent settings list.
- Add a terminal launcher for Codex/Claude Code sign-in.
- Fix the agent process environment to include `USER`/`LOGNAME`.

## [0.2.0]

- Add live Settings theme updates and Soul response styles with save-before-reset behavior.
- Make the quick menu adapt its intrinsic width and alignment to the pet's display position.
- Add explicit Codex ChatGPT sign-in, sign-out, account switching, and readiness handling.

## [0.1.1]

- Redesign the YumYum mascot and app branding.
- Add GUI-first unsigned preview installation instructions and optional SHA-256 verification guidance.
- Add explicit unsigned DMG packaging and verification plus a tag-only Developer ID signing, notarization, checksum, and GitHub Releases workflow.

## [0.1.0]

- Developer preview of the native macOS floating pet, capture, file, Finder drop, and chat flows.
- Local CLI compatibility for Hermes ACP, OpenCode, Codex, and Claude Code with validated executable paths and help contracts.
- Streaming responses, transcript continuity, Soul profiles, input validation, temporary capture cleanup, and default-deny external-change boundaries.
- Unsigned, unnotarized developer prerelease published with a Universal DMG and SHA-256 checksum; clean-machine Gatekeeper and Intel hardware execution remain unverified.
