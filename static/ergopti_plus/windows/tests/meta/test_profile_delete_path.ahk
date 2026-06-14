; tests/meta/test_profile_delete_path.ahk

; ==============================================================================
; MODULE: Profile Delete Path Meta Test
; DESCRIPTION:
; Static source guard for the "no-profile-delete-path" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TPD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_TPD_Check() {
	Src := _TPD_ReadSource("ui/tray_llm/menu_profiles.ahk")
	Assert(Src != "", "Source file menu_profiles.ahk must exist")
	Assert(InStr(Src, 'choice == "Cancel"') > 0, "menu_profiles.ahk must handle Cancel choice")
	Assert(InStr(Src, "RemoveAt(i)") > 0, "menu_profiles.ahk must delete profile from user_profiles")
	Assert(InStr(Src, "LLM_Tray_BindProfileHotkeys") > 0, "menu_profiles.ahk must re-bind hotkeys")
}

Test("LLMTray: profiles can be deleted", _TPD_Check)
