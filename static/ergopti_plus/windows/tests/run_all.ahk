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
; Same policy as ErgoptiPlus.ahk: #Warn covers the whole compilation unit and
; the vendored UIA.ahk shadows globals on purpose. Every other warning class
; stays on and fails the CI compiler-warning gate.
#Warn LocalSameAsGlobal, Off
; Parse runner flags:
;   --dry-run        parse/load gate only — register every test, skip execution.
;   --interactive    explicitly allow tests that activate windows or inject keys.
;   --only <substr>  run only tests whose name contains <substr> (case-insensitive),
;                    e.g. AutoHotkey64.exe run_all.ahk --only "(my-slug)" to replay
;                    a single failing test without the whole suite.
;   --module=<group> run only one module group (TEST_MODULE_GROUPS in
;                    test_framework.ahk); the CI runs one group per runner.
;   --list=<file>    run only the tests named in <file>, one per line, in
;                    registry order whatever the file's order; add --reverse
;                    to replay the predecessors of a reversed run.
;   --dump-plan=<f>  append "group<TAB>file<TAB>name" for each selected test.
;   --reverse        run the selected tests backwards to expose tests that rely
;                    on state an earlier test left behind.
; Reject malformed options before includes can initialize tests or input hooks.
_RejectRunnerArguments(Message) {
	FileAppend("Invalid test runner arguments: " . Message . "`n", "**")
	ExitApp(2)
}

global _AHK_DRY_RUN := false
global _AHK_ONLY_FILTER := ""
global _AHK_INTERACTIVE := false
global _AHK_QUALIFICATION_PROFILE := ""
global _AHK_MODULE := ""
global _AHK_LIST_FILE := ""
global _AHK_DUMP_PLAN := ""
global _AHK_REVERSE := false
_riArgIndex := 1
while (_riArgIndex <= A_Args.Length) {
	_riArg := A_Args[_riArgIndex]
	if (_riArg == "--dry-run")
		_AHK_DRY_RUN := true
	else if (_riArg == "--interactive")
		_AHK_INTERACTIVE := true
	else if (_riArg == "--reverse")
		_AHK_REVERSE := true
	else if (SubStr(_riArg, 1, 24) == "--qualification-profile=") {
		if _AHK_QUALIFICATION_PROFILE != ""
			_RejectRunnerArguments("--qualification-profile may be supplied only once")
		_AHK_QUALIFICATION_PROFILE := SubStr(_riArg, 25)
		if _AHK_QUALIFICATION_PROFILE == ""
			_RejectRunnerArguments("--qualification-profile requires a non-empty id")
	}
	else if (SubStr(_riArg, 1, 9) == "--module=") {
		if _AHK_MODULE != ""
			_RejectRunnerArguments("--module may be supplied only once")
		_AHK_MODULE := SubStr(_riArg, 10)
		if !RegExMatch(_AHK_MODULE, "^[a-z][a-z0-9-]*$")
			_RejectRunnerArguments("--module requires a group name")
	}
	else if (SubStr(_riArg, 1, 7) == "--list=") {
		if _AHK_LIST_FILE != ""
			_RejectRunnerArguments("--list may be supplied only once")
		_AHK_LIST_FILE := SubStr(_riArg, 8)
		if !FileExist(_AHK_LIST_FILE)
			_RejectRunnerArguments("--list requires an existing file")
	}
	else if (SubStr(_riArg, 1, 12) == "--dump-plan=") {
		if _AHK_DUMP_PLAN != ""
			_RejectRunnerArguments("--dump-plan may be supplied only once")
		_AHK_DUMP_PLAN := SubStr(_riArg, 13)
		if _AHK_DUMP_PLAN == ""
			_RejectRunnerArguments("--dump-plan requires a path")
	}
	else if (_riArg == "--only" || SubStr(_riArg, 1, 7) == "--only=") {
		if StrLen(_AHK_ONLY_FILTER) > 0
			_RejectRunnerArguments("--only may be supplied only once")
		if (_riArg == "--only") {
			if (_riArgIndex >= A_Args.Length)
				_RejectRunnerArguments("--only requires a non-empty filter")
			_riArgIndex += 1
			_AHK_ONLY_FILTER := A_Args[_riArgIndex]
			if (SubStr(_AHK_ONLY_FILTER, 1, 2) == "--")
				_RejectRunnerArguments("a filter starting with -- requires the --only= form")
		} else
			_AHK_ONLY_FILTER := SubStr(_riArg, 8)
		if (Trim(_AHK_ONLY_FILTER, " `t`r`n") == "")
			_RejectRunnerArguments("--only requires a non-empty filter")
	} else
		_RejectRunnerArguments("unknown option or unexpected positional argument")
	_riArgIndex += 1
}

; Test framework first — Assert / Test / RunTests must exist before any
; subsequent file registers its cases or invokes assertions inside lambdas.
#Include test_framework.ahk
; Acquire the selected receipt before any bootstrap observation or test include.
_TestResultsBeginRun()

; AppState — must come before test_stubs.ahk because the stubs reference
; AppState fields directly, and before any infra/ file that reads AppState.
#Include ../core/lifecycle/engine/app_state.ahk
#Include support/native_cli_diagnostics.ahk
#Include support/receiving_profile.ahk

; Stubs second — they define ScriptInformation, Features, SendNewResult,
; WrapTextIfSelected, DeadKey, ToggleCapsLock, etc., which infra/ files
; reference at definition (Bind) time or at call time during tests.
#Include test_stubs.ahk
#Include ../metrics/engine/system/health.ahk

; Install a very early error handler for top-level / #Include phase errors.
; When a newly added production module (LLM, gestures, keystats, prompt builder,
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
	global TEST_RESULTS_FILE
	try _TestResultsWrite(TEST_RESULTS_FILE, msg . "`r`n")
	try FileAppend(msg . "`r`n", "**")
	try FileAppend(msg . "`r`n", "*")
    ExitApp(1)
    return 1
}
OnError(_FatalErrorHandler)

; ── Production lib files in dependency order ──
#Include ../core/logger/engine/tick_count.ahk
#Include ../vendor/Promise.ahk
#Include ../core/ui/engine/webview/utils.ahk
#Include ../diagnostics/ui/console_window.ahk
#Include ../core/logger/engine/wall_clock.ahk
#Include ../diagnostics/engine/field_run/field_run.ahk
; Compiled-mode bundle bootstrapper — included this early (matching its real
; position right after app_state.ahk in ErgoptiPlus.ahk) so its functions are
; actually exercised by meta/core/lifecycle/engine/test_bundle_resolve_dir_local_appdata.ahk instead
; of only being scanned as raw text. Bundle_Init() itself is never called here
; (A_IsCompiled is false in the test runner, and it would ExitApp on failure
; anyway) — only its pure helpers (_Bundle_ResolveDir, ResolveLocalAppDataDir)
; are invoked directly by the regression test.
#Include ../core/lifecycle/engine/bundle.ahk
#Include ../tray/bootstrap.ahk
#Include ../tray/adapters/startup_click.ahk
#Include ../tray/adapters/startup_commands.ahk
#Include ../core/lifecycle/engine/reload/single_instance_gate.ahk
#Include ../ai/ui/menu/build_coordinator.ahk
#Include ../_generated/window_titles.ahk
#Include ../core/ui/engine/native_dialogs.ahk
#Include ../core/ui/engine/style.ahk
#Include ../_generated/logger_sub_files.ahk
#Include ../_generated/app_dirs.ahk
#Include ../apps/engine/folders.ahk
#Include ../settings/engine/migration/legacy_folder_migration.ahk
#Include ../core/logger/engine/logger.ahk
; The logs folder every logger test writes to: a private temp folder, never the
; user's real %LOCALAPPDATA%\Ergopti\logs\ (boot.ahk sets it in the driver). It
; ends in the application folder name, as a resolved LogsDirPath always does.
global _LogsDir := A_Temp . "\ergopti_test_logs\" . AppDirsFolderName() . "\"
global _DefaultLogsDir := _LogsDir
; Boot stage profiler and the cross-driver diagnostic snapshot: definitions and
; two counters only, exercised by unit/diagnostics/ui/healthcheck/test_logging.ahk.
#Include ../core/logger/engine/boot_profiler.ahk
#Include ../diagnostics/engine/field_run/startup_smoke.ahk
#Include ../diagnostics/engine/reports/snapshot.ahk
#Include ../diagnostics/engine/reports/issue_link.ahk
#Include ../diagnostics/engine/reports/redact.ahk
#Include ../diagnostics/engine/reports/issue_report.ahk
#Include ../diagnostics/engine/reports/error_policy.ahk
#Include ../diagnostics/engine/reports/error_report.ahk
#Include ../core/text/engine/toml/helpers.ahk
; Shared timing registry reader (TimingsLoadShared / TimingsGet) — needs
; ParseTomlFile above; exercised by test_timings_config.ahk.
#Include ../core/timing/engine/config.ahk

