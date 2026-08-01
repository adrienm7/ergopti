; tests/meta/test_savefullconfig_llm_loaded_gate.ahk

; ==============================================================================
; MODULE: SaveFullConfig LLM-loaded gate guard
; DESCRIPTION:
; SaveFullConfig gates _LLM_Menu_SyncToFeatures on _LLM_Menu_Loaded, but the six
; flat [llm] keys (onboarding_seen, app_profile_overrides, and the four written by
; _LLM_Menu_AppendPersistedUpdates: trigger_shortcut, ollama_port, nav_modifiers,
; disabled_apps) round-trip through _LLM_Menu DIRECTLY and were left ungated. The
; boot-armed SaveFullConfig retry timer fires ~0-100 ms after _DriverReady, while
; LLM_Menu_Init runs seconds later at the end of the deferred menu build -- so the
; first flush wrote module defaults over the user's persisted LLM settings, and a
; second reload made the loss permanent. This guards that the flat [llm]
; persistence has its OWN _LLM_Menu_Loaded gate. (F03, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_SFLG_LlmPersistGatedOnLoaded() {
	Body := _DriverFuncBody("SaveFullConfig")
	Assert(Body != "", "SaveFullConfig must exist in infra/config_io.ahk")

	First := InStr(Body, "_LLM_Menu_Loaded")
	Second := InStr(Body, "_LLM_Menu_Loaded", , First + 1)
	OnbPos := InStr(Body, "onboarding_seen")
	OvrPos := InStr(Body, "app_profile_overrides")
	AppendPos := InStr(Body, "_LLM_Menu_AppendPersistedUpdates")

	Assert(First > 0, "SaveFullConfig must gate _LLM_Menu_SyncToFeatures on _LLM_Menu_Loaded")
	Assert(Second > 0,
		"the flat [llm] persistence needs its OWN _LLM_Menu_Loaded gate; without it a boot-timer flush before LLM_Menu_Init clobbers saved LLM values with module defaults")
	Assert(OnbPos > Second && OvrPos > Second && AppendPos > Second,
		"onboarding_seen / app_profile_overrides / _LLM_Menu_AppendPersistedUpdates must sit AFTER the dedicated _LLM_Menu_Loaded gate")

	FirstMenuRead := InStr(Body, "_LLM_Menu[")
	Assert(FirstMenuRead = 0 || FirstMenuRead > Second,
		"no _LLM_Menu[...] read may occur before the flat-keys _LLM_Menu_Loaded gate")
}
Test("config: flat [llm] persistence is gated on _LLM_Menu_Loaded (no boot-timer default clobber)",
	_SFLG_LlmPersistGatedOnLoaded)
