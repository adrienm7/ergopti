# Claude Code — Project Instructions

All project rules (language, style, architecture, logging, code quality) are defined in:

@.github/copilot-instructions.md

## Project memory

Accumulated engineering knowledge — hard-won gotchas, architectural invariants,
and the working conventions the maintainer insists on — lives in
[docs/PROJECT_MEMORY.md](docs/PROJECT_MEMORY.md). It is the single in-repo source
of truth shared by every developer, LLM agent, and reviewer (it replaces any
agent-private memory store). Consult it before non-trivial work, and when you
learn something non-obvious about this codebase, add an entry there so the
knowledge never evaporates.
