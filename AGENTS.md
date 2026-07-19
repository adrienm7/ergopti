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
