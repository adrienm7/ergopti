# Windows maintainer checks

The "To confirm on the Windows PC" lines of `TODO.md` ask for
things only a real driver shows: a tray row clicked, a dialog opened, a window
titled, a reload followed. `tools/maintainer/windows-live-checks.cjs` runs the
ones that can be automated against a real `ErgoptiPlus.ahk` booted from the
working tree in an isolated profile, and reports one verdict per check. What it
cannot do is the short manual list at the end of this page.

## How it works

- The tool starts a private driver exactly as the startup smoke does
  (`LOCALAPPDATA` and `ERGOPTI_STARTUP_SMOKE_DIR` name a scratch folder, the code
  is a private copy), under a wrapper that includes
  `windows/tests/live/live_harness.ahk` and `live_checks.ahk`. At the smoke's
  inspection hook the driver stops exiting and serves commands written to
  `<scratch>\live\cmd.txt` instead, answering in `res-<id>.txt`. A reload
  replaces the process; the tool follows the successor.
- A command acts on the live process: it walks the real native tray tree,
  clicks a row with the `WM_COMMAND` the shell posts, and drives the dialogs and
  windows the click opens from a timer (the interrupted thread cannot resume
  while a modal dialog is up, and no timer runs while a native popup menu is
  open). Nothing replaces a driver function with a stub.
- Real keys come from `windows/tests/live/typist.ahk`, a separate hook-free
  process. Its `SendInput` at level 0 is ignored by the driver's InputHook, as a
  tap-hold's tap is, so it types with `SendEvent` at `SendLevel` 100. A check
  that depends on CapsLock sends named keys as `{Blind}{SC039}`: a `Send` that is
  not blind restores CapsLock when it ends, which no physical key can do.
- Every driver and typist it starts is stopped before it returns, the successors
  of a reload included. The report names the other AutoHotkey scripts that were
  running, because AutoHotkey's `SendInput` falls back to `SendEvent` while
  another script holds a keyboard hook.

```powershell
node tools/maintainer/windows-live-checks.cjs --list
node tools/maintainer/windows-live-checks.cjs --only tap-delay-row,reload-command
node tools/maintainer/windows-live-checks.cjs                  # every check
node tools/maintainer/windows-live-checks.cjs --keep           # keep the scratch tree
node tools/maintainer/windows-live-checks.cjs --without-fix-of <commit[,commit]>
```

`--without-fix-of` replaces the driver sources those commits changed by their
parents' in the private copy: the way to see a check fail without the fix it
guards (`1254dd7bd7` for the two reload checks).

Run it when the machine is not busy: one driver needs about 400 MB, and under
memory pressure the Versions window falls back to its native form, which is
reported as "not executed".

## Real keys and a driver already running

