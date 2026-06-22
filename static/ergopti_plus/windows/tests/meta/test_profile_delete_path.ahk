; tests/meta/test_profile_delete_path.ahk

; ==============================================================================
; MODULE: Profile Delete Path Meta Test
; DESCRIPTION:
; Static source guard for the "no-profile-delete-path" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TPD_Check() {
	; Move-resilient: scan the menu_llm UI dir via the framework helper instead of
	; a pinned menu_profiles.ahk path. The Cancel/RemoveAt tokens are unique to
	; menu_profiles within the dir, so the present-string checks are unambiguous.
	Src := _DriverDirConcat("ui/menu/menu_llm")
	Assert(InStr(Src, 'choice == "Cancel"') > 0, "menu_profiles.ahk must handle Cancel choice")
	Assert(InStr(Src, "RemoveAt(i)") > 0, "menu_profiles.ahk must delete profile from user_profiles")
	Assert(InStr(Src, "LLM_Menu_BindProfileHotkeys") > 0, "menu_profiles.ahk must re-bind hotkeys")
}

Test("LLMTray: profiles can be deleted", _TPD_Check)
