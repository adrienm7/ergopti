<!-- TODO-tests-windows.md -->

# ErgoptiPlus checks on a real Windows PC

The Windows checks only a real PC can answer; code work stays in [TODO.md](TODO.md).

## To confirm on the Windows PC

- [ ] **Layout editor's Windows installer (2026-11-15):** from the Studio (site or app), « Download the Windows installer » on Ergopti, unzip, run `kbdergop-setup.exe` as administrator: the layout is listed and types as with the tool's own installer; edit `layout.ini` (a space, an extra key or line) and run it again: it refuses before writing anything; uninstall from Settings → Apps leaves no `a0nn040c` key. See docs/design/layout-windows-dll.md « Windows check », step 6.
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

- [ ] Layout editor window (2026-11-13): « Create or edit a layout… » and the layout manager's « Layout editor » open
      the editor in its own window; a second request brings it to the front with its unsaved work; « Close » closes
      it; an install from it refreshes an open layout manager.
      Ergopti Studio (2026-11-14, `claude/ergopti-todo-studio-app`): the top-level « 🎨 Ergopti Studio… » row,
      right after « Keyboard layout », opens the same window, titled exactly « Ergopti Studio »; while the
      driver is paused the row is greyed with the feature rows.
      Studio tabs (2026-11-14, `claude/ergopti-todo-studio-app`): « Comparer » shows the layout ranking for a
      built-in corpus within a second, an imported layout is still listed after closing and reopening the window,
      and « Analyse my typing » then selects « My typing » in « Comparer ». XKB and KLC downloads (2026-11-15, `claude/ergopti-todo-native-export`): in the layout editor window's « Export » tab, « XKB » and « KLC » write `<id>_xkb.zip` and `<dll>.klc` to the Downloads folder, built in the page (fengari, WebView2).
      Studio tabs and autosave (2026-11-15, `claude/ergopti-todo-studio-w-2`): in « Éditer », « + » opens a second
      layout in its own tab; edit both, end the driver from the Task Manager, start it again and reopen « Ergopti
      Studio »: both tabs and their unsaved edits are back, from `layout_sources\studio_workspace.json`; « Export
      all » writes `ergopti-studio-layouts.zip` to the Downloads folder and « Import » of that file reopens every
      layout.
      Navigation layer in the Studio (2026-11-15, `claude/ergopti-todo-studio-nav-entry`): the Tap-Holds menu's « Edit the navigation layer… » row and a
      gesture bound to « Navigation layer » open Ergopti Studio on its « nav » layer, holding the current layer
      key, with the user's layers.toml bindings; « Apply the navigation layer » then changes the layer live, and
      layers.toml starts with « # source: » and « # body-fnv1a32: ».

- [ ] Layout editor downloads (2026-11-14, `layout_editor_downloads`): the editor window's XKB, KLC, DLL and macOS
      bundle downloads land in the Downloads folder, a second download of the same file is named « name (2).ext »,
      and the `.klc` opens in MSKLC.

- [ ] Restored API entry under another account (2026-11-13): restore a configuration backup holding a DPAPI API key
      under a second Windows account; the entry is greyed with « Edit » only, and a new key makes it work.

- [ ] SCD-3 (2026-11-13): with a non-Ergopti layout emulated and « Ctrl+B » set to an action, Ctrl+AltGr+B runs it;
      with the slot set to nothing, Ctrl+AltGr+B sends Ctrl+B.

- [ ] Metrics export and purge on Windows (`KL_RunMetricsMaintenance`): only source contracts check that path.

- [ ] Navigation-owner DLL after the folder migration (2026-11-13): its manifest fingerprint was derived by the
      migration without a rebuild; run `-UpdateTracked` with the pinned MSVC and check the DLL is byte-identical.

- [ ] Physical shortcut collision and delivery owners (2026-11-13, worker F, `ui/physical_shortcuts/delivery.ahk`):
      in an isolated driver only, make `PhysicalShortcutDeliveryAvailable` answer true, then run steps (3) to (7) of
      the « qualify physical shortcut delivery » item in TODO.md: a bound key runs its action once and types nothing;
      nothing runs while paused, after quit, with AltGr held or for the key sent by another program (SendInput);
      binding a position a tap-hold, a tap key, a key combination, a script shortcut or the layout emulation already
      holds is refused with `collision`. Only then may the production getter turn true.
