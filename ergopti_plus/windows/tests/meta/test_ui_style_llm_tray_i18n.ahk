; tests/meta/test_ui_style_llm_tray_i18n.ahk

; ==============================================================================
; MODULE: UiStyle Fatal MsgBox + LLM Tray i18n Guard
; DESCRIPTION:
; Regression guard for two hardcoded-French sites that bypassed i18n despite
; it being fully initialized at both call sites: infra/ui_style.ahk's
; fatal-startup MsgBox, and ui/menu/menu_llm/actions.ahk's install TrayTip
; (3 call sites — the warning-row click handler's title/launching/error, and
; the debug hotkey's title/launching).
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaUiStyleAndLlmTrayI18n() {
	Src := _DriverSourceNoComments()

	; infra/ui_style.ahk must not hardcode the French fatal-error strings.
	Assert(!InStr(Src, "Erreur fatale : _shared/modules/tooltip/constants.toml"),
		'infra/ui_style.ahk must not hardcode the French fatal-error message — use t("dialog.fatal_error.*")')
	Assert(!InStr(Src, "ne peut pas démarrer"),
		'infra/ui_style.ahk must not hardcode "ne peut pas démarrer" — use t("dialog.fatal_error.cannot_start")')
	Assert(InStr(Src, 't("dialog.fatal_error.toml_key_missing")') > 0,
		'_UiStyleFatal must build its message via t("dialog.fatal_error.toml_key_missing")')
	Assert(InStr(Src, 't("dialog.fatal_error.toml_not_found")') > 0,
		'UiStyle_LoadSharedConst`'s missing-file branch must use t("dialog.fatal_error.toml_not_found")')

	; ui/menu/menu_llm/actions.ahk must not hardcode the French install TrayTip.
	Assert(!InStr(Src, "Lancement de l'installation Ollama"),
		'ui/menu/menu_llm/actions.ahk must not hardcode the French install TrayTip — use t("llm.deps.install_launching")')
	Assert(!InStr(Src, "Installation Ollama (déclenchée par raccourci)"),
		'ui/menu/menu_llm/actions.ahk`'s debug hotkey must not hardcode French — use t("llm.deps.install_launching_hotkey")')
	Assert(InStr(Src, 't("llm.deps.tray_title")') > 0,
		'menu_llm/actions.ahk`'s install TrayTip title must use t("llm.deps.tray_title") instead of the hardcoded "Ergopti — IA"')
}
Test("i18n: ui_style fatal MsgBox and LLM install TrayTip route through t() instead of hardcoded French", _MetaUiStyleAndLlmTrayI18n)
