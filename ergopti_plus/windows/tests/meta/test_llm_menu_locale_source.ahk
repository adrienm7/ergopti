; tests/meta/test_llm_menu_locale_source.ahk

; ==============================================================================
; MODULE: LLM Menu Locale Source Guard
; DESCRIPTION:
; Pins the production-only menu projection and default-state wiring. The
; behavior suite exercises the definitions-only projection, while this guard
; ensures no stale menu slot can be reintroduced beside the i18n owner.
; ==============================================================================

#Requires AutoHotkey v2.0

_AHK021_MenuHasExactlyOneLocaleSource() {
	BuildOpts := _DriverFuncBody("LLM_Menu_BuildOpts")
	Restore := _DriverFuncBody("_LLM_Menu_RestoreSavedOptsOnce")
	Fire := _DriverFuncBody("LLM_Engine_FirePrediction")
	Source := _DriverSourceNoComments()
	Assert(BuildOpts != "" && Restore != "" && Fire != "" && Source != "",
		"AHK-021 source guard must resolve every production boundary")
	Assert(RegExMatch(BuildOpts, 'i)"language"\s*,\s*I18nGetLocale\(\)') > 0,
		"the menu projection must consult the active i18n owner")
	AssertFalse(InStr(BuildOpts, '_LLM_Menu["language"]') > 0,
		"the retired menu-local language must not influence production options")
	AssertFalse(InStr(Restore, '"language"') > 0,
		"boot restore must not recreate a second language source")
	MenuStart := InStr(Source, "global _LLM_Menu := Map(")
	MenuEnd := InStr(Source, "global LLM_PROFILE_ADVANCED_PARAMS_B",, MenuStart)
	Assert(MenuStart > 0 && MenuEnd > MenuStart,
		"the source guard must isolate the LLM menu default graph")
	MenuDefaults := SubStr(Source, MenuStart, MenuEnd - MenuStart)
	Assert(RegExMatch(MenuDefaults, 'i)"language"\s*,') == 0,
		"the LLM menu default graph must not seed a second locale owner")
	PromptStart := InStr(Fire, "system_prompt := LLM_ResolveSystemPrompt(")
	Assert(PromptStart > 0,
		"the provider path must still resolve a system prompt")
	PromptTail := SubStr(Fire, PromptStart)
	PromptEnd := InStr(PromptTail, "`n`t)")
	Assert(PromptEnd > 0,
		"the source guard must isolate the complete system-prompt call")
	PromptCall := SubStr(PromptTail, 1, PromptEnd + 2)
	AssertContains(PromptCall, '_LLM_Engine["language"]',
		"the request prompt must consume the engine's admitted language")
}
Test("AHK-021 locale: production menu has one i18n language source "
	. "(ahk-021-locale-owner)", _AHK021_MenuHasExactlyOneLocaleSource)
