; tests/unit/test_llm_menu_locale_bridge.ahk

; ==============================================================================
; MODULE: LLM Menu Locale Bridge Tests
; DESCRIPTION:
; Proves that the production menu projection takes its language from the active
; i18n owner, that boot cannot restore the retired menu-local slot, and that the
; resulting language reaches the system prompt and serialized provider request.
; ==============================================================================

#Requires AutoHotkey v2.0

_AHK021_MenuLocaleFlowsIntoProviderRequest() {
	global _I18nLocale, _LLM_Menu, _LLM_Engine
	SavedLocale := _I18nLocale
	SavedMenu := _LLM_Menu
	SavedEngine := _LLM_Engine
	try {
		_LLM_Menu := LLM_Menu_DeepClone(SavedMenu)
		for Key, Value in Map(
			"user_profiles", [],
			"api_entries", [],
			"api_entry_id", "",
			"app_profile_overrides", Map()) {
			if !_LLM_Menu.Has(Key)
				_LLM_Menu[Key] := Value
		}
		; A legacy or test-only field must not override the actual locale owner.
		_LLM_Menu["language"] := "fr"
		for Locale in ["de", "es"] {
			_I18nLocale := Locale
			Opts := LLM_Menu_BuildOpts()
			AssertEqual(Locale, Opts["language"],
				"the menu projection must read the current i18n locale")
			LLM_Engine_Init(Opts)
			AssertEqual(Locale, _LLM_Engine["language"])
			Profile := Map("system_single", "locale={language}")
			Prompt := LLM_ResolveSystemPrompt(Profile, 1,
				_LLM_Engine["min_words"], _LLM_Engine["max_words"],
				_LLM_Engine["language"])
			AssertEqual("locale=" . Locale, Prompt)
			Payload := LLM_BuildOllamaPayload("model", Prompt, "context", 0.1)
			AssertContains(Payload, '"content":"locale=' . Locale . '"',
				"the serialized provider request must carry the active locale")
		}

		; Explicit language remains a supported engine contract for genuine
		; non-menu callers; only the stale menu-owned override is retired.
		_I18nLocale := "de"
		LLM_Engine_Init(Map("language", "ja"))
		AssertEqual("ja", _LLM_Engine["language"])
		OverridePrompt := LLM_ResolveSystemPrompt(
			Map("system_single", "locale={language}"), 1, 1, 15,
			_LLM_Engine["language"])
		AssertEqual("locale=ja", OverridePrompt)
	} finally {
		_I18nLocale := SavedLocale
		_LLM_Menu := SavedMenu
		_LLM_Engine := SavedEngine
	}
}
Test("AHK-021 locale: menu locale reaches the engine, prompt and request "
	. "(ahk-021-locale-owner)", _AHK021_MenuLocaleFlowsIntoProviderRequest)

_AHK021_BootCannotRestoreRetiredMenuLanguage() {
	global _LLM_Menu, _LLM_Menu_Loaded
	SavedMenu := _LLM_Menu
	SavedLoaded := _LLM_Menu_Loaded
	try {
		_LLM_Menu := LLM_Menu_DeepClone(SavedMenu)
		if _LLM_Menu.Has("language")
			_LLM_Menu.Delete("language")
		_LLM_Menu_Loaded := false
		AssertTrue(_LLM_Menu_RestoreSavedOptsOnce(Map("language", "fr")))
		AssertFalse(_LLM_Menu.Has("language"),
			"boot must not recreate a second language source from stale state")
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_Menu_Loaded := SavedLoaded
	}
}
Test("AHK-021 locale: boot ignores the retired menu language slot "
	. "(ahk-021-locale-owner)", _AHK021_BootCannotRestoreRetiredMenuLanguage)
