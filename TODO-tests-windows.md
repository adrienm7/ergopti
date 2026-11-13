<!-- TODO-tests-windows.md -->

# ErgoptiPlus checks on a real Windows PC

The Windows checks only a real PC can answer; code work stays in [TODO.md](TODO.md).

## To confirm on the Windows PC

- [ ] Hotstring section order: run the category-order AHK regressions, move/reset sections through the real tray, restart, and verify persistence plus refusal of a stale menu after external config changes.
      PC run 2026-11-11: the category-order regressions (`test_hotstring_category_scope.ahk`, `test_hotstring_dynamic_menu_scope.ahk`, config-scope-features group) passed natively.

- [ ] Hotstring preview boundaries: run `preview-word-opening` and `boundary-cache` on native Windows; type punctuation before a word, change custom delimiters and the magic key, and confirm preview and expansion still agree.
      PC run 2026-11-11: `preview-word-opening` (`test_prefix_char_admission.ahk`) and `boundary-cache` (`test_hotstring_engine_input_generations.ahk`) passed natively (hotstrings-shortcuts group).
- [ ] Remote authentication: exercise real IBM and Google token services; local request/refusal tests do not qualify their live responses.

- [ ] **Windows personal-info eager pre-generation:** measure boot cost at the highest accepted pattern length; cover the accepted-agent policy test, the wrap-scalar test and the 2026-11-06 AHK changes with a native run.
      PC run 2026-11-11: the accepted-agent policy test (`test_llm_agent.ahk`, llm group), the wrap-scalar test (`test_wrap_symbols_global_transaction.ahk`, hotstrings-shortcuts group) and the rest of the suite passed natively; the boot cost is not measured yet.

- [ ] **Windows incremental swipes (raw touchpad reader):** on a Precision Touchpad, after « Configurer automatiquement » so the slots are routed to Ergopti: 1. The log at start has `Touchpad raw reports registered`, and at the first touch `Touchpad <handle>: N finger(s), X x Y units per mm` (not `reports no physical size`); X and Y match the pad's width and height (logical span over millimetres). 2. With `swipe_3_left`/`swipe_3_right` incremental (the default) and tab_next/tab_prev bound, a slow three-finger swipe across the pad in a browser steps one tab per 3.5 mm, starting after 3.5 mm; coming back half a step reverses; a debug log shows `swallowed` for the shortcut and the tab count equals the steps, never one more. 3. A quick short swipe (under the first step) still switches exactly one tab (the deferred shortcut, `fires once` at the lift). 4. Change the step to 10.0 and 1.0 from the slot's submenu: the distance per tab follows without a restart; set the slot to « Action unique (x1) »: one tab per swipe, no step. 5. Four-finger swipes (x1 by default) still act once; three-finger taps unchanged; swipes on a slot Windows does not route to Ergopti do nothing extra. 6. Pause Ergopti mid-swipe: no further step; resume: the next swipe steps from zero. Unplug/replug an external Precision Touchpad: `forgotten` then a fresh descriptor log. 7. Note in the log whether the shortcut (`shortcut swallowed`/`deferred`) arrives before or after the lift, to confirm the handoff window (300 ms) is enough.

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

- [ ] Layout emulation row on Windows (2026-11-06): Tray > Layout > « Disposition à émuler » lists none, Ergopti,
      Ergopti➕ and the registry layouts; choosing one restarts the driver on it (the tick follows), « none » types
      the system layout, an uninstalled stored layout stays named.
- [ ] Tray > Gestures: one « Infos… » row that opens the dialog.
- [ ] Ollama or oMLX on a non-default port with the process scan failing: still found.
      PC run 2026-11-11: `test_local_server_ports.ahk` (llm-servers group), a scan without a process list included, passed natively.
- [ ] `asa` then Space fast, 20 times: always `ASA`.
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
- [ ] Review the machine translations of 1 November (curl, proxy, token exchange, WebView2, chord and case-twin keys).
- [ ] Predictions stop on activity (feat/predictions-stop-on-activity): with a slow model, type, pause, and during
      the spinner move the mouse by a few pixels, turn the wheel, use a precision-touchpad scroll, Alt+Tab, press
      F5: each cancels the request and hides the tooltip at once (no 100 px threshold, no grace window). Tab, the
      validation digits and the cycle chords still act on a shown prediction; a still mouse keeps it.
- [ ] Branch `decisions/align-windows` (2026-11-06, AHK and PowerShell unrun on Linux): run the AHK suite
      (`test_wpm_config_types.ahk` mode `later-writes-refused`, `test_key_combination_chord_engine.ahk` copy cases,
      the persistence census at 50) and `test-windows-route-plan.cjs`; drag the WPM widget, restart, and check it
      comes back where it was (the old split position keys are no longer read, so it starts once at its default);
      Shortcuts > Key combinations > « Copy tap → combo », then a chord fires the copied action; a model pull behind
      a `PROXY dead:3128; DIRECT` PAC goes direct after the 1 s probe.
      PC run 2026-11-11: `test_wpm_config_types.ahk` (ui group), the copy cases of `test_key_combination_chord_engine.ahk` (keymap-gestures group) and the persistence census (`test_config_persistence_callers.ahk`, meta group) passed natively.