#Include ../core/ui/engine/window_utils.ahk
#Include ../core/network/engine/external_url_policy.ahk
#Include ../core/ui/ui/tooltip/position_receipt.ahk
#Include ../core/text/engine/utils.ahk
#Include ../hotstrings/engine/text_case.ahk
#Include ../keyboard/engine/wrap_pair.ahk
#Include ../infra/open_target.ahk
#Include ../settings/engine/send_input_parameter.ahk
#Include ../keyboard/engine/tap_keys.ahk
#Include ../keyboard/engine/keys/combinations.ahk
#Include ../keyboard/engine/layers/nav_layer_helpers.ahk
#Include ../hotstrings/engine/matcher/engine.ahk
#Include ../keyboard/engine/keys/altgr_family.ahk
#Include ../hotstrings/engine/matcher/engine_main.ahk
#Include ../hotstrings/engine/matcher/buffer_effects.ahk
#Include ../hotstrings/engine/matcher/live_toggle.ahk
#Include ../hotstrings/engine/matcher/count_policy.ahk
#Include ../hotstrings/engine/matcher/prefix_watcher.ahk
#Include ../core/lifecycle/engine/master_gates.ahk
; Generated terminator catalogue (shared single source) — exercised by
; test_terminators.ahk and consumed by the tray / config-window delimiter menus.
#Include ../_generated/terminators.ahk
#Include ../core/text/engine/toml/loader.ahk
#Include ../hotstrings/engine/catalogue/extension_packs.ahk
#Include ../hotstrings/engine/catalogue/cache.ahk
#Include ../core/text/engine/toml/config_loader.ahk
#Include ../settings/engine/migration/migrate.ahk
#Include ../../_shared/settings/data/outdated.ahk
#Include ../platform/remap/tap_hold_loader.ahk
#Include ../platform/remap/tap_hold_writer.ahk
; The layer-file loader reads _shared/layouts/data and the physical-key registry at run
; time; meta/corpus/test_corpus_keymap_layers.ahk replays the cross-driver corpus through it.
#Include ../keyboard/engine/layers/loader.ahk
; The navigation layer's hotkey table, built from layer files; registration is
; injectable, so unit/keyboard/engine/layers/test_nav_layer_table.ahk drives it without a live hook.
#Include ../keyboard/engine/layers/nav_layer_table.ahk
; The layer editor host: validation, the atomic save and the page's messages,
; driven by unit/hotstrings/engine/expander/test_layer_editor_host.ahk without a WebView.
#Include ../layouts/ui/layer_editor.ahk
#Include ../ui/physical_shortcuts/init.ahk
#Include ../ui/menu/menu_taphold.ahk
; The hotstring gate and « all sections » rows, built over the live Features.
#Include ../hotstrings/ui/menu/switches.ahk
; The whole tree's path collector and tick, which the bulk hotstring writer in
; settings/engine/io.ahk calls. Definitions only; the category tables they read are
; declared by menu/ui/tray_menu.ahk, which is not loaded, so a test supplies them.
#Include ../menu/ui/builder/submenus.ahk
#Include ../_generated/features_manifest.ahk
#Include ../menu/engine/manifest_reader.ahk
; Native manifest-built menu rows use the same pure label owner as tray boot.
#Include ../menu/engine/manifest_descriptions.ahk
; The dynamic-hotstring module, for its pure helpers (SpacedPrefix, the three
; date formatters). Definitions only — _DynHS_RegisterAll() is not called here,
; so no registration happens at harness load.
#Include ../hotstrings/engine/dynamic/hotstrings.ahk
#Include ../hotstrings/engine/dynamic/user_code.ahk
#Include ../settings/engine/preferences/feature_io.ahk
; EnsurePersonalHotstringFeature is exercised directly by the F4 regression
; test (test_feature_io_locator.ahk) — RegisterPersonalFeature in the same file
; is never called here, so its own unseeded global (_PersonalShortcutsRegistry)
; is harmless (#Warn VarUnset is off).
#Include ../settings/engine/preferences/personal_features.ahk
#Include ../hotstrings/engine/catalogue/config.ahk
#Include ../core/lifecycle/engine/reload/suspend_handoff.ahk
#Include ../core/lifecycle/engine/reload/terminal_handoff.ahk
#Include ../core/lifecycle/engine/reload/successor.ahk
#Include ../core/lifecycle/engine/dev_source.ahk
#Include ../core/lifecycle/engine/reload/deferral.ahk
#Include ../keyboard/engine/suppressive_inputhook_ownership.ahk
#Include ../core/lifecycle/engine/transition.ahk
#Include ../settings/engine/migration/transition.ahk
#Include ../settings/engine/migration/transition_runtime.ahk
; _CollectFeatureUpdates is exercised directly by the section-resolution
; regression tests (test_config_io_feature_section_resolution.ahk).
; SaveFullConfig itself is never invoked here (it depends on numerous
; boot-only globals), so including this file is safe — only function
; definitions at top level.
#Include ../settings/engine/io.ahk
#Include ../settings/engine/scope/scope.ahk
#Include ../../_shared/hotstrings/data/catalogue/scope_overrides.ahk
#Include ../hotstrings/engine/catalogue/scope.ahk
#Include ../settings/engine/scope/global_scope.ahk
#Include ../hotstrings/ui/personal_toml_editor.ahk
#Include ../hotstrings/ui/personal_toml_editor_webview.ahk
; Pure helpers (no boot-time side effects) — CountDynamicSection is exercised
; by the dynamic-hotstrings corpus parity test.
#Include ../menu/engine/helpers.ahk
; Definitions-only live rebuild coordinator/menu helpers. No tray mutation is
; performed until a test explicitly invokes an injected rebuild body.
#Include ../menu/ui/builder/rebuild.ahk
; Wrap-symbols persistence: globals and function definitions only, no top-level
; side effects, so it loads headlessly. Included so the load/save data-loss
; guard (test_wrap_symbols_unreadable_blocks_save.ahk) can drive the real
; functions instead of scanning their source.
#Include ../keyboard/engine/wrap_symbols_config.ahk
#Include ../layouts/engine/registry/altgr.ahk
#Include ../layouts/engine/registry/ergopti.ahk
#Include ../layouts/engine/accented_shortcuts.ahk
#Include ../../_shared/settings/data/features/number_row_policy.ahk
#Include ../../_shared/settings/data/features/layout_rows_policy.ahk
#Include ../../_shared/settings/data/features/caps_word_auto_off_policy.ahk
#Include ../../_shared/settings/data/features/pause_switch_policy.ahk
#Include ../layouts/engine/registry/shift_caps.ahk
#Include ../layouts/engine/emulation/number_row_send.ahk
; Registry layout emulation: definitions only (the hotkeys are registered by
; KeylayoutEmulation_Register, which the tests call with injected registrars).
#Include ../layouts/engine/keylayout/parser.ahk
#Include ../layouts/engine/keylayout/tables.ahk
#Include ../layouts/engine/keylayout/emulation.ahk
#Include ../layouts/engine/keylayout/source_emulation.ahk
#Include ../layouts/engine/keylayout/registry.ahk
#Include ../layouts/engine/keylayout/catalogue.ahk
#Include ../layouts/engine/keylayout/extension.ahk
; Pure layout-poll quiescence decision (no OS deps, no top-level hotkeys) —
; exercised by meta/layouts/test_quiescence.ahk and consumed by ErgoptiPlus.ahk.
#Include ../layouts/engine/registry/poll_helper.ahk
#Include ../layouts/engine/registry/watch.ahk
#Include ../layouts/engine/emulation/pause_layout_switch.ahk
#Include ../layouts/engine/system_layout_install.ahk
#Include ../core/ui/ui/tooltip/init.ahk
#Include ../core/ui/adapters/tooltip_renderer.ahk
#Include ../modules/updater.ahk
#Include ../core/lifecycle/engine/shutdown/uninstall.ahk
#Include ../infra/start_at_login.ahk
; json.ahk must precede locale.ahk — _I18nLoadLocaleMap delegates to JsonParse.
#Include ../settings/engine/registry.ahk
#Include ../core/text/engine/json.ahk
; Keep the standalone assertion library independent of production JSON symbols.
TestQualificationRegisterParser(JsonParse)
#Include ../settings/engine/program_parameter.ahk
#Include ../core/process/adapters/program_providers.ahk
#Include ../ui/action_picker_webview.ahk
#Include ../infra/program_actions.ahk
#Include ../infra/user_actions.ahk
#Include ../keyboard/engine/layers/sticky_modifiers.ahk
#Include ../../_shared/core/network/data/failure.ahk
#Include ../core/network/adapters/failure_host.ahk
#Include ../ui/download_window/session.ahk
#Include ../ui/download_window/init.ahk
; locale.ahk (string loading + t()) is included here because gestures.ahk calls
; t() at the top level when building GESTURE_SLOT_LABELS; without it the process
; blocks on an AHK runtime-error MsgBox and the CI job times out. i18n.ahk (locale
; management) follows it and calls into the loaders/state it declares.
#Include ../core/i18n/engine/locale.ahk
#Include ../_generated/gesture_emit_actions.ahk
#Include ../_generated/action_catalogue.ahk
#Include ../_generated/locale_table.ahk
#Include ../core/i18n/engine/i18n.ahk
_LogBootProgress("i18n included (t() available)")

; Install the hotstring hooks for the entire test process so neither real
; ``Hotstring()`` registrations nor real ``SendEvent`` keystrokes ever escape
; into the CI environment. Stubs that need raw send semantics still observe
; UpdateLastSentCharacter (the hook only intercepts the lower-level emission).
InstallHotstringHooks()

; ── Adapter contract: include all port adapters so contract vector tests can call them ──
#Include ../platform/system/notifier.ahk
#Include ../core/lifecycle/engine/shutdown/quit_admission.ahk
#Include ../core/events/timer_scheduler.ahk
#Include ../core/fs/adapters/file_system.ahk
#Include ../platform/focus/window_info.ahk
#Include ../core/process/adapters/uia_worker.ahk
#Include ../tray/adapters/menu.ahk
#Include ../platform/input/text_sender.ahk
#Include ../core/network/adapters/http_client.ahk
#Include ../platform/focus/secure_field_detector.ahk
#Include ../clipboard/adapters/clipboard.ahk
#Include ../diagnostics/engine/field_run/input_probe.ahk
#Include ../core/fs/adapters/storage.ahk
#Include ../core/process/adapters/lifecycle.ahk
#Include ../platform/input/key_state.ahk
#Include ../layouts/adapters/keyboard_layout_switch.ahk
#Include ../apps/adapters/launcher.ahk
#Include ../core/crypto/crypto.ahk
; The bundled App Cloner and Encryptor: definitions only (their entry runs nothing at load).
#Include ../apps/adapters/bundled_apps_native.ahk
#Include ../apps/strings.ahk
#Include ../apps/encryptor_core.ahk
#Include ../apps/cloner_core.ahk
#Include ../apps/bundled_apps.ahk
#Include ../core/network/adapters/info.ahk
#Include ../platform/focus/window_manager.ahk
#Include ../platform/system/control.ahk
#Include ../adapters/mouse_control.ahk
#Include ../core/ui/adapters/graphics_renderer.ahk
#Include ../tray/adapters/notify_icon.ahk
#Include ../core/ui/ui/spotlight/ownership.ahk
#Include ../core/process/adapters/shell_runner.ahk
#Include ../../_shared/shortcuts/data/actions/brightness.ahk
#Include ../adapters/screen_brightness.ahk
#Include ../diagnostics/adapters/crash_report_worker.ahk
#Include ../diagnostics/engine/reports/crash_reporter.ahk
#Include ../diagnostics/engine/reports/error_net.ahk
#Include ../hotstrings/engine/expander/uia_selection_worker.ahk
; Contract tests must not launch a provider against the user's foreground app.
; Worker behavior is covered separately with explicit owned-process fixtures.
SFD_ConfigureUiaWorker(
	(Context, Terminal) => false, () => false, UIASW_ContextMatches)
; Unified input-hook dispatcher + keyboard_hook adapter. hook_dispatcher.ahk
; defines only classes at top level (no hotkeys), so it is safe in the headless
; runner; keyboard_hook.ahk registers/unregisters its subscribers through it.
; Exercised by test_hook_dispatcher.ahk (BoundFunc identity + bind-once contract).
#Include ../platform/input/hook_dispatcher.ahk
; CapsWord auto-off listeners: definitions only (capsword.ahk, with its
; hotkeys, stays out of the runner; the stubs stand in for DisableCapsWord).
#Include ../modules/shortcuts/capsword_auto_off.ahk
#Include ../keyboard/engine/capsword_state.ahk
#Include ../platform/input/keyboard_hook.ahk
#Include ../core/ui/ui/editors.ahk

; Lock _AHK_SendText / _AHK_SendInput to no-ops AFTER the adapter has been
; included (the adapter sets them to real lambdas; InstallSendNoOps overwrites
; them so no keystroke can escape into the OS during test execution).
InstallSendNoOps()

; ── Per-module test files (each registers Test() cases) ──
#Include unit/platform/system/test_adapter_compliance.ahk
#Include unit/core/fs/test_ports.ahk
#Include unit/settings/engine/persistence/test_feature_io_locator.ahk
#Include meta/settings/persistence/test_feature_io_impl_no_global.ahk
#Include meta/suite/test_isset_no_property_arg.ahk
#Include unit/platform/system/test_adapter_contract_vectors.ahk
#Include unit/platform/system/test_adapter_contract_vectors_system.ahk
#Include unit/platform/input/test_clipboard_paste_transaction_ownership.ahk
#Include unit/platform/input/test_selection_capture_receiving.ahk
#Include unit/platform/input/test_suppressive_inputhook_ownership.ahk
; Runs startup/siho_boot_window_smoke.ahk as a child process. That harness is
; deliberately NOT included here: it must observe the state before the module's
; own include executes, which is unreachable inside this runner, and its
; top-level ExitApp would end the suite.
#Include unit/core/lifecycle/engine/test_siho_boot_window.ahk
#Include unit/core/ui/windows/test_manager_force_foreground.ahk
#Include unit/core/ui/windows/test_manager_present_window.ahk
#Include unit/core/ui/windows/test_native_dialog_titles.ahk
#Include unit/core/ui/windows/test_native_file_filter_behavior.ahk
#Include unit/core/ui/windows/test_native_folder_orchestration.ahk
#Include unit/core/ui/windows/test_native_file_filter_diagnostics.ahk
#Include unit/diagnostics/adapters/test_console_window.ahk
#Include unit/layouts/test_keyboard_layout_switch.ahk
#Include unit/apps/test_launcher_native_targets.ahk
#Include unit/core/ui/windows/test_spotlight_ownership.ahk
#Include unit/gestures/engine/test_take_note_async_job.ahk
#Include unit/gestures/engine/test_take_note_counted_nul.ahk
#Include unit/gestures/engine/test_takenote_pause_lifecycle_owner.ahk
#Include unit/gestures/engine/test_system_action_lifecycle_timer.ahk
#Include unit/gestures/engine/test_system_action_inflight_lifecycle.ahk
#Include unit/gestures/engine/test_takenote_native_document_owner.ahk
#Include unit/platform/input/test_text_sender_modifiers.ahk
#Include unit/platform/input/dispatch/test_timer_scheduler.ahk
#Include unit/platform/input/dispatch/test_timer_delay_ceiling.ahk
#Include unit/menu/test_tray_pause_greys_features.ahk
#Include unit/layouts/test_active_layout_rows.ahk
#Include unit/platform/input/dispatch/test_hook_dispatcher.ahk
#Include unit/platform/input/test_own_injection_is_not_activity.ahk
#Include unit/core/logger/test_logger.ahk
#Include unit/core/logger/test_shutdown_sinks.ahk
#Include unit/platform/input/dispatch/test_wall_clock_snapshot.ahk
#Include unit/platform/input/dispatch/test_field_run_utc.ahk
#Include unit/core/network/adapters/test_promise_timeout_budget.ahk
#Include unit/core/logger/test_format_failure_is_visible.ahk
#Include unit/core/logger/test_contract.ahk
#Include unit/diagnostics/ui/healthcheck/test_logging.ahk
#Include unit/core/lifecycle/engine/test_build_commit.ahk
#Include unit/modules/updater/test_version_display_strips_build_metadata.ahk
#Include unit/core/logger/test_daily_rotation.ahk
#Include unit/core/logger/test_volume.ahk
; The logs-folder resolver and the Debug menu log openers built on it
; (logs-dir-resolver). log_openers.ahk is definitions only.
#Include ../diagnostics/ui/log_openers.ahk
#Include unit/core/logger/test_logs_dir_resolver.ahk
#Include meta/core/logger/test_logs_dir_single_resolver.ahk
; The folders editor host: definitions only until a window is opened; its
; initData builder and logs-folder save are exercised headlessly.
#Include ../settings/ui/paths_editor/init.ahk
#Include unit/core/ui/windows/test_paths_editor_logs_dir.ahk
#Include unit/diagnostics/ui/healthcheck/test_healthcheck_core.ahk
#Include unit/diagnostics/ui/healthcheck/test_configuration.ahk
#Include unit/diagnostics/ui/healthcheck/test_collection.ahk
#Include unit/diagnostics/ui/healthcheck/test_archive_failure_observation.ahk
#Include unit/diagnostics/ui/healthcheck/test_window_control.ahk
#Include unit/diagnostics/ui/healthcheck/test_owner_snapshots.ahk
#Include unit/diagnostics/engine/input_probe/test_input_probe.ahk
#Include unit/core/ui/tooltip/test_tint_contract.ahk
#Include unit/core/ui/tooltip/test_border_alpha.ahk
#Include unit/core/ui/tooltip/test_border_pool.ahk
#Include unit/core/ui/tooltip/test_border_zorder.ahk
#Include unit/core/ui/tooltip/test_border_ring_region.ahk
#Include unit/core/ui/tooltip/test_latency_diagnostics.ahk
#Include unit/core/ui/tooltip/test_border_gdi_ownership.ahk
#Include unit/core/ui/tooltip/test_measure_gdi_ownership.ahk
#Include unit/core/ui/tooltip/test_dequeue_regression.ahk
#Include unit/core/ui/tooltip/test_dequeue_contract.ahk
#Include unit/core/ui/tooltip/test_position_cache_receipt.ahk
#Include unit/core/ui/tooltip/test_position_refinement.ahk
#Include unit/ai/tooltip/test_grace.ahk
#Include unit/ai/tooltip/test_render.ahk
#Include unit/ai/tooltip/test_layout.ahk
#Include unit/hotstrings/engine/engine/test_engine.ahk
#Include unit/hotstrings/engine/engine/test_engine_main.ahk
#Include unit/hotstrings/engine/engine/test_engine_match.ahk
#Include unit/hotstrings/engine/engine/test_engine_expansion.ahk
#Include unit/hotstrings/engine/engine/test_engine_input_generations.ahk
#Include unit/hotstrings/engine/engine/test_buffer_boundaries.ahk
#Include unit/platform/input/test_suppress_refcount.ahk
#Include unit/hotstrings/engine/engine/test_live_toggle.ahk
#Include unit/hotstrings/engine/catalogue/test_live_rebuild_serialization.ahk
#Include unit/menu/test_tray_root_coordinator.ahk
#Include unit/hotstrings/engine/engine/test_terminal_hotstring_pacing.ahk
#Include unit/hotstrings/engine/engine/test_terminal_hotstring_transaction_owner.ahk
#Include unit/hotstrings/engine/engine/test_output_host_resolver_independent_of_metrics.ahk
#Include unit/gestures/engine/test_modifier_release_ownership.ahk
#Include unit/gestures/engine/test_unhook_ownership.ahk
#Include unit/menu/test_tray_root_lifecycle_retained.ahk
#Include unit/menu/test_tray_bootstrap_publication_transaction.ahk
#Include unit/menu/test_tray_startup_click_waits_for_input.ahk
#Include unit/core/lifecycle/engine/test_boot_menu_wait_clock.ahk
#Include unit/ai/menu/test_build_coordinator.ahk
#Include unit/hotstrings/engine/catalogue/test_count_policy.ahk
#Include unit/hotstrings/engine/prefix/test_watcher_index.ahk
#Include unit/hotstrings/engine/prefix/test_visible_suggestion_epoch.ahk
#Include unit/hotstrings/engine/preview/test_index_covers_every_registration.ahk
#Include unit/hotstrings/engine/preview/test_defers_to_engine.ahk
#Include unit/hotstrings/engine/preview/test_no_repeat_preview.ahk
#Include unit/hotstrings/engine/preview/test_shows.ahk
#Include unit/hotstrings/engine/prefix/test_index_cache_equiv.ahk
#Include unit/hotstrings/engine/personal/test_info_mask_vectors.ahk
#Include unit/hotstrings/engine/personal/test_info_tags_single_source.ahk
#Include unit/hotstrings/engine/preview/test_provider_at_triggers.ahk
; The fire-time @-combo resolver that replaced the hand-written list of
; thirty-one registrations. It lives in hotstring_engine_main.ahk (loaded above)
; and reads only globals, so the tests drive the REAL function against fixture
; personal-info maps rather than asserting on its source.
#Include unit/hotstrings/engine/personal/test_info_combo_resolver.ahk
#Include unit/settings/engine/persistence/test_master_gates.ahk
#Include unit/hotstrings/engine/engine/test_domain_registry.ahk
#Include unit/hotstrings/engine/engine/test_domain_expander.ahk
#Include unit/core/text/toml/test_loader.ahk
#Include unit/core/text/toml/test_helpers_roundtrip.ahk
#Include support/hotstring_registry_scope.ahk
#Include unit/hotstrings/engine/catalogue/test_cache.ahk
#Include unit/hotstrings/engine/catalogue/test_language_packs.ahk
#Include unit/settings/test_menu_languages_and_global_separator.ahk
#Include unit/keyboard/test_caps_word_auto_off_submenu.ahk
#Include unit/hotstrings/engine/test_dynamic_hotstrings_module.ahk
#Include unit/hotstrings/engine/personal/test_user_hotstrings.ahk
#Include unit/hotstrings/test_user_hotstrings_native.ahk
#Include unit/hotstrings/engine/personal/test_user_hotstrings_pid_publication.ahk
#Include unit/hotstrings/engine/catalogue/test_config.ahk
#Include unit/hotstrings/engine/catalogue/test_config_delimiters.ahk
#Include unit/hotstrings/engine/catalogue/test_delimiter_global_transaction.ahk
#Include unit/hotstrings/engine/catalogue/test_word_expander_commands.ahk
#Include unit/hotstrings/engine/catalogue/test_override_global_transaction.ahk
#Include unit/hotstrings/engine/catalogue/test_terminators.ahk
#Include unit/hotstrings/engine/catalogue/test_terminator_records.ahk
#Include unit/hotstrings/engine/catalogue/test_terminator_builtin_state.ahk
#Include unit/hotstrings/engine/catalogue/test_terminator_admission.ahk
#Include unit/hotstrings/engine/personal/test_toml_editor.ahk
#Include unit/menu/test_helpers.ahk
#Include unit/ui/physical_shortcuts/test_physical_shortcut_host.ahk
#Include unit/menu/test_manifest_menu_resolve_disabled_when_failclosed.ahk
#Include unit/menu/test_manifest_menu_declarations_are_read.ahk
#Include unit/menu/test_manifest_menu_declared_groups.ahk
#Include unit/menu/test_manifest_menu_captions.ahk
#Include unit/menu/test_manifest_menu_parent_groups.ahk
#Include unit/core/i18n/test_language_deferred_declared_parent.ahk
#Include unit/menu/test_manifest_menu_checked_when.ahk
#Include unit/layouts/engine/registry/test_tables.ahk
#Include unit/modules/shortcuts/test_uia_selection_worker_deadline.ahk
#Include unit/platform/focus/uia/test_worker_cleanup_debt.ahk
#Include unit/platform/focus/uia/test_worker_exit_reentry.ahk
#Include unit/platform/focus/uia/test_secure_field_worker_context.ahk
#Include unit/platform/focus/uia/test_secure_field_native_style_change.ahk
#Include unit/platform/focus/uia/test_secure_field_native_style_cache.ahk

#Include unit/settings/engine/persistence/test_config.ahk
#Include unit/settings/engine/persistence/test_feature_state_boot.ahk
#Include unit/metrics/ui/test_wpm_config_types.ahk
#Include unit/metrics/ui/test_wpm_position_receiving.ahk
#Include ../metrics/ui/wpm/gdiplus_ownership.ahk
#Include ../metrics/ui/wpm/widget.ahk
#Include ../metrics/ui/wpm/category_color.ahk
#Include unit/metrics/ui/test_wpm_color_resolution.ahk
#Include unit/metrics/ui/test_wpm_gdiplus_ownership.ahk
#Include unit/metrics/ui/test_wpm_drag_admission.ahk
#Include unit/metrics/ui/test_wpm_region_target.ahk
#Include unit/metrics/ui/test_wpm_canon.ahk
#Include unit/metrics/ui/test_wpm_graph_native_reentry.ahk
#Include unit/settings/engine/persistence/test_features_manifest.ahk
#Include unit/settings/engine/persistence/test_apply_config_toml.ahk
#Include unit/settings/engine/persistence/test_semantic_snapshot.ahk
#Include unit/settings/engine/persistence/test_snapshot_inline_records.ahk
#Include unit/settings/engine/persistence/test_snapshot_obsolete_parent.ahk
#Include unit/settings/engine/persistence/test_snapshot_equal.ahk
#Include unit/settings/engine/persistence/test_neutral_config_manifest.ahk
#Include unit/test_config_scope_manifest.ahk
#Include unit/settings/engine/scope/test_menus.ahk
#Include unit/settings/engine/scope/test_shortcuts.ahk
#Include unit/modules/shortcuts/test_shortcuts_restore_row.ahk
#Include unit/menu/test_script_control_submenu.ahk
#Include unit/hotstrings/engine/personal/test_shortcut_neutral_seed.ahk
#Include unit/settings/engine/scope/test_hotstrings_scope.ahk
#Include unit/hotstrings/engine/personal/test_file_controls.ahk
#Include unit/settings/engine/scope/test_hotstring_delimiter_scope_preservation.ahk
#Include unit/settings/engine/scope/test_hotstring_category_scope.ahk
#Include unit/settings/engine/scope/test_hotstring_dynamic_menu_scope.ahk
#Include unit/settings/engine/scope/test_personal_editor_menu_scope.ahk
#Include unit/settings/engine/scope/test_personal_frame_native.ahk
#Include unit/settings/engine/scope/test_personal_file_captions.ahk
#Include unit/settings/engine/scope/test_global_config_scope.ahk
#Include unit/gestures/engine/test_clear_boot_marker.ahk
#Include unit/settings/engine/scope/test_tap_hold_scope.ahk
#Include unit/settings/engine/scope/test_restore_recommended_no_confirm.ahk
#Include unit/keyboard/engine/tap_hold/test_hand_sections.ahk
#Include unit/settings/engine/persistence/test_io_feature_section_resolution.ahk
#Include unit/hotstrings/engine/catalogue/test_full.ahk
#Include unit/hotstrings/engine/catalogue/test_handler.ahk
#Include unit/hotstrings/engine/catalogue/test_end_to_end.ahk
#Include unit/keyboard/engine/tap_hold/test_loader.ahk
#Include unit/keyboard/engine/tap_hold/test_migration.ahk
#Include unit/keyboard/engine/tap_hold/test_overlay_and_modifiers.ahk
#Include unit/core/i18n/test_i18n.ahk
#Include unit/core/i18n/test_probe_is_silent.ahk
#Include unit/platform/focus/test_window_utils.ahk
#Include unit/core/network/test_external_url_policy.ahk
#Include unit/core/text/test_utils.ahk
#Include unit/settings/test_registry.ahk
#Include unit/hotstrings/engine/personal/test_toml_io.ahk
#Include unit/hotstrings/engine/personal/test_info_persistence_transaction.ahk
#Include unit/keyboard/engine/layers/test_nav_layer_helpers.ahk
#Include unit/keyboard/engine/layers/test_nav_layer_table.ahk
#Include unit/hotstrings/engine/expander/test_layer_editor_host.ahk
#Include unit/hotstrings/engine/engine/test_synthetic_buffer_effects.ahk
#Include unit/hotstrings/engine/prefix/test_finalizer_generation.ahk
#Include unit/hotstrings/engine/engine/test_synthetic_sends_declare_buffer_effect.ahk
#Include unit/keyboard/engine/keys/test_capsword_taphold_unlatch.ahk
#Include unit/modules/shortcuts/test_caps_word_auto_off_policy.ahk
#Include unit/modules/shortcuts/test_capsword_auto_off.ahk
#Include unit/modules/shortcuts/test_capsword_state.ahk
#Include meta/keyboard/tap_hold/test_suspend_boundary.ahk
#Include unit/test_updater.ahk
#Include unit/modules/updater/test_updater_release_fetch.ahk
#Include unit/modules/updater/test_updater_request_pause.ahk
#Include unit/modules/updater/test_updater_transport_ownership.ahk
#Include unit/modules/updater/test_updater_tray_root.ahk
#Include unit/modules/updater/test_updater_install_deadlines.ahk
#Include unit/modules/updater/test_updater_channel_bundle.ahk
#Include unit/modules/updater/test_asset_signature.ahk
#Include unit/modules/updater/test_updater_managed_failure.ahk
#Include unit/modules/updater/test_release_install.ahk
#Include unit/modules/updater/test_config_restore_custody.ahk
#Include unit/core/lifecycle/engine/shutdown/test_uninstall.ahk
#Include unit/core/lifecycle/engine/shutdown/test_uninstall_source_run.ahk
#Include unit/core/lifecycle/engine/test_start_at_login.ahk
#Include unit/core/lifecycle/engine/test_start_at_login_other_source.ahk
#Include meta/core/lifecycle/engine/shutdown/test_uninstall_shutdown_gate.ahk
#Include unit/modules/updater/test_updater_channel_registry.ahk
#Include unit/modules/updater/test_updater_schedule_vectors.ahk
#Include unit/modules/updater/test_version_label_vectors.ahk
#Include unit/modules/updater/test_updater_check_interval_snap.ahk
#Include unit/modules/updater/test_updater_check_schedule.ahk
#Include unit/modules/updater/test_updater_balloon_click_ownership.ahk
#Include unit/modules/updater/test_updater_channel_selection.ahk
#Include unit/modules/updater/test_updater_release_list_budget.ahk
#Include unit/modules/updater/test_updater_check_only_fallback.ahk
#Include unit/modules/updater/test_updater_check_session_vectors.ahk
#Include unit/core/lifecycle/engine/shutdown/test_quit_admission.ahk
; The About row actions; menu_init.ahk is included with the tray root below.
#Include ../menu/ui/builder/actions.ahk
#Include unit/modules/updater/test_about_menu_channel_rows.ahk
#Include unit/modules/updater/test_about_menu_version_row.ahk
#Include unit/modules/updater/test_changelog_subscribe_channel.ahk
#Include unit/modules/updater/test_updater_release_notes.ahk
#Include unit/modules/updater/test_updater_staging_transport.ahk
#Include unit/modules/updater/test_updater_swap_transaction.ahk
#Include unit/modules/updater/test_updater_swap_receiving.ahk
#Include unit/modules/updater/test_updater_swap_cancellation.ahk
#Include unit/modules/updater/test_updater_swap_shutdown.ahk
#Include unit/modules/updater/test_updater_swap_recovery.ahk
#Include unit/modules/updater/test_updater_swap_cleanup.ahk
#Include unit/gestures/engine/test_emit_actions.ahk
#Include unit/gestures/engine/test_incremental_rule.ahk
#Include unit/gestures/adapters/test_touchpad_hid.ahk
#Include unit/gestures/adapters/test_raw_touchpad_owner.ahk
#Include unit/gestures/engine/test_swipe_slot_menu.ahk
#Include unit/modules/updater/test_updater_constants_single_source.ahk
#Include unit/core/lifecycle/engine/test_runtime_contract_version.ahk
#Include meta/modules/updater/test_updater_load_interval_guard.ahk

; Shortcuts modules — dispatcher logic is testable without real hotkeys firing;
; the module files are #Include'd from within test_shortcuts.ahk itself so the
; include paths are resolved relative to the tests/ directory.
#Include unit/modules/shortcuts/test_shortcuts.ahk
#Include unit/modules/shortcuts/test_open_target_vectors.ahk
#Include unit/modules/shortcuts/test_keepawake_visible_cancellation.ahk
#Include unit/modules/shortcuts/test_keepawake_pause_gate.ahk
#Include unit/suite/test_runner_shard.ahk

; Metrics boolean preferences retain their existing transaction owner; ordinary
; chord syntax tests use the shared parser and registrar without binding hotkeys.
#Include ../apps/engine/picker.ahk
#Include ../settings/engine/shortcuts.ahk
#Include ../metrics/engine/filters.ahk
#Include ../metrics/engine/shortcuts.ahk
#Include ../metrics/ui/menu/metrics.ahk
#Include ../metrics/ui/menu/actions.ahk
#Include unit/metrics/engine/metrics/test_shortcut_named_key.ahk
#Include unit/settings/engine/persistence/test_shortcuts_types.ahk
#Include unit/metrics/engine/metrics/test_preferences_global_barrier.ahk

; LLM modules — pure-logic subset (profiles, models, api_common, api_ollama,
; api_remote, prediction_engine) included here to test JSON parsing, profile
; lookup, payload building, response parsing, cancel helpers, and engine
; debounce / cache logic without any real network calls.
; models.ahk defines LLM_GetSharedPath which profiles.ahk depends on.
_LogBootProgress("loading LLM modules")
#Include ../ai/engine/settings/models.ahk
#Include ../ai/engine/defaults.ahk
; llm_profiles_data.ahk (generated) defines LLM_LEGACY_IDS + LLM_GetBasicPrompt()
; which profiles.ahk depends on — see the LLM legacy/basic-prompt single-source tests.
#Include ../_generated/llm_profiles_data.ahk
#Include ../ai/engine/settings/profiles.ahk
#Include unit/ai/profiles/test_profiles.ahk
#Include ../ai/engine/api/common.ahk
#Include ../ai/engine/api/token_crypto.ahk
#Include unit/ai/api/test_common.ahk
#Include ../ai/engine/ollama/install_files_port.ahk
#Include ../ai/engine/ollama/runtime_owner.ahk
#Include ../ai/engine/ollama/deps_checker.ahk
; Preserve the prior ready test baseline while receiving the real state getter.
_LLM_Deps_State := "ready"
#Include ../ai/engine/api/ollama.ahk
#Include ../ai/engine/api/remote_formats.ahk
#Include ..\..\_shared\ai\data\local_server_auth.ahk
#Include ..\..\_shared\ai\data\api_url_template.ahk
#Include ..\..\_shared\ai\data\model_capabilities.ahk
#Include ..\..\_shared\ai\data\thinking_off.ahk
#Include ..\..\_shared\ai\data\local_server_fingerprint.ahk
#Include ..\..\_shared\ai\data\local_server_discovery.ahk
#Include ..\..\_shared\ai\data\local_server_ports.ahk
#Include ../../_shared/ai/data/local_server_menu.ahk
#Include ../ai/engine/api/remote.ahk
#Include ../ai/engine/local_servers/models.ahk
#Include ../ai/engine/local_servers/port_scan.ahk
#Include ../ai/engine/local_servers/local_servers.ahk
#Include unit/ai/api/test_ollama.ahk
#Include unit/ai/api/test_ollama_streaming.ahk
#Include unit/ai/api/test_ollama_curl_personal_config.ahk
#Include unit/ai/api/test_provider_error_prefix.ahk
#Include unit/ai/api/test_ollama_local_presence.ahk
#Include unit/ai/api/test_ollama_warmup.ahk
#Include unit/ai/prediction/test_engine_read_guarded_in_timer.ahk
#Include unit/ai/api/test_remote.ahk
#Include unit/ai/api/test_remote_async_registry.ahk
#Include unit/ai/api/test_remote_requests.ahk
#Include unit/ai/api/test_thinking_off.ahk
#Include unit/ai/api/test_shared_vectors.ahk
#Include unit/ai/api/test_model_capabilities.ahk
#Include unit/core/network/adapters/test_managed_curl_owner.ahk
#Include unit/core/network/adapters/test_proxy_override.ahk
#Include unit/core/network/adapters/test_managed_curl_empty_header.ahk
#Include unit/core/network/adapters/test_http_post_replacement_validation.ahk
#Include unit/core/network/adapters/test_managed_curl_callers.ahk
#Include unit/ai/servers/test_local_server_auth.ahk
#Include unit/ai/servers/test_local_server_discovery_policy.ahk
#Include unit/ai/servers/test_local_server_models.ahk
#Include unit/ai/servers/test_local_server_models_timer.ahk
#Include unit/ai/servers/test_local_server_menu.ahk
#Include unit/ai/servers/test_local_servers.ahk
#Include unit/ai/servers/test_local_server_ports.ahk
#Include unit/ai/servers/test_local_server_fingerprint.ahk
#Include unit/ai/servers/test_local_server_queue_timer.ahk
#Include unit/ai/servers/test_crash_orphan_cleanup.ahk
#Include unit/ai/servers/test_temp_artifact_terminal_ownership.ahk
#Include unit/platform/system/test_filesystem_native_write.ahk
#Include unit/platform/system/test_filesystem_nul_paths.ahk
#Include unit/core/process/test_lifecycle_app_events.ahk
#Include unit/core/logger/test_native_write.ahk
#Include unit/metrics/engine/journal/test_sql_native_write.ahk
#Include unit/metrics/engine/journal/test_sql_write_compensation.ahk
#Include unit/metrics/engine/journal/test_flush_retry.ahk
#Include unit/metrics/engine/journal/test_owner.ahk
#Include unit/metrics/engine/journal/test_owner_validation.ahk
#Include unit/metrics/engine/journal/test_scope.ahk
#Include unit/metrics/engine/journal/test_native_write.ahk
#Include unit/metrics/engine/journal/test_encoding.ahk
#Include unit/metrics/engine/journal/test_tail.ahk
#Include unit/metrics/engine/journal/test_short_write.ahk
#Include meta/metrics/engine/journal/test_lifecycle_owner.ahk
#Include unit/metrics/engine/journal/test_repair_debt.ahk
#Include unit/ai/api/test_aux_request_ownership.ahk
#Include unit/ai/api/test_test_entry.ahk
#Include unit/ai/api/test_entry_names.ahk
#Include unit/ai/api/test_url_template.ahk
#Include unit/ai/menu/test_backend_model_labels.ahk
#Include unit/ai/menu/test_model_hardware.ahk
#Include unit/ai/menu/test_build_submenu.ahk
#Include unit/ai/menu/test_prediction_count.ahk
#Include unit/ai/servers/test_curl_terminal_classification.ahk
#Include unit/ai/servers/test_curl_literal_paths.ahk
#Include unit/ai/servers/test_ollama_http_terminal_classification.ahk
#Include unit/ai/servers/test_remote_curl_terminal_classification.ahk
; Remote catalogue load must fall back gracefully when api_providers.json is missing/malformed.
#Include meta/ai/servers/test_remote_catalog_load_graceful.ahk
#Include ../ai/engine/api/option_validation.ahk
#Include ../ai/engine/prediction/rewrite.ahk
#Include ../ai/engine/prediction/prompt_action.ahk
#Include ../ai/engine/prediction/tone.ahk
#Include ../ai/engine/prediction/tone_action.ahk
#Include ../ai/engine/prediction/vision.ahk
#Include ../ai/engine/prediction/vision_action.ahk
#Include ../ai/engine/prediction/translate.ahk
#Include ../ai/engine/prediction/translate_action.ahk
#Include ../ai/engine/agent/agent.ahk
#Include ../ai/engine/agent/connectors.ahk
#Include ../ai/engine/agent/action.ahk
#Include ../ai/engine/prediction/engine.ahk
#Include unit/ai/prediction/test_engine.ahk
#Include unit/ai/prediction/test_engine_state.ahk
#Include unit/ai/prediction/test_engine_pointer_dismiss.ahk
#Include unit/ai/api/test_semantic_config_identity.ahk
#Include unit/ai/api/test_semantic_config_budget.ahk
#Include unit/ai/api/test_defaults.ahk
; llm_bridge.ahk is needed by the canonical HSE -> LLM effect behaviour tests.
#Include ../ai/engine/bridge.ahk
#Include unit/ai/prediction/test_bridge_apply_expansion.ahk
#Include unit/hotstrings/engine/prefix/test_char_admission.ahk
#Include unit/hotstrings/engine/prefix/test_llm_typing_privacy.ahk
#Include unit/hotstrings/engine/prefix/test_cached_privacy_gap.ahk
#Include unit/hotstrings/engine/prefix/test_backspace_cached_privacy_gap.ahk
#Include unit/hotstrings/engine/prefix/test_backspace_native_owned.ahk
#Include unit/hotstrings/engine/prefix/test_backspace_native_gap.ahk
#Include unit/hotstrings/engine/prefix/test_backspace_native_gap_controls.ahk
#Include unit/hotstrings/engine/prefix/test_fresh_native_privacy.ahk
#Include unit/hotstrings/engine/prefix/test_llm_native_admission_order.ahk
#Include unit/hotstrings/engine/prefix/test_llm_native_entry_lifecycle.ahk
#Include unit/hotstrings/engine/prefix/test_llm_observer_lifetime.ahk
#Include unit/hotstrings/engine/engine/test_idle_click_reset.ahk
#Include unit/hotstrings/engine/engine/test_event_word_reset.ahk
#Include unit/hotstrings/engine/engine/test_backspace_word_start.ahk
#Include unit/ai/prediction/test_bridge_buffer_cap.ahk
#Include unit/ai/navigation/test_pointer_watch_transaction.ahk
#Include unit/ai/navigation/test_tab_accept_policy.ahk
#Include unit/ai/navigation/test_accept_injects_exact_text.ahk
#Include unit/modules/shortcuts/test_accented_shortcuts.ahk
#Include unit/layouts/engine/composer/test_keylayout_emulation.ahk
#Include unit/layouts/engine/composer/test_keylayout_altgr_characterization.ahk
#Include unit/layouts/engine/composer/test_keylayout_canonical_source.ahk
#Include unit/hotstrings/engine/magic_key/test_source_menu.ahk
#Include unit/hotstrings/engine/magic_key/test_source_hotkeys.ahk
#Include unit/layouts/engine/registry/test_catalogue.ahk
#Include unit/layouts/engine/registry/test_download_custody.ahk
#Include unit/layouts/engine/registry/test_late_poll.ahk
#Include unit/layouts/engine/registry/test_inline_callback.ahk
#Include unit/layouts/engine/registry/test_installed_record_corpora.ahk
#Include unit/layouts/engine/registry/test_extension_runtime.ahk
#Include unit/layouts/engine/registry/test_extension_menu.ahk
#Include unit/layouts/engine/registry/test_extension_refresh.ahk
#Include unit/hotstrings/engine/catalogue/test_ergopti_extension_hotstrings.ahk
#Include ../layouts/ui/layout_manager/init.ahk
#Include ../layouts/ui/layout_manager/composer.ahk
#Include ../layouts/ui/layout_manager/composer_check.ahk
#Include ../layouts/ui/layout_manager/source_store.ahk
#Include ../layouts/ui/layout_manager/kbd_register_core.ahk
#Include ../diagnostics/ui/field_check/network_check.ahk
#Include ../core/network/proxy_override.ahk
#Include ../layouts/ui/menu/layout.ahk
#Include unit/layouts/engine/registry/test_manager_host.ahk
#Include unit/layouts/engine/registry/test_composer_host.ahk
#Include unit/layouts/engine/registry/test_composer_stage_ownership.ahk
#Include unit/layouts/engine/registry/test_composer_check.ahk
#Include unit/layouts/engine/registry/test_source_store.ahk
#Include unit/layouts/engine/registry/test_composer_source.ahk
#Include unit/hotstrings/engine/expander/test_kbd_register.ahk
#Include unit/layouts/engine/registry/test_source_emulation.ahk
#Include unit/diagnostics/ui/test_network_check.ahk
#Include unit/hotstrings/engine/expander/test_ergopti_keylayout_tables.ahk
#Include unit/layouts/engine/registry/test_supersession.ahk
; parser.ahk (the AHK semantic-diff parser) was previously exercised by no suite,
; which let a crash in its Levenshtein helper survive — include it + its tests.
#Include ../ai/engine/api/parser.ahk
#Include unit/ai/prediction/test_parser.ahk
#Include meta/ai/prediction/test_batch_dedup_stats.ahk
; Non-blocking installed-tags cache contract + behaviour (menu-build-sync-api-tags-freeze).
; Behavioural cases call the real models.ahk cache funcs included just above.
#Include meta/ai/api/test_installed_tags_async.ahk
; Any input (type/click/move) cancels in-progress generation (llm-spinner-lingers-through-input).
#Include meta/ai/navigation/test_input_cancels_generation.ahk
; Ollama reachability probe is non-blocking curl, not WinHTTP (ollama-reachability-winhttp-connect-blocks).
#Include meta/ai/servers/test_ollama_reachability_async_nonblocking.ahk
; Orphan temp-file sweep is bounded + off the Critical dispatch path (llm-orphan-sweep-temp-recursion).
#Include meta/ai/prediction/test_orphan_sweep_nonblocking.ahk
; The coordinator serializes detached LLM menu builds and retains re-entrant work.
#Include meta/ai/tooltip/test_markchain_no_rerender.ahk
#Include meta/ai/menu/test_build_critical.ahk
#Include meta/ai/menu/test_build_coordinator.ahk
#Include meta/ai/menu/test_caller_child_full_root.ahk
_LogBootProgress("LLM modules + tests included")

; LLM tray menu -> config.toml persistence (contract-driven round-trips).
global _LLM_Menu := Map(
	"enabled", true, "backend", "ollama", "model", "Qwen3.5-0.8B",
	"profile_id", "basic", "n_predictions", 3, "auto_profile_for_model", true,
	"min_words", 3, "max_words", 15, "language", "fr", "debounce_ms", 500, "min_request_interval_ms", 300,
	"ctx_chars", 500, "temperature", "0.10", "instant_on_word_end", true,
	"after_hotstring", true, "reset_on_nav", true, "disable_url_bars", true,
	"disable_password_fields", true, "disabled_apps", [], "show_info_bar", true,
	"streaming", true, "show_all_at_once", true, "pred_indent", 0,
	"auto_raise_temp", true, "nav_modifiers", "", "val_modifiers", "alt",
	"inline_autotype", false,
	"ollama_port", 11435
)
global _LLM_Menu_Loaded := false
; Definitions-only chord translation and hotkey identities; registers no hotkey.
#Include ../ai/ui/menu/hotkey_identity.ahk
#Include ../ai/adapters/nav_event_owner.ahk
#Include ../core/ui/adapters/terminal_output_preview.ahk
#Include ../core/ui/adapters/terminal_output_custody.ahk
#Include ../ai/adapters/automation.ahk
#Include ../ai/ui/menu/tab_accept.ahk
; Definitions-only boot restore helper. LLM_Menu_Init is never invoked by the
; harness; the regression suite calls only its one-shot saved-options seam.
#Include ../ai/ui/menu/init.ahk
_LogBootProgress("loading menu_llm/persist")
#Include ../ai/ui/menu/models/models.ahk
#Include ../ai/ui/menu/profiles.ahk
#Include ../ai/ui/menu/persist.ahk
#Include ../ai/ui/menu/transactions.ahk
#Include ../ai/ui/menu/backend_lifecycle.ahk
#Include ../ai/ui/menu/aux_ownership.ahk
#Include ../ai/ui/menu/api_entries.ahk
#Include ../ai/ui/menu/panels/local_server_panel.ahk
#Include ../ai/ui/menu/menu_main.ahk
#Include ../ai/ui/menu/enable_admission.ahk
#Include ../ai/ui/menu/actions.ahk
#Include ../gestures/ui/menu/gestures.ahk
#Include ../menu/engine/dispatcher.ahk
#Include ../ai/ui/menu/settings.ahk
#Include ../ai/ui/menu/agent.ahk
#Include unit/ai/api/test_backend_lifecycle_dispatch.ahk
#Include unit/ai/prediction/test_generate_prediction_feedback.ahk
#Include unit/ai/menu/test_persistence.ahk
#Include unit/core/lifecycle/engine/test_llm_persistence_runner.ahk
#Include unit/ai/api/test_temperature_boundary.ahk
#Include unit/ai/menu/test_numeric_option_ranges.ahk
#Include unit/ai/api/test_sync_target.ahk
#Include unit/ai/menu/test_transactions.ahk
#Include unit/ai/menu/test_api_entries_transactions.ahk
#Include unit/ai/api/test_token_crypto_receiving.ahk
#Include unit/ai/menu/test_display.ahk
#Include unit/ai/menu/test_generation.ahk
#Include unit/ai/menu/test_indentation.ahk
#Include unit/ai/menu/test_privacy.ahk
#Include unit/ai/menu/test_profiles.ahk
#Include unit/ai/servers/test_local_server_private_publication.ahk
#Include unit/ai/servers/test_local_server_publication_rollback.ahk
#Include unit/ai/servers/test_local_server_receipt_entry.ahk
#Include unit/ai/servers/test_local_server_source_operations.ahk
#Include unit/ai/servers/test_local_server_sweep_admission.ahk
#Include unit/ai/api/test_add_production.ahk
#Include unit/ai/api/test_add_account_address.ahk
#Include unit/ai/servers/test_local_server_write_admission.ahk
#Include unit/ai/servers/test_local_server_join.ahk
#Include unit/ai/servers/test_local_server_scope_cohort.ahk
#Include unit/ai/servers/test_local_server_panel.ahk
#Include unit/ai/servers/test_local_server_panel_discovery.ahk
#Include unit/ai/servers/test_local_server_panel_view_preparation.ahk
#Include unit/ai/api/test_enable_admission.ahk
#Include unit/ai/menu/test_fixture_isolation.ahk
#Include unit/ai/api/test_fixture_setup.ahk
#Include unit/core/ui/windows/test_app_picker_generation.ahk
#Include meta/core/ui/windows/test_app_picker_generation_wiring.ahk
#Include unit/ai/menu/test_locale_bridge.ahk
#Include meta/ai/menu/test_locale_source.ahk
#Include unit/ai/servers/test_ollama_port_boundary.ahk
#Include meta/ai/servers/test_ollama_port_owner.ahk
#Include unit/ai/menu/test_regressions.ahk
; The prompt-editor host is definitions-only until TryOpen is called. Load it so
; its deferred context fence can be exercised without creating a Gui/WebView.
#Include ../ai/ui/prompt_editor/init.ahk
#Include unit/ai/profiles/test_prompt_editor_context_epoch.ahk
; Changelog host is likewise definitions-only until Changelog_Open is called.
; Load it so the request/window epoch can be exercised with deterministic fakes.
#Include ../ui/changelog/init.ahk
_LogBootProgress("menu_llm persist + tests included")

; Gestures module — included here because its pure logic (assignments, action
; registry, dispatch) is testable. The hotkeys it registers are harmless since
; RunTests() calls ExitApp immediately after completion.
_LogBootProgress("loading gestures modules")
#Include ../modules/take_note.ahk
#Include ../_generated/touchpad_registry.ahk
#Include ../gestures/adapters/touchpad_registry.ahk
#Include ../gestures/engine/init.ahk
#Include ../gestures/engine/click.ahk
#Include ../gestures/adapters/screenshots.ahk
#Include ../gestures/adapters/window_cycle.ahk
#Include ../gestures/adapters/virtual_desktops.ahk
#Include ../gestures/engine/config.ahk
; Genuine gestures factory/registry and generated rows are already loaded.
; These source-image cases do not invoke actions or native output.
#Include ../../_shared/tap_hold/engine/buffered_data_snapshot_owner.ahk
#Include unit/core/lifecycle/engine/test_buffered_data_snapshot_owner.ahk
; Load the definitions-only onboarding worker owner so its elevated-launch
; reservation can be exercised without constructing the wizard UI.
#Include ../ui/onboarding/gesture_registration.ahk
; The answers contract, the commit and the WebView host are definitions-only
; until _Onboarding_TryWeb is called. Include them so the finish payload is
; followed to the candidate config.toml without the persistence/reload boundary.
#Include ../ui/onboarding/translate.ahk
#Include ../ui/onboarding/answers.ahk
#Include ../ui/onboarding/finish.ahk
#Include ../ui/onboarding/webview.ahk
#Include unit/diagnostics/adapters/crash_report/test_screenshot_worker_ownership.ahk
#Include unit/diagnostics/adapters/crash_report/test_screenshot_layered_native.ahk
#Include unit/ui/onboarding/test_onboarding_finish_payload.ahk
#Include unit/ui/onboarding/test_onboarding_answers.ahk
#Include unit/ui/onboarding/test_onboarding_metrics_path.ahk
#Include unit/gestures/engine/test_gestures.ahk
#Include unit/gestures/engine/test_binding_identity.ahk
#Include unit/gestures/engine/test_menu_status.ahk
#Include unit/settings/engine/persistence/test_keyboard_binding_identity.ahk
#Include unit/gestures/adapters/test_virtual_desktops.ahk
#Include unit/modules/shortcuts/test_text_case_vectors.ahk
#Include unit/modules/shortcuts/test_wrap_selection_action.ahk
#Include unit/modules/shortcuts/test_uia_selection_native64_owner.ahk
#Include unit/gestures/engine/test_system_actions.ahk
#Include unit/gestures/engine/test_unblock_selected_root_reparse.ahk
#Include unit/gestures/engine/test_unblock_selected_file_reparse.ahk
#Include unit/gestures/engine/test_system_actions_confirmed_targets.ahk
#Include unit/gestures/engine/test_system_actions_query_pause.ahk
#Include unit/gestures/engine/test_system_actions_process_lease.ahk
#Include unit/gestures/engine/test_system_actions_receiving.ahk
#Include unit/adapters/test_screen_brightness.ahk
#Include unit/ai/actions/test_rewrite.ahk
#Include unit/ai/actions/test_prompt_action.ahk
#Include unit/ai/prediction/test_prompt_prediction.ahk
#Include unit/ai/tooltip/test_line_style.ahk
#Include unit/ai/actions/test_tone.ahk
#Include unit/ai/actions/test_vision.ahk
#Include unit/ai/actions/test_translate.ahk
#Include unit/ai/actions/test_agent.ahk
#Include unit/ai/actions/test_agent_connectors.ahk
#Include unit/ai/actions/test_agent_ai_off.ahk
#Include unit/ai/actions/test_agent_plan_corpus.ahk
#Include unit/ai/menu/test_test_prediction.ahk
#Include unit/ai/actions/test_agent_system_menu.ahk
#Include unit/ai/actions/test_agent_requester.ahk
#Include unit/ai/api/test_remote_formats.ahk
#Include unit/ai/prediction/test_live_mode.ahk
#Include unit/ai/prediction/test_engine_transcripts.ahk
#Include unit/ai/prediction/test_hotstring_tooltip_hold.ahk
#Include unit/modules/shortcuts/test_send_input_actions.ahk
#Include unit/keyboard/engine/keys/test_tap_keys.ahk
#Include unit/keyboard/engine/keys/test_tap_keys_kana_native.ahk
#Include unit/keyboard/engine/keys/test_ai_action_gate.ahk
#Include unit/keyboard/engine/key_combinations/test_key_combinations.ahk
#Include unit/keyboard/engine/key_combinations/test_chord_policy.ahk
#Include unit/keyboard/engine/key_combinations/test_chord_engine.ahk
#Include unit/gestures/engine/test_cycle_candidates.ahk
#Include unit/gestures/engine/test_recommended_actions.ahk
#Include unit/settings/engine/persistence/test_transactions.ahk
#Include unit/settings/engine/persistence/test_suspend_marker_handoff.ahk
#Include unit/core/lifecycle/engine/reload/test_terminal_pending.ahk
#Include unit/core/lifecycle/engine/reload/test_successor_quiescence.ahk
#Include unit/core/lifecycle/engine/reload/test_worker_identity.ahk
#Include unit/core/lifecycle/engine/reload/test_deferral.ahk
#Include unit/core/lifecycle/engine/test_dev_source.ahk
#Include unit/menu/test_tray_menu_separator_popup.ahk
#Include unit/menu/test_deferred_children.ahk
#Include unit/keyboard/engine/tap_hold/test_hold_picker_options.ahk
#Include unit/menu/test_command_deferral.ahk
#Include unit/menu/builder/test_reload_replay.ahk
#Include unit/keyboard/engine/tap_hold/test_roll.ahk
#Include unit/settings/engine/persistence/test_recovery_transactions.ahk
#Include unit/settings/engine/persistence/test_commit_gateway.ahk
#Include unit/settings/engine/persistence/test_typed_updates.ahk
#Include unit/settings/engine/persistence/test_typed_transactions.ahk
#Include unit/settings/engine/persistence/test_unused_keys.ahk
#Include unit/settings/engine/persistence/test_cleanup_retired_entries.ahk
#Include unit/settings/engine/persistence/test_cleanup_retired_root.ahk
#Include unit/settings/engine/persistence/test_cleanup_retired_bindings.ahk
#Include unit/settings/engine/migration/test_migrate.ahk
#Include unit/settings/engine/migration/test_migrate_variant_metadata.ahk
#Include unit/settings/engine/migration/test_migrate_same_registry.ahk
#Include unit/settings/engine/migration/test_legacy_folder_migration.ahk
#Include unit/settings/engine/migration/test_legacy_folder_migration_receiving.ahk
#Include unit/settings/engine/migration/test_journal_boot.ahk
#Include unit/settings/engine/migration/test_journal_ai_admission.ahk
#Include unit/settings/engine/migration/test_journal_settlement.ahk
#Include unit/settings/engine/migration/test_journal_nul_suffix.ahk
#Include unit/settings/engine/persistence/test_partial_load_persistence.ahk
#Include unit/settings/engine/persistence/test_partial_load_llm.ahk
#Include unit/core/text/toml/test_numeric_strings.ahk
#Include unit/core/text/toml/test_array_element_types.ahk
#Include unit/core/text/toml/test_inline_tables.ahk
#Include unit/core/text/toml/test_document_quoted_runs.ahk
#Include unit/core/text/toml/test_section_filter.ahk
#Include unit/core/text/toml/test_nested_arrays.ahk
#Include unit/core/text/toml/test_float_roundtrip.ahk
#Include unit/core/text/toml/test_incomplete_write.ahk
#Include unit/core/text/toml/test_stage_cleanup.ahk
#Include unit/settings/engine/persistence/test_typed_producers.ahk
#Include unit/metrics/engine/metrics/test_delivery_owner.ahk
#Include unit/metrics/engine/metrics/test_cached_ready.ahk
#Include unit/metrics/engine/metrics/test_warm_sidecar.ahk
#Include unit/metrics/engine/metrics/test_edge_sidecar.ahk
#Include unit/metrics/engine/metrics/test_store_isolation.ahk
#Include unit/metrics/engine/metrics/test_store_publication.ahk
#Include unit/metrics/engine/metrics/test_reader_image_reset.ahk
#Include unit/metrics/engine/metrics/test_store_edge.ahk
#Include unit/metrics/engine/metrics/test_store_projection.ahk
#Include unit/core/ui/webview/test_script_outcomes.ahk
#Include unit/core/ui/webview/test_range_outcomes.ahk
#Include unit/core/ui/webview/test_range_stage_owner.ahk
#Include unit/core/ui/webview/test_range_cleanup_reentry.ahk
#Include unit/core/ui/webview/test_range_mount.ahk
#Include unit/core/ui/webview/test_profile_ownership.ahk
#Include unit/core/ui/webview/test_fit_to_window.ahk
#Include unit/core/ui/webview/test_personal_editors_webview_only.ahk
#Include unit/metrics/engine/metrics/test_file_urls.ahk
#Include unit/core/text/toml/test_uridecode_literal_unicode.ahk
#Include meta/core/ui/webview/test_script_observer.ahk
#Include unit/metrics/engine/metrics/test_retry_outcomes.ahk
#Include meta/settings/persistence/test_typed_foreign_producers.ahk
#Include unit/settings/engine/transition/test_transition_core.ahk
#Include unit/settings/engine/transition/test_quarantine.ahk
#Include unit/settings/engine/transition/test_runtime.ahk
#Include unit/settings/engine/transition/test_windows_port.ahk
#Include unit/settings/engine/transition/test_temporal_custody.ahk
#Include unit/core/text/toml/test_build_updated_content.ahk
#Include unit/core/text/toml/test_writer_admission.ahk
#Include unit/core/text/toml/test_writer_case_twins.ahk
#Include unit/core/text/toml/test_table_array_writer.ahk
#Include unit/settings/engine/persistence/test_full_save_generation.ahk
#Include unit/settings/engine/persistence/test_full_save_terminal.ahk
#Include unit/settings/engine/persistence/test_full_save_startup_intent.ahk
#Include unit/settings/engine/persistence/test_full_save_durable_debt.ahk
#Include unit/settings/engine/persistence/test_write_terminal_barrier.ahk
#Include unit/settings/engine/persistence/test_feature_io_global_barrier.ahk
#Include unit/settings/engine/persistence/test_editor_global_barrier_behavior.ahk
#Include unit/core/lifecycle/engine/test_runtime_decision_generation.ahk
#Include meta/metrics/ui/test_wpm_global_barrier_behavior.ahk
#Include unit/gestures/engine/test_restart_result_zero_is_success.ahk
#Include unit/gestures/adapters/test_touchpad_registry.ahk
_LogBootProgress("gestures + test included")

; Keystats sub-modules — pure-logic subsets included here to test category
; lookup, character classification, and burst helpers without OS hooks or I/O.
; sqlite3.ahk needs _VendorDir (set by ErgoptiPlus.ahk at runtime); stub it
; here so the class static initialiser does not crash the test runner.
_LogBootProgress("loading keystats modules")
global _VendorDir := A_ScriptDir . "\..\vendor"
; keystats_prefetch.ahk normally receives this from core/lifecycle/engine/boot.ahk.  The
; headless runner loads only the pure worker protocol, so provide its explicit
; config-root dependency without executing the full driver boot sequence.
global _ConfigDir := A_Temp . "\ergopti_test_config\"
global _AhkSubDir := ""
#Include ../core/fs/engine/sqlite3.ahk
#Include ../metrics/engine/walker/walker.ahk
#Include ../metrics/engine/apps/categories.ahk
#Include ../metrics/engine/reader/reader.ahk
; ROI pruning is isolated from the hook-owning module so the exact production
; survivor and generation transactions can be exercised headlessly.
#Include ../metrics/engine/privacy/roi_prune.ahk
; Password-field classification is definitions-only. Load the real async cache
; writer so its fail-closed behaviour can be exercised with a fake UIA object.
#Include ../metrics/engine/capture/password.ahk
; Atomic completion journaling is definitions-only. Load the production module
; against the Keystats/Metrics stubs so privacy-epoch and RAM-commit ordering
; are verified without arming the full keystats lifecycle.
#Include ../metrics/engine/journal/llm_journal.ahk
; The prefetch worker contains no top-level I/O. Including it here enables a
; headless generation-fence test with a fake ShellRunner spawn handle.
#Include ../metrics/engine/journal/prefetch.ahk
; Wi-Fi transition reduction is pure; the live timers are armed only by
; KL_Net_Start(), which the test runner never calls.
#Include ../metrics/engine/system/network.ahk
; Capture-state reduction is also definition-only. The process snapshot is
; invoked only by KL_AV_Start/KL_AV_ScanCapture, so tests can replace its seam
; without touching Win32 process enumeration.
#Include ../metrics/engine/capture/av_state.ahk
; keystats_webview.ahk is likewise definitions-only at top level. Loading the
; real module lets terminal/retry tests drive the production state machines;
; no Gui, COM object, timer, or WebView is created until an explicit function
; call, and those tests replace the push/timer boundaries with local seams.
#Include ../metrics/engine/view/webview.ahk
; keystats_clipboard.ahk defines _KL_Clip_CharCountFromBuffer + KLClipConst,
; both exercised functionally by meta/platform/input/test_clipboard_ram_leak.ahk. It contains
; only class + function definitions at top level (the Hotkey()/OnClipboardChange
; calls live inside KL_Clip_Start), so it is headless-safe. Without this include
; the test's direct call to _KL_Clip_CharCountFromByteSize is a load-time
; "nonexistent function" error that hangs the headless runner with no output.
#Include ../metrics/engine/capture/clipboard.ahk
#Include unit/metrics/engine/capture/test_clipboard_provenance.ahk
; keystats_json.ahk (KL_JsonEncode) and keystats_sql.ahk (KL_BuildInserts +
; the per-type KL_BuildInsertXxx builders) are pure definitions with no
; top-level hotkeys/OS hooks, so — like the walker sub-modules above — they
; are safe to load directly for unit coverage of the INSERT-statement
; builders (F19/F21: llm_*/av/network/clipboard/roi event types must not
; silently fall through KL_BuildInserts's switch).
#Include ../metrics/engine/json.ahk
#Include unit/metrics/engine/test_json_roundtrip.ahk
#Include ../metrics/engine/journal/journal.ahk
#Include ../metrics/engine/system/shutdown.ahk
#Include unit/metrics/engine/system/test_shutdown_timers.ahk
; Event-ID recovery is a pure module extracted from keystats.ahk so its real
; tail parser can be exercised without loading the OS-hooking entry module.
#Include ../metrics/engine/journal/event_id.ahk
#Include unit/metrics/engine/journal/test_event_id.ahk
#Include unit/metrics/engine/capture/test_device_uuid.ahk
#Include unit/metrics/engine/test_full_id_recovery.ahk
; keystats_text_cipher.ahk (KL_Enc_* at-rest encryption) is pure definitions
; with no top-level hotkeys, and keystats_sql.ahk now calls it, so it must load
; before the SQL builders.
#Include ../metrics/engine/privacy/text_cipher.ahk
; keystats_text_migration.ahk (the data.sql rewrite that converts rows stored
; before the setting changed) is likewise pure definitions: its only side effect
; is armed by a timer from KL_Init, which the runner never calls.
#Include ../metrics/engine/privacy/text_migration.ahk
#Include ../metrics/engine/journal/sql.ahk
#Include unit/metrics/engine/journal/test_ingest_encryption_retry.ahk
#Include unit/metrics/engine/journal/test_rollover_recovery.ahk
#Include unit/metrics/engine/test_torn_ledger_tail.ahk
; keystats_hotstring_log.ahk holds KL_LogHotstring — the one persisted row that
; can carry the user's personal data. It was split out of keystats.ahk (which
; installs OS hooks at load and can never be included here) precisely so this
; runner can drive the REAL function against the recording KL_AppendLog /
; KL_Roi_OnHotstring / WPMWidget_Push stubs in test_stubs.ahk. Asserting on a
; test-built copy of the row would have passed against the leaking code.
#Include ../metrics/engine/journal/hotstring_log.ahk
; keystats_watchers.ahk is definition-only. Include it so WTS subscription
; verdict/retry ownership is exercised through the real production functions.
#Include ../metrics/engine/system/watchers.ahk
#Include unit/metrics/engine/test_wts_registration.ahk
; keystats_hook.ahk holds the OTHER sink that can carry the user's personal
; data: the per-keystroke typing buffer. The InputHook observes the driver's own
; auto-typed expansions, so an @iban★ fire reaches KL_Hook_OnChar character by
; character ~90 ms before the redacted hotstring row is written. The file is
; class + function definitions only (the InputHook is created inside
; KL_Hook_Start, which the runner never calls), so the real callbacks can be
; driven headless and the buffer they fill read straight back — the previous
; test asserted only on KL_LogHotstring's row and missed this one entirely.
#Include ../metrics/engine/capture/hook.ahk
#Include ../metrics/engine/capture/mouse.ahk
#Include ../metrics/engine/system/window_topology.ahk
#Include unit/core/ui/windows/test_bounded_focus_snapshot.ahk
#Include unit/core/ui/windows/test_focus_handle_release_reentry.ahk
#Include unit/metrics/engine/capture/test_mouse_coordinates.ahk
#Include unit/metrics/engine/system/test_window_topology.ahk
#Include unit/metrics/engine/system/test_virtual_desktop.ahk
#Include unit/hotstrings/engine/engine/test_fire_log_privacy.ahk
#Include unit/metrics/engine/ergonomics/test_synthetic_typing_row_privacy.ahk
; The near-miss row — the third persisted sink, and the one that had no privacy
; concept at all. _CheckNearMiss lives in hotstring_inputhook.ahk, which the
; prefix-watcher shim above already loads, so these drive the REAL function
; against the recording KL_AppendLog stub rather than a copy of its row.
#Include unit/metrics/engine/ergonomics/test_near_miss_row_privacy.ahk
#Include unit/metrics/engine/test_walker.ahk
#Include unit/metrics/engine/privacy/test_token_encoding.ahk
#Include unit/metrics/engine/ergonomics/test_walker_json_flush_merge.ahk
#Include unit/metrics/engine/ergonomics/test_walker_histogram_partitions.ahk
#Include unit/metrics/engine/journal/test_sql.ahk
#Include unit/metrics/engine/journal/test_sql_literal_controls.ahk
#Include unit/metrics/engine/privacy/test_text_cipher.ahk
#Include unit/metrics/engine/journal/test_sealing.ahk
#Include unit/metrics/engine/privacy/test_text_migration.ahk
#Include unit/settings/engine/migration/test_native_write.ahk
#Include unit/settings/engine/migration/test_open_refusal.ahk
#Include unit/settings/engine/migration/test_keystats_migration_read_refusal.ahk
#Include unit/hotstrings/engine/engine/test_build_inserts_covers_emitted_types.ahk
#Include unit/metrics/engine/metrics/test_and_locale_honesty.ahk
#Include unit/metrics/engine/test_corpus_app_category_store.ahk
#Include unit/metrics/engine/apps/test_categories.ahk
#Include unit/metrics/engine/reader/test_reader.ahk
#Include unit/metrics/engine/reader/test_manifest_contract.ahk
#Include unit/metrics/engine/test_context_nonempty_prepare_owner.ahk
#Include unit/metrics/engine/test_context_roi_stale_owner.ahk
#Include unit/metrics/engine/reader/test_query_catalogue.ahk
#Include unit/metrics/engine/reader/test_klr_manifest_switches_to.ahk
#Include unit/metrics/engine/test_llm_accepted_metrics.ahk
#Include unit/metrics/engine/metrics/test_sqlite_fixture_cleanup.ahk
#Include unit/metrics/engine/test_shortcut_projection.ahk
#Include unit/metrics/engine/test_word_projection_contract.ahk
#Include unit/metrics/engine/test_accuracy_projection_contract.ahk
#Include unit/metrics/engine/test_unicode_projection_contract.ahk
#Include unit/metrics/engine/test_case_projection_contract.ahk
#Include unit/metrics/engine/test_app_pair_projection_contract.ahk
#Include unit/metrics/engine/reader/test_ngram_sources.ahk
#Include unit/metrics/engine/ergonomics/test_roi_prune_bounded.ahk
#Include unit/metrics/engine/reader/test_sql_fail_loud.ahk
#Include unit/metrics/engine/reader/test_klr_ledger_read_refusal.ahk
#Include unit/metrics/engine/journal/test_read_progress.ahk
#Include unit/metrics/engine/reader/test_klr_sql_operational_retry.ahk
#Include unit/core/fs/sqlite/test_read_dispatch.ahk
#Include unit/core/fs/sqlite/test_exec_progress_cleanup.ahk
#Include unit/core/fs/sqlite/test_module_owner.ahk
#Include unit/metrics/engine/reader/test_klr_ledger_chunk_boundary.ahk
#Include unit/metrics/engine/reader/test_klr_cache_fixture.ahk
#Include unit/metrics/engine/reader/test_klr_durable_cache.ahk
#Include unit/metrics/engine/reader/test_klr_multi_ledger_retry.ahk
#Include unit/metrics/engine/reader/test_klr_candidate_live_retry.ahk
#Include unit/metrics/engine/metrics/test_cancel_retry.ahk
#Include unit/metrics/engine/metrics/test_native_start_cancel.ahk
#Include unit/metrics/engine/metrics/test_native_worker_exit.ahk
#Include unit/ai/servers/test_orphan_cleanup_pid.ahk
#Include unit/core/network/adapters/test_http_orphan_liveness.ahk
#Include unit/metrics/engine/reader/test_klr_cache_admission.ahk
#Include unit/metrics/engine/reader/test_klr_cache_offsets.ahk
#Include unit/hotstrings/engine/catalogue/test_count_units.ahk
#Include unit/metrics/engine/context/test_system_missing_durations.ahk
#Include unit/metrics/engine/context/test_system_duration_accounting.ahk
#Include unit/metrics/engine/metrics/test_system_manifest.ahk
#Include unit/metrics/engine/context/test_system_intervals.ahk
#Include unit/metrics/engine/context/test_system_event_owner.ahk
#Include unit/metrics/engine/context/test_system_watcher_intervals.ahk
#Include unit/metrics/engine/reader/test_klr_cold_projection_failure.ahk
#Include unit/metrics/engine/reader/test_klr_cache_date_scope.ahk
#Include unit/metrics/engine/reader/test_klr_projection_paging.ahk
#Include unit/metrics/engine/reader/test_klr_worker_memory_bound.ahk
#Include unit/metrics/engine/reader/test_klr_projection_cursor_int64.ahk
#Include unit/metrics/engine/reader/test_klr_projection_page_work.ahk
#Include unit/metrics/engine/reader/test_klr_projection_sql_failure.ahk
#Include unit/metrics/engine/reader/test_klr_projection_late_page_failure.ahk
#Include unit/metrics/engine/reader/test_klr_cache_publication_order.ahk
#Include unit/metrics/engine/reader/test_klr_cache_save_cadence.ahk
#Include unit/core/fs/sqlite/test_readonly_clone.ahk
#Include unit/core/fs/sqlite/test_clone_page_size.ahk
#Include unit/metrics/engine/reader/test_klr_resident_refresh.ahk
#Include unit/metrics/engine/reader/test_klr_cache_encryption.ahk
#Include unit/metrics/engine/reader/test_klr_newest_first_rebuild.ahk
#Include unit/metrics/engine/metrics/test_rebuild_snapshots.ahk
#Include unit/metrics/engine/reader/test_klr_cache_stages.ahk
#Include unit/metrics/engine/reader/test_klr_cache_open_failure.ahk
#Include unit/metrics/engine/reader/test_klr_utc_offset_migration.ahk
#Include unit/metrics/engine/reader/test_klr_utc_offset_rows.ahk
#Include unit/metrics/engine/reader/test_klr_cache_rejection_identity.ahk
#Include unit/metrics/engine/reader/test_klr_rebuild_publication.ahk
#Include unit/metrics/engine/reader/test_klr_ledger_listing_failure.ahk
#Include unit/metrics/engine/reader/test_klr_cache_copy_failure.ahk
#Include unit/metrics/engine/reader/test_klr_cache_sql_read_failure.ahk
#Include unit/metrics/engine/reader/test_klr_cache_timings.ahk
#Include unit/metrics/engine/reader/test_klr_append_compensation.ahk
#Include unit/metrics/engine/reader/test_klr_closed_comment_refresh.ahk
#Include unit/metrics/engine/reader/test_klr_stream_writer_interleaving.ahk
#Include unit/metrics/engine/metrics/test_full_retry_cadence.ahk
#Include meta/metrics/engine/metrics/test_committed_ingest_signal.ahk
#Include unit/metrics/engine/reader/test_klr_consumed_ledger_identity.ahk
#Include unit/metrics/engine/reader/test_klr_clear_failure.ahk
#Include unit/metrics/engine/reader/test_klr_live_drain_failure.ahk
#Include unit/metrics/engine/metrics/test_prefetch_history_presence.ahk
#Include unit/metrics/engine/metrics/test_historical_json.ahk
#Include unit/metrics/engine/metrics/test_history_seed.ahk
#Include unit/metrics/engine/metrics/test_terminal_exception_cleanup.ahk
#Include unit/metrics/engine/metrics/test_range_date_types.ahk
#Include unit/metrics/engine/metrics/test_range_json_equivalence.ahk
#Include unit/metrics/engine/metrics/test_range_json_failure.ahk
#Include unit/metrics/engine/metrics/test_seed_header.ahk
#Include unit/metrics/engine/metrics/test_manifest_json.ahk
#Include unit/metrics/engine/metrics/test_delta_lifecycle.ahk
#Include unit/metrics/engine/metrics/test_delivery_sequence.ahk
#Include unit/metrics/engine/metrics/test_delivery_midnight.ahk
#Include unit/metrics/engine/metrics/test_prefetch_orphans.ahk
#Include unit/metrics/engine/reader/test_klr_cache_failed_refresh.ahk
#Include unit/metrics/engine/reader/test_klr_category_order.ahk
#Include unit/core/fs/sqlite/test_query_failure.ahk
#Include unit/metrics/engine/reader/test_encrypted_rebuild.ahk
#Include unit/metrics/engine/apps/test_category_projection.ahk
#Include unit/metrics/engine/capture/test_password_fail_closed.ahk
#Include unit/core/lifecycle/test_single_instance_gate.ahk
#Include unit/platform/system/test_worker_tray_icon_hidden.ahk
#Include unit/tray/test_notify_icon.ahk
#Include unit/metrics/engine/system/test_network_transitions.ahk
#Include ../menu/engine/command_origin.ahk
#Include unit/menu/test_command_origin.ahk
#Include unit/menu/test_row_order.ahk
; KLW_GetMap and KLW_GetAppCtx must handle missing context keys without throwing.
#Include unit/metrics/engine/ergonomics/test_walker_ctx_missing_key.ahk
; Shared timings (A3): tap_holds/constants.ahk defines the tap-hold timing
; globals + TapHoldsLoadTimings() and has NO top-level hotkeys, so it is safe to
; include here (unlike most modules/). test_timings_config exercises the shared
; registry reader plus the keystats-walker and tap-hold reassign-at-boot loaders.
#Include ../keyboard/engine/keys/constants.ahk
#Include ../platform/remap/tap_hold_roll.ahk
#Include ../keyboard/engine/keys/altgr_criteria.ahk
#Include unit/keyboard/engine/tap_hold/test_activity_cancel.ahk
#Include unit/keyboard/engine/tap_hold/test_owned_press.ahk
#Include unit/keyboard/engine/tap_hold/test_prior_key.ahk
#Include unit/keyboard/engine/tap_hold/test_tap_keeps_held_modifiers.ahk
#Include unit/keyboard/engine/tap_hold/test_tap_copy_check.ahk
#Include unit/keyboard/engine/tap_hold/test_lone_tap.ahk
#Include unit/keyboard/engine/tap_hold/test_one_shot_timeout.ahk
#Include unit/keyboard/engine/tap_hold/test_shared_file.ahk
#Include unit/keyboard/engine/keys/test_timings_config.ahk
_LogBootProgress("keystats modules + tests included")

; ── Meta tests (codebase hygiene, no production includes needed) ──
#Include meta/suite/test_driver_source_constants.ahk
#Include meta/suite/test_ahk_brace_balance.ahk
#Include meta/suite/test_run_all_include_integrity.ahk
#Include meta/suite/test_runner_only_filter.ahk
#Include meta/suite/test_host_capability_probes.ahk
#Include meta/suite/test_runner_failure_ergonomics.ahk
#Include unit/suite/test_qualification_parser_owner.ahk
#Include meta/suite/test_ahk_os_purity_ratchet.ahk
#Include meta/suite/test_ahk_os_purity_inputs.ahk
#Include meta/core/logger/test_pairing.ahk
#Include meta/core/logger/test_private_label.ahk
#Include meta/ai/servers/test_remote_generate_curl_dispatch.ahk
#Include unit/core/network/adapters/test_dispatch_nonblocking.ahk
#Include unit/core/network/adapters/test_managed_network_failure.ahk
#Include unit/core/network/adapters/test_managed_network_windows_actions.ahk
#Include unit/core/network/adapters/test_managed_terminal_failure.ahk
#Include unit/core/network/adapters/test_system_proxy_retirement.ahk
#Include unit/core/network/adapters/test_pac_source_contract.ahk
#Include unit/core/network/adapters/test_managed_routes_native.ahk
#Include unit/core/network/adapters/test_native_static_scheme_proxy.ahk
#Include unit/core/network/adapters/test_native_ipv6_http_socks.ahk
#Include unit/core/network/adapters/test_native_winhttp_ipv6_host.ahk
#Include unit/core/network/adapters/test_managed_remote_transport.ahk
#Include unit/core/network/adapters/test_managed_remote_cleanup_diagnostics.ahk
#Include unit/core/network/adapters/test_managed_remote_fixture_scope.ahk
#Include unit/core/network/adapters/test_managed_remote_readiness_diagnostics.ahk
#Include unit/modules/updater/test_updater_managed_transport.ahk
#Include unit/modules/updater/test_updater_managed_transport_diagnostics.ahk
#Include unit/modules/updater/test_updater_curl_artifact.ahk
#Include unit/modules/updater/test_updater_curl_capture.ahk
#Include unit/modules/updater/test_updater_curl_capture_namespace.ahk
#Include unit/modules/updater/test_updater_curl_capture_move_graph.ahk
#Include unit/core/network/adapters/test_managed_remote_sspi.ahk
#Include unit/core/network/adapters/test_winhttp_transport.ahk
#Include unit/core/network/adapters/test_native_http_forward_proxy.ahk
#Include unit/core/network/adapters/test_native_relay_hop_branches.ahk
#Include unit/core/network/adapters/test_native_ipv6_relay_upstream.ahk
#Include unit/modules/updater/test_updater_artifact_winhttp.ahk
#Include unit/core/network/adapters/test_managed_winhttp_proxy.ahk
#Include meta/ai/servers/test_remote_connect_timeout_bounded.ahk
#Include meta/metrics/engine/test_json_64bit_decode.ahk
#Include meta/diagnostics/adapters/test_crash_build_offthread.ahk
#Include meta/suite/test_assertions_are_case_sensitive.ahk
#Include meta/suite/test_adapter_contract_exception_delivery.ahk
#Include meta/suite/test_adapter_contract_boolean_types.ahk
#Include meta/suite/test_no_throw_sentinel_delivery.ahk
#Include meta/suite/test_retired_callback_exception_delivery.ahk
#Include meta/suite/test_live_drive_failure_delivery.ahk
#Include meta/suite/test_live_dialog_button.ahk
#Include meta/suite/test_live_right_click_menu.ahk
#Include meta/hotstrings/engine/personal/test_node_shape.ahk
#Include meta/hotstrings/engine/personal/test_seed.ahk
#Include meta/hotstrings/engine/personal/test_new_section_seed.ahk
#Include meta/hotstrings/engine/personal/test_cache_invalidation.ahk
#Include meta/hotstrings/engine/personal/test_toml_write_failure_logged.ahk
#Include meta/hotstrings/engine/catalogue/test_override_atomic_publish.ahk
#Include meta/hotstrings/engine/personal/test_section_label_disambiguation_wired.ahk
#Include meta/suite/test_no_duplicate_defaults.ahk
#Include meta/suite/test_require_state_pattern.ahk
#Include meta/metrics/engine/test_pause_guard.ahk
#Include meta/modules/updater/test_changelog_http_timeout.ahk
#Include meta/platform/system/test_dpapi_decrypt_safe.ahk
#Include meta/menu/test_dispatcher_critical.ahk
#Include meta/menu/test_dispatch_epoch.ahk
#Include meta/ai/api/test_setbackend_propagates_to_engine.ahk
#Include meta/ai/menu/test_persistence_transactions.ahk
#Include meta/ai/api/test_warmup_retry_suspend_guard.ahk
#Include meta/metrics/engine/ergonomics/test_halflife_tick_suspend_guard.ahk
#Include meta/layouts/test_poll_suspend_guard.ahk
#Include meta/layouts/test_poll_native_arming.ahk
#Include meta/keyboard/keys/test_lalt_rctrl_accept_suspend_guard.ahk
#Include meta/keyboard/tap_hold/test_fire_action_suspend_guard.ahk
#Include meta/keyboard/tap_hold/test_native_dispatch_guard.ahk
#Include meta/keyboard/tap_hold/test_taps_use_held_modifier_emitter.ahk
#Include meta/keyboard/tap_hold/test_hotkeys_admit_held_modifiers.ahk
#Include meta/keyboard/tap_hold/test_owned_repeat_identities.ahk
#Include meta/keyboard/layers/test_nav_layer_admits_held_modifiers.ahk
#Include meta/keyboard/keys/test_lshift_lctrl_rshift_bounded_keywait.ahk
#Include meta/layouts/test_poll_blacklist_guard.ahk
#Include meta/layouts/test_quiescence.ahk
#Include meta/keyboard/keys/test_layer_key_under_another_holder.ahk
#Include unit/hotstrings/engine/expander/test_foreground_keyboard_layout.ahk
#Include meta/hotstrings/engine/engine/test_hse_register_atomic.ahk
#Include meta/hotstrings/engine/engine/test_hse_rebuild_guard.ahk
#Include meta/hotstrings/engine/engine/test_hse_rebuild_prefix_buffer_reset.ahk
#Include meta/gestures/test_shared_lbutton.ahk
#Include meta/gestures/test_left_hold_tap_release.ahk
#Include meta/gestures/test_takenote_winwait.ahk
#Include meta/gestures/test_takenote_hotpath_nonblocking.ahk
#Include meta/gestures/test_gesture_takenote_winmaximize_guard.ahk
#Include meta/gestures/test_get_cyclable_windows_catch.ahk
#Include meta/gestures/test_open_downloads_nonblocking.ahk
#Include meta/gestures/test_searchpath_regjump_catch.ahk
#Include meta/gestures/test_getpath_clipboard_receipt.ahk
#Include meta/core/ui/windows/test_path_dialog_button_race.ahk
#Include meta/gestures/test_exit_button_release.ahk
#Include meta/core/lifecycle/engine/test_onexit_terminal_order.ahk
#Include meta/platform/input/test_textsend_clipall.ahk
#Include meta/platform/input/test_text_sender_clipboard_restore.ahk
#Include meta/ai/navigation/test_autotype_hse_suppress.ahk
#Include meta/metrics/engine/journal/test_ingest_tick_guards.ahk
#Include meta/metrics/engine/journal/test_ingest_failure_requeues.ahk
#Include meta/gestures/test_keywatcher_suspend.ahk
#Include meta/gestures/test_activitysim_collision.ahk
#Include meta/metrics/engine/metrics/test_focus_cache_atomic.ahk
#Include meta/metrics/engine/metrics/test_focus_ttl_leak.ahk
#Include meta/metrics/engine/metrics/test_focus_off_thread.ahk
#Include meta/platform/input/test_clipboard_ram_leak.ahk
#Include meta/keyboard/keys/test_space_tap_dispatch.ahk
#Include meta/platform/input/dispatch/test_verdict_consumed.ahk
#Include meta/hotstrings/engine/engine/test_fire_log_never_synchronous.ahk
#Include meta/hotstrings/engine/engine/test_deferred_hotstring_lifecycle_guards.ahk
#Include meta/metrics/engine/ergonomics/test_roi_map_mutation_race.ahk
#Include meta/hotstrings/engine/catalogue/test_deferred_registration_live_rebuild_race.ahk
#Include meta/core/ui/windows/test_spotlight_non_blocking.ahk
#Include meta/core/ui/windows/test_spotlight_gdiplus_leak.ahk
#Include meta/core/text/test_toml_batchwrite_atomic.ahk
#Include unit/core/text/toml/test_batchwrite_exact_subtree.ahk
#Include meta/core/ui/webview/test_webview2_temp_leak.ahk
#Include meta/metrics/engine/view/test_webview_fallback.ahk
#Include meta/core/ui/windows/test_graphics_renderer_createwindow_catch.ahk
#Include meta/ai/servers/test_ollama_webview_executescript_deferred.ahk
#Include meta/ai/servers/test_ollama_webview_callback_epoch.ahk
#Include meta/metrics/engine/view/test_webview_executescript_deferred.ahk
#Include meta/core/ui/webview/test_low_ram_native_fallback.ahk
#Include meta/platform/input/dispatch/test_hookdispatcher_swallow.ahk
#Include meta/ai/api/test_json_parser_silent_fail.ahk
#Include meta/core/text/test_json_unicode_escape.ahk
#Include meta/diagnostics/ui/test_healthcheck_recordwarn_called.ahk
#Include meta/modules/shortcuts/test_wrap_symbol_disabled_state.ahk
#Include meta/gestures/test_screenshot_region_clipwait_clobber.ahk
#Include meta/metrics/engine/context/test_av_mute_heuristic.ahk
#Include meta/metrics/engine/ergonomics/test_ergo_roi_count_synth.ahk
#Include meta/ai/profiles/test_delete_path.ahk
#Include meta/ai/navigation/test_nav_val_modifiers_wired.ahk
#Include meta/modules/updater/test_updater_sync_winhttp_blocks.ahk
#Include meta/core/fs/test_sqlite_progress_yield.ahk
#Include meta/metrics/engine/ergonomics/test_agg_app_day_llm_suggested.ahk
#Include meta/metrics/engine/reader/test_preserves_walker_aggregates.ahk
#Include meta/hotstrings/engine/catalogue/test_check_constraint_widened.ahk
#Include meta/core/logger/test_sync_warning.ahk
#Include meta/metrics/engine/test_deferred_write.ahk
#Include meta/keyboard/layers/test_deadkey_timeout.ahk
#Include meta/modules/shortcuts/test_sendinstant_deferred_clipboard.ahk
#Include meta/modules/shortcuts/test_keepawake_pause_gate.ahk
#Include meta/modules/shortcuts/test_keepawake_stop_notify_gate.ahk
#Include meta/gestures/test_mouse_park_gate.ahk
#Include meta/gestures/test_mouse_hotkey_clobber.ahk
#Include meta/gestures/test_mouse_suspend_guard.ahk
#Include meta/metrics/engine/test_scroll_flush_fn_cleared_on_stop.ahk
#Include meta/metrics/engine/system/test_watchers_pause_guard.ahk
#Include unit/metrics/engine/test_session_privacy_transaction.ahk
#Include unit/metrics/engine/test_session_close_retry.ahk
#Include unit/metrics/engine/test_native64_clock.ahk
#Include unit/metrics/engine/test_arrival_fifo.ahk
#Include unit/metrics/engine/capture/test_mouse_privacy_transaction.ahk
#Include meta/modules/shortcuts/test_uia_selection_background_poll.ahk
#Include meta/modules/shortcuts/test_uia_selection_snapshot.ahk
#Include meta/core/ui/tooltip/test_render_epoch.ahk
#Include meta/core/ui/tooltip/test_position_cache_receipt_wiring.ahk
#Include meta/ai/tooltip/test_render_epoch.ahk
#Include meta/ai/profiles/test_presented_record_single_source.ahk
#Include meta/ai/servers/test_remote_poll_deadline.ahk
#Include meta/modules/updater/test_download_integrity_guard.ahk
#Include meta/suite/test_no_coauthor_in_commits.ahk
#Include meta/core/lifecycle/engine/test_bundle_exclusions.ahk
#Include meta/ai/menu/test_init_order.ahk
#Include meta/ai/api/test_ensure_model_ready_guard.ahk
#Include meta/core/lifecycle/engine/test_boot_deferred_tasks.ahk
#Include meta/core/lifecycle/engine/test_boot_error_fatal_before_ready.ahk
#Include meta/core/lifecycle/engine/test_hotif_globals_boot_safe.ahk
#Include meta/suite/test_hotif_directive_lexical_boundaries.ahk
#Include meta/core/logger/test_error_net_prelogger_safe.ahk
#Include meta/core/lifecycle/engine/test_boot_paths_fail_soft.ahk
#Include meta/metrics/ui/test_wpm_widget_native_render.ahk
#Include meta/metrics/ui/test_wpm_widget_hidden_until_typed.ahk
#Include meta/metrics/ui/test_wpm_boot_show_respects_disable.ahk
#Include meta/metrics/ui/test_wpm_graph_upload_acknowledgement.ahk
#Include meta/modules/shortcuts/test_wrap_remap_uses_saved_custom_pair.ahk
#Include meta/platform/focus/uia/test_selection_withholds_capped_text.ahk
#Include meta/hotstrings/engine/catalogue/test_text_expansion_critical_path.ahk
#Include meta/platform/input/test_text_sender_clipboard_failure.ahk
#Include meta/platform/input/test_text_sender_clipboard_sequence_ownership.ahk
#Include meta/core/ui/windows/test_download_window_i18n_fallback.ahk
#Include meta/menu/test_tray_build_critical_restore.ahk
#Include meta/menu/test_tray_root_terminal_forwarding.ahk
#Include meta/hotstrings/engine/prefix/test_watcher_deferred.ahk
#Include meta/hotstrings/engine/catalogue/test_ready_contract.ahk
#Include meta/settings/test_native_hotstrings_migrated.ahk
#Include meta/hotstrings/engine/engine/test_hse_send_transaction_guard.ahk
#Include meta/core/i18n/test_fallback_deferred.ahk
#Include unit/hotstrings/engine/engine/test_hse_conform_double_fire.ahk
#Include meta/ai/menu/test_deferred_build.ahk
#Include meta/core/logger/test_format_placeholders.ahk
#Include meta/core/logger/test_sub_files_routing.ahk
#Include meta/hotstrings/engine/prefix/test_render_deferred.ahk
#Include meta/hotstrings/engine/prefix/test_visible_suggestion_epoch.ahk
#Include meta/platform/input/test_serialization.ahk
#Include meta/hotstrings/engine/engine/test_fire_log_defer_after_suppress.ahk
#Include meta/hotstrings/engine/engine/test_repeat_fire_category_hosts.ahk
#Include meta/hotstrings/engine/engine/test_repeat_private_ancestry.ahk
#Include meta/hotstrings/engine/engine/test_ai_context_unknown_edit.ahk
#Include meta/hotstrings/engine/engine/test_hse_suppress_release_bounded.ahk
#Include meta/hotstrings/engine/engine/test_hse_physical_suppression_provenance.ahk
#Include meta/hotstrings/engine/engine/test_hse_endchar_index_bound.ahk
#Include meta/hotstrings/engine/engine/test_hse_physical_input_provenance.ahk
#Include meta/platform/focus/uia/test_wrap_suppress_latch.ahk
#Include meta/metrics/engine/ergonomics/test_near_miss_scan_bounded.ahk
#Include meta/gestures/test_cycle_winevent_fence.ahk
#Include meta/gestures/test_cycling_flag_critical.ahk
#Include meta/ai/api/test_app_filter_enforced.ahk
#Include meta/ai/navigation/test_instant_word_end_trigger.ahk
#Include meta/ai/tooltip/test_chunk_type_guard.ahk
#Include meta/keyboard/keys/test_space_hold_suspend_guard.ahk
#Include meta/ai/api/test_av_warmup_cancellable.ahk
#Include meta/ai/servers/test_remote_poll_com_exception_bails.ahk
#Include meta/hotstrings/engine/catalogue/test_cle_emoji_gated.ahk
#Include meta/hotstrings/engine/engine/test_hse_consumed_endchar_ring.ahk
#Include meta/hotstrings/engine/engine/test_expansion_burst_atomic.ahk
#Include meta/core/text/test_parsetomlfile_unterminated_array_recovers.ahk
#Include meta/platform/input/dispatch/test_dispatcher_register_duplicate_label.ahk
#Include meta/modules/updater/test_updater_cancel_fires_on_json.ahk
#Include meta/modules/updater/test_updater_download_receive_timeout.ahk
#Include meta/modules/updater/test_updater_download_reentrancy_guard.ahk
#Include meta/modules/updater/test_updater_download_requires_consent.ahk
#Include meta/modules/updater/test_updater_prompt_uses_shared_notes.ahk
#Include meta/hotstrings/engine/personal/test_load_once.ahk
#Include meta/ai/menu/test_actions_include.ahk
#Include meta/ai/menu/test_suspend_bootstrap.ahk
#Include meta/ai/api/test_backend_lifecycle_ownership.ahk
#Include meta/ai/menu/test_disabled_greyed.ahk
#Include meta/hotstrings/engine/test_language_menu_deferred_publication.ahk
#Include meta/ai/menu/test_layout_shared.ahk
; MenuManifest_LoadTopLevel/LoadGlobalActions/LoadDebugMenu — needed so the
; top-level drift gate stages the root from the real shared manifest.
#Include ../menu/engine/manifest.ahk
; The generic manifest walker. Pure function definitions — no top-level
; statements, no includes — so pulling it in is side-effect free, and it lets
; disabled_when tests exercise the real resolver instead of scanning its source.
#Include ../menu/engine/manifest_menu.ahk
#Include unit/menu/test_population.ahk
#Include unit/menu/test_startup_commands.ahk
#Include unit/settings/engine/persistence/test_registry_cache.ahk
#Include unit/ai/api/test_runtime_activation.ahk
; The tray root builder: its top-level dispatcher and the id → builder table.
; Function definitions only, and the table names only its own _MI_ builders,
; so pulling it in stages nothing and resolves no menu dependency at load.
; The Applications stage the root builder table names.
#Include ../apps/ui/menu/apps.ahk
#Include ../menu/ui/builder/menu_init.ahk
#Include unit/apps/test_bundled_apps.ahk
; Drift gate: the staged tray root follows the manifest's top level, separators included.
#Include meta/menu/test_top_level_drift_gate.ahk
; Regression: no separator doubles up in any manifest menu.
#Include unit/menu/test_manifest_menu_no_double_separator.ahk
; Regression: every section header titles real rows, drawn by the shared format.
#Include unit/menu/test_manifest_menu_section_headers.ahk
#Include unit/menu/test_category_off_rule.ahk
; Regression: every category switch is a first-row checkbox with one label.
#Include unit/hotstrings/engine/catalogue/test_category_toggle_checkbox.ahk
#Include unit/menu/test_choice_row.ahk
; Regression: each hotstring « tout activer » / « tout désactiver » pair is one checkbox.
#Include unit/hotstrings/engine/catalogue/test_bulk_checkboxes.ahk
; Regression: Shortcuts submenu block separator and screenshot key label.
#Include unit/modules/shortcuts/test_shortcuts_menu_blocks.ahk
#Include unit/modules/shortcuts/test_shortcuts_personal_data_frame.ahk
#Include unit/modules/shortcuts/test_shortcuts_personal_data_native_port.ahk
#Include unit/modules/shortcuts/test_shortcuts_extension_results.ahk
#Include unit/modules/shortcuts/test_shortcuts_menu_groups_unique.ahk
#Include unit/modules/shortcuts/test_keyboard_slot_group_scope.ahk
; Contract gate: metrics_menu disabled_when predicate == AHK handler resolver calls (MG-1/MG-2).
#Include meta/menu/test_list_providers_touch_no_menu.ahk
#Include meta/metrics/engine/metrics/test_menu_metrics_disabled_when.ahk
#Include unit/metrics/engine/metrics/test_widget_menu_parity.ahk
#Include meta/platform/system/test_port_adapter_coverage.ahk
#Include meta/suite/test_no_class_global_conflict.ahk
#Include meta/core/i18n/test_json_valid.ahk
#Include meta/modules/shortcuts/test_wrap_symbols_gate.ahk
#Include meta/modules/shortcuts/test_wrap_symbols_catalogue.ahk
#Include unit/modules/shortcuts/test_wrap_symbols_global_transaction.ahk
#Include unit/modules/shortcuts/test_wrap_symbols_single_symbol.ahk
; ── Cross-driver corpus consumers ──
#Include support/toml_corpus_values.ahk
#Include meta/corpus/test_corpus_hotstrings.ahk
#Include meta/hotstrings/engine/preview/test_matches_engine.ahk
#Include meta/hotstrings/engine/prefix/test_buffer_tracks_engine.ahk
#Include meta/hotstrings/engine/prefix/test_buffer_atomic_transitions.ahk
#Include meta/hotstrings/engine/engine/test_nav_cluster_resets_both_buffers.ahk
#Include meta/hotstrings/engine/preview/test_never_wiped_alone.ahk
#Include meta/hotstrings/engine/preview/test_engine_single_owner.ahk
#Include meta/corpus/test_corpus_dynamic_hotstrings_prefix.ahk
#Include meta/corpus/test_corpus_hotstrings_config_resolve.ahk
#Include meta/corpus/test_corpus_hotstring_family_samples.ahk
#Include meta/corpus/test_corpus_hotstring_override_parse.ahk
#Include meta/corpus/test_corpus_tap_hold.ahk
#Include meta/corpus/test_corpus_tap_hold_decisions.ahk
#Include meta/corpus/test_corpus_keymap_layers.ahk
#Include meta/corpus/test_corpus_hotstring_matcher.ahk
; LLM parser corpus -- tests LLM_ParseOllamaResponse and _LLMRemoteParseResponse
; against the shared cross-driver vectors (already included above via api_ollama/api_remote).
#Include meta/corpus/test_corpus_llm_parser.ahk
; Security / keystats privacy corpus -- tests ES_PASSWORD detection and
; Win32 known-class lookup logic in isolation (OS-level paths are headless-safe stubs).
#Include meta/corpus/test_corpus_security_keystats.ahk
; PromptBuilder corpus -- tests the generated PromptBuilder class against the
; shared cross-driver vectors.
#Include ../_generated/prompt_builder.ahk
#Include meta/corpus/test_corpus_prompt_builder.ahk
; Chord notation corpus -- runs the shared _shared/keyboard/engine/chord/vectors.json against
; the AutoHotkey twin, plus the native-translation half that is supposed to differ.
#Include ../keyboard/engine/layers/chord.ahk
#Include ../platform/input/hotkey_registrar.ahk
#Include ../../_shared/shortcuts/data/magic_editor.ahk
#Include ../keyboard/engine/magic_editor.ahk
#Include meta/keyboard/key_combinations/test_chord_notation.ahk
#Include unit/platform/input/test_hotkey_registrar_transactions.ahk
#Include unit/platform/input/test_hotkey_registrar_aliases.ahk
#Include unit/platform/input/test_hotkey_registrar_modifier_keys.ahk
#Include unit/hotstrings/engine/magic_key/test_magic_editor.ahk
#Include unit/keyboard/engine/key_combinations/test_slot_win_space.ahk
#Include unit/keyboard/engine/key_combinations/test_slot_neutral_roles.ahk
#Include unit/ai/actions/test_trigger_shortcut_retired.ahk
#Include unit/ai/navigation/test_hotkey_identity.ahk
#Include unit/ai/navigation/test_nav_event_owner.ahk
; Reuses the navigation owner's deterministic native port and fixtures above.
#Include unit/ai/navigation/test_tab_accepts_visible_prediction.ahk
#Include unit/ai/tooltip/test_nav_consumed.ahk
; Reuses the chord helpers of test_llm_tooltip_nav_consumed above.
#Include unit/ai/navigation/test_nav_cycle_windows.ahk
#Include unit/ai/navigation/test_nav_hotkey_transaction.ahk
#Include unit/ai/navigation/test_nav_hotkey_native_transaction.ahk
#Include unit/ai/navigation/test_profile_hotkey_transaction.ahk
#Include unit/ai/navigation/test_hotkeys_deferred_by_pause.ahk
#Include unit/ai/navigation/test_hotkey_cross_owner_collision.ahk
#Include unit/ai/navigation/test_hotkey_contextual_routes.ahk
#Include meta/ai/navigation/test_hotkey_cross_owner_policy.ahk
#Include meta/settings/test_transition_integration.ahk
; Logger behaviour corpus -- severity filtering and the ring buffer, from the
; same shared file the macOS and Linux suites replay.
#Include meta/corpus/test_corpus_logger_behaviour.ahk
; TOML fuzz corpus -- exercises ParseTomlFile() against 50 adversarial inputs.
; Asserts the loader never crashes on any input (valid or invalid TOML).
#Include meta/corpus/test_corpus_toml_fuzz.ahk
#Include meta/core/text/test_toml_inline_comment_stripping.ahk
#Include meta/core/text/test_toml_read_failure_is_loud.ahk
#Include meta/settings/persistence/test_boot_read_failure_blocks_persist.ahk
#Include meta/settings/persistence/test_persist_result_not_discarded.ahk
#Include meta/settings/persistence/test_callers.ahk
#Include meta/settings/persistence/test_recovery_gateway.ahk
; Keystats aggregation corpus -- tests KLW_WalkTypingEntry / KLW_WalkAppSwitch /
; KLW_WalkWindowSwitch / KLW_WalkSystemEvent against shared cross-driver vectors.
#Include meta/corpus/test_corpus_keystats_aggregation.ahk
#Include meta/corpus/test_corpus_keystats_session_events.ahk
#Include meta/corpus/test_corpus_keystats_correction_erased.ahk
#Include meta/corpus/test_corpus_keystats_metrics_maintenance.ahk
; Healthcheck snapshot corpus -- tests _HealthCheck_FormatUptime and validates
; the golden vectors for the shared snapshot logic (format_uptime, issues, schema).
#Include meta/corpus/test_corpus_healthcheck_snapshot.ahk
; Updater release parser corpus -- tests Updater_ParseTagName / Updater_ParseBody /
; _Updater_ParsePrerelease / _Updater_SplitReleasesArray against shared cross-driver vectors.
#Include meta/corpus/test_corpus_updater_release_parser.ahk
; Locale resolution corpus -- tests t() cascade (active→en→fr→raw key) and ★
; substitution against shared cross-driver vectors.
#Include meta/corpus/test_corpus_locale_resolution.ahk
; Tooltip layout corpus -- validates _TooltipClampToScreen against shared
; cross-driver vectors.
#Include meta/corpus/test_corpus_tooltip_layout.ahk
; TOML coercion corpus
#Include meta/corpus/test_corpus_toml_batch_write.ahk
#Include meta/corpus/test_corpus_updater_redirect.ahk
#Include meta/corpus/test_corpus_config_scope_plan.ahk
#Include meta/corpus/test_corpus_menu_numbered_caption.ahk
#Include meta/corpus/test_corpus_llm_small_families.ahk
#Include meta/corpus/test_corpus_llm_request_plan.ahk
#Include meta/corpus/test_corpus_terminators_and_llm_rows.ahk
#Include meta/corpus/test_corpus_tap_hold_labels.ahk
#Include meta/corpus/test_corpus_toml_hotstring_reader.ahk
#Include meta/corpus/test_corpus_toml_leaf_rows.ahk
#Include meta/corpus/test_corpus_toml_inline_scalar.ahk
#Include meta/corpus/test_corpus_toml_coercion.ahk

; -- Audit finding regression tests (batch-wired) --
#Include meta/hotstrings/engine/catalogue/test_activate_hotstrings_sleep_gate.ahk
#Include meta/core/ui/windows/test_app_picker_t_variable_shadows_i18n.ahk
#Include meta/core/lifecycle/engine/test_appstate_orphaned_parallel_state.ahk
#Include meta/metrics/engine/context/test_av_no_blocking_registry_walk.ahk
#Include meta/core/ui/tooltip/test_border_gdi_cleanup_broken_nesting.ahk
#Include meta/core/ui/tooltip/test_measure_gdi_ownership.ahk
#Include meta/keyboard/keys/test_capslock_led_single_owner.ahk
#Include meta/settings/persistence/test_shortcuts_array_escape.ahk
#Include meta/settings/persistence/test_window_delay_write_per_keystroke.ahk
#Include meta/settings/persistence/test_window_republishes_baked_fields.ahk
#Include meta/settings/persistence/test_window_no_delimiter_ui.ahk
#Include meta/core/network/test_curl_payload_pii_temp_leak.ahk
#Include meta/keyboard/layers/test_deadkey_suspend_guard.ahk
#Include meta/menu/test_deferred_menu_critical_file_io.ahk
#Include meta/platform/input/dispatch/test_dequeue_poll_no_suspend_guard.ahk
#Include meta/platform/input/dispatch/test_dispatcher_map_never_cleared_stale_misfire.ahk
#Include meta/platform/input/dispatch/test_dispatcher_start_guarded.ahk
#Include meta/platform/input/dispatch/test_dispatcher_start_ungated.ahk
#Include meta/platform/input/dispatch/test_dispatcher_stop_wired.ahk
#Include meta/suite/test_driver_source_helpers_fail_loudly.ahk
#Include meta/suite/test_driver_source_partial_reads.ahk
#Include meta/suite/test_driver_body_cache.ahk
#Include meta/suite/test_driver_block_comment_extraction.ahk
#Include meta/suite/test_driver_symbol_case.ahk
#Include meta/suite/test_driver_quoted_definitions.ahk
#Include meta/diagnostics/adapters/test_error_handler_heavy_diagnostics.ahk
#Include meta/hotstrings/engine/catalogue/test_ext_builder_fn_dynamic_call_swallow.ahk
#Include meta/gestures/test_gesturepickcolor_clipboard_clobber.ahk
#Include meta/modules/shortcuts/test_getselection_blocks_and_eats_keys.ahk
#Include meta/diagnostics/adapters/test_global_error_handler_sendevent_storm.ahk
#Include meta/hotstrings/engine/engine/test_output_host_resolver_single_owner.ahk
#Include meta/gestures/test_modifier_release_class.ahk
#Include meta/diagnostics/ui/test_health_probe_timer_suspend_guard.ahk
#Include meta/diagnostics/ui/test_healthcheck_init_dead_reference.ahk
#Include meta/diagnostics/ui/test_healthcheck_webview_handler.ahk
#Include meta/hotstrings/engine/engine/test_hse_disable_group_atomic.ahk
#Include meta/menu/test_insert_id_discovery_label_collision.ahk
#Include meta/settings/persistence/test_isrepeat_section_name_mismatch_latent_divergence.ahk
#Include meta/hotstrings/engine/catalogue/test_text_expansion_auto_toml_backed.ahk
#Include meta/keyboard/keys/test_kh_intercept_dead_flag.ahk
#Include meta/metrics/engine/test_kl_refresh_context_blocks_on_keystroke.ahk
#Include meta/metrics/engine/test_kl_stop_dead_no_exit_flush.ahk
#Include meta/metrics/engine/test_kl_switch_privacy_filter_outgoing.ahk
#Include meta/metrics/engine/test_kl_window_switch_pre_flush.ahk
#Include meta/metrics/engine/test_klpf_writeatomic_delete_window.ahk
#Include meta/metrics/engine/reader/test_klr_builddatabase_debug_fileappend_hot.ahk
#Include meta/metrics/engine/reader/test_klr_builddatabase_failure_logged.ahk
#Include meta/metrics/engine/ergonomics/test_klw_ctx_unbounded_hist_growth.ahk
#Include meta/keyboard/keys/test_lalt_capslock_tap_min_duration.ahk
#Include meta/keyboard/keys/test_lalt_tab_requires_hold_layer.ahk
#Include meta/ai/navigation/test_accept_cleanup_in_finally.ahk
#Include meta/ai/prediction/test_failure_callback_arity.ahk
#Include meta/ai/navigation/test_inline_autotype_suspend_guard.ahk
#Include meta/ai/navigation/test_pointer_watch_not_stopped_on_suspend.ahk
#Include meta/core/text/test_loader_toml_injection_readfile_hotpath.ahk
#Include meta/gestures/test_lock_workstation_named_helper.ahk
#Include meta/metrics/engine/test_lost_tick_after_filtered_keystroke.ahk
#Include meta/menu/test_dispatch_callbacks_unbounded_growth.ahk
; Deep-liveness: the prune's tray walk reaches items at any depth (F07 deep-liveness).
#Include meta/menu/test_dispatch_deep_liveness.ahk
; Prune collects live IDs once, not per tracked ID — O(tray+tracked) (menu-prune-quadratic-tray-walk).
#Include meta/menu/test_prune_quadratic_tray_walk.ahk
#Include meta/metrics/engine/context/test_ni_isvpnactive_missing_return.ahk
#Include meta/metrics/engine/test_no_onexit_keystats_flush.ahk
#Include meta/ui/onboarding/test_onboarding_no_appstate.ahk
#Include meta/ui/onboarding/test_onboarding_toml_bool_reads.ahk
#Include meta/ui/onboarding/test_onboarding_effective_config_dir.ahk
#Include meta/core/ui/windows/test_numeric_prompt_throws_on_nonnumeric.ahk
#Include meta/keyboard/keys/test_oneshotshift_lalt_lshift_stuck.ahk
#Include meta/keyboard/keys/test_oneshotshift_suspend_guard.ahk
#Include meta/keyboard/keys/test_hold_modifier_release_bounded.ahk
#Include meta/keyboard/altgr/test_rolls_precedence.ahk
#Include meta/metrics/engine/test_session_watcher_synth.ahk
#Include meta/metrics/engine/test_kl_stop_flush_survives_suspend.ahk
#Include meta/ai/prediction/test_onkeydown_dead_llm_branch.ahk
#Include meta/core/text/test_parser_ord_empty_token_crash.ahk
#Include meta/metrics/engine/context/test_password_cache_torn_write.ahk
#Include meta/gestures/test_paste_plain_nontext_clip_guard.ahk
#Include meta/core/text/test_pathstoml_read_missing_utf8_encoding.ahk
#Include meta/hotstrings/engine/personal/test_ext_scan_unbounded_recursion.ahk
#Include meta/platform/input/dispatch/test_pointer_watch_timer_bypasses_suspend.ahk
#Include meta/hotstrings/engine/prefix/test_index_rebuild_no_suspend_guard.ahk
#Include meta/hotstrings/engine/prefix/test_onkeydown_tab_llm_feed_gap.ahk
#Include meta/platform/system/test_reg_keyexists_value_only.ahk
#Include meta/hotstrings/adapters/test_registry_oserror_number_not_extra.ahk
#Include meta/keyboard/layers/test_emit_critical_uneven.ahk
#Include meta/ai/servers/test_remote_api_validate_async.ahk
#Include meta/metrics/engine/ergonomics/test_roi_current_word_unbounded_growth.ahk
#Include meta/metrics/engine/ergonomics/test_roi_full_map_prune_scan_on_hot_path.ahk
#Include meta/modules/shortcuts/test_sendinstant_reentrancy_guard.ahk
#Include meta/metrics/engine/context/test_sensors_cpu_state_stale_across_reload.ahk
#Include meta/keyboard/tap_hold/test_space_altgr_double_raalt_down.ahk
#Include meta/metrics/engine/context/test_ssid_utf8_misdecode_and_signal_offset.ahk
#Include meta/ai/api/test_stream_final_flush_sleep_blocks_thread.ahk
#Include meta/core/text/test_strict_canon_does_not_drop_stale_keys.ahk
#Include meta/core/lifecycle/engine/reload/test_suspend_watchdog_no_prefix_keywait.ahk
#Include meta/platform/input/test_owned_inputhooks_suspend.ahk
#Include meta/platform/input/test_blocking_inputhook_suspend_ownership.ahk
#Include meta/platform/input/dispatch/test_timer_scheduler_registration_transaction.ahk
#Include meta/modules/updater/test_updater_finalize_nonblocking.ahk
#Include meta/core/lifecycle/engine/test_bundle_upgrade_transaction.ahk
#Include meta/ai/navigation/test_tab_accept_cancels_timer.ahk
#Include meta/platform/input/test_textsend_clipboard_thread.ahk
#Include meta/suite/test_tint_test_stale_constants_comment.ahk
#Include meta/core/ui/tooltip/test_hide_non_blocking.ahk
#Include meta/core/ui/tooltip/test_teardown_on_keyboard_thread.ahk
#Include meta/ai/prediction/test_bridge_deferred_hides.ahk
#Include meta/metrics/engine/context/test_topo_checkvirtualdesktop_stale_prev_hwnd.ahk
#Include meta/menu/test_traymenu_separator_addstandard.ahk
#Include meta/menu/test_traymenu_setmenu_raw_add.ahk
#Include meta/keyboard/tap_hold/test_menu_register_dispatch.ahk
#Include meta/menu/test_dispatch_error_propagation.ahk
#Include meta/core/ui/windows/test_launch_error_msgbox_on_timer_thread.ahk
#Include meta/platform/focus/uia/test_error_logged.ahk
#Include meta/modules/updater/test_updater_focus_poll_suspend_guard.ahk
#Include meta/modules/updater/test_updater_setchannel_cancels_async.ahk
#Include meta/modules/updater/test_updater_setchannel_blocks_during_download.ahk
#Include meta/modules/updater/test_updater_setcheckinterval_coerces.ahk
#Include meta/modules/updater/test_updater_scheduler_off_typing_path.ahk
#Include meta/core/ui/webview/test_temp_dir_and_com_leak_on_reload.ahk
#Include meta/hotstrings/engine/engine/test_win_l_lock_resets_context.ahk
#Include meta/core/network/test_winhttp_no_abort_on_poll_timeout.ahk
#Include meta/gestures/test_winorder_unbounded_and_cross_thread.ahk
#Include meta/metrics/ui/test_wpm_push_unguarded_debug_arg_build.ahk
#Include meta/metrics/ui/test_wpm_config_position_pair_validation.ahk
#Include meta/metrics/ui/test_wpm_tray_readout_wiring.ahk
#Include meta/metrics/ui/test_wpm_persistence_transaction.ahk
#Include meta/settings/persistence/test_full_save_generation_guard.ahk
#Include meta/metrics/ui/test_wpm_ring_buffer_cross_thread_race.ahk
#Include unit/core/process/shell_runner/test_coalesced_job_callbacks_dropped.ahk
#Include unit/hotstrings/engine/personal/test_count_regex_vs_entry_pattern_divergence.ahk
#Include unit/core/text/toml/test_counttoml_overcounts_personal_meta_sections.ahk
#Include unit/hotstrings/engine/personal/test_delay_edit_non_integer_personal_truncation.ahk
#Include unit/settings/engine/persistence/test_freshness_same_second_edit_window.ahk
#Include unit/platform/input/test_inline_autotype_not_synthetic.ahk
#Include unit/core/text/toml/test_loadexttoml_skips_meta_sections.ahk
#Include unit/core/text/toml/test_json_number_misleading_error.ahk
#Include unit/core/text/toml/test_json_string_fast_path.ahk
#Include unit/core/text/toml/test_json_object_key_nul.ahk
#Include unit/core/text/toml/test_json_native_string_scan.ahk
#Include unit/ai/servers/test_ollama_curl_temp_pii_plaintext.ahk
#Include unit/core/text/toml/test_parsetomlgroupconfig_missing_file_cache_key.ahk
#Include unit/core/text/toml/test_parsetomlgroupconfig_missing_file_cache_key_mismatch.ahk
#Include unit/hotstrings/engine/personal/test_per_entry_priority_divergence_cache_vs_toml.ahk
#Include unit/core/process/shell_runner/test_plc_closure_callable.ahk
#Include unit/core/process/shell_runner/test_win_ps_version_check.ahk
#Include unit/ai/servers/test_remote_parse_first_content_match.ahk
#Include unit/hotstrings/engine/engine/test_stale_cache_survives_reset_and_pause.ahk
#Include unit/hotstrings/engine/engine/test_time_activation_fails_open_on_missing_prev_char.ahk
#Include unit/core/text/toml/test_uridecode_multibyte_utf8_corruption.ahk

; -- Audit finding regression tests (batch-wired) --
#Include meta/suite/test_generated_substr_minus_one.ahk
#Include meta/core/text/test_toml_multiline_array_depth.ahk
#Include meta/core/text/test_toml_unescape_ordering.ahk
#Include meta/platform/input/test_clipboard_sentinel.ahk
#Include meta/platform/input/test_clipboard_saveall_sentinel.ahk
#Include meta/platform/input/test_textsend_callback_wired.ahk
#Include meta/settings/persistence/test_is_category_all_enabled_loop.ahk
#Include meta/platform/system/test_regread_no_type_arg.ahk
#Include meta/core/logger/test_dedup_tick.ahk
#Include meta/hotstrings/engine/prefix/test_watcher_magic_suffix.ahk
#Include meta/hotstrings/engine/magic_key/test_deadkey_uses_dynamic_magic_key.ahk
#Include meta/core/text/test_parse_overrides_seen_sections.ahk
#Include meta/ai/api/test_getactiveprofile_arg.ahk
#Include meta/platform/input/dispatch/test_tickcount_wrap_safe.ahk
#Include meta/platform/input/dispatch/test_tickcount_lib_wrap.ahk
#Include meta/ai/api/test_token_budget_min5.ahk
#Include meta/ai/prediction/test_parser_nul_strip.ahk
#Include meta/metrics/engine/ergonomics/test_ergo_pinky_modifier_skip.ahk
#Include meta/metrics/engine/context/test_watchers_idle_end_ordering.ahk
#Include meta/platform/input/dispatch/test_timer_scheduler_ms_guard.ahk
#Include meta/core/network/test_http_cancel_aborts.ahk
#Include meta/platform/input/test_keyboard_hook_vk_format.ahk
#Include meta/core/process/shell_runner/test_plc_stop_clears_callbacks.ahk
#Include meta/core/text/test_toml_coerce_quoted_commas.ahk
#Include meta/core/i18n/test_setlocale_resets_fallback.ahk
#Include meta/modules/shortcuts/test_ws_save_atomic.ahk
#Include meta/keyboard/tap_hold/test_tapholdwriter_int_before_bool.ahk
#Include meta/ai/menu/test_toggle_reentrancy.ahk
#Include meta/ai/menu/test_tab_source_hwnd.ahk
#Include meta/ai/menu/test_modelbrowser_sort_callback.ahk
#Include meta/keyboard/keys/test_space_taphold_configurable.ahk
#Include meta/hotstrings/engine/catalogue/test_terminators_requires_directive.ahk
#Include meta/layouts/test_poll_pending_hkl.ahk
#Include meta/ai/api/test_llmbridge_stop_order.ahk
#Include meta/ai/tooltip/test_render_clears_dequeue.ahk
#Include meta/gestures/test_search_shortcut_run_path_existence_guard.ahk
#Include meta/modules/updater/test_updater_swap_exit_guard.ahk
#Include meta/platform/input/test_keyboard_hook_dispatch_error_logged.ahk
#Include meta/menu/test_tray_menu_cleared_before_onboarding.ahk
#Include meta/menu/test_tray_bootstrap_publication_transaction.ahk
#Include meta/settings/persistence/test_shortcuts_unescape_ordering.ahk
#Include meta/gestures/test_selfactivated_bounded.ahk
#Include meta/ai/api/test_no_entry_logged.ahk
#Include meta/ai/prediction/test_cancel_not_under_critical.ahk
#Include meta/ai/prediction/test_dispatch_not_under_critical.ahk
#Include meta/ai/prediction/test_dispatcher_char_serialized.ahk
#Include meta/ai/servers/test_deps_fail_restores_priority.ahk
#Include meta/ai/navigation/test_tab_accept_invalidates_inflight.ahk
#Include meta/ai/navigation/test_accept_suppress_balance.ahk
#Include meta/keyboard/altgr/test_latch_dispatch_aborts.ahk
#Include meta/gestures/test_click_hold_released_on_suspend.ahk
#Include meta/gestures/test_click_hold_transaction.ahk
#Include meta/metrics/engine/ergonomics/test_walker_batch_drained_on_rollover_and_stop.ahk
#Include meta/keyboard/tap_hold/test_none_sentinel.ahk
#Include meta/ai/servers/test_deps_check_epoch_guard.ahk
#Include meta/modules/updater/test_updater_rebuild_resets_dispatcher.ahk
#Include meta/keyboard/keys/test_capsword_reset_on_suspend.ahk
#Include meta/modules/shortcuts/test_capsword_auto_off_single_source.ahk
#Include meta/keyboard/keys/test_capsword_space_release_timeout.ahk
#Include meta/gestures/test_toggle_ui_errors_logged.ahk
#Include meta/metrics/ui/test_wpm_mousewatch_suspend_guard.ahk
#Include meta/core/ui/tooltip/test_resolve_pos_profiled.ahk
#Include meta/core/logger/test_error_net_guarded_send.ahk
#Include meta/core/logger/test_error_net_dedup_throttle.ahk
#Include meta/core/logger/test_error_net_smoke_fatal_stderr.ahk
#Include unit/core/logger/test_error_report_dedup_ownership.ahk
#Include meta/core/logger/test_error_net_uia_orphan_suppress.ahk
#Include meta/diagnostics/adapters/test_deferred_crash_report_catch.ahk
#Include meta/metrics/engine/view/test_webview_bridge_and_i18n.ahk
#Include meta/metrics/engine/view/test_webview_range_bridge.ahk
#Include meta/metrics/engine/test_flush_atomic.ahk
#Include meta/metrics/engine/test_tick_overflow.ahk
#Include meta/ai/api/test_streaming_fixes.ahk
#Include meta/keyboard/layers/test_layout_deadkey_endkey.ahk
#Include meta/keyboard/keys/test_oneshotshift_endkeys.ahk
#Include meta/hotstrings/engine/magic_key/test_capture.ahk
#Include meta/gestures/test_restart_nonblocking.ahk
#Include meta/gestures/test_open_url_run_guard.ahk
#Include meta/modules/shortcuts/test_addshortcut_registration_guard.ahk
#Include meta/ai/navigation/test_gpt_hotkey_run_guard.ahk
#Include meta/menu/test_manifest_lifecycle_pair.ahk
#Include meta/settings/persistence/test_editor_persist_before_publish.ahk
#Include meta/metrics/engine/view/test_webview_epoch.ahk
#Include meta/metrics/engine/view/test_webview_callback_fail_safe.ahk
#Include meta/metrics/engine/capture/test_clipboard_registration_transaction.ahk
#Include meta/metrics/test_prefetch_worker.ahk
#Include meta/metrics/engine/journal/test_prefetch_recovery.ahk
#Include meta/modules/shortcuts/test_sendinstant_clip_contention_guard.ahk
#Include meta/modules/shortcuts/test_sendinstant_clipboard_sequence_ownership.ahk
#Include meta/gestures/test_plain_paste_clipboard_sequence_ownership.ahk
#Include meta/ui/onboarding/test_onboarding_gesture_registration_async.ahk
#Include unit/platform/input/test_text_sender_completion_status.ahk
#Include unit/core/ui/windows/test_native_editor_completion.ahk
#Include unit/platform/input/test_text_sender_sendinput_failure.ahk
#Include meta/keyboard/layers/test_deadkey_unmapped_base_char.ahk
#Include meta/settings/persistence/test_savefullconfig_no_delete.ahk
#Include meta/metrics/engine/test_scan_max_id_tail.ahk
#Include meta/gestures/test_screenshot_no_tempfile.ahk
#Include meta/platform/system/test_wmexists_is_not_a_handle.ahk
#Include meta/keyboard/tap_hold/test_taphold_scancodes_are_the_real_keys.ahk
#Include unit/core/crypto/test_sha256_is_real.ahk
#Include meta/keyboard/keys/test_capslock_led_does_not_latch.ahk
#Include meta/hotstrings/engine/engine/test_deadkey_uppercase_cleanup.ahk
#Include meta/core/text/test_parser_splitblocks_cap.ahk
#Include meta/ai/servers/test_ollama_trim_registry_min_id.ahk
#Include meta/platform/input/test_clipwait_binary.ahk
#Include meta/platform/input/dispatch/test_timer_scheduler_oneshot_suspend.ahk
#Include meta/hotstrings/engine/catalogue/test_cache_atomic_write.ahk
#Include meta/metrics/engine/capture/test_hook_global_try.ahk
#Include meta/metrics/engine/test_idle_defer_preserves_pending.ahk
#Include meta/metrics/engine/journal/test_rollover_force_ingest.ahk
#Include meta/metrics/engine/journal/test_rollover_transaction.ahk
#Include meta/metrics/engine/test_klnet_starter_deref.ahk
#Include meta/keyboard/layers/test_nav_layer_hotkey_interval.ahk
#Include unit/hotstrings/engine/engine/test_escape_braces.ahk
#Include unit/hotstrings/engine/engine/test_send_failure_containment.ahk
#Include unit/hotstrings/engine/engine/test_title_timeout_does_not_eat_expansion.ahk
#Include unit/hotstrings/engine/engine/test_hse_send_failure_transaction.ahk
#Include unit/hotstrings/engine/engine/test_hse_dispatch_behaviour.ahk
#Include unit/hotstrings/engine/engine/test_output_is_final.ahk
#Include unit/hotstrings/engine/engine/test_chaining.ahk
#Include unit/hotstrings/engine/engine/test_cascade.ahk
#Include unit/hotstrings/engine/engine/test_final_result.ahk
#Include unit/hotstrings/engine/engine/test_injection_plan.ahk
#Include unit/hotstrings/engine/engine/test_output_tokens.ahk
#Include meta/hotstrings/engine/catalogue/test_combo_auto_escaping.ahk
#Include meta/metrics/engine/ergonomics/test_ergo_flow_gap_end.ahk
#Include meta/settings/persistence/test_window_patch_toml_meta_error.ahk
#Include meta/keyboard/keys/test_capsword_mouse_clobber.ahk
#Include unit/platform/input/dispatch/test_timer_scheduler_suspend.ahk
#Include meta/hotstrings/engine/magic_key/test_probe_deadkey_safe.ahk
#Include meta/menu/test_script_shortcut_labels_locale.ahk
#Include meta/keyboard/altgr/test_chord_debounce_per_slot.ahk
#Include meta/metrics/engine/ergonomics/test_roi_halflife_threshold_reachable.ahk
#Include meta/hotstrings/engine/engine/test_notepad_hotstring_atomic_burst.ahk
#Include unit/ai/prediction/test_parser_dedup_stats.ahk
#Include meta/modules/shortcuts/test_paste_without_formatting_restore.ahk
#Include meta/keyboard/keys/test_hold_layer_release_bounded.ahk
#Include meta/keyboard/keys/test_hold_layer_survives_long_press.ahk
#Include meta/core/text/test_toml_batchwrite_cache_coherence.ahk
#Include meta/metrics/engine/context/test_topology_debounce_settled_geometry.ahk
#Include meta/metrics/engine/context/test_topology_single_append.ahk
#Include meta/diagnostics/adapters/test_crash_report_unique_filename.ahk
#Include meta/gestures/test_paste_plain_busy_guard.ahk
#Include unit/ai/api/test_deadline_wrap.ahk
#Include meta/core/ui/windows/test_gr_drawbitmap_type_guard.ahk
#Include unit/core/ui/windows/test_gr_drawbitmap_closure.ahk
#Include meta/gestures/test_action_catalog_deferred.ahk
#Include meta/hotstrings/engine/engine/test_hse_altgr_kana_sendinput.ahk
#Include meta/platform/input/test_text_sender_clipboard_generation_recheck.ahk
#Include meta/platform/input/test_text_sender_clipboard_suspend_guard.ahk
#Include meta/ai/prediction/test_output_physical_generation.ahk
#Include meta/platform/input/test_text_sender_callback_on_bailout.ahk
#Include meta/core/process/shell_runner/test_poll_suspend_guard.ahk
#Include meta/core/process/shell_runner/test_legacy_claims.ahk
#Include meta/gestures/test_screenshot_tree_owned_default.ahk
#Include meta/core/process/shell_runner/test_isolated_logger.ahk
#Include meta/platform/focus/uia/test_disable_password_fields_gate.ahk
#Include meta/hotstrings/engine/test_menu_dynamic_hotstrings_category_gate.ahk
#Include meta/menu/test_master_category_cache.ahk
#Include unit/core/fs/test_storage_st_delete_contract.ahk
#Include meta/core/lifecycle/engine/test_boot_dircreate_guarded.ahk
#Include meta/core/text/test_toml_render_bool_sentinel.ahk
#Include meta/ai/menu/test_loaded_gate.ahk
#Include meta/keyboard/altgr/test_dispatch_suspend_guard.ahk
#Include meta/ai/prediction/test_inject_complete_callback.ahk
#Include meta/ai/prediction/test_ngram_esrc_json_accumulate.ahk
#Include meta/ai/prediction/test_ngram_tables_not_cleared_on_refresh.ahk
#Include meta/keyboard/keys/test_shift_digit_passthrough_not_shadowed.ahk
#Include meta/ai/servers/test_deps_installer_pid_captured.ahk
#Include meta/ai/api/test_parse_billions_null_guard.ahk
#Include meta/keyboard/keys/test_toggle_capslock_calls_disable_capsword.ahk
#Include meta/keyboard/tap_hold/test_writer_inherit_defaults.ahk
#Include meta/keyboard/tap_hold/test_persist_before_publish.ahk
#Include meta/keyboard/tap_hold/test_picker_catalog_path.ahk
#Include meta/keyboard/tap_hold/test_global_transaction.ahk
#Include meta/ai/navigation/test_nav_loop_ten.ahk
#Include meta/ai/api/test_entries_persist_error_logged.ahk
#Include meta/modules/updater/test_updater_callback_suspend_guard.ahk
#Include meta/keyboard/altgr/test_dispatch_resume_aware.ahk
#Include meta/modules/updater/test_updater_self_update_bak_rollback.ahk
#Include meta/modules/updater/test_updater_swap_failure_receipt.ahk
#Include meta/core/lifecycle/engine/test_bundle_resolve_dir_local_appdata.ahk
#Include meta/hotstrings/engine/personal/test_shortcuts_compiled_include_path.ahk
#Include meta/hotstrings/engine/personal/test_shortcuts_generator_encoding.ahk
#Include meta/hotstrings/engine/personal/test_shortcuts_reload_handoff.ahk
#Include meta/hotstrings/engine/personal/test_shortcuts_atomic_bootstrap.ahk
#Include meta/keyboard/altgr/test_detect_hkl_fallback.ahk
#Include unit/keyboard/engine/altgr/test_detection.ahk
#Include unit/keyboard/engine/altgr/test_family_follows_layout.ahk
#Include unit/keyboard/engine/altgr/test_probe_real_layouts.ahk
#Include unit/layouts/engine/registry/test_digit_row_probe.ahk
#Include unit/layouts/engine/emulation/test_number_row_symbols.ahk
#Include unit/layouts/engine/registry/test_rows_policy.ahk
#Include unit/hotstrings/engine/expander/test_pause_switch_policy.ahk
#Include unit/layouts/engine/emulation/test_pause_layout_switch.ahk
#Include unit/layouts/engine/registry/test_watch.ahk
#Include unit/layouts/engine/test_system_layout_install.ahk
#Include unit/layouts/engine/emulation/test_number_row_native_hkl.ahk
#Include meta/keyboard/altgr/test_kana_taphold_entry.ahk
#Include meta/keyboard/altgr/test_prefix_arms_on_press.ahk
#Include unit/keyboard/engine/altgr/test_owner_matrix.ahk
#Include unit/keyboard/engine/altgr/test_combos_stand_down.ahk
#Include unit/keyboard/engine/key_combinations/test_script_chords_follow_their_slot.ahk
#Include unit/keyboard/engine/altgr/test_layer_shift_from_hold.ahk
#Include unit/keyboard/engine/key_combinations/test_ctrl_alt_numpad_gate.ahk
#Include unit/keyboard/engine/key_combinations/test_native_press_ledger_consumers.ahk
#Include unit/keyboard/engine/keys/test_user_lctrl_held.ahk
#Include unit/keyboard/engine/altgr/test_takes_its_lctrl.ahk
#Include unit/keyboard/engine/altgr/test_lctrl_not_typed.ahk
#Include meta/keyboard/keys/test_prior_key_guards_use_helper.ahk
#Include meta/keyboard/keys/test_modifier_hotkeys_single_identity.ahk
#Include meta/keyboard/key_combinations/test_scan_code_shadows_key_name.ahk
#Include meta/core/ui/windows/test_spotlight_gdiplus_free_library.ahk
#Include meta/modules/shortcuts/test_case_transform_synthetic_mark.ahk
#Include meta/gestures/test_color_dropdown_recompute_index.ahk
#Include meta/gestures/test_color_picker_hotkey_nonblocking.ahk
#Include meta/hotstrings/engine/magic_key/test_no_regex_inject.ahk
#Include meta/core/logger/test_fanout_batched.ahk
#Include meta/diagnostics/adapters/test_crash_reporter_slash_precedence.ahk
#Include meta/core/logger/test_flush_on_error.ahk
#Include meta/platform/system/test_atomic_write_unique_scratch.ahk
#Include unit/platform/system/test_atomic_temp_owner.ahk
#Include meta/suite/test_byref_call_sites.ahk
#Include meta/platform/focus/uia/test_probe_bounded.ahk
#Include meta/diagnostics/ui/test_healthcheck_collectors_guarded.ahk
#Include meta/gestures/test_init_lifecycle_pair.ahk
#Include meta/settings/persistence/test_paths_file_single_writer.ahk
#Include meta/modules/updater/test_changelog_fetch_status_logged.ahk
#Include meta/platform/system/test_mutex_yield_is_recorded.ahk
#Include meta/core/lifecycle/engine/reload/test_suspend_deferral_bounded.ahk
#Include meta/core/lifecycle/engine/shutdown/test_veto_bounded.ahk
#Include meta/core/lifecycle/engine/reload/test_suspend_lifecycle_logged.ahk
#Include unit/core/lifecycle/engine/test_transition.ahk
#Include meta/suite/test_dead_state_and_single_source.ahk
#Include meta/settings/persistence/test_discarded_config_is_reported.ahk
#Include meta/metrics/engine/journal/test_sql_replay_is_idempotent.ahk
#Include meta/keyboard/key_combinations/test_shortcut_slots_roundtrip.ahk
#Include meta/settings/persistence/test_failures_are_surfaced.ahk
#Include meta/diagnostics/adapters/test_crash_report_not_suppressed.ahk
#Include meta/menu/test_submenu_survives_publish.ahk
#Include meta/keyboard/layers/test_keymap_hotpath_guards.ahk
#Include meta/keyboard/layers/test_keymap_deadkey_emit_serialized.ahk
#Include meta/keyboard/layers/test_deadkey_ring_push.ahk
#Include meta/keyboard/altgr/test_callbacks_serialized.ahk
#Include meta/platform/input/dispatch/test_hook_dispatcher_critical_save_restore.ahk
#Include meta/platform/input/dispatch/test_hook_dispatcher_err_cache_cap.ahk
#Include meta/metrics/engine/ergonomics/test_walker_batch_critical.ahk
#Include meta/metrics/engine/ergonomics/test_walker_pure_fns_match_shared_core.ahk
#Include meta/metrics/engine/test_critical_restore.ahk
#Include meta/metrics/engine/context/test_sensors_warmup_distinct_callback.ahk
#Include meta/metrics/engine/context/test_kltopo_seen_hwnds_cap.ahk
#Include meta/keyboard/layers/test_remapped_list_unconditional.ahk
#Include meta/gestures/test_screenshot_async_run.ahk
#Include meta/keyboard/keys/test_space_hold_empty_guard.ahk
#Include meta/ai/navigation/test_profile_hotkey_stable_pred.ahk
#Include meta/modules/updater/test_updater_download_timeout.ahk
#Include meta/gestures/test_mouse_control_physical_cursor.ahk
#Include meta/diagnostics/adapters/test_crash_prompt_blocking_msgbox.ahk
#Include meta/keyboard/key_combinations/test_shortcut_groups_register_dispatch.ahk
#Include meta/modules/updater/test_changelog_fetch_async.ahk
#Include meta/core/network/test_curl_response_size_bound.ahk
#Include unit/core/network/adapters/test_curl_start_check.ahk
#Include meta/core/network/test_curl_personal_config_disabled.ahk
#Include meta/modules/updater/test_curl_staging_failure_cleanup.ahk
#Include meta/modules/updater/test_changelog_webview_bridge.ahk
#Include meta/ai/menu/test_model_browser_webview_bridge.ahk
#Include meta/hotstrings/engine/catalogue/test_deferred_ext_scan_critical_file_io.ahk
#Include meta/metrics/ui/test_wpm_compact_color_validation.ahk
#Include meta/keyboard/keys/test_backspace_repeat_suspend_guard.ahk
#Include meta/hotstrings/engine/prefix/test_render_flush_suspend_guard.ahk
#Include meta/gestures/test_dispatch_logs_failure.ahk
#Include meta/ai/servers/test_ollama_installer_sync_winhttp_blocks.ahk
#Include meta/ai/servers/test_ollama_delete_model_async.ahk
#Include meta/modules/updater/test_updater_download_resilience.ahk
#Include meta/platform/input/test_key_state_dllcall_guards.ahk
#Include meta/modules/updater/test_updater_loadchannel_try_wrap.ahk
#Include meta/diagnostics/adapters/test_crash_report_sysinfo_dedup.ahk
#Include meta/core/logger/test_dedup_exit_flush.ahk
#Include meta/core/logger/test_repeat_collapsing.ahk
#Include meta/core/process/shell_runner/test_boot_crash_and_quoting.ahk
#Include meta/platform/input/dispatch/test_hotpath_priority_starvation.ahk
#Include meta/suite/test_priority_baseline_single_source.ahk

; -- Previously-orphaned regression tests (on disk but never wired into the
;    runner; re-wired so they actually execute). All were silently skipped; the
;    four that "failed" turned out to be test bugs (wrong A_ScriptDir-relative
;    path, first-call-vs-definition match, elapsed- vs deadline-form poll, a
;    comment tripping a substring guard), not real code regressions — fixed. --
#Include meta/platform/input/dispatch/test_bypass_dispatch_arity.ahk
#Include meta/hotstrings/engine/catalogue/test_hcw_reset_all_teardown.ahk
#Include meta/diagnostics/ui/test_healthcheck_sysinfo_git_nonblocking.ahk
#Include meta/metrics/engine/test_pause_metrics.ahk
#Include meta/core/process/test_processentry32w_size.ahk
#Include meta/keyboard/altgr/test_script_altgr_hotkeys.ahk
#Include meta/keyboard/keys/test_space_hold_exception_guard.ahk
#Include meta/ai/api/test_stream_handle_type.ahk
#Include meta/ai/api/test_warmup_backoff_preserved.ahk
; These three were orphaned with their own (duplicate or pure-scan) includes;
; the duplicate test_framework.ahk includes were stripped so they integrate.
#Include meta/platform/system/test_dpapi_blob_size.ahk
; The diagnostics window's sources are headless-safe: function definitions and
; their globals only, no top-level side effects.
#Include ../diagnostics/ui/healthcheck/core.ahk
; The local reload control rides the Diagnostics endpoint owner above.
#Include ../core/lifecycle/engine/driver_control.ahk
#Include unit/diagnostics/engine/control/test_driver_control.ahk
#Include unit/diagnostics/engine/control/test_driver_control_cli.ahk
#Include ../diagnostics/ui/healthcheck/collection.ahk
#Include unit/core/ui/webview/test_warm_hosts.ahk
#Include ../diagnostics/ui/healthcheck/helpers.ahk
#Include ../diagnostics/ui/healthcheck/probes.ahk
#Include ../diagnostics/ui/healthcheck/report.ahk
#Include ../diagnostics/ui/healthcheck/actions.ahk
#Include ../diagnostics/ui/healthcheck/configuration.ahk
#Include unit/keyboard/engine/altgr/test_kana_altgr_readers.ahk
#Include unit/keyboard/engine/altgr/test_kana_altgr_lift_respects_owner.ahk
#Include unit/keyboard/engine/altgr/test_kana_altgr_ctrl_chords.ahk
#Include ../diagnostics/ui/error_dialog.ahk
#Include unit/core/ui/windows/test_error_dialog.ahk
#Include unit/core/ui/windows/test_hcw_palette_generated.ahk
#Include unit/core/ui/webview/test_onboarding_open_generation.ahk
#Include unit/core/ui/webview/test_changelog_open_generation.ahk
#Include unit/core/ui/webview/test_changelog_restore_authority.ahk
#Include unit/core/ui/windows/test_title_captions.ahk
#Include ../ui/update_check/init.ahk
#Include unit/modules/updater/test_updater_result_dialog_states.ahk
#Include meta/modules/updater/test_updater_manual_check_uses_dialog.ahk
#Include unit/diagnostics/ui/healthcheck/test_os_name_windows11.ahk
#Include unit/diagnostics/ui/healthcheck/test_issues_from_errors_file.ahk
#Include unit/diagnostics/ui/healthcheck/test_report_issue.ahk
#Include meta/corpus/test_corpus_diagnostics.ahk

; Guards the _HsEdWeb_Reset() idempotency fix for the live-log access-violation
; crash (double-unsubscribe against an already torn-down WebView2 controller).
#Include meta/hotstrings/engine/catalogue/test_hsedweb_reset_idempotent.ahk

; Same idempotency-guard shape, verified in the 6 sibling WebView2 hosts that
; got the identical F7 fix applied.
#Include meta/core/ui/webview/test_reset_idempotent_siblings.ahk
#Include meta/modules/updater/test_updater_onjson_callback_catch.ahk
#Include meta/core/ui/webview/test_bridge_suspend_guard.ahk
#Include meta/modules/updater/test_changelog_close_order.ahk
#Include meta/modules/updater/test_updater_changelog_install_closegui.ahk
; MCSetPos/MCGetPos bare-try-no-catch fix (F32).
#Include meta/gestures/test_mouse_control_error_logging.ahk
; TooltipRHide bare-try-no-catch + TooltipRShow OutputDebug-instead-of-Logger fix (F50).
#Include meta/core/ui/tooltip/test_renderer_error_logging.ahk
; WMGetList/WIGetAll bare-try-no-catch fix (F33) — sibling of the
; GestureGetCyclableWindows TOCTOU guard (commit 7b701020d).
#Include meta/platform/focus/test_window_adapters_catch.ahk
#Include meta/ui/onboarding/test_onbweb_singleton_guard.ahk
#Include meta/settings/persistence/test_reset_config_writes_meta_placeholder.ahk
#Include meta/core/ui/webview/test_shared_env_reentrancy_guard.ahk
#Include meta/core/ui/webview/test_host_callback_epoch.ahk
; AltTabMonitor bare-try-no-catch fix (F37) — sibling of the
; GestureGetCyclableWindows TOCTOU guard (commit 7b701020d).
#Include meta/gestures/test_alt_tab_monitor_catch.ahk
#Include meta/metrics/engine/metrics/test_shortcut_persist_guard.ahk
#Include meta/metrics/engine/metrics/test_shortcut_transaction.ahk
#Include meta/metrics/engine/metrics/test_app_time_accuracy.ahk
#Include meta/settings/persistence/test_toggle_category_all_features_atomic.ahk
#Include meta/core/crypto/test_djb2_fallback_logged.ahk
#Include meta/platform/system/test_adapter_callback_swallow_logged.ahk
#Include meta/ai/prediction/test_callbacks_never_swallowed.ahk
#Include meta/ai/prediction/test_inflight_hygiene.ahk
#Include meta/ai/api/test_semantic_config_class.ahk
#Include meta/metrics/ui/test_wpm_widget_consistency.ahk
#Include meta/metrics/engine/ergonomics/test_marker_and_heatmap_completeness.ahk
#Include meta/platform/input/test_text_send_direct_mode_guarded.ahk
#Include meta/core/network/test_http_post_reentrancy_guard.ahk
#Include meta/core/text/test_jsstr_cr_escaped.ahk
#Include meta/core/text/test_json_string_literal_single_source.ahk
#Include meta/core/text/test_json_string_decoder_single_source.ahk
#Include meta/core/text/test_toml_string_codec_single_source.ahk
#Include meta/hotstrings/engine/magic_key/test_editor_reopen_presents.ahk
#Include meta/modules/updater/test_update_check_window_presented.ahk
#Include meta/hotstrings/engine/catalogue/test_hs_delimiter_dialog_reachable.ahk
#Include meta/core/ui/windows/test_style_llm_tray_i18n.ahk
#Include meta/ai/servers/test_ollama_webview_msgsub_retained.ahk
#Include meta/gestures/test_open_downloads_catch.ahk
#Include meta/gestures/test_takenote_winmaximize_guard.ahk
#Include meta/hotstrings/engine/personal/test_info_combo_generation.ahk
#Include meta/hotstrings/engine/personal/test_combo_letters_guard.ahk
#Include meta/suite/test_driver_pid_single_source.ahk
#Include meta/keyboard/tap_hold/test_taphold_timings_load_order.ahk
#Include meta/hotstrings/engine/engine/test_suspend_resets_hse_context.ahk
#Include meta/keyboard/keys/test_capsword_parse_time_callback.ahk
#Include meta/settings/persistence/test_shortcuts_inline_comment.ahk
#Include meta/settings/persistence/test_savefullconfig_llm_loaded_gate.ahk
#Include meta/core/lifecycle/test_single_instance_mutex_first.ahk
#Include meta/settings/persistence/test_master_gate_drifted_subgate_skip.ahk
#Include meta/keyboard/keys/test_rctrl_lalt_hotif_gated.ahk
#Include meta/hotstrings/engine/prefix/test_keydown_ctrl_backspace_reset.ahk
#Include meta/hotstrings/engine/prefix/test_index_rebuild_suspend_replay.ahk
#Include meta/core/lifecycle/engine/reload/test_suspend_transition_serialized.ahk
#Include meta/modules/shortcuts/test_wrap_selection_clip_fallback.ahk
#Include meta/modules/shortcuts/test_uia_selection_poll_boot_gated.ahk
#Include meta/keyboard/tap_hold/test_synthetic_up_suspend_guard.ahk
#Include meta/hotstrings/engine/catalogue/test_menu_delay_prompt_rebuild.ahk
#Include meta/gestures/test_edit_shortcuts_no_reload.ahk
#Include meta/gestures/test_screenshot_instant_completion.ahk
#Include meta/hotstrings/engine/catalogue/test_live_rebuild_no_critical_io.ahk
#Include meta/metrics/engine/metrics/test_focus_refresh_suspend_guard.ahk
#Include meta/ai/tooltip/test_loading_tooltip_no_safety_deadline.ahk
#Include meta/ui/onboarding/test_onboarding_gesture_result_token.ahk
#Include meta/core/lifecycle/engine/reload/test_suspend_prefix_drain_covers_all_combos.ahk
#Include meta/hotstrings/engine/catalogue/test_case_sensitivity_mapping.ahk
#Include meta/ai/profiles/test_prompt_editor_singleton_context.ahk
#Include meta/core/ui/webview/test_deferred_host_actions.ahk
#Include meta/modules/shortcuts/test_wrap_symbols_load_flush.ahk
#Include unit/modules/shortcuts/test_wrap_symbols_unreadable_blocks_save.ahk
#Include unit/settings/engine/persistence/test_unreadable_config_never_persisted.ahk
#Include meta/core/ui/windows/test_app_picker_sort_safe_selection.ahk
#Include meta/modules/updater/test_changelog_ready_not_stranded.ahk
#Include meta/hotstrings/engine/catalogue/test_hcw_bulk_writers_republish.ahk
#Include meta/hotstrings/engine/catalogue/test_hcw_patch_toml_meta_refuses_unread_file.ahk
#Include meta/diagnostics/ui/test_healthcheck_singleton_destroys_window.ahk
#Include meta/metrics/engine/journal/test_ingest_offset_respects_batch_limit.ahk
#Include meta/metrics/engine/test_kl_payload_privacy_filter.ahk
#Include meta/metrics/engine/test_kl_stop_shutdown_ingest_forced.ahk
#Include meta/metrics/engine/system/test_shutdown_timer_durability.ahk
#Include meta/ai/prediction/test_finalize_guard_before_yield.ahk
#Include meta/ai/prediction/test_indexed_callbacks_never_swallowed.ahk
#Include meta/ai/profiles/test_menu_unique_labels.ahk
#Include meta/core/i18n/test_tsv_atomic_write.ahk
#Include meta/menu/test_manifest_single_decode.ahk
#Include meta/menu/test_prune_keeps_detached_registrations.ahk
#Include meta/metrics/engine/metrics/test_filter_secure_field_fails_closed.ahk
#Include meta/metrics/engine/context/test_network_info_single_wlan_roundtrip.ahk
#Include meta/ui/onboarding/test_onboarding_unbraced_if_scope.ahk
#Include meta/hotstrings/engine/personal/test_info_save_surfaces_failure.ahk
#Include meta/ai/servers/test_remote_curl_forwards_usage_meta.ahk
#Include meta/ai/servers/test_remote_token_not_on_argv.ahk
#Include meta/platform/focus/uia/test_secure_field_native_detect_conclusive_order.ahk
#Include meta/platform/focus/uia/test_secure_field_probes_focused_element.ahk
#Include meta/platform/focus/uia/test_secure_field_stale_verdict_fails_closed.ahk
#Include meta/platform/focus/uia/test_secure_field_uia_probe_guards.ahk
#Include meta/metrics/engine/ergonomics/test_today_bucket_slots_all_fed.ahk
#Include meta/core/ui/tooltip/test_expiry_anchored_at_request.ahk
#Include meta/core/ui/tooltip/test_expiry_timers_keep_preview.ahk
#Include meta/core/ui/tooltip/test_uia_gate_reachable.ahk
#Include meta/hotstrings/adapters/test_uia_wrap_resets_both_buffers.ahk
#Include meta/modules/updater/test_updater_releases_list_cancellable.ahk
#Include meta/modules/updater/test_updater_worker_terminated_on_exit.ahk
#Include meta/core/ui/webview/test_reset_guard_class.ahk
#Include meta/metrics/ui/test_wpm_graph_mode_draggable.ahk
#Include meta/metrics/ui/test_wpm_rebuilt_surface_is_sized.ahk
#Include unit/hotstrings/engine/catalogue/test_activate_hotstrings_commits_synchronously.ahk
#Include unit/core/text/toml/test_cache_builder_strips_header_comment.ahk
#Include unit/core/lifecycle/engine/test_bundle_skip_validation.ahk
#Include unit/core/lifecycle/engine/test_startup_smoke_receipt.ahk
#Include unit/modules/shortcuts/test_clipboard_history_paste.ahk
#Include unit/modules/updater/test_changelog_request_epoch.ahk
#Include unit/modules/updater/test_changelog_network_resilience.ahk
#Include unit/settings/engine/persistence/test_toml_single_writer.ahk
#Include unit/core/text/toml/test_derived_toml_caches_not_memoised_on_failed_read.ahk
#Include unit/hotstrings/engine/engine/test_fire_log_callable_replacement.ahk
#Include unit/hotstrings/engine/engine/test_fire_log_suspend_boundary.ahk
#Include unit/settings/engine/persistence/test_group_config_cache_alias_invalidation.ahk
#Include unit/platform/input/dispatch/test_hotpath_profiler_exclusive.ahk
#Include unit/platform/input/dispatch/test_hotpath_latency_statistics.ahk
#Include unit/platform/input/dispatch/test_phase_stats.ahk
#Include unit/platform/input/dispatch/test_hotpath_breakdown_reentry.ahk
#Include unit/platform/input/dispatch/test_hook_timing_input_privacy.ahk
#Include unit/platform/input/dispatch/test_hotpath_per_segment_threshold.ahk
#Include unit/platform/input/dispatch/test_hotpath_nesting_vectors.ahk
#Include unit/layouts/engine/composer/test_keylayout_canonical_form.ahk
#Include unit/metrics/engine/test_today_fh_flush.ahk
#Include unit/ai/prediction/test_cache_hit_logs_suggested.ahk
#Include unit/ai/api/test_keep_alive_from_shared_defaults.ahk
#Include unit/ai/prediction/test_parser_refuses_uninjectable_deletes.ahk
#Include unit/core/logger/test_preinit_level.ahk
#Include unit/core/logger/test_set_level_transaction.ahk
#Include unit/core/logger/test_sub_files_multiline_arrays.ahk
#Include unit/hotstrings/engine/engine/test_marker_substituted_in_replacement.ahk
#Include unit/settings/engine/persistence/test_master_gates_not_persisted.ahk
#Include unit/core/text/toml/test_parse_toml_file_sticky_unreadable.ahk
#Include unit/hotstrings/engine/personal/test_info_unreadable_never_persisted.ahk
#Include unit/hotstrings/engine/personal/test_read_clears_unreadable_latch.ahk
#Include unit/hotstrings/engine/personal/test_reload_bakes_resolved_delay.ahk
#Include unit/metrics/engine/journal/test_prefetch_apps_list_deduped.ahk
#Include unit/metrics/engine/journal/test_prefetch_dbg_write_level_gated.ahk
#Include unit/core/process/shell_runner/test_worker_spawn_args_are_strings.ahk
#Include unit/metrics/engine/journal/test_prefetch_worker_failure.ahk
#Include unit/hotstrings/engine/preview/test_picks_engine_winner.ahk
#Include unit/hotstrings/engine/personal/test_priority_missing_defaults_to_common.ahk
#Include unit/hotstrings/engine/preview/test_uses_by_trigger_index.ahk
#Include unit/hotstrings/engine/engine/test_repeat_key_honours_rebuild_fence.ahk
#Include unit/hotstrings/engine/engine/test_repeat_activation_window.ahk
#Include unit/hotstrings/engine/engine/test_backspace_undo.ahk
#Include unit/core/process/shell_runner/test_legacy_state_machine.ahk
#Include unit/core/process/shell_runner/test_multiline_arg.ahk
#Include unit/core/process/shell_runner/test_tree_owned.ahk
#Include unit/ai/servers/test_ollama_install_files_port.ahk
#Include unit/ai/servers/test_ollama_runtime_owner.ahk
#Include unit/ai/servers/test_ollama_managed_bootstrap.ahk
#Include unit/ai/servers/test_ollama_managed_origin.ahk
#Include unit/ai/servers/test_ollama_owned_only.ahk
#Include unit/ai/prediction/test_request_plan.ahk
#Include unit/ai/servers/test_ollama_managed_model_offer.ahk
#Include unit/modules/shortcuts/test_run_program_actions.ahk
#Include unit/gestures/engine/test_user_actions.ahk
#Include unit/gestures/engine/test_sticky_and_navigation_actions.ahk
#Include unit/gestures/adapters/test_sticky_kana_native.ahk
#Include unit/gestures/engine/test_display_mirror_toggle.ahk
#Include unit/gestures/engine/test_display_mirror_query_pause.ahk
#Include unit/modules/shortcuts/test_run_program_actions_custody.ahk
#Include unit/modules/shortcuts/test_program_providers.ahk
#Include unit/core/process/shell_runner/test_launch_cleanup.ahk
#Include unit/core/process/shell_runner/test_native_argv.ahk
#Include unit/core/process/shell_runner/test_nul_arguments.ahk
#Include unit/core/process/shell_runner/test_native_exit_code.ahk
#Include unit/core/process/shell_runner/test_exit_query_failure.ahk
#Include unit/core/process/shell_runner/test_native_ownership.ahk
#Include unit/core/process/shell_runner/test_native_teardown.ahk
#Include unit/core/process/shell_runner/test_tree_native_refusal.ahk
#Include unit/core/process/shell_runner/test_tree_close_recovery.ahk
#Include unit/core/process/shell_runner/test_capture_debt.ahk
#Include unit/core/process/shell_runner/test_capture_lock.ahk
#Include unit/core/process/shell_runner/test_creator_debt.ahk
#Include unit/core/process/shell_runner/test_completion_pause.ahk
#Include unit/core/process/shell_runner/test_deferred_completion.ahk
#Include unit/core/process/shell_runner/test_tree_deferred_completion.ahk
#Include unit/diagnostics/adapters/crash_report/test_worker_transport.ahk
#Include unit/diagnostics/adapters/crash_report/test_shared_document.ahk
#Include unit/diagnostics/adapters/crash_report/test_crash_mapping_drain_reentry.ahk
#Include unit/diagnostics/adapters/crash_report/test_crash_mapping_payload_bounds.ahk
#Include unit/diagnostics/adapters/crash_report/test_crash_worker_git_exit.ahk
#Include unit/diagnostics/adapters/crash_report/test_crash_worker_fixture_cleanup.ahk
#Include unit/diagnostics/adapters/crash_report/test_crash_worker_attempt_ownership.ahk
#Include unit/diagnostics/adapters/crash_report/test_crash_worker_deadline.ahk
#Include unit/keyboard/engine/tap_hold/test_taphold_inherit_defaults_roundtrip.ahk
#Include unit/keyboard/engine/tap_hold/test_taphold_synthetic_refcount_combo.ahk
#Include unit/keyboard/engine/tap_hold/test_taphold_synthetic_user_held.ahk
#Include unit/keyboard/engine/tap_hold/test_taphold_unreadable_blocks_rewrite.ahk
#Include unit/keyboard/engine/tap_hold/test_global_transaction.ahk
#Include unit/keyboard/engine/tap_hold/test_duration_transaction.ahk
#Include unit/core/ui/tooltip/test_row_band_elision.ahk
#Include meta/core/lifecycle/engine/test_boot_profile_retroactive_stamps.ahk
#Include meta/modules/shortcuts/test_clipboard_history_paste_wiring.ahk
#Include meta/suite/test_fast_timer_inventory.ahk
#Include meta/gestures/test_bulk_actions_ahk_reachable.ahk
#Include meta/gestures/test_constants_available_to_onboarding.ahk
#Include meta/platform/input/dispatch/test_hotpath_segment_coverage.ahk
#Include meta/ai/api/test_health_probe_constants.ahk
#Include meta/menu/test_manifest_one_decoder.ahk
#Include meta/menu/test_reload_preserves_suspend.ahk
#Include meta/core/lifecycle/engine/reload/test_pending_contract.ahk
#Include meta/ui/menu/test_menu_shortcut_groups_spliced_once.ahk
#Include meta/metrics/engine/metrics/test_private_title_memo.ahk
#Include meta/ai/servers/test_ollama_async_registry_is_curl_only.ahk
#Include meta/hotstrings/engine/personal/test_save_rebuilds_preview_index.ahk
#Include meta/keyboard/tap_hold/test_taphold_hold_gate_arms_without_tap.ahk
#Include meta/core/ui/tooltip/test_debounce_is_load_bearing.ahk
#Include meta/core/ui/tooltip/test_present_subsegmented.ahk
#Include meta/core/ui/tooltip/test_reveal_zorder.ahk
#Include meta/core/ui/tooltip/test_border_ring_region.ahk
#Include meta/core/ui/tooltip/test_render_accounting.ahk
#Include meta/menu/test_tray_suspend_checkmark_survives_rebuild.ahk
#Include meta/platform/focus/uia/test_clamp_every_probe_site.ahk
#Include meta/platform/focus/uia/test_poll_segment_bounded.ahk
#Include meta/hotstrings/engine/catalogue/test_hcw_reset_all_republishes.ahk
#Include meta/ai/navigation/test_inline_autotype_staleness.ahk
#Include meta/metrics/engine/ergonomics/test_walker_batch_has_an_inprocess_drain.ahk
#Include unit/metrics/engine/ergonomics/test_walker_title_cap_enforced.ahk
#Include meta/suite/test_suite_watchdog_manifest.ahk
#Include meta/suite/test_suite_unique_includes.ahk

#Include unit/core/fs/test_file_read_activity.ahk

; Watchdog: kill the process if RunTests() never returns (e.g. a corpus
; consumer blocks on a synchronous HTTP call, an InputHook with no timeout,
; or a blocking dialog in a headless CI context). The current corpus normally
; now includes measured full-cohort file authority work. The finite 120-minute
; cap reserves five minutes below CI's process bound for partial TAP validation.
global _SUITE_STARTUP_BUDGET_MS := 120000
global _SUITE_PER_TEST_BUDGET_MS := 650
global _SUITE_MAX_TIMEOUT_MS := 7200000
global _SUITE_TIMEOUT_MS := _SuiteTimeoutForCount(TEST_REGISTRY.Length)

; Saturation deliberately reserves time for CI to publish partial results.
_SuiteTimeoutForCount(PlannedCount) {
	global _SUITE_MAX_TIMEOUT_MS, _SUITE_STARTUP_BUDGET_MS, _SUITE_PER_TEST_BUDGET_MS
	return Min(_SUITE_MAX_TIMEOUT_MS,
		_SUITE_STARTUP_BUDGET_MS + PlannedCount * _SUITE_PER_TEST_BUDGET_MS)
}

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
