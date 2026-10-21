<!-- docs/ERGOPTIPLUS_TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-21 midday. Latest stable:
[v1.0.4](https://github.com/adrienm7/ergopti/releases/tag/v1.0.4) (tagged 2026-10-21, nothing
deferred: every macOS native scope qualified). Open work only: a finished
item is removed, its lessons go to [docs/memory](memory/README.md), and the history stays in Git
(`git log -p -- docs/ERGOPTIPLUS_TODO.md`). Item numbers are stable and never reused. Groups follow
the [parallel work contract](handovers/2026-10-04-parallel-containers/PARALLEL-WORK.md).

Tags: **[CODE]** software to write or adopt; **[CI]** only a hosted or native CI run qualifies it;
**[PHYS-W]**, **[PHYS-M]**, **[PHYS-L]** needs a real Windows PC, Mac or Linux machine.

**Generic caveat, stated once.** Unless an item says otherwise, native macOS and Linux qualification
and every physical-device acceptance remain OPEN and their qualification flags stay false; portable
tests, containers and software-supplied events are never physical evidence. The maintainer has a
Windows PC (physical tests on request) and a work Mac (reproduce on CI first, then at most one short
command); there is no Linux machine.

## State on October 21

- **v1.0.4 is released** (bf419b8dd6, then 4a12db2fae) with no deferred scope, so the
  "next release with nothing deferred" plan is closed. A `Release-As: X.Y.Z` trailer now forces any
  later stable version (8b8d3abf77, documented in 11b07fc897 and in
  [memory](memory/workflow-and-verification.md#project-stable-version-release-as)).
- **Issues #84, #95, #96 and #97 are closed without a reply** (the maintainer's choice). Their open
  physical checks stay at their items: oMLX listing, ISO key left of "1", Karabiner lease timings and
  dropped letters, all on the Mac.
- origin/dev was green at 9432f4d963 (run 39596425717, preflight 39591820398 in 36 min); later pushes
  (163b8214cb and after) had their automatic CI runs cancelled on the maintainer's order to save quota, so
  run `gh workflow run ci.yml --ref dev -f os_lanes=all` once before the next release. The CI errors of dev stay owned by the
  coordinator.
- **Codex agents push directly to dev** with the maintainer's credentials. Fetch and rebase before
  any push; dev and main stay linear (no merge commits, answered October 21). Preflight before
  pushing dev: push HEAD to `tmp/preflight-dev`, run
  `gh workflow run ci.yml --ref tmp/preflight-dev -f os_lanes=all`, and push dev only after it is
  green.
- Landed since the October 20 evening, residual checks kept at their items: the clean CI layout
  (d1862ef26b..3ea8b6d69e); the Windows parity backlog (01b9d6aa2d..72d2125c5d) and the macOS one
  (45d74ee3e1..4fa3f50d54); Linux L69, L77, L103, L126 and the finite no-luv period of L105
  (84707de17c, c6896fac9d, c7178bb5bd, c876362759, a6e229a59f, d276bacfe0); the Linux metrics reader
  keeps NUL in its projections and credits a session a crash left open (1bdc2a31cc, b0381e5afa); a
  NOT EXECUTED outcome for AHK cases the host cannot run (edd13547d0).

## Handoff: work in flight (October 21, 16:45 Paris)

The maintainer's weekly quota is nearly exhausted. Every agent below works on `dev` in the main
repository (no worktree, no feature branch), commits small and atomic, pushes `dev` fast-forward
only after `git fetch` and `git rebase origin/dev`, then cancels the automatic CI run of that SHA
(`gh run list --commit <sha>`, `gh run cancel <id>`). Each agent keeps a handoff file in
[`docs/todo-agents/`](todo-agents/) with what is done, what remains and the exact next step: read
the file first, then continue. A backup of the working tree at 16:29 (uncommitted patch, untracked
files, bundle of the local commits, this TODO) sits outside the repository in
`C:\Users\admin\ergopti_wip_backup_20261021_1629`.

| Work                                                                                                          | Handoff file                                                                               | State at hand-over                                                                                                                                                                             |
| ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Integrate the Codex branches `fix/windows` (113 commits), `fix/macos` (12), `fix/linux` (3) into linear `dev` | [integration-fix-branches.md](todo-agents/integration-fix-branches.md)                     | Rebase/cherry-pick in a scratch clone `D:\_int`, order linux, macos, windows; `git cherry origin/dev origin/fix/<os>` lists what remains                                                       |
| Issue #99 (macOS 1.0.4): Karabiner lease, swallowed keys, ISO key, event tap                                  | [issue99-karabiner-input.md](todo-agents/issue99-karabiner-input.md)                       | Root cause found: `hs.application.get` falls back to `hs.window.find` and froze the main thread 13 s; fixed by a running-application adapter; READY deadline 11.5 s; ISO fix needs a Mac check |
| Issue #99: AI startup, oMLX, update flow                                                                      | [issue99-ai-startup-updater.md](todo-agents/issue99-ai-startup-updater.md)                 | IPv4 loopback probe, Atom-feed fallback, refused-install warning committed; rest in the file                                                                                                   |
| Shared Lua: timer ceiling, tap-binding tests, POSIX separator owner                                           | [lua-shared-timers-separators.md](todo-agents/lua-shared-timers-separators.md)             | Ceiling and tap-binding tests committed; separator conversion in batches (grep for `[/\\]` in `macos/`)                                                                                        |
| Windows: updater release-list freeze, last 3 native menu rows                                                 | [windows-updater-freeze-menu-census.md](todo-agents/windows-updater-freeze-menu-census.md) | Uncommitted files were blocking the repo-wide lint: first priority is to commit them clean                                                                                                     |
| Config policy items 33 and 42                                                                                 | [config-policy-33-42.md](todo-agents/config-policy-33-42.md)                               | Reproduce first, fix at the root, per sub-item                                                                                                                                                 |

Rules every continuing agent must keep: dev and main stay linear (never `git merge`); a release is a
push to `main` carrying a `Release-As: X.Y.Z` trailer; a hook failure caused by someone else's dirty
file is waited out or bypassed with a private index plus compare-and-swap `update-ref` running the
hooks, never with `--no-verify`; never weaken a test; quality over speed. Open questions for the
maintainer are in [questions-for-maintainer.md](questions-for-maintainer.md).

Verification still owed on real runners once dev is green again: the Windows NTLM cases are
NOT EXECUTED on images whose curl has no NTLM (item 62); the macOS PTY worker test
`testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope` failed once on macOS 26 and
passed on rerun (probable timing race in the retirement proof, investigate the Swift test); AppImage
catalog `/retest` was posted on #10422, read the bot's answer.

## Priority 0: Windows

### Windows session notes

The next sessions run on the maintainer's Windows PC (real AHK, native Windows suites without a CI
round trip). Read the latest dev CI run first. Maintainer decisions of October 20 already applied:
the release list and its ETag persist across restarts; `config.toml` keeps the 5/3 blank-line style
everywhere (templates and the Windows writer) and `windows/_generated/config_template.toml` changes
only through `npm run build:manifest`; the three drivers share the structured personal info editor;
dev reaches main only with a release (main last moved with v1.0.4).

1. Run the AHK suites locally: `config`, managed network and artifact curl groups, then the full
   suite (sharded, `--only` or `--shard=K/N`).
2. Reproduce the Windows reports on the real machine: key combinations after c89d74eb, number-row
   direct access and precedence, prediction-key and script-chord stalls (item 114).
3. Keep pinned ruff 0.15.8 and Prettier before every commit. After touching a sealed Windows updater
   source, reseal its cohort inputs with
   `node tools/ci/seal-windows-updater-original-source.cjs --ref <commit> --write`.

### Open Windows items

- [ ] **Windows managed-network software (item 62): NTLM-only proxies are unserved.** [CODE]
      Microsoft's `System32\curl.exe` 8.21.0 (Windows image 20261018) no longer lists NTLM, so the
      managed transport refuses an NTLM-only company proxy on an up-to-date Windows
      ([memory](memory/windows-ahk.md#project-windows-system32-curl-has-no-ntlm)). The three cases
      that need NTLM report NOT EXECUTED on such a host (f2cad38252, 90c42fbaa9); that is a gate,
      not a fix. Real fix: ship an owned, pinned, SSPI-capable curl (size, signing, updater impact)
      or move the transport to WinHTTP/.NET; question 6 for the maintainer. Also open: WinHTTP route
      vector shape, updater route/trust classification, the Job/child cleanup ack, and the
      PowerShell 5 fetch (`Source44`) exception with no known cause.
- [ ] **Windows parity remainders.** [CODE] The updater still processes the release list on the AHK
      thread for about 4 s even with the strict JSON owner and the native string scan (ffa4ee7c21,
      b17bf3d0a4): move it off the thread or shorten it from a measurement. L124 (a NUL histogram
      key merged by `json_group_object`) has not been checked on Windows.
- [ ] **Semantic TOML parse cost: one parse per transaction.** [CODE] The tokenizer reads unquoted
      runs and blank lines in one step (33a320cf01, about twice as fast). Still open: every
      document-mode write parses source, expected model and final candidate, and every start pays
      two builds after ready; reuse one parse per transaction before adding any cache.
- [ ] **Number-row reports (October 13 and Discord, v1.0.3).** [PHYS-W] Two testers: with an
      emulated layout and "Digits first", Shift reportedly still gives the Windows AZERTY symbols;
      digit-row direct access reportedly broken on v1.0.3. Dev since rebuilt the number row (the
      built-in Ergopti row from its own levels, the choice re-evaluated on every layout change, the
      effective layout on the edge keys, `#HotIf` reads contained during the first pump, an
      end-to-end replay on the machine's layouts). Ask both testers to retest the next dev build
      with their exact setup (native layout, emulation and row switches, CapsLock, outputs in all
      three modes); fix only a confirmed discrepancy, with a causal regression, and check the other
      drivers.
- [ ] **Reported key-combination and shortcut settings (October 15 and Discord).** [PHYS-W] Likely
      cause fixed in c89d74eb (the pair menu was a released local `Menu`). Confirm with the testers
      on the next dev build; if it persists, ask for `[KeyCombinations] Pair`, `AHK drop detected`
      and `Menu command refused` log lines.
- [ ] **114. Prediction-key (1-5) and AltGr+Enter stalls.** [PHYS-W] Cause unconfirmed. Observe the
      resident process while it stalls; collect the Notepad stale-admission diagnostics before
      changing tooltips or hooks.
- [ ] **143. AI enable/disable latency behind an incomplete startup.** [PHYS-W] The toggle lends its
      built child to the root queue instead of a second construction (0c5006c863) and an AI source
      check pays one full admission (9fac7fcb66): a toggle behind an unfinished startup went from
      about 5.4 s to 3.05 s on the startup smoke. Re-measure the real click on the PC; reduce the
      remaining startup cost (Rescan, schema checks) only from that measurement.
- [ ] **49. Keyboard-hook order.** [PHYS-W] [CODE] AutoHotkey removes and reinstalls its low-level
      hook around SendInput, so hook order is undefined. Record the real order before and after a
      SendInput rehook; audit terminal capture against KLE, dead-key, digit, profile, tap-hold,
      combination and script-shortcut consumers (down, repeat, up, owner change while held, pause,
      reload); finish event-specific capture and replay and modifier ownership (source pin,
      authenticated event stream, non-hook handler conversion, chained/repeat semantics). Regenerate
      the DLL and manifest only through the official MSVC generator; check the patches in
      `docs/handovers/2026-10-12-dev-consolidation/` against the tree first (many were applied
      since).
- [ ] **50. SendEvent against SendInput.** [PHYS-W] `SendMode("Event")` is set, yet the hotstring
      send/dispatch, text sender and config I/O still call SendInput. Measure expansions, pastes and
      predictions (latency, lost or interleaved keys) before choosing.
- [ ] **51. Real-machine matrix for the September 30 evening fixes.** [PHYS-W] See the checklist
      below; remove only after the whole matrix passes.
- [ ] **19. Tooltip border and white corners.** [PHYS-W] Visual acceptance on Windows 10 and 11 at
      several DPI scales; do not repeat the integrated fix without a demonstrated regression.
- [ ] **101. Keylogger shutdown debt (`watchers=0`).** [PHYS-W] The original diagnostic is lost;
      capture a new one with the full watcher/debt state if it recurs. Quit during a flush now
      retries once the flush settles (f95d0bfa0b).
- [ ] **Full Windows AHK suite.** [CI] It has never completed green locally (watchdog
      `_SUITE_MAX_TIMEOUT_MS`, 120 min; about 90 min single-threaded). Run it sharded on the PC;
      never raise the watchdog to make a run finish.
- [ ] **115. Portable JS suite on the Windows host.** [CODE] Host-bound cases (Linux installer
      sandbox, POSIX paths, Sparkle POSIX mode, symlink privilege 1314) now report "not executed" on
      a local Windows host (f2aebecb94) and the Node checks start without a shell (d66010e82c). The
      remaining local reds come from the host, not the code: Node 22.16 against the pinned 22.22.2,
      and no `pwsh`. Install both, rerun, and fix only a red that survives.
- [ ] **Native Windows TLS fixture.** [CI] Seven managed-network `native_tls` cases fail since
      hosted Git 2.56 moved the SDK from mingw64 to ucrt64; the trust install stays at `before_add`
      with no root-removal or service closure ack. Cause not proved.
- [ ] **Installed Diagnostics and shutdown.** [PHYS-W] An earlier build crashed on File/Exit
      (`0xC0000374`); later builds exit 0, but no final installed build is recorded. Installed
      Diagnostics UIA/render probes fail intermittently (`native_probe_error`) and a cold WebView
      can time out.
- [ ] **Windows updater production coupling (item 36).** [CODE] The interpreted-AHK "original23"
      updater collector stays inactive
      (`docs/handovers/2026-10-12-group6-ci/INACTIVE-ORIGINAL23-SOURCE.md`) until its role, runtime,
      caller and source contract is enrolled.
- [ ] **132. SignPath Foundation signing.** [CODE] Apply, integrate Windows signing, then delete
      `.github/ci/stable_windows_signing_exception.json`. Unsigned stable Windows releases are
      authorised until then.

### Physical Windows tests the maintainer can run

Record the commit, Windows build, scale, layout and emulation state for each run, and report pass,
fail or not executed per line. Use a disposable profile (`paths.toml` pointing at a scratch folder)
for anything that writes configuration.

1. **Seven-page wizard** (item 7): fresh, existing and moved folder; every page, Cancel, Finish then
   restart, rerun; No against recommended choices; changed-folder reads; real WebView rendering and
   persistence; the layout step's emulation and number-row controls never reload the UI.
2. **Clear and Restore** (item 5): per category and global (Configuration menu) Clear and
   « Restaurer les valeurs conseillées », then restart; unknown and outdated keys preserved;
   effective recommended delays; personal hotstrings and personal-file tuning unchanged by Restore
   (#96 decision); exact backups; an external write is refused.
3. **Number row and key combinations**: the reports above; on AZERTY, US QWERTY and Ergopti, each
   ordering and edge-key choice, each row emulation switch, an inert choice shown ticked, greyed and
   suffixed « — non appliqué », and the ² key; a pair assignment saved and reloaded.
4. **Installed build**: install, start, open Diagnostics (cold and reopened), Quit while a keylogger
   flush runs (exits once), File/Exit and Windows shutdown with exit code 0; uninstall greyed on a
   source run.
5. **Item 51 matrix**: arrows and both Shift+Tab over a multi-slot prediction move the marker once
   per press and wrap, never the caret (also after reload, with `nav_modifiers = ctrl`, and with a
   tap-hold Tab); footer "⇧G + Tab ou ↑/←"; bubbles and delayed expansions with emulation off and
   on; no "eeee" after a prediction; one clipboard-log row per Ctrl+V; AltGr+Entrée/Suppr/Retour
   arrière/Échap run script actions (and the script shortcuts switch restores them); AI menu
   (Backend « API 🌐 », API entry asks no name); « Revenir à cette version » keeps a backup.
6. **Items 19, 49, 50**: tooltips near screen edges at several DPI scales; hook order around a
   SendInput rehook; the send-mode measurement.
7. **Hotstrings on Windows** (items 34, 37, 102, 104, 105): follow
   [GROUP2-WINDOWS-TODO](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md); for 37,
   with no Ergopti layout installed the shipped pack, all suffix rules and the magic-key repeat
   appear, with no duplicate Layout row.
8. **Layout switching** (item 38): AZERTY with AHK emulation to the native Ergopti layout and back
   keeps AltGr usable without a manual reload, including on an AZERTY-style AltGr (LCtrl+RAlt) and a
   Kana layout.
9. **Touchpad registry** (item 13): values restored exactly after OFF and removal; prior values kept
   after an authorization refusal.
10. **Managed network** (item 62): the twelve steps in the [Group 6 Windows
    handover](handovers/2026-10-04-group6-windows/README.md) behind a company proxy, if one is
    available.
11. **Menu-click replay**: tray toggles clicked during a slow startup whose hotstring write requests
    a reload all apply in the successor, with no error toast.
12. **CapsWord auto-off**: the delay choices, the eight default delimiters, each pointer kind and the
    LAlt then CapsLock trigger end CapsWord as configured.
13. **AI off (#97)**: with the AI off, no local server sweep, no AI hotkeys registered, and a
    refused AI hotkey leaves the driver running.
14. **Prediction chord (item 112)**: in Notepad, each slot's modifier+digit chord inserts that
    prediction (and its correction form), and the shortcut column is right-aligned and muted.
15. **Local reload command (item 142)**: against the installed driver, run
    `tools/control/request_driver_reload.ps1` idle, paused and during a reload (expect "busy"); one
    driver afterwards, never a forced end.

## Integration (items 16, 38)

- [ ] **AI off must be inert on macOS.** [CODE] Windows keeps the AI runtime inert, stops local
      server discovery and survives refused AI hotkeys; macOS and Linux sweep no local server while
      the AI is off. Still open on macOS: profile shortcuts are still bound, `ollama list` still
      runs and the MLX download still resumes with the AI off.
- [ ] **Report-a-bug locale wording.** [CODE] Debug > Report a bug opens the prefilled bug form on
      the three OS, with the report copied to the clipboard and saved as a file. The rewording of
      `notify.report_bug_body` in the 21 locales was never committed and is no longer in the working
      tree: redo it through the `i18n` skill and commit.
- [ ] **AppImage catalog.** [CI] 3c4209e947 bundles libayatana-appindicator3 for the catalog's
      tray-less runner. `/retest` is posted on AppImage/appimage.github.io#10422 against v1.0.4: wait
      for the bot's result and fix what it reports. Polish: with no keyboard device the notice still
      names input groups.
- [ ] **CI duration.** [CI] Four of the five planned optimisations are in (macOS packaging after
      Unit beside E2E, Build waiting beside E2E for qualified inputs, the Intel XCTest cohorts in
      their own cell, several installed-app scenarios per job, Windows unit shards rebalanced from
      measured times); the fourth was deliberately not done. The macOS lane, not Linux, was the
      critical path at about 58 minutes; it must stay within the five-runner budget. The parallel
      `package-flatpak` job (6310b316bf) is pushed but unvalidated: check that it is green, that the
      install cells start right after Build and that a release-like run still lists the `.flatpak`
      asset. Then build the Linux packages per format in parallel (each install cell bound to the
      bytes it installs) and keep the graph symmetric (one row per OS).
- [ ] **Intermittent native CI fixtures.** [CI] Linux window switch (waits for Openbox's desktops),
      cffi-lua clone (two logged retries) and desktop-webview AI focus case (one logged re-run) now
      have bounded, logged retries: close each after it stays green, and root-cause any relapse from
      the logged attempt. Still unexplained: Windows `config` group (managed-network budget,
      artifact curl relay) and macOS Go `TestIdleDeadlinePhysicallyRetiresPeer` (ad03a898).
- [ ] **Integrate the fix branches.** `origin/fix/windows`, `fix/macos` and `fix/linux` still hold
      commits that are not ancestors of dev (113, 12 and 3 on October 21, many of them pre-rewrite
      copies of commits already on dev). Bring only the genuinely missing ones onto dev by rebase or
      cherry-pick (dev stays linear, never `git merge`), preflight, push dev only with
      authorisation, then fast-forward each `fix/*` only when it is an ancestor of dev. After a
      change touching `run_all.ahk`, `test_framework.ahk` or a sealed source, reseal
      `tools/ci/windows-updater-original-diagnostic-cohort-inputs.json`.
- [ ] **Menu clicks during a reload on macOS and Linux.** [CODE] Windows holds a click that lands
      while a reload is pending and replays it in the successor (85a926ba27). Check the Lua drivers
      for the same pending-reload window and give them the same contract if it exists.
- [ ] **Test parity across the drivers.** [CODE] Continue [the parity
      audit](audits/2026-10-18-test-parity-audit.md): next are Windows dynamic hotstrings, the
      remaining verbatim duplicate Lua test files, absence ratchets for deleted code, and one tidy
      `tests/` tree on the three drivers.
- [ ] **CI structure.** [CODE] Elapsed time per CI step, suite and test with a slowest-test summary;
      live Windows unit-log progress. The lane layout itself is done (d1862ef26b..3ea8b6d69e):
      `ci.yml` plans and calls, release and publication live in `ci-release.yml`, each lane calls
      one reusable workflow per stage with three-part check names, and eight one-off diagnostic
      workflows are deleted; `linux-layout.yml`, `bench.yml`, `windows-test-replay.yml` and
      `deploy-site.yml` are kept on purpose.
- [ ] **CI layout follow-ups.** [CODE] The HS-274 Python and Swift tools lost their workflows with
      the `hs274-*.yml` deletion: retire them, or give them a lane. The site deploy reads its
      receiver from main, so it lags dev until the next release: decide whether that is wanted.
- [ ] **16/38. Final acceptance.** [CI] One complete non-release three-OS checkpoint on the final
      source (units, E2E, packaging, installation, launch) with exact receipts, then the physical
      tests. Mac checks (38): no "Lease-bound input startup failed" or spurious "Layout poll
      detected change"; Right Option + Return/Delete/Backspace/Escape run script actions; no Python
      or Rosetta notice at launch; MLX behind a proxy; Versions rollback.

## config-menus (items 5, 7, 33, 42, 54, 81)

- [ ] **Neutral installation (October 13).** [CODE] A new installation enables no layout emulation,
      system layout change or number-row inversion (explicit configurations kept). The wizard's
      layout step already offers the emulated layout, row emulation and number-row ordering as
      persistent controls that never reload the UI (7977d3dc74); check that the shipped defaults are
      neutral on the three drivers.
- [ ] **5. W1 neutral configuration and scopes.** [PHYS-W] see the checklist. [CODE] Linux layout
      and number-row scope participants composed with the real runtime producers (file publication
      is not behaviour); Linux/macOS numeric-owned Script aliases need an explicit snapshot
      contract.
- [ ] **7. Seven-page wizard.** [PHYS-W] see the checklist. [PHYS-M] Cocoa Finish,
      custom-against-default folder disagreement, native restart. [PHYS-L] Wayland, physical input,
      installed-daemon restart and Linux trigger selection.
- [ ] **33. Config policy for files other than config.toml.** [CODE] Windows keyboard binding
      publication from its real input owner (its four-group producer lacks the expanded chord
      domain); macOS Hotstrings category/section/order authority; Linux retired API-provider reader
      keeps a removed provider active (with ai); macOS Karabiner obsolete-leaf intent; Windows
      retired dotted/inline/table-array cleanup projections.
- [ ] **42. config.toml batch writer follow-ups.** [CODE] Ancestor admission and external
      symlink-target replacement for the explicit `--config FILE.toml` watcher; Windows full-save
      comment preservation and scalar/array table-array boundaries need native qualification.
- [ ] **54/81. Every menu row declared in the shared manifest.** [CODE] The native-menu-row census
      is down to Windows 3, macOS 0, Linux 0 (a0eee67936 to f29d2f815c: personal folder levels, AI
      dynamic rows and the AI model picker return row data to the renderer;
      `npm run test:native-menu-rows`, regenerate before trusting any count). The last three rows
      are in `menu_hotstrings.ahk` and need a renderer design first: the renderer must own the child
      menus it hands back to repaint commands, so a repaint cannot act on a child it no longer
      publishes. Then lower the baseline to zero. [PHYS-W/M/L] Installed menus: captions,
      unavailable reasons, child commands, state after restart.
- [ ] **116. Guided third-party validation report.** [CODE] Isolated timer/Karabiner/Shortcuts/Brew
      checks and package provenance; [PHYS-M] the installed page.
- [ ] **121. AI Agent submenu unavailable on every OS.** [CI] Composed-menu qualification.
- [ ] **122. Focus Diagnostics when opened or reopened.** [PHYS-M] Physical Mac foreground.
- [ ] **123. Privacy-safe shared export.** [CI] Native Linux write/close refusal; [PHYS-M] installed
      app.
- [ ] **131. Startup ownership with another installation.** [CODE] macOS `SMAppService` cannot
      expose the registered bundle URL; legacy ownership unqualified.
- [ ] **138. English diagnostic export and editable issue.** [CODE] The configuration (files,
      resolution order, shareable setting rows, collected by a local probe) is now in the reports of
      the three drivers. Still open: three native daily-log collectors (a 64 KiB / 50-entry tail is
      not a day); [PHYS-W/M] installed copy, write, reveal and browser; GitHub field editability.
- [ ] **139. Remove personal identities from logs.** [CODE] Free-form text is not proven safe;
      historical logs unchanged; GitHub attachment URL revocation unestablished.
- [ ] **141. Newer configuration schemas read-only on every driver.** [CODE] A greyed row can name
      the cause that greys it (449ccd4fd3, contract pinned by 2e8a9fb02a), and the AI switch and
      "restore recommended" rows now name a newer configuration (9f6ec6b9a5). Still open: the AI
      submenus (servers, API entries, profiles) are refused only by the normal save path; give their
      persistence rows the same greyed cause and recheck the retained callbacks.
- [ ] **142. Local driver control command for reload.** [PHYS-W/M/L] Windows, Linux and macOS
      reload on an authenticated local command through their reload owner, with requested, refused
      and completed outcomes (9c30266410, 9ad640d327, 0ada3403db; declaration in
      `_shared/modules/control/driver_control.json`). Never tried against an installed driver
      (Windows check 15 above). Known gaps: Windows refuses with "busy" while a reload is pending
      rather than queueing; Linux reloads the hotstrings in process instead of a successor; [CODE]
      the Windows client does not check the driver executable's hash before trusting the session.

## hotstrings (items 34, 37, 102, 104, 105)

- [ ] **Priority-100 entry cannot output uppercase (Discord tester).** [PHYS-W] Fixed on Windows
      (cf29c35e5f): a case-insensitive entry registered a lowercased replacement, so its own
      capitals were lost whatever the priority; three shared corpus vectors replay it on the three
      drivers. Confirm with the tester on the next dev build. Tell him meanwhile: on 1.0.3, tick
      « Case sensitive » on the entry to keep its capitals.
- [ ] **34. Recommended delays and handwritten `[[hotstrings.terminators]]`.** [PHYS-W] Menu, save
      and restart acceptance
      ([checklist](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo34-delays-and-handwritten-delimiters)).
      [CI] Native Linux/macOS delimiter transactions.
- [ ] **37. Always show the shipped Ergopti pack.** [PHYS-W]
      ([checklist](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo37-shipped-ergopti-sections)),
      including build/install/upgrade/uninstall with both extension TOML files. [CI] macOS packaging
      and installation.
- [ ] **102. Two commands per Hotstrings category submenu.** [CODE] Windows now loads only adopted
      personal files: `PersonalFileControls.ActiveOwner` is the one identity gate of the live
      registration, the preview index and the menu total (ae040558d8). Still open: a refused file's
      row caption shows its raw entry count, as if it were active. [CI] Windows native cases,
      Fedora/Alpine ShellRunner fixtures; [PHYS-W]
      ([checklist](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo102-personal-files-and-source-controls)).
- [ ] **104. Common autocorrection sections.** [CI] Native Windows/macOS, per-section E2E, package;
      the independent 140-rule corpus is never regenerated from production.
- [ ] **105. Programmable dynamic hotstrings.** [CI] The Windows worker probe passed 24/24 natively;
      still open: macOS execution, E2E, package.
- [ ] **129. Built-in dynamic hotstrings only at word starts** (`update` must not propose `date`).
      Linux leaves the word start unknown after its six text-context resets (8302ea9269). [CI] The
      E2E scenario needs a Linux runner, and the composed release gate is the CI run itself;
      [PHYS-W/M/L] real typing.

## actions (items 63, 71, 73, 91, 93, 96-98, 106-109, 111)

- [ ] **Number row: remaining checks.** The ordering is offered only where it reorders the effective
      row (digits first on AZERTY-like rows, symbols first on QWERTY-like rows, neither on Ergopti
      or mixed rows), scopes are per row, the three edge keys have their own checkbox, the wizard
      has the step (c9479f2e6a, a2d4adb113, 7977d3dc74), the layout emulation switches off row by
      row, and the built-in Ergopti row resolves from its own levels; layout emulation and
      its row switches are Windows-only and greyed with their reason elsewhere. [PHYS-W] Real
      typing on the maintainer's layouts (checklist item 3). [CODE] Emulating the number row's base
      and Shift levels independently is not implemented as such (a row is emulated or native):
      confirm with the maintainer that the row switches cover the October 13 request.
- [ ] **CapsWord auto-off and Linux CapsWord.** CapsWord ends after a configurable delay (choice
      list, 10 s default), on eight default delimiters taken from the hotstring delimiter catalogue
      and on chosen pointer kinds, on the three OS; Linux CapsWord types capitals by locking
      CapsLock and toggles from keys, key combinations and tap-holds. [PHYS-W/M/L] Real-hardware
      checks. [CODE] Linux has no recommended setting for the LAlt then CapsLock trigger; Linux
      chord slots still refuse `caps_word`; the engine's unused per-letter CapsWord mode can be
      removed.
- [ ] **63. Brightness up/down.** [CI] Qualify the joined source; [PHYS-W/M/L] real luminance,
      refusal without a backlight provider.
- [ ] **71. Retired Metrics-window shortcuts.** [CI] Three-OS full save and installed upgrade.
- [ ] **73. Physical-key labels.** [PHYS] Real providers, locale change, native menus; never
      force-enable the disabled French magic-key category.
- [ ] **91. Simultaneous and first-key hold arbitration (Windows).** [CODE] Integrate with the
      single-hook/RawInput source (needs a genuine MSVC DLL and manifest pair); [PHYS-W]
      held-alone-then-joined order, AltGr hook provenance.
- [ ] **93. Linux ordered pairs and Manager.** [CODE] Saved Xi runtime/staging packet plus
      `libxi-dev` workflow dependency; XKB/XI2 server state join; [PHYS-L] real kernel capture.
- [ ] **96. Ergopti+ emulation picker.** [PHYS-W] Precedence, chevron timing, layout and dead-state
      output.
- [ ] **97/98. User-chosen physical position and arbitrary output.** [CODE] Native physical-position
      capture, all-owner collision admission, star setting migration; Linux identity needs the
      MediaStore device contract; [PHYS] real outputs including dead keys.
- [ ] **106. Action catalogue.** [CODE] Genuine Apple Shortcuts invocation with bounded cancellation
      (discovery timed out after 20 s).
- [ ] **107. Native / digits-direct / symbols-direct policy.** [CODE] macOS forced output, Linux
      input+XI2+writer join; [PHYS] number-row delivery.
- [ ] **108. Hotstring-editor shortcut follows the chosen magic key.** [CODE] Item 97's
      collision/source/modifier/output joins; [PHYS] delivery.
- [ ] **109. Branded debug GUI.** [CODE] Blocked: stock AHK 2.0.26 offers no supported invisible
      Variables/KeyHistory snapshot. Nothing implemented.
- [ ] **111. App switcher and cursor-display actions.** [CI] macOS compile, sign, query; [PHYS-M]
      two displays.
- [ ] **125. Free-text translation target.** [PHYS] Installed dialog, real inference.
- [ ] **126. Recommended two-finger gestures unassigned.** [PHYS-M] Built-in trackpad restore check.

## ai (items 46, 47, 48, 88)

- [ ] **Ollama 0.40.4: compile and qualify.** [CI] Every driver pins 0.40.4 (662ed3714b) with the
      checked dialer and native HTTP hooks ported, and every managed server runs with
      `OLLAMA_NO_CLOUD=1` (b06c421923). The Mac receiving create stage runs its client with
      `OLLAMA_CREATE_REMOTE=1` (460b96dd1f) and qualified for v1.0.4. The Go side has not been
      compiled anywhere yet (the source test applies the hooks without Go).
      Product decision for the maintainer, needs a Go toolchain: whether a download host that does
      not resolve is left to the proxy or the native worker, which reverses an assertion in
      `address_policy_test.go`.
- [ ] **46/47/48. Local models, discovery and owned runtime.** [CI] [PHYS] Real model, chat,
      download, consent, pause/resume/shutdown, HTTPS behind a system proxy, per-user install and
      restart. Windows managed AI was never received live; its private UI assembly is not adopted
      (it rejects the default `localhost` URL). [CODE] 17 baseline FFI failures in the Lua 5.4
      authenticated private-file fixture.
- [ ] **88. Prediction tooltip appearance.** [PHYS] Typography on the three OS.
- [ ] **112. Accept a prediction with its modifier+digit shortcut.** [PHYS] Windows inserts the
      prediction a validation chord names (af5cb11b84) and the three OS show each prediction's chord
      in one shared right-aligned muted column (a9e1f997c1). Check the insert and the correction
      form in Notepad (Windows check 14) and the column's look on the three OS.
- [ ] **113. Promo-video i18n and performance.** [CODE] Sales-page placeholder rows
      (`_modifier_chords_placeholder`); regenerate GIFs
      (`npm run gifs -- personal-hotstrings screen-time ai-predictions`) without touching the video
      agent's uncommitted work; cache PAC resolution only after measuring.
- [ ] **120. Provider and model selection before enabling AI.** [PHYS-M] Installed menu; broad
      Ollama process termination on macOS stays debt.
- [ ] **137. Publish the selected provider before model loading (macOS).** [CI] Hosted
      qualification.
- [ ] **Configured local servers (issues 94 and 95).** [PHYS-M] Native acceptance of configured
      local discovery with a real oMLX install. A running oMLX was never seen because the sweep ran
      inside the menu build, which holds the run loop about a second past the 1.5 s probe deadline;
      the sweep now starts once the build returns (15ab2ac6f3). Measure on the Mac that the probe
      no longer times out and that a running oMLX is listed.

## macos-input (items 13, 24, 30, 31, 35, 40, 43, 44)

- [ ] **Dropped letters on macOS.** [PHYS-M] Unproven. Every typed key the driver consumed and never
      delivered is now reported ("typed key(s) swallowed", decisions only, never the key), and a
      stale one-shot Shift claim was fixed with the CapsWord policy. Mac action: Debug > Report a
      bug right when a letter disappears, then look near that time for "typed key(s) swallowed"
      against a lease failure or a Karabiner deploy.
- [ ] **117/140. Karabiner lease failures on Apple silicon.** [PHYS-M] Exit 73, PONG/READY timeouts
      since dev.155. The lease budgets are ordered so a slow CLI keeps the lease, every exit 73
      names its cause, and each deploy decision is one INFO line (recovery deploys wait for a typing
      pause; an unchanged `karabiner.json` is never republished). Reproduce on the Mac with these
      log lines and read the lease timings; the only workaround is Configuration > Ergopti uses
      Karabiner > Off. Replaying the 2026-10-19 log shows that recovery deploys (28 of 33 that day)
      cannot be reduced without fewer lease failures.
- [ ] **118. ANSI/ISO positions distinct.** [PHYS-M] Real ISO/ANSI typing and the final package.
      The tap key left of "1" fired on the extra ISO key; it now follows the deployed virtual
      keyboard's ISO/ANSI form (97ec406f4b): check it on the maintainer's ISO Mac.
- [ ] **Issue 94 native acceptance.** [PHYS-M] Tap-hold menu change refusal, clipboard retention in
      symbol wrapping, ANSI/ISO layout captured once: portable fixes only.
- [ ] **13/35. Guardian lifecycle.** [PHYS-M] [CI] Signed helper ServiceManagement registration,
      wrong-inode refusal, unregistration, idempotence and job absence on both architectures; enrol
      the complete acceptance collector in main CI [CODE]. Never infer retirement from a signal, a
      missing handle or a hidden dialog.
- [ ] **24. Tap-hold outage guide.** [PHYS-M] Login Items approval and retirement on a real Mac.
- [ ] **30. Physical magic key on the three OS.** [PHYS] Windows capture under emulation, macOS ISO
      and ANSI (Backquote and IntlBackslash), Linux grab, injection and hotplug. Linux now says when
      a tap action takes the physical magic key instead of overriding it silently (407db5fd50);
      [CI] its Linux tests have not run yet.
- [ ] **31. HS-274 exact physical key accounting with an owned Karabiner runtime.** [CODE] Work
      packages WP3-WP10 (production consumer, headless producer v2, reproducible runtime, launchd
      ownership, owned configuration, native and real-Mac acceptance, enable and retire); media keys
      without a macOS keycode; VirtualHIDDevice incompatibility blocks owned mode with an
      explanation. Plan: [ADR 011](../static/ergopti_plus/docs/adr/011-owned-karabiner-runtime.md).
      Estimate 30-40 agent-days plus hardware time. The owned runtime stays dormant at default
      startup.
- [ ] **40. Packaged-launch gate builds a Karabiner configuration.** [CI] Signed native execution of
      all eight default/recommended/switch variants.
- [ ] **43. Upgraded Mac with 25 ambiguous legacy rules.** [PHYS-M] Test
      « Retirer les anciennes règles » on a real upgrade.
- [ ] **44. CapsWord and pointer with Karabiner.** [PHYS-M] Pointer cancellation on the final
      installed source (the CLI pointer probe was removed: `karabiner_cli` cannot read user
      variables).
- [ ] **Tap-binding "malformed source" tests pass for the wrong reason.** [CODE] The shared macOS and
      Linux contract tests reach the refusal through a size mismatch in their fake `io.open`, not
      through the malformed source they claim to test. Make the fake faithful and prove each test
      fails without the refusal (`false-green-tests` skill).
- [ ] **127. VS Code bridge retirement.** [PHYS-M] Installed startup.
- [ ] **Carbon and daemon-report Swift.** [CI] Carbon fixture compilation and both-architecture
      receipts; daemon-report Swift allocation compiler failures on Intel and Apple silicon.

## release-network (items 36, 62)

- [ ] **36. macOS `.tar.xz` release archive and Brew/Sparkle acceptance.** [CI] Final macOS Package
      job: Sparkle install/refusal/retry/relaunch, both Brew positives, full-policy denial, all Brew
      archive scenarios. The Brew deny-removal AppleEvent positive has no supported consent path on
      hosted runners [PHYS-M]. Linux side: Flatpak/AppImage full-format installation and
      PAC/session/TLS delivery; the `.rpm` builds for x86_64 as `ErgoptiPlus-linux-x86_64.rpm`
      (1b4b8250f9). The AppImage name must never contain "linux" (the catalog refuses it;
      `test-linux-appimage-portability.cjs` pins it), so it stays `ErgoptiPlus-x86_64.AppImage`.
- [ ] **62. Downloads on managed company networks.** [CODE] macOS full request-URL PAC/WPAD, ordered
      fallback and redirects for uv, HTTPX/HF/Xet and outgoing Ollama Go (keep the
      verified-unsupported-route refusal); diagnose `-1202`/SSL-9813 after a successful trust add
      and the 15 s trust-removal timeout; forward the Ollama daemon log directory (output goes to
      `/dev/null`). [PHYS] Corporate proxy, CA, authentication, cancel/retry, upgrade and rollback
      on every OS.
- [ ] **119/130/136. MLX bootstrap and install.** [PHYS-M] Real PAC download on the affected Mac
      (119, 130), a new Apple silicon attempt for the code 74 failure (136); qualify the Homebrew
      live upgrade and launcher/child retirement of issue 90 (130).
- [ ] **CodeQL Go.** [CI] After the `native_http` Go module is published, re-enable Go in the
      default setup and check a fresh non-empty analysis.

## Cross-OS parity backlog

The Windows (01b9d6aa2d..72d2125c5d) and macOS (45d74ee3e1..4fa3f50d54) backlogs of source-only
proposals found while hardening Linux are worked through. Not defects after native review: L48, L83
and the release-notes CR handling on Windows (L128 was already fixed); L30, L85, L88 and L18 on
macOS. The Windows remainders are under [Open Windows items](#open-windows-items). Still open on
macOS:

- [ ] **One path-separator owner.** [CODE] About 85 `[/\\]` sites still treat both separators on
      their own (L64 fixed the bootstrap walk only); give them one owner.
- [ ] **Smaller macOS findings.** [CODE] `ui/changelog` `asyncGet` follows redirects; the at-rest
      cipher puts its plaintext in the `sh -c` argv. [PHYS-M] Confirm on the Mac: `pipefail` and
      `printf %b` under bash 3.2, the native HTTPS downgrade refusal, `hs.fs.attributes` on a FIFO,
      and the read-only dashboard open with a hot journal.

## Linux hardening: open items

The other Linux hardening items (L5-L145) are delivered apart from the generic caveat. L69, L77,
L103 and L126 are done (84707de17c, d276bacfe0, c6896fac9d, c7178bb5bd, a6e229a59f), and macOS
direct append admits only regular files (L94, 5e524b9658). The items below still need software
work.

| Item | Subject                       | Remaining work                                                                                                                                                   |
| ---- | ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| L105 | Finite timer admission        | The no-luv finite period is done (c876362759). Decided: refuse a delay above about 2^53 ms on every runtime (LuaJIT arms a timer that never fires): to implement |
| L115 | Provider error envelope guard | Instrumented (1f103733aa): the fixture now prints the swallowed traceback; cause still unknown                                                                   |

Metrics follow-ups:

- [ ] **Correction bigrams and trigrams.** Linux counts the n-grams that end in a correction
      differently from Windows and macOS, which push `x[BS]` and `yx[BS]` for every Backspace.
      Maintainer decision: align Linux, or align the other two.

Optional scoping notes, not planned: XKB angle-name lexical gaps and the wider raw-input grammar
(L118-L120); source-side concurrent replacement of a JSON backup (L52, L60); ALSA hardware audio
fallback (L63); multi-group XKB recovery (L100).

## Decided, do not re-raise

- **Delta updates (item 22)**: withdrawn by the maintainer; full signed downloads stay below 20 MB.
  Reconsider only if release size or measured repeated-download cost grows
  ([rationale](handovers/2026-10-04-parallel-containers/PARALLEL-WORK.md#delta-updates-decision)).
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
  critical path, and drops their only macOS 26 coverage. The repetition is deliberate cross-version
  coverage; job, lot and step names state each cell's macOS version, read from `HOSTS` in
  `tools/ci/macos-stage-roles.cjs`.
- **Windows unit shards are grouped by test category, not by duration.** A new test file with no
  category fails a gate; a minute more of wall time buys a CI whose red job says what broke.
- **Maintainer workflow**: partial work is delivered into dev after the feasible container or CI
  work, with native or device gaps documented here rather than holding a branch.
