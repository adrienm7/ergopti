# Common brief for every Ergopti agent of this pass

You are one of ~14 parallel agents, each in its OWN git worktree on its OWN local branch. The coordinator
(not you) rebases your branch onto `origin/dev`, pushes and cancels CI. Work fast but to the repository's
quality bar.

## Hard rules

- Work ONLY inside your worktree (path given in your task). Never touch `/home/user/ergopti` (the
  coordinator's checkout) or another agent's worktree under `/home/user/wt/`.
- NEVER push, never `git fetch`/`rebase`/`reset --hard`/`stash`/`clean`, never touch `dev`/`main` refs.
  Just commit on your branch (it is already checked out).
- Never `--no-verify`. The pre-commit hook (husky) formats staged files and runs the strict convention
  lint over the WHOLE tree; fix what it reports in your own files.
- Commit messages: English Conventional Commits, imperative, lowercase subject <= 72 chars, body says why.
  NO `Co-Authored-By` or any tool/LLM attribution trailer (repository rule). No plan tokens like
  `P2.5`, `DL-3`, `Phase 2B` in messages (commit-msg hook). `PAR-12` style ids are fine.
- One atomic commit per fix/feature, each with a regression test that would fail without it.
- Do NOT edit `docs/ERGOPTIPLUS_TODO.md`, `TODO.md` or `docs/todo-agents/*` (the coordinator updates
  them from your final report). You may add durable facts to `docs/memory/*.md` when truly needed.
- Never edit `.claude/skills/` (generated mirror). User-facing text goes through every locale in
  `static/ergopti_plus/_shared/data/locales/*.json` (21 files; read `.agents/skills/i18n/SKILL.md`).
  Generated files change only through their generator (`npm run build:domain`, `npm run build:manifest`,
  `npm run gen`), never by hand.
- Store text as LF. AutoHotkey files keep their UTF-8 BOM. Never write backslashes through bash
  heredocs: use the Write/Edit tools.
- Read `AGENTS.md`, `docs/memory/README.md` and only the memory topics and `.agents/skills/*/SKILL.md`
  relevant to your surface (e.g. `linux-driver`, `hammerspoon-driver`, `ahk-driver`, `cross-driver-parity`,
  `logger`, `i18n`, `verify-change`, `meta-test`).
- Never weaken, skip or delete a test to get green. No magic values, no silent fallbacks, one source of
  truth for every constant.
- Cross-OS: the maintainer wants Windows, macOS and Linux parity. This container is Linux: there is NO
  AutoHotkey here, so `.ahk` code cannot be executed. You MAY edit AHK when the change is small and
  mechanical and you read the surrounding code carefully (ahk-driver skill), but say in your report
  that it was not executed; prefer delivering the Lua/JS parts fully and listing the Windows remainder.

## Tools available in this container

- Node 22.22.0 (pinned is 22.22.2: the Unicode 17 generator `codegen-unicode-case` may be red here,
  that is a host red), npm deps installed (node_modules is a symlink to the coordinator's).
- Linux driver tests: `cd static/ergopti_plus/linux && luajit tests/run.lua [--only <module>] [--module=<group>]`
- macOS driver tests (stubbed Hammerspoon): `cd static/ergopti_plus/macos && LUA=lua5.4 lua5.4 tests/run.lua [--only <module>] [--module=<group>]`
- Shared Lua tests are run by both runners (check `tests/support/module_groups.lua`).
- JS gates: `node tools/test/verify-change.cjs --plan` then `node tools/test/verify-change.cjs` (gates for
  your diff). Single gates: `node tools/test/<file>.cjs`, `npm run lint:conventions:strict`,
  `npm run format:check`, `python3 tools/locale/check_locales.py`.
- Ruff 0.15.8 is at `~/.local/bin/ruff` (pinned); prettier via node_modules.
- Full suites take a while: run the targeted modules first, the full driver suite once before your
  final commit if your change is broad. Compare a red against a clean baseline (`git stash` is
  forbidden: use `git worktree`-free methods such as `git show HEAD:path`) before blaming your change.

## Final report (your last message, concise, English)

1. Commits (sha + subject) on your branch.
2. What is done per todo item id, and what is LEFT (exact, so the coordinator can update the todo).
3. Gates run and their results (say plainly what is red and whether it is pre-existing).
4. Anything not executed (AHK, real hardware) and maintainer questions.
