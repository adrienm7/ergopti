# Windows Suspend gates: inventory for the real pause

Audited source: `claude/ergopti-todo-parity-b`, on `dev`.
Date: November 12, 2026.

The maintainer's real pause (EDD-1, `docs/memory/maintainer-decisions.md`)
keeps configuration and installs available under Suspend and keeps typing
inert. This lists every executable `A_IsSuspended` read in `windows/**`
outside the tests, by file and line, so the Windows change can be made in one
pass with a Windows runtime. No AHK file was changed here: this session had no
AutoHotkey to run, and the gates reach the configuration writers, not only the
page handlers.

The classes are a first reading by file, not a verdict per line. Each A to C
entry names the unit suite that already loads the file (preferring one that
exercises Suspend), where its « a suspended save writes » regression goes:

- **A, B**: page handlers, editors, configuration writers and installs. Their
  gates are to remove, each with a regression that a suspended save writes.
- **C**: menu rows, the tray's feature greying (`TrayMenu_ApplyPauseGreying`,
  `menu_init.ahk`'s `greyed_when_paused` filter) and the tray root rebuild,
  which is refused while suspended (`menu_rebuild.ahk`, `infra/lifecycle.ahk`).
  Ungreying alone would leave a submenu stale after a change made while
  suspended, so the rebuild must be allowed under Suspend first; then
  `greyed_when_paused` leaves `menu.toml`, its last reader gone.
- **D**: updates and diagnostics keep their own rules.
- **E**: typing and input runtime. These gates stay; each file is still to be
  read once, since a configuration page (for example the metrics page in
  `keystats_webview.ahk`) may sit among them.

### A page or editor (65 sites in 15 files)

- `windows/ui/action_picker/init.ahk`: 220 — candidate suite: `tests/unit/ui/windows/test_native_picker_retirement.ahk`
- `windows/ui/action_picker_webview.ahk`: 421, 475, 500, 517, 883, 888, 896 — candidate suite: none yet, add one beside the file
- `windows/ui/download_window/init.ahk`: 143, 539, 677 — candidate suite: `tests/unit/ui/windows/test_native_picker_retirement.ahk`
- `windows/ui/editors.ahk`: 28, 60, 66, 71, 97, 270, 298, 304, 307, 336 — candidate suite: `tests/unit/modules/hotstrings/magic_key/test_magic_key_source_menu.ahk`
- `windows/ui/hotstrings_config_window/webview.ahk`: 289, 338 — candidate suite: `tests/unit/ui/webview/test_webview_range_mount.ahk`, `tests/unit/ui/webview/test_webview_range_outcomes.ahk`
- `windows/ui/layer_editor/init.ahk`: 144, 151, 581, 586, 666, 669, 695 — candidate suite: `tests/unit/ui/windows/test_native_picker_retirement.ahk`
- `windows/ui/layout_manager/init.ahk`: 385, 990 — candidate suite: `tests/unit/ui/windows/test_native_picker_retirement.ahk`
- `windows/ui/model_browser/init.ahk`: 426, 502, 548, 562, 1076, 1266, 1505, 1571, 1679 — candidate suite: `tests/unit/ui/windows/test_native_picker_retirement.ahk`
- `windows/ui/onboarding/gesture_registration.ahk`: 157 — candidate suite: none yet, add one beside the file
- `windows/ui/onboarding/webview.ahk`: 303, 530, 540, 636, 674, 686, 701 — candidate suite: `tests/unit/ui/webview/test_webview_range_mount.ahk`, `tests/unit/ui/webview/test_webview_range_outcomes.ahk`
- `windows/ui/paths_editor/init.ahk`: 240, 290, 296, 320, 329, 378 — candidate suite: `tests/unit/ui/windows/test_native_picker_retirement.ahk`
- `windows/ui/personal_info_editor/init.ahk`: 238 — candidate suite: `tests/unit/ui/windows/test_native_picker_retirement.ahk`
- `windows/ui/personal_toml_editor_webview.ahk`: 280, 422, 443, 467, 506 — candidate suite: none yet, add one beside the file
- `windows/ui/physical_shortcuts/host.ahk`: 485 — candidate suite: `tests/unit/ui/webview/test_ui_warm_hosts.ahk`
- `windows/ui/prompt_editor/init.ahk`: 474, 547, 608 — candidate suite: `tests/unit/ui/windows/test_native_picker_retirement.ahk`

### B configuration writer or install (43 sites in 14 files)

