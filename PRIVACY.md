# Privacy

## Data processed

YumYum passes explicitly entered or selected chat text, local files, Finder drops, screen captures, and transcript context to the selected local CLI. Empty input, invalid attachments, cancellation, denied permission, or no selected agent never creates or sends a request.

The selected CLI definition ID and exact executable path, language, theme, and shortcut preferences are stored in macOS `UserDefaults`. Soul settings are stored atomically in plaintext at `~/Library/Application Support/YumYum/SOUL.md`. Do not put secrets, credentials, or sensitive personal data in Soul.

## Network and external CLIs

YumYum sends no telemetry or analytics. The selected Hermes, OpenCode, Codex, or Claude Code CLI may use its existing sign-in and configuration to send data to a network or model provider. Review that CLI's and provider's privacy policies separately.

YumYum does not read or copy Keychain, CLI sign-in files, or token files. Known credential names and extensions are blocked from attachments, but users remain responsible for reviewing file contents before sending.

## Temporary captures and deletion

Captures are regular `YumYum-Capture-*.png` files in the system temporary directory. YumYum attempts to remove them after completion, failure, cancellation, and draft removal, and retries cleanup for regular files with the same prefix at launch. Deletion is best effort and cannot be guaranteed immediately after crashes, conflicts, or permission failures.

Resetting Soul saves an empty profile after confirmation. YumYum does not delete other user-selected files or data retained by external CLIs or model providers.
