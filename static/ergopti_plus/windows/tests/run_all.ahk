; static/ergopti_plus/windows/tests/run_all.ahk

; ==============================================================================
; MODULE: Test Runner Entry Point
; DESCRIPTION:
; Single ``AutoHotkey.exe`` entry point for the ErgoptiPlus AHK test suite.
; Loads the framework, the stubs, every production lib and every per-module
; test file in dependency order, then calls ``RunTests`` to execute all
; registered ``Test`` cases. Exits with code 0 on full pass, 1 on any failure
; — the contract the GitHub Actions workflow relies on to fail the CI build.
;
; FEATURES & RATIONALE:
; 1. The runner #Includes the production ``lib/`` files directly. This means
;    a refactor in a lib file is immediately exercised by the corresponding
;    test_*.ahk file with no per-test glue to maintain.
; 2. ``modules/`` files are deliberately NOT included — they register hotkeys
;    at top level and would prevent the runner from exiting cleanly. The
;    behaviour exposed by modules (layer / shortcuts / hotstrings) is tested
;    through the lib/ helpers it shares with production.
; 3. AHK v2 directives at the top mirror those in ErgoptiPlus.ahk so that
;    parser quirks (#Warn VarUnset, encoding) are identical between test
;    runs and production startup.
; ==============================================================================

#Requires Autohotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn All, StdOut
#Warn VarUnset, Off
; Parse runner flags:
;   --dry-run        parse/load gate only — register every test, skip execution.
;   --only <substr>  run only tests whose name contains <substr> (case-insensitive),
;                    e.g. AutoHotkey64.exe run_all.ahk --only "(my-slug)" to replay
;                    a single failing test without the whole suite.
global _AHK_DRY_RUN := false
global _AHK_ONLY_FILTER := ""
_riArgIndex := 1
while (_riArgIndex <= A_Args.Length) {
	_riArg := A_Args[_riArgIndex]
	if (_riArg == "--dry-run")
		_AHK_DRY_RUN := true
	else if (_riArg == "--only" && _riArgIndex < A_Args.Length) {
		_riArgIndex += 1
		_AHK_ONLY_FILTER := A_Args[_riArgIndex]
	} else if (SubStr(_riArg, 1, 7) == "--only=")
		_AHK_ONLY_FILTER := SubStr(_riArg, 8)
	_riArgIndex += 1
}

; Test framework first — Assert / Test / RunTests must exist before any
; subsequent file registers its cases or invokes assertions inside lambdas.
#Include test_framework.ahk

; AppState — must come before test_stubs.ahk because the stubs reference
; AppState fields directly, and before any lib/ file that reads AppState.
#Include ../lib/app_state.ahk

; Stubs second — they define ScriptInformation, Features, SendNewResult,
; WrapTextIfSelected, DeadKey, ToggleCapsLock, etc., which lib/ files
; reference at definition (Bind) time or at call time during tests.
#Include test_stubs.ahk

; Install a very early error handler for top-level / #Include phase errors.
; When a newly added production module (LLM, gestures, keylogger, prompt builder,
; tray_llm persist, etc.) or test_*.ahk has a top-level statement that throws
; (unset global, t() before i18n is ready, missing stub for a static initializer,
; bad include order, etc.) the default AHK behaviour is to show a modal error
; MsgBox. In the headless CI runner that dialog is never dismissed → the exe
; never exits → the step times out even if the previous green run was ~10 s.
; This handler writes a clear "not ok 0" line to the exact file the CI tailer
; watches and forces a clean ExitApp so the failure is visible and fast.
_FatalErrorHandler(e, mode) {
    msg := "not ok 0 - FATAL STARTUP ERROR: " . e.Message
    try 	msg .= "`r`nSTACK TRACE:`r`n" . e.Stack
	msg .= "`r`nLikely cause: top-level code or missing stub in a newly added module."
	try FileAppend(msg . "`r`n", A_Temp . "\ergopti_test_results.txt", "UTF-8")
	try FileAppend(msg . "`r`n", "*")
    ExitApp(1)
    return 1
}
OnError(_FatalErrorHandler)

; ── Production lib files in dependency order ──
#Include ../lib/app_state.ahk
#Include ../lib/ui_style.ahk
#Include ../lib/logger.ahk
#Include ../lib/toml/toml_helpers.ahk
; Shared timing registry reader (TimingsLoadShared / TimingsGet) — needs
; ParseTomlFile above; exercised by test_timings_config.ahk.
#Include ../lib/timings/timings_config.ahk

#Include ../lib/window_utils.ahk
#Include ../lib/string_utils.ahk
#Include ../lib/nav_layer_helpers.ahk
#Include ../lib/hotstrings/hotstring_engine.ahk
#Include ../lib/hotstrings/hotstring_engine_main.ahk
#Include ../lib/hotstrings/hotstring_live_toggle.ahk
#Include ../lib/hotstrings/hotstring_prefix_watcher.ahk
#Include ../lib/master_gates.ahk
; Generated terminator catalogue (shared single source) — exercised by
; test_terminators.ahk and consumed by the tray / config-window delimiter menus.
#Include ../_generated/terminators.ahk
#Include ../lib/toml/toml_loader.ahk
#Include ../lib/hotstrings/hotstrings_cache.ahk
#Include ../lib/toml/toml_config_loader.ahk
#Include ../lib/tap_hold/tap_hold_loader.ahk
#Include ../_generated/features_manifest.ahk
#Include ../lib/manifest_reader.ahk
#Include ../lib/hotstrings/hotstrings_config.ahk
#Include ../ui/personal_toml_editor.ahk
#Include ../lib/layout/layout_altgr.ahk
#Include ../lib/layout/layout_shift_caps.ahk
; Pure layout-poll quiescence decision (no OS deps, no top-level hotkeys) —
; exercised by meta/test_layout_quiescence.ahk and consumed by ErgoptiPlus.ahk.
#Include ../lib/layout_poll_helper.ahk
#Include ../ui/tooltip/init.ahk
#Include ../lib/updater.ahk
; json.ahk must precede i18n.ahk — _I18nLoadFile now delegates to JsonParse.
#Include ../lib/registry.ahk
#Include ../lib/json.ahk
; i18n is included here because gestures.ahk calls t() at the top level
; when building GESTURE_SLOT_LABELS; without this the process blocks on
; an AHK runtime-error MsgBox and the CI job times out.
#Include ../lib/i18n.ahk
try FileAppend("# [marker] i18n included (t() should now be available)`r`n", A_Temp . "\ergopti_test_results.txt", "UTF-8")
try FileAppend("# [marker] i18n included (t() should now be available)`r`n", "*")

; Install the hotstring hooks for the entire test process so neither real
; ``Hotstring()`` registrations nor real ``SendEvent`` keystrokes ever escape
; into the CI environment. Stubs that need raw send semantics still observe
; UpdateLastSentCharacter (the hook only intercepts the lower-level emission).
InstallHotstringHooks()

; ── Adapter contract: include all port adapters so contract vector tests can call them ──
#Include ../adapters/notifier.ahk
#Include ../adapters/timer_scheduler.ahk
#Include ../adapters/file_system.ahk
#Include ../adapters/window_info.ahk
#Include ../adapters/tray_menu.ahk
#Include ../adapters/text_sender.ahk
#Include ../adapters/http_client.ahk
#Include ../adapters/secure_field_detector.ahk
#Include ../adapters/clipboard.ahk
#Include ../adapters/storage.ahk
#Include ../adapters/process_lifecycle.ahk
#Include ../adapters/key_state.ahk
#Include ../adapters/app_launcher.ahk
#Include ../adapters/crypto.ahk
#Include ../adapters/network_info.ahk
#Include ../adapters/window_manager.ahk
; Unified input-hook dispatcher + keyboard_hook adapter. hook_dispatcher.ahk
; defines only classes at top level (no hotkeys), so it is safe in the headless
; runner; keyboard_hook.ahk registers/unregisters its subscribers through it.
; Exercised by test_hook_dispatcher.ahk (BoundFunc identity + bind-once contract).
#Include ../lib/hook_dispatcher.ahk
#Include ../adapters/keyboard_hook.ahk

; Lock _AHK_SendText / _AHK_SendInput to no-ops AFTER the adapter has been
; included (the adapter sets them to real lambdas; InstallSendNoOps overwrites
; them so no keystroke can escape into the OS during test execution).
InstallSendNoOps()

; ── Per-module test files (each registers Test() cases) ──
#Include test_adapter_compliance_new.ahk
#Include test_adapter_contract_vectors.ahk
#Include test_text_sender_modifiers.ahk
#Include test_timer_scheduler.ahk
#Include test_hook_dispatcher.ahk
#Include test_logger.ahk
#Include test_logger_contract.ahk
#Include test_tooltip_tint_contract.ahk
#Include test_tooltip_border_alpha.ahk
#Include test_tooltip_dequeue_regression.ahk
#Include test_llm_tooltip_grace.ahk
#Include test_llm_tooltip_render.ahk
#Include test_hotstring_engine.ahk
#Include test_hotstring_engine_main.ahk
#Include test_suppress_refcount.ahk
#Include test_hotstring_live_toggle.ahk
#Include test_prefix_watcher_index.ahk
#Include test_master_gates.ahk
#Include test_domain_registry.ahk
#Include test_domain_expander.ahk
#Include test_toml_loader.ahk
#Include test_toml_helpers_roundtrip.ahk
#Include test_hotstrings_cache.ahk
#Include test_hotstrings_config.ahk
#Include test_terminators.ahk
#Include test_personal_toml_editor.ahk
#Include test_layout_tables.ahk

#Include test_config.ahk
#Include test_features_manifest.ahk
#Include test_hotstrings_full.ahk
#Include test_tap_hold_loader.ahk
#Include test_i18n.ahk
#Include test_window_utils.ahk
#Include test_string_utils.ahk
#Include test_registry.ahk
#Include test_nav_layer_helpers.ahk
#Include test_updater.ahk
#Include meta/test_updater_load_interval_guard.ahk

; Shortcuts modules — dispatcher logic is testable without real hotkeys firing;
; the module files are #Include'd from within test_shortcuts.ahk itself so the
; include paths are resolved relative to the tests/ directory.
#Include test_shortcuts.ahk

; Metrics shortcuts — MS_ToAhkSyntax is pure logic (no OS calls, no hotkeys
; registered at top level) so the file is safe to include in the headless runner.
#Include ../lib/metrics/metrics_shortcuts.ahk
#Include test_metrics_shortcut_named_key.ahk

; LLM modules — pure-logic subset (profiles, models, api_common, api_ollama,
; api_remote, prediction_engine) included here to test JSON parsing, profile
; lookup, payload building, response parsing, cancel helpers, and engine
; debounce / cache logic without any real network calls.
; models.ahk defines LLM_GetSharedPath which profiles.ahk depends on.
try FileAppend("# [marker] starting direct include of LLM production modules`r`n", A_Temp . "\ergopti_test_results.txt", "UTF-8")
try FileAppend("# [marker] starting direct include of LLM production modules`r`n", "*")
#Include ../modules/llm/models.ahk
#Include ../lib/llm_defaults.ahk
#Include ../modules/llm/profiles.ahk
#Include test_llm_profiles.ahk
#Include ../modules/llm/api_common.ahk
#Include test_llm_api_common.ahk
#Include ../modules/llm/api_ollama.ahk
#Include ../modules/llm/api_remote.ahk
#Include test_llm_api_ollama.ahk
#Include test_llm_api_remote.ahk
#Include ../modules/llm/prediction_engine.ahk
#Include test_llm_prediction_engine.ahk
#Include test_llm_defaults.ahk
; parser.ahk (the AHK semantic-diff parser) was previously exercised by no suite,
; which let a crash in its Levenshtein helper survive — include it + its tests.
#Include ../modules/llm/parser.ahk
#Include test_llm_parser.ahk
#Include meta/test_llm_batch_dedup_stats.ahk
try FileAppend("# [marker] LLM production modules + tests included`r`n", A_Temp . "\ergopti_test_results.txt", "UTF-8")
try FileAppend("# [marker] LLM production modules + tests included`r`n", "*")

; LLM tray menu -> config.toml persistence (contract-driven round-trips).
global _LLM_Tray := Map(
	"enabled", true, "backend", "ollama", "model", "Qwen3.5-0.8B",
	"profile_id", "basic", "n_predictions", 3, "auto_profile_for_model", true,
	"min_words", 3, "max_words", 15, "language", "fr", "debounce_ms", 500,
	"ctx_chars", 500, "temperature", "0.10", "instant_on_word_end", true,
	"after_hotstring", true, "reset_on_nav", true, "disable_url_bars", true,
	"disable_password_fields", true, "disabled_apps", [], "show_info_bar", true,
	"streaming", true, "show_all_at_once", true, "pred_indent", 0,
	"auto_raise_temp", true, "nav_modifiers", "", "val_modifiers", "alt",
	"trigger_shortcut", "Ctrl+Space", "inline_autotype", false
)
try FileAppend("# [marker] about to include tray_llm/persist.ahk (with _LLM_Tray hack)`r`n", A_Temp . "\ergopti_test_results.txt", "UTF-8")
try FileAppend("# [marker] about to include tray_llm/persist.ahk (with _LLM_Tray hack)`r`n", "*")
#Include ../ui/tray_llm/persist.ahk
#Include test_llm_menu_persistence.ahk
#Include test_llm_menu_regressions.ahk
try FileAppend("# [marker] tray_llm persist + tests included`r`n", A_Temp . "\ergopti_test_results.txt", "UTF-8")
try FileAppend("# [marker] tray_llm persist + tests included`r`n", "*")

; Gestures module — included here because its pure logic (assignments, action
; registry, dispatch) is testable. The hotkeys it registers are harmless since
; RunTests() calls ExitApp immediately after completion.
try FileAppend("# [marker] about to include gestures.ahk (top-level t() for SLOT_LABELS)`r`n", A_Temp . "\ergopti_test_results.txt", "UTF-8")
try FileAppend("# [marker] about to include gestures.ahk (top-level t() for SLOT_LABELS)`r`n", "*")
#Include ../modules/gestures.ahk
#Include test_gestures.ahk
try FileAppend("# [marker] gestures + test included`r`n", A_Temp . "\ergopti_test_results.txt", "UTF-8")
try FileAppend("# [marker] gestures + test included`r`n", "*")

; Keylogger sub-modules — pure-logic subsets included here to test category
; lookup, character classification, and burst helpers without OS hooks or I/O.
; sqlite3.ahk needs _VendorDir (set by ErgoptiPlus.ahk at runtime); stub it
; here so the class static initialiser does not crash the test runner.
try FileAppend("# [marker] about to include keylogger modules + sqlite3 (with _VendorDir stub)`r`n", A_Temp . "\ergopti_test_results.txt", "UTF-8")
try FileAppend("# [marker] about to include keylogger modules + sqlite3 (with _VendorDir stub)`r`n", "*")
global _VendorDir := A_ScriptDir . "\..\vendor"
#Include ../lib/sqlite3.ahk
#Include ../modules/keylogger/keylogger_walker.ahk
#Include ../modules/keylogger/keylogger_app_categories.ahk
#Include ../modules/keylogger/keylogger_reader.ahk
; keylogger_clipboard.ahk defines _KL_Clip_CharCountFromByteSize + KLClipConst,
; both exercised functionally by meta/test_clipboard_ram_leak.ahk. It contains
; only class + function definitions at top level (the Hotkey()/OnClipboardChange
; calls live inside KL_Clip_Start), so it is headless-safe. Without this include
; the test's direct call to _KL_Clip_CharCountFromByteSize is a load-time
; "nonexistent function" error that hangs the headless runner with no output.
#Include ../modules/keylogger/keylogger_clipboard.ahk
#Include test_keylogger_walker.ahk
#Include test_keylogger_app_categories.ahk
#Include test_keylogger_reader.ahk
; Shared timings (A3): tap_holds/constants.ahk defines the tap-hold timing
; globals + TapHoldsLoadTimings() and has NO top-level hotkeys, so it is safe to
; include here (unlike most modules/). test_timings_config exercises the shared
; registry reader plus the keylogger-walker and tap-hold reassign-at-boot loaders.
#Include ../modules/tap_holds/constants.ahk
#Include test_timings_config.ahk
try FileAppend("# [marker] keylogger modules + tests included`r`n", A_Temp . "\ergopti_test_results.txt", "UTF-8")
try FileAppend("# [marker] keylogger modules + tests included`r`n", "*")

; ── Meta tests (codebase hygiene, no production includes needed) ──
#Include meta/test_ahk_brace_balance.ahk
#Include meta/test_file_headers.ahk
#Include meta/test_section_headers.ahk
#Include meta/test_run_all_include_integrity.ahk
#Include meta/test_runner_only_filter.ahk
#Include meta/test_runner_failure_ergonomics.ahk
#Include meta/test_ahk_os_purity_ratchet.ahk
#Include meta/test_logger_pairing.ahk
#Include meta/test_no_duplicate_defaults.ahk
#Include meta/test_require_state_pattern.ahk
#Include meta/test_keylogger_pause_guard.ahk
#Include meta/test_changelog_http_timeout.ahk
#Include meta/test_dpapi_decrypt_safe.ahk
#Include meta/test_menu_dispatcher_critical.ahk
#Include meta/test_warmup_retry_suspend_guard.ahk
#Include meta/test_halflife_tick_suspend_guard.ahk
#Include meta/test_layout_poll_suspend_guard.ahk
#Include meta/test_lalt_rctrl_accept_suspend_guard.ahk
#Include meta/test_layout_poll_blacklist_guard.ahk
#Include meta/test_layout_quiescence.ahk
#Include meta/test_hse_register_atomic.ahk
#Include meta/test_hse_rebuild_guard.ahk
#Include meta/test_gesture_shared_lbutton.ahk
#Include meta/test_gesture_takenote_winwait.ahk
#Include meta/test_gesture_exit_button_release.ahk
#Include meta/test_textsend_clipall.ahk
#Include meta/test_llm_autotype_hse_suppress.ahk
#Include meta/test_ingest_tick_guards.ahk
#Include meta/test_ingest_failure_requeues.ahk
#Include meta/test_gesture_keywatcher_suspend.ahk
#Include meta/test_activitysim_collision.ahk
#Include meta/test_metrics_focus_cache_atomic.ahk
#Include meta/test_clipboard_ram_leak.ahk
#Include meta/test_space_tap_dispatch.ahk
#Include meta/test_roi_map_mutation_race.ahk
#Include meta/test_deferred_registration_live_rebuild_race.ahk
#Include meta/test_spotlight_non_blocking.ahk
#Include meta/test_spotlight_gdiplus_leak.ahk
#Include meta/test_toml_batchwrite_atomic.ahk
#Include meta/test_webview2_temp_leak.ahk
#Include meta/test_webview_low_ram_native_fallback.ahk
#Include meta/test_hookdispatcher_swallow.ahk
#Include meta/test_llm_json_parser_silent_fail.ahk
#Include meta/test_json_unicode_escape.ahk
#Include meta/test_healthcheck_recordwarn_called.ahk
#Include meta/test_wrap_symbol_disabled_state.ahk
#Include meta/test_screenshot_region_clipwait_clobber.ahk
#Include meta/test_av_mute_heuristic.ahk
#Include meta/test_ergo_roi_count_synth.ahk
#Include meta/test_profile_delete_path.ahk
#Include meta/test_nav_val_modifiers_wired.ahk
#Include meta/test_no_active_app_cache.ahk
#Include meta/test_updater_sync_winhttp_blocks.ahk
#Include meta/test_sqlite_progress_yield.ahk
#Include meta/test_logger_sync_warning.ahk
#Include meta/test_keylogger_deferred_write.ahk
#Include meta/test_deadkey_timeout.ahk
#Include meta/test_sendinstant_deferred_clipboard.ahk
#Include meta/test_keepawake_pause_gate.ahk
#Include meta/test_mouse_park_gate.ahk
#Include meta/test_mouse_hotkey_clobber.ahk
#Include meta/test_mouse_suspend_guard.ahk
#Include meta/test_scroll_flush_fn_cleared_on_stop.ahk
#Include meta/test_timer_scheduler_pause_guard.ahk
#Include meta/test_keylogger_watchers_pause_guard.ahk
#Include meta/test_uia_selection_background_poll.ahk
#Include meta/test_remote_poll_deadline.ahk
#Include meta/test_download_integrity_guard.ahk
#Include meta/test_no_coauthor_in_commits.ahk
#Include meta/test_no_pascal_case_in_toml.ahk
#Include meta/test_bundle_exclusions.ahk
#Include meta/test_llm_tray_init_order.ahk
#Include meta/test_llm_ensure_model_ready_guard.ahk
#Include meta/test_boot_deferred_tasks.ahk
#Include meta/test_wpm_widget_native_render.ahk
#Include meta/test_wpm_widget_hidden_until_typed.ahk
#Include meta/test_text_expansion_critical_path.ahk
#Include meta/test_prefix_watcher_deferred.ahk
#Include meta/test_native_hotstrings_migrated.ahk
#Include meta/test_i18n_fallback_deferred.ahk
#Include test_hse_conform_double_fire.ahk
#Include meta/test_llm_tray_deferred_build.ahk
#Include meta/test_logger_format_placeholders.ahk
#Include meta/test_logger_sub_files_routing.ahk
#Include meta/test_prefix_render_deferred.ahk
#Include meta/test_input_serialization.ahk
#Include meta/test_personal_load_once.ahk
#Include meta/test_tray_llm_actions_include.ahk
#Include meta/test_port_adapter_coverage.ahk
#Include meta/test_no_class_global_conflict.ahk
#Include meta/test_locale_json_valid.ahk
#Include meta/test_wrap_symbols_gate.ahk
#Include meta/test_wrap_symbols_catalogue.ahk
; ── Cross-driver corpus consumers ──
#Include meta/test_corpus_hotstrings.ahk
#Include meta/test_corpus_tap_hold.ahk
#Include meta/test_corpus_hotstring_matcher.ahk
; LLM parser corpus -- tests LLM_ParseOllamaResponse and _LLMRemoteParseResponse
; against the shared cross-driver vectors (already included above via api_ollama/api_remote).
#Include meta/test_corpus_llm_parser.ahk
; Security / keylogger privacy corpus -- tests ES_PASSWORD detection and
; Win32 known-class lookup logic in isolation (OS-level paths are headless-safe stubs).
#Include meta/test_corpus_security_keylogger.ahk
; PromptBuilder corpus -- tests the generated PromptBuilder class against the
; shared cross-driver vectors.
#Include ../_generated/prompt_builder.ahk
#Include meta/test_corpus_prompt_builder.ahk
; TOML fuzz corpus -- exercises ParseTomlFile() against 50 adversarial inputs.
; Asserts the loader never crashes on any input (valid or invalid TOML).
#Include meta/test_corpus_toml_fuzz.ahk

; -- Audit finding regression tests (batch-wired) --
#Include meta/test_activate_hotstrings_sleep_gate.ahk
#Include meta/test_altgr_reregister_guard.ahk
#Include meta/test_app_picker_t_variable_shadows_i18n.ahk
#Include meta/test_appstate_orphaned_parallel_state.ahk
#Include meta/test_av_focus_mode_dead_code.ahk
#Include meta/test_border_gdi_cleanup_broken_nesting.ahk
#Include meta/test_capslock_led_single_owner.ahk
#Include meta/test_config_shortcuts_array_escape.ahk
#Include meta/test_config_window_delay_write_per_keystroke.ahk
#Include meta/test_curl_payload_pii_temp_leak.ahk
#Include meta/test_deadkey_suspend_guard.ahk
#Include meta/test_deferred_menu_critical_file_io.ahk
#Include meta/test_dequeue_poll_no_suspend_guard.ahk
#Include meta/test_dispatcher_map_never_cleared_stale_misfire.ahk
#Include meta/test_dispatcher_start_guarded.ahk
#Include meta/test_dispatcher_start_ungated.ahk
#Include meta/test_dispatcher_stop_wired.ahk
#Include meta/test_error_handler_heavy_diagnostics.ahk
#Include meta/test_ext_builder_fn_dynamic_call_swallow.ahk
#Include meta/test_format_toml_stale_path_deadcode.ahk
#Include meta/test_gesturepickcolor_clipboard_clobber.ahk
#Include meta/test_getselection_blocks_and_eats_keys.ahk
#Include meta/test_global_error_handler_sendevent_storm.ahk
#Include meta/test_health_probe_timer_suspend_guard.ahk
#Include meta/test_healthcheck_init_dead_reference.ahk
#Include meta/test_hse_disable_group_atomic.ahk
#Include meta/test_insert_id_discovery_label_collision.ahk
#Include meta/test_isrepeat_section_name_mismatch_latent_divergence.ahk
#Include meta/test_kh_intercept_dead_flag.ahk
#Include meta/test_kl_refresh_context_blocks_on_keystroke.ahk
#Include meta/test_kl_stop_dead_no_exit_flush.ahk
#Include meta/test_kl_window_switch_pre_flush.ahk
#Include meta/test_klpf_writeatomic_delete_window.ahk
#Include meta/test_klr_builddatabase_debug_fileappend_hot.ahk
#Include meta/test_klw_ctx_unbounded_hist_growth.ahk
#Include meta/test_lalt_capslock_tap_min_duration.ahk
#Include meta/test_llm_accept_cleanup_in_finally.ahk
#Include meta/test_llm_pointer_watch_not_stopped_on_suspend.ahk
#Include meta/test_loader_toml_injection_readfile_hotpath.ahk
#Include meta/test_lock_workstation_named_helper.ahk
#Include meta/test_lost_tick_after_filtered_keystroke.ahk
#Include meta/test_menu_dispatch_callbacks_unbounded_growth.ahk
#Include meta/test_ni_isvpnactive_missing_return.ahk
#Include meta/test_no_onexit_keylogger_flush.ahk
#Include meta/test_onboarding_no_appstate.ahk
#Include meta/test_numeric_prompt_throws_on_nonnumeric.ahk
#Include meta/test_oneshotshift_lalt_lshift_stuck.ahk
#Include meta/test_oneshotshift_suspend_guard.ahk
#Include meta/test_hold_modifier_release_bounded.ahk
#Include meta/test_altgr_rolls_precedence.ahk
#Include meta/test_keylogger_session_watcher_synth.ahk
#Include meta/test_kl_stop_flush_survives_suspend.ahk
#Include meta/test_onkeydown_dead_llm_branch.ahk
#Include meta/test_parser_ord_empty_token_crash.ahk
#Include meta/test_password_cache_torn_write.ahk
#Include meta/test_paste_plain_nontext_clip_guard.ahk
#Include meta/test_pathstoml_read_missing_utf8_encoding.ahk
#Include meta/test_personal_ext_scan_unbounded_recursion.ahk
#Include meta/test_pointer_watch_timer_bypasses_suspend.ahk
#Include meta/test_prefix_index_rebuild_no_suspend_guard.ahk
#Include meta/test_prefix_onkeydown_tab_llm_feed_gap.ahk
#Include meta/test_reg_keyexists_value_only.ahk
#Include meta/test_remap_emit_critical_uneven.ahk
#Include meta/test_remote_api_validate_async.ahk
#Include meta/test_roi_current_word_unbounded_growth.ahk
#Include meta/test_roi_full_map_prune_scan_on_hot_path.ahk
#Include meta/test_sendinstant_reentrancy_guard.ahk
#Include meta/test_sensors_cpu_state_stale_across_reload.ahk
#Include meta/test_space_altgr_double_raalt_down.ahk
#Include meta/test_ssid_utf8_misdecode_and_signal_offset.ahk
#Include meta/test_stream_final_flush_sleep_blocks_thread.ahk
#Include meta/test_strict_canon_does_not_drop_stale_keys.ahk
#Include meta/test_suspend_watchdog_no_prefix_keywait.ahk
#Include meta/test_tab_accept_cancels_timer.ahk
#Include meta/test_textsend_clipboard_thread.ahk
#Include meta/test_tint_test_stale_constants_comment.ahk
#Include meta/test_tooltip_hide_non_blocking.ahk
#Include meta/test_tooltip_teardown_on_keyboard_thread.ahk
#Include meta/test_topo_checkvirtualdesktop_stale_prev_hwnd.ahk
#Include meta/test_traymenu_separator_addstandard.ahk
#Include meta/test_traymenu_setmenu_raw_add.ahk
#Include meta/test_tap_hold_menu_register_dispatch.ahk
#Include meta/test_menu_dispatch_error_propagation.ahk
#Include meta/test_ui_launch_error_msgbox_on_timer_thread.ahk
#Include meta/test_uia_error_logged.ahk
#Include meta/test_updater_focus_poll_suspend_guard.ahk
#Include meta/test_updater_setchannel_cancels_async.ahk
#Include meta/test_updater_setcheckinterval_coerces.ahk
#Include meta/test_webview_temp_dir_and_com_leak_on_reload.ahk
#Include meta/test_win_l_lock_resets_context.ahk
#Include meta/test_winhttp_no_abort_on_poll_timeout.ahk
#Include meta/test_winorder_unbounded_and_cross_thread.ahk
#Include meta/test_wpm_push_unguarded_debug_arg_build.ahk
#Include meta/test_wpm_ring_buffer_cross_thread_race.ahk
#Include test_coalesced_job_callbacks_dropped.ahk
#Include test_count_regex_vs_entry_pattern_divergence.ahk
#Include test_counttoml_overcounts_personal_meta_sections.ahk
#Include test_delay_edit_non_integer_personal_truncation.ahk
#Include test_freshness_same_second_edit_window.ahk
#Include test_inline_autotype_not_synthetic.ahk
#Include test_json_number_misleading_error.ahk
#Include test_ollama_curl_temp_pii_plaintext.ahk
#Include test_parsetomlgroupconfig_missing_file_cache_key.ahk
#Include test_parsetomlgroupconfig_missing_file_cache_key_mismatch.ahk
#Include test_per_entry_priority_divergence_cache_vs_toml.ahk
#Include test_plc_closure_callable.ahk
#Include test_remote_parse_first_content_match.ahk
#Include test_stale_cache_survives_reset_and_pause.ahk
#Include test_time_activation_fails_open_on_missing_prev_char.ahk
#Include test_uridecode_multibyte_utf8_corruption.ahk

; -- Audit finding regression tests (batch-wired) --
#Include meta/test_generated_substr_minus_one.ahk
#Include meta/test_toml_multiline_array_depth.ahk
#Include meta/test_toml_unescape_ordering.ahk
#Include meta/test_clipboard_sentinel.ahk
#Include meta/test_textsend_callback_wired.ahk
#Include meta/test_is_category_all_enabled_loop.ahk
#Include meta/test_regread_no_type_arg.ahk
#Include meta/test_logger_dedup_tick.ahk
#Include meta/test_hse_endchar_consumed_delimiters.ahk
#Include meta/test_prefix_watcher_magic_suffix.ahk
#Include meta/test_deadkey_uses_dynamic_magic_key.ahk
#Include meta/test_parse_overrides_seen_sections.ahk
#Include meta/test_llm_getactiveprofile_arg.ahk
#Include meta/test_tickcount_wrap_safe.ahk
#Include meta/test_tickcount_lib_wrap.ahk
#Include meta/test_llm_token_budget_min5.ahk
#Include meta/test_llm_parser_nul_strip.ahk
#Include meta/test_altgr_hotif_dynamic.ahk
#Include meta/test_ergo_pinky_modifier_skip.ahk
#Include meta/test_watchers_idle_end_ordering.ahk
#Include meta/test_timer_scheduler_ms_guard.ahk
#Include meta/test_http_cancel_aborts.ahk
#Include meta/test_keyboard_hook_vk_format.ahk
#Include meta/test_plc_stop_clears_callbacks.ahk
#Include meta/test_toml_coerce_quoted_commas.ahk
#Include meta/test_i18n_setlocale_resets_fallback.ahk
#Include meta/test_ws_save_atomic.ahk
#Include meta/test_tapholdwriter_int_before_bool.ahk
#Include meta/test_llm_tray_toggle_reentrancy.ahk
#Include meta/test_llm_tray_tab_source_hwnd.ahk
#Include meta/test_modelbrowser_sort_callback.ahk
#Include meta/test_space_taphold_configurable.ahk
#Include meta/test_terminators_requires_directive.ahk
#Include meta/test_layout_poll_pending_hkl.ahk
#Include meta/test_llmbridge_stop_order.ahk
#Include meta/test_llmdiff_has_corrections_ltrim.ahk
#Include meta/test_audit_test_gaps.ahk
#Include meta/test_keylogger_flush_atomic.ahk
#Include meta/test_keylogger_tick_overflow.ahk
#Include meta/test_llm_streaming_fixes.ahk
#Include meta/test_layout_deadkey_endkey.ahk
#Include meta/test_deadkey_unmapped_base_char.ahk
#Include meta/test_savefullconfig_no_delete.ahk
#Include meta/test_keylogger_scan_max_id_tail.ahk
#Include meta/test_gesture_screenshot_no_tempfile.ahk
#Include meta/test_hotstrings_deadkey_uppercase_cleanup.ahk
#Include meta/test_parser_splitblocks_cap.ahk
#Include meta/test_ollama_trim_registry_min_id.ahk
#Include meta/test_clipwait_binary.ahk
#Include meta/test_timer_scheduler_oneshot_suspend.ahk
#Include meta/test_hotstrings_cache_atomic_write.ahk
#Include meta/test_keylogger_hook_global_try.ahk
#Include meta/test_keylogger_idle_defer_preserves_pending.ahk
#Include meta/test_keylogger_rollover_force_ingest.ahk
#Include meta/test_klnet_starter_deref.ahk
#Include test_audit_v4_fixes.ahk
#Include test_hotstrings_escape_braces.ahk
#Include meta/test_hotstrings_combo_auto_escaping.ahk
#Include meta/test_ergo_flow_gap_end.ahk
#Include meta/test_config_window_patch_toml_meta_error.ahk
#Include meta/test_capsword_mouse_clobber.ahk
#Include test_timer_scheduler_suspend.ahk
#Include meta/test_magic_key_probe_deadkey_safe.ahk
#Include meta/test_script_shortcut_labels_locale.ahk
#Include meta/test_altgr_chord_debounce_per_slot.ahk
#Include meta/test_roi_halflife_threshold_reachable.ahk
#Include meta/test_hse_notepad_consumed_delimiter.ahk
#Include test_llm_parser_dedup_stats.ahk
#Include meta/test_paste_without_formatting_restore.ahk
#Include meta/test_hold_layer_release_bounded.ahk
#Include meta/test_toml_batchwrite_cache_coherence.ahk
#Include meta/test_topology_debounce_settled_geometry.ahk
#Include meta/test_topology_single_append.ahk
#Include meta/test_crash_report_unique_filename.ahk
#Include meta/test_gesture_paste_plain_busy_guard.ahk
#Include test_llm_deadline_wrap.ahk
#Include meta/test_gr_drawbitmap_type_guard.ahk
#Include test_gr_drawbitmap_closure.ahk
#Include meta/test_gestures_action_catalog_deferred.ahk
#Include meta/test_hse_altgr_kana_sendinput.ahk
#Include meta/test_text_sender_clipboard_generation_recheck.ahk
#Include meta/test_disable_password_fields_gate.ahk
#Include meta/test_boot_dircreate_guarded.ahk
#Include meta/test_toml_render_bool_sentinel.ahk
#Include meta/test_llm_tray_loaded_gate.ahk
#Include meta/test_altgr_dispatch_suspend_guard.ahk
#Include meta/test_llm_inject_complete_callback.ahk
#Include meta/test_ngram_esrc_json_accumulate.ahk
#Include meta/test_ngram_tables_not_cleared_on_refresh.ahk
#Include meta/test_shift_digit_passthrough_not_shadowed.ahk
#Include meta/test_deps_installer_pid_captured.ahk
#Include meta/test_llm_parse_billions_null_guard.ahk
#Include meta/test_toggle_capslock_calls_disable_capsword.ahk
#Include meta/test_tap_hold_writer_inherit_defaults.ahk
#Include meta/test_llm_nav_loop_ten.ahk
#Include meta/test_api_entries_persist_error_logged.ahk
#Include meta/test_updater_callback_suspend_guard.ahk
#Include meta/test_updater_self_update_bak_rollback.ahk
#Include meta/test_bundle_resolve_dir_local_appdata.ahk
#Include meta/test_altgr_detect_hkl_fallback.ahk
#Include meta/test_spotlight_gdiplus_free_library.ahk
#Include meta/test_case_transform_synthetic_mark.ahk
#Include meta/test_color_dropdown_recompute_index.ahk
#Include meta/test_magic_key_no_regex_inject.ahk
#Include meta/test_logger_fanout_batched.ahk
#Include meta/test_crash_reporter_slash_precedence.ahk
#Include meta/test_logger_flush_on_warning.ahk
#Include meta/test_hook_dispatcher_critical_save_restore.ahk
#Include meta/test_hook_dispatcher_err_cache_cap.ahk
#Include meta/test_walker_batch_critical.ahk
#Include meta/test_async_password_detect_suspend_guard.ahk
#Include meta/test_sensors_warmup_distinct_callback.ahk
#Include meta/test_kltopo_seen_hwnds_cap.ahk
#Include meta/test_remapped_list_unconditional.ahk
#Include meta/test_wpm_widget_color_cache.ahk
#Include meta/test_screenshot_async_run.ahk
#Include meta/test_space_hold_empty_guard.ahk
#Include meta/test_profile_hotkey_stable_pred.ahk
#Include meta/test_updater_download_timeout.ahk
#Include meta/test_mouse_control_physical_cursor.ahk
#Include meta/test_crash_prompt_blocking_msgbox.ahk
#Include meta/test_keyboard_shortcut_groups_register_dispatch.ahk
#Include meta/test_changelog_fetch_async.ahk
#Include meta/test_deferred_ext_scan_critical_file_io.ahk
#Include meta/test_wpm_compact_color_validation.ahk
#Include meta/test_backspace_repeat_suspend_guard.ahk
#Include meta/test_prefix_render_flush_suspend_guard.ahk
#Include meta/test_gesture_dispatch_logs_failure.ahk
#Include meta/test_ollama_installer_sync_winhttp_blocks.ahk
#Include meta/test_g5_updater_download.ahk

; Watchdog: kill the process if RunTests() never returns (e.g. a corpus
; consumer blocks on a synchronous HTTP call, an InputHook with no timeout,
; or a blocking dialog in a headless CI context). The CI-level timeout is
; 5 min; this fires at 4 min so the log message reaches stdout before the
; runner is killed externally.
global _SUITE_TIMEOUT_MS := 240000
_WatchdogFire() {
	try FileAppend("`n[WATCHDOG] Test suite timed out after " . _SUITE_TIMEOUT_MS . " ms - force-exiting.`n", "*")
	ExitApp(2)
}
SetTimer(_WatchdogFire, -_SUITE_TIMEOUT_MS)

; Drive everything. RunTests prints a TAP-style report to stdout and exits
; with the appropriate code — control never returns from this call.
RunTests()