- `windows/infra/config_io.ahk`: 2337 — candidate suite: `tests/unit/ui/webview/test_model_browser_close_pause_owner.ahk`, `tests/unit/infra/config/persistence/test_feature_state_boot.ahk`
- `windows/infra/hotstrings/hotstrings_scope.ahk`: 231 — candidate suite: `tests/unit/suite/test_runner_shard.ahk`, `tests/unit/infra/config/scope/test_hotstrings_scope.ahk`
- `windows/infra/hotstrings/personal_toml_io.ahk`: 268, 1486, 1529, 1719, 2018, 2254 — candidate suite: `tests/unit/modules/hotstrings/personal/test_personal_toml_io.ahk`, `tests/unit/modules/hotstrings/engine/test_marker_substituted_in_replacement.ahk`
- `windows/infra/key_combinations.ahk`: 1258, 1271, 1292, 1330 — candidate suite: `tests/unit/modules/shortcuts/test_shortcuts.ahk`
- `windows/infra/magic_editor.ahk`: 232, 396 — candidate suite: `tests/unit/modules/keymap/test_layout_rows_policy.ahk`, `tests/unit/modules/hotstrings/magic_key/test_magic_editor.ahk`
- `windows/infra/menu_startup_commands.ahk`: 222, 230 — candidate suite: `tests/unit/ui/menu/test_menu_startup_commands.ahk`
- `windows/infra/wrap_symbols_config.ahk`: 448, 555, 814 — candidate suite: none yet, add one beside the file
- `windows/modules/gestures/config.ahk`: 777, 785, 795, 804, 815, 823, 1073, 1238 — candidate suite: `tests/unit/ui/wpm/test_wpm_config_types.ahk`, `tests/unit/modules/hotstrings/catalogue/test_hotstrings_config.ahk`
- `windows/modules/keymap/pause_layout_switch.ahk`: 184 — candidate suite: `tests/unit/modules/keymap/test_pause_layout_switch.ahk`
- `windows/modules/keymap/system_layout_install.ahk`: 198 — candidate suite: `tests/unit/modules/keymap/test_system_layout_install.ahk`
- `windows/modules/keystats/keystats_apps_editor.ahk`: 24, 131 — candidate suite: none yet, add one beside the file
- `windows/modules/llm/local_model_offer.ahk`: 50 — candidate suite: none yet, add one beside the file
- `windows/modules/llm/ollama_install_files_port.ahk`: 74, 295, 299 — candidate suite: `tests/unit/modules/llm/servers/test_ollama_install_files_port.ahk`
- `windows/modules/llm/ollama_managed_bootstrap.ahk`: 476, 843, 892, 1230, 1242, 1252, 1255, 1269 — candidate suite: `tests/unit/modules/llm/servers/test_ollama_managed_bootstrap.ahk`

### C menu row, tray greying or rebuild (118 sites in 20 files)

