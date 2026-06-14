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
global _AHK_DRY_RUN := (A_Args.Length > 0 && A_Args[1] == "--dry-run")

; Test framework first — Assert / Test / RunTests must exist before any
; subsequent file registers its cases or invokes assertions inside lambdas.
#Include test_framework.ahk

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
#Include ../lib/hotstrings/personal_toml_editor.ahk
#Include ../lib/layout/layout_altgr.ahk
#Include ../lib/layout/layout_shift_caps.ahk
#Include ../lib/tooltip.ahk
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

; Shortcuts modules — dispatcher logic is testable without real hotkeys firing;
; the module files are #Include'd from within test_shortcuts.ahk itself so the
; include paths are resolved relative to the tests/ directory.
#Include test_shortcuts.ahk

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
#Include meta/test_file_headers.ahk
#Include meta/test_section_headers.ahk
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
#Include meta/test_layout_poll_blacklist_guard.ahk
#Include meta/test_hse_register_atomic.ahk
#Include meta/test_gesture_shared_lbutton.ahk
#Include meta/test_textsend_clipall.ahk
#Include meta/test_llm_autotype_hse_suppress.ahk
#Include meta/test_ingest_tick_guards.ahk
#Include meta/test_gesture_keywatcher_suspend.ahk
#Include meta/test_activitysim_collision.ahk
#Include meta/test_metrics_focus_cache_atomic.ahk
#Include meta/test_space_tap_dispatch.ahk
#Include meta/test_roi_map_mutation_race.ahk
#Include meta/test_deferred_registration_live_rebuild_race.ahk
#Include meta/test_spotlight_non_blocking.ahk
#Include meta/test_spotlight_gdiplus_leak.ahk
#Include meta/test_toml_batchwrite_atomic.ahk
#Include meta/test_webview2_temp_leak.ahk
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
#Include meta/test_timer_scheduler_pause_guard.ahk
#Include meta/test_keylogger_watchers_pause_guard.ahk
#Include meta/test_uia_selection_cache.ahk
#Include meta/test_remote_poll_deadline.ahk
#Include meta/test_download_integrity_guard.ahk
#Include meta/test_no_coauthor_in_commits.ahk
#Include meta/test_no_pascal_case_in_toml.ahk
#Include meta/test_bundle_exclusions.ahk
#Include meta/test_llm_tray_init_order.ahk
#Include meta/test_llm_ensure_model_ready_guard.ahk
#Include meta/test_boot_deferred_tasks.ahk
#Include meta/test_wpm_widget_native_render.ahk
#Include meta/test_text_expansion_critical_path.ahk
#Include meta/test_prefix_watcher_deferred.ahk
#Include meta/test_native_hotstrings_migrated.ahk
#Include meta/test_i18n_fallback_deferred.ahk
#Include test_hse_conform_double_fire.ahk
#Include meta/test_llm_tray_deferred_build.ahk
#Include meta/test_logger_format_placeholders.ahk
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
