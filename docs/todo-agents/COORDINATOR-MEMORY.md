<!-- docs/todo-agents/COORDINATOR-MEMORY.md -->

# Coordinator memory (written October 21, 2026, 18:00 Paris)

Everything the coordinating session knew, so a fresh session or agent can continue without it. Read
[the checklist](../ERGOPTIPLUS_TODO.md) first, then this file, then the per-agent files in this folder.

## Where things stand

- **Released:** v1.0.4 (stable, nothing deferred) from 4a12db2fae. `dev` moves on from there; its
  automatic CI runs since 163b8214cb were cancelled on purpose to save quota. The last green full run
  was a manual preflight (39591820398, then dev run 39596425717 at 9432f4d963). Before the next release run
  `gh workflow run ci.yml --ref dev -f os_lanes=all` and fix what it shows.
- **Issues:** #84, #95, #96, #97 are closed (no replies, maintainer's choice). #99 (macOS 1.0.4, own Mac)
  is open: its fixes are on dev (see issue99-\*.md) and wait for the maintainer's Mac checks.
- **AppImage catalog:** `/retest` was posted on AppImage/appimage.github.io#10422 for v1.0.4. Read the bot's
  answer; the name must never contain "linux" (rule enforced by a pin test).
- **Maintainer's quota:** the weekly budget was nearly exhausted on October 21. Be economical: small
  targeted agents, no full-CI loops unless needed.

## Agents (none in flight since the evening of October 21)

Every agent of October 21 finished and its work is on dev: the Codex fix-branch integration (128 commits,
f0fb919379), the Windows image capture without PowerShell plus exe version info (03d9c017ed..1965c2ffac, exe text
965ff7569b), the Linux status window and tray menu for the AppImage catalog (98d41e630b, 3061ae1160), and the dev red
fixes (40e283e555..b0d4acd718; that agent stopped on an API error after recording its work). The `tmp/*`, `fix/*`
branches and the `D:\_int`, `D:\_lin` clones are deleted. v1.0.5 was released on October 22 (tag 17d4a3f421);
finished handoff files were retired into the checklist on October 22. Leftovers live in the remaining handoff files:
`windows-exe-flagged-by-proxy.md` (PAC helper /Brepro, signing, VirusTotal and T1-T4), `issue99-karabiner-input.md`,
`issue99-ai-startup-updater.md`, `macos-tap-hold-action-picker.md`, `config-policy-33-42.md`.

## Maintainer rules and decisions (all sessions)

- **Quality over speed**; ten days for a 1% gain is acceptable. Never weaken a test; a genuine external flake
  gets a bounded (max 2) logged retry at the harness boundary only; fix causes first.
- **dev and main are strictly linear**: rebase or cherry-pick, never `git merge`, no squash without explicit
  permission. Codex agents push to dev with the maintainer's credentials: always `git fetch` and rebase first.
  Pushing dev needs the maintainer's explicit permission in the current conversation; on October 21 he
  ordered: push to dev and cancel the automatic CI run of each push (`gh run list --commit <sha>`,
  `gh run cancel <id>`). `main` only moves for a release.
- **Release procedure:** a push to `main` runs the release. Force the number with a commit-message trailer
  `Release-As: X.Y.Z` (without it a `feat` commit bumps the minor). The plan step validates it. v1.0.4 was
  published by pushing the same commit to main and dev.
- **No hardcoding:** one source of truth for defaults, delimiters, delays, budgets (shared manifests).
- **Defaults are deliberate:** no automatic override of a user choice by layout; a stored number-row choice is
  never rewritten; an inert choice stays ticked, greyed and suffixed " — non appliqué".
- **Parity:** Windows, macOS and Linux get the same behavior or a stated reason in the menu text.
- **CapsWord:** default delay 10 s; default terminators space, tab, enter, nbsp, nnbsp, period, comma, semicolon,
  judged on typed output; pointer triggers are checkboxes; Linux CapsWord locks the desktop CapsLock.
- **Questions go to** [questions-for-maintainer.md](../questions-for-maintainer.md) when he is away.
- **Do not post on GitHub issues** unless told; the maintainer closed issues without replies.
- **No time estimates** for him unless asked; report outcomes faithfully, including red gates.

## Procedures that worked

- **Preflight before dev:** `git push -f origin HEAD:refs/heads/tmp/preflight-dev` then
  `gh workflow run ci.yml --ref tmp/preflight-dev -f os_lanes=all` (manual runs publish nothing; about 36 min
  when green). Read failures with `gh run view <id> --json jobs`, logs via `gh api repos/adrienm7/ergopti/actions/jobs/<id>/logs`.
  Delete `tmp/*` branches when done (`gh api -X DELETE repos/adrienm7/ergopti/git/refs/heads/<name>`).
- **Hook blocked by someone else's dirty file:** the pre-commit lint scans the whole tree. Wait, or commit
  through a private index (build the tree, run the hooks on an export, `commit-tree`, compare-and-swap
  `update-ref`). Never `--no-verify`. Do not leave long-lived dirty files in the shared tree.
- **Updater source seal:** after touching a sealed Windows file run
  `node tools/ci/seal-windows-updater-original-source.cjs --ref <HEAD sha> --write` (works on Windows now) and
  commit `tools/ci/windows-updater-original-diagnostic-cohort-inputs.json` alone. New Windows test files must
  belong to exactly one of the 14 test categories (matrix gate).
- **Windows host quirks:** AHK from PowerShell/Node, never Git Bash; `run_all.ahk` replaces a running copy of
  itself (use a private copy for `--only` runs, and never leave it in `tests/`); AHK ignores the APPDATA
  variable and reads the real profile; never boot against the live config; long paths need a short-path clone
  (`D:\_int`, `D:\_lin` may be deleted by the maintainer); `rtk proxy <cmd>` gives raw output when the hook
  filters; macOS Lua tests need the luv.hrtime shim; no WSL distro, so Linux LuaJIT tests only run in CI.
- **Host-only reds are normal locally:** no pwsh, Node 22.16 vs pinned 22.22.2 (Unicode 17 generator), no
  symlink privilege, `D:` paths in macOS fixtures. Compare with a baseline before blaming a change.
- **Windows image curl:** hosted Windows images from 20261018 have a System32 curl without NTLM: three cases
  report NOT EXECUTED by design (item 62: needs an owned SSPI-capable curl).
- **Known flakes:** macOS Swift test `testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope`
  (passed on rerun), Linux `test_dynamic_dry_run_dispatch.lua:181` on some distros, Windows `artifact curl`
  staging worker, a Fedora mirror 404. Rerun failed jobs first, then root-cause if it repeats.

## Open decisions waiting for the maintainer

See [questions-for-maintainer.md](../questions-for-maintainer.md): Linux `[BS]x` pairs, Ollama redirect
policy behind a proxy, Linux recommended LAlt+CapsLock, NTLM transport (owned curl vs WinHTTP), timer ceiling
(decided: 2^53 ms, delivered), HS-274 orphan tools, ISO key override check with Karabiner-EventViewer,
macOS automatic proxy setting (`scutil --proxy`), the second Hammerspoon instance at install.
