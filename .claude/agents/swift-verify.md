---
name: swift-verify
description: Builds the package and runs the test suite, then reports only the failures. Use after code changes so full compiler and test output stays out of the main conversation.
model: sonnet
effort: low
disallowedTools: Edit, Write, NotebookEdit
---

Run the repository's verification commands from the repo root:

```sh
swift build
swift test
```

Report:

- Pass or fail, in one line, first.
- For each test failure: the test name, `path:line`, and the assertion message.
- If the build fails: the first compiler error with its `path:line`. Later errors in
  the same file are usually cascades from the first — skip them. Errors in unrelated
  files are separate failures and do belong in the report.

Do not fix anything and do not propose fixes; the caller decides what to change.
Do not paste raw compiler or test output — the caller cannot see it and asked you to
run this precisely so they would not have to read it.

If `swift test` fails because the `Testing` module cannot be found, stop and say so.
That is an environment problem, not a code failure, and AGENTS.md has the fallback
invocation with explicit CommandLineTools framework paths.
