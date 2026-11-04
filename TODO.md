<!-- TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-31. Latest stable: [v1.0.8](https://github.com/adrienm7/ergopti/releases/tag/v1.0.8).
This file shrinks toward deletion after the next field reports: each machine section is one line per check, naming
the field-run step or the hand action that proves it and the commits it confirms. Conventions and tags:
[workflow and verification memory](docs/memory/workflow-and-verification.md). Finished items are in Git
(`git show 2a0083cb11:TODO.md` is the long form before this shrink).

## Handoff, 2026-11-03 late evening (read first if the session was lost)

- **Release 1.0.9 is pending on CI only.** dev `ed2618c2fe` holds every 1.0.9 change; full CI run 41730677937 is the
  release gate. Last reds before it were infrastructure (Ubuntu APT over 10 min in Shared UI rendering, macOS 26 XCTest
  lease lost, Windows keystats `metrics-native-sender` deadline): rerun those jobs once; any other red is real. When
  green: fast-forward `main` to that commit (`Release-As: 1.0.9` trailer only if the computed version differs), watch
  the publish, then clean up (below). Never push main for anything else.
- **Work for the next release, each on its own pushed branch** (rebase on dev, land by fast-forward only):
  - `next/ai-hotstring-tooltip` — AI tooltip never covers a hotstring tooltip; choice wait (default) / both. Done, CI
    reds same as dev. Left: try « both » by hand; Windows rows linger past expiry; macOS canvas does not follow height.
  - `next/key-names` — chord action labels, sticky/layer holds, tooltip footer from the key name table; Arabic and
    Chinese finger counts fixed. Left: physical shortcuts and metrics web pages; macOS `hyper`/`altgr` holds French.
  - `wip/gesture-clear-touchpad` (agent running) — Gestures « Tout effacer » also restores the touchpad (backup, else
    Windows factory defaults) and the Configuration row goes; « Infos… » instant (took 5 s) with a rewritten text in 21
    locales explaining the rare-shortcut trick; recommended set on all OS, macOS direction: 3 fingers ←/→ tabs (macOS
    incremental `ax_actions.tabs`, Windows discrete), ↑ new tab / ↓ close tab; 4 fingers ←/→ Space/desktop, ↑/↓ next /
    previous window of the app; macOS 5 fingers ↑ Mission Control / ↓ App Exposé; tap 3 left click held; tap 4
    `alt_tab_monitor`; macOS greys a slot whose system gesture is on (suffix about 20 characters, « — pris par macOS »)
    and suspends it until the system gesture is None; never write the macOS prefs.
  - `wip/layout-composer-responsive` (agent running) — the layout composer page reflows when the window is resized and
    no button sits behind the preview, same page on the three OS; Layout menu: « Couches émulées » header, the four
    rows in a « Rangées émulées (apprentissage progressif) » submenu.
  - `wip/windows-boot-time` (agent running) — boot measured at 7.8 s (parse 1.7, layout 1.2, hotstrings 1.0, tray 1.0);
    parser and snapshot fixes, counted-operations gate; approved: keyboard before tray, a tray click during boot waits
    for input ready. Still too slow: keep cutting (lazy includes, caches).
- **Cleanup after the release.** Remove every `.claude/worktrees/*` (delete the node_modules link first, never the
  real folder); delete local branches except dev and main; delete remote branches except main, dev, sparkle-appcasts,
  gh-pages and the `next/*` / live `wip/*` branches above; tag non-merged tips `archive/2026-11-03/<branch>` first.
- **After that:** owned bundled Karabiner (`next/owned-karabiner`), one Ergopti folder name, one config layout on every
  OS (items below); macOS field report rerun (`git pull && bash tools/dev/collect-macos-field-report.sh`).

## Branch `wip/layout-composer-responsive` (3 November, resume from this branch alone)

- [x] **Responsive layout composer, same page on the three OS.** Done in 47e87f0f0b: board in fractions of a
      full-width board, footer action bar, `WebView_FitToWindow` in every Windows Size handler; macOS and Linux
      already resized their view. Gates: `npm run test:browser:layout-composer`, `test_webview_fit_to_window.ahk`.
- [x] **Layout menu: layers and rows apart.** Header « Couches émulées » above the two layer rows, the four row
      switches in the submenu « Rangées émulées (apprentissage progressif) »; decision in maintainer-decisions.md.
- [ ] **Next: land on `dev`** by rebase and fast-forward when the maintainer asks (never push `dev` or `main` from
      here). Branch rebased on dev 41e2888d08; CI run 41742438444 green except Linux alpine integration
      (`test_sqlite_first_open.lua` system-event capture, metrics, untouched here) and the macOS 26 build still
      running when noted. Chromium and WebKit ran the composer gate: 24 cases.

## Branch `wip/gesture-clear-touchpad` (gesture requests of 3 November)

Resume from this branch alone; it is based on dev 6d6b743c4f and not yet integrated.

- **Done.** Gestures « Tout effacer » restores the Windows touchpad (registry backup, else the Windows factory
  defaults of `precision_touchpad_registry.toml`), global clear too; Configuration row and its locale key removed
  (95ee89c868). Instant « Infos… » after a reload (27c7e13053, a18cfaecff). Infos text: the Windows rare-shortcut
  trick, macOS/Linux read the touchpad (9d8d16237a). One recommended set on every OS, macOS direction (6bc43f8d44),
  macOS five fingers up/down = Mission Control/App Exposé (6fd5f27e95); macOS tabs already scale (mode
  incremental), Linux scalable swipes queued below (c99fe71d17). macOS greys and holds back a slot whose macOS
  gesture is on, short « — pris par macOS » suffix, recheck every 20 s (bccbdb185c). Updater sources resealed
  (5b6ee92094).
- **In progress.** CI `os_lanes=all` on bccbdb185c. Known reds also red on dev 6d6b743c4f: Common Menus
  (`test-menu-parity.cjs` macOS configuration dispatch fixture) and Linux fedora (OpenSSL signature tests).
- **Next.** Rebase on dev and hand over for integration; on the Mac, check that a slot greys when its Trackpad
  gesture is on and comes back when it is off, and that a three-finger swipe moves tabs with the distance.

## Release 1.0.9 (maintainer requests of 1-2 November, written so the work survives a lost session)

Release as 1.0.9 on `main` by fast-forward from `dev`, with `Release-As: 1.0.9` if the computed version differs, once the
three-OS CI is green on the final source. See the handoff above for the current state.

- [ ] **Macos field report 2026-11-02.** Rotation warnings at midnight during the recovery; `event_taps` run loop late:
      main thread held 1.5 s, `menu.rebuild` 1.3 s (`menu_item.shortcuts` about 1 s); `diagnostics` phase A over 5 ms;
      `idle_cost` 8.35 %; Ollama `digest_mismatch` on `granite4:350m-h` twice, after the retry. Then rerun the report
      without touching the Mac.
- [ ] **Slowness, every driver.** Windows boot 7 s, `menu.rebuild` 1.7 s: lazy submenus, single-toggle update, one
      registry proof, full save after ready, disk caches; a toggle must not rebuild 1000 rows.
      Resume here (branch `wip/windows-boot-time`): parse fixes, the smoke operation caps, keyboard before tray root
      and the queued early tray click are committed (keyboard registered at 4.5 s instead of 5.1 s on the smoke
      fixture). Next, largest first: the emoji and symbol sections take 406 of the 1031 ms hotstrings stage on that
      fixture; defer them after ready in slices of a few tens of ms, but their registration order feeds the
      collision tie-break (`_DynHS_RegisterAll` and the repeat key must stay after them): reserve their `Seq` block at
      the boot position, and keep the preview index complete. Then script parse (lighter boot includes; AHK has no
      runtime include, so only a smaller graph or a worker helps) and layout (rejected disk cache: native hotkey
      registration). Measure each with interleaved base/candidate smoke-fixture boots (summed `process_cpu`). CI of
      the branch: run 41737399378 (first run 41732233161 found two branch regressions, fixed since; its PAC and
      action-picker WebView reds pass locally).
      Windows boot, 3 November. Real logs: 4.75 s at best, 7.8 s typical, 15 s and more
      under load; parse 1-1.7 s, layout 1.2 s, hotstrings 1.0 s, tray 1.0 s (AI submenu 0.75 s), pre-logger 1.2 s.
      Three boots waited 24 s, 26 s and 446 s on a tray opened during boot (`native_menu_wait`): input waits for the
      open menu. Done, measured on a smoke fixture made from the maintainer's config (median of 3 interleaved runs,
      process CPU 7.75 → 7.20 s, menu usable 6.6 → 5.5 s; realistic-hotstrings fixture: hotstrings stage 1.9 → 1.1 s):
      quoted TOML text lexed in native runs (personal file parse 463 → 165 ms), snapshot comparison without map
      copies, one boot snapshot read for the AI options (4 → 1), personal-file metadata decodes only `[_meta]`
      (468 → 29 ms for three 35 KB files). Gate: the startup smoke bounds the boot's counted operations
      (`BOOT_OPERATION_CEILINGS`). Left, deliberate or rejected: parse, layout and hotstring registration (about
      4.4 s) are needed at the first key; the remote AI catalogue (212 ms, rejected while the AI root is eager); the
      boot's 9-13 registry deep compares (every write compares).
