<!-- TODO-tests-windows.md -->

# ErgoptiPlus checks on a real Windows PC

The Windows checks only a real PC can answer; code work stays in [TODO.md](TODO.md).

## To confirm on the Windows PC

Run by the PC agent from a fresh `dev` on a `fix/windows-pc-<date>` branch; push the branch, the coordinator
integrates. Every commit keeps the AHK UTF-8 BOM, reseals a touched updater source and passes the Windows lane
(`gh workflow run ci.yml --ref <branch> -f os_lanes=windows`). Rules and ported work:
[PC handoff](docs/tooling/windows-pc-agent-handoff.md). Order:

1. The full AHK suite passed 19,331 of 19,331 on 2026-11-17 (`npm run test:ahk-parallel -- --fresh`, after the fixes
   of `fix/windows-pc-2026-11-17`); the owned daemon's proxy (743181a933) has still not run live.
2. Field report: run with Windows PowerShell 5.1 on 2026-11-17 (field run network and composer pass, boot cost
   3,814 ms over its 2,500 ms budget), after four collector fixes; the runtime layer of
   `test-windows-field-report-contract.cjs` passes. Left: the `pwsh` run (PowerShell 7 is not installed on the PC),
   and a boot cost measured on an idle PC before reading it as a regression.
3. The Windows items of « Remaining code work » in TODO.md.
4. The checks below and the [standing checks](docs/tooling/windows-maintainer-checks.md#standing-checks) 1 to 15
   (`node tools/maintainer/windows-live-checks.cjs` runs the automatable ones).

### Layouts and Ergopti Studio

- [ ] Layout tool pages (LTP-01 to LTP-07, 2026-11-21), Narrator on, interface in English and the Configuration
      menu's reading font set to Atkinson Hyperlegible: « Install or remove layouts… » shows that font and Narrator
      reads it in English (LTP-01, LTP-02), as Ergopti Studio. Tab to « Use » or « Update » on an installed layout
      and press Space: after the answer the focus is still on that row; Escape closes the window (LTP-06, LTP-07).
      Pause the driver, open Ergopti Studio: the editor shows the last source, « Save » and « Emulate without
      installing » answer at once, and the emulation types only after the resume (LTP-03). Do not install or remove
      a layout you need.
- [ ] Seeded editors and paused configuration windows (LTP-09, LTP-10, 2026-11-21), same reading font: the personal
      information editor and the config-folder editor show that font (LTP-09). Pause the driver, open the physical
      shortcuts editor, change one row and save: the page answers at once and the shortcut acts only after the resume;
      the unused configuration keys cleanup also answers while paused (LTP-10).
- [ ] **Layout editor's Windows installer (2026-11-15):** from the Studio (site or app), « Format » « Windows
      installer (.zip) » then « Download » on Ergopti, unzip, run `kbdergop-setup.exe` as administrator: the layout is
      listed and types as with the tool's own installer; edit `layout.ini` (a space, an extra key or line) and run it
      again: it refuses before writing anything; uninstall from Settings → Apps leaves no `a0nn040c` key. See
      docs/design/layout-windows-dll.md « Windows check », step 6.
- [ ] Layout capabilities (2026-11-19): with French AZERTY selected and no layout emulated, « Couches émulées »
      AltGr on types Ergopti's AltGr symbols over AZERTY, Ctrl+é sends the chosen letter's chord and the number
      row order applies; with Ergo-L emulated from Studio (« Émuler »), the same rows apply on top of it. A
      Studio-installed DLL shows in Settings > Apps and in « Installer ou retirer des dispositions… » (LCP-05): its
      « Désinstaller » asks first, « Non » changes nothing, « Oui » raises one UAC prompt and leaves no `Keyboard
Layouts` key. Re-saving the source under another `dll_name` with « Installer et utiliser » removes the old DLL
      first (LCP-06). With `ergopti_ansi` emulated from the registry, Ctrl+è sends the chosen letter (LCP-07).
- [ ] Layout editor host (2026-11-12): the real UAC install of a source's DLLs, typing, switching and the uninstall
      (Settings > Apps and « Remove »), in source and compiled mode.
- [ ] Ergopti Studio opens maximized (2026-11-17), at 100 %, 150 % and 200 % display scale: the title bar and its
      buttons are reachable, « Restore » gives a window inside the screen; the page is dark in the dark theme,
      « Comparer » included, and « Analyse de la disposition » spans the editor's width in columns.
- [ ] Ergopti Studio window: « Create or edit a layout… », the layout manager's « Layout editor » and the top-level
      « 🎨 Ergopti Studio… » row (right after « Keyboard layout ») open one window titled exactly « Ergopti Studio »; a
      second request brings it to the front with its unsaved work; « Close » closes it; an install from it refreshes
      an open layout manager.
      Tabs: « Comparer » shows the layout ranking for a built-in corpus within a second, an imported layout is still
      listed after closing and reopening the window, and « Analyse my typing » then selects « My typing ».
      Autosave: in « Éditer », « + » opens a second layout in its own tab; edit both, end the driver from the Task
      Manager, start it again and reopen « Ergopti Studio »: both tabs and their unsaved edits are back, from
      `layout_sources\studio_workspace.json`; « Export all » writes `ergopti-studio-layouts.zip` to the Downloads
      folder and « Import » of that file reopens every layout.
      Formats: « Open » in WebView2's file chooser lists .json, .klc and .kbe files, opens a KLAnext JSON
      (static/layouts/kla_iso) and a UTF-16 .klc, and refuses a KbdEdit .kbe with the « KbdEdit encrypts » message.
      Downloads: the XKB, KLC, DLL, macOS bundle, « KLA / KLAnext JSON » and « Kalamine TOML » downloads land in the
      Downloads folder, a second download of the same file is named « name (2).ext », and the `.klc` opens in MSKLC.
      Navigation layer: the Tap-Holds menu's « Edit the navigation layer… » row and a gesture bound to « Navigation
      layer » open the Studio on its « nav » layer, holding the current layer key, with the user's layers.toml
      bindings; « Apply the navigation layer » then changes the layer live, and layers.toml starts with « # source: »
      and « # body-fnv1a32: ».
      Optimiser: the « Optimiser » tab opens the optimizer; after « Analyse my typing », « My typing » is its chosen
      corpus; « Optimize » with 10 s runs to « Done » with a score, the window staying responsive (Web Workers); « Open
      in the editor » opens the result in a new tab of « Éditer » and « Compare with other layouts » adds it in «
      Comparer »; its choices are back after closing and reopening the window.
- [ ] « Ma frappe » at once (2026-11-17): open Ergopti Studio once and wait for « Ma frappe » (the worker writes
      `metrics\cache\studio_ngrams.json`), restart the driver, type a few words, reopen the Studio: « Ma frappe » is
      the chosen corpus of « Comparer » and « Analyse de la disposition » within a second (the saved read), then its
      counts change a little when the worker ends (30 s or more on a 1 GB store) without changing a corpus picked
      meanwhile. After the dashboard's « Purge », the next Studio open shows no saved read before the worker's.
- [ ] KLC with Kana and Roya columns (direct KLC compiler): the `export-klc` of
      `static/ergopti_plus/_shared/tests/corpus/layouts/source/direct_levels.toml` (`npm run layout-source`) writes
      shift states 8, 9, 16 and 17 with F12 on `VK_KANA` and Caps Lock on `VK_OEM_FJ_ROYA`. Check that MSKLC's
      `kbdutool` builds it (MSKLC is not installed on the PC yet), and that with the DLL installed F12+B types « ka »
      and Caps Lock+A types ←.
- [ ] Native carriage of `shortcut_key`: a source with `keys.<code>.shortcut_key` exported to KLC and built into the
      DLL carries the shortcut VK; with the DLL installed, the shortcut sends that VK.
- [ ] Layout DLL package: install the CI-built `Ergopti_windows_layout.zip` on the PC (the MSVC builder stays strict
      and needs the ARM64 C++ tools the PC lacks, decided 2026-11-17), then a native 32-bit typing check of the wow64
      image.
- [ ] Composed layout on a real keyboard (Debug > "Test the composed layout").

### Typing, hotstrings and shortcuts

- [ ] Windows Security prompt (2026-11-19, SFC-01): open a credential prompt (`\\<host>\share` for an unknown host
      in Explorer), type a hotstring trigger in its user-name box: nothing expands, no AI suggestion shows and
      keystats records nothing; the same trigger in Notepad expands.
- [ ] AltGr rolls and script shortcuts (2026-11-17): on Ergopti+, AltGr held over J then I types `("`, over the
      `)` key then I types `)#`, and the `chevron_equal` roll works again; AltGr then Enter alone pauses, but « (# »
      then Enter or Backspace with AltGr still down types Enter or erases, and never pauses or reloads.
- [ ] Non-text keys during a burst beside another AutoHotkey hook (2026-11-20, `burst-holds-non-text-keys`): with a
      second AutoHotkey script that installs a keyboard hook running, roll an expanding trigger straight into a
      letter, Backspace and a letter, then into Ctrl+Left: the Backspace erases the letter typed before it and the
      caret moves after the expansion, never inside it.
- [ ] Items 34, 37, 102 and 129: the Windows native cases of native delimiter transactions and packaging with both
      extension TOML files.
- [ ] Immediate-Backspace restoration in Windows Terminal: `sru` + Space then Backspace types `sru` back through the
      paced terminal capture, an OpenTUI prompt such as Claude Code included. The live check `backspace-undo-hosts`
      passed on 2026-11-17 in an edit, Notepad and a conhost console; conhost names its client as the window's owner,
      so the console took the atomic path, and the check does not drive the user's own Windows Terminal.
- [ ] Immediate-Backspace restoration of an emoji per host (2026-11-17): an expansion ending in « 👍🏽 », then
      Backspace, gives the trigger back with nothing left of the expansion in a classic Edit (Win+R), the Store
      Notepad, WordPad and Edge or an Electron app, and so does one ending in « 🇫🇷 »; the DEBUG log names the
      host family (« Undo: N Backspace step(s) in a richedit host »); a letter typed before the trigger stays, in Word
      too.
- [ ] Backspace restore (2026-11-19): in Notepad, Edge and Windows Terminal, a ★ trigger (`td★`) then Backspace
      within half a second leaves `td`, never `td★`; `adn` then Space, a comma or Enter, then Backspace, leaves `adn`
      and that terminator, never `ADN`; a Backspace a second after the expansion, or after Escape, deletes one
      character; with Hotstrings > « Backspace undoes the last expansion » off, Backspace deletes one character, and
      the window's choices and free entry (« Other value… », 50 to 10000 ms) take effect without a reload.
- [ ] One-shot modifiers (2026-11-13): the sticky delay row accepts 0 and shows « no time limit », and the one-shot
      Shift and `sticky_*` captures then wait with no InputHook timeout; `sticky_altgr` types the AltGr level on the
      Ergopti layout, through Kana on a Kana-style layout; a tap-hold key set to tap `sticky_altgr` and hold AltGr
      types one AltGr character after a tap.
- [ ] Key chords, first: assign a « Chord (simultaneous) » slot and check that it fires and that both orders follow the
      symmetry setting (the harness never reached the wait path); then rolling text with a chord on Space, AltGr alone
      and real LCtrl+AltGr on AZERTY, SC138 and AltGr characters on Kana, and a tap-hold key held during an expansion.
- [ ] Shortcuts > Key combinations > « Copy tap → combo », then a chord fires the copied action.
- [ ] SCD-3 (2026-11-13): with a non-Ergopti layout emulated and « Ctrl+B » set to an action, Ctrl+AltGr+B runs it;
      with the slot set to nothing, Ctrl+AltGr+B sends Ctrl+B.
- [ ] Win+S, Win+E, Win+H and Ctrl+B on a real keyboard (Ctrl+B now runs `microsoft_bold`).
- [ ] Hold LCtrl through Ctrl+Alt+Del or UAC, come back, press AltGr: it stays AltGr. Confirm raw 0x21D in the log for an
      AltGr press: it unblocks the `left_ctrl` + `alt_gr` pair and the terminal recipe alias.
- [ ] Item 49: the terminal-capture hardware list. Item 91: held-alone-then-joined order, AltGr hook provenance.
- [ ] Physical shortcut delivery (`ui/physical_shortcuts/delivery.ahk`, `test_physical_shortcut_delivery.ahk` and
      `test_physical_shortcut_host.ahk` pass natively): `PhysicalShortcutDeliveryAvailable()` stays false until steps
      (2) to (7) pass, in an isolated driver only: (2) flip the getter and open the editor from the tray: the page
      shows positions by name (A, 1, Pavé num. 7), never `KeyA` or `SC01E`; (3) capture a key with Ctrl, Shift, Win
      and none held, on an ISO and an ANSI board, with AZERTY and Ergopti layouts: the captured position is the
      physical key, AltGr is refused, a key sent by another program (SendInput) is not captured, and the key still
      types in the focused app; (4) save an action, then edit, move and remove it: config.toml gets one backup and one
      write each, the reload keeps it, and an external edit of config.toml between opening and saving shows
      « Configuration changed »; (5) press the bound key: the action runs once, the key's character is not typed,
      nothing runs while paused, after the driver quit, with AltGr held, or for the same key sent synthetically; (6)
      bind a position a tap-hold, a tap key, a key combination, a script shortcut or the layout emulation already
      holds: the save is refused with `collision`; (7) close the window during a capture and while the picker is
      open: no capture survives, no draft is saved.
- [ ] Sticky keys, `run_command` in a console, `open_path` through both pickers, the vision backend list, and a real
      vLLM on port 8000.

### AI

- [ ] Live Ollama, « Afficher en streaming » on (PAR-12, enabled 2026-11-20): predictions grow token by token, the
      row never shows TAIL_CORRECTED or NEXT_WORDS, Tab mid-stream types the row shown, and a stream killed mid-way
      (stop Ollama) brings the spinner back before the buffered retry.
- [ ] System Ollama on 11434, AI on: Ergopti's listens on 11435, the other is untouched (f016081056, 597cbbe983).
- [ ] Ollama or oMLX on a non-default port with the process scan failing: still found.
- [ ] Managed Ollama pull longer than 30 minutes (OLL-02, 2026-11-20): on a line throttled so the first model takes
      over 30 minutes (Windows Settings metered connection plus a large model, or a throttling proxy), enable the AI
      with no runtime installed and accept the install, then later pull a second large model from the model selector:
      both pulls finish, and the log names no `bootstrap_timeout`, `model_pull_timeout` or menu pull failure.
- [ ] Managed Ollama cold start on a quiet PC (OLL-06, 2026-11-20): after a reboot, with nothing else running, turn
      the AI on and time the start of the owned runtime to its readiness (the AI menu dot turning ready, and the
      `LLM.managed` log lines of the start and of the version answer); repeat right after a fresh runtime install,
      while Defender scans it. The report needs both figures to choose one readiness bound with
      macOS (30 s today, against what is left of the 30 min install budget here).
- [ ] Predictions stop on activity: with a slow model, type, pause, and during the spinner move the mouse by a few
      pixels, turn the wheel, use a precision-touchpad scroll, Alt+Tab, press F5: each cancels the request and hides
      the tooltip at once (no 100 px threshold, no grace window). Tab, the validation digits and the cycle chords still
      act on a shown prediction; a still mouse keeps it.
- [ ] AI tooltip « both » mode: with a hotstring tooltip showing, the prediction draws under its rows in one stack and
      the rows leave on their own expiry.
- [ ] Restored API entry under another account (2026-11-13): restore a configuration backup holding a DPAPI API key
      under a second Windows account; the entry is greyed with « Edit » only, and a new key makes it work.
- [ ] AI Agent submenu: an installed driver shows its composed menu.
- [ ] Remote authentication: exercise real IBM and Google token services; local request/refusal tests do not qualify
      their live responses.

### Gestures, metrics and UI

- [ ] **Windows incremental swipes (raw touchpad reader):** on a Precision Touchpad, after « Configurer
      automatiquement » so the slots are routed to Ergopti: 1. The log at start has `Touchpad raw reports
registered`, and at the first touch `Touchpad <handle>: N finger(s), X x Y units per mm` (not `reports no
physical size`); X and Y match the pad's width and height (logical span over millimetres). 2. With
      `swipe_3_left`/`swipe_3_right` incremental (the default) and tab_next/tab_prev bound, a slow three-finger swipe
      across the pad in a browser steps one tab per 3.5 mm, starting after 3.5 mm; coming back half a step reverses;
      a debug log shows `swallowed` for the shortcut and the tab count equals the steps, never one more. 3. A quick
      short swipe (under the first step) still switches exactly one tab (the deferred shortcut, `fires once` at the
      lift). 4. Change the step to 10.0 and 1.0 from the slot's submenu: the distance per tab follows without a
      restart; set the slot to « Action unique (x1) »: one tab per swipe, no step. 5. Four-finger swipes (x1 by
      default) still act once; three-finger taps unchanged; swipes on a slot Windows does not route to Ergopti do
      nothing extra. 6. Pause Ergopti mid-swipe: no further step; resume: the next swipe steps from zero.
      Unplug/replug an external Precision Touchpad: `forgotten` then a fresh descriptor log. 7. Note in the log
      whether the shortcut (`shortcut swallowed`/`deferred`) arrives before or after the lift, to confirm the handoff
      window (300 ms) is enough.
- [ ] WG-003 two-account check: as a standard user, run the first-run wizard's gesture registration and answer UAC
      with a different administrator account; the standard user's PrecisionTouchPad values change (and its backup is
      theirs), the administrator's hive is untouched, and the touchpad restart still reports success.
- [ ] Virtual desktops: on Windows 11 and Windows 10 switch desktops (Win+Ctrl+Left/Right) and confirm one
      `space_change` per switch in today.log and the dashboard's desktop-change KPI, and none from Alt+Tab.
- [ ] Encrypted metrics: enable Metrics > « Encrypt logs on disk », type a unique marker in Notepad, wait for the
      ingest and check that `by_device\<id>\today.log` holds no readable marker while the dashboard still counts it.
- [ ] Metrics ledgers: the Windows reader replays a Linux `by_device/` ledger.
- [ ] Metrics export and purge (`KL_RunMetricsMaintenance`): only source contracts check that path.
- [ ] WPM notification-area readout: tick Metrics > « WPM in menu bar », type: a second icon shows the number (source
      colour after a hotstring, neutral otherwise), hides when typing stops and on pause; restart Explorer: it comes
      back; quit: it leaves; at 125 % and 200 % the number stays legible.
- [ ] WPM widget: drag it, restart, and check it comes back where it was (the old split position keys are no longer
      read, so it starts once at its default).
- [ ] Typing-speed widget bursts (TWD-2, 2026-11-16): with the widget on, type a sentence in Notepad: it shows; an
      arrow, F5, Ctrl+C, Ctrl alone, Alt alone, Win alone, a click, a one-pixel mouse move or a wheel turn hides it at
      once; Shift and AltGr (alone, held, together; AltGr's own LCtrl is no lone Ctrl), Backspace, Enter and Tab keep
      it; an AltGr character counts as typed text.
- [ ] Brightness joined source; retired Metrics shortcuts across a three-OS full save and an installed upgrade (63,
      71).
- [ ] Ten window-toggle actions, also without WebView2 (native fallbacks): no orphan WebView2 process.
- [ ] Manual steps 1 to 4 of [windows-maintainer-checks.md](docs/tooling/windows-maintainer-checks.md) (Win+S,
      Backspace word start, Versions Retry, pair popup).
- [ ] Review the machine translations of 1 November (curl, proxy, token exchange, WebView2, chord and case-twin keys).

- [ ] **Accessibility with Narrator and NVDA** ([audit](docs/audits/accessibility/README.md)): 1. Tray: Win+B
      reaches the icon; its name is « Ergopti+ », and « Ergopti+ (paused) » after a pause from the menu and after
      a pause taken while CapsLock holds the navigation layer; the menu opens with Shift+F10 or the menu key; every
      item and submenu is read and runs from the keyboard. 2. Open Studio, the metrics, the hotstring settings and
      the onboarding: the focus lands inside the page when the window opens (else call the WebView2 controller's
      `MoveFocus`), Tab walks every control in order and Escape closes. 3. Type a trigger with a preview, then ask
      an AI prediction: Narrator and NVDA each say the preview once (not the struck-through alternates) and the
      selected prediction when it is complete (the tooltip window is a polite live region); with no screen reader
      running nothing changes; say whether the speech interrupts typing or lags. 4. The error dialog, the download
      window and the config cleanup open without focus: is anything read? 5. Windows high contrast (Settings >
      Accessibility > Contrast themes), switched while Ergopti+ runs: the next hotstring and AI tooltips take the
      theme's tooltip colours with no tint; which native windows keep fixed colours, and do the Studio's bars and heatmap stay visible (`forced-colors`). 6. Text size at 150 % then 225 % (Settings > Accessibility > Text size): the tooltips' text grows without clipping;
      then reopen the update check, the Releases window, the hotstring settings, the action picker and the
      Encryptor: their text is larger too (fourth pass), say which ones clip or wrap a label;
      display scale 200 %: clipped text in native windows. 9. With Narrator on, type until the WPM widget shows,
      reach it with the Narrator key + arrows: it says « 72 WPM » (the speed); press the Spotlight shortcut: « Mouse
      pointer highlighted » is said once. 7. The hotstring settings window: the four « ↺ »
      buttons read « Restore default: Delay (ms) » and so on, the colour swatch is not read as a progress bar. 8. Fields named by their label: the Win + G link editor (« Link: »), the Releases window's channel picker
      (« Update channel ») and notes (« Changelog »), the input check's field.

- [ ] Metrics views and WPM readouts (MET-01 to MET-03, MET-06 to MET-08, MET-13 to MET-19, 2026-11-21): 1. With the tray
      readout on, type a burst then stop: the readout falls to nothing about 5 s after the last key, not 15 s
      (MET-01). 2. Accept an AI suggestion in an app listed in the metrics exclusions and in a private browser
      window: the pill and the tray readout stay off; in an ordinary window they turn the AI colour (MET-02). 3. Open the typing dashboard and the diagnostics, close both, change Configuration > reading font or spacing,
      reopen them: both show the new font (MET-03). 4. Interface in English: the dashboards read `12,345` and `1.2M`
      and a date change reads « Reading the selected period… » with Narrator (MET-06, MET-07). 5. Narrator on, the
      WPM widget in compact then graph mode at the same speed: Narrator names both « N WPM », never « ErgoptiPlus WPM
      Graph » (MET-08). 6. Interface in English: hovering a card definition or a chart point reads English, never
      « Précision » or « Acceptées » (MET-12).
      Graph » (MET-08). 6. Wait 10 s without typing, then type one letter: the pill shows « 0 » at once (MET-18). 7. In the typing dashboard pick a past range with no typing: every card reads « No data », not « Computing… »
      (MET-13). 8. Tab to the activity calendar's « Chart values »: Narrator reads each day and its count (MET-16). 9. Open the dashboard in English from a French session: the banners read English (MET-15). 10. With the
      metrics folder's `cache
eader.sqlite` held open by another program, press Reset: the status line says the
      reset failed and the figures stay (MET-19).
      Graph » (MET-08).
- [ ] Keep-awake and the layout editor's export host (SNU-01 to SNU-03, SNU-07, SNU-11, 2026-11-21): 1. Start
      Simulate activity (keep-awake): the cursor moves every 1 to 5 s and comes back 0.2 s later; the log holds
      « Keep-awake started. ». Leave it 3 min, stop it: « Keep-awake stopped. », and after the next metrics rebuild
      the typing dashboard counts about 3 min of keep-awake time today (it read 0 before). 2. Start it again, pause
      the driver after 1 min, resume after 1 min: the minute before the pause is counted once and keep-awake comes
      back. 3. In the layout editor window, with `vendor/ergopti_lua_export.exe` present, rename
      `_shared/layouts/engine/composer/export_step.lua` in a copy of the install and download the XKB files: the
      editor says « This target cannot be generated from the current layout. », not a generic error code. 4. Start
      keep-awake, quit the driver from the tray after 2 min and start it again: the log holds « Keep-awake
      stopped. » after « Exit accepted », and the dashboard counts those 2 min today (they were lost before).

### Pause, startup, updates and network

- [ ] EDD-1, a pause stops typing, not configuration: paused, save once from each editor (prompt, paths, hotstrings
      window, layout manager install/select/remove, action picker, model page choice, download and removal, magic key
      capture), from the AI scope restore and the hotstring order rows, and from the AI menu's local server rows with
      LM Studio or oMLX running (a model choice, then an address and a key in their dialogs); each writes the file at
      once, the Layout rows stay live, the AI submenu shows the change before the resume, and nothing that acts on
      typing (hotstrings, remaps, tap-holds, predictions) runs until the resume, after which each change applies and
      the local servers are searched again. A click that still waits (API entry test, test prediction, local server
      rescan, touchpad auto-configure, programmable hotstrings) shows the paused notice once.
- [ ] Cold tray in the configured language (TRAY-01, 2026-11-20): with Ergopti set to English and Narrator on, start
      the driver and right-click the icon as soon as it appears: Suspend, Reload and Quit read in English, never «
      Suspendre », « Recharger », « Quitter », and Narrator names the icon « Ergopti+ », never `ErgoptiPlus.exe`. On a
      first run (no `config.toml`), the icon shown beside the wizard reads « ErgoptiPlus — Starting… », is named «
      Ergopti+ », and a click on it brings the wizard forward. Left-click the icon too and note what it does (TRAY-02:
      nothing today, where macOS and Linux open the menu).
- [ ] Update download window (UPD-05, UPD-07, 2026-11-21): Update from the Updates window opens the download
      window, whose bar follows the bytes received; its Cancel stops the update, its close box does not (the update
      installs once verified).
- [ ] Pickers and prompts (PCK-08, PCK-11, PCK-15 to PCK-17, PCK-19, PCK-21, PCK-22, 2026-11-21): with Ergopti in
      English, Metrics > exclude applications: the list's headers read « Application » and « Process », never
      « Processus », and a Word document open shows « Microsoft Word », never the document's name (PCK-21). Tray >
      clean unused settings: the window comes to the front with the keyboard, and Escape closes it. Open a shortcut's
      action picker from the tray and type at once, Narrator on: the search field has the keyboard (PCK-16). With
      `config.toml` read-only, pick an action: the picker stays open for another pick (PCK-15). Click « Other
      value… » of the AI temperature twice in a row: one input box only, brought forward (PCK-17). The model
      selector and the physical shortcuts window close on Escape (PCK-19). In Arabic, the action picker and the
      prompt editor lay out right to left (PCK-22).
- [ ] Updates window (UPD-01, UPD-03, UPD-04, 2026-11-21): with Narrator on, About > Check for updates: Narrator
      reads « Checking for updates on the … channel » then the answer without a focus move, and Escape closes the
      window while the page has the focus. On a test build fed by a local release mirror whose `.sha256` does not
      match the asset, Update ends on « The integrity check of v… failed: nothing was installed. », never « Check
      your internet connection »; nothing is replaced.
- [ ] Missing tray logo (TRAY-05, 2026-11-21): in a copy of the install, move `img\logo\logo_simple_disabled.ico` away
      and start the driver: running, the usual logo; pause: the tray draws the Windows warning sign (user32.dll icon
      101), not the running logo, Narrator names it « Ergopti+ (paused, icon file missing, reinstall Ergopti+) » in
      the configured language, and the log holds one error naming the file, not one per pause; resume: the logo
      comes back. Put the file back.
- [ ] Boot and menu timings: a toggle must not rebuild 1000 rows; compare base and candidate with interleaved smoke
      boots (summed `process_cpu`); the 2026-11-16 smoke boots gave `Boot complete` between 5.9 and 8.7 s.
- [ ] Hot-path span lines: at DEBUG, switch the layout once; the field log then holds a `layout.switch` pair beside the
      `tray.fill` and `hotstring.expand` ones already seen.
- [ ] One folder name: after the next boot, `%APPDATA%\Ergopti\` is gone and the log holds « Removed the emptied
      legacy folder » (`legacy-folder-migration-bootstrap-log`); the rest of the handoff's Windows list
      ([handoff](docs/tooling/one-folder-name-handoff.md#what-the-maintainer-checks-on-each-machine)) passed on
      2026-11-16.
- [ ] Requalify the key-combination and updater cohorts after the structure migration: the native key-combination run
      (`run-windows-key-combination-cohorts.cjs`) needs the CI lane's generated
      `windows-key-combination-cohort-inputs.json`; the updater cohort
      (`run-windows-updater-original-diagnostic-cohort.cjs --local`) refused with « source pin changed » on
      2026-11-16: reseal its inputs, then rerun it.
- [ ] Updater: install a build with 5d6beccf83, update: the exe restarts, the three scripts are in
      `%LOCALAPPDATA%\Ergopti\vendor\`, the command line shows `-File`, no `-EncodedCommand`.
- [ ] api.github.com blocked: the update check's Atom fallback reports the version.
- [ ] "Create a GitHub issue" signed in opens the form with no "Whoops" page (4e63c54c8a).
- [ ] Developer mode: a source-mode driver ignores `taskkill /PID` without `/F` (2026-11-17; File > Exit closes it
      cleanly), and `run-windows-dev.ps1` closes the exe with the same `taskkill /IM`: check that the exe does close.
      `tools\dev\run-windows-dev.ps1` with the exe running closes the exe, the tray appears, saving
      an `.ahk` reloads once; `npm run dev:windows` from Git Bash and cmd; double-click `ErgoptiPlus.ahk` with and
      without the exe (expected lines in `docs/design/developer-mode.md`).
- [ ] Corporate network (item 62; 1d15b51e66, 7c001b2456): Debug > diagnostics (`github_api`, `proxy_pac`), a model
      pull behind a PAC (and with the PAC unreachable, d20d328751; behind `PROXY dead:3128; DIRECT` it goes direct
      after the 1 s probe), the Windows security warning for the native CA case, Kerberos, TLS inspection and
      revocation.
- [ ] Native Windows TLS fixture (`docs/memory/windows-ahk.md`): `X509Store.Add` on the CurrentUser root store blocks
      on the Windows security warning, so a person runs the native cases with `--interactive` (10 s to click); local
      runs report them NOT EXECUTED at `ChangeTrust(true)`.
- [ ] Native receiving: replay refused writes, native timer admission, stale epochs and physical cleanup at the
      retained runtime, editor and diagnostics boundaries
      ([native UI audit](docs/audits/platform-parity/2026-11-05-native-ui/report.md)); the flow scenarios WCP-002 (a
      paste into a new foreground window, real key emission) and a DPAPI blob of another Windows account
      ([flow review](docs/audits/platform-parity/2026-11-04-flows/report.md)); the account-context and PnP scenarios
      of each module coverage register ([18-scope review](docs/audits/platform-parity/2026-11-04-deep/report.md)).

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