A check that types real keys refuses to run while another ErgoptiPlus driver
(the maintainer's own, a build under test) is on the desktop: close it first.
Two drivers each act on the same keys, so the session's typing comes out
doubled. A session started beside one boots paused and owns no input, and the
driver refuses `ERGOPTI_STARTUP_SMOKE_LIVE_INPUT` when a resident holds the
single-owner mutex.

## Checks

| Check                                   | TODO line                                                     | Also covered by                                                         |
| --------------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `reload-click-joins`                    | Menu-click replay; item 142                                   | `test_menu_reload_replay.ahk`                                           |
| `reload-command`                        | Local reload command (idle, paused, during a reload)          | `test_driver_control.ahk`                                               |
| `menu-click-replay`                     | Menu-click replay                                             | `test_menu_reload_replay*.ahk`                                          |
| `reload-over-a-log-flush`               | Menu-click replay                                             | `test_reload_terminal_pending.ahk`                                      |
| `quit-over-a-log-flush`                 | Quit landing on a log flush                                   | `test_quit_admission.ahk`                                               |
| `private-browsing-click-during-startup` | Private-browsing metrics filter                               | `test_menu_command_deferral.ahk`                                        |
| `private-browsing-click-during-write`   | Private-browsing metrics filter                               | same                                                                    |
| `tap-delay-row`                         | Tap delay row                                                 | `test_tap_hold_duration_transaction.ahk`                                |
| `keyboard-group-scope`                  | Keyboard group restore and clear                              | `test_keyboard_slot_group_scope.ahk`                                    |
| `taphold-pickers`                       | Tap-hold pickers                                              | none                                                                    |
| `keycombo-picker`                       | Key-combination picker                                        | `test_key_combinations.ahk`                                             |
| `keycombo-pair-saved`                   | Number row and key combinations: a pair saved and reloaded    | same                                                                    |
| `number-row-inert-choice`               | Number row: an inert choice ticked, greyed and suffixed       | `test_number_row_symbols.ahk`                                           |
| `window-titles`                         | Window titles                                                 | `test_window_manager_present_window.ahk`                                |
| `versions-tabs`                         | Versions tabs                                                 | `test-changelog-channel-sync.cjs`                                       |
| `win-s-open-target`                     | Win+S open target                                             | `test_open_target_vectors.ahk`, `test_shortcuts.ahk`                    |
| `backspace-word-start`                  | Backspace word start                                          | `test_hotstring_backspace_word_start.ahk`                               |
| `capsword-auto-off`                     | CapsWord auto-off                                             | `test_capsword_state.ahk`, the shared corpus                            |
| `clear-restore-categories`              | Clear and Restore: per category and global, then restart      | `test_keyboard_slot_group_scope.ahk`                                    |
| `number-row-layouts`                    | Number row on each installed layout, each ordering            | `test_number_row_symbols.ahk`                                           |
| `hotstring-delays-recommended-cleared`  | Hotstrings: the declared 0.5 s after Restore and after Clear  | `test_hotstrings_scope.ahk`, `section_default_delay_vectors.json`       |
| `handwritten-delimiters`                | Handwritten delimiters: Add, toggle, Delete, restart          | `test_terminator_admission.ahk`                                         |
| `consume-submenu`                       | The delimiters an expansion consumes                          | `test_hotstring_delimiter_global_transaction.ahk`                       |
| `ai-off-inert`                          | AI off (#97)                                                  | `test_llm_hotkeys_deferred_by_pause.ahk`                                |
| `test-prediction-ai-off`                | Test a prediction refuses with the AI off                     | `test_llm_menu_test_prediction.ahk`                                     |
| `tap-hold-v1-migration`                 | tap_hold.toml backup and v1 stamp on an old file              | the `tap_hold_migrations` corpus                                        |
| `old-config-migration`                  | The oldest supported config.toml through the registry         | the `config_migrations` corpus                                          |
| `too-old-config-refused`                | A config.toml below the oldest version, refused byte for byte | the `config_migrations` corpus                                          |
| `quit-refused-during-write`             | Quit during a configuration write                             | `test_quit_admission.ahk`                                               |
| `ai-agent-unavailable-row`              | AI agent submenu composed-menu qualification (121, 123, 137)  | `test_llm_agent.ahk`                                                    |
| `autocorrection-family-alone`           | Each common autocorrection family alone (104, 105)            | `test_hotstrings_cache.ahk`, `test_corpus_hotstring_family_samples.ahk` |
| `hotstring-section-order`               | Hotstring section order: move, restart, reset, a stale menu   | `test_hotstring_dynamic_menu_scope.ahk`, `section_order_vectors.json`   |
| `gestures-info-row`                     | Tray > Gestures: one « Infos… » row that opens the dialog     | `test_gesture_menu_status.ahk`                                          |

## What stays manual

Press, look for, and bring back the lines named. The driver logs are in
`%LOCALAPPDATA%\Ergopti\logs` (`ErgoptiPlus_<date>.log`; `today.log` holds
the typed-keys ledger).

1. **Win+S, what leaves the driver.** In Notepad type each text, select it,
   press Win+S. `192.168.1.1`, `localhost:3000`, `example.com` and
   `https://example.com/page.` open the default browser on that address (the
   final period dropped); `ada@example.com` opens the mail client; an existing
   file path with spaces, quoted or not, opens in its default application; an
   existing folder, `~/Documents` and `%APPDATA%` open in Explorer;
   `HKEY_CURRENT_USER\Control Panel\Desktop` and `HKCU:\Software` open Regedit
   on that key (accept the prompt); `ms-settings:display` opens Settings;
   `bonjour le monde` opens a web search. Bring back the `[Search]` lines.
2. **Backspace word start, other applications.** Windows Terminal with Claude
   Code: Enter on an empty prompt, `ab`, two Backspaces, `c` offers « c’est »;
   Backspace past the empty prompt, then `C★`, `J★`, `Ct★`; `ab`, a 5 s pause,
   two Backspaces, `c★` expands; `ab`, one Backspace, `c★` does nothing. Notepad:
   `ab`, Ctrl+Backspace, `c★`. A browser: Ctrl+L, Backspace, `c★`. AltGr+Backspace
   on an AZERTY-style AltGr and on a Kana layout acts as Backspace. Bring back
   `today.log` for the session.
3. **Versions window.** Needs the network and free memory. Open it, wait for the
   list, click each channel tab: the list repaints at once with no spinner. Cut
   the network, reopen it, press Retry once the network is back: the list loads.
4. **Pair menu and Hold picker.** Shortcuts > Key combinations > Escape >
   « Escape + Tab » pops a menu at the pointer: « Hold 1 + tap 2 → … » and
   « Hold 1 + hold 2 → … » each open the shared picker; the hold one lists the
   holdable actions once the Wave 2 item lands.
5. **Item 51 matrix.** With the AI on and a prediction offered in Notepad
   (Win+Space) that has several slots: each arrow and both Shift+Tab move the
   marker once and wrap, after a reload, with `nav_modifiers = ctrl`, with a
   tap-hold Tab; the footer reads « ⇧G + Tab ou ↑/← »; bubbles and delayed
   expansions with emulation off and on, no « eeee »; one clipboard-log row per
   Ctrl+V; AltGr+Entrée/Suppr/Retour arrière/Échap run their script actions; the
   AI menu; « Revenir à cette version » keeps a backup. Bring back the log of the
   session. This needs a prediction producer the live harness does not have.
6. **Number row outputs.** `number-row-layouts` types the ten digit keys for every
   ordering on each layout installed on the PC. By hand: a layout not installed
   there, the edge-keys choice, each row emulation switch, the ² key.
7. **CapsWord, when `capsword-auto-off` was not executed.** With no other driver
   running, run it. By hand: the trigger LAlt then CapsLock; the eight default
   delimiters, each pointer kind and the delay end it; the next word is lower
   case.
8. **Mirror displays, two screens.** The suite never changes the screens. Bind
   `display_mirror_toggle`, start from Extend: one press mirrors, a second brings
   Extend back with the same arrangement. Again from PC screen only and from Second
   screen only: the second press returns to that one. Mirror by Win+P, then press:
   Extend. With one screen, a notice says no other monitor is detected and nothing
   flickers. Bring back the `display_mirror_toggle` lines.

## Standing checks

The installed-driver checks the maintainer repeats before a release. `TODO.md`
names each by its number; report each as pass, fail or not run.

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
7. **Hotstrings** (items 34, 37, 102, 104, 105, 129), in the installed driver: delays 0.5 s
   recommended and cleared back to 1.0 s; handwritten delimiters and `[[hotstrings.terminators]]`
   through Add, Delete, toggle, save and restart; with no Ergopti layout installed the shipped pack,
   the 24 suffix rules and magic-key repeat appear once; personal files (duplicates, unreadable,
   junctions, depth 16) and their delay, priority, colour and tooltip edits; each common
   autocorrection family alone (34/95/11 rules); `run_all.ahk --only "programmable hotstrings"`
   and the compiled probe `tools/test/run-compiled-user-hotstrings.ps1`; `update` never proposes
   `date`. Full list: `49c62d77a1:docs/handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md`.
8. **Layout switching** (item 38): AZERTY with emulation to native Ergopti and back keeps AltGr
   usable without a reload, also on an AZERTY-style AltGr (LCtrl+RAlt) and a Kana layout.
9. **Touchpad registry** (item 13): values restored after OFF and removal; kept after a refusal.
10. **Managed network** (item 62), behind a company proxy: WinINet settings, PAC order and
    failover, WPAD absence, the eight remote CA cases, Negotiate and NTLM proxy challenges, then the
    installed updater (download, swap, rollback). The twelve detailed steps stay in Git
    (`49c62d77a1:docs/handovers/2026-10-04-group6-windows/README.md`).
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
