<!-- docs/ERGOPTIPLUS_TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-27 morning (read "Handover of 2026-10-26" first). Latest stable: [v1.0.6](https://github.com/adrienm7/ergopti/releases/tag/v1.0.6)
(tag 950979d19c, 2026-10-23). **Next step: issue #101 follow-ups on the Mac (Backlog).** Open work only: a finished item is removed, its lessons go to
[docs/memory](memory/README.md), and the history stays in Git
(`git log -p -- docs/ERGOPTIPLUS_TODO.md`). Item numbers are stable and never reused. Open
questions are in [questions-for-maintainer.md](questions-for-maintainer.md); per-work handoff files
are in [`docs/todo-agents/`](todo-agents/).

Tags: **[CODE]** software to write or adopt; **[CI]** only a hosted or native CI run qualifies it;
**[PHYS-W]**, **[PHYS-M]**, **[PHYS-L]** needs a real Windows PC, Mac or Linux machine.

**Generic caveat, stated once.** Unless an item says otherwise, native macOS and Linux qualification
and every physical-device acceptance remain OPEN and their qualification flags stay false; portable
tests, containers and software-supplied events are never physical evidence. The maintainer has a
Windows PC (physical tests on request) and a work Mac (reproduce on CI first, then at most one short
command); there is no Linux machine.

**Rules for every agent.** dev and main stay linear (rebase or cherry-pick, never `git merge`); a
release is a push to `main` carrying a `Release-As: X.Y.Z` trailer; Codex agents push to dev, so
fetch and rebase first, and preflight on `tmp/preflight-dev` with
`gh workflow run ci.yml --ref tmp/preflight-dev -f os_lanes=all`; a hook failure caused by someone
else's dirty file is waited out or bypassed with a private index plus compare-and-swap `update-ref`
running the hooks, never with `--no-verify`; never weaken a test; quality over speed. Run the pinned
ruff 0.15.8 and Prettier before every commit. After touching
a sealed Windows updater source, reseal with
`node tools/ci/seal-windows-updater-original-source.cjs --ref <commit> --write`. Procedures:
[COORDINATOR-MEMORY](todo-agents/COORDINATOR-MEMORY.md).

## Handover of 2026-10-26 (read first if the session was lost)

- **State.** dev 376b28db82 is linear and pushed; every push of dev had its CI cancelled (a dev push builds a
  release). Latest stable release: v1.0.6. A full CI on 376b28db82 was dispatched on `tmp/preflight-dev` at
  03:23 UTC on 27 October: read it first. The previous full run (40424851292 on 34ff85e515) was green except
  Windows `hotstrings-shortcuts`, macOS E2E Managed Ollama (Intel, likely flaky: rerun) and Launcher XCTest
  (macOS 26), and the Linux integration rows, all addressed in this batch (CI-only confirmation).
- **Integrated from the ChatGPT fix branches** up to 27 Oct 01:30 UTC. Per-branch seal refresh commits are never
  integrated: reseal once on dev instead.
- **Sixth integration batch (27 Oct morning)** brought into dev: fix/windows up to 07d2514ef0 (seal commits
  skipped, resealed once), the Linux daemon account-name fix, the PAR-74 Lua burn-down (567 to 0), the PAR-58
  vectors and ledger, the network-check `route_plan` step, PAR-43, and PAR-41 on macOS/Linux (schema v15).
- **Agent work in flight (Linux/macOS only)**, each backed up on a remote `tmp/wip-*` branch; if lost, redo
  from the spec:
  - `tmp/wip-todo-ae-sweep`: a sweep of the small Linux/macOS TODO items (anything not owned below).
  - `tmp/wip-todo-af`: check the prediction floor decisions are all covered, then PAR-66 section readers, then
    the Lua 5.4 `io.popen` child that still sees the real HOME in tests.
  - `tmp/wip-todo-ag`: Linux Quit refusals as macOS (Quit wins over reload, a pending scope write blocks).
- **Scripts used by the coordinator** live in the session scratchpad (lost with the container): `fullsweep.sh`
  (gen:check, every `node` suite check with `xargs -P6`, Linux suite with `USER=root LOGNAME=root` and a
  private `XDG_RUNTIME_DIR`, macOS suite per `--module` group), `pick.sh` (cherry-pick a list until a conflict)
  and `renumber.py` (contiguous suite ordinals, increasing within each file). The commit hook needs Ruff 0.15.8
  first on PATH (`python3 -m venv` plus `pip install ruff==0.15.8`).
- **Integration procedure** (each batch): fetch `origin/fix/{linux,macos,windows}`; list commits whose subject
  is not on dev; cherry-pick them on a local `integ/*` branch from dev (skip seal refresh commits; on a
  conflict prefer dev when it already fixed the same thing, otherwise merge both by hand); renumber
  `tools/test/features/*/suite.json` ordinals on collision (`test-js-feature-inventory.cjs`); reseal if
  `test-windows-updater-original-source.cjs` fails; run gen:check, the complete JS sweep (every `node` check
  of the suite.json files, `xargs -P6`), the Linux suite and the macOS suite per `--module` group; then
  fast-forward dev, push, cancel the push CI, and dispatch `ci.yml` on `tmp/preflight-dev` with
  `os_lanes=all`.
- **Host-only reds on the Linux container** (not bugs): JS `test-ahk-tap-follower`, `test-linux-install-sandbox`,
  `test-linux-runtime-native-registration`, `test-macos-managed-bootstrap-http`, `test-managed-ollama-protocol`,
  `test-managed-remote-retirement` (no pwsh), `test-linux-deb-package-owner` (refuses root),
  `test-drift-guard-covers-every-output` (worktrees only, node_modules symlink). Lua as root: every
  EACCES/unreadable/denied case, Linux test 102, four `test_sqlite_first_open` native cases; macOS screenshot
  EACCES, two mlx-repair unreadable neighbour, errors-log refuses denied, the eight `release-arming-physical`
  cases (refuse root). Confirm with
  `setpriv --reuid=65534 --regid=65534 --clear-groups` and set `XDG_RUNTIME_DIR`. Run the macOS suite per
  group: one process slows down progressively here.
- **Windows counterparts of the 26 October work** (add to the PC list below once the Lua side is in dev):
  - read `[logger] hotpath_slow_ms` in `hotpath_profiler.ahk`;
  - drop the dead crash kind (`error_dialog/init.ahk`, `ERROR_REPORT_KINDS`, then the shared `KINDS` and the
    `crash_multi_line_without_recent_issues` vector together);
  - read the 14-colour palette from `native_theme.toml`;
  - use `dialog.action_picker.requires_ai` for the greyed AI actions;
  - port `llm/request_plan` (debounce, batching) with its vectors, accept -1 "never", never hold explicit
    requests, read `llm.trigger.min_request_interval_ms` with a menu row, then delete
    `rate_limit_min_interval_ms` from `inference.json`;
  - `tap_hold.toml` v0→v1 migration (`_shared/tap_hold/migrations.toml`) in the loader and writer, stop
    reading and writing `explicit_delays`;
  - Quit refusals before `ExitApp` with `notify.quit_refused` (PAR-45);
  - the registry op that re-encodes a value in `config_migrate.ahk`, then delete the macOS
    `[llm.profiles] user_profiles` reader import.

## Release blocker (before the next release)

- [ ] **Shortcut parameters lost by the schema v15 slot renames.** [CODE] PAR-41's `v14_to_v15` step renames
      the macOS and Linux slot ids (`cmd_*`→`primary_*`, `hs_ctrl_*`→`secondary_*`, `ctrl_*`→`primary_*`,
      `super_*`→`meta_*`), but the per-slot action parameters (`gestures.action_parameters` keys
      `keyboard__<slot>__<action>`) cannot follow with the existing op kinds, so they would be orphaned (reported
      as outdated, re-entered by hand). Fix: a `rename_prefix` op, taught first to Windows
      `config_migrate.ahk` (it refuses an unknown op at boot) together with the re-encode op of the older macOS
      LLM profiles, then to the Lua engines and the JS reference, then the parameter ops in `v14_to_v15`. Do
      not release with v15 before this lands (only after PAR-41 reaches dev).

## Windows side to do on the PC (from October 25)

Work done on Linux and macOS only; the AHK side is built and run live on the Windows PC.

- [ ] **PRIVACY: private hotstring text reaches AI prompts on Windows.** [CODE] Fixed on macOS (private
      expansions now hidden from every prompt) and Linux (separate AI context). Read-only look at Windows:
      `_HSE_MirrorCanonicalEffectToLlm` (`hotstring_dispatch.ahk`) and `_HSE_MirrorLiteralEditToLlm`
      (`hotstring_send.ahk`) copy `Effect.InsertedText` into `_LLM_Bridge_Buffer` and the agent buffer, and the
      Effect objects from `HSE_ApplyExpansion` carry no private flag, so a phone/SSN/IBAN expansion can be sent
      to Ollama or a remote provider. Add `IsPrivate` to those Effects, clear both buffers on a private effect
      and keep appending later typing (as Linux); AHK test: a private expansion then a prediction request
      carries no secret. Do this first on the PC.
- [ ] **Hosted Windows unit failures.** [CODE] Run 40235626114 (e2aa642f8c) still fails `meta`,
      `config-scope-features`, `core` and `keymap-gestures` (likely the gesture greying, dbc29c5077);
      `hotstrings-shortcuts` passes since the second round of fixes. `test_hotstrings_scope.ahk:520` (expected 0.5, got 1.0) is
      unexplained: print `_HotstringsOverrides["autocorrection"].Sections[family]` after
      `HotstringsOverridesApplyBase()`.
- [ ] **AI off disarms the AI keys and the agent's manual actions.** [CODE] Done on Linux and macOS
      (bc2048765a, 6d96986979). Windows: `AiActionIsAi`/`AiActionBlocked` in `modules/gestures/config.ahk`;
      split `TapHoldTapAction` (`platform/remap/tap_hold_loader.ahk`) so a blocked AI tap returns the native
      tap, configured readers in `menu_taphold.ahk` and `tap_hold_writer.ahk` use the new
      `TapHoldConfiguredTapAction`; per-press gates in `TapKeyShouldFire`, `ScriptShortcutSlotRunsAction`,
      `KeyCombinationOwns`/`KeyCombinationFire`, `GestureDispatch`, `_MagicEditorBrokerWinner`; AI hotkeys
      through `HotkeyRegistrarSetEnabled` from `LLM_Menu_ActivateRuntime` and `_LLM_Menu_ApplyToggleCommitted`;
      `_LLM_Agent_ManualRefusal` passes `LLM_Menu_AiEnabled()`; `requires_ahk = ["ai:on"]` on the two agent
      actions with the codegen token and the picker greying; tests `test_ai_action_gate.ahk`,
      `test_llm_agent.ahk`, `test_llm_agent_requester.ahk`; reseal.
- [ ] **One app-category file on the three OS (PAR-34).** [CODE] Windows keeps `app_categories.json` in the
      metrics dir and accepts legacy flat string values the Lua codec refuses, and it preserves unknown
      members the codec drops. Align the location (decision pending), the record shape and the score range,
      and replay `_shared/tests/corpus/metrics/app_category_store_vectors.json` in AHK.
- [ ] **AI off disarms the agent's automatic mode.** [CODE] Done on Linux and macOS (e284077ba9). Windows:
      the AHK agent runner arms no typing pause and refuses a triage or request in flight while the AI is
      off, cancels the pause at the switch-off and re-arms on the next keystroke; rewrite
      `test_llm_agent_ai_off.ahk` (it feeds the agent with the AI off on purpose) to assert that.
- [ ] **Release notes in the update-check window (PAR-52).** [CODE] `windows/ui/update_check/init.ahk`:
      seed `state.notes = {body, owner, repo}` in the `available` message (from `UPDATER_LATEST_RELEASE.Body`,
      `UPDATER_GH_OWNER`, `UPDATER_GH_REPO`, as `_Updater_ReleaseNotesSeed`), serve `open_url` in the
      `available` phase through the allowlist behind `_Updater_OpenManualUrl`, add `"open_url", "available"` to
      `UC_PAGE_ACTIONS`, then drop `open_url:available` from `luaHostsOnly` in
      `tools/test/test-update-check-dialog.cjs`.

## Decisions of 2026-10-26 to implement (docs/questions-for-maintainer.md)

- [x] **Slow-segment threshold 5 ms on macOS and Linux.** [CODE] Done (`[logger] hotpath_slow_ms`); Windows reader left.
- [ ] **Versioned `tap_hold.toml` migrator.** [CODE] Linux done (`_shared/tap_hold/migrations.toml`,
      macOS has no tap_hold.toml); in progress: byte-preserving rewrite (agent AE); Windows side on the PC.
- [x] **Linux crash: notification only.** [CODE] Done; Windows dead crash kind left.
- [x] **Linux Quit refusals as macOS.** [CODE] Done (shared `quit_admission.lua`; Quit wins over a reload and waits
      for a running write, 59e20c6b0a); Windows on the PC (PAR-45).
- [x] **14 hotstring colours on the three OS.** [CODE] Done (`native_theme.toml`); Windows reader left.
- [x] **Retire `_shared/ui/metrics_apps/script.js`.** [CODE] Done; the "general" alias folding is in the live modules
      (81635a815a).
- [x] **Dedicated AI-off hint string.** [CODE] [I18N] Done (`dialog.action_picker.requires_ai`); Windows reader left.
- [ ] **Registry op that re-encodes a value.** [CODE] Windows `config_migrate.ahk` first (PC), then the Lua
      engines, then delete the macOS `[llm.profiles] user_profiles` reader import (0146a938c5).
- [x] **Prediction request floor.** [CODE] Explicit requests never wait for the floor; one global floor
      settable from the menu on the three OS; "never" debounce on the three OS; live mode instant at a word end;
      the variants of one request never wait; default 300 ms, 0 accepted; a mashed explicit shortcut supersedes
      its in-flight request. macOS and Linux: done and checked part by part (88b27a94c1 to 5c36a116cd,
      fcaec1a91c, 8fce07aa86, 928bca090e, 15ceb9e044). Windows on the PC (see the counterparts list).
- [x] **PAR-66 section readers.** [CODE] Done (4c9a672215, 0747800cfc; gates pin the shared text). Re-point the source-pin gates to the shared module, then extract
      `personal_info_editor_source` and the metrics/configuration/debug/about readers.

## Integration pass of 2026-10-24 evening: what landed and what is left

A coordinator session ran a parallel pass on the parity and performance items. Its work is now on `dev` (about 495
commits). Its CI run was cancelled, so no release was cut. The `agent/*` and `fix/*` branches on origin could not be deleted from the session (the proxy refuses branch deletion): delete them by hand, since all their commits are on `dev`.

**Landed.** 9 cloud worker branches:

- Linux CI lanes, AppImage distribution matrix, Linux perf probe.
- macOS Lua perf (TOML scan reuse, ASCII fold), macOS stubbed suite health, Windows AHK suite under Wine.
- PAR-19, PAR-22/34/40, PAR-30 (first commit), PAR-59/63/64, PAR-67, PAR-71, PAR-73/77, PAR-74/84.

14 local agent branches:

- The health fixes, the Linux perf commits (in-process `find` replacements), PAR-21 (part).
- PAR-44/45/52 (part), PAR-53..57 (part), PAR-60..62 (part), PAR-65 (part), PAR-68/72 (part).
- PAR-69 and PAR-70 (one of nine), PAR-75, PAR-81 (part), PAR-12/37/48 (part), PAR-78..80 (part), PAR-82/83/85 (part).

The three `fix/*` branches: fix/linux 36 commits, fix/macos 31 commits, fix/windows 269 of its 273 commits (the other
four were already on dev).

**Measured on this container (stubbed suites).**

- macOS: 484 failures on the previous `dev`, 68 after integration.
- Linux: 18 failures after integration (the agents reported 85 on the previous `dev`).
- `npm run test:js` loads again; the duplicate ordinals and ids were renumbered.
- `node tools/test/verify-change.cjs` is still red in this container: openbox, native Nix admission and Unicode 17 are
  missing here.
- Nothing native (AHK, Hammerspoon, a real desktop) was executed except the AHK suites under Wine.

**Integration resolutions to review.** These are conflicts between branches that each counted from a base without the
other:

- `test-linux-e2e-shards.cjs` 180 steps, and `test-ci-full-default.cjs` 185 slots: the Go route plan twin plus the
  split install steps.
- The reason ratchet ledger in `test-platform-restrictions-explained.cjs` (3): `llm.user_profiles` and
  `auto_profile_for_model` should be opened to macOS.
- The duplicate-constant-name baseline shrank by two.
- `windows/infra/input_probe.ahk`: the owner and admission rewrite from fix/windows, combined with dev's
  `WMPresentWindow` and `_IP_TargetReady`. **Not executed: run it on the PC.**
- The keystats aggregation corpus test now follows the shared walker from PAR-67.
- Duplicate fixes for the LuaJIT 60-upvalue limit of `main()` (three agents) were dropped in favour of the first one.

**Left, not committed when the agents stopped.** Their worktrees were removed; redo each item from its PAR entry:

- PAR-53..57: the instrumentation inventory, Lua driver sections and the macOS boot profiler tests.
- PAR-75: the macOS adapters migration.
- PAR-66: the menu frames, entirely.
- PAR-82/83/85: the Lua reader migrations of the UI-string gate.
- PAR-44/45/52: the release-notes and update-check pages, and the notes contract.
- PAR-65: the request plan in both prediction engines.
- PAR-68/72: the Linux and macOS readers of the shared hotstring config.
- PAR-78..80: the `[limits]` rules of the timing gate.
- PAR-12/37/48: the locale and translation-audit part.
- PAR-60..62: the sequence-corpus commit and the macOS harness edits.
- PAR-81: the computed-style comparison.
- fix/windows: the keylogger publication owner tests.
- Cloud sessions stopped mid-task:
  - PAR-73/77 (features manifest text consumers);
  - PAR-74/84 (Lua dotted-key migration);
  - macOS stubbed suite health (about 68 reds left);
  - Linux perf lab (boot-stage timings);
  - Windows AHK under Wine (triage of its reds).
- Not started: PAR-14 (Windows), PAR-43, PAR-58, PAR-76, the Windows managed Ollama route plan consumer, the PAR-71
  proxy-precedence ratchet to zero, and the Wave 2 and backlog remainders.

**How the work was split, and what to keep.**

- **Split by file ownership, not by todo item.** Each agent owned one surface (a driver area or a shared module) and
  the items that touch it, so two agents rarely edited the same file. The coordinator alone edited this todo, integrated
  and pushed. Each agent had its own branch and wrote a final report: commits, done and left per item, gates, what was
  not executed.
- **Shared registries collide.** These grow at the end in every branch: `tools/test/features/*/suite.json` (global
  ordinals and `js-NNNN` ids), `linux/tests/test_manifest.lua`, CI step and slot counts, ratchet baselines, the sealed
  updater inputs. Give each agent a reserved ordinal range up front, or integrate often. Regenerate generated files
  and reseal once after integration, never by hand.
- **Land early and often.** One branch every half hour, rebased onto `dev`, with one push and its CI cancelled, is far
  cheaper than 30 branches at the end.
- **Size the pass to the quota.** About 30 parallel agents (18 local, 12 cloud) used the whole five-hour allowance in
  about 20 minutes. Stay at 4 to 6 parallel agents. Resume a stopped agent within the hour, while its prompt cache is
  warm; after that, harvest its commits instead of reloading its context.
- **Specialised containers worth reusing.**
  - A Wine container that runs the Windows AHK suites on Linux (`tools/test/run-ahk-under-wine.sh`, UTF-8 locale):
    Windows checks no longer need the PC for everything that is not input or GUI.
  - A distribution container matrix that launches the AppImage (Ubuntu 20.04 to 26.04, Debian, Fedora, openSUSE,
    Arch, Alpine).
  - A Linux perf lab (startup module graph probe, boot-stage timings).
  - A macOS pure-Lua profiling container (stubbed Hammerspoon).
  - A Linux CI-lanes container that runs every step of the hosted Ubuntu jobs locally.
  - One review pass with three lenses (correctness, contracts, integration), each finding checked by two skeptics,
    before landing.

## Handover of 2026-10-24: where we stand and how to continue

Written at the end of a long multi-agent session. Read this first, then the item you pick.

**State of the repository.** About 140 local commits on `dev` are NOT pushed (the last push to `origin/dev` was
7099eb93ef). Pushing `dev` needs the maintainer's explicit go-ahead in the current conversation (AGENTS.md); a push
cuts a release unless the run is cancelled, so cancel the CI run of each push (`gh run cancel`). No release was cut and
`main` was not touched. Before the first push: integrate the shared JSON (see "Integration checklist"), run
`node tools/lint/lint-conventions.js`, the three AHK boot checks and the targeted gates of the items you touched.

**What was done in this session (details in `git log` and in the items).** Keystats rename (keylogger gone); issue #101
fixes (ATS key for an http PAC, direct route when the PAC lookup names no route, named lookup stages, no retry of a
refused route, lease line cap, Ollama 412 upgrade request); WinHTTP transport (item 62); per-layer layout composer on the
three OS; hotstring expansion delay defined once and aligned (shared corpus `time_gate_vectors.json`, definition in
`docs/memory/text-input-and-config.md`); chaining pinned by tests (buffer continuity, `test_hotstring_chaining.ahk`);
Space tap-hold press tick; HS-274 owned Karabiner runtime (dormant, hidden `[karabiner] runtime = "owned"`); one-click
Debug field checks on all OS; evidence log API that is never collapsed (`LoggerEvidence`, `Logger.evidence`); redaction
rules and the opt-in redacted day log; AV-surface gate and the false-positive submission pack; CI tooling (rerun verdict,
Flatpak cache and retry, remap-runtime workflow, slowest-test summary); performance work (below); cross-OS parity audit
(PAR entries). Hosted validation on throwaway `tmp/ci-validate-*` branches is logged in
[ci-validation-2026-10-24.md](ci-validation-2026-10-24.md).

**Performance state per OS (measure before optimising; every driver now has permanent counters).**

- Windows: boot to ready 13.6 s to about 8.4 s, tray menu stage 2.6 s to 1.2 s, focus cache event driven. Next: remaining
  registry compares (about 28 write-admission callers), `Hook.KeyDown` attribution (sampled subscriber timings are in;
  read the next live log), `Tooltip.Build` 7.6 ms and `Present` 10.6 ms, layout registration (about 1 s of `Hotkey()`
  calls), the 2 s script parse (9.7 MB include graph, no safe lever found), typst/emoji hotstring sections (about 460 ms).
- Linux: idle loop 99.99 % of a core to 1.5 %, X11 focus without forks, TOML about 2x faster. Next: 315 eagerly loaded
  modules (about 500 ms), five `find` forks in the hotstring loader, log rotation forks in `logger_sink.lua`, validate
  idle CPU and the libxcb focus path on a real desktop.
- macOS: instrumentation only (`infra/phase_stats.lua`, menu per row, boot sub-stages, hold attribution). Next: read the
  Mac log lines listed in "Mac field test" and optimise the dominant phases (menu rebuild 113-247 ms, boot stages,
  preview 21-29 ms per key, preferences writes of 300 operations, ingest tick 1.0-1.5 s).

**Maintainer decisions taken (do not re-ask).** Hotstring chaining is buffer continuity and already works; it is pinned
by tests, never break it. Shared complex-key multiplier on all three OS (PAR-7). Layout pause/resume implemented on
Windows and Linux (PAR-19). Tap-hold and key-combination defaults identical on all OS except real role differences,
each with a stated reason (PAR-17). Linux reload through a TTL-bound pending-record protocol shared by the three OS.
Preview switches default ON everywhere, notifications aligned on macOS, WPM defaults off (coordinator choices, ask for
review). libXi dependency declined (Xi packet retired). Items 46/47/48 retired except the macOS Ollama termination debt
(120). Optional redacted day log allowed; config-directory names masked in logs. Item 131 is a read-only login-items
check, no removal. No token-reuse rearm (ADR 012). Expansion delay with end char: from the last typed letter to the
expander (`★` or the end character).

**Decisions still pending for the maintainer.** `docs/questions-for-maintainer.md` (check it for anything new). The 2026-10-24 QCM answers are implemented (October 25): PAR-6, PAR-8, PAR-15, PAR-21, PAR-24, hotstring cascading, Space tap completion, the recommended-defaults rule and AI off on Linux. Still open: the content-Gui pool of the Windows prediction tooltip, PAR-12 on the PC.

**Remaining work, in the order to take it.**

1. Integrate and push (see checklist), then run the FULL suites once on the final tree: `node tools/test/verify-change.cjs`
   (about an hour with parallel agents idle) and the full AHK suite (about 90 minutes, single threaded, nothing else
   running: `run_all.ahk` is `#SingleInstance Force`, concurrent runs silently kill each other). Fix only reds caused by
   our changes (hosts reds: Node 22.16 vs pinned 22.22.2, Unicode 16, no pwsh, no lfs, `build:linux`, Windows file staging).
   Known red to chase first: live check `reload-click-joins` ("second click not logged as joined") failed at the end of the
   session after it passed at 1254dd7bd7; the joined-click log line comes from `menu_dispatcher.ahk`; suspects: the
   driver_control pending-record work (d682fa6995) or the perf commits; run
   `node tools/maintainer/windows-live-checks.cjs --only reload-click-joins` with no other AutoHotkey process, bisect with
   `git archive` exports (no worktree).
2. Hosted CI on the final source: `gh workflow run ci.yml --ref tmp/preflight-dev -f os_lanes=all` (only after every
   piece passed alone; macOS runners are expensive). Then the CI receipts section.
3. The cross-OS parity entries `PAR-1` to `PAR-85` below: unfinished ones are those not marked done; centralisation and
   constants (PAR-65 to PAR-85) were not started: one declaration in `_shared` per constant, delay, colour, label;
   hexagonal architecture (rules and ports in `_shared`, OS code only in adapters); each with a single-source gate.
4. Performance items above, on each OS; then re-measure with the permanent counters and keep the numbers in the commits.
5. Items that need devices or the maintainer: see "Mac field test", "Windows PC field test", SignPath application,
   Microsoft/vendor submissions, tester retests, the maintainer checks sections.

**Mac field test (after a release or a local build of this tree).** Debug menu, one click each, then Copy report and
send the log lines `Field check result:`: Test Karabiner lease, Test owned Karabiner runtime (dormant check), Test
network (PAC, proxy, download), Test key accounting (30 s while typing), login items and agents, toolchain (timer,
Shortcuts, Homebrew, Karabiner signature), Test the composed layout. Also bring back after an hour of normal use:
`Phase summary [family]` (keymap, preview, menu, menu_item, toml, process, boot_sub, hotstring_load, runtime, hotpath),
`Menu tree rebuilt ... Slowest:`, `Boot stage requires:`, `Boot sub-stage:`, `Common hotstring load:`, every
`held the main thread ... Phases inside the hold:`, `Slow ingest tick`, `Slow preferences save`,
`Lease token decision=`, `written in N ms`, `Memory snapshot`. Confirm on the Mac: an http company PAC works (issue
#101), `pr` + Space style triggers, the ISO/ANSI selector (Automatic/ISO/ANSI) with a physical keyboard, the
menu-triggered redeploy.

**Windows PC field test.** Reload the driver from the working tree only when the tree parses (the three boot checks);
then run `node tools/maintainer/windows-live-checks.cjs` with NO other AutoHotkey process running (SendInput falls back
to SendEvent when another script has a keyboard hook, and the real-key checks refuse to run next to another driver);
Debug > Record keyboard hook order (expect the native owner first again after the reassertion) and Measure SendEvent vs
SendInput on a quiet machine; the manual lists in [windows-maintainer-checks.md](tooling/windows-maintainer-checks.md).

**Integration checklist (shared files other agents leave uncommitted, because the pre-commit hook rejects a partially
staged `.json`).** `static/ergopti_plus/_shared/data/locales/*.json` (21 files), `_shared/modules/menu/menu_manifest.json`
(regenerate with `npm run build:domain`; `codegen-unicode-case` fails on this host, ignore that step),
`_shared/modules/diagnostics/schema.json`, `_shared/modules/features/manifest.toml`, `_shared/ui/layout_manager/strings.json`,
`windows/tests/run_all.ahk` (includes for tests whose files already exist: capsword state, composer check, new live
tests), `package.json` (npm aliases such as `test:remap-runtime-manifest`, `test:neutral-installation`), the test suite
registries under `tools/test/features/*/suite.json` (renumber clashing ids), `docs/memory/*.md` entries listed by the
agents. After integrating: `python tools/locale/check_locales.py`, `node tools/test/test-menu-manifest.cjs`,
`test-approved-menu-labels.cjs`, `test-diagnostic-ui-integrity.cjs`, `npm run test:ci-pipeline-wiring`. Reseal the
updater original source after any change to a pinned file:
`node tools/ci/seal-windows-updater-original-source.cjs --ref <commit> --write` (only when `run_all.ahk` is clean).

**Hazards learned.** One lint violation in anyone's new file blocks every commit (the hook lints the whole repo):
run the lint after every save. A half-saved `.ahk` file breaks the maintainer's live driver (reloads come from the
working tree): edit a copy and move it in when it parses. Committing through a temporary index leaves the real index
stale: run `git status` before a plain commit and reset only your own paths. `wsl --shutdown` kills other agents' WSL
jobs and clears `/tmp`: do not run it while others work. Never type backslashes through bash heredocs or python text
mode (use the Write/Edit tools). Test the Windows pieces for real on the maintainer's PC (everything Windows can be run
here); macOS and Linux behaviour that needs hardware goes through the Debug field checks and the maintainer's logs.

