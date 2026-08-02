# Contributing

YumYum targets macOS 14 or later and Swift tools 6.0. Read [AGENTS.md](AGENTS.md) before working; its safety, architecture, and verification rules apply repository-wide.

## Development workflow

1. Make the smallest change required for one purpose. Do not bundle new dependencies, unrelated refactors, or external-change features.
2. Never add API keys, tokens, sign-in files, personal data, real user paths, or captures to source, fixtures, or logs.
3. Record evidence from the installed CLI's `--version` and relevant `--help` output plus exact executable URL and argv for CLI contract changes. Do not add shell execution, `which`, or arbitrary PATH search.
4. Add a reproduction test first for bug fixes and Core policy or state tests for behavior changes.
5. Describe the reason, security/privacy/external-change impact, exact verification, and unperformed manual checks in the PR.

## Automated verification

```sh
swift build
swift test
./scripts/build-app.sh
git diff --check
git status --short --untracked-files=all
```

Only if `swift test` fails because standalone Command Line Tools cannot find `Testing`, use the complete fallback command in [README](README.md#build-and-run-from-source). It cannot excuse other failures. External CLI probes, sign-in, networking, and model responses are not automated verification.

## Manual UI checks

For relevant UI changes, verify on macOS: VoiceOver labels and order, Reduce Motion, no focus stealing, multi-display and mixed-scale capture, denied screen permission, multiple Finder drops, `visibleFrame` clamping, language switching with PID and state preservation, and theme/contrast/transparency state preservation.

## Security issues

Do not disclose sensitive vulnerabilities in public issues or PRs; follow [SECURITY.md](SECURITY.md). Contributions are governed by the [Code of Conduct](CODE_OF_CONDUCT.md) and [Apache License 2.0](LICENSE).
