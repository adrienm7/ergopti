# Pause: configuration stays available (first pass)

Audited source: `claude/ergopti-todo-parity-b`, on `dev`.
Date: November 12, 2026.

## Scope

Maintainer decision EDD-1 (2026-11-12), sharpened the same day into a « real
pause »: while the driver is paused, every configuration and install action
stays available, and everything that acts on typing stays inert. This pass
removes the pause gates on the menus' whole-scope restore and clear and on
opening the physical shortcuts editor, on macOS and Linux. Windows
(`windows/**`) is the read-only reference; its counterpart is in `TODO.md`
« Windows (the PC agent's) ».

## Fixed (macOS and Linux)

| Sequence                                                           | Before                                                                                                                                                      | Regression                                         |
| ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| Pause, then open the physical shortcuts editor                     | Linux and macOS menus refused to open it                                                                                                                    | `edd1-paused-writes` (physical editor menu)        |
| Pause, then « restore recommended » or « clear » in a feature menu | Every scope owner refused: Linux script, tap-hold, hotstrings, shortcuts, key combinations; macOS scoped preferences, gestures, layout, metrics, AI restore | `edd1-paused-writes` in each scope suite           |
| Pause, then the Configuration menu's restore or clear              | Linux refused the composition; macOS greyed both rows and stripped their handler                                                                            | global scope suites, shared Configuration contract |
| Pause, then edit an ordered key combination or its delay (Linux)   | The pair owner refused its configuration source while paused                                                                                                | `edd1-paused-writes` (ordered pair, delay)         |

The typing runtime keeps its pause: the Linux pair owner's runtime capture,
action capture and engine admission still require an unpaused driver, which
the paused-custody regression asserts.

## Second pass: tray rows and submenu rows

| Sequence                                                                                  | Before                                                                                                              | Regression                                 |
| ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| Pause, then open a feature menu from the tray                                             | Both trays greyed every row the manifest marks `greyed_when_paused`; macOS Shortcuts and Gestures greyed themselves | `edd1-paused-writes` in both trays' suites |
| Pause, then use the Configuration menu's « clean unused keys » (macOS)                    | Greyed and stripped of its handler                                                                                  | shared Configuration contract, macOS suite |
| Pause, then reorder, toggle or bulk-toggle Linux hotstring sections                       | Greyed and refused                                                                                                  | Linux hotstrings suites                    |
| Pause, then change the layout switched to on pause or resume                              | Greyed on both drivers                                                                                              | layout switching suites                    |
| Pause, then edit a Linux keyboard group or the wrap choices, or restore or clear gestures | Refused                                                                                                             | Linux shortcuts and gestures suites        |

`greyed_when_paused` stays in `menu.toml`: only the AHK tray reads it now,
and the Windows agent deletes it with its `A_IsSuspended` gates (choice B,
2026-11-12).

## Third pass (2026-11-13, worker H)

| Sequence                                                                                                                                                | Before                                                                | Regression                                                                                            |
| ------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Pause, then switch Gestures on or off (macOS)                                                                                                           | Refused; the slot rows greyed                                         | `test_menu_gestures_pause_gate`, `test_switch_under_suspension` (`edd1-paused-writes`)                |
| Pause, then restore or clear gestures (Linux)                                                                                                           | `gestures.apply_scope` refused « gesture configuration is paused »    | `test_gesture_scope` (the real menu's clear while paused, the switch while paused stays inert)        |
| Pause, then edit a tap-hold key's tap or delay (Linux)                                                                                                  | `capture_configuration_edit` and the menu's guard refused             | `test_tap_hold_edit_owner` (committed while paused, installed on resume)                              |
| Pause, then the programmable hotstrings switch, delay, example                                                                                          | The shared policy refused through its `paused` port (macOS and Linux) | shared `user_hotstring_menu_contract`, macOS `test_user_code_native` (`edd1-paused-writes`)           |
| Pause, then switch Shortcuts on or off (macOS)                                                                                                          | Refused                                                               | `test_shortcuts_toggle_pause_gated`, `test_feature_toggle_keeps_script_control`, `test_bindings_debt` |
| Pause, then a hotstring section, a language or extension « all sections », a section order, the preview rows, the delays or the settings window (macOS) | Greyed or refused                                                     | the hotstrings menu suites (`edd1-paused-writes`), `menu-hotstring-language-binding.cjs` proofs       |

macOS records the Gestures switch with `gestures.set_enabled_under_suspension`: OFF
releases the native runtime at once, ON publishes only the flag and the start
intent, and `resume()` starts the runtime. On Linux the reader may run under a
pause and the dispatch keeps every gesture but the script-control ones inert, so
the switch and the scope commit at once. A Linux tap-hold edit made while paused
reloads an engine the paused hook does not install (`_apply`), and resume
installs it; a pause or resume transition still retires an editor captured
before it, through the manager's generation. The programmable source loads at
once when switched on while paused; its hotstrings stay inert because the
paused driver types nothing (confirmed by the maintainer on 2026-11-14).

The macOS Shortcuts switch records its intent under ScriptControl's claim
(`shortcuts.set_feature_intent_under_pause`): OFF publishes the feature claim,
ON drops it, and nothing binds under the pause. ScriptControl's resume inverse
for a layer that was OFF at pause time is now
`shortcuts.resume_bindings_after_pause`, which starts the layer only when the
switch turned it ON during the pause. A macOS hotstring section switched while
paused changes the registry at once; the keymap's processing stays paused, so
nothing expands until resume.

Typing-inertness audit, Linux WPM (worker H, 2026-11-13): the WPM widget and
the tray readout kept ticking while paused, so a pause right after typing left
a fading speed on screen and a key typed while paused brought the widget back.
Windows and macOS hide both. The daemon tick now passes the live pause and
both surfaces hide (`(wpm-pause-hides)` in `test_wpm_readouts`).

## Fourth pass (2026-11-14, worker H): shared rows on all three drivers

| Sequence                                                                                         | Before                                                                   | Regression                                                                                                                                                |
| ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pause, then open the personal hotstrings editor                                                  | Refused on every driver; the shared corpus pinned the pause              | `personal_editor_command.json`, `test_personal_editor_menu_scope.ahk`, `test_hotstring_editor_shortcut_transaction`                                       |
| Pause, then a word expander row, a custom terminator, or an extension scope command              | Greyed or refused (Windows `A_IsSuspended`, macOS and Linux readiness)   | `test_word_expander_commands.ahk`, `test_terminator_admission.ahk`, `test_custom_terminator_add_transaction`, `test_terminator_bulk_mutation_transaction` |
| Pause, then an AI privacy, trigger, Info Bar, streaming, indentation, Show-all or generation row | The shared policies and their AutoHotkey twins refused a paused snapshot | the four shared corpora (paused admitted, a malformed pause refused), each driver's settings suites                                                       |

A pause stops typing, not configuration: each of these rows commits while
paused and the engine reads the stored value when typing resumes. A missing or
non-boolean pause is still refused. On macOS the AI settings groups grey only
when the AI is off.

Later on 2026-11-14 (worker H): the AI switch turns the AI off while paused on
the three OS; turning it on waits for resume, because it starts model warmups
and may offer an install (decided by the agent on 2026-11-14, accepted by the
coordinator). AI profiles are chosen, created, cloned, edited and deleted while
paused; the macOS profile shortcut waits for resume because it binds a hotkey
(`llm_custom_profile_shortcut_ready`). Regressions: `test_llm_menu_toggle_row`
on macOS and Linux, `test_config_journal_ai_admission.ahk`, the profile
suites (`edd1-paused-writes`).

Later on 2026-11-14 (worker H): the macOS model page opens while paused and
its choices, downloads and API entry changes run; a key test, a server rescan,
an MLX port change and a runtime install wait for resume, and a model chosen
while paused is warmed on resume (`warmup_controller.defer_to_resume`). Linux
removes an installed model while paused. Windows keeps both refused: its pause
retires every AI operation and its tray greys the AI submenu (EDD-1 on AHK).

## Fifth pass (2026-11-14, worker P): shortcut slots changed while paused

Decided by the maintainer on 2026-11-14: a shortcut slot changed while paused
is saved at once and takes effect only on resume; the chord that resumes stays
the one active when the pause began.

| Sequence                                                                | Before                                                                                      | Regression                                                                                         |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| macOS: pause, then a script chord slot, the chords' switch or a restore | Slot rows greyed; a scope restore or clear applied at once and could move the resume chord  | `test_paused_chord_change_waits_for_resume`, `test_shortcuts_runtime_transaction`                  |
| macOS: pause, then a keyboard slot (Add, edit, group restore and clear) | Rows greyed and `keyboard_shortcuts.set_action` refused while paused                        | `test_keyboard_canonical` `(paused-slot-change)`, `test_menu_keyboard_slots_declared_group_frames` |
| macOS: pause, then the personal editor's legacy shortcut row            | The row had no action while paused                                                          | `test_hotstring_editor_shortcut_transaction` `(paused-slot-change)`                                |
| Linux: pause, then a script chord slot, the switch or a restore         | Applied at once: moving the pause toggle off AltGr+Enter left the daemon with no chord back | `test_script_chords` `(paused-chord-change)`                                                       |

macOS: `script_control` keeps a change made while paused, or while a pause or
resume is settling, in a deferred table that `get_shortcut_actions` and
`chords_enabled` report, while dispatch, `slot_runs` and the Karabiner plan
keep the chords of pause time; the table is applied once the resume settles.
Keyboard slots hold no hotkey while paused, so an edit is only published and
the resume start binds it from the file. The editor shortcut is saved without
binding; the menu's resume listener binds it. A parameterized action (a link,
a program) is admitted while paused too (`program_parameter_transaction`), as
the paused driver runs none.

Linux: `script_chords` copies the chords live at pause time before a paused
change replaces them, and answers presses from that copy while the same pause
lasts (`pause_epoch`). Its keyboard slots already follow SCD-1: no Linux slot
runs through a pause, and each press reads the configuration.

Windows: the tray greys the Shortcuts submenu while paused, so no slot row
changes then. A global restore or clear from the Configuration menu while
paused rewrites the chords and reloads born suspended with them; it is put to
the maintainer through the coordinator.

## Left (next pass, listed rather than guessed)

These still refuse or grey while paused. Ungating the menu alone would let a
paused driver act at once instead of « on resume », or the change needs its
source proofs reworked first:

- AI menus: turning the AI on (it starts model warmups and may offer an
  install), and on Windows the model and API entry rows, the whole-scope
  restore and clear, and the tray's greying of the AI submenu.
- macOS magic key source capture: it listens to a physical key press.
- The audit that every typing feature is inert while paused, and that a
  setting changed while paused applies on resume. Layout emulation is done:
  both Lua drivers gate it on the live pause (`is_active` from
  `CoreState.processing_paused` on macOS, `script_actions.is_paused` on Linux),
  pinned by `test_layout_emulation` on each driver.
- Windows: every `A_IsSuspended` gate is listed in
  [the Windows inventory](windows-inventory.md); the fourth pass removed the
  personal editor, word expander, terminator, extension scope and AI settings
  row gates above.