- `windows/infra/lifecycle.ahk`: 57, 117, 192, 205, 258, 261, 263, 264, 265, 272, 403, 436, 442, 448, 476, 837, 863, 864, 885, 1266, 1718, 1743, 1756 — candidate suite: `tests/unit/modules/shortcuts/test_shortcuts.ahk`, `tests/unit/ui/menu/test_menu_startup_commands.ahk`
- `windows/infra/menu_population.ahk`: 286, 306, 402 — candidate suite: `tests/unit/ui/menu/test_menu_population.ahk`
- `windows/ui/menu/menu_engine.ahk`: 481 — candidate suite: `tests/unit/modules/keymap/test_layout_supersession.ahk`, `tests/unit/infra/config/persistence/test_master_gates.ahk`
- `windows/ui/menu/menu_hotstring_order.ahk`: 126, 150, 167, 168, 177 — candidate suite: none yet, add one beside the file
- `windows/ui/menu/menu_hotstrings.ahk`: 460, 466, 480, 614, 647, 952, 1576, 1621, 1629, 1639, 1656 — candidate suite: `tests/unit/modules/hotstrings/catalogue/test_hotstring_delimiter_global_transaction.ahk`
- `windows/ui/menu/menu_init.ahk`: 488 — candidate suite: none yet, add one beside the file
- `windows/ui/menu/menu_layout.ahk`: 246 — candidate suite: none yet, add one beside the file
- `windows/ui/menu/menu_llm/actions.ahk`: 387, 451, 623, 644, 725 — candidate suite: `tests/unit/infra/lifecycle/test_quit_admission.ahk`, `tests/unit/modules/gestures/test_system_actions.ahk`
- `windows/ui/menu/menu_llm/aux_ownership.ahk`: 26, 77, 103, 224 — candidate suite: none yet, add one beside the file
- `windows/ui/menu/menu_llm/backend_lifecycle.ahk`: 194, 227, 249, 293 — candidate suite: `tests/unit/modules/llm/api/test_llm_backend_lifecycle_dispatch.ahk`
- `windows/ui/menu/menu_llm/enable_admission.ahk`: 22 — candidate suite: `tests/unit/modules/llm/api/test_llm_enable_admission.ahk`
- `windows/ui/menu/menu_llm/init.ahk`: 168, 176, 235, 252 — candidate suite: `tests/unit/ui/windows/test_native_picker_retirement.ahk`
- `windows/ui/menu/menu_llm/local_server_panel.ahk`: 102, 257, 273, 412, 433, 503, 552, 606, 631, 648, 722, 743, 806, 831, 868, 890 — candidate suite: `tests/unit/modules/llm/servers/test_local_server_panel.ahk`, `tests/unit/modules/llm/servers/test_local_server_panel_discovery.ahk`
- `windows/ui/menu/menu_llm/menu_api_entries.ahk`: 469, 547, 1057, 1569, 1599, 2051, 2340 — candidate suite: none yet, add one beside the file
- `windows/ui/menu/menu_llm/menu_main.ahk`: 37, 93, 147, 258, 259, 620, 621 — candidate suite: `tests/unit/modules/llm/menu/test_llm_menu_build_submenu.ahk`
- `windows/ui/menu/menu_llm/menu_models.ahk`: 235, 270, 273 — candidate suite: `tests/unit/modules/llm/menu/test_llm_menu_regressions.ahk`, `tests/unit/modules/llm/menu/test_llm_menu_backend_model_labels.ahk`
- `windows/ui/menu/menu_llm/menu_profiles.ahk`: 158, 896, 910, 974, 988, 1003, 1012 — candidate suite: `tests/unit/modules/llm/menu/test_llm_menu_profiles.ahk`, `tests/unit/modules/llm/menu/test_llm_menu_regressions.ahk`
- `windows/ui/menu/menu_llm/menu_settings.ahk`: 121, 129, 428, 474, 528, 555, 986, 1023, 1067, 1145, 1202 — candidate suite: `tests/unit/modules/llm/menu/test_llm_menu_regressions.ahk`, `tests/unit/modules/llm/menu/test_llm_menu_prediction_count.ahk`
- `windows/ui/menu/menu_rebuild.ahk`: 149, 260, 403 — candidate suite: `tests/unit/modules/llm/menu/test_llm_menu_build_submenu.ahk`
- `windows/ui/tray_menu.ahk`: 27 — candidate suite: `tests/unit/infra/config/scope/test_hotstring_dynamic_menu_scope.ahk`

### D own rules (updates, diagnostics) (44 sites in 10 files)

- `windows/modules/updater/changelog.ahk`: 75, 301, 347, 378, 411, 458, 631
- `windows/modules/updater/core.ahk`: 1134, 1545, 1857, 1946, 2017, 2057, 2082, 2114, 2297, 2312, 2327, 2371, 2395, 2406, 2523
- `windows/modules/updater/self_update.ahk`: 555, 628, 1255, 1346, 1460, 1495, 1534, 2119, 2247, 2522, 2790, 3540, 3699
- `windows/ui/changelog/init.ahk`: 110
- `windows/ui/error_dialog/init.ahk`: 692
- `windows/ui/field_check/network_check.ahk`: 422
- `windows/ui/healthcheck/collection.ahk`: 147
- `windows/ui/healthcheck/core.ahk`: 1054, 1412
- `windows/ui/healthcheck/helpers.ahk`: 290
- `windows/ui/update_check/init.ahk`: 742, 859

### E typing or input runtime (keeps its gate) (528 sites in 90 files)