- [ ] **AI menu.** "Test a prediction" under the profile row: group model, profile, test, never two separators in a row.
      The test uses a high temperature, bypasses the cache, never a fixed string, and shows the generation time.
- [ ] **Generation parameters submenu.** Predictions count, min and max words with no separator; one separator; all the
      context rows at the bottom (two separators become one).
- [ ] **Prediction indentation default -3**, recommended -3, all drivers.
- [ ] **French punctuation.** Space before `:` in composed `label: value` rows and about 21 strings, with a gate.
- [ ] **Multi-prediction tooltip.** The number is right-aligned in the tooltip, not stuck to the text.
- [x] **macOS one-shot Shift is not one-shot.** Tap it then type « abc » quickly: « ABc » or « ABC ». It must be spent
      by the first key; today it seems to end only on its timeout (configurable in the menu, can be infinite). Check
      the F20 one-shot sentinel path (modules/keymap/one_shot_shift.lua, adapters/one_shot_shift.lua) against Windows
      and Linux, with a regression test typing three keys inside the timeout.
- [ ] **One configuration layout on every OS.** A macOS configuration imported on Windows or Linux must work as it
      did, Cmd versus Ctrl aside. Today the tap-hold settings live in three shapes: Windows `config.toml` plus
      `tap_hold.toml`, macOS `config_karabiner.toml` (keys, global delay, sticky delay, key combinations, and now
      `tap_holds.lone_modifier_tap_max_ms`), Linux `tap_hold.toml` (keys, switch, and the lone tap window) plus
      `config.toml` (`mod_combos`). Pick one home per manifest path (the manifest's `config.toml` for every
      `[[features.*]]` row, one shared tap-hold file for the keys), move each driver's reader and writer to it,
      with one migration of the old files, and a cross-driver test that writes a file on one driver and reads it on
      the other two.
