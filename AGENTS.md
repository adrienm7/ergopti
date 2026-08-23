# Shared repository contract

This is the small common startup context for Codex, Claude Code, GitHub
Copilot, Gemini CLI, and other repository agents. Keep detailed procedures in
skills and durable technical knowledge in routed memory.

## Safety

- Preserve unrelated working-tree and index changes. Stage exact owned paths;
  never use a broad add, stash, reset, clean, or worktree move as a shortcut.
- Treat registered sibling worktrees as active user state. Do not modify,
  delete, or relocate one unless the current request explicitly puts it in
  scope.
- Never push `dev` or `main` without explicit authorization in the current
  conversation. Commits and green tests do not imply push permission.
- Store text as LF on every OS. AutoHotkey source additionally keeps its
  UTF-8 BOM; use the repository encoding gate after touching it.

## Context routing

- Before non-trivial work, read [docs/memory/README.md](docs/memory/README.md),
  then only the topics it routes for the current surface.
- Reusable procedures live canonically in `.agents/skills/`. Select skills by
  their descriptions and load only matching `SKILL.md` bodies and references.
  `.claude/skills/` is a generated mirror; never edit it directly.
- Use the project launcher documented in
  [docs/tooling/rtk.md](docs/tooling/rtk.md) when command output is read by a
  human or LLM. Invoke the child directly when stdout feeds a pipe,
  redirection, parser, hash, generator, or test assertion. CI remains
  network-independent and can execute the child command unfiltered.
- A small, local, low-risk edit does not require a formal or persisted plan.
  Use a plan for multi-step, cross-driver, high-risk, or audit-campaign work.

## Delivery

- Write code, identifiers, developer documentation, logs, and commit messages
  in English. Route user-facing French text through the `i18n` skill.
- Treat the strict convention lint as authoritative for indentation, file
  headers, section banners, documentation, and punctuation. Comments explain
  why; public APIs use the language's established documentation format.
- Keep one source of truth for defaults and shared constants. Fail fast on
  invalid state or external failure; do not add magic values, silent fallbacks,
  compatibility shims, or success paths that hide an error.
- Stateful modules have explicit initialization ownership and reject invalid or
  duplicate initialization. Use the central logger and pair lifecycle messages.
- Fix root causes and add a regression test that can fail for the original bug.
  Use `verify-change` to select proportional gates before each commit.
- Change generated artifacts through their owner and regenerate them; do not
  hand-edit generated output.
- Keep local commits atomic and use English Conventional Commit subjects.
