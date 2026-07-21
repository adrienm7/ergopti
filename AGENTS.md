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

**Start here:** `windows-toolchain` (the shell will corrupt files if you let it)
and `verify-change` (a green suite is not evidence unless it covers what you
changed).

| Skill | Read it when |
| --- | --- |
| `windows-toolchain` | Before scripting anything, and before every commit — shell, git and Node traps on this box |
| `verify-change` | After ANY edit and before every commit — which gates cover what you touched |
| `ship-fix` | Fixing any bug — root cause, regression test, local gate, commit |
| `commit-and-push` | Before any commit or push — commit format, linear history, CI monitoring |
| `ahk-driver` | Writing or editing `.ahk` files — the AutoHotkey v2 foot-guns that have bitten us |
| `hammerspoon-driver` | Writing or editing macOS `.lua` files — the Hammerspoon foot-guns, several of which fail silently |
| `linux-driver` | Working on the Linux driver — evdev, the grab/observe decision, ydotool, kanata |
| `meta-test` | Adding a test that scans driver source instead of calling a function |
| `false-green-tests` | Auditing the suite, or whenever a test passes and you are not sure it could ever fail |
| `perf-profiling` | Before proposing any performance change — where the logs are and how to read them |
| `cross-driver-parity` | Changing anything that exists on more than one driver (Windows / macOS / Linux / JS) |
| `adversarial-audit` | Auditing or hunting latent bugs — includes the evidence-verification rule |
| `orchestrate-pass` | Running a multi-agent pass — scouting, the rejected list, two-lens verification |
| `bulk-edit` | Rewriting a tracked file with a script instead of by hand |
| `retire-artifact` | Deleting a plan, report or archive without losing what it still carried |
| `i18n` | Touching any user-facing text |
| `logger` | Adding or reviewing log statements |
| `project-memory` | Before non-trivial work, and after learning something worth keeping |