- [x] **Metrics and gestures section titles.** The metrics section « Mots par minute » becomes « Vitesse de frappe »;
      the gestures menu gets one section title per finger count (« Gestes à 2 doigts », « à 3 doigts », …) and no
      « Gestes Ergopti » title; « Gestes du système » gets a clearer title saying the system gestures are handed to
      Ergopti so it can change them (synchronisation of the system gestures), all drivers, 21 locales. In the
      shortcuts menu the « Sélection » section title becomes « Encadrement de la sélection ».
- [x] **Download proxy row out of Debug.** The download proxy setting is configuration, not debugging: move it from
      the Debug menu to the Configuration menu, all drivers.
- [x] **Hotstring tooltip under the AI tooltip.** Option `llm.trigger.while_hotstring_tooltip` in the AI trigger
      menu, 21 locales: "wait" (default and recommended) holds every automatic request at the debounce, the spinner
      and the render while a hotstring tooltip shows, and the chain after the hotstring asks again; "both" draws the
      hotstring rows and the prediction in one stack (Windows one surface, Linux one window, macOS the prediction
      canvas under the rows). Live mode always waits; a prompt asked for by name is never held. Field check left:
      "both" on a real desktop, and the Windows header rows stay until the next render after their own expiry.
- [ ] **Key names, what lot CH left.** Menus now name keys from `_shared/data/keycodes/key_names.json` in the 21
      locales. Still raw or French: the shared modifier-chord action labels (« Cmd + Option + Shift + Enter » in the
      action pickers, all drivers; tests pin this label family, so it needs its own change); the macOS sticky holds
      and `layer` hold labels; the tooltip footer hints in `_shared/modules/tooltip/constants.toml`; the physical
      shortcuts and metrics web pages. Arabic `gesture.slots.swipe_5_horiz` says four fingers.
- [ ] **Model selection page.** Install Ollama and Install MLX buttons act or say why, disabled when installed; a whole
      section header opens its list; header on two lines (install, port, status; then add a model by hand); Ollama and MLX
      models grouped in collapsible sections per provider, alphabetical; search crosses sections; gate for page actions
      with no host handler.
- [ ] **Options greyed.** Disable in browser address bars and in password fields can be changed, or say why not.
- [ ] **Defaults and recommended.** Each manifest row declares feature or setting, CI gate, empty config boots neutral,
      missing option takes its manifest default, Restore recommended restores adjusted settings too (see
      docs/memory/maintainer-decisions.md).
- [ ] **Keep Ollama behind a proxy.** 0.40.4 downloads blobs outside the proxy; 0.40.6 fixes it, shared pin needs a Mac rebuild.
- [ ] **Before publishing.** Whole AHK suite on a quiet machine with no resident driver, `npm run test:ahk-tray-rows-read-as-text`,
      all live checks including `quit-over-a-log-flush`, JS, macOS and Linux suites, Windows field report with a driver.

## To confirm on the Mac

Check out `dev` (or the branch to test), set Debug > Log level > DEBUG, then run
`bash tools/dev/collect-macos-field-report.sh`: it creates `field/mac-<today>-<branch>`, runs the field checks in
the developer app, writes the report under `docs/field-reports/`, commits and pushes. Needs Go, the Xcode Command
Line Tools and python3 3.11.4 or newer; `swift test` needs full Xcode.app (install once from the App Store). Read a
red step with its `proves` line in `static/ergopti_plus/macos/data/field_run.json` and
[project-macos-field-run-step-details](docs/memory/macos-hammerspoon.md). Report each line as pass, fail or not run.

Field run, no person needed (read the next report):

- [ ] Owned Ollama starts and pulls: `field_ai_local` ready daemon and a done pull (6170813ea9, 6335790e5a,
      894585a213, b71b4a67db, 4545f672d1, 721074f21d).
- [ ] Test models: one complete Ollama and MLX test-model download on a connection that does not count (e8ff7479e1).
- [ ] Timed reload: `driver_reload` passes and `reload.request_to_boot` is under 4000 ms (b12a654d79, 02c58f8a94,
      c366dd1c5b, c0ba1d98bb, 8121349ee7, e6426e2ec5).
- [ ] Remap guardian: `field_login_items` `developer_adhoc_reregistered` on a Mac that holds an earlier build's
      Background Items record, no `ErgoptiPlus` codesigning kill in `field_app_health`, `guardian_state` ready with
      `guardian_wait` under 10 s, and the same on an Intel Mac (2be257c9f5). Hosted CI proves the ad hoc installed-app
      path on Apple silicon: registration, repeat registration (62eb698420), readback (34888894dd) and retirement pass
      in all five Install-and-launch rows (run 41257389239).
- [ ] Main-thread holds (ledger L16, L17, L18, L23; 0b679b0b0d, b5c0c0de37, c17aa3e5d7, 71a8b87f65, 236ea82e52,
      933707a1ae, 016ef6adc5, 58f82e9fdc, 6c30779ec3): menu rebuild (`field_menu_build` `menu_layout_slowest`,
      `slow_hold_phase`), preferences save (`slow_preferences_save_stage`, `_forks`), keystats append and ledger read
      (`slow_ingest_*`, `worst_hold_site`), healthcheck and ignored-window probe (`slow_diagnostics_collector`,
      `slow_ignored_window_*`), one-off holds (`worst_hold_site`), `keystats_start_ms` under 100 ms. Each names the
      stage to bound next.
- [ ] L24 key events: re-read `key_event_health` totals once the holds are gone (82c220c089); key-ups lost without a
      hold point at the Karabiner virtual HID path.
