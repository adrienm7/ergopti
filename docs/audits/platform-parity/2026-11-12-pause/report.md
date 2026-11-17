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
changes then, but a global restore or clear while paused reloaded born
suspended with the new chords at once (decided by the coordinator on
2026-11-14 to fix now). The chord gate now reads the chords of pause time while
paused (`ScriptShortcutPausedChords`, taken by `Ergopti_OnSuspendEnter`,
dropped by `Ergopti_OnSuspendResume`); a reload while paused writes them to
`suspend_restore.chords` beside the suspend marker before preparing it, and the
replayed pause reads them back. A file no replayed pause claims is removed.
Regression: `test_script_chords_follow_their_slot.ahk` `(paused-chord-change)`.

## Sixth pass (2026-11-14, worker P): the magic key capture while paused

Decided by the coordinator on 2026-11-14 (EDD-1): « capture the next key » runs
while paused on the three OS; the key is saved at once and stays inert until
resume, since a paused driver remaps nothing; a pause or a resume during the
capture cancels it. Before, all three refused it while paused (macOS dropped the
row's action, Linux `can_capture` required `is_active`, Windows
`MagicKeySourceCapture` returned on `A_IsSuspended`).

The Windows tray greyed the whole Layout submenu while paused, so the capture
was unreachable there (decided by the coordinator on 2026-11-14 to lift it):
the Layout head now stays live while paused, a pause or a resume builds its
rows again at the next open (`MenuDeferred_Rearm`, the tray root being kept
under a pause), and only the layout manager and the layout editor, whose pages
refuse every command under Suspend, are greyed with « ErgoptiPlus est en
pause ». The pause and resume layout pickers no longer grey while paused, as
on macOS and Linux. Regressions: `test_tray_pause_greys_features.ahk`
`(paused-layout-live)`.

| OS      | Change                                                                                                    | Regression                                                        |
| ------- | --------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| macOS   | `magic_key_source_menu` admits a settled pause and binds the capture to the pause state it started in     | `test_magic_key_source_menu` `(paused-magic-capture)`             |
| Linux   | `magic_key_source.can_capture` needs the grab only; the pause listener cancels a capture on either edge   | `test_magic_key_source_config_toml_leaf` `(paused-magic-capture)` |
| Windows | `MagicKeySourceCapture` follows the pause state it started in; the resume reactor stops a capture as well | `test_magic_key_capture_settlement.ahk` `source paused-live`      |

## Typing-inertness audit (2026-11-14, worker P)

A census of every typing feature's pause gate on the three drivers (hotstrings
of every kind, the physical magic key, layout emulation, tap-holds, layers,
chords, one-shot modifiers, CapsWord, keyboard slots, tap keys, wrap, text and
accented shortcuts, gestures, AI predictions, metrics, WPM, the preview, dead
keys). Each is gated on Windows (native Suspend plus the explicit `A_IsSuspended`
gates; the only Suspend-exempt hotkeys are the script chords) and on macOS (the
keymap's `processing_paused`, Karabiner's paused graph, the pause inventory).

Fixed on Linux: Main fed every physical key-down to the heatmap and the live
WPM, and counted every modifier chord, while paused (`handle_physical`,
`handle_control`, `consume_bound_chord`); macOS and Windows drop them. Regression:
`test_paused_driver_records_no_keys` `(paused-records-no-keys)`.

Fixed on macOS: nothing ended CapsWord at pause, where Windows and Linux do.
The paused Karabiner graph holds no CapsWord rule, so its auto-off could not
answer and its CapsLock stayed on through the pause. The pause inventory now
runs the one-way `watchers.end_capsword_for_pause`, which clears only a CapsWord
known active. Regressions: `test_pause_ends_capsword`,
`test_watchers_capsword_auto_off` `(paused-ends-capsword)`; field point
`pause_ends_capsword`.

## Background behaviours census (2026-11-14, worker P)

