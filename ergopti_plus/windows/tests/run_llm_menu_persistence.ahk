; static/ergopti_plus/windows/tests/run_llm_menu_persistence.ahk
#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off
global _AHK_DRY_RUN := false
global _ConfigBootReadFailed := false
#Include support/llm_persistence_runner_contract.ahk
#Include test_framework.ahk
#Include test_stubs.ahk
; Native sources use a private test context, never a user's driver paths.
global _ConfigDir := A_Temp . "\ergopti_llm_persistence_test_" . DllCall("GetCurrentProcessId") . "\"
global _AhkSubDir := ""
global ConfigurationFile := _ConfigDir . "config.toml"
global _LogsDir := _ConfigDir . "logs\"
#Include ../infra/tick_count.ahk
#Include ../infra/wall_clock.ahk
#Include ../_generated/config_keys.ahk
#Include ../_generated/app_dirs.ahk
#Include ../_generated/logger_sub_files.ahk
#Include ../infra/logger.ahk
#Include ../adapters/crypto.ahk
#Include ../adapters/file_system.ahk
#Include ../infra/json.ahk
#Include ../infra/locale.ahk
#Include ../_generated/locale_table.ahk
#Include ../infra/i18n.ahk
#Include ../infra/chord.ahk
#Include ../adapters/hotkey_registrar.ahk
#Include ../infra/hotpath_profiler.ahk
#Include ../infra/toml/toml_helpers.ahk
#Include ../infra/toml/toml_loader.ahk
#Include ../infra/toml/toml_config_loader.ahk
#Include ../infra/manifest_reader.ahk
#Include ../infra/master_gates.ahk
#Include ../infra/hotstrings/hotstrings_cache.ahk
#Include ../infra/config_transition.ahk
#Include ../infra/config_transition_runtime.ahk
#Include ../infra/config_migrate.ahk
#Include ../infra/magic_editor.ahk
#Include ../infra/config_io.ahk
#Include ../infra/config_scope.ahk
#Include ../infra/metrics/metrics_filters.ahk
#Include ../infra/metrics/metrics_shortcuts.ahk
#Include support/wpm_widget_state_contract.ahk
#Include support/config_journal_fixtures.ahk
#Include ../modules/llm/models.ahk
#Include ../infra/llm_defaults.ahk
#Include ../_generated/llm_profiles_data.ahk
#Include ../modules/llm/profiles.ahk
#Include ../modules/llm/option_validation.ahk
#Include ../modules/llm/prediction_engine.ahk
global _LLM_Menu := Map(
	"enabled", true, "backend", "ollama", "model", "Qwen3.5-0.8B",
	"profile_id", "basic", "n_predictions", 3, "auto_profile_for_model", true,
	"min_words", 3, "max_words", 15, "language", "fr", "debounce_ms", 500,
	"ctx_chars", 500, "temperature", "0.10", "instant_on_word_end", true,
	"after_hotstring", true, "reset_on_nav", true, "disable_url_bars", true,
	"disable_password_fields", true, "disabled_apps", [], "show_info_bar", true,
	"streaming", true, "show_all_at_once", true, "pred_indent", 0,
	"auto_raise_temp", true, "nav_modifiers", "", "val_modifiers", "alt",
	"api_entry_id", "api_primary",
	"ollama_port", 11434, "inline_autotype", false, "user_profiles", []
)
global _LLM_Menu_Loaded := false
#Include ../ui/menu/menu_llm/menu_api_entries.ahk
#Include ../ui/menu/menu_llm/transactions.ahk
#Include ../ui/menu/menu_llm/menu_models.ahk
#Include ../ui/menu/menu_llm/menu_profiles.ahk
#Include ../ui/menu/menu_llm/hotkey_identity.ahk
#Include ../ui/menu/menu_llm/persist.ahk
; The native AI tray owner catches the real staged-root exception classes.
#Include ../ui/menu/menu_rebuild.ahk
#Include ../ui/menu/menu_llm/init.ahk
#Include unit/modules/llm/menu/test_llm_menu_persistence.ahk
#Include unit/modules/llm/menu/test_llm_menu_regressions.ahk

; Isolated suite should finish in seconds; exit if a stale lock/hang blocks RunTests.
_LlmPersistWatchdog(*) {
	try FileAppend("`n[WATCHDOG] run_llm_menu_persistence timed out after 90s`n", "*")
	ExitApp(2)
}
SetTimer(_LlmPersistWatchdog, -LLM_PERSISTENCE_RUNNER_TIMEOUT_MS)

LLM_Defaults_Load()

RunTests()
