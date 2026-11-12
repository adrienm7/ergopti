<!-- TODO-tests-macos.md -->

# ErgoptiPlus checks on a real Mac

The macOS checks only a real Mac can answer; code work stays in [TODO.md](TODO.md).

## To confirm on the Mac

Every open line carries a `field-point` id; one `bash tools/dev/collect-macos-field-report.sh --installed` run
answers each of them in `docs/field-reports/mac-<stamp>/todo_summary.md` (guided steps prompt the gestures in the
terminal): coverage table, verdicts and what no run can test in
[docs/tooling/macos-field-report-coverage.md](docs/tooling/macos-field-report-coverage.md).

- [ ] <!-- field-point: raw_telemetry --> Raw telemetry (2026-11-11): Metrics on, move, resize and full-screen a window, drag it to a second screen and

      open Zoom or OBS: `events_window_topo` and `events_av` hold the rows; turn Wi-Fi off then on and connect a VPN
      (WireGuard or the system IPsec client): `events_network` holds `internet_down`, `internet_up`,
      `vpn_connected` and `vpn_disconnected`, and an idle iCloud Private Relay utun records no VPN.

- [ ] <!-- field-point: pac_real --> PAC route lists with a real PAC (dead relay then DIRECT or a live relay): field report: `field_network` (`route_lookup`) and `field_pac_fallback` on a network with a PAC. Native XCTest milestone: `ManagedProxyRouteWorkerTests` compiled and passed all 23 cases on macOS 26 in [CI run 42374265115](https://github.com/adrienm7/ergopti/actions/runs/42374265115/job/128410747338), source `07dda15c1`, including the native TCP listener probe; the injected route-list cases do not close application receiving with a real PAC.

- [ ] <!-- field-point: minimum_tap --> Minimum tap: with CapsLock set to Enter on tap and Ctrl on hold, a bounce of about 20 ms types nothing and leaves no Ctrl held, a 60 ms tap types Enter, and Space still types at once in fast typing (owned runtime `to_delayed_action` timing, generator `apply_tap_minimum`).
- [ ] <!-- field-point: lalt_one_shot --> Left Command's one-shot Shift (2026-11-12): with Left Command tapping the one-shot Shift and holding nothing, a tap then a letter types it capitalised, holding it shifts each key typed under it, and under a held Right Option, Caps Lock, Left Shift or Fn it fires nothing, as Windows' `lalt.ahk` 4.1 (generator `HELD_SHIFT_ONE_SHOT_TAPS`, model test `lalt-one-shot-held-shift`).
- [ ] <!-- field-point: pair_press_order --> Pair first key by press order (2026-11-12): with CapsLock then Tab and Left Shift then Tab on distinct taps, the key held first decides which pair Tab runs, in both orders (generator `apply_pair_press_order`, its `ke_before_*` variables set through a to-event's own condition; model test `pair-first-key-press-order`).
- [ ] <!-- field-point: mrt004_service_repair --> **MRT-004 « Réparer le service »:** after the runtime rebuild that ships the repair role, unload the owned Core job (`sudo launchctl bootout system/com.ergoptiplus.runtime.core`), reload: the Tap-Holds menu says the service is stopped and offers « Réparer le service… »; confirm, enter the administrator password, and the answer is `service-repaired-observed`, the Core runs again from the adopted plist and the tap-holds work after the reload. Repeat with the VirtualHIDDevice job unloaded.
- [ ] <!-- field-point: developer_app_login_item --> **Start at login from the developer app (SAD-1, 2026-11-12):** in the
      developer app (ad hoc signed), tick About > Start at login: the row is checked, or « Allow Ergopti in the system
      startup settings » opens Login Items and the row is checked once allowed; log out and in: Ergopti starts from
      `build/macos/ErgoptiPlus.app`; untick it afterwards. A refusal of the ad hoc bundle by `SMAppService` is a
      failure to report (then the row greys on that build with a reason).

Check out `dev` (or the branch to test), set Debug > Log level > DEBUG, then run
`bash tools/dev/collect-macos-field-report.sh`: it creates `field/mac-<today>-<branch>`, runs the field checks in
the developer app, writes the report under `docs/field-reports/`, commits and pushes. Needs Go, the Xcode Command
Line Tools and python3 3.11.4 or newer; `swift test` needs full Xcode.app (install once from the App Store). Read a
red step with its `proves` line in `static/ergopti_plus/macos/data/field_run.json` and
[project-macos-field-run-step-details](docs/memory/macos-hammerspoon.md). Report each line as pass, fail or not run.

Field run, no person needed (read the next report):

- [ ] <!-- field-point: rerun_2026_11_02 --> Rerun of the 2026-11-02 report, without touching the Mac: no keystats rotation warning around midnight, no
      `event_taps` run-loop lateness with the main thread held over 1 s, `menu.rebuild` and its
      `menu_item.shortcuts` / `menu_keyboard_layout.sources` phases, `diagnostics` phase A under 5 ms, `idle_cost`
      below 8 %, and `granite4:350m-h` pulled with no `digest_mismatch`. A remaining one is a code entry with its
      report lines.
- [ ] <!-- field-point: two_copies_accessibility --> Two copies and one Accessibility switch: field report: `field_login_items` (each copy and whose it is) and `field_permissions` (`accessibility`, bundle identity), run once with a `build/macos` copy registered beside the `/Applications` prerelease: no `tccutil reset`, the dialog names `…/build/macos/ErgoptiPlus.app`, the boot resumes once that copy is trashed and the switch on.
- [ ] <!-- field-point: owned_install_launcher --> Owned runtime install through the launcher (after the next runtime rebuild): field report: `field_owned_install` then `owned_install_reload` (`files-published-services-observed-staging-retired`, no `helper_signature` or report refusal); the administrator prompt is its one human step.
- [ ] <!-- field-point: managed_ollama_0406 --> Managed Ollama 0.40.6 (rebuild with `tools/build/build-macos-managed-ollama.py` first): field report: `field_ai_local` behind a PAC-only or explicit proxy with no direct route, and `field_network_hosts` (the registry).
- [ ] <!-- field-point: physical_shortcut_delivery --> Physical shortcut delivery: `keyboard_shortcuts.physical_delivery_available` answers true since the maintainer's decision of 2026-11-11 (the « Pas encore disponible » row was closed on the macOS lane [run 42926643778](https://github.com/adrienm7/ergopti/actions/runs/42926643778) before that; `test_physical_shortcuts_row_available` now pins that a false answer still greys it so). Field report: with a physical slot bound in « Raccourcis physiques », the source key is suppressed once, no other owner (tap-hold, layer, hotstring, magic key) acts on it, and the action's output reaches the focused app under Karabiner and the keymap tap; the editor captures and saves the slot.
- [ ] <!-- field-point: taphold_word_reset --> Tap-hold word reset: with « Un tap ou un hold sur une touche tap-hold commence un nouveau mot » on and « Un raccourci clavier commence un nouveau mot » off, a tap-hold copy (Cmd+C tap) between two words makes the next word-start hotstring fire, the user's own Cmd+C does not, and no F20 reaches TextEdit or a Finder rename; switching the option off keeps the word. Karabiner-Elements must deliver the tagged F20 before the chord. Then with Caps Lock (or another tap-hold key) held as Ctrl or Cmd: a shortcut struck under it follows the same option, the user's own Cmd+C afterwards follows « Un raccourci clavier commence un nouveau mot », Ctrl held by hand before the key still reaches the tap (Ctrl+Enter), and no context-menu key reaches TextEdit or a Finder rename (Karabiner-Elements must deliver the untagged `application` key before the hold's modifier).
- [ ] <!-- field-point: ai_inline_autotype --> AI inline auto-type: the engine (typed without Tab, a correction with deletions stays in the bubble) is `test_prediction_inline_autotype`; the typing into a real editor with a model is field report: `prediction_tooltip` with « Inline auto-type » on.
- [ ] <!-- field-point: api_entries_backup --> Backup of the API entries: the backup and the restore are unit-tested (`test_config_backup_api_entries`, `test_changelog_release_install`). Decided by the maintainer on 2026-11-11: deleting an entry keeps deleting its Keychain item (`modules/llm/init.lua` `delete_entry_ids` → `retry_pending_api_token_deletes`), so an entry restored from a backup taken before that deletion needs its key re-entered. Field report: restore such a backup; the model selector page greys the entry with « Clé manquante : cette entrée est revenue d’une sauvegarde sans sa clé… » and its « Clé API… » action takes a new key, after which the entry answers (unit-tested by `test_api_token_absent_read`: the launcher's `itemNotFound` exit 69, the resolver's mark, the page row). An entry whose key survived still works unchanged.
- [ ] <!-- field-point: onboarding_number_row --> Onboarding number-row order: the offer, the greyed reason with a system layout and the live apply before the reload are `test_onboarding_number_row` and `test_number_row_live`; the symbols typed after the reload are field report: `field_layout_rows` (a layout build read back) plus one person typing the row.
- [ ] <!-- field-point: owned_ollama_pulls --> Owned Ollama starts and pulls: field report: `field_ai_local` (ready daemon) and `ollama_model` (a done pull) (6170813ea9, 6335790e5a, 894585a213, b71b4a67db, 4545f672d1, 721074f21d).
- [ ] <!-- field-point: test_models --> Test models: field report: `ollama_model` and `mlx_model` (one complete download each) on a connection that does not count (e8ff7479e1).
- [ ] <!-- field-point: timed_reload --> Timed reload: field report: `driver_reload` passes with its `reload_ms` under 4000 ms (b12a654d79, 02c58f8a94, c366dd1c5b, c0ba1d98bb, 8121349ee7, e6426e2ec5).
- [ ] <!-- field-point: remap_guardian --> Remap guardian: `field_login_items` `developer_adhoc_reregistered` on a Mac that holds an earlier build's
      Background Items record, no `ErgoptiPlus` codesigning kill in `field_app_health`, `guardian_state` ready with
      `guardian_wait` under 10 s, and the same on an Intel Mac (2be257c9f5). Hosted CI proves the ad hoc installed-app
      path on Apple silicon: registration, repeat registration (62eb698420), readback (34888894dd) and retirement pass
      in all five Install-and-launch rows (run 41257389239).
- [ ] <!-- field-point: main_thread_holds --> Main-thread holds (ledger L16, L17, L18, L23; 0b679b0b0d, b5c0c0de37, c17aa3e5d7, 71a8b87f65, 236ea82e52,
      933707a1ae, 016ef6adc5, 58f82e9fdc, 6c30779ec3): menu rebuild (`field_menu_build` `menu_layout_slowest`,
      `slow_hold_phase`), preferences save (`slow_preferences_save_stage`, `_forks`), keystats append and ledger read
      (`slow_ingest_*`, `worst_hold_site`), healthcheck and ignored-window probe (`slow_diagnostics_collector`,
      `slow_ignored_window_*`), one-off holds (`worst_hold_site`), `keystats_start_ms` under 100 ms. Each names the
      stage to bound next.
- [ ] <!-- field-point: l24_key_events --> L24 key events: field report: `field_lease` (`key_event_health` totals) once the holds are gone (82c220c089); key-ups lost without a hold point at the Karabiner virtual HID path.
- [ ] <!-- field-point: l32_memory --> L32 memory: field report: `field_app_health` (`memory_footprint_mb`, `memory_region_1..5`, `lua_heap_mb`) (cce99afbc7, 58961fd2b2, f7faaa0558).
- [ ] <!-- field-point: l42_off_company_network --> L42 off the company network: field report: `field_network` with `pac_download info:unreachable_direct`, `pac_script skip:not_fetched`, `route_lookup pass:selected:direct` (5d93e78e90, 1dfaec8298, ec15345d22, 8fedb505dd).
- [ ] <!-- field-point: l43_karabiner_signature --> L43: field report: `field_toolchain` `karabiner_signature` reads `info strict_only:finder_detritus` (cc172a504d, 58fd867081).
- [ ] <!-- field-point: item_116_toolchain --> 116: field report: `field_toolchain` (timer, Shortcuts, Homebrew, Karabiner signature, Gatekeeper).
- [ ] <!-- field-point: composer_l52 --> Composer (L52): field report: `field_composer` passes after a single re-read.
- [ ] <!-- field-point: keystats_cache --> Keystats cache: field report: `field_storage` `keystats_cache_place` is `caches`.
- [ ] <!-- field-point: lease_117_140 --> Karabiner lease 117/140: field report: `field_lease` `lease_failure_kinds` and `memory_free_percent` (25411ee080, 380ad99aa8); a low free percentage next to PONG/READY kinds confirms starvation.
- [ ] <!-- field-point: lease_deploy_write --> Lease deploy write: field report: `field_lease` `deploy_write_verdict` is `keep`; `shrink` means code to write (make the 743 KB file smaller).
- [ ] <!-- field-point: owned_karabiner_runtime --> Owned Karabiner runtime: field report: `field_owned_runtime`, then on an owned boot `field_owned_start` and `field_owned_pause`; the next run's `field_owned_start` proves close-on-resume.
- [ ] <!-- field-point: layout_rows --> Layout rows: field report: `field_layout_rows` answers M4 to M6 (91725b18f7, fc5d3a11df, aaf3518af7); a failed `rows_build` or `rows_replace` means the live path needs the design note's in-bundle route.
- [ ] <!-- field-point: apple_shortcuts --> Apple Shortcuts (106) and the actions `run_command`, `open_path`, `run_apple_shortcut`: field report: `field_apple_shortcuts` `field_test_run` (create once a no-op shortcut named `Ergopti Field Test` in Shortcuts).
- [ ] <!-- field-point: pac_unusable --> PAC unusable on a network whose PAC is unreachable: field report: `field_pac_fallback` `direct_worked` for an Ollama pull and the MLX install.
- [ ] <!-- field-point: ollama_real_pac --> Ollama behind a real PAC: field report: `field_ollama_blob_host` and `field_network` (the Debug > Test network chain).
- [ ] <!-- field-point: log_only_20261030 --> Log-only checks of the 2026-10-30 report: field report: `field_slow_lines` `log_shortcuts_still_unregistered` after a rebind retry (else rebinding needs the `hs.keycodes.map` notification), `log_keystats_database_locked` (8084562373), `log_lease_bound_failures` and `log_layout_change_before_baseline` (item 38).

Hands needed:

- [ ] <!-- field-point: layout_emulation --> Layout emulation (2026-11-06): with French (or ABC) selected as the input source, choose Keyboard layout >
      Layout to emulate > Ergopti➕ and type in TextEdit: letters, Shift, CapsLock, Option levels and the
      circumflex dead key (`^` then `e` gives ê) follow Ergopti➕; Cmd+Z undoes where Ergopti has z; a row switched
      off types French; a hotstring fires on emulated text. Check that a key the French layout makes dead (`^`)
      types its emulated character, that the cleared Option flag does not break an Option chord in Terminal, and
      note the password-field limit (Secure Event Input: the system layout types).
- [ ] <!-- field-point: hotstrings_asa --> Hotstrings (asa): the carrier types the whole `ASA` while the trigger's `a` is held (`test_text_carrier_avoids_held_key`); on the Mac: field report: `field_log_signals` `log_held_key_moves` after a person types `asa` + Space fast twenty times, also holding `a`, and `hotstring_roundtrip`; ordinary hotstrings in Edge, VS Code and a terminal stay hands.
- [ ] <!-- field-point: omlx_8181 --> oMLX on port 8181: field report: `field_local_servers` names it in API mode (`server_<id>` `up:...`), with no `ps` deadlock.
- [ ] <!-- field-point: l46_gestures --> L46 with no explicit `[gestures.sensitivities]` swipe_3 value (6d3aa65273): field report: `field_gesture_frames`, and `field_log_signals` `log_capture_stamp_errors` (no `has no capture timestamp` ERROR after a reload) and `log_three_finger_rejections` (`<n>:<gate>`). The swipes themselves (minutes of two-finger scrolls switch no tab; deliberate vertical three-finger swipes — slow, flick, staggered, after a scroll, finger resting, ten half a second apart — each switch exactly one tab, past 29 units two) stay hands.
- [ ] <!-- field-point: ctrl_capslock --> Ctrl+Caps Lock: field report: `field_capslock_chord` (`never_delivered` drops the slot's macOS recommendation with a reason, ea02cf7000), after a person types it once during the session.
- [ ] <!-- field-point: dropped_letters --> Dropped letters: field report: `field_lease` `swallowed_keys` and `key_accounting` after a day of typing in Safari, TextEdit, Terminal, VS Code and an Electron app; Debug > Report a bug right when a letter disappears.
- [ ] <!-- field-point: production_profile --> Production profile: field report: `field_boot_cost`, `field_idle_cost` and `field_slow_lines` after a working day, plus three cold starts and one after a login (`Boot complete in`, `Boot CPU`).
- [ ] <!-- field-point: refused_taps_rollbacks --> Event taps refused, personal hotstring reload rolled back, MLX POST routes 404 after a repair, screenshot without an image: field report: `field_event_taps`, `field_permissions` (`accessibility`) and `field_log_signals` `log_start_rollbacks` on the next occurrence.
- [ ] <!-- field-point: window_toggles --> Ten window-toggle actions bound to shortcuts: open, raise when covered and close when focused are `test_window_toggle` (all ten pages); on the Mac: field report: `field_log_signals` `log_window_toggle_errors` after `open_model_browser` right after a reload and with the AI off, and a person checks restore when minimised.
- [ ] <!-- field-point: menus --> Menus: Clear and Restore per category and global; Shortcuts group restore and clear; tap delay row and « Use
      global delay (…) »; tap and hold pickers; « Combinaisons de touches »; row order unchanged (PAR-76 R18);
      « Retirer les anciennes règles » on an upgrade (43); Login Items show one Ergopti (24).
- [ ] <!-- field-point: typing --> Typing: chained expansions, magic key on ISO and ANSI, undo by Backspace, password field, ignored app, no
      wrong erase count (PAR-76 R26); tap-hold rolls; Right Option + Return/Delete/Backspace/Escape; Backspace word
      start (Terminal, TextEdit, Safari Cmd+L); CapsWord cancelled by the pointer (44).
- [ ] <!-- field-point: ai_real_model --> AI with a real local model: request floor, explicit shortcut never held, variants, replace in flight, debounce
      "never", live mode; AI off disarms keys and agent actions (PAR-65); tooltip near edges on two displays (111).
- [ ] <!-- field-point: network_updates --> Network and updates: Debug > Test network on the office network and at home, an `http://` company PAC
      (Issue #101 fixes); release notes pane in light and dark (PAR-52); a Sparkle update; Homebrew live upgrade;
      MLX behind a proxy (119/130/136, code 74).
- [ ] <!-- field-point: pages_light_dark --> Pages in light and dark (PAR-81); onboarding wizard (7); App Cloner errors (4550befb08); trackpad gestures
      (126), Diagnostics focus (122), shared export (123); reload menu clicks held and replayed; quit while busy ends
      both processes in 10 s.
- [ ] <!-- field-point: issue_100_99 --> Issue #100 (2353a72eed, 25411ee080, e57f4cce77): with Ollama.app and a PAC proxy, enabling the AI downloads
      the model; the menu held open causes no lease timeout. Issue #99: `memory_pressure` during lease errors, which
      login item starts a second Hammerspoon, declining the download opens no error window.
- [ ] <!-- field-point: installed_app --> Installed app: guardian registration and retirement on both architectures (13/35), VS Code bridge retirement
      (127), 120 provider menu, issue 94 (tap-hold refusal, symbol-wrap clipboard).
- [ ] <!-- field-point: app_cloner --> App Cloner (81b3cda6a8): on a Mac without the Command Line Tools, Apps > App Cloner offers the install and
      "Install" finishes with no Xcode prompt; clone one app and one PWA, both launch; the PWA launcher shows
      `exec "$CLONE_PYTHON"` on the versionless link; double-clicking App Cloner in Finder shows the localized refusal.
- [ ] <!-- field-point: vhid_offer --> VirtualHIDDevice offer (3ebab93a17): on a Mac whose active driver is older than 8.5.0, Tap-holds > update row,
      admin prompt, installer, forceActivate; the report names the new version and the remap reloads; cancelling the
      prompt reports `cancelled` and changes nothing.
- [ ] <!-- field-point: scpt_recompile --> Run the field report once: field report: `scpt_recompile` rebuilds `Encryptor.app/.../main.scpt` from its updated `.applescript` (keystats rename) and commits it on the field branch (710f0a379d); cherry-pick that commit.
- [ ] <!-- field-point: predictions_stop --> Predictions stop on activity: the cancellations (pointer, scroll, gestures, a key the tooltip did not consume) and Tab, Shift+Tab, arrows and digits acting on it are `test_mouse_tap_pointer_activity`, `test_prediction_cancelled_by_user_activity` and `test_llm_tooltip_chords_consumed`; on the Mac: field report: `field_log_signals` `log_prediction_activity_cancels` (one `User activity (mouseMoved)` per cancellation, at DEBUG). A person still checks Cmd+Tab, a click in another app, F5 and that mouseMoved in the keymap mouse tap adds no visible pointer lag.
- [ ] <!-- field-point: input_policies --> Branch `wave3/input-policies` (2026-11-06): CapsWord closed on the macOS lane [run 42926643778](https://github.com/adrienm7/ergopti/actions/runs/42926643778) (`test_watchers_capsword_auto_off` « a second CapsWord action ends it at once and unlocks CapsLock », `test_karabiner_actions_reachable`, `test_menu_caps_word` « ★ » after the rename). Native one-shot Shift (modifier-map, dead-key and IME handling of the captured key) and CapsWord key/control payload receiving stay hands (moved from the one-shot and CapsWord parity follow-ups).
