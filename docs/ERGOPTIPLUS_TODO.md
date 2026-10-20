<!-- docs/ERGOPTIPLUS_TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-20 (evening). Latest stable:
[v1.0.3](https://github.com/adrienm7/ergopti/releases/tag/v1.0.3) (tagged 2026-10-18, with deferred
macOS native scopes, see [below](#next-release-with-nothing-deferred)). Open work only: a finished
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

## Tonight (October 20)

- dev is pushed at a49445bdee. Other agents (Codex) fix bugs on `fix/windows`, `fix/macos` and
  `fix/linux`, branched from that commit, each fix with a non-regression test; integrate them as
  described under [Integration](#integration-items-16-38).
- The CI errors of dev are owned by the coordinator. The Windows CI step fixes (shared serve
  environment for the runtime model, refused file-port receiver stderr, Mac Ollama fixture registry)
  are in dev; dev's CI run on a49445bdee decides whether they hold.
- Not started or stopped mid-way, still open below: AI 112, 124, 143; Windows 115, TOML fuzz
  semantics, item 30 Linux magic-key override; hotstrings 102, 129 and the priority-100 uppercase
  report; config-menus 141, 142, 54/81.

## Priority 0: Windows

### Windows session notes

The next sessions run on the maintainer's Windows PC (real AHK, native Windows suites without a CI
round trip). Read the latest dev CI run first. Maintainer decisions of October 20 already applied:
the release list and its ETag persist across restarts; `config.toml` keeps the 5/3 blank-line style
everywhere (templates and the Windows writer) and `windows/_generated/config_template.toml` changes
only through `npm run build:manifest`; the three drivers share the structured personal info editor;
dev reaches main only with the next release, so Deploy site failures on main are expected until
then.

1. Run the AHK suites locally: `config`, managed network and artifact curl groups, then the full
   suite (sharded, `--only` or `--shard=K/N`).
2. Reproduce the Windows reports on the real machine: key combinations after c89d74eb, number-row
   direct access and precedence, prediction-key and script-chord stalls (item 114).
3. Keep pinned ruff 0.15.8 and Prettier before every commit. After touching a sealed Windows updater
   source, reseal its cohort inputs with
   `node tools/ci/seal-windows-updater-original-source.cjs --ref <commit> --write`.

### Open Windows items

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
- [ ] **143. AI enable/disable latency behind an incomplete startup.** [CODE] Not started. Pass the
      exact caller-owned child through the root builder map so the queue settles without a second
      child construction; reduce startup cost (Rescan, schema checks). [PHYS-W] Re-measure the real
      click.
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
- [ ] **115. Portable JS suite on the Windows host.** [CODE] Not started. Fix the host-bound fixtures
      (Linux installer sandbox, drive-letter path given to a POSIX constructor, backslash
      `LUA_CPATH`, Sparkle POSIX mode, symlink privilege error 1314), so a local run equals the
      hosted one.
- [ ] **Native Windows TLS fixture.** [CI] Seven managed-network `native_tls` cases fail since
      hosted Git 2.56 moved the SDK from mingw64 to ucrt64; the trust install stays at `before_add`
      with no root-removal or service closure ack. Cause not proved.
- [ ] **Installed Diagnostics and shutdown.** [PHYS-W] An earlier build crashed on File/Exit
      (`0xC0000374`); later builds exit 0, but no final installed build is recorded. Installed
      Diagnostics UIA/render probes fail intermittently (`native_probe_error`) and a cold WebView
      can time out.
- [ ] **Windows managed-network software (item 62).** [CODE] SSPI/NTLM in the owned curl, WinHTTP
      route vector shape, updater route/trust classification and Job/child cleanup ack; the
      PowerShell 5 fetch (`Source44`) exception has no known cause.
- [ ] **Windows updater production coupling (item 36).** [CODE] The interpreted-AHK "original23"
      updater collector stays inactive
      (`docs/handovers/2026-10-12-group6-ci/INACTIVE-ORIGINAL23-SOURCE.md`) until its role, runtime,
      caller and source contract is enrolled.
- [ ] **132. SignPath Foundation signing.** [CODE] Apply, integrate Windows signing, then delete
      `.github/ci/stable_windows_signing_exception.json`. Unsigned stable Windows releases are
      authorised until then.
- [ ] **Windows AHK TOML fuzz.** [CODE] Not started. The fuzz callbacks check only the absence of
      unhandled errors, not the expected parse semantics.

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

## Integration (items 16, 38)

- [ ] **GitHub issue #96 (Windows, v1.0.3): fixed on dev, release and answer.** An editor-created
      category took the neutral-off default of an undeclared personal section (d31776170a). Restore
      no longer touches personal hotstrings on the three drivers (20a9858f3d, dc8421f3). After the
      next release, reply: the reporter ticks "metiers" once, or updates.
- [ ] **GitHub issue #97 (AI off must be inert).** Windows keeps the AI runtime inert, stops local
      server discovery, survives refused AI hotkeys and logs arbiter failures under their own tag;
      macOS and Linux sweep no local server while the AI is off. Still open on macOS [CODE]: profile
      shortcuts are still bound, `ollama list` still runs and the MLX download still resumes with
      the AI off. The reply is drafted (session scratchpad `issue97/reply.md`), not posted.
- [ ] **GitHub issue #95 (macOS, v1.0.3, maintainer's log).**
  - (1) oMLX added by hand: fixed (c67d70f1fe).
  - (2) oMLX running but never seen: the sweep ran inside the menu build, which holds the run loop
    about a second, so the 1.5 s probe deadline expired before any answer was read. The sweep now
    starts once the build returns (15ab2ac6f3). [PHYS-M] Confirm on the Mac that a running oMLX is
    listed.
  - (3) "Check for updates" HTTP 403: the unauthenticated GitHub API limit, named with its UTC reset;
    macOS and Windows keep the release list ETag across restarts. Done; release and answer.
  - (4) Karabiner lease timeouts (READY, PONG, watchdog exit 73): the lease budgets are ordered so a
    slow CLI keeps the lease, every exit 73 names its cause, the browser window watch no longer
    builds an `hs.window.filter`, the CapsWord CLI probe is gone, and each deploy decision is one
    INFO line (recovery deploys wait for a typing pause; no `karabiner.json` equal to the file on
    disk is published). Needs a Mac reproduction with the new log lines (items 117/140).
  - (5) The tap key left of "1" fired on the extra ISO key: it now follows the deployed virtual
    keyboard's ISO/ANSI form (97ec406f4b). [PHYS-M] Check on the maintainer's ISO Mac (item 118).
  - Lower-noise logs (gesture conflict once per posture, logger stall, changelog Atom fallback at
    INFO) are in. Reply after the next release.

- [ ] **Report-a-bug locale wording.** [CODE] Debug > Report a bug opens the prefilled bug form on
      the three OS, with the report copied to the clipboard and saved as a file. The rewording of
      `notify.report_bug_body` in the 21 locales is still uncommitted in the working tree: finish it
      through the `i18n` skill and commit.
- [ ] **AppImage catalog.** [CI] 3c4209e947 bundles libayatana-appindicator3 for the catalog's
      tray-less runner. Watch `install-linux` on dev, release, comment `/retest` on
      AppImage/appimage.github.io#10422 and fix what the bot reports. Polish: with no keyboard
      device the notice still names input groups.
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
- [ ] **Integrate the fix branches.** Merge `fix/windows`, `fix/macos`, `fix/linux` into dev with
      `--no-ff`, validate, push dev only with authorisation, then fast-forward each `fix/*` only
      when it is an ancestor of dev. After a merge touching `run_all.ahk`, `test_framework.ahk` or a
      sealed source, reseal `tools/ci/windows-updater-original-diagnostic-cohort-inputs.json`.
- [ ] **Menu clicks during a reload on macOS and Linux.** [CODE] Windows holds a click that lands
      while a reload is pending and replays it in the successor (85a926ba27). Check the Lua drivers
      for the same pending-reload window and give them the same contract if it exists.
- [ ] **Test parity across the drivers.** [CODE] Continue [the parity
      audit](audits/2026-10-18-test-parity-audit.md): next are Windows dynamic hotstrings, the
      remaining verbatim duplicate Lua test files, absence ratchets for deleted code, and one tidy
      `tests/` tree on the three drivers.
- [ ] **CI structure.** [CODE] Elapsed time per CI step, suite and test with a slowest-test summary;
      live Windows unit-log progress; four parallel lanes (Common/Windows/macOS/Linux: Unit, E2E,
      Build, Test-the-build) converging into Release.
- [ ] **Clean CI layout: do right after the first green dev (maintainer, October 20).** [CODE] One
      dedicated agent, separate commits, each validated on a `tmp/*` branch before dev, receipts and
      the release verifier kept exact: (1) `ci.yml` only plans and calls: move release and
      publication into `ci-release.yml`; (2) each lane (`ci-windows.yml`, `ci-macos.yml`,
      `ci-linux.yml`, `ci-common.yml`; today 80 KB, 175 KB, 257 KB, 12 KB) delegates per stage
      (unit, E2E, build, install, verdict) to small reusable workflows or composite actions, with
      the stage and job names stating what they test and, on macOS, the runner OS version (macOS 15
      E2E and macOS 26 Build run the same Swift classes on purpose); (3) delete the standalone
      workflows that no longer serve after checking each one's callers, pins and tests:
      `hs274-native.yml`, `hs274-producer-build.yml`, `hs274-shutdown.yml`, `hs274-transport.yml`,
      `shortcuts-cold-cli-diagnostic.yml`, `windows-test-replay.yml`,
      `metrics-reader-bench.yml`, `macos-keyboard-geometry.yml`, `macos-release-launch.yml`,
      `linux-layout.yml`, `bench.yml`; keep `deploy-site.yml`. Windows unit shards are grouped by
      test type with explicit names (a new test file with no category fails a gate), not by
      duration.
- [ ] **16/38. Final acceptance.** [CI] One complete non-release three-OS checkpoint on the final
      source (units, E2E, packaging, installation, launch) with exact receipts, then the physical
      tests. Mac checks (38): no "Lease-bound input startup failed" or spurious "Layout poll
      detected change"; Right Option + Return/Delete/Backspace/Escape run script actions; no Python
      or Rosetta notice at launch; MLX behind a proxy; Versions rollback.

### Next release with nothing deferred

[CI] v1.0.3 deferred the macOS native scopes
(`.github/ci/stable_v103_macos_native_qualification_exception.json`, `STABLE_V103_SCOPE_IDS` in
`tools/ci/dev-release-qualification.cjs`); the maintainer wants the next release with no deferral.
When a scope is green twice on both architectures, remove it from the constants and the JSON; with
none left the next tag publishes with no profile (tested). Items 128 and 133 close with this.

- PAC/WPAD/bootstrap wire methods: green twice since the refused-proxy fix (ca778f39). Confirm
  `test01` (HTTP wire) before dropping `macos-native-http` and `macos-native-pac`.
- Brew archive acceptance: green once (empty core tap, 3d298e30).
- Managed model receiving: green twice on both architectures before Ollama 0.40.4; the receiver now
  reads its manifests-v2 store and the fixture registry is served from a public test address, so
  re-qualify on the new pin.
- Shortcuts discovery, launch AppleEvents, owned-runtime XCTest (ACL fix 0b7428c8): validate through
  a release-like run with Build and Install-and-launch green.

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
- [ ] **54/81. Every menu row declared in the shared manifest.** [CODE] Not resumed. Drive the
      native-menu-row census to zero, one commit per menu with the baseline lowered
      (`npm run test:native-menu-rows`; regenerate before trusting any count). Convert Windows
      dynamic `register/append/add` rows to check/command; a declared child template for `list`
      parents (Tap-Hold, gesture slot, hotstring file, AI profile); provider separators; tray root
      bootstrap; four Windows Personal constructors. Next: Hotstrings, AI menus, Linux
      `menu_builder.lua`. [PHYS-W/M/L] Installed menus: captions, unavailable reasons, child
      commands, state after restart.
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
- [ ] **141. Newer configuration schemas read-only on every driver.** [CODE] The three drivers show
      `config.read_only.newer_schema` (58ef8cfcdd). Still open: grey the AI persistence actions with
      that reason and recheck retained callbacks.
- [ ] **142. Local driver control command for reload.** [CODE] Not started. Route through the
      lifecycle owner (pause, transactions, cleanup, successor identity); report requested, refused
      and completed separately; never start a duplicate driver or force termination; all three OS.

## hotstrings (items 34, 37, 102, 104, 105)

- [ ] **Priority-100 entry cannot output uppercase (Discord tester).** [CODE] A hotstring whose
      priority is 100 reportedly never types its uppercase form. Get the entry and the OS from the
      tester, reproduce it in the shared corpus, then fix with a causal regression on the three
      drivers.
- [ ] **34. Recommended delays and handwritten `[[hotstrings.terminators]]`.** [PHYS-W] Menu, save
      and restart acceptance
      ([checklist](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo34-delays-and-handwritten-delimiters)).
      [CI] Native Linux/macOS delimiter transactions.
- [ ] **37. Always show the shipped Ergopti pack.** [PHYS-W]
      ([checklist](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo37-shipped-ergopti-sections)),
      including build/install/upgrade/uninstall with both extension TOML files. [CI] macOS packaging
      and installation.
- [ ] **102. Two commands per Hotstrings category submenu.** [CODE] Not resumed. Windows additional
      personal-file persistence ownership and a personal-file identity gate shared by the live
      engine and previews; [CI] Windows native cases, Fedora/Alpine ShellRunner fixtures; [PHYS-W]
      ([checklist](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo102-personal-files-and-source-controls)).
- [ ] **104. Common autocorrection sections.** [CI] Native Windows/macOS, per-section E2E, package;
      the independent 140-rule corpus is never regenerated from production.
- [ ] **105. Programmable dynamic hotstrings.** [CI] The Windows worker probe never ran natively;
      macOS/Windows execution, E2E, package.
- [ ] **129. Built-in dynamic hotstrings only at word starts** (`update` must not propose `date`).
      [CODE] Not resumed. Composed release gate; review the six Linux unknown-context reset sites;
      [PHYS-W/M/L] real typing.

## actions (items 63, 71, 73, 91, 93, 96-98, 106-109, 111)

- [ ] **Number row: remaining checks.** The ordering is offered only where it reorders the effective
      row (digits first on AZERTY-like rows, symbols first on QWERTY-like rows, neither on Ergopti
      or mixed rows), the three edge keys can be reordered too, the layout emulation switches off
      row by row, and the built-in Ergopti row resolves from its own levels; layout emulation and
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

- [ ] **Ollama 0.40.4: compile and qualify.** [CI] Every driver pins 0.40.4 with the checked dialer
      and native HTTP hooks ported, and every managed server runs with `OLLAMA_NO_CLOUD`; the Go
      side has not been compiled anywhere yet (the source test applies the hooks without Go).
      Product decision for the maintainer, needs a Go toolchain: whether a download host that does
      not resolve is left to the proxy or the native worker, which reverses an assertion in
      `address_policy_test.go`.
- [ ] **46/47/48. Local models, discovery and owned runtime.** [CI] [PHYS] Real model, chat,
      download, consent, pause/resume/shutdown, HTTPS behind a system proxy, per-user install and
      restart. Windows managed AI was never received live; its private UI assembly is not adopted
      (it rejects the default `localhost` URL). [CODE] 17 baseline FFI failures in the Lua 5.4
      authenticated private-file fixture.
- [ ] **88. Prediction tooltip appearance.** [PHYS] Typography on the three OS.
- [ ] **112. Accept a prediction with its modifier+digit shortcut.** [CODE] Not started (it only
      highlights): insert through the acceptance owner and show the shortcut in a right-aligned
      muted column, same design on the three OS.
- [ ] **113. Promo-video i18n and performance.** [CODE] Sales-page placeholder rows
      (`_modifier_chords_placeholder`); regenerate GIFs
      (`npm run gifs -- personal-hotstrings screen-time ai-predictions`) without touching the video
      agent's uncommitted work; cache PAC resolution only after measuring.
- [ ] **120. Provider and model selection before enabling AI.** [PHYS-M] Installed menu; broad
      Ollama process termination on macOS stays debt.
- [ ] **124. Remove the Live mode submenu.** [CODE] Not started. Migrate the older source-scanning
      guards.
- [ ] **137. Publish the selected provider before model loading (macOS).** [CI] Hosted
      qualification.
- [ ] **Configured local servers (issue 94 follow-up).** [PHYS-M] Native acceptance of configured
      local discovery with a real oMLX install.

## macos-input (items 13, 24, 30, 31, 35, 40, 43, 44)

- [ ] **Dropped letters on macOS.** [PHYS-M] Unproven. Every typed key the driver consumed and never
      delivered is now reported ("typed key(s) swallowed", decisions only, never the key), and a
      stale one-shot Shift claim was fixed with the CapsWord policy. Mac action: Debug > Report a
      bug right when a letter disappears, then look near that time for "typed key(s) swallowed"
      against a lease failure or a Karabiner deploy.
- [ ] **117/140. Karabiner lease failures on Apple silicon.** [PHYS-M] Exit 73, PONG/READY timeouts
      since dev.155. The causes are now logged (see #95 point 4); the only workaround is
      Configuration > Ergopti uses Karabiner > Off. Replaying the 2026-10-19 log shows that
      recovery deploys (28 of 33 that day) cannot be reduced without fewer lease failures.
- [ ] **118. ANSI/ISO positions distinct.** [PHYS-M] Real ISO/ANSI typing and the final package
      (issue #95 point 5).
- [ ] **Issue 94 native acceptance.** [PHYS-M] Tap-hold menu change refusal, clipboard retention in
      symbol wrapping, ANSI/ISO layout captured once: portable fixes only.
- [ ] **13/35. Guardian lifecycle.** [PHYS-M] [CI] Signed helper ServiceManagement registration,
      wrong-inode refusal, unregistration, idempotence and job absence on both architectures; enrol
      the complete acceptance collector in main CI [CODE]. Never infer retirement from a signal, a
      missing handle or a hidden dialog.
- [ ] **24. Tap-hold outage guide.** [PHYS-M] Login Items approval and retirement on a real Mac.
- [ ] **30. Physical magic key on the three OS.** [PHYS] Windows capture under emulation, macOS ISO
      and ANSI (Backquote and IntlBackslash), Linux grab, injection and hotplug. [CODE] Not started:
      on Linux, choosing Backquote/Minus/Equal silently overrides a tap-key action.
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
- [ ] **127. VS Code bridge retirement.** [PHYS-M] Installed startup.
- [ ] **Carbon and daemon-report Swift.** [CI] Carbon fixture compilation and both-architecture
      receipts; daemon-report Swift allocation compiler failures on Intel and Apple silicon.

## release-network (items 36, 62)

- [ ] **36. macOS `.tar.xz` release archive and Brew/Sparkle acceptance.** [CI] Final macOS Package
      job: Sparkle install/refusal/retry/relaunch, both Brew positives, full-policy denial, all Brew
      archive scenarios. The Brew deny-removal AppleEvent positive has no supported consent path on
      hosted runners [PHYS-M]. Linux side: Flatpak/AppImage full-format installation and
      PAC/session/TLS delivery; the `.rpm` now builds for x86_64.
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

Source-only proposals found while hardening Linux (items L5-L145). Each owner reproduces natively
first; none is a confirmed defect.

- **Windows**: curl `--disable` as the first argument (L49); URL globbing off (L83); empty header
  value serialization (L98); initial scheme fence on the async curl (L48); sync WinHTTP header
  CR/LF/NUL and replacement validation before cancelling (L45, L46); release parsing by raw regex
  for tag, publication time, prerelease and the array brace scan, and the notes wrapper/CR handling,
  instead of the strict shared JSON decoder (L102, L104, L107, L108, L110); `SQLite_Utf8ToStr` uses
  a length-unaware `StrGet` (L128); UTF-16 ceiling in the provider error prefix (L117); missing
  launch/quit app events (L25); manifests omit `switches_to` (L133); public NUL guards on file paths
  and spawn bridges (L15, L40); embedded NUL in SQL literals (L55); `json_group_object` merges a NUL
  histogram key (Linux fixed, L124).
- **macOS**: NUL boundaries in the sync shell, task bridge, text SHA-256, OpenSSL heredoc and
  exact-input pipelines (L12, L20, L35-L39, L44, L54, L55); initial URL bridging (L41); public
  native-follow HTTPS downgrade (L43); cancel-before-validate on replacement (L45); logger ignores
  write/flush returns (L23); raw protected-exception text in logs (L30); dashboard partial side
  effects on exception (L29); file-existence fallback without `hs.fs` (L31); direct append lacks
  non-regular-file admission (L94); diagnostics report close unchecked (L85); dashboard opens SQLite
  with default flags before `query_only` (L56); device registration uses REPLACE and loses import
  metadata (L88); cached event cursor and numeric bounds (L82); UTF-8 byte cut in the provider error
  prefix (L117); timer error formatting (L112); parent traversal treats both separators (L64);
  manifests omit `switches_to` (L133); `hs.task` descendants and forceful kill (L18).

## Linux hardening: open items

The other Linux hardening items (L5-L145) are delivered apart from the generic caveat; the metrics
items L121, L124, L130, L134, L135, L140, L143 and L145 are done. The items below still need
software work.

| Item | Subject                         | Remaining work                                                                   |
| ---- | ------------------------------- | -------------------------------------------------------------------------------- |
| L69  | `FileSystem.read` special files | `read_with_status` and the shared TOML reader are still FIFO-unsafe (TOML owner) |
| L77  | Event-loop wait EINTR           | The reserved injector wait has the same unfixed EINTR diagnosis                  |
| L94  | File write endpoint admission   | macOS direct append lacks non-regular admission (macOS owner)                    |
| L103 | Event-loop reentry guard        | No-luv periodic clock issue diagnosed, left unmodified pending coordination      |
| L105 | Finite timer admission          | Native huge-range timer and no-luv clock diagnoses unmodified                    |
| L115 | Provider error envelope guard   | Unprinted callback-recorder failure in the unchanged HTTP fixture, cause unknown |
| L126 | Callback diagnostics            | Vision object and outer HTTP diagnostics unmeasured                              |

Metrics follow-ups:

- [ ] **Linux metrics reader.** [CODE] Raw fields containing NUL are still projected through the
      SQLite CLI; an open session is lost when the daemon crashes before its flush.
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