The maintainer listed what must stop at pause on the three OS: keystroke
metrics, application usage metrics, and the keep-awake action that moves the
mouse (Ctrl+M on macOS, Win+M on Windows) with every other mouse action. The
census then covered every background behaviour driven by keys, the pointer or
the active application.

| Behaviour                                                        | Windows | macOS              | Linux         |
| ---------------------------------------------------------------- | ------- | ------------------ | ------------- |
| Keystroke metrics                                                | stops   | stops              | stops (fixed) |
| Application time, app switches, window titles                    | stops   | stops (fixed)      | stops (fixed) |
| Pointer clicks, scroll, distance, tap-to-click                   | stops   | stops (fixed edge) | stops (fixed) |
| Window topology, capture presence, network and VPN rows          | stops   | stops              | stops (fixed) |
| System day counters (lock, sleep, mute, Wi-Fi, battery, desktop) | stops   | stops              | stops (fixed) |
| Clipboard copy and paste metrics                                 | stops   | stops              | stops         |
| Keep-awake and activity simulation, restored on resume           | stops   | stops              | stops         |
| Keyboard-slot and gesture actions, mouse moves and click holds   | stops   | stops              | stops         |
| Mouse spotlight overlay                                          | stops   | stops              | stops (fixed) |
| Mouse-layer wheel                                                | stops   | stops              | stops         |
| Hotstrings, auto-corrections, previews, WPM                      | stops   | stops              | stops         |
| AI predictions, agent, Info Bar, warmups                         | stops   | stops              | stops         |

Linux: keystats kept recording everything but keystrokes while paused, its
single gate `may_record` reading only the Metrics menu's pause.
`keystats.set_script_paused`, set by the pause listener, now closes it for
every writer; the system day sampler waits for the resume, the pause dismisses
the spotlight, and the resume opens the focused application's time again.
macOS: the paused maintenance tick kept the distance seed, crediting the
pause's travel at the resume. Regressions: Linux `test_paused_driver_records_no_keys`,
`test_window_titles` and `test_excluded_span_boundary` (`driver-paused`);
macOS `test_pause_forgets_mouse_seed`.

Fixed, macOS (eighth pass): the pause inventory closes the foreground interval
(`keystats.close_app_interval_for_pause`), so the time before the pause is
credited and the resume opens a new interval. The first attempt was reverted
because `test_physical_history_persistence` then failed its rebuild. The cause
was the test's SQLite bridge, not the rebuild: SQL NULL crosses it as JSON
null, and the shared decoder's default mode turns null into a truthy empty
table (`(val == NULL) and nil or val` always yields `val`), so the closed
interval's NULL `next_app` reached the walker as a table. lsqlite3 returns nil
in production. The bridge now maps NULL to nil, as the cold-rollover bridge
does; the decoder itself is a separate question to the coordinator.
Regression: `test_pause_closes_app_interval`.

Keep-awake across a pause (decided by the maintainer on 2026-11-14): a pause
stops it and the resume restores it when it ran at the pause, on the three OS.
macOS already did (`bindings.lua` `resume_awake`); Windows records it in
`Ergopti_OnSuspendEnter` and restarts it once the resume settled
(`_LifecycleRestoreKeepAwake`); Linux `keep_awake.set_paused`, called from the
gestures manager's pause, starts it again once the old inhibitor settled.
Regressions: `test_keepawake_restored_on_resume.ahk`, Linux `test_keep_awake`
and macOS `test_rebind_preserves_keep_awake` `(paused-keepawake-restore)`.

## Seventh pass (2026-11-14, worker P): the number-row choice while paused

The shared number-row policy (`number_row_policy.lua`, its Windows twin
`number_row_policy.ahk`) refused every snapshot taken while paused, so the
number-row rows refused on the three OS. A pause now admits the choice: it is
saved at once and the resume reads the stored row. A snapshot whose `paused`
field is not a boolean is still refused, and `paused` joins the fields an
intent compares, so a pause or resume between the capture and the write
retires the capture (as the magic key capture). Regressions: the shared
contract `(paused-number-row)` and the Windows `test_number_row_symbols`
corpus.

