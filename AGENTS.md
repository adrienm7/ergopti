<!-- AGENTS.md -->

# Codex Project Instructions

## Release Branch Safety

Never run `git push` against `dev` or `main` unless the user explicitly asks
to push that branch in the current conversation. Do not infer permission from
an earlier commit, a successful test run, or a general request to work
autonomously. A push to either branch triggers CI and a release, so commits
must remain local until that explicit approval is received.

## Shared Project Rules

Read and follow [.github/copilot-instructions.md](.github/copilot-instructions.md)
and [docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md) before non-trivial work.

## Skills

Reusable procedures for recurring tasks live at `.claude/skills/<name>/SKILL.md`.
They are plain Markdown with a YAML header — the header is inert for tools that
do not consume it, so read the file directly when the situation matches. They
hold procedure only, and link back to the two documents above rather than
restating their rules.

| Skill | Read it when |
| --- | --- |
| `ship-fix` | Fixing any bug — root cause, regression test, local gate, commit |
| `commit-and-push` | Before any commit or push — commit format, linear history, CI monitoring |
| `ahk-driver` | Writing or editing `.ahk` files — the AutoHotkey v2 foot-guns that have bitten us |
| `meta-test` | Adding a test that scans driver source instead of calling a function |
| `cross-driver-parity` | Changing anything that exists on more than one driver (Windows / macOS / Linux / JS) |
| `adversarial-audit` | Auditing or hunting latent bugs — includes the evidence-verification rule |
| `i18n` | Touching any user-facing text |
| `logger` | Adding or reviewing log statements |
| `project-memory` | Before non-trivial work, and after learning something worth keeping |