- [ ] L32 memory: read `memory_footprint_mb`, `memory_region_1..5` and `lua_heap_mb` in `field_app_health`
      (cce99afbc7, 58961fd2b2, f7faaa0558).
- [ ] L42 off the company network: `03_field_network` passes with `pac_download info:unreachable_direct`,
      `pac_script skip:not_fetched`, `route_lookup pass:selected:direct` (5d93e78e90, 1dfaec8298, ec15345d22,
      8fedb505dd).
- [ ] L43: `04_field_toolchain` `karabiner_signature` reads `info strict_only:finder_detritus` (cc172a504d,
      58fd867081).
- [ ] 116: `field_toolchain` third-party report (timer, Shortcuts, Homebrew, Karabiner signature, Gatekeeper).
- [ ] Composer (L52): `06_field_composer` passes after a single re-read.
- [ ] Keystats cache: `field_storage` `keystats_cache_place` is `caches`.
- [ ] Karabiner lease 117/140: `lease_failure_kinds` and `memory_free_percent` (25411ee080, 380ad99aa8); a low free
      percentage next to PONG/READY kinds confirms starvation.
- [ ] Lease deploy write: `deploy_write_verdict` is `keep`; `shrink` means code to write (make the 743 KB file
      smaller).
- [ ] Owned Karabiner runtime: `field_owned_runtime`, then on an owned boot `field_owned_start` and
      `field_owned_pause`; the next run's `field_owned_start` proves close-on-resume.
- [ ] Layout rows: `field_layout_rows` answers M4 to M6 (91725b18f7, fc5d3a11df, aaf3518af7); on `select_refused` or
      `requires_logout` the live path needs the design note's in-bundle route.
- [ ] Apple Shortcuts (106) and the new actions (`run_command`, `open_path`, `run_apple_shortcut`, on dev, not
      field-verified): `field_apple_shortcuts` `field_test_run`. First create a no-op shortcut named
      `Ergopti Field Test` in Shortcuts.
- [ ] PAC unusable on a network whose PAC is unreachable: `field_pac_fallback` `direct_worked` for an Ollama pull and
      the MLX install.
- [ ] Ollama behind a real PAC: `field_ollama_blob_host` and Debug > Test network.
- [ ] Log-only checks of the 2026-10-30 report, each failing by name in `field_slow_lines`: no
      `log_shortcuts_still_unregistered` after a rebind retry (else rebinding needs the `hs.keycodes.map`
      notification); no `log_keystats_database_locked` (8084562373); no `log_lease_bound_failures` nor
      `log_layout_change_before_baseline` (item 38).

Hands needed:

- [ ] Hotstrings (axa): `axa` + Space fast twenty times, also holding `a`: always `AXA`, with
      `Synthetic text moved off a held key` in the day log; ordinary hotstrings in Edge, VS Code and a terminal.
- [ ] oMLX on port 8181 is found in API mode with no `ps` deadlock (`field_local_servers` names it).
- [ ] Gestures: one « Infos… » row that opens the dialog; `tap_3` recommends left click.
- [ ] L46 with no explicit `[gestures.sensitivities]` swipe_3 value (6d3aa65273; `field_gesture_frames`): minutes of
      two-finger scrolls switch no tab; deliberate vertical three-finger swipes (slow, flick, staggered, after a
      scroll, finger resting, ten half a second apart) each switch exactly one tab, past 29 units two; a miss logs
      `Three-finger candidate rejected by <gate>`; no `has no capture timestamp` ERROR after a reload.
- [ ] Ctrl+Caps Lock: type it during a session before the field run; `field_capslock_chord` `never_delivered` drops
      the slot's macOS recommendation with a reason (ea02cf7000).
- [ ] Dropped letters: a day of typing in Safari, TextEdit, Terminal, VS Code and an Electron app, then the field
      report (`swallowed_keys`); Debug > Report a bug right when a letter disappears.
- [ ] Production profile: the same working day feeds `field_boot_cost`, `field_idle_cost` and `field_slow_lines`;
      also three cold starts and one after a login (`Boot complete in`, `Boot CPU`).
- [ ] Event taps refused, personal hotstring reload rolled back, MLX POST routes 404 after a repair, screenshot
      without an image: read the named step or `accessibility_trusted` on the next occurrence.
- [ ] Native ownership contracts with Xcode.app: the launcher XCTest suite, the FSEvents start refusal
      (`macos/infra/file_watchers.lua`), POSIX filesystem capability and ServiceManagement boundaries (hosted CI, run
      41257389239: Launcher XCTest on macOS 26, Native XCTest on macOS 15 Intel, Build and all five Install-and-launch
      rows green for the owned-runtimes Swift and the guardian fixes; a local `swift test` run on full Xcode.app
      remains).
- [ ] Schema v15 and v20 (PAR-41): an old `config.toml` with parameterised slots keeps every action under its role
      id; a v19 file with `ctrl_g = true` opens the ChatGPT URL on Ctrl+G and loses `ctrl_g`, `false` leaves the
      slot empty; old `[llm.profiles] user_profiles` still show (PAR-40).
- [ ] Ten window-toggle actions bound to shortcuts: open, raise when covered, close when frontmost, restore when
      minimised; `open_model_browser` right after a reload and with the AI off logs no `window_toggle` ERROR.
- [ ] Menus: Clear and Restore per category and global; Shortcuts group restore and clear; tap delay row and « Use
      global delay (…) »; tap and hold pickers; « Combinaisons de touches »; row order unchanged (PAR-76 R18);
      « Retirer les anciennes règles » on an upgrade (43); Login Items show one Ergopti (24).