## Eighth pass (2026-11-17): the Windows editors and AI menus

The Windows editors that refused a paused click, most with a log line only,
now save while paused: the prompt editor, the paths editor and its native
fallback, the hotstrings window, the layout manager (install, select, remove),
the action picker and its program discovery, the model page (choice, download,
removal, native list), the magic key character capture, the AI scope restore,
the API entries and the hotstring order rows. The pause greying of the Layout
rows and of the hotstring order rows is gone, and the AI submenu is rebuilt
under a settled pause (`_LLM_Menu_BuildHeld` holds a build only during the
pause transition). The API entry test and the test prediction wait for the
resume and say so. Regressions: `test_paused_handlers_never_silent.ahk` (every
pause reader of the configuration surfaces is told or classified),
`test_bridge_suspend_guard.ahk`, and the paused cases of the paths editor,
model browser, layout manager, magic key capture, hotstring order and
physical editor suites.

## Ninth pass (2026-11-17): the Windows local server rows

The AI menu's local server rows greyed under a pause and the panel refused a
model choice, an address or a key while paused; the pause also retired the
panel. They now commit while paused, and only the rescan, which talks to the
servers, waits for the resume and says so. The pause stops the panel's network
work (a sweep or a port scan in flight is cancelled) and keeps the accepted
verdicts, which do not age while paused. A source receipt commits only in the
pause state it was captured in, so the pause and the resume each retire the
panel's view and a build prepares the next one; the local server owner's reads
cross a pause (`_PausedReadPort`), so the verdicts stay usable. After a paused
write the verdicts need the resume's sweep and show inert, with the new choice
checked. macOS and Linux still grey these rows (`menu.lua` `paused`), which
this pass found: the report's earlier passes did not list them (TODO).
Regressions: `test_local_server_panel_view_preparation.ahk`
`(paused-local-server-rows)` under a real Suspend, and the panel case of
`test_paused_handlers_never_silent.ahk`.

## Tenth pass (2026-11-17): the macOS and Linux local server rows

The shared row builder (`ai/engine/local_servers/menu.lua`) greyed every local
server row under `paused`, and the macOS panel (`admitted`) and the Linux rows
(`admit`, `can_configure_local_servers`) refused a model choice, an address and
a key while paused. As on Windows they now commit while paused; only the
rescan, which talks to the servers, waits for the resume and says so with the
paused notice (`notify.paused_refused`). The shared discovery controller owns
the pause (`pause`, `resume`): a sweep in flight is fenced and its callers
dropped, a new one is refused, and the verdicts stay with their age frozen. A
write, a view change or a sweep the pause cut short holds them (`is_held`):
shown, without actions, until the resume's sweep. The builder's option is now
`inert` (the AI off, an unreadable pause, held verdicts), as on Windows. macOS
wires it as the `api_remote.pause_local_discovery` pause step, which also
cancels the probes in flight; Linux's `on_pause_change` calls
`local_servers.pause` (scan and probes cancelled) and `resume`. Regressions:
the shared `run_pause` contract replayed by both drivers, macOS
`test_local_openai_backends_api_models.lua` and Linux
`test_local_server_discovery.lua` (`edd1-local-server-rows`).

## Left (next pass, listed rather than guessed)

These still refuse or grey while paused. Ungating the menu alone would let a
paused driver act at once instead of « on resume », or the change needs its
source proofs reworked first:

- AI menus: turning the AI on (it starts model warmups and may offer an
  install), on the three OS, greyed with its reason.
- Windows: the onboarding page, the touchpad auto-configure, the programmable
  hotstrings switch and the metrics page refuse while paused and say so.