- `windows/ErgoptiPlus.ahk`: 1550, 1620, 1623, 1639, 1642, 1795
- `windows/adapters/crash_report_worker.ahk`: 302
- `windows/adapters/editor_replace.ahk`: 129, 130, 160, 162
- `windows/adapters/http_client.ahk`: 427, 441, 1620, 1662, 1710
- `windows/adapters/keyboard_hook.ahk`: 242
- `windows/adapters/llm_automation.ahk`: 37, 47
- `windows/adapters/llm_nav_event_owner.ahk`: 176, 217, 258, 539, 579, 646, 736, 908, 920, 994, 1019, 1070, 1109, 1127, 1132, 1166, 1422, 1614, 1727, 1858, 1917, 1960, 2004, 2061, 2091, 2271
- `windows/adapters/network_failure_host.ahk`: 53
- `windows/adapters/process_lifecycle.ahk`: 445
- `windows/adapters/screen_brightness.ahk`: 49, 76, 142, 173
- `windows/adapters/secure_field_detector.ahk`: 495, 532
- `windows/adapters/shell_runner.ahk`: 942, 2680, 2697, 2848, 2878
- `windows/adapters/text_sender.ahk`: 573, 625
- `windows/adapters/timer_scheduler.ahk`: 423, 470
- `windows/infra/capsword_state.ahk`: 147
- `windows/infra/hook_dispatcher.ahk`: 240
- `windows/infra/hotstrings/hotstring_dispatch.ahk`: 164, 705, 1745
- `windows/infra/hotstrings/hotstring_inputhook.ahk`: 589, 618, 628, 632, 716, 866, 1062, 1465, 1506, 1556, 1790, 1924, 2473
- `windows/infra/hotstrings/hotstring_send.ahk`: 507, 509, 812, 833, 967, 982, 1022, 1149, 1172
- `windows/infra/hotstrings/terminator_records.ahk`: 470, 516
- `windows/infra/input_probe.ahk`: 285, 315, 325, 328, 333, 337, 393, 400, 406, 496, 883, 889
- `windows/infra/metrics/metrics_filters.ahk`: 527, 539, 610, 782, 799
- `windows/infra/nav_layer_helpers.ahk`: 47, 57, 128, 162, 196
- `windows/infra/program_actions.ahk`: 44, 65, 91
- `windows/infra/sticky_modifiers.ahk`: 49, 76
- `windows/infra/suppressive_inputhook_ownership.ahk`: 32, 302, 308
- `windows/infra/user_actions.ahk`: 290
- `windows/infra/webview_utils.ahk`: 641, 666, 678, 704, 724, 766, 780, 797, 807, 887
- `windows/modules/dynamic_hotstrings/user_code.ahk`: 390
- `windows/modules/gestures/actions.ahk`: 697, 701, 710, 755
- `windows/modules/gestures/click.ahk`: 56, 249, 284
- `windows/modules/gestures/raw_touchpad.ahk`: 477
- `windows/modules/gestures/screenshots.ahk`: 643, 674, 718, 736, 745, 747, 764, 792, 921, 1010, 1016, 1049, 1105, 1121, 1174, 1176, 1192
- `windows/modules/gestures/system_actions.ahk`: 115, 161, 214, 235, 256, 294, 332, 385, 400, 479, 532, 539, 550, 555, 657, 664, 684, 708, 715, 723, 745, 768, 775, 790, 807
- `windows/modules/gestures/virtual_desktops.ahk`: 173, 182, 201
- `windows/modules/gestures/window_cycle.ahk`: 105, 332, 388
- `windows/modules/keymap/keylayout/keylayout_emulation.ahk`: 1899, 1989
- `windows/modules/keymap/layout.ahk`: 47, 88, 402, 478, 724
- `windows/modules/keymap/layout/layout_altgr.ahk`: 218, 278
- `windows/modules/keymap/layout_poll_helper.ahk`: 150, 191, 196, 203, 208, 221
- `windows/modules/keymap/llm_bridge.ahk`: 109, 178, 443, 873, 1127, 1269, 1283, 1349, 1388, 1476, 1493, 1723, 1743, 1900, 1907, 1982, 1996, 2427
- `windows/modules/keymap/uia_selection_worker.ahk`: 379, 396, 450, 560
- `windows/modules/keystats/keystats.ahk`: 505, 600, 997
- `windows/modules/keystats/keystats_app_categories.ahk`: 482
- `windows/modules/keystats/keystats_av_state.ahk`: 119, 205
- `windows/modules/keystats/keystats_clipboard.ahk`: 160, 198, 302
- `windows/modules/keystats/keystats_collection.ahk`: 54
- `windows/modules/keystats/keystats_hook.ahk`: 1002, 1024
- `windows/modules/keystats/keystats_hotstring_log.ahk`: 78, 104, 145
- `windows/modules/keystats/keystats_ingest.ahk`: 137, 151
- `windows/modules/keystats/keystats_llm_journal.ahk`: 46, 126
- `windows/modules/keystats/keystats_network.ahk`: 187, 242, 282
- `windows/modules/keystats/keystats_password.ahk`: 406, 447
- `windows/modules/keystats/keystats_prefetch.ahk`: 399, 442, 492, 494, 495, 626, 630, 856, 882, 886
- `windows/modules/keystats/keystats_rollover.ahk`: 159, 169
- `windows/modules/keystats/keystats_system_events.ahk`: 30, 72
- `windows/modules/keystats/keystats_text_migration.ahk`: 567, 578, 736, 871, 931, 979, 1008, 1035
- `windows/modules/keystats/keystats_trigger_roi.ahk`: 165, 174, 399
- `windows/modules/keystats/keystats_watchers.ahk`: 404, 421, 561, 578, 703
- `windows/modules/keystats/keystats_webview.ahk`: 656, 698, 813, 840, 854, 944, 968, 1263, 1335, 1353, 1376, 1378, 1415, 1572, 1619, 1634, 1635, 1715, 1717, 1727, 1743, 1861, 1987, 2060, 2106, 2163, 2215, 2223, 2234
- `windows/modules/keystats/keystats_window_topology.ahk`: 141
- `windows/modules/llm/agent_action.ahk`: 377, 394, 435, 534, 578, 633, 635, 719, 731, 806, 986, 1048
- `windows/modules/llm/api_ollama/ollama_streaming.ahk`: 241, 297, 373, 376, 409, 449, 478, 866, 879, 906, 942
- `windows/modules/llm/api_ollama/ollama_warmup.ahk`: 208, 243
- `windows/modules/llm/api_remote.ahk`: 952, 958, 965, 1007, 1792, 1804, 1825, 1844
- `windows/modules/llm/api_token_exchange.ahk`: 509, 600
- `windows/modules/llm/local_server_models.ahk`: 61, 76, 87, 97, 109, 114, 120, 182, 235, 242, 250, 256, 258, 265, 278, 282
- `windows/modules/llm/local_servers.ahk`: 170, 216, 297, 323, 373, 406, 476, 489, 511, 546, 695, 765, 860, 1077, 1100, 1165, 1205
- `windows/modules/llm/ollama_runtime_owner.ahk`: 95, 205, 209, 305, 434
- `windows/modules/llm/ollama_webview.ahk`: 489, 523, 535, 620, 639, 668, 674, 681, 685
- `windows/modules/llm/prediction_exec.ahk`: 290, 1215, 1505
- `windows/modules/llm/tone_action.ahk`: 156, 279, 291, 367
- `windows/modules/llm/translate_action.ahk`: 80, 249
- `windows/modules/llm/vision_action.ahk`: 171, 365, 558, 740, 785
- `windows/modules/shortcuts/capsword_auto_off.ahk`: 610, 630
- `windows/modules/shortcuts/win.ahk`: 40, 72, 87, 152, 161, 174, 186, 224, 430, 432, 490
- `windows/modules/take_note.ahk`: 68, 311, 329, 351, 395, 468, 475
- `windows/platform/remap/constants.ahk`: 521, 618, 684, 744, 749, 757, 906, 949, 971, 1131, 1498, 1506, 1529, 1536, 1544, 1749, 1770, 1806, 1834, 1840, 2083
- `windows/platform/remap/lalt.ahk`: 102, 205, 209, 212, 216, 370, 379, 387, 396, 405, 408, 411, 419, 422, 425, 430, 435, 443, 448
- `windows/platform/remap/one_shot_shift.ahk`: 26, 33, 53, 70, 77, 98, 108, 113
- `windows/platform/remap/rctrl.ahk`: 70, 75, 78, 81, 85, 89, 92, 96, 264, 268, 271, 274, 278
- `windows/platform/remap/tab.ahk`: 95
- `windows/platform/remap/tap_hold_roll.ahk`: 200, 209, 214, 269, 302, 317, 330, 337, 352, 390, 402
- `windows/ui/spotlight/init.ahk`: 119, 142
- `windows/ui/tooltip/core.ahk`: 203, 232, 288, 324, 527, 556, 602, 606
- `windows/ui/tooltip/helpers.ahk`: 1740
- `windows/ui/tooltip/llm.ahk`: 177, 300, 347, 394, 433, 567, 591
- `windows/ui/tooltip/position_refinement.ahk`: 185, 326
- `windows/ui/wpm/wpm_display.ahk`: 264, 279, 530, 691, 702, 708, 727, 862
- `windows/ui/wpm/wpm_tray_readout.ahk`: 256