- [ ] KLC with Kana and Roya columns (2026-11-13, direct KLC compiler): the `export-klc` of
      `static/ergopti_plus/_shared/tests/corpus/layouts/source/direct_levels.toml` (`npm run layout-source`) writes
      shift states 8, 9, 16 and 17 with F12 on `VK_KANA` and Caps Lock on `VK_OEM_FJ_ROYA`. Check that MSKLC's
      `kbdutool` builds it, and that with the DLL installed F12+B types « ka » and Caps Lock+A types ←. The
      repository KLC reader reads it back (`tools/test/test-layout-source-compiler.cjs`); MSKLC itself was not run.
- [ ] One-shot modifiers (worker A, 2026-11-13): the sticky delay row accepts 0 and shows « no time limit », and the
      one-shot Shift and `sticky_*` captures then wait with no InputHook timeout; `sticky_altgr` types the AltGr level
      on the Ergopti layout, through Kana on a Kana-style layout; a tap-hold key set to tap `sticky_altgr` and hold
      AltGr types one AltGr character after a tap.
- [ ] Native carriage of `shortcut_key` (moved 2026-11-15 from TODO.md « Native carriage of `shortcut_key`
      (2026-11-15) », its real-OS proof once the [CODE] part is written): a source with `keys.<code>.shortcut_key`
      exported to KLC and built into the DLL carries the shortcut VK; with the DLL installed, the shortcut sends that
      VK.
- [ ] Qualify physical shortcut delivery on Windows (moved 2026-11-15 from TODO.md « Windows/macOS/Linux: qualify
      physical shortcut delivery and its editor », Cross-platform feature inventory; the « qualify physical shortcut
      delivery » steps the « Physical shortcut collision and delivery owners » line names;
      `test_physical_shortcut_delivery.ahk`, `test_physical_shortcut_host.ahk`): `PhysicalShortcutDeliveryAvailable()`
      still returns false until steps (2) to (7) pass on the PC: (2) flip the getter in an isolated driver only, open
      the editor from the tray: the page shows positions by name (A, 1, Pavé num. 7), never `KeyA` or `SC01E`; (3)
      Capture a key with Ctrl, Shift, Win and none held, on an ISO and an ANSI board, with AZERTY and Ergopti layouts:
      the captured position is the physical key, AltGr is refused, a key sent by another program (SendInput) is not
      captured, and the key still types in the focused app; (4) save an action, then edit, move and remove it:
      config.toml gets one backup and one write each, the reload keeps it, and an external edit of config.toml between
      opening and saving shows « Configuration changed »; (5) press the bound key: the action runs once, the key's
      character is not typed, nothing runs while paused, after the driver quit, or for the same key sent
      synthetically; (6) bind a combination already owned by a tap-hold, a script shortcut or a key combination: the
      save is refused with `collision`; (7) close the window during a capture and while the picker is open: no capture
      survives, no draft is saved.. Only then may the getter turn true. Token-by-token prediction display also remains
      unvalidated on Windows (`platform_reason.token_streaming_unvalidated_on_windows`, the « Live Ollama » line).
- [ ] Native runtime, editor and diagnostics receiving on Windows (moved 2026-11-15 from TODO.md « [NATIVE] Exercise
      the retained runtime/editor/diagnostics receiving boundaries », [native UI
      audit](docs/audits/platform-parity/2026-11-05-native-ui/report.md)): on the real PC, replay refused writes,
      native timer admission, stale epochs and physical cleanup at the retained runtime, editor and diagnostics
      boundaries; the private models do not certify these boundaries.
- [ ] Flow receiving scenarios WCP-002 and the DPAPI second account (moved 2026-11-15 from TODO.md « [PHYS-W] /
      [PHYS-M] / [PHYS-L] », End-to-end parity follow-up; [flow
      review](docs/audits/platform-parity/2026-11-04-flows/report.md)): on an isolated native host, WCP-002 (the paste
      into a new foreground window needs real key emission) and a DPAPI blob of another Windows account (a second
      account). The other WCP/WCR/WCF/WDS scenarios passed 8 of 8 on the maintainer's PC on 2026-11-12
      (`tools/test/run-windows-receiving-scenarios.ps1`).
- [ ] Native acceptance, account-context and PnP (moved 2026-11-15 from TODO.md « Native acceptance », Deep OS ×
      module follow-up; [18-scope review](docs/audits/platform-parity/2026-11-04-deep/report.md)): run the unexecuted
      account-context and PnP scenarios from each module coverage register; the whole AHK suite and `e2e/run_e2e.ahk`
      already ran natively on 2026-11-11.
- [ ] Windows boot and menu timings (moved 2026-11-15 from TODO.md « Slowness, every driver », branch
      `wip/windows-boot-time`): on the PC, time the boot (7 s typical and `menu.rebuild` 1.7 s in the 3 November real
      logs) and a toggle, which must not rebuild 1000 rows, after the deferred emoji and symbol registration
      (`HSE_DeferRegistration`) and the AI submenu built at its first open; measure each with interleaved
      base/candidate boots (summed `process_cpu`).