## Big item 1: Windows corporate networks and trust (items 62, 132)

- [ ] **62. WinHTTP transport for the managed remote downloads.** [CODE] Done (1d15b51e66, 7c001b2456
      and the following commits): managed requests, updater artifact download and Ollama archive
      download use WinHTTP (`vendor/ergopti_winhttp_transport.ps1`, worker
      `ergopti_managed_http_worker.ps1`); `curl.exe` stays only for loopback Ollama. Proven on this PC
      against owned loopback services with real SSPI NTLM and Negotiate proxies, CONNECT, untrusted
      TLS, bounds, deadlines and PAC failover. Left: the native CA cases (a click on the Windows
      security warning or an elevated LocalMachine scope), enterprise acceptance behind a real
      proxy/PAC (Kerberos, TLS inspection, revocation) through Debug > diagnostics (`github_api`,
      `proxy_pac`), and item 36 (external trusted binding).
- [ ] **132. SignPath Foundation signing.** [CODE] Apply, integrate Windows signing, then delete
      `.github/ci/stable_windows_signing_exception.json`. Before applying, check the current
      conditions on signpath.org/foundation (open-source license, public repository, build and
      signing from CI with a maintainer approval per signing request, a published code-signing
      policy and privacy statement, a reputable project; the keystats-like metrics module and the
      hooks need a clear explanation). Decided 2026-10-22: apply now. Done: SignPath wired in
      `ci-windows.yml`, off until configured (61fb29d64d); README code signing policy and privacy
      (c6db589c76). Left (maintainer): apply, then set the variables and secrets; eligibility table,
      form answers and switch-on steps in the
      [handoff](todo-agents/signpath-foundation-application.md).
