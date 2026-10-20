<!-- docs/ERGOPTIPLUS_TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-20. Latest stable: [v1.0.3](https://github.com/adrienm7/ergopti/releases/tag/v1.0.3)
(tagged 2026-10-18, with deferred macOS native scopes, see
[below](#next-release-with-nothing-deferred)). Open work only: a finished item is removed, its
lessons go to [docs/memory](memory/README.md), and the history stays in Git
(`git log -p -- docs/ERGOPTIPLUS_TODO.md`). Item numbers are stable and never reused. Groups follow
the [parallel work contract](handovers/2026-10-04-parallel-containers/PARALLEL-WORK.md).

Tags: **[CODE]** software to write or adopt; **[CI]** only a hosted or native CI run qualifies it;
**[PHYS-W]**, **[PHYS-M]**, **[PHYS-L]** needs a real Windows PC, Mac or Linux machine.

**Generic caveat, stated once.** Unless an item says otherwise, native macOS and Linux qualification
and every physical-device acceptance remain OPEN and their qualification flags stay false; portable
tests, containers and software-supplied events are never physical evidence. The maintainer has a
Windows PC (physical tests on request) and a work Mac (reproduce on CI first, then at most one short
command); there is no Linux machine.

## Priority 0: Windows

### Windows session handover (October 20)

The Linux container session stopped on October 20; the next session runs on the maintainer's Windows
PC (real AHK, native Windows suites without a CI round trip). Read the latest dev CI run first.

Maintainer decisions of October 20, applied without asking again: retained menu clicks that meet a
reload are replayed in the successor (done on Windows, below); the Windows release list and its ETag persist
across restarts (done, 3d7b9d7481); `config.toml` keeps the 5/3 blank-line style and
`windows/_generated/config_template.toml` changes only through `npm run build:manifest` (done,
be30824e92); the three drivers share the structured personal info editor, the raw Linux
`personal_info.toml` bridge is retired (done, 54bd2bcbdd); the Flatpak builds in its own parallel
Linux job (prepared in 6310b316bf, validate on `tmp/*`); dev reaches main only with the next
release, so Deploy site failures on main are expected until then.

Session order (all four requested):

1. Run the AHK suites locally: `config`, managed network and artifact curl groups, then the full
   suite (sharded, `--only` or `--shard=K/N`).
2. Implement the menu-click replay.
3. Reproduce the Windows reports on the real machine: key combinations after c89d74eb, number-row
   precedence, `TOML_ParseDocument` cost, prediction-key and script-chord stalls (item 114).
4. Keep pinned ruff 0.15.8 and Prettier before every commit. After touching a sealed Windows updater
   source, reseal its cohort inputs with
   `node tools/ci/seal-windows-updater-original-source.cjs --ref <commit> --write`.

### Open Windows items

- [x] **Menu clicks that land after a reload.** [CODE] Done (October 20): `MenuCommandRun` holds
      a command that lands while a reload is pending, OnExit publishes its tray row path once
      (`menu_reload_replay.json` beside `paths.toml`, `infra/menu_reload_replay.ahk`), and the
      successor's startup owner consumes it at boot and replays the row after input readiness; a
      refused reload runs it in place, and a row the successor cannot match once gets one localized
      notice. Still open: check macOS and Linux for the same pending-reload window. Tray clicks
      retained during a slow startup ran when the configuration write they waited for ended; when
      that write was a hotstring intent that requests a reload, each retained toggle was refused
      (`terminal_barrier_busy`, one error toast each).
- [ ] **Slow configuration transactions: repeated registry liveness checks.** [CODE] `AllLive` in
      `config_transition_runtime.ahk` re-runs every destination guard before and after each native
      operation (`Dispatch`, `Read`, `Delete`, moves), and each guard deep-compares the shipped
      migration registry (about 10 ms): O(files x operations), most of the local-server and
      configuration-scope group time. Decide whether one liveness proof per `AllLive` call keeps the
      custody guarantee; keep the mid-transaction mutation refusals that `test_config_migrate` pins
      (a plain cache is not enough). `ConfigMigrateRegistryChecks` counts calls.
- [ ] **Semantic TOML parse cost.** [CODE] `TOML_ParseDocument` takes about 110 ms for the
      maintainer's 830-line `config.toml`; every document-mode write parses source, expected model
      and final candidate, and every start pays two builds after ready. Profile the tokenizer
      (`_TOML_DocumentToken` per character) and reuse one parse per transaction before adding any
      cache.
- [ ] **Reported number-row precedence (October 13).** [PHYS-W] With an emulated layout and "Digits
      first", Shift reportedly still gives the Windows AZERTY symbols. Ergopti emulated over AZERTY
      resolves correctly (`digit-row-ergopti-emulated-shift` regression) and the same code shipped
      in v1.0.1, so the reporter's exact setup (native layout, emulation switch, CapsLock, outputs
      in all three modes) is needed. Fix only a confirmed discrepancy, with a causal regression, and
      check the other drivers.
- [ ] **Reported key-combination settings (October 15).** [PHYS-W] Likely cause fixed in c89d74eb
      (the pair menu was a released local `Menu`). Confirm with the tester on the next dev build; if
      it persists, ask for `[KeyCombinations] Pair`, `AHK drop detected` and `Menu command refused`
      log lines.
- [ ] **114. Prediction-key (1-5) and AltGr+Enter stalls.** [PHYS-W] Cause unconfirmed. Observe the
      resident process while it stalls; collect the Notepad stale-admission diagnostics before
      changing tooltips or hooks.
- [ ] **143. AI enable/disable latency behind an incomplete startup.** [CODE] Pass the exact
      caller-owned child through the root builder map so the queue settles without a second child
      construction; reduce startup cost (Rescan, schema checks). [PHYS-W] Re-measure the real click.
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
      capture a new one with the full watcher/debt state if it recurs.
- [ ] **Full Windows AHK suite.** [CI] It has never completed green locally (watchdog
      `_SUITE_MAX_TIMEOUT_MS`, 120 min; about 90 min single-threaded). Run it sharded on the PC;
      never raise the watchdog to make a run finish.
- [ ] **115. Portable JS suite on the Windows host.** [CODE] Fix the host-bound fixtures (Linux
      installer sandbox, drive-letter path given to a POSIX constructor, backslash `LUA_CPATH`,
      Sparkle POSIX mode, symlink privilege error 1314), so a local run equals the hosted one.
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
- [ ] **Windows AHK TOML fuzz.** [CODE] The fuzz callbacks check only the absence of unhandled
      errors, not the expected parse semantics.

### Physical Windows tests the maintainer can run

Record the commit, Windows build, scale, layout and emulation state for each run, and report pass,
fail or not executed per line. Use a disposable profile (`paths.toml` pointing at a scratch folder)
for anything that writes configuration.

1. **Seven-page wizard** (item 7): fresh, existing and moved folder; every page, Cancel, Finish then
   restart, rerun; No against recommended choices; changed-folder reads; real WebView rendering and
   persistence.
2. **Clear and Restore** (item 5): per category and global (Configuration menu) Clear and
   « Restaurer les valeurs conseillées », then restart; unknown and outdated keys preserved;
   effective recommended delays; personal hotstrings and personal-file tuning unchanged by Restore
   (#96 decision); exact backups; an external write is refused.
3. **Number-row and key-combination reports**: the two reports above, plus the ² key and a pair
   assignment saved and reloaded.
4. **Installed build**: install, start, open Diagnostics (cold and reopened), Quit while a keylogger
   flush runs (exits once, f95d0bfa0b), File/Exit and Windows shutdown with exit code 0; uninstall
   greyed on a source run.
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
11. **Menu-click replay**, once implemented: tray toggles clicked during a slow startup whose
    hotstring write requests a reload all apply in the successor, with no error toast.

## Integration (items 16, 38)

- [ ] **GitHub issue #96 (Windows, v1.0.3): fixed on dev, release and answer.** An editor-created
      category took the neutral-off default of an undeclared personal section (d31776170a). Restore
      no longer touches personal hotstrings on the three drivers (20a9858f3d, dc8421f3). After the
      next release, reply: the reporter ticks "metiers" once, or updates.
- [ ] **GitHub issue #95 (macOS, v1.0.3, maintainer's log).**
  - (1) oMLX added by hand: fixed (c67d70f1fe).
  - (2) oMLX running but never seen: each sweep logs four "Request timed out after 1500ms". The
    `localhost`/::1 hypothesis is not supported: all four catalogue servers timed out, including
    closed ports, and the proxy policy treats `localhost` and `127.0.0.1` alike. Needs one Mac
    measurement of both addresses, and a check for a system proxy or firewall:

    ```sh
    curl -sS -m2 -o /dev/null -w "%{http_code} %{time_total}\n" http://localhost:8000/v1/models
    curl -sS -m2 -o /dev/null -w "%{http_code} %{time_total}\n" http://127.0.0.1:8000/v1/models
    ```

  - (3) "Check for updates" HTTP 403: the unauthenticated GitHub API limit (60/h per IP). The three
    drivers name an exhausted limit with its UTC reset (`_shared/lua/updater/rate_limit.lua`); macOS
    (1d341534) and Windows (3d7b9d7481) keep the release list ETag across restarts. Done; release
    and answer.
  - (4) Karabiner lease timeouts (READY, PONG, watchdog exit 73): needs a Mac reproduction (items
    117/140).
  - (5) The shortcut on the key left of "1" targets the 105th ISO key (keycodes 10 and 50 swap on
    ISO Macs): needs the maintainer's keyboard type and configured shortcut (item 118).

- [ ] **AppImage catalog.** [CI] 3c4209e947 bundles libayatana-appindicator3 for the catalog's
      tray-less runner. Watch `install-linux` on dev, release, comment `/retest` on
      AppImage/appimage.github.io#10422 and fix what the bot reports. Polish: with no keyboard
      device the notice still names input groups.
- [ ] **CI duration from ~24 to ~20 minutes.** [CODE] The Linux lane is the critical path (Build
      about 7 min, then installed-archive cells). The separate `package-flatpak` job (6310b316bf,
      local) should let the other install cells start about four minutes earlier: validate on a
      `tmp/*` run that the Flatpak job is green, the install cells start right after Build, and a
      release-like run still lists the `.flatpak` asset. Then build the Linux packages per format in
      parallel (each install cell bound to the bytes it installs) and keep the graph symmetric (one
      row per OS).
- [ ] **Intermittent native CI fixtures.** [CI] Root-cause each from its next failure output:
      Windows `config` group (managed-network budget, artifact curl relay); Linux `updater` (clones
      cffi-lua at test time); Linux `desktop-webview` tone case (d6812d90); Linux `input-display`
      window switch (449529dc); macOS Go `TestIdleDeadlinePhysicallyRetiresPeer` (ad03a898). Close
      each after it stays green.
- [ ] **Integrate the maintainer's fix branches regularly.** Merge `fix/windows`, `fix/macos`,
      `fix/linux` into dev with `--no-ff`, validate, push dev, then fast-forward each `fix/*` only
      when it is an ancestor of dev. After a merge touching `run_all.ahk`, `test_framework.ahk` or a
      sealed source, reseal `tools/ci/windows-updater-original-diagnostic-cohort-inputs.json`.
- [ ] **Test parity across the drivers.** [CODE] Continue [the parity
      audit](audits/2026-10-18-test-parity-audit.md): next are Windows dynamic hotstrings and
      CapsWord behaviour, the remaining verbatim duplicate Lua test files, absence ratchets for
      deleted code, and one tidy `tests/` tree on the three drivers.
- [ ] **CI structure.** [CODE] Elapsed time per CI step, suite and test with a slowest-test summary;
      live Windows unit-log progress; four parallel lanes (Common/Windows/macOS/Linux: Unit, E2E,
      Build, Test-the-build) converging into Release.
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
- Managed model receiving: green twice on both architectures; cca8eb94 and 13b6f5c7 now print the
  Intel failure fields and the failed Go test names.
- Shortcuts discovery, launch AppleEvents, owned-runtime XCTest (ACL fix 0b7428c8): validate through
  a release-like run with Build and Install-and-launch green.

## config-menus (items 5, 7, 33, 42, 54, 81)

- [ ] **Configuration in diagnostic reports (October 13 request).** [CODE] Include the user's TOML
      files and their resolution order in system diagnostics and generated GitHub reports; keep
      exact non-secret settings, name missing or unreadable inputs, redact credentials, never upload
      personal configuration automatically. Same contract on the three OS.
- [ ] **Neutral installation and persistent layout UI (October 13).** [CODE] A new installation
      enables no layout emulation, system layout change or number-row inversion (explicit
      configurations kept). The wizard's layout step offers emulated layout, base/Shift number-row
      emulation and ordering as persistent controls that never reload the UI; one shared definition
      with capability reasons (layout emulation is AHK-only today).
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
- [ ] **54/81. Every menu row declared in the shared manifest.** [CODE] Drive the native-menu-row
      census to zero, one commit per menu with the baseline lowered
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
- [ ] **138. English diagnostic export and editable issue.** [CODE] Shared privacy/collection
      contract and three native daily-log collectors (a 64 KiB / 50-entry tail is not a day);
      [PHYS-W/M] installed copy, write, reveal and browser; GitHub field editability.
- [ ] **139. Remove personal identities from logs.** [CODE] Free-form text is not proven safe;
      historical logs unchanged; GitHub attachment URL revocation unestablished.
- [ ] **141. Newer configuration schemas read-only on every driver.** [CODE] The three drivers show
      `config.read_only.newer_schema` (58ef8cfcdd). Still open: grey the AI persistence actions with
      that reason and recheck retained callbacks.
- [ ] **142. Local driver control command for reload.** [CODE] Not started. Route through the
      lifecycle owner (pause, transactions, cleanup, successor identity); report requested, refused
      and completed separately; never start a duplicate driver or force termination; all three OS.

## hotstrings (items 34, 37, 102, 104, 105)

- [ ] **34. Recommended delays and handwritten `[[hotstrings.terminators]]`.** [PHYS-W] Menu, save
      and restart acceptance
      ([checklist](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo34-delays-and-handwritten-delimiters)).
      [CI] Native Linux/macOS delimiter transactions.
- [ ] **37. Always show the shipped Ergopti pack.** [PHYS-W]
      ([checklist](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo37-shipped-ergopti-sections)),
      including build/install/upgrade/uninstall with both extension TOML files. [CI] macOS packaging
      and installation.
- [ ] **102. Two commands per Hotstrings category submenu.** [CODE] Windows additional personal-file
      persistence ownership and a personal-file identity gate shared by the live engine and
      previews; [CI] Windows native cases, Fedora/Alpine ShellRunner fixtures; [PHYS-W]
      ([checklist](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md#todo102-personal-files-and-source-controls)).
- [ ] **104. Common autocorrection sections.** [CI] Native Windows/macOS, per-section E2E, package;
      the independent 140-rule corpus is never regenerated from production.
- [ ] **105. Programmable dynamic hotstrings.** [CI] The Windows worker probe never ran natively;
      macOS/Windows execution, E2E, package.
- [ ] **129. Built-in dynamic hotstrings only at word starts** (`update` must not propose `date`).
      [CODE] Composed release gate; review the six Linux unknown-context reset sites; [PHYS-W/M/L]
      real typing.

## actions (items 63, 71, 73, 91, 93, 96-98, 106-109, 111)

- [ ] **Independent number-row source and order (October 13 request).** [CODE] A custom-layout
      option emulates the number row's base and Shift levels independently; digits-first and
      symbols-first reorder the user's native row when row emulation is off and the emulated row
      when it is on, without hardcoded AZERTY/QWERTY symbols or touching AltGr levels. Live layout
      refresh, missing unavailable-reason text, shared locale labels.
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
- [ ] **107. Native / digits-direct / symbols-direct policy.** [CODE] Windows native-HKL symbols
      owner, macOS forced output, Linux input+XI2+writer join; [PHYS] number-row delivery.
- [ ] **108. Hotstring-editor shortcut follows the chosen magic key.** [CODE] Item 97's
      collision/source/modifier/output joins; [PHYS] delivery.
- [ ] **109. Branded debug GUI.** [CODE] Blocked: stock AHK 2.0.26 offers no supported invisible
      Variables/KeyHistory snapshot. Nothing implemented.
- [ ] **111. App switcher and cursor-display actions.** [CI] macOS compile, sign, query; [PHYS-M]
      two displays.
- [ ] **125. Free-text translation target.** [PHYS] Installed dialog, real inference.
- [ ] **126. Recommended two-finger gestures unassigned.** [PHYS-M] Built-in trackpad restore check.

## ai (items 46, 47, 48, 88)

- [ ] **Ollama 0.40.4.** [CODE] The catalogue and macOS build recipe pin 0.24.0, which cannot pull
      `qwen3.5:0.8b`; 0.40.4 removes `registry.go`, so port the checked dialer/address validation
      and the native HTTP wrapper on every driver.
- [ ] **46/47/48. Local models, discovery and owned runtime.** [CI] [PHYS] Real model, chat,
      download, consent, pause/resume/shutdown, HTTPS behind a system proxy, per-user install and
      restart. Windows managed AI was never received live; its private UI assembly is not adopted
      (it rejects the default `localhost` URL). [CODE] 17 baseline FFI failures in the Lua 5.4
      authenticated private-file fixture.
- [ ] **88. Prediction tooltip appearance.** [PHYS] Typography on the three OS.
- [ ] **112. Accept a prediction with its modifier+digit shortcut.** [CODE] Unimplemented (it only
      highlights): insert through the acceptance owner and show the shortcut in a right-aligned
      muted column, same design on the three OS.
- [ ] **113. Promo-video i18n and performance.** [CODE] Sales-page placeholder rows
      (`_modifier_chords_placeholder`); regenerate GIFs
      (`npm run gifs -- personal-hotstrings screen-time ai-predictions`) without touching the video
      agent's uncommitted work; cache PAC resolution only after measuring.
- [ ] **120. Provider and model selection before enabling AI.** [PHYS-M] Installed menu; broad
      Ollama process termination on macOS stays debt.
- [ ] **124. Remove the Live mode submenu.** [CODE] Migrate the older source-scanning guards.
- [ ] **137. Publish the selected provider before model loading (macOS).** [CI] Hosted
      qualification.
- [ ] **Configured local servers (issue 94 follow-up).** [PHYS-M] Native acceptance of configured
      local discovery with a real oMLX install.

## macos-input (items 13, 24, 30, 31, 35, 40, 43, 44)

- [ ] **117/140. Karabiner lease failures on Apple silicon.** [CODE] [PHYS-M] Exit 73, PONG/READY
      timeouts since dev.155; cause unknown. The only workaround is Configuration > Ergopti uses
      Karabiner > Off.
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
      and ANSI (Backquote and IntlBackslash), Linux grab, injection and hotplug. [CODE] Linux:
      choosing Backquote/Minus/Equal silently overrides a tap-key action.
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
      installed source.
- [ ] **127. VS Code bridge retirement.** [PHYS-M] Installed startup.
- [ ] **Carbon and daemon-report Swift.** [CI] Carbon fixture compilation and both-architecture
      receipts; daemon-report Swift allocation compiler failures on Intel and Apple silicon.

## release-network (items 36, 62)

- [ ] **36. macOS `.tar.xz` release archive and Brew/Sparkle acceptance.** [CI] Final macOS Package
      job: Sparkle install/refusal/retry/relaunch, both Brew positives, full-policy denial, all Brew
      archive scenarios. The Brew deny-removal AppleEvent positive has no supported consent path on
      hosted runners [PHYS-M]. Linux side: Flatpak/AppImage full-format installation and
      PAC/session/TLS delivery.
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
  and spawn bridges (L15, L40); embedded NUL in SQL literals (L55).
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

The other Linux hardening items (L5-L145) are delivered apart from the generic caveat. The fifteen
below still need software work.

| Item | Subject                         | Remaining work                                                                     |
| ---- | ------------------------------- | ---------------------------------------------------------------------------------- |
| L69  | `FileSystem.read` special files | `read_with_status` and the shared TOML reader are still FIFO-unsafe (TOML owner)   |
| L77  | Event-loop wait EINTR           | The reserved injector wait has the same unfixed EINTR diagnosis                    |
| L94  | File write endpoint admission   | macOS direct append lacks non-regular admission (macOS owner)                      |
| L103 | Event-loop reentry guard        | No-luv periodic clock issue diagnosed, left unmodified pending coordination        |
| L105 | Finite timer admission          | Native huge-range timer and no-luv clock diagnoses unmodified                      |
| L115 | Provider error envelope guard   | Unprinted callback-recorder failure in the unchanged HTTP fixture, cause unknown   |
| L121 | App category edit transaction   | Reader NUL projection through the SQLite CLI; lost post-COMMIT receipt             |
| L124 | Burst histogram key JSON        | NUL-key projection through the SQLite CLI                                          |
| L126 | Callback diagnostics            | Vision object and outer HTTP diagnostics unmeasured                                |
| L130 | Raw-event batch transaction     | Whole-flush atomicity, ID reservation rollback, exactly-once after lost COMMIT ack |
| L134 | Hourly manual corrections       | Physical Backspace never produces the `[BS]` marker (input hook gap)               |
| L135 | `[BS]` excluded from char count | Same physical Backspace gap as L134                                                |
| L140 | Ngram source conflicts merge    | Cross-flush session accounting                                                     |
| L143 | Backspace unigrams              | Backspace bigrams and trigrams not covered                                         |
| L145 | Ngram group atomicity           | Collector retry queue, raw replay, session cursor, post-COMMIT recovery            |

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
- **Maintainer workflow**: partial work is delivered into dev after the feasible container or CI
  work, with native or device gaps documented here rather than holding a branch.