- [ ] Requalify the Windows key-combination and updater cohorts after the structure migration (moved 2026-11-15 from
      TODO.md « Remaining code work »; rule C1, decided by the coordinator on 2026-11-12, to review by the
      maintainer): each structure step re-pins the immutable cohort receipts and its commit body lists every old→new
      pin with the move that justifies it under « Requalification ». Run both cohorts natively on the Windows PC once
      the migration has landed, and confirm the re-pinned frames.
- [ ] EDD-1 on AHK, a pause stops typing, not configuration (moved 2026-11-15 from TODO.md « EDD-1 on AHK »; 392ae998,
      [pause Windows inventory](docs/audits/platform-parity/2026-11-12-pause/windows-inventory.md)): once the suspend
      gates of prompt_editor, paths_editor, layer_editor, layout_manager, hotstrings_config_window, action_picker,
      model_browser and menu_llm are removed (the tray greying went on 2026-11-15, `greyed_when_paused` is now
      `boot_deferred`), a PC run confirms: a save while suspended writes the file, the configuration and install rows
      stay live, a click that still waits for the resume shows the paused notice once, the tray rebuilds after a
      pause and a resume, and nothing that acts on typing stays active under Suspend.
- [ ] Immediate-Backspace restoration after Notepad-paste and terminal expansions (moved 2026-11-15 from TODO.md
      « Remaining code work »; c448c6d1ff): once the Notepad and terminal owners keep an undo record, a PC run in
      Notepad and in a terminal qualifies that the undo burst goes through the same owned output as the expansion (the
      clipboard owner of `_HSE_BeginOwnedNotepadTransaction`, the paced capture of
      `_HSE_BeginOwnedTerminalTransaction`): a Backspace right after the expansion types the trigger back. Until then
      `HSE_UndoExpansion` keeps refusing both hosts.
- [ ] One folder name (moved 2026-11-15 from TODO.md « One folder name for Ergopti on the three OS »;
      [handoff](docs/tooling/one-folder-name-handoff.md#what-the-maintainer-checks-on-each-machine)): check the PC
      against the handoff's Windows list (after the first boot, the « Moved legacy folder entry » lines in
      `%LOCALAPPDATA%\Ergopti\logs\`, the old folders gone, the configuration in `%LOCALAPPDATA%\Ergopti\config\`,
      `before-folder-migration\` read for clashes); the migration is removed only once the maintainer's machines pass.
- [ ] Hot-path span lines on Windows (moved 2026-11-15 from TODO.md « Linux performance », « Windows counterparts »;
      fa8175e636, `test_hotpath_span_lines.ahk`): at DEBUG on the PC, a field log holds the `[TRACE] [Span] <name>…`
      and `[DONE] [Span] <name> done in N ms (<outcome>)` pairs for `hotstring.expand` (fired, declined or pending),
      `tray.fill` and `layout.switch`.
- [ ] Common autocorrection sections, native Windows cases (moved 2026-11-15 from TODO.md « 104, 105 », CI acceptance;
      the Linux per-section E2E is e13cf14a03, `run_e2e.lua`): with one common section chosen at a time
      (`[hotstrings.groups]`, `[hotstrings.modules.autocorrection]`), typing `chatgpt adn adaboost` gives only ChatGPT
      with names, only ADN with abbreviations and only AdaBoost with technical terms, as the Linux daemon E2E
      (`AUTOCORRECT_SCENARIOS`) does.
- [ ] Items 34, 37, 102 and 129, the Windows native cases (moved 2026-11-15 from TODO.md « 34, 37, 102, 129 », CI
      acceptance): run on the PC the Windows native cases of native delimiter transactions and packaging with both
      extension TOML files (maintainer).
- [ ] AI Agent submenu composed-menu qualification, the Windows part (moved 2026-11-15 from TODO.md « 121, 123, 137 »,
      CI acceptance; the macOS Unit lots are green in run 42929436137): on the PC, the AI Agent submenu shows its
      composed menu (maintainer).
- [ ] Native Windows TLS fixture (moved 2026-11-15 from TODO.md « CI acceptance »; `docs/memory/windows-ahk.md`):
      `X509Store.Add` on the CurrentUser root store blocks on the Windows security warning, so a person runs the
      native cases with `--interactive` on the Windows PC (10 s to click); local runs report them NOT EXECUTED at
      `ChangeTrust(true)`, and the LocalMachine scope stays refused outside hosted CI. No code is needed.