- [ ] **`ErgoptiPlus.exe` flagged by a corporate proxy (Netskope, Airbus tester).** [CODE] [PHYS-W]
      Done: no hidden PowerShell clipboard stage, own version resource, English metadata, tar.exe
      extraction, the keylogger naming gone (keystats rename; the gate forbids `keylog` in the script
      and the bundle), string-surface ceilings and a per-build record with the exe SHA-256 in CI
      (e2c9dfb79d), the submission pack
      [windows-exe-false-positive-submission-pack.md](todo-agents/windows-exe-false-positive-submission-pack.md).
      Left (maintainer): signing (132), VirusTotal lookup, Microsoft and vendor submissions, the
      tester's block page and retry (T1-T4); decide whether the `WH_KEYBOARD_LL` probe in
      `input_probe.ahk` stays in the release exe. Playbook:
      [handoff](todo-agents/windows-exe-flagged-by-proxy.md).

## Big item 2: macOS Karabiner input reliability (items 31, 117, 140)

- [ ] **117/140. Karabiner lease failures on Apple silicon.** [PHYS-M] Exit 73, PONG/READY
      timeouts since dev.155. The lease budgets are ordered so a slow CLI keeps the lease, every
      exit 73 names its cause, each deploy decision is one INFO line (recovery deploys wait for a
      typing pause; an unchanged `karabiner.json` is never republished), and the lookup that froze
      the main thread 13 s is gone (0292ec401d, e57f4cce77). Issue #100: on-time deadlines fired
      while the Ergopti menu was open, because `hs.task` streaming output is read only in the
      default run loop mode; an on-time deadline now waits for a `/bin/cat` echo before judging the
      worker (25411ee080, after v1.0.5). Reproduce on the Mac with these log lines; the only
      workaround is Configuration > Ergopti uses Karabiner > Off. Recovery deploys (28 of 33 on
      2026-10-19) cannot be reduced without fewer lease failures. Leftovers:
      [issue99-karabiner-input.md](todo-agents/issue99-karabiner-input.md).
