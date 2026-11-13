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
#Include ../core/logger/engine/tick_count.ahk
#Include ../core/logger/engine/wall_clock.ahk
#Include ../_generated/config_keys.ahk
#Include ../_generated/app_dirs.ahk
#Include ../apps/engine/folders.ahk
#Include ../settings/engine/migration/legacy_folder_migration.ahk
#Include ../_generated/logger_sub_files.ahk
#Include ../core/logger/engine/logger.ahk
#Include ../core/crypto/crypto.ahk
#Include ../core/fs/adapters/file_system.ahk
#Include ../core/events/timer_scheduler.ahk
#Include ../core/text/engine/json.ahk
#Include ../core/i18n/engine/locale.ahk
#Include ../_generated/locale_table.ahk
#Include ../core/i18n/engine/i18n.ahk
#Include ../infra/chord.ahk
#Include ../platform/input/hotkey_registrar.ahk
#Include ../infra/hotpath_profiler.ahk
#Include ../core/text/engine/toml/helpers.ahk
#Include ../core/text/engine/toml/loader.ahk
#Include ../core/text/engine/toml/config_loader.ahk
#Include ../menu/engine/manifest_reader.ahk
#Include ../core/lifecycle/engine/master_gates.ahk
#Include ../hotstrings/engine/catalogue/cache.ahk
#Include ../settings/engine/migration/transition.ahk
#Include ../settings/engine/migration/transition_runtime.ahk
#Include ../settings/engine/migration/migrate.ahk
#Include ../infra/magic_editor.ahk
#Include ../settings/engine/io.ahk
#Include ../settings/engine/scope/scope.ahk
#Include ../infra/metrics/metrics_filters.ahk
#Include ../infra/metrics/metrics_shortcuts.ahk
#Include support/wpm_widget_state_contract.ahk
#Include support/config_journal_fixtures.ahk
#Include ../ai/engine/settings/models.ahk
#Include ../ai/engine/defaults.ahk
#Include ../_generated/llm_profiles_data.ahk
#Include ../ai/engine/settings/profiles.ahk
#Include ../ai/engine/api/option_validation.ahk
#Include ../ai/engine/prediction/engine.ahk
global _LLM_Menu := Map(
	"enabled", true, "backend", "ollama", "model", "Qwen3.5-0.8B",
	"profile_id", "basic", "n_predictions", 3, "auto_profile_for_model", true,
	"min_words", 3, "max_words", 15, "language", "fr", "debounce_ms", 500, "min_request_interval_ms", 300,
	"ctx_chars", 500, "temperature", "0.10", "instant_on_word_end", true,
	"after_hotstring", true, "reset_on_nav", true, "disable_url_bars", true,
	"disable_password_fields", true, "disabled_apps", [], "show_info_bar", true,
	"streaming", true, "show_all_at_once", true, "pred_indent", 0,
	"auto_raise_temp", true, "nav_modifiers", "", "val_modifiers", "alt",
	"api_entry_id", "api_primary",
	"ollama_port", 11435, "inline_autotype", false, "user_profiles", []
)
global _LLM_Menu_Loaded := false
#Include ../ai/ui/menu/api_entries.ahk
#Include ../ai/ui/menu/transactions.ahk
#Include ../ai/ui/menu/models/models.ahk
#Include ../ai/ui/menu/profiles.ahk
#Include ../ai/ui/menu/hotkey_identity.ahk
#Include ../ai/ui/menu/persist.ahk
; The native AI tray owner catches the real staged-root exception classes.
#Include ../menu/ui/builder/rebuild.ahk
#Include ../ai/ui/menu/init.ahk
#Include unit/ai/menu/test_persistence.ahk
#Include unit/ai/menu/test_regressions.ahk

; Isolated suite should finish in seconds; exit if a stale lock/hang blocks RunTests.
_LlmPersistWatchdog(*) {
	try FileAppend("`n[WATCHDOG] run_llm_menu_persistence timed out after 90s`n", "*")
	ExitApp(2)
}
SetTimer(_LlmPersistWatchdog, -LLM_PERSISTENCE_RUNNER_TIMEOUT_MS)

LLM_Defaults_Load()

RunTests()
