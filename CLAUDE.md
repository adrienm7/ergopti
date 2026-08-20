# Claude Code — Project Instructions

All project rules (language, style, architecture, logging, code quality) are defined in:

@.github/copilot-instructions.md

## Release branch safety

Never run `git push` against `dev` or `main` unless the user explicitly asks
to push that branch in the current conversation. A push to either branch
triggers CI and a release; commits must therefore remain local until that
approval is received.

## Skills

Reusable procedures for recurring tasks (fixing a bug, editing AHK, auditing,
committing) live in `.claude/skills/`. They are loaded on demand — see
[AGENTS.md](AGENTS.md) for the index, which is shared with every other agent.

## Project memory

Accumulated engineering knowledge is routed by
[docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md) into focused topic files. Read
only the topics relevant to the work. The catalog is shared by every developer,
agent, and reviewer and replaces private memory stores. Keep durable additions
concise and in English, and prune stale history rather than accumulating it.
