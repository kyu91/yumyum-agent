# Open-source readiness checklist

- [ ] Confirm ownership and publication rights for source, documentation, and assets.
- [ ] Decide trademark registration, use, and contributor-use policy for the YumYum Agent name and logo.
- [ ] Scan the complete Git history for secrets and retain results.
  - `gitleaks` and `trufflehog` are unavailable locally, so this is not yet done.
- [ ] Decide whether to publish a clean snapshot or complete history.
- [ ] Verify redaction of user data, paths, notifications, and account names in screenshots, videos, and fixtures.
- [ ] Configure repository description, default branch, license detection, and topics.
- [ ] Configure branch protection/rulesets, required CI, review count, and force-push/deletion restrictions.
- [ ] Enable GitHub Private Vulnerability Reporting and verify the SECURITY.md flow.
- [ ] Configure a private Code of Conduct reporting channel before removing its publication blocker.
- [ ] Verify issue/PR templates, disabled blank issues, and Code of Conduct enforcement.
- [ ] Decide whether and with what permissions to enable Dependabot, CodeQL, or other GitHub features.
- [x] Implement explicit unsigned DMG packaging, checksum, tag-only signing/notarization automation, and architecture checks.
- [ ] Run the signed/notarized workflow with real credentials and verify the published artifacts.
- [x] Set the permanent bundle ID to `io.github.kyu91.yumyumagent`.
- [ ] Decide certificate ownership/custody and configure GitHub signing secrets.
- [ ] Verify clean-machine TCC, installation, Intel execution, VoiceOver, and Reduce Motion; define rollback policy.

No `NOTICE` is currently included because no separate third-party attribution requirement has been identified. Vendor names are used only to describe CLI compatibility; vendor logos are not included.
