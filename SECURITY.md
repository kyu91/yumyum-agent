# Security Policy

## Reporting a vulnerability

When the GitHub repository is public and **Private Vulnerability Reporting** is enabled, use **Security → Report a vulnerability**. This project currently has only a local repository, so no private reporting channel has been published. Do not post sensitive details in a public issue.

Do not include tokens, credentials, personal information, absolute local paths, raw logs or stderr, selected files, or captures in public issues. If reproduction requires sensitive information, wait until a private reporting channel is available.

## Scope and boundaries

YumYum input validation, process execution, temporary files, permissions, path exposure, and external-change boundaries are in scope. Report vulnerabilities in Hermes, OpenCode, Codex, or Claude Code installation, authentication, networking, or model-provider behavior to the relevant upstream project. Vendor names describe compatibility and do not imply sponsorship or endorsement.

Current connectors do not execute external changes, and Hermes ACP permission requests are cancelled. Any bypass of this boundary is a security vulnerability.
