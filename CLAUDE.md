# Claude Code — Project Instructions

All project rules (language, style, architecture, logging, code quality) are defined in:

@.github/copilot-instructions.md

## Release branch safety

Never run `git push` against `dev` or `main` unless the user explicitly asks
to push that branch in the current conversation. A push to either branch
triggers CI and a release; commits must therefore remain local until that
approval is received.

## Project memory

Accumulated engineering knowledge — hard-won gotchas, architectural invariants,
and the working conventions the maintainer insists on — lives in
[docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md). It is the single in-repo source
of truth shared by every developer, LLM agent, and reviewer (it replaces any
agent-private memory store). Consult it before non-trivial work, and when you
learn something non-obvious about this codebase, add an entry there so the
knowledge never evaporates.
