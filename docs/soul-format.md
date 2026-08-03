# YumYum Agent Soul format

YumYum Agent owns `~/Library/Application Support/YumYum/SOUL.md`. The app does not currently import external Soul files; [examples](../Examples/Souls/) are reference material only.

## Grammar

The file begins with exactly `# YumYum Soul`, a blank line, and the fixed safety statement. Only nonempty fields may follow, in this order:

1. `Name`
2. `Role / Identity`
3. `Personality`
4. `Speaking Style`
5. `Core Values`
6. `Likes`
7. `Dislikes / Avoidances`
8. `User Form of Address`
9. `Behavior Principles`
10. `Additional Instructions`
11. `Response Style`

After normalization, each free-text field is limited to 2,000 characters and all free-text fields together to 12,000 characters in field order. `Response Style` is one of the app-owned canonical instructions for Urgent, Normal, or Relaxed; Normal is the default when the heading is absent so existing files remain valid. CRLF becomes LF and consecutive inline whitespace becomes one space. Body lines beginning with `## ` or `\` are escaped with `\` when saved. Unknown, duplicate, or out-of-order headings; invalid prefixes; non-normalized content; and oversized files fail closed to an empty profile.

Soul applies only to the first prompt of a new logical session and is subordinate to YumYum Agent safety, privacy, approval, attachment, and external-change policies. Response Style controls directness, context, and detail, not processing speed. It has no hooks, includes, environment expansion, network access, or command execution syntax. Do not include secrets, credentials, or sensitive personal data.
