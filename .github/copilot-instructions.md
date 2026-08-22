# Ergopti repository instructions

`AGENTS.md` is the common contract for Codex, Claude Code, GitHub Copilot,
Gemini CLI, and other coding agents. Keep this file limited to rules that apply
to nearly every Copilot task; detailed procedures live in agent skills.

## Universal code rules

- Write code, identifiers, developer comments, docstrings, logs, and commit
  messages in English. User-facing UI text is French and follows the `i18n`
  skill rather than being hardcoded.
- Preserve the repository's tab indentation, file-path header, section-banner,
  documentation, and punctuation conventions. The strict convention lint is
  authoritative; do not reproduce its formatting rules from memory.
- Keep one source of truth for defaults and shared constants. Do not introduce
  magic values, compatibility shims, unused fallbacks, or hardcoded behavioral
  fallbacks.
- Fail fast on invalid state and external failures. Never swallow an exception
  or claim success after an operation failed.
- Comments explain why a decision exists. Public APIs use the language's
  established documentation format.
- Stateful modules keep explicit initialization ownership, reject duplicate
  initialization, and guard public operations before their dependencies exist.
- Use the central logger. Lifecycle messages are paired; load the `logger`
  skill before adding or reviewing logs.
- Every bug fix includes a regression test that fails for the root cause before
  the fix and passes afterwards.

## Context routing

Read `docs/PROJECT_MEMORY.md`, then only the topic files relevant to the task.
Load detailed procedures through the skills listed in `AGENTS.md`; do not load
the entire skill catalog or project-memory directory.

In particular, route work by surface:

- Windows AutoHotkey: `windows-toolchain` and `ahk-driver`.
- macOS Hammerspoon/Lua: `hammerspoon-driver`.
- Linux driver: `linux-driver`.
- Shared behavior across drivers: `cross-driver-parity`.
- User-facing text: `i18n`.
- Tests or validation: `verify-change`; source-scanning tests also use
  `meta-test`.
- Commits or pushes: `commit-and-push`.

## Validation and Git safety

- Preserve unrelated working-tree changes and stage exact paths only.
- After any edit, use `verify-change` to select the gates that cover it. A green
  unrelated suite is not evidence.
- Use Conventional Commits in English, without co-author trailers.
- Never push `dev` or `main` without explicit authorization in the current
  conversation. A successful commit or test run is not push authorization.
