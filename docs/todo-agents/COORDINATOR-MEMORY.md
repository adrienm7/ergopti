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

## In-flight agents when this session was closed (relaunch these)

Relaunch an agent by giving a fresh agent the prompt below plus "read docs/todo-agents/<file> first".

1. **Integration of the Codex fix branches** (file `integration-fix-branches.md`, which at hand-over lives on
   branch `tmp/integrate-final`, 133 commits above dev, 15 behind). Status: `fix/linux` (3), `fix/macos`
   (12) and `fix/windows` (113) are rebased there in a scratch clone `D:\_int`, with hosted-CI evidence
   recorded; uncommitted fixes sit in `D:\_int` (`tools/test/prepare-linux-distro-unit.sh`,
   `tools/test/test-ci-pipeline-wiring.cjs`). NOT yet on dev. Next: `cd D:\_int`, commit the pending fixes,
   `git fetch origin`, `git rebase origin/dev` (resolve conflicts keeping both intents; Codex tests are never
   dropped), run the cheap local gates, push `HEAD:refs/heads/dev` fast-forward only, cancel the automatic
   run of that SHA, and apply the same to the main checkout's local dev (`git fetch && git reset --keep
origin/dev` only when the working tree has no conflicting changes). Prompt: "Integrate
   origin/tmp/integrate-final into dev linearly (no merge commits, no squash) per
   docs/todo-agents/COORDINATOR-MEMORY.md; finish, then delete the tmp/integrate-\* branches."
2. **Windows image capture without PowerShell + exe metadata** (file `windows-exe-flagged-by-proxy.md`).
   Context: a tester behind Netskope (Airbus) gets "ErgoptiPlus.exe a peut-etre ete infecte par un virus" for
   v1.0.4 only (v1.0.0 and v1.0.3 pass). Strongest suspect: the hidden PowerShell clipboard-image stage
   `_GestureScreenshotRegionSaveScript` in `windows/modules/gestures/screenshots.ahk` (new in 1.0.4).
   Tasks, one atomic commit each: (a) revert the size budget gate (422ce140fd: the maintainer wants no
   forced size threshold; just keep files small); (b) replace the PowerShell/C# capture with GDI/GDI+ via
   DllCall in the driver, same behavior and logging, keep the robustness fixes and their tests, add a guard
   test against spawning powershell there, list other hidden PowerShell launchers; (c) add real PE version
   info (product, description, company, copyright, original filename, version from the CI plan version) to
   the Ahk2Exe build with a test; (d) update the handoff file. Physical check on the maintainer's PC after.
   Still open afterwards: reproducible PAC helper build (/Brepro), code signing (SignPath, item 132),
   VirusTotal/Defender submission with the new hash, the tester's download matrix T1-T4.

Finished agents' leftovers are in their files: `issue99-karabiner-input.md`, `issue99-ai-startup-updater.md`,
`lua-shared-timers-separators.md`, `windows-updater-freeze-menu-census.md`, `config-policy-33-42.md`.

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
