; tests/meta/settings/persistence/test_savefullconfig_llm_loaded_gate.ahk

; ==============================================================================
; MODULE: SaveFullConfig LLM-loaded gate guard
; DESCRIPTION:
; SaveFullConfig gates _LLM_Menu_SyncToFeatures on _LLM_Menu_Loaded, but the five
; flat [llm] keys (onboarding_seen, app_profile_overrides, and the three written by
; _LLM_Menu_AppendPersistedUpdates: ollama_port, nav_modifiers, disabled_apps)
; round-trip through _LLM_Menu DIRECTLY and were left ungated. The
; boot-armed SaveFullConfig retry timer fires ~0-100 ms after _DriverReady, while
; LLM_Menu_Init runs seconds later at the end of the deferred menu build -- so the
; first flush wrote module defaults over the user's persisted LLM settings, and a
; second reload made the loss permanent. This guards that the flat [llm]
; persistence has its OWN _LLM_Menu_Loaded gate. (F03, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_SFLG_LlmPersistGatedOnLoaded() {
	Body := _DriverFuncBody("_ConfigCollectFullSaveUpdates")
	Assert(Body != "", "the full-save collector must exist in settings/engine/io.ahk")

	First := InStr(Body, "HasMenuCandidate := IsSet(MenuSource)")
	Second := InStr(Body, "if (MenuReady && (MenuState is Map))")
	Owned := _DriverFuncBody("_LLM_Menu_AppendOwnedPersistedUpdates")
	Owned := _DriverMaskBlockComments(&Owned)
	Owned := _StripFullLineComments(Owned)
	OwnedCall := InStr(Body, "_LLM_Menu_AppendOwnedPersistedUpdates(Updates, MenuState)")
	OnbPos := InStr(Owned, "ONBOARDING_SEEN")
	OvrPos := InStr(Owned, "APP_PROFILE_OVERRIDES")
	AppendPos := InStr(Owned, "_LLM_Menu_AppendPersistedUpdates(Updates, MenuState)")

	Assert(First > 0,
		"the collector must distinguish an explicit detached menu candidate from the live boot state")
	Assert(Second > 0,
		"the flat [llm] persistence needs its own MenuReady gate; without it a boot-timer flush before LLM_Menu_Init clobbers saved LLM values with module defaults")
	Assert(OwnedCall > Second && OnbPos > 0 && OvrPos > 0 && AppendPos > 0,
		"the sole complete private LLM collector must run AFTER MenuReady and retain every canonical owned row")

	Assert(InStr(Body, "IsSet(_LLM_Menu_Loaded) && _LLM_Menu_Loaded") > First,
		"MenuReady must continue to include the live _LLM_Menu_Loaded gate")
	Assert(InStr(Owned, "MenuState[") > 0 && InStr(Owned, "global _LLM_Menu") == 0,
		"flat LLM keys must read the gated explicit/live MenuState, never the "
		. "global menu directly")
}
Test("config: flat [llm] persistence is gated on _LLM_Menu_Loaded (no boot-timer default clobber)",
	_SFLG_LlmPersistGatedOnLoaded)

_SFLG_AppOverridesUseCanonicalBootCodec() {
	Body := _DriverFuncBody("_MI_StageLlm")
	Call := "_LLM_Menu_LoadAppProfileOverridesFromCache(_LlmSavedOpts, _IniCache)"
	Assert(InStr(Body, Call) > 0,
		"menu boot must restore app overrides through the canonical codec boundary")
	Assert(InStr(Body, "_LLM_Menu_DeserializeAppProfileOverrides(") == 0,
		"menu boot must not grow a second inline app-override parser")
}
Test("config: app-profile override boot restore uses the canonical codec (AHK-019)",
	_SFLG_AppOverridesUseCanonicalBootCodec)