- [ ] Typing: chained expansions, magic key on ISO and ANSI, undo by Backspace, password field, ignored app, no
      wrong erase count (PAR-76 R26); tap-hold rolls; Right Option + Return/Delete/Backspace/Escape; Backspace word
      start (Terminal, TextEdit, Safari Cmd+L); CapsWord cancelled by the pointer (44).
- [ ] AI with a real local model: request floor, explicit shortcut never held, variants, replace in flight, debounce
      "never", live mode; AI off disarms keys and agent actions (PAR-65); tooltip near edges on two displays (111).
- [ ] Network and updates: Debug > Test network on the office network and at home, an `http://` company PAC
      (Issue #101 fixes); release notes pane in light and dark (PAR-52); a Sparkle update; Homebrew live upgrade;
      MLX behind a proxy (119/130/136, code 74).
- [ ] Pages in light and dark (PAR-81); onboarding wizard (7); App Cloner errors (4550befb08); trackpad gestures
      (126), Diagnostics focus (122), shared export (123); reload menu clicks held and replayed; quit while busy ends
      both processes in 10 s.
- [ ] Issue #100 (2353a72eed, 25411ee080, e57f4cce77): with Ollama.app and a PAC proxy, enabling the AI downloads
      the model; the menu held open causes no lease timeout. Issue #99: `memory_pressure` during lease errors, which
      login item starts a second Hammerspoon, declining the download opens no error window.
- [ ] Installed app: guardian registration and retirement on both architectures (13/35), VS Code bridge retirement
      (127), 120 provider menu, issue 94 (tap-hold refusal, symbol-wrap clipboard).
- [ ] App Cloner (81b3cda6a8): on a Mac without the Command Line Tools, Apps > App Cloner offers the install and
      "Install" finishes with no Xcode prompt; clone one app and one PWA, both launch; the PWA launcher shows
      `exec "$CLONE_PYTHON"` on the versionless link; double-clicking App Cloner in Finder shows the localized refusal.
- [ ] VirtualHIDDevice offer (3ebab93a17): on a Mac whose active driver is older than 8.5.0, Tap-holds > update row,
      admin prompt, installer, forceActivate; the report names the new version and the remap reloads; cancelling the
      prompt reports `cancelled` and changes nothing.
- [ ] Run the field report once: its `scpt_recompile` step rebuilds `Encryptor.app/.../main.scpt` from its updated
      `.applescript` (keystats rename) and commits it on the field branch (710f0a379d); cherry-pick that commit.

## To confirm on the Windows PC

Run by the PC agent from a fresh `dev` on a `fix/windows-pc-<date>` branch; push the branch, the coordinator
integrates. Every commit keeps the AHK UTF-8 BOM, reseals a touched updater source and passes the Windows lane
(`gh workflow run ci.yml --ref <branch> -f os_lanes=windows`). Rules and ported work:
[PC handoff](docs/tooling/windows-pc-agent-handoff.md). Order:

1. Parse and run the full AHK suite (`run_all.ahk`, then `e2e/run_e2e.ahk`) and fix what fails. Never executed yet:
   the field run, budgets and LLM latency line (e4ffacc709, 8d52300169), the menu without dynamic rows (eeee484c6c,
   65f298c3f7), thinking off and model capabilities, the per-account provider form and access-token refusal
   (`test_llm_api_url_template.ahk`, `test_llm_api_add_account_address.ahk`), the owned daemon's proxy (743181a933)
   and `vendor/ergopti_route_plan.ps1`.
2. Field report: `powershell -ExecutionPolicy Bypass -File tools/dev/collect-windows-field-report.ps1` (5.1, then
   `pwsh`) with `tools/dev/run-windows-dev.ps1` started, plus the runtime layer of
   `test-windows-field-report-contract.cjs`; this is the first real run of the field run without a click
   (e5315ec576, 29cb604df0, e4ffacc709) and of the report marks.
3. The Windows items of "Remaining code work".
4. The checks below and the [standing checks](docs/tooling/windows-maintainer-checks.md#standing-checks) 1 to 15
   (`node tools/maintainer/windows-live-checks.cjs` runs the automatable ones).

- [ ] Tray > Gestures: one « Infos… » row that opens the dialog.
- [ ] Ollama or oMLX on a non-default port with the process scan failing: still found.
- [ ] `axa` then Space fast, 20 times: always `AXA`.
- [ ] Personal `sru` -> `SRU` (priority 100) beats the bundled `sru` -> `sur` (4741950f04); a hotstring with `{left}`
      moves the caret.
- [ ] Live Ollama: token-by-token predictions display, then enable the row (PAR-12).
- [ ] System Ollama on 11434, AI on: Ergopti's listens on 11435, the other is untouched (f016081056, 597cbbe983).
- [ ] Item 50: `fb` + Space, Enter and ★ with the abbreviation and brand packs, at 1, 2 and 3 arrows, consumed and
      not.
- [ ] Composed layout on a real keyboard (Debug > "Test the composed layout").
- [ ] api.github.com blocked: the update check's Atom fallback reports the version.
- [ ] "Create a GitHub issue" signed in opens the form with no "Whoops" page (4e63c54c8a).
- [ ] Updater: install a build with 5d6beccf83, update: the exe restarts, the three scripts are in
      `%LOCALAPPDATA%\Ergopti\vendor\`, the command line shows `-File`, no `-EncodedCommand`.
- [ ] Developer mode: `tools\dev\run-windows-dev.ps1` with the exe running closes the exe, the tray appears, saving
      an `.ahk` reloads once; `npm run dev:windows` from Git Bash and cmd; double-click `ErgoptiPlus.ahk` with and
      without the exe (expected lines in `docs/design/developer-mode.md`).
- [ ] Ten window-toggle actions, also without WebView2 (native fallbacks): no orphan WebView2 process.
- [ ] Manual steps 1 to 4 of [windows-maintainer-checks.md](docs/tooling/windows-maintainer-checks.md) (Win+S,
      Backspace word start, Versions Retry, pair popup).
- [ ] Brightness joined source; retired Metrics shortcuts across a three-OS full save and an installed upgrade (63,
      71).
- [ ] Corporate network (item 62; 1d15b51e66, 7c001b2456): Debug > diagnostics (`github_api`, `proxy_pac`), a model
      pull behind a PAC (and with the PAC unreachable, d20d328751), the Windows security warning for the native CA
      case, Kerberos, TLS inspection and revocation.
- [ ] Item 49: the terminal-capture hardware list. Item 91: held-alone-then-joined order, AltGr hook provenance.

Account and tester actions (maintainer, from the PC):

- [ ] SignPath application ([answers](docs/tooling/signpath-foundation-application.md)), then its variables and
      secrets (132).
- [ ] Update-signing key ([five steps](docs/tooling/update-signing.md)), one release with `off`, then `required`
      (PAR-30, fe5a1c2340).
- [ ] VirusTotal lookup, Microsoft Defender and vendor submissions
      ([pack](docs/tooling/windows-exe-false-positive-submission-pack.md)).
- [ ] Testers: Netskope tester's download retry, T1-T4 ([matrix](docs/tooling/windows-exe-flagged-by-proxy.md));
      number-row, key-combination (c89d74eb) and priority-100 (cf29c35e5f) testers with their exact setup.
- [ ] `/retest` on AppImage/appimage.github.io#10422 from PowerShell, then read the bot's screenshot (98d41e630b).
- [ ] Key chords, first: assign a « Chord (simultaneous) » slot and check that it fires and that both orders follow the
      symmetry setting (the harness never reached the wait path); then rolling text with a chord on Space, AltGr alone
      and real LCtrl+AltGr on AZERTY, SC138 and AltGr characters on Kana, and a tap-hold key held during an expansion.
- [ ] Win+S, Win+E, Win+H and Ctrl+B on a real keyboard (Ctrl+B now runs `microsoft_bold`).
- [ ] Hold LCtrl through Ctrl+Alt+Del or UAC, come back, press AltGr: it stays AltGr. Confirm raw 0x21D in the log for an
      AltGr press: it unblocks the `left_ctrl` + `alt_gr` pair and the terminal recipe alias.
- [ ] Sticky keys, `run_command` in a console, `open_path` through both pickers, the vision backend list, and a real
      vLLM on port 8000.
- [ ] Decide: squash the old steps of `migrations.toml` (recommended, it would cut most remaining config test time) and
      whether a registry change seen only at the sweep's next capture is acceptable.
- [ ] Review the machine translations of 1 November (curl, proxy, token exchange, WebView2, chord and case-twin keys).

## To confirm on Linux

No machine is available. First `bash tools/dev/collect-linux-field-report.sh` on a real desktop: the field run
without a click (53c1766514), the report marks, and `driver_reload` (one daemon restart under a real user manager).

- [ ] Physical acceptance: evdev/uinput grabs, polkit, autostart, Wayland and X11; wizard (7) on Wayland; magic key
      grab, injection and hotplug (30); real kernel capture (93: ordered pairs need Xorg or a compositor on real
      evdev nodes).
- [ ] Gestures: a three-finger pad and one `libinput record` from a real touchpad (d627f511fc, 1870e62e1a,
      `linux/HARDWARE.md` section 13); a two-finger scroll with a thumb resting reports two fingers, a brisk
      three-finger tap still reports `tap_3`.
- [ ] Navigation layer wheel bindings with a real mouse (ea4b3fa600).
- [ ] Secret service: add a key with the keyring locked, the unlock prompt takes the keyboard under the grab; restart
      and check the plaintext `api_keys.json` migration (e93a4f7368, 939c0f60).
- [ ] Owned Ollama: with `ollama serve` on 11434, enabling the AI starts Ergopti's on 11435 (32fa07be7f).
- [ ] PAC unreachable: an Ollama pull logs the WARNING then the direct success (50b424b997, afc7fa23db).
- [ ] Item 50 cascade and the composed layout typed on a physical keyboard.
- [ ] Layout emulation W1 to W4 of `docs/design/layout-option-emulation.md` on real GNOME and KDE sessions
      (dbe176e52b, 9b0a205029, dfb197a1ea), including mutter and KWin reloading a `~/.config/xkb` layout (107).
- [ ] Developer mode with the package installed: `run-linux-dev.sh` stops the unit, the tray appears, a saved `.lua`
      and the tray's Reload restart the daemon, a second run reports "already running".
- [ ] Ten window-toggle actions on GNOME Wayland and X11 (a covered page is raised, not closed); release notes pane
      (PAR-52); tap delay row and every tray dialog in the owned GTK host (ca680655d7), group restore and clear, open target, Backspace word start.
- [ ] Some `local_servers.json` servers installed: the detection names them.

## Remaining code work

### Windows (the PC agent's)

State on 2026-11-01. Whole AHK suite at d85a24eb53: 17277/17288 in parallel, the other 11 (clipboard and focus contention
between workers) green alone. All live checks pass, typed by the harness.

- **LLM.** `retry_extra_tokens` has no Windows owner, so the corpus retry rows are not replayed there. Real IBM and Google
  token services were never tried.
- **Parity.** PAR-58 families not yet consumed: `terminator_restoration`, `context_buffer`, `request_plan_*`, the
  keystats families, `row_options`, `menus/*`. PAR-74: 549 literals left, the rest of the menu files need
  `test-menu-manifest` to stop pinning their spelling. PAR-79: the 28 literals left are inventory pollers and sleeps
  before the registry loads. PAR-83: the host in `ollama_managed_files.ps1`. Moving `tests/run_*.ahk` to
  `tests/runners/` is not worth it (455 `A_ScriptDir` uses, 1,908 includes).
- **Tests.** Source assertions left to convert to behaviour; `--reverse` on the `llm` group has 3 order-dependent reds.
- **Proxy override.** `_NetworkCheck_FetchPac` and the COM WinHttp use of `api_remote.ahk:603` are not checked against the
  override; `SystemProxy_IsLoopbackUrl` knows only named loopback hosts.
- **Field report.** `field/win-2026-11-01-dev` ran with no driver; run it again with one.
- **Signing follow-ups.** Delete `.github/ci/stable_windows_signing_exception.json` once SignPath is configured; flip
  update enforcement to `required` after the `off` release. The relay exe and the vendor binaries are unsigned.
- **Older findings.** The seven "Remaining findings" of
  [the 2026-10-28 Windows audit](docs/audits/windows-2026-10-28/README.md); item 36 updater production coupling (the
  first trusted PowerShell host acquisition); a408a29790 (the four longest AHK unit shards split) was never landed.

### macOS

- **Next release after 1.0.9, maintainer priority: switch the driver to the owned Karabiner.** Today the driver still uses
  the installed one and the owned runtime is dormant. The runtime is published and pinned; WP8, WP9 and the real-Mac
  acceptance of item 31 below come next, then `runtime = "owned"` becomes the default.
- **One folder name for Ergopti on the three OS (maintainer, 3 November).** macOS has three folders in Application
  Support: `ErgoptiPlus` (paths.toml, runtime, locks, karabiner.json), `Ergopti` (managed Ollama, embedded Python, MLX)
  and `ergopti_plus` (the local reload control); Windows mixes `%LOCALAPPDATA%ergopti_plus` and `Ergoptiundle`, and the
  config, logs and caches use other spellings. Decided: `Ergopti` on macOS and
  Windows, `ergopti` under XDG on Linux, no "Plus" in folder names; put each driver's data under one root, name it once in the shared identifiers,
  and migrate the old folders once at boot with a backup.
- **31. Owned Karabiner runtime** ([ADR 011](static/ergopti_plus/docs/adr/011-owned-karabiner-runtime.md),
  branch `next/owned-karabiner`, [handoff](docs/tooling/next-release-handoff.md)). Status on 4 November:
  - Done: runtime `16.3.0-ergopti.2` published (prerelease `remap-runtime-v16.3.0-ergopti.2`, downloaded back: sha256
    `ad1541f8…2de8e`, 12176523 bytes) and pinned in `macos/vendor/remap-runtime/manifest.json`; shared-rule migration,
    Tap-Holds block rows and notice; WP8 step 1: the live helper's first install also provisions and starts the idle
    Core service (`OwnedRuntimeIdleServiceEntry`), compiled unsigned for both architectures on a hosted Mac (Remap
    runtime build run 41813372448).
  - In progress (ready, not merged): the `RUNTIME_DEFAULT = "owned"` flip with the two Configuration rows
    (`menu.global.karabiner_integration`, `menu.global.remove_from_karabiner`, `macos/ui/menu/remap_switch.lua`)
    deleted, one commit on branch `next/owned-karabiner-flip` stacked on this one. It turns tap-holds off on any Mac
    without the owned runtime, so it waits for WP8 and WP9.
  - Next (WP8, in order): the `com.ergoptiplus.runtime.vhid` LaunchDaemon writer and the VirtualHIDDevice pkg install
    in the helper; a `--request-owned-runtime-install` launcher role and its Lua port from the `owned_not_installed`
    row; `RUNTIME_VERSION` `16.3.0-ergopti.3`, a signed Remap runtime build, its publication (maintainer go-ahead) and
    pin; a hosted `sudo` install acceptance job. A hosted runner cannot approve the DriverKit extension, so typing
    through the owned runtime is proven only by WP9 on a real Mac.
  - Then: WP9 (handoff checklist), the flip, the shared-mode deletion.
    Done on 1 November: the per-OS feature requirements table
    (`docs/design/feature-requirements.md`) and the driver-only VirtualHIDDevice update offer (3ebab93a17).
- **When the owned Karabiner is the one used:** delete the Configuration rows `menu.global.karabiner_integration` and
  `menu.global.remove_from_karabiner` (`macos/ui/menu/remap_switch.lua`), which act on the installed Karabiner.
- **Owned runtimes.** The rows in state "to do" of `_shared/data/owned_runtimes.json` are all item 31 (shared
  Karabiner app, owned runtime, VirtualHIDDevice). The Swift-owned managed daemon under the proxy relay needs a short
  design note first (who launches the relay, how its refusal receipt reaches the Swift owner; Swift and Go). Done on 1
  November: App Cloner on the managed Python with pinned PyObjC 12.1 (managed-pyobjc.json, ensure-managed-pyobjc.sh
  under the native PTY guardian, consent offer from the Apps menu, stable link `native-bootstrap/app-cloner/python3`;
  existing clones keep /usr/bin/python3 until re-cloned).
- **Proxy variables in `network-retry.sh`.** Four hand-typed spellings of the proxy variables now live there (the
  direct override and the refused sign-in start, 3597ee4f, among them); `test-proxy-policy-single-source` allows 4.
  Factor one `clear_proxy_environment()` both paths call, then lower the allowance.
- **Checks left to a program from the Mac session.** Done on 1 November: `field_tap_hold_thresholds` (9901da4d94;
  PAR-15 is confirmed by the next field run's result);
  the HTTPS downgrade refusal is already covered by `ManagedPACSourceTests` and `ManagedBootstrapDownloadTests`.

### All drivers

- **Test parity (audit item 14).** Done on 1 November for the `init.lua` gates (boot scenarios), the dedup test,
  the `managed_http` group and most Linux source invariants (`helpers.read_driver_unit`). Left: whole-tree class scans
  (legitimate meta tests) and the sliced-source compile tests (archive_output tar feeder).
- **Provider flags inferred, not read.** Checked against the docs on 1 November (90344262aa): Featherless and
  Qianfan confirmed; left: SambaNova toggle unverified (its docs answer 403 to automated reads), Chutes Qwen field
  inferred; watch Perplexity Sonar chat completions (ended
  2026-09-27), `dashscope-intl`, Moonshot K2 retiring by December.
- **Linux: scalable three-finger swipes (maintainer, 3 November).** macOS steps tab_next / tab_prev with the swipe's
  distance (mode "incremental"); the Linux gesture manager acts once, when the swipe ends, and has no per-slot mode, so
  a long swipe moves one tab. Its evdev decoder sees the travel, so it could count steps at the end of the swipe (live
  stepping would need a new path in `linux/modules/gestures/manager.lua`). Not small: the mode settings, their menu
  rows and the step accounting are macOS-only today. Linux recommends no swipe anyway (the desktop acts on them), so
  this is for users who bind one.
- **108. Per-device physical bindings.** Deferred until designed: the collision, source, modifier and output joins
  of a shortcut bound to a key position on one device; `keyboard_hook.capture_position` hands only `native_code` and
  `mods` (macOS capture is item 31's).

## CI acceptance

Each closes on a named green hosted or native run, recorded here.

- [ ] **16/38.** One complete non-release three-OS checkpoint on the final source (units, E2E, packaging,
      installation, launch) with exact receipts; it also carries the first hosted run of: the Linux X11 window list
      (962a25a973), AppImage Build and `install-linux` rows (dce846a0bd), the Linux per-step installs (17e80f2882),
      "Qualify the installed managed Ollama route plan" (c0a50b5e41), the Linux private runtime in every package,
      and the run-timing summary (`run-timing.cjs --step-summary`; Flatpak under 5 min).
- [ ] **macOS lane.** L32 and L42 Swift in the Build stage; the Issue #101
      Swift and Go cells; native qualification of the Hotstrings category boot publication and the obsolete-leaf
      setters; item 31's lane once its runtime build is green. Already green (run 41257389239): Launcher XCTest,
      Native XCTest (Intel), Build and all five Install-and-launch rows, guardian fixes included; macOS Unit,
      Integration and every E2E cell on run 41261068581.
- [ ] **Ollama Go cell** (cda1e10c5e) on the final source before a release (passed on run 40021624397).
- [ ] **36.** macOS Package job: Sparkle install/refusal/retry/relaunch, both Brew positives, full-policy denial, Brew
      archive scenarios; Linux Flatpak/AppImage installation and PAC/session/TLS delivery.
- [ ] **40.** Signed native execution of the eight Karabiner default/recommended/switch variants.
- [ ] **104, 105.** Common autocorrection sections (native Windows/macOS, per-section E2E, package); dynamic
      hotstrings on macOS.
- [ ] **34, 37, 102, 129.** Native macOS delimiter transactions; macOS packaging with both extension TOML files;
      Windows native cases and Fedora/Alpine ShellRunner fixtures (Linux done in the start-up E2E).
- [ ] **121, 123, 137.** AI Agent submenu composed-menu qualification on macOS and Windows; provider published before
      model loading on macOS (Linux done).
- [ ] **Carbon and daemon-report Swift.** Carbon fixture compilation and both-architecture receipts; daemon-report
      allocation failures on Intel and Apple silicon.
- [ ] **CodeQL Go.** After the `native_http` Go module is published, re-enable Go and check a non-empty analysis.
- [ ] **Native Windows TLS fixture.** `X509Store.Add` on the CurrentUser root store blocks on the Windows security
      warning (`docs/memory/windows-ahk.md`), so these cases need a click; hosted lanes pass in LocalMachine scope.
- [x] **Full Windows AHK suite.** Done on 2026-11-01 at d85a24eb53 with `npm run test:ahk-parallel`: 17277/17288 in
      parallel, the 11 others (clipboard and focus contention between workers) green alone.
- [ ] **Intermittent fixtures.** Close each after it stays green: Linux window switch, cffi-lua clone, desktop-webview
      AI focus, Windows `config` group, macOS Go `TestIdleDeadlinePhysicallyRetiresPeer`, macOS Swift
      `testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope`.

## Maintainer decisions pending

- [ ] Define "the read-only dashboard with a hot journal" (which dashboard opens which database read-only, and
      which journal is hot: a rollback `-journal` left by an interrupted keystats write, or a WAL?) so a program can
      check it.

- **PAC list walk on macOS and Windows.** Linux probes a `PROXY a; DIRECT` list before the Ollama start
  (`llm.managed_proxy_probe_timeout_ms`); the decision named Linux only, so macOS
  (`resolve_system_route_for_probe`) and Windows still export the first entry. Default meanwhile: first entry.