- [ ] **Dropped letters on macOS.** [PHYS-M] Unproven. Every consumed and never delivered key is
      reported ("typed key(s) swallowed", decisions only, never the key). Mac action: Debug > Report
      a bug right when a letter disappears, then compare with lease failures or Karabiner deploys.
- [ ] **31. HS-274 exact physical key accounting with an owned Karabiner runtime.** [CODE] Work
      packages WP3-WP10 (production consumer, headless producer v2, reproducible runtime, launchd
      ownership, owned configuration, native and real-Mac acceptance, enable and retire); media keys
      without a macOS keycode; VirtualHIDDevice incompatibility blocks owned mode with an
      explanation. Plan: [ADR 011](../static/ergopti_plus/docs/adr/011-owned-karabiner-runtime.md).
      Estimate 30-40 agent-days plus hardware time. The owned runtime stays dormant at default
      startup.
      Status 2026-10-24: WP3 largely done and dormant; WP6 Lua owner (`runtime_owner.lua`,
      `runtime_vhid.lua`, read-only ports) and WP7 owned deploy done, dormant behind the hidden
      `[karabiner] runtime = "owned"`; one-click Debug field checks shipped (lease, owned runtime
      dormancy, network, 30 s key accounting). Left: WP5 artifact manifest (hosted macOS run), a
      closer for another running Karabiner, the production capture owner, the Swift lease worker's
      owned CLI path, who starts the Console (Lua or `InstalledPhysicalSourceBridge`: duplicates
      otherwise), `UninstallWorker.swift`, the karabiner_model diff 16.0.0 to 9312593e, WP8-WP10.
      Next: the maintainer sends the `Field check result:` log lines from the Mac.

## Big item 3: Windows input-hook architecture (items 49, 91, 50)

- [ ] **49. Keyboard-hook order.** [PHYS-W] [CODE] AutoHotkey removes and reinstalls its low-level
      hook around SendInput, so hook order is undefined. Record the real order before and after a
      SendInput rehook; audit terminal capture against KLE, dead-key, digit, profile, tap-hold,
      combination and script-shortcut consumers (down, repeat, up, owner change while held, pause,
      reload); finish event-specific capture and replay and modifier ownership (source pin,
      authenticated event stream, non-hook handler conversion, chained/repeat semantics). Regenerate
      the DLL and manifest only through the official MSVC generator; check the patches in
      `docs/handovers/2026-10-12-dev-consolidation/` against the tree first.
      Measured on the maintainer's PC (Debug > Record keyboard hook order, 2026-10-24): before a
      SendInput the test hook is first; after it the AutoHotkey hook is first, so SendInput does
      reinstall the AutoHotkey hook in front of any hook installed earlier. SendEvent does not
      (item 50: hotstring output already uses SendInput at level 0, so it is exposed to this rehook). Consumers that rely on their own hook staying ahead of AutoHotkey's (the
      native nav owner DLL, item 91) lose that position at the first SendInput of the other paths.
      Consumer audit:
      [windows-input-hooks-items-49-50.md](todo-agents/windows-input-hooks-items-49-50.md). Left:
      decide per remaining SendInput consumer (text sender, HSE dispatch) whether it can avoid
      SendInput or make the consumer order-independent (single-hook/RawInput source, needs an MSVC
      DLL and manifest); the terminal-capture hardware list; the `SetWindowsHookExW` string in the
      exe for antivirus (the AV-surface gate allows it).
- [ ] **91. Simultaneous and first-key hold arbitration.** [CODE] Integrate with the
      single-hook/RawInput source (needs a genuine MSVC DLL and manifest pair); [PHYS-W]
      held-alone-then-joined order, AltGr hook provenance.
