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
; 1. The runner #Includes the production ``infra/`` files directly. This means
;    a refactor in a lib file is immediately exercised by the corresponding
;    test_*.ahk file with no per-test glue to maintain.
; 2. ``modules/`` files are deliberately NOT included — they register hotkeys
;    at top level and would prevent the runner from exiting cleanly. The
;    behaviour exposed by modules (layer / shortcuts / hotstrings) is tested
;    through the infra/ helpers it shares with production.
; 3. AHK v2 directives at the top mirror those in ErgoptiPlus.ahk so that
;    parser quirks (#Warn VarUnset, encoding) are identical between test
;    runs and production startup.
; ==============================================================================

#Requires Autohotkey v2.0+
#SingleInstance Force
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
; AppState fields directly, and before any infra/ file that reads AppState.
#Include ../infra/app_state.ahk

; Stubs second — they define ScriptInformation, Features, SendNewResult,
; WrapTextIfSelected, DeadKey, ToggleCapsLock, etc., which infra/ files
; reference at definition (Bind) time or at call time during tests.
#Include test_stubs.ahk
#Include ../modules/keylogger/keylogger_health.ahk

; Install a very early error handler for top-level / #Include phase errors.
; When a newly added production module (LLM, gestures, keylogger, prompt builder,
; menu_llm persist, etc.) or test_*.ahk has a top-level statement that throws
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
#Include ../infra/tick_count.ahk
#Include ../infra/app_state.ahk
; Compiled-mode bundle bootstrapper — included this early (matching its real
; position right after app_state.ahk in ErgoptiPlus.ahk) so its functions are
; actually exercised by meta/test_bundle_resolve_dir_local_appdata.ahk instead
; of only being scanned as raw text. Bundle_Init() itself is never called here
; (A_IsCompiled is false in the test runner, and it would ExitApp on failure
; anyway) — only its pure helpers (_Bundle_ResolveDir, ResolveLocalAppDataDir)
; are invoked directly by the regression test.
#Include ../infra/bundle.ahk
#Include ../infra/tray_bootstrap.ahk
#Include ../infra/single_instance_gate.ahk
#Include ../ui/menu/menu_llm/menu_build_coordinator.ahk
#Include ../infra/ui_style.ahk
#Include ../_generated/logger_sub_files.ahk
#Include ../infra/logger.ahk
#Include ../infra/toml/toml_helpers.ahk
; Shared timing registry reader (TimingsLoadShared / TimingsGet) — needs
; ParseTomlFile above; exercised by test_timings_config.ahk.
#Include ../infra/timings/timings_config.ahk

#Include ../infra/window_utils.ahk
#Include ../ui/tooltip/position_receipt.ahk
#Include ../infra/text_utils.ahk
#Include ../infra/nav_layer_helpers.ahk
#Include ../infra/hotstrings/hotstring_engine.ahk
#Include ../infra/hotstrings/hotstring_engine_main.ahk
#Include ../infra/hotstrings/hotstring_buffer_effects.ahk
#Include ../infra/hotstrings/hotstring_live_toggle.ahk
#Include ../infra/hotstrings/hotstring_count_policy.ahk
#Include ../infra/hotstrings/hotstring_prefix_watcher.ahk
#Include ../infra/master_gates.ahk
; Generated terminator catalogue (shared single source) — exercised by
; test_terminators.ahk and consumed by the tray / config-window delimiter menus.
#Include ../_generated/terminators.ahk
#Include ../infra/toml/toml_loader.ahk
#Include ../infra/hotstrings/hotstrings_cache.ahk
#Include ../infra/toml/toml_config_loader.ahk
#Include ../platform/remap/tap_hold_loader.ahk
#Include ../platform/remap/tap_hold_writer.ahk
#Include ../ui/menu/menu_taphold.ahk
#Include ../_generated/features_manifest.ahk
#Include ../infra/manifest_reader.ahk
; The dynamic-hotstring module, for its pure helpers (SpacedPrefix, the three
; date formatters). Definitions only — _DynHS_RegisterAll() is not called here,
; so no registration happens at harness load.
#Include ../modules/dynamic_hotstrings/dynamic_hotstrings.ahk
#Include ../infra/feature_io.ahk
; EnsurePersonalHotstringFeature is exercised directly by the F4 regression
; test (test_feature_io_locator.ahk) — RegisterPersonalFeature in the same file
; is never called here, so its own unseeded global (_PersonalShortcutsRegistry)
; is harmless (#Warn VarUnset is off).
#Include ../infra/personal_features.ahk
#Include ../infra/hotstrings/hotstrings_config.ahk
#Include ../infra/suspend_handoff.ahk
#Include ../infra/reload_terminal_handoff.ahk
#Include ../infra/suppressive_inputhook_ownership.ahk
#Include ../infra/lifecycle_transition.ahk
#Include ../infra/config_transition.ahk
#Include ../infra/config_transition_runtime.ahk
; _CollectFeatureUpdates / _CollectFeatureFlipUpdates are exercised directly by
; the section-resolution regression tests
; (test_config_io_feature_section_resolution.ahk).
; ToggleAllFeatures/SaveFullConfig themselves are never invoked here (they
; depend on numerous boot-only globals, and the successful bulk path reloads),
; so including this file is safe — only function definitions at top level.
#Include ../infra/config_io.ahk
#Include ../ui/personal_toml_editor.ahk
; Pure helpers (no boot-time side effects) — CountDynamicSection is exercised
; by the dynamic-hotstrings corpus parity test.
#Include ../infra/menu_helpers.ahk
; Definitions-only live rebuild coordinator/menu helpers. No tray mutation is
; performed until a test explicitly invokes an injected rebuild body.
#Include ../ui/menu/menu_rebuild.ahk
; Wrap-symbols persistence: globals and function definitions only, no top-level
; side effects, so it loads headlessly. Included so the load/save data-loss
; guard (test_wrap_symbols_unreadable_blocks_save.ahk) can drive the real
; functions instead of scanning their source.
#Include ../infra/wrap_symbols_config.ahk
#Include ../modules/keymap/layout/layout_altgr.ahk
#Include ../modules/keymap/layout/layout_shift_caps.ahk
; Pure layout-poll quiescence decision (no OS deps, no top-level hotkeys) —
; exercised by meta/test_layout_quiescence.ahk and consumed by ErgoptiPlus.ahk.
#Include ../modules/keymap/layout_poll_helper.ahk
#Include ../ui/tooltip/init.ahk
#Include ../modules/updater.ahk
; json.ahk must precede locale.ahk — _I18nLoadLocaleMap delegates to JsonParse.
#Include ../infra/registry.ahk
#Include ../infra/json.ahk
; locale.ahk (string loading + t()) is included here because gestures.ahk calls
; t() at the top level when building GESTURE_SLOT_LABELS; without it the process
; blocks on an AHK runtime-error MsgBox and the CI job times out. i18n.ahk (locale
; management) follows it and calls into the loaders/state it declares.
#Include ../infra/locale.ahk
#Include ../_generated/gesture_emit_actions.ahk
#Include ../_generated/locale_table.ahk
#Include ../infra/i18n.ahk
_LogBootProgress("i18n included (t() available)")

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
#Include ../adapters/uia_worker.ahk
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
#Include ../adapters/mouse_control.ahk
#Include ../adapters/graphics_renderer.ahk
#Include ../adapters/shell_runner.ahk
#Include ../adapters/crash_report_worker.ahk
#Include ../modules/diagnostics/crash_reporter.ahk
#Include ../infra/error_net.ahk
#Include ../modules/keymap/uia_selection_worker.ahk
SFD_ConfigureUiaWorker(
	UIASW_RequestPassword, UIASW_Start, UIASW_ContextMatches)
; Unified input-hook dispatcher + keyboard_hook adapter. hook_dispatcher.ahk
; defines only classes at top level (no hotkeys), so it is safe in the headless
; runner; keyboard_hook.ahk registers/unregisters its subscribers through it.
; Exercised by test_hook_dispatcher.ahk (BoundFunc identity + bind-once contract).
#Include ../infra/hook_dispatcher.ahk
#Include ../adapters/keyboard_hook.ahk

; Lock _AHK_SendText / _AHK_SendInput to no-ops AFTER the adapter has been
; included (the adapter sets them to real lambdas; InstallSendNoOps overwrites
; them so no keystroke can escape into the OS during test execution).
InstallSendNoOps()

; ── Per-module test files (each registers Test() cases) ──
#Include unit/test_adapter_compliance_new.ahk
#Include unit/test_feature_io_locator.ahk
#Include meta/test_feature_io_impl_no_global.ahk
#Include meta/test_isset_no_property_arg.ahk
#Include unit/test_adapter_contract_vectors.ahk
#Include unit/test_clipboard_paste_transaction_ownership.ahk
#Include unit/test_suppressive_inputhook_ownership.ahk
#Include unit/test_window_manager_force_foreground.ahk
#Include unit/test_take_note_async_job.ahk
#Include unit/test_text_sender_modifiers.ahk
#Include unit/test_timer_scheduler.ahk
#Include unit/test_hook_dispatcher.ahk
#Include unit/test_logger.ahk
#Include unit/test_logger_format_failure_is_visible.ahk
#Include unit/test_logger_contract.ahk
#Include unit/test_logger_daily_rotation.ahk
#Include unit/test_healthcheck_core.ahk
#Include unit/test_healthcheck_owner_snapshots.ahk
#Include unit/test_tooltip_tint_contract.ahk
#Include unit/test_tooltip_border_alpha.ahk
#Include unit/test_tooltip_border_pool.ahk
#Include unit/test_tooltip_dequeue_regression.ahk
#Include unit/test_tooltip_dequeue_contract.ahk
#Include unit/test_tooltip_position_cache_receipt.ahk
#Include unit/test_llm_tooltip_grace.ahk
#Include unit/test_llm_tooltip_render.ahk
#Include unit/test_hotstring_engine.ahk
#Include unit/test_hotstring_engine_main.ahk
#Include unit/test_suppress_refcount.ahk
#Include unit/test_hotstring_live_toggle.ahk
#Include unit/test_live_rebuild_serialization.ahk
#Include unit/test_tray_root_coordinator.ahk
#Include unit/test_terminal_hotstring_pacing.ahk
#Include unit/test_terminal_hotstring_transaction_owner.ahk
#Include unit/test_output_host_resolver_independent_of_metrics.ahk
#Include unit/test_gesture_modifier_release_ownership.ahk
#Include unit/test_tray_root_lifecycle_retained.ahk
#Include unit/test_tray_bootstrap_publication_transaction.ahk
#Include unit/test_llm_menu_build_coordinator.ahk
#Include unit/test_hotstring_count_policy.ahk
#Include unit/test_prefix_watcher_index.ahk
#Include unit/test_prefix_visible_suggestion_epoch.ahk
#Include unit/test_preview_index_covers_every_registration.ahk
#Include unit/test_preview_defers_to_engine.ahk
#Include unit/test_prefix_index_cache_equiv.ahk
#Include unit/test_personal_info_mask_vectors.ahk
#Include unit/test_personal_info_tags_single_source.ahk
#Include unit/test_preview_provider_at_triggers.ahk
; The fire-time @-combo resolver that replaced the hand-written list of
; thirty-one registrations. It lives in hotstring_engine_main.ahk (loaded above)
; and reads only globals, so the tests drive the REAL function against fixture
; personal-info maps rather than asserting on its source.
#Include unit/test_personal_info_combo_resolver.ahk
#Include unit/test_master_gates.ahk
#Include unit/test_domain_registry.ahk
#Include unit/test_domain_expander.ahk
#Include unit/test_toml_loader.ahk
#Include unit/test_toml_helpers_roundtrip.ahk
#Include unit/test_hotstrings_cache.ahk
#Include unit/test_dynamic_hotstrings_module.ahk
#Include unit/test_hotstrings_config.ahk
#Include unit/test_hotstring_delimiter_global_transaction_20260813.ahk
#Include unit/test_hotstring_override_global_transaction_20260813.ahk
#Include unit/test_terminators.ahk
#Include unit/test_personal_toml_editor.ahk
#Include unit/test_menu_helpers.ahk
#Include unit/test_manifest_menu_resolve_disabled_when_failclosed.ahk
#Include unit/test_manifest_menu_declarations_are_read.ahk
#Include unit/test_manifest_menu_checked_when.ahk
#Include unit/test_layout_tables.ahk
#Include unit/test_uia_selection_worker_deadline.ahk

#Include unit/test_config.ahk
#Include unit/test_feature_state_boot.ahk
#Include unit/test_wpm_config_types.ahk
#Include ../ui/wpm/wpm_widget.ahk
#Include unit/test_wpm_drag_admission.ahk
#Include unit/test_features_manifest.ahk
#Include unit/test_config_io_feature_section_resolution.ahk
#Include unit/test_hotstrings_full.ahk
#Include unit/test_tap_hold_loader.ahk
#Include unit/test_i18n.ahk
#Include unit/test_locale_probe_is_silent.ahk
#Include unit/test_window_utils.ahk
#Include unit/test_text_utils.ahk
#Include unit/test_registry.ahk
#Include unit/test_personal_toml_io.ahk
#Include unit/test_personal_info_persistence_transaction_20260813.ahk
#Include unit/test_nav_layer_helpers.ahk
#Include unit/test_synthetic_buffer_effects.ahk
#Include unit/test_prefix_finalizer_generation.ahk
#Include unit/test_synthetic_sends_declare_buffer_effect.ahk
#Include unit/test_capsword_taphold_unlatch.ahk
#Include meta/test_tap_hold_suspend_boundary.ahk
#Include unit/test_updater.ahk
#Include unit/test_updater_staging_transport.ahk
#Include unit/test_updater_swap_transaction.ahk
#Include unit/test_gesture_emit_actions.ahk
#Include unit/test_updater_constants_single_source.ahk
#Include meta/test_updater_load_interval_guard.ahk

; Shortcuts modules — dispatcher logic is testable without real hotkeys firing;
; the module files are #Include'd from within test_shortcuts.ahk itself so the
; include paths are resolved relative to the tests/ directory.
#Include unit/test_shortcuts.ahk
#Include unit/test_keepawake_visible_cancellation.ahk

; Metrics shortcuts — MS_ToAhkSyntax is pure logic (no OS calls, no hotkeys
; registered at top level) so the file is safe to include in the headless runner.
#Include ../infra/app_picker.ahk
#Include ../infra/config_shortcuts.ahk
#Include ../infra/metrics/metrics_filters.ahk
#Include ../infra/metrics/metrics_shortcuts.ahk
#Include ../ui/menu/menu_metrics.ahk
#Include ../ui/menu/menu_metrics_actions.ahk
#Include unit/test_metrics_shortcut_named_key.ahk
#Include unit/test_metrics_shortcut_persist_on_bind_failure.ahk
#Include unit/test_metrics_shortcut_transactions.ahk
#Include unit/test_config_shortcuts_types.ahk
#Include unit/test_metrics_shortcut_menu_refresh.ahk
#Include unit/test_metrics_preferences_global_barrier_20260813.ahk

; LLM modules — pure-logic subset (profiles, models, api_common, api_ollama,
; api_remote, prediction_engine) included here to test JSON parsing, profile
; lookup, payload building, response parsing, cancel helpers, and engine
; debounce / cache logic without any real network calls.
; models.ahk defines LLM_GetSharedPath which profiles.ahk depends on.
_LogBootProgress("loading LLM modules")
#Include ../modules/llm/models.ahk
#Include ../infra/llm_defaults.ahk
; llm_profiles_data.ahk (generated) defines LLM_LEGACY_IDS + LLM_GetBasicPrompt()
; which profiles.ahk depends on — see the LLM legacy/basic-prompt single-source tests.
#Include ../_generated/llm_profiles_data.ahk
#Include ../modules/llm/profiles.ahk
#Include unit/test_llm_profiles.ahk
#Include ../modules/llm/api_common.ahk
#Include ../modules/llm/api_token_crypto.ahk
#Include unit/test_llm_api_common.ahk
#Include ../modules/llm/api_ollama.ahk
#Include ../modules/llm/api_remote.ahk
#Include unit/test_llm_api_ollama.ahk
#Include unit/test_llm_api_remote.ahk
#Include unit/test_llm_crash_orphan_cleanup.ahk
#Include unit/test_llm_temp_artifact_terminal_ownership.ahk
#Include unit/test_llm_aux_request_ownership.ahk
#Include unit/test_llm_curl_terminal_classification.ahk
#Include unit/test_ollama_http_terminal_classification.ahk
#Include unit/test_remote_curl_terminal_classification.ahk
; Remote catalogue load must fall back gracefully when api_providers.json is missing/malformed.
#Include meta/test_remote_catalog_load_graceful.ahk
#Include ../modules/llm/option_validation.ahk
#Include ../modules/llm/prediction_engine.ahk
#Include unit/test_llm_prediction_engine.ahk
#Include unit/test_llm_semantic_config_identity.ahk
#Include unit/test_llm_semantic_config_budget.ahk
#Include unit/test_llm_defaults.ahk
; llm_bridge.ahk is needed by the canonical HSE -> LLM effect behaviour tests.
#Include ../modules/keymap/llm_bridge.ahk
#Include unit/test_llm_bridge_apply_expansion.ahk
#Include unit/test_llm_bridge_buffer_cap.ahk
#Include unit/test_llm_pointer_watch_transaction.ahk
#Include unit/test_llm_tab_accept_policy.ahk
; parser.ahk (the AHK semantic-diff parser) was previously exercised by no suite,
; which let a crash in its Levenshtein helper survive — include it + its tests.
#Include ../modules/llm/parser.ahk
#Include unit/test_llm_parser.ahk
#Include meta/test_llm_batch_dedup_stats.ahk
; Non-blocking installed-tags cache contract + behaviour (menu-build-sync-api-tags-freeze).
; Behavioural cases call the real models.ahk cache funcs included just above.
#Include meta/test_llm_installed_tags_async.ahk
; Any input (type/click/move) cancels in-progress generation (llm-spinner-lingers-through-input).
#Include meta/test_llm_input_cancels_generation.ahk
; Ollama reachability probe is non-blocking curl, not WinHTTP (ollama-reachability-winhttp-connect-blocks).
#Include meta/test_ollama_reachability_async_nonblocking.ahk
; Orphan temp-file sweep is bounded + off the Critical dispatch path (llm-orphan-sweep-temp-recursion).
#Include meta/test_llm_orphan_sweep_nonblocking.ahk
; The coordinator serializes detached LLM menu builds and retains re-entrant work.
#Include meta/test_llm_markchain_no_rerender.ahk
#Include meta/test_llm_menu_build_critical.ahk
#Include meta/test_llm_menu_build_coordinator.ahk
_LogBootProgress("LLM modules + tests included")

; LLM tray menu -> config.toml persistence (contract-driven round-trips).
global _LLM_Menu := Map(
	"enabled", true, "backend", "ollama", "model", "Qwen3.5-0.8B",
	"profile_id", "basic", "n_predictions", 3, "auto_profile_for_model", true,
	"min_words", 3, "max_words", 15, "language", "fr", "debounce_ms", 500,
	"ctx_chars", 500, "temperature", "0.10", "instant_on_word_end", true,
	"after_hotstring", true, "reset_on_nav", true, "disable_url_bars", true,
	"disable_password_fields", true, "disabled_apps", [], "show_info_bar", true,
	"streaming", true, "show_all_at_once", true, "pred_indent", 0,
	"auto_raise_temp", true, "nav_modifiers", "", "val_modifiers", "alt",
	"trigger_shortcut", "Ctrl+Space", "inline_autotype", false,
	"ollama_port", 11434
)
global _LLM_Menu_Loaded := false
; Definitions-only trigger transaction. The fake registrar in its unit suite
; owns every native transition; this include registers no real hotkey.
#Include ../ui/menu/menu_llm/trigger_journal.ahk
#Include ../ui/menu/menu_llm/trigger_shortcut.ahk
#Include ../adapters/llm_nav_event_owner.ahk
#Include ../ui/menu/menu_llm/tab_accept.ahk
; Definitions-only boot restore helper. LLM_Menu_Init is never invoked by the
; harness; the regression suite calls only its one-shot saved-options seam.
#Include ../ui/menu/menu_llm/init.ahk
_LogBootProgress("loading menu_llm/persist")
#Include ../ui/menu/menu_llm/menu_models.ahk
#Include ../ui/menu/menu_llm/menu_profiles.ahk
#Include ../ui/menu/menu_llm/persist.ahk
#Include ../ui/menu/menu_llm/transactions.ahk
#Include ../ui/menu/menu_llm/backend_lifecycle.ahk
#Include ../ui/menu/menu_llm/aux_ownership.ahk
#Include ../ui/menu/menu_llm/menu_api_entries.ahk
#Include ../ui/menu/menu_llm/menu_settings.ahk
#Include unit/test_llm_backend_lifecycle_dispatch.ahk
#Include unit/test_llm_menu_persistence.ahk
#Include unit/test_llm_temperature_boundary.ahk
#Include unit/test_llm_numeric_option_ranges.ahk
#Include unit/test_llm_sync_target.ahk
#Include unit/test_llm_menu_transactions_20260813.ahk
#Include unit/test_app_picker_generation.ahk
#Include meta/test_app_picker_generation_wiring.ahk
#Include unit/test_llm_menu_locale_bridge.ahk
#Include meta/test_llm_menu_locale_source.ahk
#Include unit/test_llm_ollama_port_boundary.ahk
#Include meta/test_llm_ollama_port_owner.ahk
#Include unit/test_llm_menu_regressions.ahk
; The prompt-editor host is definitions-only until TryOpen is called. Load it so
; its deferred context fence can be exercised without creating a Gui/WebView.
#Include ../ui/prompt_editor/init.ahk
#Include unit/test_prompt_editor_context_epoch.ahk
; Changelog host is likewise definitions-only until Changelog_Open is called.
; Load it so the request/window epoch can be exercised with deterministic fakes.
#Include ../ui/changelog/init.ahk
_LogBootProgress("menu_llm persist + tests included")

; Gestures module — included here because its pure logic (assignments, action
; registry, dispatch) is testable. The hotkeys it registers are harmless since
; RunTests() calls ExitApp immediately after completion.
_LogBootProgress("loading gestures modules")
#Include ../modules/take_note.ahk
#Include ../modules/gestures/init.ahk
#Include ../modules/gestures/click.ahk
#Include ../modules/gestures/screenshots.ahk
#Include ../modules/gestures/window_cycle.ahk
#Include ../modules/gestures/config.ahk
; Load the definitions-only onboarding worker owner so its elevated-launch
; reservation can be exercised without constructing the wizard UI.
#Include ../ui/onboarding/steps_metrics.ahk
#Include unit/test_screenshot_worker_ownership.ahk
#Include unit/test_gestures.ahk
#Include unit/test_config_persistence_transactions.ahk
#Include unit/test_config_recovery_transactions.ahk
#Include unit/test_config_commit_gateway.ahk
#Include unit/test_config_transition_core.ahk
#Include unit/test_config_transition_runtime.ahk
#Include unit/test_config_transition_windows_port.ahk
#Include unit/test_toml_build_updated_content.ahk
#Include unit/test_config_full_save_generation.ahk
#Include unit/test_config_write_terminal_barrier.ahk
#Include unit/test_feature_io_global_barrier.ahk
#Include unit/test_editor_global_barrier_behavior_20260813.ahk
#Include unit/test_runtime_decision_generation.ahk
#Include meta/test_wpm_global_barrier_behavior_20260813.ahk
#Include unit/test_gesture_restart_result_zero_is_success.ahk
_LogBootProgress("gestures + test included")

; Keylogger sub-modules — pure-logic subsets included here to test category
; lookup, character classification, and burst helpers without OS hooks or I/O.
; sqlite3.ahk needs _VendorDir (set by ErgoptiPlus.ahk at runtime); stub it
; here so the class static initialiser does not crash the test runner.
_LogBootProgress("loading keylogger modules")
global _VendorDir := A_ScriptDir . "\..\vendor"
; keylogger_prefetch.ahk normally receives this from infra/boot.ahk.  The
; headless runner loads only the pure worker protocol, so provide its explicit
; config-root dependency without executing the full driver boot sequence.
global _ConfigDir := A_Temp . "\ergopti_test_config\"
global _AhkSubDir := ""
#Include ../infra/sqlite3.ahk
#Include ../modules/keylogger/keylogger_walker.ahk
#Include ../modules/keylogger/keylogger_app_categories.ahk
#Include ../modules/keylogger/keylogger_reader.ahk
; ROI pruning is isolated from the hook-owning module so the exact production
; survivor and generation transactions can be exercised headlessly.
#Include ../modules/keylogger/keylogger_roi_prune.ahk
; Password-field classification is definitions-only. Load the real async cache
; writer so its fail-closed behaviour can be exercised with a fake UIA object.
#Include ../modules/keylogger/keylogger_password.ahk
; Atomic completion journaling is definitions-only. Load the production module
; against the Keylogger/Metrics stubs so privacy-epoch and RAM-commit ordering
; are verified without arming the full keylogger lifecycle.
#Include ../modules/keylogger/keylogger_llm_journal.ahk
; The prefetch worker contains no top-level I/O. Including it here enables a
; headless generation-fence test with a fake ShellRunner spawn handle.
#Include ../modules/keylogger/keylogger_prefetch.ahk
; Wi-Fi transition reduction is pure; the live timers are armed only by
; KL_Net_Start(), which the test runner never calls.
#Include ../modules/keylogger/keylogger_network.ahk
; Capture-state reduction is also definition-only. The process snapshot is
; invoked only by KL_AV_Start/KL_AV_ScanCapture, so tests can replace its seam
; without touching Win32 process enumeration.
#Include ../modules/keylogger/keylogger_av_state.ahk
; keylogger_webview.ahk is likewise definitions-only at top level. Loading the
; real module lets terminal/retry tests drive the production state machines;
; no Gui, COM object, timer, or WebView is created until an explicit function
; call, and those tests replace the push/timer boundaries with local seams.
#Include ../modules/keylogger/keylogger_webview.ahk
; keylogger_clipboard.ahk defines _KL_Clip_CharCountFromBuffer + KLClipConst,
; both exercised functionally by meta/test_clipboard_ram_leak.ahk. It contains
; only class + function definitions at top level (the Hotkey()/OnClipboardChange
; calls live inside KL_Clip_Start), so it is headless-safe. Without this include
; the test's direct call to _KL_Clip_CharCountFromByteSize is a load-time
; "nonexistent function" error that hangs the headless runner with no output.
#Include ../modules/keylogger/keylogger_clipboard.ahk
#Include unit/test_keylogger_clipboard_provenance.ahk
; keylogger_json.ahk (KL_JsonEncode) and keylogger_sql.ahk (KL_BuildInserts +
; the per-type KL_BuildInsertXxx builders) are pure definitions with no
; top-level hotkeys/OS hooks, so — like the walker sub-modules above — they
; are safe to load directly for unit coverage of the INSERT-statement
; builders (F19/F21: llm_*/av/network/clipboard/roi event types must not
; silently fall through KL_BuildInserts's switch).
#Include ../modules/keylogger/keylogger_json.ahk
#Include ../modules/keylogger/keylogger_journal.ahk
#Include ../modules/keylogger/keylogger_shutdown.ahk
#Include unit/test_keylogger_shutdown_timers.ahk
; Event-ID recovery is a pure module extracted from keylogger.ahk so its real
; tail parser can be exercised without loading the OS-hooking entry module.
#Include ../modules/keylogger/keylogger_event_id.ahk
#Include unit/test_keylogger_event_id.ahk
; keylogger_text_cipher.ahk (KL_Enc_* at-rest encryption) is pure definitions
; with no top-level hotkeys, and keylogger_sql.ahk now calls it, so it must load
; before the SQL builders.
#Include ../modules/keylogger/keylogger_text_cipher.ahk
; keylogger_text_migration.ahk (the data.sql rewrite that converts rows stored
; before the setting changed) is likewise pure definitions: its only side effect
; is armed by a timer from KL_Init, which the runner never calls.
#Include ../modules/keylogger/keylogger_text_migration.ahk
#Include ../modules/keylogger/keylogger_sql.ahk
; keylogger_hotstring_log.ahk holds KL_LogHotstring — the one persisted row that
; can carry the user's personal data. It was split out of keylogger.ahk (which
; installs OS hooks at load and can never be included here) precisely so this
; runner can drive the REAL function against the recording KL_AppendLog /
; KL_Roi_OnHotstring / WPMWidget_Push stubs in test_stubs.ahk. Asserting on a
; test-built copy of the row would have passed against the leaking code.
#Include ../modules/keylogger/keylogger_hotstring_log.ahk
; keylogger_watchers.ahk is definition-only. Include it so WTS subscription
; verdict/retry ownership is exercised through the real production functions.
#Include ../modules/keylogger/keylogger_watchers.ahk
#Include unit/test_keylogger_wts_registration.ahk
; keylogger_hook.ahk holds the OTHER sink that can carry the user's personal
; data: the per-keystroke typing buffer. The InputHook observes the driver's own
; auto-typed expansions, so an @iban★ fire reaches KL_Hook_OnChar character by
; character ~90 ms before the redacted hotstring row is written. The file is
; class + function definitions only (the InputHook is created inside
; KL_Hook_Start, which the runner never calls), so the real callbacks can be
; driven headless and the buffer they fill read straight back — the previous
; test asserted only on KL_LogHotstring's row and missed this one entirely.
#Include ../modules/keylogger/keylogger_hook.ahk
#Include ../modules/keylogger/keylogger_mouse.ahk
#Include ../modules/keylogger/keylogger_window_topology.ahk
#Include unit/test_bounded_focus_snapshot.ahk
#Include unit/test_keylogger_mouse_coordinates.ahk
#Include unit/test_keylogger_window_topology.ahk
#Include unit/test_hotstring_fire_log_privacy.ahk
#Include unit/test_synthetic_typing_row_privacy.ahk
; The near-miss row — the third persisted sink, and the one that had no privacy
; concept at all. _CheckNearMiss lives in hotstring_inputhook.ahk, which the
; prefix-watcher shim above already loads, so these drive the REAL function
; against the recording KL_AppendLog stub rather than a copy of its row.
#Include unit/test_near_miss_row_privacy.ahk
#Include unit/test_keylogger_walker.ahk
#Include unit/test_keylogger_sql.ahk
#Include unit/test_keylogger_text_cipher.ahk
#Include unit/test_keylogger_text_migration.ahk
#Include unit/test_build_inserts_covers_emitted_types.ahk
#Include unit/test_metrics_and_locale_honesty.ahk
#Include unit/test_keylogger_app_categories.ahk
#Include meta/test_keylogger_ui_dead_code.ahk
#Include unit/test_keylogger_reader.ahk
#Include unit/test_keylogger_reader_manifest_contract.ahk
#Include unit/test_keylogger_llm_accepted_metrics.ahk
#Include unit/test_keylogger_shortcut_projection.ahk
#Include unit/test_keylogger_reader_ngram_sources.ahk
#Include unit/test_roi_prune_bounded.ahk
#Include unit/test_keylogger_reader_sql_fail_loud.ahk
#Include unit/test_keylogger_reader_encrypted_rebuild.ahk
#Include unit/test_keylogger_app_category_projection.ahk
#Include unit/test_keylogger_password_fail_closed.ahk
#Include unit/test_single_instance_gate.ahk
#Include unit/test_keylogger_network_transitions.ahk
#Include ../infra/menu_command_origin.ahk
#Include unit/test_menu_command_origin.ahk
; KLW_GetMap and KLW_GetAppCtx must handle missing context keys without throwing.
#Include unit/test_walker_ctx_missing_key.ahk
; Shared timings (A3): tap_holds/constants.ahk defines the tap-hold timing
; globals + TapHoldsLoadTimings() and has NO top-level hotkeys, so it is safe to
; include here (unlike most modules/). test_timings_config exercises the shared
; registry reader plus the keylogger-walker and tap-hold reassign-at-boot loaders.
#Include ../platform/remap/constants.ahk
#Include unit/test_tap_hold_activity_cancel.ahk
#Include unit/test_timings_config.ahk
_LogBootProgress("keylogger modules + tests included")

; ── Meta tests (codebase hygiene, no production includes needed) ──
#Include meta/test_ahk_brace_balance.ahk
#Include meta/test_run_all_include_integrity.ahk
#Include meta/test_runner_only_filter.ahk
#Include meta/test_runner_failure_ergonomics.ahk
#Include meta/test_ahk_os_purity_ratchet.ahk
#Include meta/test_logger_pairing.ahk
#Include meta/test_remote_generate_curl_dispatch.ahk
#Include unit/test_network_dispatch_nonblocking.ahk
#Include meta/test_remote_connect_timeout_bounded.ahk
#Include meta/test_keylogger_json_64bit_decode.ahk
#Include meta/test_crash_build_offthread.ahk
#Include meta/test_assertions_are_case_sensitive.ahk
#Include meta/test_personal_hotstring_node_shape.ahk
#Include meta/test_personal_hotstring_seed.ahk
#Include meta/test_personal_hotstring_new_section_seed.ahk
#Include meta/test_personal_hotstring_cache_invalidation.ahk
#Include meta/test_personal_toml_write_failure_logged.ahk
#Include meta/test_hotstring_override_atomic_publish_20260813.ahk
#Include meta/test_personal_section_label_disambiguation_wired.ahk
#Include meta/test_no_duplicate_defaults.ahk
#Include meta/test_require_state_pattern.ahk
#Include meta/test_keylogger_pause_guard.ahk
#Include meta/test_changelog_http_timeout.ahk
#Include meta/test_dpapi_decrypt_safe.ahk
#Include meta/test_menu_dispatcher_critical.ahk
#Include meta/test_menu_dispatch_epoch.ahk
#Include meta/test_llm_setbackend_propagates_to_engine.ahk
#Include meta/test_llm_menu_persistence_transactions_20260813.ahk
#Include meta/test_warmup_retry_suspend_guard.ahk
#Include meta/test_halflife_tick_suspend_guard.ahk
#Include meta/test_layout_poll_suspend_guard.ahk
#Include meta/test_lalt_rctrl_accept_suspend_guard.ahk
#Include meta/test_tap_hold_fire_action_suspend_guard.ahk
#Include meta/test_tap_hold_native_dispatch_guard.ahk
#Include meta/test_lshift_lctrl_rshift_bounded_keywait.ahk
#Include meta/test_layout_poll_blacklist_guard.ahk
#Include meta/test_layout_quiescence.ahk
#Include meta/test_hse_register_atomic.ahk
#Include meta/test_hse_rebuild_guard.ahk
#Include meta/test_hse_rebuild_prefix_buffer_reset.ahk
#Include meta/test_gesture_shared_lbutton.ahk
#Include meta/test_gesture_left_hold_tap_release.ahk
#Include meta/test_gesture_takenote_winwait.ahk
#Include meta/test_takenote_hotpath_nonblocking.ahk
#Include meta/test_gesture_takenote_winmaximize_guard.ahk
#Include meta/test_gesture_get_cyclable_windows_catch.ahk
#Include meta/test_open_downloads_nonblocking.ahk
#Include meta/test_searchpath_regjump_catch.ahk
#Include meta/test_gesture_exit_button_release.ahk
#Include meta/test_onexit_terminal_order.ahk
#Include meta/test_textsend_clipall.ahk
#Include meta/test_text_sender_clipboard_restore.ahk
#Include meta/test_llm_autotype_hse_suppress.ahk
#Include meta/test_ingest_tick_guards.ahk
#Include meta/test_ingest_failure_requeues.ahk
#Include meta/test_gesture_keywatcher_suspend.ahk
#Include meta/test_activitysim_collision.ahk
#Include meta/test_metrics_focus_cache_atomic.ahk
#Include meta/test_metrics_focus_ttl_leak.ahk
#Include meta/test_metrics_focus_off_thread.ahk
#Include meta/test_clipboard_ram_leak.ahk
#Include meta/test_space_tap_dispatch.ahk
#Include meta/test_dispatch_verdict_consumed.ahk
#Include meta/test_fire_log_never_synchronous.ahk
#Include meta/test_deferred_hotstring_lifecycle_guards.ahk
#Include meta/test_roi_map_mutation_race.ahk
#Include meta/test_deferred_registration_live_rebuild_race.ahk
#Include meta/test_spotlight_non_blocking.ahk
#Include meta/test_spotlight_gdiplus_leak.ahk
#Include meta/test_toml_batchwrite_atomic.ahk
#Include unit/test_toml_batchwrite_exact_subtree.ahk
#Include meta/test_webview2_temp_leak.ahk
#Include meta/test_keylogger_webview_fallback.ahk
#Include meta/test_graphics_renderer_createwindow_catch.ahk
#Include meta/test_ollama_webview_executescript_deferred.ahk
#Include meta/test_ollama_webview_callback_epoch.ahk
#Include meta/test_keylogger_webview_executescript_deferred.ahk
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
#Include meta/test_b7_1_dead_shims_absent.ahk
#Include meta/test_b7_3_dead_fns_absent.ahk
#Include meta/test_updater_sync_winhttp_blocks.ahk
#Include meta/test_sqlite_progress_yield.ahk
#Include meta/test_agg_app_day_llm_suggested.ahk
#Include meta/test_reader_preserves_walker_aggregates.ahk
#Include meta/test_hotstring_check_constraint_widened.ahk
#Include meta/test_logger_sync_warning.ahk
#Include meta/test_keylogger_deferred_write.ahk
#Include meta/test_deadkey_timeout.ahk
#Include meta/test_sendinstant_deferred_clipboard.ahk
#Include meta/test_keepawake_pause_gate.ahk
#Include meta/test_keepawake_stop_notify_gate.ahk
#Include meta/test_mouse_park_gate.ahk
#Include meta/test_mouse_hotkey_clobber.ahk
#Include meta/test_mouse_suspend_guard.ahk
#Include meta/test_scroll_flush_fn_cleared_on_stop.ahk
#Include meta/test_timer_scheduler_pause_guard.ahk
#Include meta/test_keylogger_watchers_pause_guard.ahk
#Include unit/test_keylogger_session_privacy_transaction.ahk
#Include unit/test_keylogger_mouse_privacy_transaction.ahk
#Include meta/test_uia_selection_background_poll.ahk
#Include meta/test_uia_selection_snapshot.ahk
#Include meta/test_tooltip_render_epoch.ahk
#Include meta/test_tooltip_position_cache_receipt_wiring.ahk
#Include meta/test_tooltip_llm_render_epoch.ahk
#Include meta/test_llm_presented_record_single_source.ahk
#Include meta/test_remote_poll_deadline.ahk
#Include meta/test_download_integrity_guard.ahk
#Include meta/test_no_coauthor_in_commits.ahk
#Include meta/test_bundle_exclusions.ahk
#Include meta/test_llm_menu_init_order.ahk
#Include meta/test_llm_ensure_model_ready_guard.ahk
#Include meta/test_boot_deferred_tasks.ahk
#Include meta/test_boot_error_fatal_before_ready.ahk
#Include meta/test_hotif_globals_boot_safe.ahk
#Include meta/test_error_net_prelogger_safe.ahk
#Include meta/test_boot_paths_fail_soft.ahk
#Include meta/test_wpm_widget_native_render.ahk
#Include meta/test_wpm_widget_hidden_until_typed.ahk
#Include meta/test_text_expansion_critical_path.ahk
#Include meta/test_text_sender_clipboard_failure.ahk
#Include meta/test_text_sender_clipboard_sequence_ownership.ahk
#Include meta/test_download_window_i18n_fallback.ahk
#Include meta/test_tray_build_critical_restore.ahk
#Include meta/test_tray_root_terminal_forwarding.ahk
#Include meta/test_prefix_watcher_deferred.ahk
#Include meta/test_hotstrings_ready_contract.ahk
#Include meta/test_native_hotstrings_migrated.ahk
#Include meta/test_hse_send_transaction_guard.ahk
#Include meta/test_i18n_fallback_deferred.ahk
#Include unit/test_hse_conform_double_fire.ahk
#Include meta/test_llm_menu_deferred_build.ahk
#Include meta/test_logger_format_placeholders.ahk
#Include meta/test_logger_sub_files_routing.ahk
#Include meta/test_prefix_render_deferred.ahk
#Include meta/test_prefix_visible_suggestion_epoch.ahk
#Include meta/test_input_serialization.ahk
#Include meta/test_fire_log_defer_after_suppress.ahk
#Include meta/test_hse_suppress_release_bounded.ahk
#Include meta/test_hse_physical_suppression_provenance.ahk
#Include meta/test_hse_endchar_index_bound.ahk
#Include meta/test_hse_physical_input_provenance.ahk
#Include meta/test_uia_wrap_suppress_latch.ahk
#Include meta/test_near_miss_scan_bounded.ahk
#Include meta/test_gesture_cycle_winevent_fence.ahk
#Include meta/test_gesture_cycling_flag_critical.ahk
#Include meta/test_llm_app_filter_enforced.ahk
#Include meta/test_llm_instant_word_end_trigger.ahk
#Include meta/test_llm_tooltip_chunk_type_guard.ahk
#Include meta/test_space_hold_suspend_guard.ahk
#Include meta/test_av_warmup_cancellable.ahk
#Include meta/test_remote_poll_com_exception_bails.ahk
#Include meta/test_cle_emoji_gated.ahk
#Include meta/test_hse_consumed_endchar_ring.ahk
#Include meta/test_expansion_burst_atomic.ahk
#Include meta/test_parsetomlfile_unterminated_array_recovers.ahk
#Include meta/test_dispatcher_register_duplicate_label.ahk
#Include meta/test_updater_cancel_fires_on_json.ahk
#Include meta/test_updater_download_receive_timeout.ahk
#Include meta/test_updater_download_reentrancy_guard.ahk
#Include meta/test_personal_load_once.ahk
#Include meta/test_menu_llm_actions_include.ahk
#Include meta/test_llm_menu_suspend_bootstrap.ahk
#Include meta/test_llm_backend_lifecycle_ownership.ahk
#Include meta/test_llm_menu_disabled_greyed.ahk
#Include meta/test_language_menu_deferred_publication.ahk
#Include meta/test_llm_menu_layout_shared.ahk
; MenuManifest_LoadTopLevelTail/LoadGlobalActions/LoadDebugMenu — needed so
; the gestures-actions-separator regression test can exercise the real
; production loader (not a source-scan) against the real shared manifest.
#Include ../infra/menu_manifest.ahk
; The generic manifest walker. Pure function definitions — no top-level
; statements, no includes — so pulling it in is side-effect free, and it lets
; disabled_when tests exercise the real resolver instead of scanning its source.
#Include ../infra/manifest_menu.ahk
; Drift gate: manifest top_level tail (from global_actions) must match the AHK dispatch table.
#Include meta/test_menu_top_level_drift_gate.ahk
; Regression: the separator between Gestures and "Actions globales" must survive the tail loader.
#Include meta/test_menu_gestures_actions_separator.ahk
; Contract gate: metrics_menu disabled_when predicate == AHK handler resolver calls (MG-1/MG-2).
#Include meta/test_list_providers_touch_no_menu.ahk
#Include meta/test_menu_metrics_disabled_when.ahk
#Include meta/test_port_adapter_coverage.ahk
#Include meta/test_no_class_global_conflict.ahk
#Include meta/test_locale_json_valid.ahk
#Include meta/test_wrap_symbols_gate.ahk
#Include meta/test_wrap_symbols_catalogue.ahk
#Include unit/test_wrap_symbols_global_transaction_20260813.ahk
; ── Cross-driver corpus consumers ──
#Include meta/test_corpus_hotstrings.ahk
#Include meta/test_preview_matches_engine.ahk
#Include meta/test_prefix_buffer_tracks_engine.ahk
#Include meta/test_prefix_buffer_atomic_transitions_20260813.ahk
#Include meta/test_nav_cluster_resets_both_buffers.ahk
#Include meta/test_preview_never_wiped_alone.ahk
#Include meta/test_preview_engine_single_owner.ahk
#Include meta/test_corpus_dynamic_hotstrings_prefix.ahk
#Include meta/test_corpus_hotstrings_config_resolve.ahk
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
; Chord notation corpus -- runs the shared _shared/lua/chord/vectors.json against
; the AutoHotkey twin, plus the native-translation half that is supposed to differ.
#Include ../infra/chord.ahk
#Include ../adapters/hotkey_registrar.ahk
#Include meta/test_chord_notation.ahk
#Include unit/test_hotkey_registrar_transactions.ahk
#Include unit/test_llm_trigger_shortcut_transactions.ahk
#Include unit/test_llm_nav_event_owner.ahk
#Include unit/test_llm_nav_hotkey_transaction.ahk
#Include unit/test_llm_profile_hotkey_transaction.ahk
#Include unit/test_llm_hotkey_cross_owner_collision.ahk
#Include meta/test_llm_hotkey_cross_owner_policy.ahk
#Include unit/test_llm_trigger_journal.ahk
#Include meta/test_llm_trigger_shortcut_transaction.ahk
#Include meta/test_llm_trigger_journal_lifecycle.ahk
#Include meta/test_config_transition_integration.ahk
; Logger behaviour corpus -- severity filtering and the ring buffer, from the
; same shared file the macOS and Linux suites replay.
#Include meta/test_corpus_logger_behaviour.ahk
; TOML fuzz corpus -- exercises ParseTomlFile() against 50 adversarial inputs.
; Asserts the loader never crashes on any input (valid or invalid TOML).
#Include meta/test_corpus_toml_fuzz.ahk
#Include meta/test_toml_inline_comment_stripping.ahk
#Include meta/test_toml_read_failure_is_loud.ahk
#Include meta/test_config_boot_read_failure_blocks_persist.ahk
#Include meta/test_persist_result_not_discarded.ahk
#Include meta/test_config_persistence_callers.ahk
#Include meta/test_config_recovery_gateway.ahk
; Keylogger aggregation corpus -- tests KLW_WalkTypingEntry / KLW_WalkAppSwitch /
; KLW_WalkWindowSwitch / KLW_WalkSystemEvent against shared cross-driver vectors.
#Include meta/test_corpus_keylogger_aggregation.ahk
; Healthcheck snapshot corpus -- tests _HealthCheck_FormatUptime and validates
; the golden vectors for the shared snapshot logic (format_uptime, issues, schema).
#Include meta/test_corpus_healthcheck_snapshot.ahk
; Updater release parser corpus -- tests Updater_ParseTagName / Updater_ParseBody /
; _Updater_ParsePrerelease / _Updater_SplitReleasesArray against shared cross-driver vectors.
#Include meta/test_corpus_updater_release_parser.ahk
; Locale resolution corpus -- tests t() cascade (active→en→fr→raw key) and ★
; substitution against shared cross-driver vectors.
#Include meta/test_corpus_locale_resolution.ahk
; Tooltip layout corpus -- validates _TooltipClampToScreen against shared
; cross-driver vectors.
#Include meta/test_corpus_tooltip_layout.ahk
; TOML coercion corpus
#Include meta/test_corpus_toml_coercion.ahk

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
#Include meta/test_config_window_republishes_baked_fields.ahk
#Include meta/test_config_window_no_delimiter_ui.ahk
#Include meta/test_curl_payload_pii_temp_leak.ahk
#Include meta/test_deadkey_suspend_guard.ahk
#Include meta/test_deferred_menu_critical_file_io.ahk
#Include meta/test_dequeue_poll_no_suspend_guard.ahk
#Include meta/test_dispatcher_map_never_cleared_stale_misfire.ahk
#Include meta/test_dispatcher_start_guarded.ahk
#Include meta/test_dispatcher_start_ungated.ahk
#Include meta/test_dispatcher_stop_wired.ahk
#Include meta/test_driver_source_helpers_fail_loudly.ahk
#Include meta/test_error_handler_heavy_diagnostics.ahk
#Include meta/test_ext_builder_fn_dynamic_call_swallow.ahk
#Include meta/test_format_toml_stale_path_deadcode.ahk
#Include meta/test_gesturepickcolor_clipboard_clobber.ahk
#Include meta/test_getselection_blocks_and_eats_keys.ahk
#Include meta/test_global_error_handler_sendevent_storm.ahk
#Include meta/test_output_host_resolver_single_owner.ahk
#Include meta/test_gesture_modifier_release_class.ahk
#Include meta/test_health_probe_timer_suspend_guard.ahk
#Include meta/test_healthcheck_init_dead_reference.ahk
#Include meta/test_healthcheck_onwebmsg_dead_code.ahk
#Include meta/test_hse_disable_group_atomic.ahk
#Include meta/test_insert_id_discovery_label_collision.ahk
#Include meta/test_isrepeat_section_name_mismatch_latent_divergence.ahk
#Include meta/test_text_expansion_auto_toml_backed.ahk
#Include meta/test_kh_intercept_dead_flag.ahk
#Include meta/test_kl_refresh_context_blocks_on_keystroke.ahk
#Include meta/test_kl_stop_dead_no_exit_flush.ahk
#Include meta/test_kl_switch_privacy_filter_outgoing.ahk
#Include meta/test_kl_window_switch_pre_flush.ahk
#Include meta/test_klpf_writeatomic_delete_window.ahk
#Include meta/test_klr_builddatabase_debug_fileappend_hot.ahk
#Include meta/test_klr_builddatabase_failure_logged.ahk
#Include meta/test_klw_ctx_unbounded_hist_growth.ahk
#Include meta/test_lalt_capslock_tap_min_duration.ahk
#Include meta/test_llm_accept_cleanup_in_finally.ahk
#Include meta/test_llm_failure_callback_arity.ahk
#Include meta/test_llm_inline_autotype_suspend_guard.ahk
#Include meta/test_llm_pointer_watch_not_stopped_on_suspend.ahk
#Include meta/test_loader_toml_injection_readfile_hotpath.ahk
#Include meta/test_lock_workstation_named_helper.ahk
#Include meta/test_lost_tick_after_filtered_keystroke.ahk
#Include meta/test_menu_dispatch_callbacks_unbounded_growth.ahk
; Deep-liveness: the prune's tray walk reaches items at any depth (F07 deep-liveness).
#Include meta/test_menu_dispatch_deep_liveness.ahk
; Prune collects live IDs once, not per tracked ID — O(tray+tracked) (menu-prune-quadratic-tray-walk).
#Include meta/test_menu_prune_quadratic_tray_walk.ahk
#Include meta/test_ni_isvpnactive_missing_return.ahk
#Include meta/test_no_onexit_keylogger_flush.ahk
#Include meta/test_onboarding_no_appstate.ahk
#Include meta/test_onboarding_toml_bool_reads.ahk
#Include meta/test_onboarding_magic_key_sentinel.ahk
#Include meta/test_onboarding_effective_config_dir.ahk
#Include meta/test_onboarding_back_keeps_answers.ahk
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
#Include meta/test_registry_oserror_number_not_extra.ahk
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
#Include meta/test_owned_inputhooks_suspend.ahk
#Include meta/test_blocking_inputhook_suspend_ownership_20260813.ahk
#Include meta/test_timer_scheduler_registration_transaction.ahk
#Include meta/test_updater_finalize_nonblocking.ahk
#Include meta/test_bundle_upgrade_transaction.ahk
#Include meta/test_tab_accept_cancels_timer.ahk
#Include meta/test_textsend_clipboard_thread.ahk
#Include meta/test_tint_test_stale_constants_comment.ahk
#Include meta/test_tooltip_hide_non_blocking.ahk
#Include meta/test_tooltip_teardown_on_keyboard_thread.ahk
#Include meta/test_llm_bridge_deferred_hides.ahk
#Include meta/test_topo_checkvirtualdesktop_stale_prev_hwnd.ahk
#Include meta/test_traymenu_separator_addstandard.ahk
#Include meta/test_traymenu_setmenu_raw_add.ahk
#Include meta/test_tap_hold_menu_register_dispatch.ahk
#Include meta/test_menu_dispatch_error_propagation.ahk
#Include meta/test_ui_launch_error_msgbox_on_timer_thread.ahk
#Include meta/test_uia_error_logged.ahk
#Include meta/test_updater_focus_poll_suspend_guard.ahk
#Include meta/test_updater_setchannel_cancels_async.ahk
#Include meta/test_updater_setchannel_blocks_during_download.ahk
#Include meta/test_updater_setcheckinterval_coerces.ahk
#Include meta/test_webview_temp_dir_and_com_leak_on_reload.ahk
#Include meta/test_win_l_lock_resets_context.ahk
#Include meta/test_winhttp_no_abort_on_poll_timeout.ahk
#Include meta/test_winorder_unbounded_and_cross_thread.ahk
#Include meta/test_wpm_push_unguarded_debug_arg_build.ahk
#Include meta/test_wpm_config_position_pair_validation.ahk
#Include meta/test_wpm_persistence_transaction.ahk
#Include meta/test_config_full_save_generation_guard.ahk
#Include meta/test_wpm_ring_buffer_cross_thread_race.ahk
#Include unit/test_coalesced_job_callbacks_dropped.ahk
#Include unit/test_count_regex_vs_entry_pattern_divergence.ahk
#Include unit/test_counttoml_overcounts_personal_meta_sections.ahk
#Include unit/test_delay_edit_non_integer_personal_truncation.ahk
#Include unit/test_freshness_same_second_edit_window.ahk
#Include unit/test_inline_autotype_not_synthetic.ahk
#Include unit/test_loadexttoml_skips_meta_sections.ahk
#Include unit/test_json_number_misleading_error.ahk
#Include unit/test_ollama_curl_temp_pii_plaintext.ahk
#Include unit/test_parsetomlgroupconfig_missing_file_cache_key.ahk
#Include unit/test_parsetomlgroupconfig_missing_file_cache_key_mismatch.ahk
#Include unit/test_per_entry_priority_divergence_cache_vs_toml.ahk
#Include unit/test_plc_closure_callable.ahk
#Include unit/test_remote_parse_first_content_match.ahk
#Include unit/test_stale_cache_survives_reset_and_pause.ahk
#Include unit/test_time_activation_fails_open_on_missing_prev_char.ahk
#Include unit/test_uridecode_multibyte_utf8_corruption.ahk

; -- Audit finding regression tests (batch-wired) --
#Include meta/test_generated_substr_minus_one.ahk
#Include meta/test_toml_multiline_array_depth.ahk
#Include meta/test_toml_unescape_ordering.ahk
#Include meta/test_clipboard_sentinel.ahk
#Include meta/test_clipboard_saveall_sentinel.ahk
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
#Include meta/test_llm_menu_toggle_reentrancy.ahk
#Include meta/test_llm_menu_tab_source_hwnd.ahk
#Include meta/test_modelbrowser_sort_callback.ahk
#Include meta/test_space_taphold_configurable.ahk
#Include meta/test_terminators_requires_directive.ahk
#Include meta/test_layout_poll_pending_hkl.ahk
#Include meta/test_llmbridge_stop_order.ahk
#Include meta/test_llm_render_clears_dequeue.ahk
#Include meta/test_search_shortcut_run_path_existence_guard.ahk
#Include meta/test_updater_swap_exit_guard.ahk
#Include meta/test_keyboard_hook_dispatch_error_logged.ahk
#Include meta/test_tray_menu_cleared_before_onboarding.ahk
#Include meta/test_tray_bootstrap_publication_transaction.ahk
#Include meta/test_config_shortcuts_unescape_ordering.ahk
#Include meta/test_gesture_selfactivated_bounded.ahk
#Include meta/test_llm_api_no_entry_logged.ahk
#Include meta/test_llm_cancel_not_under_critical.ahk
#Include meta/test_llm_dispatch_not_under_critical.ahk
#Include meta/test_dead_ps1_pipeline_absent.ahk
#Include meta/test_deps_fail_restores_priority.ahk
#Include meta/test_tab_accept_invalidates_inflight.ahk
#Include meta/test_llm_accept_suppress_balance.ahk
#Include meta/test_altgr_latch_dispatch_aborts.ahk
#Include meta/test_gesture_click_hold_released_on_suspend.ahk
#Include meta/test_gesture_click_hold_transaction.ahk
#Include meta/test_walker_batch_drained_on_rollover_and_stop.ahk
#Include meta/test_tap_hold_none_sentinel.ahk
#Include meta/test_deps_check_epoch_guard.ahk
#Include meta/test_updater_rebuild_resets_dispatcher.ahk
#Include meta/test_capsword_reset_on_suspend.ahk
#Include meta/test_capsword_space_release_timeout.ahk
#Include meta/test_gesture_toggle_ui_errors_logged.ahk
#Include meta/test_lalt_capslock_enabled_gate.ahk
#Include meta/test_wpm_mousewatch_suspend_guard.ahk
#Include meta/test_tooltip_resolve_pos_profiled.ahk
#Include meta/test_error_net_guarded_send.ahk
#Include meta/test_error_net_dedup_throttle.ahk
#Include meta/test_error_net_uia_orphan_suppress.ahk
#Include meta/test_deferred_crash_report_catch.ahk
#Include meta/test_keylogger_webview_bridge_and_i18n.ahk
#Include meta/test_keylogger_webview_range_bridge.ahk
#Include meta/test_llmdiff_has_corrections_ltrim.ahk
#Include meta/test_audit_test_gaps.ahk
#Include meta/test_keylogger_flush_atomic.ahk
#Include meta/test_keylogger_tick_overflow.ahk
#Include meta/test_llm_streaming_fixes.ahk
#Include meta/test_layout_deadkey_endkey.ahk
#Include meta/test_oneshotshift_endkeys.ahk
#Include meta/test_magic_key_capture.ahk
#Include meta/test_gesture_restart_nonblocking.ahk
#Include meta/test_gesture_open_url_run_guard.ahk
#Include meta/test_addshortcut_registration_guard.ahk
#Include meta/test_gpt_hotkey_run_guard.ahk
#Include meta/test_menu_manifest_lifecycle_pair.ahk
#Include meta/test_editor_persist_before_publish.ahk
#Include meta/test_keylogger_webview_epoch.ahk
#Include meta/test_keylogger_webview_callback_fail_safe.ahk
#Include meta/test_keylogger_clipboard_registration_transaction.ahk
#Include meta/test_keylogger_prefetch_worker.ahk
#Include meta/test_sendinstant_clip_contention_guard.ahk
#Include meta/test_sendinstant_clipboard_sequence_ownership.ahk
#Include meta/test_plain_paste_clipboard_sequence_ownership.ahk
#Include meta/test_onboarding_gesture_registration_async.ahk
#Include unit/test_text_sender_completion_status.ahk
#Include unit/test_text_sender_sendinput_failure.ahk
#Include meta/test_deadkey_unmapped_base_char.ahk
#Include meta/test_savefullconfig_no_delete.ahk
#Include meta/test_keylogger_scan_max_id_tail.ahk
#Include meta/test_gesture_screenshot_no_tempfile.ahk
#Include meta/test_wmexists_is_not_a_handle.ahk
#Include meta/test_taphold_scancodes_are_the_real_keys.ahk
#Include unit/test_crypto_sha256_is_real.ahk
#Include meta/test_capslock_led_does_not_latch.ahk
#Include meta/test_hotstrings_deadkey_uppercase_cleanup.ahk
#Include meta/test_parser_splitblocks_cap.ahk
#Include meta/test_ollama_trim_registry_min_id.ahk
#Include meta/test_clipwait_binary.ahk
#Include meta/test_timer_scheduler_oneshot_suspend.ahk
#Include meta/test_hotstrings_cache_atomic_write.ahk
#Include meta/test_keylogger_hook_global_try.ahk
#Include meta/test_keylogger_idle_defer_preserves_pending.ahk
#Include meta/test_keylogger_rollover_force_ingest.ahk
#Include meta/test_keylogger_rollover_transaction.ahk
#Include meta/test_klnet_starter_deref.ahk
#Include unit/test_audit_v4_fixes.ahk
#Include unit/test_hotstrings_escape_braces.ahk
#Include unit/test_hotstring_send_failure_containment.ahk
#Include unit/test_hse_send_failure_transaction.ahk
#Include meta/test_hotstrings_combo_auto_escaping.ahk
#Include meta/test_ergo_flow_gap_end.ahk
#Include meta/test_config_window_patch_toml_meta_error.ahk
#Include meta/test_capsword_mouse_clobber.ahk
#Include unit/test_timer_scheduler_suspend.ahk
#Include meta/test_magic_key_probe_deadkey_safe.ahk
#Include meta/test_script_shortcut_labels_locale.ahk
#Include meta/test_altgr_chord_debounce_per_slot.ahk
#Include meta/test_roi_halflife_threshold_reachable.ahk
#Include meta/test_hse_notepad_consumed_delimiter.ahk
#Include meta/test_notepad_hotstring_atomic_burst.ahk
#Include unit/test_llm_parser_dedup_stats.ahk
#Include meta/test_paste_without_formatting_restore.ahk
#Include meta/test_hold_layer_release_bounded.ahk
#Include meta/test_hold_layer_survives_long_press.ahk
#Include meta/test_toml_batchwrite_cache_coherence.ahk
#Include meta/test_topology_debounce_settled_geometry.ahk
#Include meta/test_topology_single_append.ahk
#Include meta/test_crash_report_unique_filename.ahk
#Include meta/test_gesture_paste_plain_busy_guard.ahk
#Include unit/test_llm_deadline_wrap.ahk
#Include meta/test_gr_drawbitmap_type_guard.ahk
#Include unit/test_gr_drawbitmap_closure.ahk
#Include meta/test_gestures_action_catalog_deferred.ahk
#Include meta/test_hse_altgr_kana_sendinput.ahk
#Include meta/test_text_sender_clipboard_generation_recheck.ahk
#Include meta/test_text_sender_clipboard_suspend_guard.ahk
#Include meta/test_llm_output_physical_generation_20260813.ahk
#Include meta/test_text_sender_callback_on_bailout.ahk
#Include meta/test_shell_runner_poll_suspend_guard.ahk
#Include meta/test_shell_runner_legacy_claims.ahk
#Include meta/test_screenshot_tree_owned_default.ahk
#Include meta/test_shell_runner_isolated_logger.ahk
#Include meta/test_disable_password_fields_gate.ahk
#Include meta/test_menu_dynamic_hotstrings_category_gate.ahk
#Include meta/test_menu_master_category_cache.ahk
#Include unit/test_storage_st_delete_contract.ahk
#Include meta/test_boot_dircreate_guarded.ahk
#Include meta/test_toml_render_bool_sentinel.ahk
#Include meta/test_llm_menu_loaded_gate.ahk
#Include meta/test_altgr_dispatch_suspend_guard.ahk
#Include meta/test_llm_inject_complete_callback.ahk
#Include meta/test_ngram_esrc_json_accumulate.ahk
#Include meta/test_ngram_tables_not_cleared_on_refresh.ahk
#Include meta/test_shift_digit_passthrough_not_shadowed.ahk
#Include meta/test_deps_installer_pid_captured.ahk
#Include meta/test_llm_parse_billions_null_guard.ahk
#Include meta/test_toggle_capslock_calls_disable_capsword.ahk
#Include meta/test_tap_hold_writer_inherit_defaults.ahk
#Include meta/test_tap_hold_persist_before_publish.ahk
#Include meta/test_tap_hold_picker_catalog_path.ahk
#Include meta/test_tap_hold_global_transaction_20260813.ahk
#Include meta/test_llm_nav_loop_ten.ahk
#Include meta/test_api_entries_persist_error_logged.ahk
#Include meta/test_updater_callback_suspend_guard.ahk
#Include meta/test_altgr_dispatch_resume_aware.ahk
#Include meta/test_updater_self_update_bak_rollback.ahk
#Include meta/test_updater_swap_failure_receipt.ahk
#Include meta/test_bundle_resolve_dir_local_appdata.ahk
#Include meta/test_personal_shortcuts_compiled_include_path.ahk
#Include meta/test_personal_shortcuts_generator_encoding.ahk
#Include meta/test_personal_shortcuts_reload_handoff.ahk
#Include meta/test_personal_shortcuts_atomic_bootstrap.ahk
#Include meta/test_altgr_detect_hkl_fallback.ahk
#Include meta/test_altgr_kana_taphold_entry.ahk
#Include meta/test_spotlight_gdiplus_free_library.ahk
#Include meta/test_case_transform_synthetic_mark.ahk
#Include meta/test_color_dropdown_recompute_index.ahk
#Include meta/test_color_picker_hotkey_nonblocking.ahk
#Include meta/test_magic_key_no_regex_inject.ahk
#Include meta/test_logger_fanout_batched.ahk
#Include meta/test_crash_reporter_slash_precedence.ahk
#Include meta/test_logger_flush_on_error.ahk
#Include meta/test_atomic_write_unique_scratch.ahk
#Include meta/test_byref_call_sites.ahk
#Include meta/test_uia_probe_bounded.ahk
#Include meta/test_healthcheck_collectors_guarded.ahk
#Include meta/test_personal_editor_section_guard.ahk
#Include meta/test_gestures_init_lifecycle_pair.ahk
#Include meta/test_paths_file_single_writer.ahk
#Include meta/test_changelog_fetch_status_logged.ahk
#Include meta/test_mutex_yield_is_recorded.ahk
#Include meta/test_suspend_deferral_bounded.ahk
#Include meta/test_suspend_lifecycle_logged.ahk
#Include unit/test_lifecycle_transition.ahk
#Include meta/test_dead_state_and_single_source.ahk
#Include meta/test_discarded_config_is_reported.ahk
#Include meta/test_sql_replay_is_idempotent.ahk
#Include meta/test_keyboard_shortcut_slots_roundtrip.ahk
#Include meta/test_config_failures_are_surfaced.ahk
#Include meta/test_crash_report_not_suppressed.ahk
#Include meta/test_submenu_survives_publish.ahk
#Include meta/test_keymap_hotpath_guards.ahk
#Include meta/test_keymap_deadkey_emit_serialized.ahk
#Include meta/test_deadkey_ring_push.ahk
#Include meta/test_altgr_callbacks_serialized.ahk
#Include meta/test_hook_dispatcher_critical_save_restore.ahk
#Include meta/test_hook_dispatcher_err_cache_cap.ahk
#Include meta/test_walker_batch_critical.ahk
#Include meta/test_walker_pure_fns_match_shared_core.ahk
#Include meta/test_keylogger_critical_restore.ahk
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
#Include meta/test_curl_response_size_bound.ahk
#Include meta/test_changelog_webview_bridge.ahk
#Include meta/test_model_browser_webview_bridge.ahk
#Include meta/test_deferred_ext_scan_critical_file_io.ahk
#Include meta/test_wpm_compact_color_validation.ahk
#Include meta/test_backspace_repeat_suspend_guard.ahk
#Include meta/test_prefix_render_flush_suspend_guard.ahk
#Include meta/test_gesture_dispatch_logs_failure.ahk
#Include meta/test_ollama_installer_sync_winhttp_blocks.ahk
#Include meta/test_ollama_delete_model_async.ahk
#Include meta/test_g5_updater_download.ahk
#Include meta/test_key_state_dllcall_guards.ahk
#Include meta/test_updater_loadchannel_try_wrap.ahk
#Include meta/test_crash_report_sysinfo_dedup.ahk
#Include meta/test_logger_dedup_exit_flush.ahk
#Include meta/test_shell_runner_boot_crash_and_quoting.ahk
#Include meta/test_hotpath_priority_starvation.ahk
#Include meta/test_priority_baseline_single_source.ahk

; -- Previously-orphaned regression tests (on disk but never wired into the
;    runner; re-wired so they actually execute). All were silently skipped; the
;    four that "failed" turned out to be test bugs (wrong A_ScriptDir-relative
;    path, first-call-vs-definition match, elapsed- vs deadline-form poll, a
;    comment tripping a substring guard), not real code regressions — fixed. --
#Include meta/test_bypass_dispatch_arity.ahk
#Include meta/test_hcw_reset_all_teardown.ahk
#Include meta/test_healthcheck_sysinfo_git_nonblocking.ahk
#Include meta/test_keylogger_pause_metrics.ahk
#Include meta/test_processentry32w_size.ahk
#Include meta/test_script_altgr_hotkeys.ahk
#Include meta/test_space_hold_exception_guard.ahk
#Include meta/test_stream_handle_type.ahk
#Include meta/test_warmup_backoff_preserved.ahk
#Include meta/test_wpm_menubar_dead_code_removed.ahk
; These three were orphaned with their own (duplicate or pure-scan) includes;
; the duplicate test_framework.ahk includes were stripped so they integrate.
#Include meta/test_dpapi_blob_size.ahk
#Include meta/test_llm_diff_french_accents.ahk
; LLM render must clear the dequeue state before rendering (llm-render-clears-dequeue).
#Include meta/test_llm_render_clears_dequeue.ahk
#Include unit/test_audit_v5_fixes.ahk
; Healthcheck pure formatters (uptime / HTML-escape) — coverage preserved from
; the deleted P5-stale test_session_regressions orphan. helpers.ahk is
; headless-safe (function definitions only, no top-level side effects).
#Include ../ui/healthcheck/core.ahk
#Include ../ui/healthcheck/helpers.ahk
#Include meta/test_healthcheck_format_helpers.ahk

; Guards the _HsEdWeb_Reset() idempotency fix for the live-log access-violation
; crash (double-unsubscribe against an already torn-down WebView2 controller).
#Include meta/test_hsedweb_reset_idempotent.ahk

; Same idempotency-guard shape, verified in the 6 sibling WebView2 hosts that
; got the identical F7 fix applied.
#Include meta/test_webview_reset_idempotent_siblings.ahk
#Include meta/test_updater_onjson_callback_catch.ahk
#Include meta/test_webview_bridge_suspend_guard.ahk
#Include meta/test_changelog_close_order.ahk
#Include meta/test_updater_changelog_install_closegui.ahk
; MCSetPos/MCGetPos bare-try-no-catch fix (F32).
#Include meta/test_mouse_control_error_logging.ahk
; TooltipRHide bare-try-no-catch + TooltipRShow OutputDebug-instead-of-Logger fix (F50).
#Include meta/test_tooltip_renderer_error_logging.ahk
; WMGetList/WIGetAll bare-try-no-catch fix (F33) — sibling of the
; GestureGetCyclableWindows TOCTOU guard (commit 7b701020d).
#Include meta/test_window_adapters_catch.ahk
#Include meta/test_onbweb_singleton_guard.ahk
#Include meta/test_reset_config_writes_meta_placeholder.ahk
#Include meta/test_webview_shared_env_reentrancy_guard.ahk
#Include meta/test_webview_host_callback_epoch.ahk
; AltTabMonitor bare-try-no-catch fix (F37) — sibling of the
; GestureGetCyclableWindows TOCTOU guard (commit 7b701020d).
#Include meta/test_alt_tab_monitor_catch.ahk
#Include meta/test_metrics_shortcut_persist_guard.ahk
#Include meta/test_metrics_shortcut_transaction.ahk
#Include meta/test_metrics_app_time_accuracy.ahk
#Include meta/test_toggle_category_all_features_atomic.ahk
#Include meta/test_crypto_djb2_fallback_logged.ahk
#Include meta/test_adapter_callback_swallow_logged.ahk
#Include meta/test_llm_callbacks_never_swallowed.ahk
#Include meta/test_llm_inflight_hygiene.ahk
#Include meta/test_llm_semantic_config_class.ahk
#Include meta/test_wpm_widget_consistency.ahk
#Include meta/test_marker_and_heatmap_completeness.ahk
#Include meta/test_text_send_direct_mode_guarded.ahk
#Include meta/test_http_post_reentrancy_guard.ahk
#Include meta/test_personal_editor_autoexpand_i18n.ahk
#Include meta/test_jsstr_cr_escaped.ahk
#Include meta/test_json_string_literal_single_source.ahk
#Include meta/test_json_string_decoder_single_source.ahk
#Include meta/test_toml_string_codec_single_source.ahk
#Include meta/test_onboarding_gesture_msgbox_zorder.ahk
#Include meta/test_ui_style_llm_tray_i18n.ahk
#Include meta/test_ollama_webview_msgsub_retained.ahk
#Include meta/test_open_downloads_catch.ahk
#Include meta/test_takenote_winmaximize_guard.ahk
#Include meta/test_personal_info_combo_generation.ahk
#Include meta/test_personal_combo_letters_guard.ahk
#Include meta/test_driver_pid_single_source.ahk
#Include meta/test_taphold_timings_load_order.ahk
#Include meta/test_suspend_resets_hse_context.ahk
#Include meta/test_capsword_parse_time_callback.ahk
#Include meta/test_config_shortcuts_inline_comment.ahk
#Include meta/test_savefullconfig_llm_loaded_gate.ahk
#Include meta/test_single_instance_mutex_first.ahk
#Include meta/test_master_gate_drifted_subgate_skip.ahk
#Include meta/test_rctrl_lalt_hotif_gated.ahk
#Include meta/test_prefix_keydown_ctrl_backspace_reset.ahk
#Include meta/test_prefix_index_rebuild_suspend_replay.ahk
#Include meta/test_suspend_transition_serialized.ahk
#Include meta/test_wrap_selection_clip_fallback.ahk
#Include meta/test_uia_selection_poll_boot_gated.ahk
#Include meta/test_tap_hold_synthetic_up_suspend_guard.ahk
#Include meta/test_menu_delay_prompt_rebuild.ahk
#Include meta/test_gesture_edit_shortcuts_no_reload.ahk
#Include meta/test_gesture_screenshot_instant_completion.ahk
#Include meta/test_live_rebuild_no_critical_io.ahk
#Include meta/test_metrics_focus_refresh_suspend_guard.ahk
#Include meta/test_llm_loading_tooltip_no_safety_deadline.ahk
#Include meta/test_onboarding_gesture_result_token.ahk
#Include meta/test_suspend_prefix_drain_covers_all_combos.ahk
#Include meta/test_audit_2026_07_20_batch2.ahk
#Include meta/test_audit_2026_07_20_hotstrings.ahk
#Include meta/test_audit_2026_07_20_batch3.ahk
#Include meta/test_audit_2026_07_20_webview.ahk
#Include meta/test_audit_2026_07_20_batch4.ahk
#Include meta/test_wrap_symbols_load_flush.ahk
#Include unit/test_wrap_symbols_unreadable_blocks_save.ahk
#Include unit/test_unreadable_config_never_persisted.ahk
#Include meta/test_app_picker_sort_safe_selection.ahk
#Include meta/test_changelog_ready_not_stranded.ahk
#Include meta/test_hcw_bulk_writers_republish.ahk
#Include meta/test_hcw_patch_toml_meta_refuses_unread_file.ahk
#Include meta/test_healthcheck_singleton_destroys_window.ahk
#Include meta/test_ingest_offset_respects_batch_limit.ahk
#Include meta/test_kl_payload_privacy_filter.ahk
#Include meta/test_kl_stop_shutdown_ingest_forced.ahk
#Include meta/test_keylogger_shutdown_timer_durability.ahk
#Include meta/test_llm_finalize_guard_before_yield.ahk
#Include meta/test_llm_indexed_callbacks_never_swallowed.ahk
#Include meta/test_llm_model_menu_no_model_row_actionable.ahk
#Include meta/test_llm_profile_menu_unique_labels.ahk
#Include meta/test_locale_tsv_atomic_write.ahk
#Include meta/test_menu_manifest_single_decode.ahk
#Include meta/test_menu_prune_keeps_detached_registrations.ahk
#Include meta/test_metrics_filter_secure_field_fails_closed.ahk
#Include meta/test_nav_layer_lalt_capslock_group_gate.ahk
#Include meta/test_network_info_single_wlan_roundtrip.ahk
#Include meta/test_onboarding_unbraced_if_scope.ahk
#Include meta/test_personal_info_save_surfaces_failure.ahk
#Include meta/test_remote_curl_forwards_usage_meta.ahk
#Include meta/test_remote_token_not_on_argv.ahk
#Include meta/test_secure_field_native_detect_conclusive_order.ahk
#Include meta/test_secure_field_probes_focused_element.ahk
#Include meta/test_secure_field_stale_verdict_fails_closed.ahk
#Include meta/test_secure_field_uia_probe_guards.ahk
#Include meta/test_today_bucket_slots_all_fed.ahk
#Include meta/test_tooltip_expiry_anchored_at_request.ahk
#Include meta/test_tooltip_expiry_timers_keep_preview.ahk
#Include meta/test_tooltip_uia_gate_reachable.ahk
#Include meta/test_uia_wrap_resets_both_buffers.ahk
#Include meta/test_updater_releases_list_cancellable.ahk
#Include meta/test_updater_worker_terminated_on_exit.ahk
#Include meta/test_webview_reset_guard_class.ahk
#Include meta/test_wpm_graph_mode_draggable.ahk
#Include meta/test_wpm_rebuilt_surface_is_sized.ahk
#Include unit/test_activate_hotstrings_commits_synchronously.ahk
#Include unit/test_cache_builder_strips_header_comment.ahk
#Include unit/test_bundle_skip_validation.ahk
#Include unit/test_clipboard_history_paste.ahk
#Include unit/test_changelog_request_epoch.ahk
#Include unit/test_config_toml_single_writer.ahk
#Include unit/test_derived_toml_caches_not_memoised_on_failed_read.ahk
#Include unit/test_fire_log_callable_replacement.ahk
#Include unit/test_fire_log_suspend_boundary.ahk
#Include unit/test_group_config_cache_alias_invalidation.ahk
#Include unit/test_hotpath_profiler_exclusive.ahk
#Include unit/test_hotpath_per_segment_threshold.ahk
#Include unit/test_keylogger_today_fh_flush.ahk
#Include unit/test_llm_cache_hit_logs_suggested.ahk
#Include unit/test_llm_keep_alive_from_shared_defaults.ahk
#Include unit/test_llm_parser_refuses_uninjectable_deletes.ahk
#Include unit/test_logger_preinit_level.ahk
#Include unit/test_logger_set_level_transaction.ahk
#Include unit/test_logger_sub_files_multiline_arrays.ahk
#Include unit/test_marker_substituted_in_replacement.ahk
#Include unit/test_master_gates_not_persisted.ahk
#Include unit/test_parse_toml_file_sticky_unreadable.ahk
#Include unit/test_personal_info_unreadable_never_persisted.ahk
#Include unit/test_personal_read_clears_unreadable_latch.ahk
#Include unit/test_personal_reload_bakes_resolved_delay.ahk
#Include unit/test_prefetch_apps_list_deduped.ahk
#Include unit/test_prefetch_dbg_write_level_gated.ahk
#Include unit/test_preview_picks_engine_winner.ahk
#Include unit/test_priority_missing_defaults_to_common.ahk
#Include unit/test_preview_uses_by_trigger_index.ahk
#Include unit/test_repeat_key_honours_rebuild_fence.ahk
#Include unit/test_shell_runner_legacy_state_machine.ahk
#Include unit/test_shell_runner_multiline_arg.ahk
#Include unit/test_shell_runner_tree_owned.ahk
#Include unit/test_crash_report_worker_transport.ahk
#Include unit/test_taphold_inherit_defaults_roundtrip.ahk
#Include unit/test_taphold_synthetic_refcount_combo.ahk
#Include unit/test_taphold_unreadable_blocks_rewrite.ahk
#Include unit/test_tap_hold_global_transaction_20260813.ahk
#Include unit/test_tooltip_row_band_elision.ahk
#Include meta/test_boot_profile_retroactive_stamps.ahk
#Include meta/test_clipboard_history_paste_wiring.ahk
#Include meta/test_fast_timer_inventory.ahk
#Include meta/test_gestures_bulk_actions_ahk_reachable.ahk
#Include meta/test_gesture_constants_available_to_onboarding.ahk
#Include meta/test_hotpath_segment_coverage.ahk
#Include meta/test_llm_health_probe_constants.ahk
#Include meta/test_menu_manifest_one_decoder.ahk
#Include meta/test_menu_reload_preserves_suspend.ahk
#Include meta/test_menu_shortcut_groups_spliced_once.ahk
#Include meta/test_metrics_private_title_memo.ahk
#Include meta/test_ollama_async_registry_is_curl_only.ahk
#Include meta/test_personal_save_rebuilds_preview_index.ahk
#Include meta/test_taphold_hold_gate_arms_without_tap.ahk
#Include meta/test_tooltip_debounce_is_load_bearing.ahk
#Include meta/test_tooltip_present_subsegmented.ahk
#Include meta/test_tooltip_render_accounting.ahk
#Include meta/test_tray_suspend_checkmark_survives_rebuild.ahk
#Include meta/test_uia_clamp_every_probe_site.ahk
#Include meta/test_uia_poll_segment_bounded.ahk
#Include meta/test_hcw_reset_all_republishes.ahk
#Include meta/test_llm_inline_autotype_staleness.ahk
#Include meta/test_walker_batch_has_an_inprocess_drain.ahk
#Include unit/test_walker_title_cap_enforced.ahk
#Include meta/test_boot_profile_retroactive_stamps.ahk
#Include meta/test_fast_timer_inventory.ahk
#Include meta/test_hotpath_segment_coverage.ahk
#Include meta/test_tooltip_debounce_is_load_bearing.ahk
#Include meta/test_tooltip_present_subsegmented.ahk
#Include meta/test_tooltip_render_accounting.ahk
#Include meta/test_uia_clamp_every_probe_site.ahk
#Include meta/test_boot_profile_retroactive_stamps.ahk
#Include meta/test_hotpath_segment_coverage.ahk
#Include meta/test_tooltip_debounce_is_load_bearing.ahk
#Include meta/test_tooltip_present_subsegmented.ahk
#Include meta/test_tooltip_render_accounting.ahk
#Include meta/test_uia_clamp_every_probe_site.ahk
#Include meta/test_boot_profile_retroactive_stamps.ahk
#Include meta/test_hotpath_segment_coverage.ahk
#Include meta/test_uia_clamp_every_probe_site.ahk
#Include meta/test_boot_profile_retroactive_stamps.ahk
#Include meta/test_uia_clamp_every_probe_site.ahk
#Include meta/test_boot_profile_retroactive_stamps.ahk
#Include meta/test_suite_watchdog_manifest.ahk

; Watchdog: kill the process if RunTests() never returns (e.g. a corpus
; consumer blocks on a synchronous HTTP call, an InputHook with no timeout,
; or a blocking dialog in a headless CI context). The current corpus normally
; uses a small fraction of this per-test budget; the cap remains three minutes
; below CI's 25-minute process timeout so partial TAP can still be validated.
global _SUITE_STARTUP_BUDGET_MS := 120000
global _SUITE_PER_TEST_BUDGET_MS := 200
global _SUITE_MAX_TIMEOUT_MS := 1320000
global _SUITE_TIMEOUT_MS := Min(_SUITE_MAX_TIMEOUT_MS,
	_SUITE_STARTUP_BUDGET_MS + TEST_REGISTRY.Length * _SUITE_PER_TEST_BUDGET_MS)
_WatchdogFire() {
	; Preserve the exact partial execution list before force-exiting. The CI
	; validator rejects any missing RUNNING/result pair.
	try _CopyTestResultsForCi()
	try FileAppend("`n[WATCHDOG] Test suite timed out after " . _SUITE_TIMEOUT_MS . " ms - force-exiting.`n", "*")
	ExitApp(2)
}
SetTimer(_WatchdogFire, -_SUITE_TIMEOUT_MS)

; Drive everything. RunTests prints a TAP-style report to stdout and exits
; with the appropriate code — control never returns from this call.
RunTests()
