# Windows maintainer checks

The "Maintainer checks > Windows PC" lists of `docs/ERGOPTIPLUS_TODO.md` ask for
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
  tap-hold's tap is, so it types with `SendEvent` at `SendLevel` 100.
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
(the maintainer's own, a build under test) is on the desktop. Its hooks see the
same keys, expand or remap them too, and its metrics record them. Close it, or
pass `--allow-other-driver` to run anyway: the checks that judge the private
driver's own state (the engine buffer, its log) stay valid, the screen is then
not judged. `capsword-auto-off` ignores the flag, because CapsWord writes the
real CapsLock state, which that driver's CapsLock tap-hold would see.

## Checks

| Check                                   | TODO line                                                  | Also covered by                                      |
| --------------------------------------- | ---------------------------------------------------------- | ---------------------------------------------------- |
| `reload-click-joins`                    | Menu-click replay; item 142                                | `test_menu_reload_replay.ahk`                        |
| `reload-command`                        | Local reload command (idle, paused, during a reload)       | `test_driver_control.ahk`                            |
| `menu-click-replay`                     | Menu-click replay                                          | `test_menu_reload_replay*.ahk`                       |
| `private-browsing-click-during-startup` | Private-browsing metrics filter                            | `test_menu_command_deferral.ahk`                     |
| `private-browsing-click-during-write`   | Private-browsing metrics filter                            | same                                                 |
| `tap-delay-row`                         | Tap delay row                                              | `test_tap_hold_duration_transaction.ahk`             |
| `keyboard-group-scope`                  | Keyboard group restore and clear                           | `test_keyboard_slot_group_scope.ahk`                 |
| `taphold-pickers`                       | Tap-hold pickers                                           | none                                                 |
| `keycombo-picker`                       | Key-combination picker                                     | `test_key_combinations.ahk`                          |
| `keycombo-pair-saved`                   | Number row and key combinations: a pair saved and reloaded | same                                                 |
| `number-row-inert-choice`               | Number row: an inert choice ticked, greyed and suffixed    | `test_number_row_symbols.ahk`                        |
| `window-titles`                         | Window titles                                              | `test_window_manager_present_window.ahk`             |
| `versions-tabs`                         | Versions tabs                                              | `test-changelog-channel-sync.cjs`                    |
| `win-s-open-target`                     | Win+S open target                                          | `test_open_target_vectors.ahk`, `test_shortcuts.ahk` |
| `backspace-word-start`                  | Backspace word start                                       | `test_hotstring_backspace_word_start.ahk`            |
| `capsword-auto-off`                     | CapsWord auto-off                                          | `test_capsword_state.ahk`, the shared corpus         |

## What stays manual

Press, look for, and bring back the lines named. The driver logs are in
`%LOCALAPPDATA%\ergopti_plus\logs` (`ErgoptiPlus_<date>.log`; `today.log` holds
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
6. **Number row outputs.** Type each row on the real AZERTY, US QWERTY and Ergopti
   layouts for every ordering and the edge-keys choice, with each row emulation
   switch, and compare with the menu; the ² key included.
7. **CapsWord, when `capsword-auto-off` was not executed.** With no other driver
   running, run it. By hand: the trigger LAlt then CapsLock; the eight default
   delimiters, each pointer kind and the delay end it; the next word is lower
   case.