- [ ] **50. SendEvent against SendInput.** [PHYS-W] `SendMode("Event")` is set, yet the hotstring
      send/dispatch, text sender and config I/O still call SendInput. Measure expansions, pastes and
      predictions (latency, lost or interleaved keys) before choosing.
      Measured on the maintainer's PC (8 repetitions per scenario, all exact, 0 lost, 0 interleaved in
      both modes): expansion median 50.6 ms (SendInput) vs 136.8 ms (SendEvent), prediction 56.1 vs
      191.0 ms, paste 3.6 vs 3.8 ms, a concurrent key during the send 201 vs 282 ms. \*\*Finding
      (2026-10-24, real engine on the maintainer's PC): hotstring expansion already used SendInput
      (`HSE_DispatchMatch`); there are no native `Hotstring()` registrations left, so a hotstring's
      output is final on every driver and does not trigger another hotstring (the comment on
      `SendMode("Event")` described the retired native engine; `SendMode` now only affects `Send`,
      `Click`, `MouseMove`). One real bug fixed (0c85debc93): the Space tap-hold completed a trigger
      from its level-2 thread, and with another AutoHotkey hook SendInput fell back to SendEvent, so
      the burst re-entered the watcher and cascaded (final text `foo qbar qzz` instead of
      `foo qzy `); all engine output now goes at level 0. Deliberate cascading is built (858c9aa, 0746b18c86):
      `hotstrings.cascade_max_arrows` counts arrows (1 = one expansion, 2 = a > b > c), default 3,
      range 1 to 10, the whole chain resolved before one send (one SendInput burst on Windows), a rule
      fires once per chain, a link fires only where typing the same text would; the typed delimiter
      lands once after the final output unless the user marked it consumed (★ ships consumed).
      Space tap completes an end-character trigger like a plain space on the three drivers (Windows
      already via `TextPressKeyFed`, Linux pinned by 504ee63, macOS emits a native space).
      `test_hotstring_output_is_final.ahk` is already in `run_all.ahk`. Left: on each OS type `fb` + Space,
      Enter and ★ with the abbreviation and brand packs, at 1, 2 and 3 arrows, consumed and not.
- [ ] **Per-layer layout composer.** [CODE] Done on the three OS (docs/layout-composer.md): shared
      model, page, 21 locales, Windows host, macOS and Linux install paths, tests, one-click Debug
      "Test the composed layout". Left: typing the composed layout on a real keyboard on each OS.

## Wave 2: mid-size work

In progress (agent), October 22:

- [ ] **Windows config policy (items 33, 42) and the TOML parse cost.** [CODE] Per sub-item in
      [config-policy-33-42.md](todo-agents/config-policy-33-42.md); 33: Windows keyboard binding
      publication from its real input owner, macOS Hotstrings category authority, Linux retired
      API-provider reader, macOS Karabiner obsolete-leaf intent, Windows retired cleanup
      projections; 42: explicit `--config FILE.toml` watcher admission, Windows full-save comment
      preservation. Parse cost: every document-mode write parses source, expected model and final
      candidate, and every start pays two builds after ready; reuse one parse per transaction
      before adding any cache. **In progress (agent).**

Not started:

- [ ] **Ollama redirect policy and Go compile (decision 5).** [CODE] [CI] Code done (cda1e10c5e): an
      unresolved download host is left to the proxy or the native worker; private, loopback,
      link-local and CGNAT addresses and names resolving to them stay refused; the build recipe
      patches upstream `ValidateRedirectTarget`. The hosted Go cell (`go vet`, `go test` through
      `build-macos-managed-ollama.py`) passed on a throwaway branch (run 40021624397, see
      [ci-validation-2026-10-24.md](ci-validation-2026-10-24.md)). Left: the same cell on the final
      source before a release.
- [x] **54/81. Last three native Windows menu rows.** Done in 02b63912f1 (local): census Windows
      0, macOS 0, Linux 0. The default-section, file and folder submenus are renderer template
      children (`MenuRenderer_TemplateChild` reserves, `MenuRenderer_FillTemplateChild` fills,
      `MenuRenderer_RepaintTemplateChild` repaints only a child the renderer still publishes); a
      kept callback after a rebuild is now refused before any write. Left: manual check 17
      (installed menus, default choice after restart); the shared-tree census is red on Linux only
      while `linux/ui/menu/rebuild_owner.lua:39` (another agent's uncommitted edit) is in flight.
- [ ] **Ergopti-started Ollama behind a PAC proxy.** [CODE] Linux done (89d22d782c, fake-lookup
      tests). macOS in code (launcher role `--managed-proxy-route`, 06addb2e3f; per-origin route
      plan 1fd254d92e and 749e00c4c8); Swift compiled and tested on the hosted macOS cell. Windows
      is covered by the WinHTTP transport (62). Left: a real-PAC pull on the maintainer's Mac (Debug >
      Test network), the Ollama blob host inventory check, a `route_plan` step in the network check.
- [x] **Menu clicks during a reload.** Done (b0fb0f585b, c280aa4eaf, 8c4314524a, d8f6fbf1d2): a click
      is held during a reload and replayed with its intended state; a Reload click during a reload
      JOINS it (Linux and macOS; Windows in the standing-checks agent's work, see PAR entries); Linux
      reports a refused `load_all` truthfully; the ordered-pair test runs in 8 s.
- [ ] **AppImage self-contained.** [CODE] `.zsync` and update information are done (10c016e51f,
      6fb83014e3). Built on ubuntu:22.04 (glibc 2.35 floor, no bundled libc or loader, musl refused in words,
      tray closure kept); the build refuses a foreign loader or a staged C library (dce846a0bd). Left: hosted
      CI evidence of the Build and `install-linux` AppImage rows on the distro matrix.
- [x] **Linux `copy_selected_path` in a file manager.** Done (8edb31edba, d2a7bc9c5b, 3027faffd3: the
      AT-SPI active frame names the application under Wayland). Left: confirm the AT-SPI query on a
      real GNOME or KDE Wayland desktop. Unicode IDNs and a zoned IPv6 are searched, not opened.
- [ ] **Linux X11 window list.** [CODE] `getAll()` is covered by the Openbox receipts (962a25a973);
      confirm in the first hosted run. Flatpak: wmctrl is only a documented host program.

## Cross-OS parity, centralisation and constants (audit of 2026-10-24)

Maintainer rule: the same behaviour on Windows, macOS and Linux wherever possible, unless there is a
good reason stated in the menu reason text; everything that can be common lives in `_shared`
(hexagonal architecture: rules and ports in `_shared`, OS code only in adapters); every constant,
delay, colour and label has one declaration. Source: [audit](audits/2026-10-24-cross-os-parity.md)
(row ids `H1`, `R3`, ... refer to it); entries are `PAR-1` to `PAR-85`, stable ids. Rows tagged I in the
audit come from grep counts: confirm them before starting. Done and verified: about 35 entries (see git log); the list below is what remains. Decisions taken: PAR-7 shared multiplier, PAR-17 identical defaults with stated exceptions, PAR-19 implement on Windows and Linux.

### A. Behaviour that differs without a good reason (fix first)

- [ ] **Tests write the real user config.** [CODE] Fixed (the magic-key catalogue test, and both Lua
      runners now move a real HOME to a scratch dir, `_shared/lua/test/runner_home.lua`). The keystats
      tests own their HOME fixture (29b7c5a0fe). Left: on Lua 5.4 an `io.popen` child still sees the real
      HOME.
- [ ] **Retire the orphaned Windows gesture-notice entries.** [CODE] The gesture status submenu and notice
      are gone (dbc29c5077); the `gesture_conflict_dismissed.*` storage entries they wrote stay in user
      state. Remove them in a config migration.
- [ ] **Review the machine translations of October 25.** [I18N] New keys (gesture recommendation notes,
      cascade depth, tap-hold defaults, missing-program messages) are hand-written in French and
      machine-written in the 19 other locales.
- [ ] **PAR-6. Make the base expansion delay user-settable on all three.** [CODE] Done (a737049): the
      base is user-settable everywhere, section delays are stored as `delay_offset` or `delay_unlimited`,
      old absolute values migrate keeping the effective delay, shared vectors `base_delay_vectors.json`.
      Left: run the Windows corpus test on the PC.
- [ ] **PAR-8. Word delimiters in config leaves on Windows.** [CODE] Done: the consume choice is the
      leaf `[hotstrings.terminator_consume]` on macOS and Linux (76716e7); Windows writes built-in states
      through the live config writer and moves the old override strings at boot (2d734b6). Left: run the
      rewritten AHK tests on the PC (never executed); no menu toggle for built-in consumption on any
      driver; macOS and Linux still ignore user delimiters when deciding a repeat.
- [ ] **PAR-12. Token streaming reason.** [CODE] Done: reason text rewritten in 21 locales and the key renamed
      `token_streaming_unvalidated_on_windows`. Left [PC]: enable the row on Windows after a live Ollama check.
- [ ] **PAR-14. Check-only fallback when the GitHub API is blocked: Windows.** [CODE] Linux and shared
      pieces done (28bdd5a5d9, vectors `check_only_vectors.json` and `list_cache_vectors.json`). Windows
      needs the Atom fallback in `core.ahk` plus an AHK feed parser, then a reseal of the sealed updater
      sources (only when `run_all.ahk` has no foreign hunk).
- [ ] **PAR-15. Tap-hold thresholds.** [CODE] Done: exact per-key thresholds pinned, one one-shot timeout
      (macOS read 3000 against 2000 ms), Linux holds the key's own side. macOS reads the shared per-key
      thresholds too (8cb8f04); one fallback `default_activation_ms = 200` (macOS was 250). Left: Windows
      still holds a 0.2 literal pinned to it by a gate; check the Karabiner JSON on a Mac.
- [x] **PAR-19. Pause and resume of the layout, implement on Windows and Linux (decided).** [CODE] Done on
      the three OS (shared `pause_switch_policy.lua` and contract; Linux gsettings and `setxkbmap` adapter;
      Windows `pause_layout_switch.ahk`). Left: a live check on GNOME, X11 and Windows.

### B. Missing features on one OS

- [x] **PAR-21. Linux LLM parity batch.** [CODE] Done: per-app trigger disabling (5b66b7e761), min/max
      words rows, model delete (`http_client.delete_owned`, `model_delete.lua`), warmup (`warmup.lua`), a
      separate AI typing context with `llm.generation.reset_on_nav` (e934ae45c8, shared `context_buffer`).
      Private expansions clear that context; macOS and Windows are being checked for the same exposure. AI off
      disarms the automatic agent mode and every AI key (7735e6b, 47ca337, bc2048765a).
- [x] **PAR-22. LLM telemetry on Linux.** [CODE] Done: generation, suggested, dismissed, accepted rows in
      `events_llm`, Ollama token counts (928aeffd43), remote-provider tokens and cost through the shared
      `remote_response_classifier.lua` and `remote_usage_vectors.json`. Left: check the dashboard cost with a
      real provider.
- [ ] **PAR-30. Sign the Windows and Linux update assets.** [CODE] [CI] Done: ECDSA P-256 detached signatures
      over a record of asset name, size and SHA-256, signer and reference verifier
      (`tools/build/update-asset-signature.cjs`), Linux verifies with OpenSSL, Windows with CNG, shared
      vectors, CI signs the Windows exe and publishes the `.sig`. Left: call the verification in the Linux
      manager's transfer flow and the Windows `release_install`/`self_update` path (enforcement `"off"` until
      the maintainer provisions the key: five steps in `docs/tooling/update-signing.md`), then flip it to
      `"required"`.
- [x] **PAR-34. Mouse metrics, event families and app-category store on Linux and macOS.** [CODE] Done:
      Linux pointer counters and the window, session and system families (4947f7a445); one
      `{schema, version, apps}` category file shared by macOS and Linux through
      `_shared/lua/keystats/app_category_store.lua`, Linux importing its old SQLite rows once (94e7ed0b4a).

### C. UI-only gaps, reasons and docs

- [x] **PAR-37. Platform reasons for restrictions.** [CODE] Done: every restriction has a reason, the ratchet
      is frozen at 0; the drafted reason texts in 20 locales still want a native review.
- [x] **PAR-40. Unify user LLM profile storage.** [CODE] Done: one `llm.user_profiles` envelope on the three
      OS (a6f0fd8ad9, manifest rows d6146eb82b, 300aa8c4a6). An older macOS `[llm.profiles] user_profiles`
      array is imported on load and deleted by the next save (0146a938c5). Left: check on a real Mac that an
      old config keeps its profiles in the menu.
- [ ] **PAR-41. One shortcut data model.** [CODE] Design note written
      (`docs/design/one-shortcut-model.md`, 4ca41ed2e9): one action slot per chord with neutral role-based ids.
      Done on macOS and Linux (sixth integration batch): schema v15 `v14_to_v15` migration of the slots and
      Ctrl-letter switches, role table with per-driver families, manifest slots, both drivers adopt the role
      names, migrated-config binding proof, AHK fixtures pinned to v15. Left: the release blocker above
      (`rename_prefix` for parameters, PC first), the Windows adoption, macOS `ctrl_g` to `open_url` later.
- [x] **PAR-43. Duplicated per-OS prompt strings.** [CODE] Done: `max_words`, `temperature` and the port
      dialogs (fb1aa4d934); one shared `menu.llm.server_port_label` row caption through `caption_getters`
      (`mlx_port_label` retired, `ollama_port_label` kept for AHK); `delay_prompt` and `debounce_prompt` stay two
      keys on purpose (different accepted input), reason documented (3f885f03d1).
- [x] **PAR-44. Reset error texts on macOS and Linux.** [CODE] Done: shared `config_reset_failure.lua`
      composes `dialog.reset_defaults.reason.*` for the macOS (`ui/menu/init.lua`) and Linux
      (`ui/menu/menu_builder.lua`) restore and clear rows; `reload_refused` has no entry there because they
      reload nothing.
- [ ] **PAR-45. Notifications: one behaviour for toggles and refusals.** [CODE] Done on macOS and Linux
      (shared `feature_notice.lua`, Linux quit refusal). Left: Windows `NotifyFeature(label, enabled)` around
      `NotifierSend` at the same call sites, and a Windows quit-refusal path firing `notify.quit_refused`.
- [x] **PAR-48. Review values equal to English in each locale.** [CODE] Done on `tmp/wip-todo-ag`: 95 keys
      translated in 19 locales, sticky and leftover labels, a shrink-only gate in
      `test-locale-catalogue-complete.cjs` with `tools/lint/locale-identical-to-english-allowlist.json` and
      `tools/locale/report-identical-to-english.cjs`. Left: a native review of the long `ui_typing.tooltip_*`
      texts; on the PC re-run the Windows menu caption tests (`menu.llm.backend_unknown` changed).
- [ ] **PAR-52. Release notes on macOS and Linux update windows.** [CODE] Done on macOS and Linux
      (80a5a650a6): shared `release_notes/pane.js` in the `update_check` page, repository-only links. Left:
      the Windows host (section "Windows side"), a visual check on a Mac and a Linux desktop.

### D. Instrumentation and diagnostics

- [ ] **PAR-53. Bring HotPath-style slow-segment logging to macOS and Linux.** [CODE] Done (shared
      `hotpath_segments.lua`, always-on Linux spans, one warning per segment per 10 s). Left: nesting
      attribution (Windows has it), the threshold question.
- [ ] **PAR-54. PhaseStats and child-process timing.** [CODE] Done on macOS and Linux (`process.<program>`,
      `toml.parse`, `menu.rebuild`, `boot.stage`, `boot.stage_cpu`). Windows: port `phase_stats_core.lua` with
      the same phases (`boot_profiler.ahk` already measures stages).
- [ ] **PAR-55. Crash reports: one content, one cap, one notice.** [CODE] Done on macOS and Linux (shared
      `crash_report.lua`, vectors `diagnostics/crash_report_vectors.json`, 20 newest kept). Left: Windows
      `crash_report_worker.ahk` adopting the same fields, names and cap.
- [ ] **PAR-56. Log-volume metrics on all three drivers.** [CODE] Done on macOS and Linux (per-level,
      dropped, suppressed and collapsed counts in the shared logger core, on the interval evidence record).
      Left: Windows `_LoggerEmit` counting the same seven figures in the same order.
- [ ] **PAR-57. Retention read from timings on Windows.** [CODE] `logger.ahk:112` is a literal 14. Read
      `Timings` and extend `test-logger-scalars-single-source.cjs`. Audit G5.

### E. Tests and corpora

- [ ] **PAR-58. Windows consumer for the shared Lua contracts.** [CODE] 105 contracts (about 940 cases)
      run on macOS and Linux, none on Windows. Convert the highest-value ones (`config_scope_*`,
      `toml_*`, `menu_*`) to JSON vectors and replay from one AHK consumer per family. Audit test
      item 11, section 14. Lua side done: 302 JSON vectors replayed by both drivers; the ledger
      (`tools/test/test-contract-vector-ledger.cjs`) classifies 288 Lua sites, 13 data-driven and 275 kept in
      Lua with a reason code. Left [PC]: the AHK consumers per family.
- [ ] **PAR-59. Corpus replay gaps.** [CODE] Done on macOS and Linux (file warnings, route plan, GET
      redirects, document lease; the download-document contract is Linux-only by design). Left: Windows
      consumers of `http/get_redirect_vectors.json`, `native_presentations/original_captions.json`,
      `route_plan_vectors.json`.
- [ ] **PAR-60. Hotstring `family_samples.json` plus chaining, synthetic-output and erase vectors.** [CODE]
      Done on macOS and Linux (`family_samples.json`, `sequence_vectors.json`, `cascade_vectors.json` in both
      E2E harnesses). Left: a Windows `family_samples` consumer.
- [ ] **PAR-61. Tap-versus-hold decision corpus.** [CODE] Done on macOS and Linux (`decision_vectors.json`,
      23 vectors, shared contract). Left: a Windows consumer through its tap-hold engine.
- [x] **PAR-62. Contract tests for shared modules no test requires by name.** [CODE] Done (ab086f5020):
      direct contracts for nine shared modules, each proved red by a mutation; personal_model's
      `unowned-personal-section` stays covered by the writer corpus only.
- [ ] **PAR-63. Remaining 2026-10-18 test items.** [CODE] Done on Linux and macOS (personal-info editor,
      field masking, native-only number row; model records, downloads, keystats corpus and the toggle gaps
      were already covered). Left: Windows dynamic hotstrings, Windows root runners and the
      `test-driver-tree-parity.cjs:19` exclusion.
- [ ] **PAR-64. Installed-record and layout corpora on Windows.** [CODE] Windows replays 1 of 4 files.
      Replay extensions, preservation and updates. Audit L6.

### F. Centralisation and hexagonal architecture (value order)

- [ ] **PAR-65. Extract the LLM request plan to `_shared/lua/llm/request_plan`.** [CODE] Phase 1 done on macOS
      and Linux: `debounce.lua` and `batching.lua` with request-transcript vectors (`_shared/tests/corpus/llm/`)
      replayed by both drivers (48be669def, 7442ab5edd, d18f573791; the decisions of October 26 are on
      `work/todo-af`). Left: the Windows twin replaying the vectors, then the HttpClient, TimerScheduler and
      TooltipRenderer ports, the live prompt, the token budget, the info-bar text and the agent flows. Audit R1.
- [x] **PAR-66. Move the menu frame builders to `_shared/lua/menu/frames`.** [CODE] Done on macOS and Linux:
      `magic_frame`, `parent_source` (Debug, Configuration, Metrics, About) and `personal_info_source`, with
      contracts replayed by both drivers; the source-pin gates own the shared text and pin only the driver
      ports (`tools/lib/menu-parent-source-gate.cjs`). Windows has its own AHK reader.
- [ ] **PAR-67. Shared keystats query catalogue and walker.** [CODE] Reader catalogue, shared walker and
      aggregation vectors done; `meta.rev` shared and a gate refuses SQL spelled by hand in both Lua drivers.
      In progress: write-statement catalogue with typed slots (agent). Windows: adopt it later.
- [ ] **PAR-68. Hotstring override parser into `_shared` on `toml_codec`.** [CODE] Done on macOS and Linux
      (shared `hotstrings/overrides.lua`, `override_parse_vectors.json`). macOS now reads a duplicate key or
      header as invalid TOML (was last-wins). Left: Windows `_ParseOverrides` replaying the vectors.
- [x] **PAR-69. Shared ownership protocols.** [CODE] Done: `scope_owner.lua`, `storage_owned.lua`,
      `error_dialog/core.lua`, `owned_timer_slots.lua`, each with a contract (4947f7a445).
- [x] **PAR-70. Factory per macOS/Linux infra shim.** [CODE] Done on macOS and Linux: `timings`,
      `manifest_reader`, `text_cipher`, `text_migration`, `config_backup`, `user_code` share their policy in
      `_shared/lua` with contracts replayed by both drivers. Windows keeps its own AHK implementations.
- [ ] **PAR-71. Finish the route-plan rollout and make `proxy_policy.json` the codegen source.** [CODE] Done on
      macOS and Linux (generated shell and Lua precedence, Linux lookup limits from the policy, drift guard).
      Left, Windows: generated or read AHK copy in `http_client.ahk` (reseal), the route-plan consumer
      replaying `route_plan_vectors.json`, the native lookup limits from the policy.
- [ ] **PAR-72. Shared registries and catalogues.** [CODE] Done: layout registry store, shortcuts
      catalogue, healthcheck report runner, agent learning store (daee88e48d..e105336d39); gesture
      direction and temperature were already shared with vectors. Left: the registry install/select flows and
      the healthcheck bridge stay per driver (different converters and bridges).
- [ ] **PAR-73. Collapse generated per-driver artifacts and tap-hold timeout duplicates.** [CODE] Done:
      `[hs_timeouts]`, `action_catalogue.lua`, and `features_manifest.lua` (one shared
      `_shared/lua/features/manifest_data.lua`, eae6f45708). Left: `config_template.toml` (decision pending).
- [ ] **PAR-74. Config-key and command-id constants by codegen.** [CODE] Generate constants from
      `config.schema.json` and `menu_manifest.json` for AHK, Lua and JS; lint raw literals such as
      `private_filter_enabled`. Audit R10. Lua and shared Lua done (567 sites to 0). Left: 1243 AHK and JS
      literals in the shrink-only `config-key-literal-baseline.json`.
- [x] **PAR-75. Shared Lua helper modules and a redefinition lint.** [CODE] Done: every inline site burned
      down (baseline `{}`), basename detector added; the allowed exceptions are listed in the gate's `ALLOWED`
      list (two URL segments, the Linux worker `arg[0]` check, boot-time dirname splits).
- [ ] **PAR-76. Long refactors, plan before starting.** [CODE] Generate the AHK config-migration op table
      from `migrations.toml` (R17); extract menu row-ordering rules to data (R18); pure hotstring
      injection plan (R26); FileSystem port spec for lease/atomic write (R33); canonical `.keylayout`
      parser (R23); Windows updater `check_session`/`rate_limit` vectors (R25).
- [x] **PAR-77. Remove platform branches from shared UI JS.** [CODE] Done: hosts pass capability flags
      and `executableSyntax`; `test-shared-ui-no-platform-branches.cjs` guards it.

### G. Constants, delays, colours, labels (value order)

- [x] **PAR-78. Timing registry liveness and duplicate-name gate.** [CODE] Done:
      `test-timings-registry-liveness.cjs`, the duplicate ratchet `test-duplicate-constant-names.cjs`, and source
      pins for copies that cannot read the registry (ed257e285a).
- [ ] **PAR-79. Replace repeated timer literals with registry keys.** [CODE] Done on Lua and JS
      (ed257e285a): registry keys for the repeated delays, the literal gate in `test-fast-timer-inventory.cjs`
      with a shrink-only `timer-literal-baseline.json`. Left: 139 AHK sites (`STALE_TEMP_MS` x5, gesture poll
      `-100` x6, safety flush `-2000` x3...), ~25 Swift `usleep`, 40 baselined Lua/JS sites.
- [ ] **PAR-80. `[limits]` section for byte caps.** [CODE] Done (7376321788): `[limits]` with the process
      output, declaration file and changelog caps, a retyping gate with a shrink-only baseline. Left: the AHK
      caps, `MAX_TEXT_BYTES` and `MAX_BODY_BYTES` (public module fields).
- [ ] **PAR-81. Theme tokens and palette codegen.** [CODE] Done: `_shared/ui/theme.css` linked by the
      shared pages; `_shared/data/native_theme.toml` generating `_shared/lua/native_theme_data.lua` for the macOS
      and Linux palettes; the dead macOS download-window page removed; hex lint with a shrink-only baseline
      (`tools/lint/hex-literal-baseline.json`, 53 files). Left: an AHK emitter replacing the typed palette in
      `hcw_helpers.ahk` (then retire `test-color-presets-parity.cjs`), and moving the baselined literals onto
      tokens with per-page pixel diffs.
- [ ] **PAR-82. Hard-coded UI string gate.** [CODE] New `tools/test/test-no-hardcoded-ui-strings.cjs`
      (TrayTip, MsgBox, alert, title literals fail unless allowlisted; reuse
      `tools/lint/audit-gui-titles.cjs`), including the Linux `install.sh` echo table. Audit K6, I9.
- [ ] **PAR-83. Identifiers and hosts in one file.** [CODE] Done for Lua (948ebef074, bb1899206e):
      `_shared/data/identifiers.json` generating `_shared/lua/identifiers.lua`, typed copies held to a
      shrink-only baseline. Left: an AHK emitter and the AHK, Swift, shell, Python and JS-page copies.
- [x] **PAR-84. Closed enums for reasons, phases and log tags.** [CODE] Done: `vocabulary.json`, the scan,
      the census and the gate in `test-logger-scalars-single-source.cjs` with a shrink-only free-form baseline.
- [x] **PAR-85. Tooltip dequeue and ring constants.** [CODE] Done: dequeue timings single-sourced in
      `tooltip/constants.toml [timing]` (`test-tooltip-timing-single-source.cjs`); the 64/32 rings are
      unrelated (keystroke ring, phase attribution ring).

## Backlog (one line each)

Added October 22 (from the agents' reports; details in their commits):

- [ ] **macOS swallowed-keys check on v1.0.6.** [PHYS-M] The fixes (03a2c2fa4b, d026f3e024,
      a414e83fb7, 19fa9fa872, 89cbcae90b, 9b500a9e8c, c21e920d7e, bb6fcc2cc2) shipped in v1.0.6;
      they need a Mac day of typing with the `key_event_health` counters; handoff in
      [issue99-karabiner-input.md](todo-agents/issue99-karabiner-input.md).
- [ ] **Keystats rename leftovers.** [CODE] The rename is done (180a53e4de, 1 283 files, 579 paths). Left:
      the comment in `macos/apps/Encryptor.app/Contents/Resources/Scripts/main.scpt` (a compiled
      script: recompile on a Mac); declare each persisted name once and make tests read it instead
      of pinning spellings, so the next rename is cheap.
- [ ] **Issue #101: Mac follow-ups.** [PHYS-M] Fixed, to confirm on the Mac with the next release:
      ATS key so the URLSession can fetch an `http://` company PAC (c0c29cd8ab); direct route when the
      PAC lookup names no route (719c7fcd76); no retry of a refused route (ace928dc1c); the lookup now
      names its failing step (363a63f79d: `native_proxy_budget`, `native_pac_download`, ...); lease
      line cap judged per line (5deb892d58); Ollama 412 upgrade request shown (08aaeaf3c2);
      diagnostics PAC probe on the three OS (f798aae1f9); one-click Debug checks (lease, owned
      runtime, network, 30 s key accounting). Left: (1) read the Mac's next log lines `Slow ingest
tick`, `Slow preferences save` and `Field check result:` to name the dominant main-thread
      phase before slicing it; (2) an explicit proxy override field; (3) local server probes (oMLX,
      Jan) all answer "Network request failed"; (4) `keymap/utils.lua` ignored-window TTL probe
      (1 s): bound it only after measuring the AX call time (secure-field cache); (5) rebuild the
      inverse oracle of `macos_native_http_receiving_facts_test` (red since 719c7fcd76), compile the
      Swift on macOS CI, add Go table cases for the new stages; (6) the network check's digest step
      is skipped (HEAD only).
- [ ] **macOS input follow-ups (swallowed keys).** [CODE] Done: late keys pass through (ed2d9fe65c),
      AXValue read once per burst (34765cde7c), no error window for a lease failure that recovered
      within 60 s (fcf4af85dc), `key_*` counters in the diagnostics (6f2daed2e5). Lease token reuse
      was analysed and refused (ADR 012): a reused token could never reach READY because the
      revocation tombstone is monotone; reuse needs a native acknowledged rearm, decided NOT to
      build for now. The next Mac log carries `Lease token decision=` and `written in N ms`: if the
      write is short, keep it; if long, shrink the 743 KB file instead.
- [ ] **Linux correction parity remainders.** [CODE] Done (06bbbe5985): Backspace pops the word, erased
      n-grams get `e`, synthetic output chains. Left: erased and synthetic vectors in the shared corpus
      (needs the AHK and macOS replayers); Windows word separators are wider than Linux's three.
- [ ] **Windows updater -File workers: real update check.** [PHYS] Install a build with 5d6beccf83
      by hand, then update from it to the next release: the exe is replaced and restarts, the
      three scripts are in `%LOCALAPPDATA%\Ergopti\vendor\`, the PowerShell command line shows
      `-File ...ergopti_updater_staging.ps1` and no `-EncodedCommand`.
- [ ] **Config policy remainders (33, 42).** [CODE] Done: macOS category authority (80c18d9cc2),
      explicit `--config` watcher topology (3dd420292d), `api_entries` retired rows (c03762d27b),
      parse cost (e525cd6615). Left: the physical keyboard slot parameters
      (`keyboard__win_SC03A__x`), the Windows `api_entries.json` per-row warning, the bare-root and
      unknown-`[[x]]` cleanup offers, a reseal of the updater original source after e525cd6615
      once `run_all.ahk` is clean, and the Linux reload as a daemon restart (the control protocol
      needs a pending record that can name an unknowable successor pid; recommended: a TTL-bound
      pending record completed by the successor).
- [ ] **Linux CI installs packages inside short test steps.** [CI] 18 steps moved and skipped when the
      suite is deferred (c52cb916a7, 285d3363a1). Left: `Qualify three actual XI2 property cookies`
      and `The whole daemon, live` (their text is pinned), the 35-minute and 18-minute steps, the
      other jobs, and hosted validation.
- [ ] **macOS "Quit did not end both processes within 10 s".** [CI] Cause found: the Quit AppleEvent
      timed out while the launcher log had been silent since startup (run 39850037912); the gate now
      names the surviving process and keeps the failing attempt's evidence for 7 days
      (b2b5bb149b, bf05488dfb). Read `launch-gate-failed-*` if it recurs.
- [ ] **History hygiene of October 22.** Commits with another agent's message, already on dev:
      c6db589c76 (macOS cipher argv fix under a README subject), 90da28c725 (config snapshot test
      under a CI subject), 18ca214ead (also deletes ten handoff files), 6d9c659 ("applied for now"
      instead of "apply now"). Keep, or rewrite dev once with a lease: maintainer's call.
- [ ] **Signing and antivirus: maintainer actions.** Apply to SignPath at signpath.org/apply (the
      HubSpot form does not load in an automated browser; answers in
      [signpath-foundation-application.md](todo-agents/signpath-foundation-application.md)), submit
      the Defender false positive, and ask the tester for the exact block page.

- [ ] **36. Windows updater production coupling.** [CODE] The "original23" collector stays inactive
      (`docs/handovers/2026-10-12-group6-ci/INACTIVE-ORIGINAL23-SOURCE.md`) until enrolled.
- [ ] **62 (macOS and Linux).** [CODE] Packaged paths resolve every request and redirect natively;
      the environment fallback now resolves each origin of the client inventory and refuses two
      different relays (1fd254d92e, 749e00c4c8). Left: confirm the Ollama blob host on the Mac,
      the Go twin `_shared/go/route_plan` in a CI cell, a Linux wrapper test.
- [ ] **CI duration** ([target](memory/workflow-and-verification.md)). Flatpak runtime cache and a
      bounded retry are in (07a601c97e plus the retry commit); confirm on a hosted run (target under
      5 min). Windows Integration still adds 4-5 min on the critical path; the macOS lane (about 58
      min) must stay within the five-runner budget.
- [ ] **CI structure.** [CODE] Slowest-test summary and `tools/ci/run-timing.cjs` shipped
      (e1aa4a5f48, cab1170446). Left: a per-step elapsed summary inside the CI run itself.
- [ ] **Test parity across the drivers.** [CODE] Done: Windows CapsWord behaviour tests, dynamic
      hotstrings, macOS audit-named tests renamed, neutral-installation gate. Left: Windows replay of
      the shared HTTP-redirect, timer-ceiling and key-chord corpora (needs a decision to build those
      policies on Windows), conversion of Windows source assertions to behaviour (audit item 14).
- [ ] **5.** [CODE] Linux layout and number-row scope participants composed with the real runtime
      producers; Linux/macOS numeric-owned Script aliases need an explicit snapshot contract.
- [ ] **116. Guided third-party validation report.** [PHYS-M] macOS `field_check_toolchain` landed
      (timer, Shortcuts, Homebrew, Karabiner signature); needs a run on a real Mac. Package
      provenance beyond the signature check is open.
- [ ] **139. Personal identities in logs.** [CODE] Done: email, URL-credential, foreign-profile
      rules (5ef12e8a2a) and config-directory name masking (20e845692b); opt-in redacted day log
      attachment (1c6f891ed3, item 138). Left: emitter-side pack labels (the TomlLoader SUCCESS line
      prints the pack label; check the macOS and Linux loaders), write-time masking in the three
      loggers, historical logs on disk stay unmasked (the collector masks at export), GitHub field
      editability after a form reload needs a real draft.
- [ ] **142 gaps.** [CODE] Windows: a Reload click during a pending reload now follows the join rule
      (standing-checks agent); no hash-check requirement identified for the Windows client. Linux:
      the reload is in process; see "Config policy remainders" for the protocol decision.
- [ ] **13/35.** [CODE] Enrol the complete guardian acceptance collector in main CI.
- [ ] **93. Linux ordered pairs.** [CODE] XI2 property cookies proven on Xvfb in WSL; the saved Xi
      packet is retired (libXi as a package dependency declined by the maintainer). Physical input
      and the XKB/XI2 server-state join need a real kernel and desktop.
- [ ] **97/98.** [CODE] Native physical-position capture and all-owner collision admission; Linux
      identity needs the MediaStore device contract. The star setting migration is dropped (no
      users, no legacy migration).
- [ ] **106.** [PHYS-M] Genuine Apple Shortcuts invocation with bounded cancellation; only the
      refusal-in-time probe exists (in 116).
- [ ] **107.** [CODE] macOS forced output, Linux input+XI2+writer join.
- [ ] **108.** [CODE] Item 97's collision/source/modifier/output joins.
- [ ] **109. Branded debug GUI.** Blocked: AHK 2.0.26 has no supported invisible
      Variables/KeyHistory snapshot.
- [ ] **120 (formerly 46/47/48).** [CODE] Broad Ollama process termination on macOS stays debt (the
      other clauses of 46/47/48 were stale or by design; their context was lost and the maintainer
      retired them).
- [ ] **L115.** [CODE] Provider error envelope guard: not reproducible under WSL LuaJIT (6 of 6
      runs pass); leave it or close it.
- Optional, not planned: XKB angle-name gaps and raw-input grammar (L118-L120); concurrent JSON
  backup replacement (L52, L60); ALSA fallback (L63); multi-group XKB recovery (L100); a real
  `Comments` exe field through a version `.res` resource.

## Maintainer checks

Record the commit, OS build, scale, layout and emulation state; report pass, fail or not executed
per line. Use a disposable profile (`paths.toml` pointing at a scratch folder) for anything that
writes configuration. Reload the driver from the working tree for dev-only fixes.

### After v1.0.5 (actions)

- [ ] Post `/retest` on AppImage/appimage.github.io#10422 from **PowerShell** (Git Bash rewrites
      it): `gh pr comment 10422 -R AppImage/appimage.github.io --body '/retest'`; read the bot's
      screenshot (status window and tray menu, 98d41e630b) and warnings.
- [ ] Airbus tester (Netskope): retry the `ErgoptiPlus.exe` download and report T1-T4
      ([matrix](todo-agents/windows-exe-flagged-by-proxy.md)).
- [ ] Give the v1.0.5 SHA-256 to VirusTotal; submit it to Microsoft Defender as a false positive if
      flagged.
- [ ] Number-row testers (October 13 and Discord): retest with their exact setup (native layout,
      emulation and row switches, CapsLock, outputs in the three modes); fix only a confirmed
      discrepancy. Key-combination testers (October 15): confirm c89d74eb, else ask for
      `[KeyCombinations] Pair`, `AHK drop detected` and `Menu command refused` lines.
      Priority-100 tester: confirm uppercase output (cf29c35e5f).

### Windows PC

Fixes of October 22 (dev, after v1.0.5):

- [ ] **Win+S open target** (ec1c4105d9): automated checks cover the target resolution; by hand only
      what leaves the driver: a browser, the mail client, Regedit with its prompt, Settings, a web
      search (steps in [windows-maintainer-checks.md](tooling/windows-maintainer-checks.md)).
- [ ] **Backspace word start**: the engine-buffer cases are automated; by hand only Windows Terminal
      with Claude Code, Notepad Ctrl+Backspace, the browser Ctrl+L, and AltGr+Backspace on an
      AZERTY-style AltGr and a Kana layout.
- [ ] **Tap-hold and key-combination pickers**: automated except the native pair popup itself.
- [ ] **Versions tabs**: automated except the Retry button.

Standing checks:

1. **Seven-page wizard** (item 7): fresh, existing and moved folder; every page, Cancel, Finish then
   restart, rerun; No against recommended choices; WebView rendering and persistence; the layout
   step's controls never reload the UI.
2. **Clear and Restore** (item 5): per category and global, then restart; unknown and outdated keys
   preserved; personal hotstrings unchanged by Restore; exact backups; an external write refused.
3. **Number row and key combinations**: on AZERTY, US QWERTY and Ergopti, each ordering and
   edge-key choice, each row emulation switch, an inert choice ticked, greyed and suffixed « — non
   appliqué », the ² key; a pair assignment saved and reloaded.
4. **Installed build**: install, start, Diagnostics cold and reopened (UIA/render probes, cold
   WebView), Quit during a keystats flush, File/Exit and Windows shutdown with exit code 0;
   uninstall greyed on a source run. Item 101: capture the watcher/debt state if `watchers=0`
   recurs.
5. **Item 51 matrix**: arrows and both Shift+Tab over a multi-slot prediction move the marker once
   and wrap (also after reload, with `nav_modifiers = ctrl`, with a tap-hold Tab); footer "⇧G + Tab
   ou ↑/←"; bubbles and delayed expansions with emulation off and on; no "eeee"; one clipboard-log
   row per Ctrl+V; AltGr+Entrée/Suppr/Retour arrière/Échap script actions; AI menu; « Revenir à
   cette version » keeps a backup.
6. **Items 19, 49, 50**: tooltips near screen edges on Windows 10 and 11 at several DPI scales; hook
   order around a SendInput rehook; the send-mode measurement.
7. **Hotstrings** (items 34, 37, 102, 104, 105, 129): follow
   [GROUP2-WINDOWS-TODO](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md); with no
   Ergopti layout installed the shipped pack, suffix rules and magic-key repeat appear once;
   `update` never proposes `date`.
8. **Layout switching** (item 38): AZERTY with emulation to native Ergopti and back keeps AltGr
   usable without a reload, also on an AZERTY-style AltGr (LCtrl+RAlt) and a Kana layout.
9. **Touchpad registry** (item 13): values restored after OFF and removal; kept after a refusal.
10. **Managed network** (item 62): the twelve steps of the
    [Group 6 Windows handover](handovers/2026-10-04-group6-windows/README.md) behind a company
    proxy.
11. **CapsWord auto-off**: delays, the eight default delimiters, each pointer kind, the LAlt then
    CapsLock trigger.
12. **AI off (#97)**: no local server sweep, no AI hotkeys, a refused AI hotkey leaves the driver
    running. Item 143: time the AI toggle behind an unfinished startup (3.05 s on the smoke).
13. **Prediction chord (item 112)**: in Notepad each slot's modifier+digit inserts that prediction
    and its correction form; the shortcut column is right-aligned and muted.
14. **Item 114**: observe the resident process during a prediction-key (1-5) or AltGr+Enter stall
    and collect the Notepad stale-admission diagnostics before changing anything.
15. **Items 30, 46-48, 54/81, 63, 73, 88, 96-98, 107, 108, 125, 138**: physical magic key under
    emulation; a real local model (chat, download, consent, pause/resume/shutdown, HTTPS behind the
    system proxy); installed menus (captions, unavailable reasons, state after restart);
    brightness up/down and refusal without a backlight; physical-key labels after a locale change;
    prediction tooltip typography; emulation picker precedence and dead-state output; chosen
    physical positions and arbitrary outputs including dead keys; number-row and magic-key
    shortcut delivery; free-text translation dialog; diagnostic export copy, write, reveal and
    browser.

### Mac

- [ ] **Issue #100 retest** (after v1.0.5: 2353a72eed, 25411ee080, e57f4cce77): with Ollama.app and
      a PAC proxy, enabling the AI downloads the model; with the Ergopti menu held open, no lease
      timeout.
- [ ] **Issue #99**: `memory_pressure | tail -1` during lease errors; oMLX listed (DEBUG
      line `Local server 'omlx' probe answered ...`, else
      `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/v1/models` and
      `lsof -nP -iTCP -sTCP:LISTEN | grep -i omlx`); `Ollama bootstrap failed (exit=137)` with an
      external Ollama; which login item starts the second Hammerspoon; declining the download
      opens no error window. Details:
      [issue99-ai-startup-updater.md](todo-agents/issue99-ai-startup-updater.md).
- [ ] **Fixes of October 21-22**: tap and hold pickers (steps in
      [macos-tap-hold-action-picker.md](todo-agents/macos-tap-hold-action-picker.md)); tap delay
      row opens the AppleScript dialog, « Use global delay (…) » right below; Shortcuts group
      restore/clear; Ctrl+S open target (as on Windows, registry keys answer « Windows only »);
      Backspace word start (Terminal Return, `ab`, three Backspaces, `c★`; TextEdit
      Option+Backspace; Safari Cmd+L).
- [ ] **Item 38**: no "Lease-bound input startup failed" or spurious "Layout poll detected change";
      Right Option + Return/Delete/Backspace/Escape run script actions; no Python or Rosetta notice;
      MLX behind a proxy; Versions rollback.
- [ ] **Installed app**: 7 (Cocoa Finish, folder disagreement, native restart), 116 page, 120
      provider menu, 122 Diagnostics focus, 123 shared export, 127 VS Code bridge retirement, 13/35
      guardian registration and retirement on both architectures, 24 Login Items, 43 « Retirer les
      anciennes règles » on an upgrade, 44 CapsWord pointer cancellation, 126 trackpad gestures,
      111 two displays, 30 magic key on ISO and ANSI, 46-48 and 88 a real local model and the
      tooltip typography, issue 94 (tap-hold menu refusal, symbol-wrap clipboard, ISO/ANSI captured
      once), 119/130/136 MLX PAC download, code 74, Homebrew live upgrade.
- [ ] **Shell and file edge cases**: `pipefail` and `printf %b` under bash 3.2, the native HTTPS
      downgrade refusal, `hs.fs.attributes` on a FIFO, the read-only dashboard with a hot journal.

### Linux (no machine available)

Wizard (7) on Wayland, physical input, installed-daemon restart; real kernel capture (93); magic
key grab, injection and hotplug (30); tap delay row (zenity/kdialog), group restore/clear, open
target, Backspace word start (GNOME Terminal Enter, `ab`, three Backspaces, `c★`; gedit
Ctrl+Backspace; Firefox Ctrl+L).

## CI final acceptance receipts

Qualification-only items: each closes on a named green hosted or native run, recorded here. They are
not open software work.

- [ ] **16/38.** One complete non-release three-OS checkpoint on the final source (units, E2E,
      packaging, installation, launch) with exact receipts.
- [ ] **36.** macOS Package job: Sparkle install/refusal/retry/relaunch, both Brew positives,
      full-policy denial, Brew archive scenarios (the deny-removal AppleEvent positive needs a Mac);
      Linux Flatpak/AppImage installation and PAC/session/TLS delivery.
- [ ] **40.** Signed native execution of the eight Karabiner default/recommended/switch variants.
- [ ] **63, 71.** Brightness joined source; retired Metrics-window shortcuts across a three-OS full
      save and installed upgrade.
- [ ] **104, 105.** Common autocorrection sections (native Windows/macOS, per-section E2E, package;
      the 140-rule corpus is never regenerated from production); dynamic hotstrings on macOS.
- [ ] **34, 37, 102, 129.** Native Linux/macOS delimiter transactions; macOS packaging with both
      extension TOML files; Windows native cases and Fedora/Alpine ShellRunner fixtures; Linux E2E.
- [ ] **121, 123, 137.** AI Agent submenu composed-menu qualification; native Linux export
      write/close refusal; provider published before model loading (macOS).
- [ ] **30.** Linux tests of the physical magic-key notice (407db5fd50).
- [ ] **Carbon and daemon-report Swift.** Carbon fixture compilation and both-architecture
      receipts; daemon-report Swift allocation failures on Intel and Apple silicon.
- [ ] **CodeQL Go.** After the `native_http` Go module is published, re-enable Go and check a fresh
      non-empty analysis.
- [ ] **Native Windows TLS fixture.** Seven `native_tls` cases fail since Git 2.56 moved the SDK to
      ucrt64; the trust install stays at `before_add`. Cause not proved.
- [ ] **Full Windows AHK suite.** Never completed green locally (about 90 min single-threaded);
      shard it, never raise `_SUITE_MAX_TIMEOUT_MS`.
- [ ] **Intermittent fixtures.** Close each after it stays green, root-cause a relapse from the
      logged attempt: Linux window switch, cffi-lua clone, desktop-webview AI focus, Windows
      `config` group (managed-network budget, artifact curl relay), macOS Go
      `TestIdleDeadlinePhysicallyRetiresPeer`, macOS Swift
      `testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope` (failed once on macOS 26).

## Decided, do not re-raise

- **Delta updates (item 22)**: withdrawn by the maintainer; full signed downloads stay below 20 MB.
  Reconsider only if release size or measured repeated-download cost grows
  ([rationale](handovers/2026-10-04-parallel-containers/PARALLEL-WORK.md#delta-updates-decision)).
- **Report a bug has no review screen**: the report is reviewable on GitHub (October 21).
- **Not defects after native review**: L48, L83 and the release-notes CR handling on Windows; L30,
  L85, L88 and L18 on macOS.
- **Configuration file style (October 20)**: `config.toml` keeps the 5/3 blank-line style everywhere
  (templates and the Windows writer); `windows/_generated/config_template.toml` changes only
  through `npm run build:manifest`; the release list and its ETag persist across restarts.
- **Credentialed redirects** are not followed, by design (L42).
- **Unsigned stable Windows releases** are authorised until SignPath signing is integrated (item
  132).
- **The AHK suite watchdog** is not raised to make a run finish; shard the suite instead.
- **Obsolete configuration scalars** are preserved until explicit cleanup; ordinary saves refuse a
  colliding subtree (ADR-009).
- **Unicode general categories and graphemes** are out of scope for the metrics character classes
  (L137); there is no Lua 5.4 AT-SPI backend, the FFI needs LuaJIT (L67).
- **A stored layout or number-row choice is never rewritten** by a layout change: where it cannot
  apply it stays ticked, greyed and suffixed « — non appliqué », and applies again by itself.
- **Moving the Karabiner lease token out of the rule text** is impossible: Karabiner compares
  variables only to fixed values. Fewer recovery deploys need fewer lease failures first.
- **Do not deduplicate the macOS Swift launcher XCTest classes between E2E and Build.** The managed
  native E2E cells run the SDK, logger and daily-log cohorts on macOS 15 (Apple silicon and Intel);
  Build's full Swift run repeats them on macOS 26 (`macos-latest`). Skipping them in Build saves
  about 42 s of 364 s of test time (measured 2026-10-20, run 39388400901) and nothing on the
  critical path, and drops their only macOS 26 coverage. Job, lot and step names state each cell's
  macOS version, read from `HOSTS` in `tools/ci/macos-stage-roles.cjs`.
- **Windows unit shards are grouped by test category, not by duration.** A new test file with no
  category fails a gate; a minute more of wall time buys a CI whose red job says what broke.
- **Maintainer workflow**: partial work is delivered into dev after the feasible container or CI
  work, with native or device gaps documented here rather than holding a branch.
