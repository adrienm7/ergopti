; static/ergopti_plus/windows/tests/run_llm_menu_persistence.ahk
#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off
global _AHK_DRY_RUN := false
#Include test_framework.ahk
#Include test_stubs.ahk
#Include ../infra/json.ahk
#Include ../infra/toml/toml_helpers.ahk
#Include ../infra/toml/toml_config_loader.ahk
global _LLM_Menu := Map(
	"enabled", true, "backend", "ollama", "model", "Qwen3.5-0.8B",
	"profile_id", "basic", "n_predictions", 3, "auto_profile_for_model", true,
	"min_words", 3, "max_words", 15, "language", "fr", "debounce_ms", 500,
	"ctx_chars", 500, "temperature", "0.10", "instant_on_word_end", true,
	"after_hotstring", true, "reset_on_nav", true, "disable_url_bars", true,
	"disable_password_fields", true, "disabled_apps", [], "show_info_bar", true,
	"streaming", true, "show_all_at_once", true, "pred_indent", 0,
	"auto_raise_temp", true, "nav_modifiers", "", "val_modifiers", "alt",
	"trigger_shortcut", "Ctrl+Space", "api_entry_id", "api_primary",
	"ollama_port", 11434, "inline_autotype", false
)
#Include ../ui/menu/menu_llm/persist.ahk
#Include unit/test_llm_menu_persistence.ahk
#Include unit/test_llm_menu_regressions.ahk

; Isolated suite should finish in seconds; exit if a stale lock/hang blocks RunTests.
_LlmPersistWatchdog(*) {
	try FileAppend("`n[WATCHDOG] run_llm_menu_persistence timed out after 90s`n", "*")
	ExitApp(2)
}
SetTimer(_LlmPersistWatchdog, -90000)

RunTests()