- [ ] Branch `wave3/metrics` virtual desktops (AHK unrun on Linux): run `test_keystats_virtual_desktop.ahk` and the aggregation corpus (`system_event_night_wake`), then on Windows 11 and Windows 10 switch desktops (Win+Ctrl+Left/Right) and confirm one `space_change` per switch in today.log and the dashboard's desktop-change KPI, and none from Alt+Tab.
      PC run 2026-11-11: `test_keystats_virtual_desktop.ahk` (keystats group) and the aggregation corpus (`test_corpus_keystats_aggregation.ahk`, meta group) passed natively.
- [ ] Bundled apps (`wave3/app-cloner-encryptor`, AHK unrun on Linux): parse and run `test_bundled_apps.ahk`; from the
      PC run 2026-11-11: `test_bundled_apps.ahk` (ui group) passed natively.
- [ ] [COVERAGE] Windows managed-runtime fixture: after a first native Windows run of the legacy fixture, register it
      in `ci-windows.yml` (it holds the only reuse and runtime-receipt retirement cases).
- [ ] Branch `wave3/windows-deep` (2026-11-06, AHK unrun on Linux): run `test_keystats_journal_sealing.ahk`; then
      enable Metrics > « Encrypt logs on disk », type a unique marker in Notepad, wait for the ingest and check that
      `by_device\<id>\today.log` holds no readable marker while the dashboard still counts it.
      PC run 2026-11-11: `test_keystats_journal_sealing.ahk` (keystats group) passed natively.
- [ ] WG-003 two-account check: as a standard user, run the first-run wizard's gesture registration and answer UAC
      with a different administrator account; the standard user's PrecisionTouchPad values change (and its backup is
      theirs), the administrator's hive is untouched, and the touchpad restart still reports success.
- [ ] WPM notification-area readout: run `test_notify_icon.ahk` and `test_wpm_tray_readout_wiring.ahk`; tick Metrics >
      « WPM in menu bar », type: a second icon shows the number (source colour after a hotstring, neutral otherwise),
      hides when typing stops and on pause; restart Explorer: it comes back; quit: it leaves; at 125 % and 200 % the
      number stays legible.
      PC run 2026-11-11: `test_notify_icon.ahk` (core group) and `test_wpm_tray_readout_wiring.ahk` (meta group) passed natively.
- [ ] Branch `layout/system-switch-parity` (2026-11-06, AHK unrun on Linux): run the AHK suite
      PC run 2026-11-11: the whole AHK suite ran natively.
- [ ] Branch `wave3/input-policies` (2026-11-06, AHK unrun on Linux): run `test_tap_hold_one_shot_timeout.ahk`,
      PC run 2026-11-11: `test_tap_hold_one_shot_timeout.ahk` (keymap-gestures group) passed natively.
- [ ] Branch `layout/windows-klc-installer` (2026-11-06, built on Linux only: no MSVC run, AHK unit tests under Wine):
      PC run 2026-11-11: the AHK unit tests ran natively, not under Wine; no MSVC build yet.

- [ ] Metrics ledgers: the Windows reader replays a Linux `by_device/` ledger (never run, no AutoHotkey in the cloud
      containers).

- [ ] AI tooltip « both » mode: with a hotstring tooltip showing, the prediction draws under its rows in one stack and
      the rows leave on their own expiry.

- [ ] Layout editor host (2026-11-12): the real UAC install of a source's DLLs, typing, switching and the uninstall
      (Settings > Apps and « Remove »), in source and compiled mode.

- [ ] Metrics export and purge on Windows (`KL_RunMetricsMaintenance`): only source contracts check that path.

- [ ] Navigation-owner DLL after the folder migration (2026-11-13): its manifest fingerprint was derived by the
      migration without a rebuild; run `-UpdateTracked` with the pinned MSVC and check the DLL is byte-identical.

- [ ] KLC with Kana and Roya columns (2026-11-13, direct KLC compiler): the `export-klc` of
      `static/ergopti_plus/_shared/tests/corpus/layouts/source/direct_levels.toml` (`npm run layout-source`) writes
      shift states 8, 9, 16 and 17 with F12 on `VK_KANA` and Caps Lock on `VK_OEM_FJ_ROYA`. Check that MSKLC's
      `kbdutool` builds it, and that with the DLL installed F12+B types « ka » and Caps Lock+A types ←. The
      repository KLC reader reads it back (`tools/test/test-layout-source-compiler.cjs`); MSKLC itself was not run.
