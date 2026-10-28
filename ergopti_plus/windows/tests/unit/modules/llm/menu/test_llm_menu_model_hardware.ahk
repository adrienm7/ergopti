; tests/unit/modules/llm/menu/test_llm_menu_model_hardware.ahk

; ==============================================================================
; MODULE: LLM Menu Per-App Profile Frame
; DESCRIPTION:
; The per-app profile frame keeps its lazy native commands and its true empty
; predicate, and refuses a withdrawn declaration. The per-model hardware rows
; this file also covered left the tray with the model list on 2026-10-27; the
; model selector page shows that hardware (tools/test/test-model-selector-page.cjs).
; ==============================================================================

#Requires AutoHotkey v2.0



/** The per-app frame retains lazy native commands and its true empty predicate. */
_LBMD_CompletePerAppFrame() {
	global _LLM_Menu
	Saved := _LLM_Menu
	Root := _MM_GetManifestRoot(), Original := Root["llm_profile_app_override_frame"]
	try {
		_LLM_Menu := Saved.Clone()
		; Match the genuine menu constructor rather than inheriting another fixture's profile array.
		_LLM_Menu["user_profiles"] := []
		_LLM_Menu["app_profile_overrides"] := Map()
		Empty := _LLM_Menu_PerAppProfileRows()
		AssertEqual(1, Empty.Length)
		AssertEqual(t("menu.profiles.override_active_app_with_current"), Empty[1]["label"])
		AssertTrue(HasMethod(Empty[1]["action"], "Call"))
		_LLM_Menu["app_profile_overrides"] := Map("editor.exe", "default")
		Rows := _LLM_Menu_PerAppProfileRows()
		AssertEqual(3, Rows.Length)
		AssertTrue(Rows[2]["separator"])
		AssertEqual("editor.exe  →  " . LLM_Menu_GetProfileLabel("default"), Rows[3]["label"])
		AssertTrue(HasMethod(Rows[3]["action"], "Call"))
		Root.Delete("llm_profile_app_override_frame")
		AssertThrows(_LLM_Menu_PerAppProfileRows, "the actual unowned per-app frame refuses construction")
		Root["llm_profile_app_override_frame"] := [Map("type", "command", "id", "unbound_profile_override", "i18n", "button.cancel")]
		AssertThrows(_LLM_Menu_PerAppProfileRows, "the actual unowned per-app frame refuses construction")
		AssertEqual("default", _LLM_Menu["app_profile_overrides"]["editor.exe"])
	} finally {
		Root["llm_profile_app_override_frame"] := Original
		_LLM_Menu := Saved
	}
}
Test("complete per-app frame: actual empty/populated override owner and strict withdrawal", _LBMD_CompletePerAppFrame)


; The native profile reader legitimately requires assigned canonical profile records.
; Seed a real sparse Array to prove this fixture never inherits another case's holes.
_LBMD_PerAppFrameIsolatesProfiles() {
	global _LLM_Menu
	Saved := _LLM_Menu, Holey := []
	Holey.Length := 1
	try {
		_LLM_Menu := Saved.Clone()
		_LLM_Menu["user_profiles"] := Holey
		Owner := _LLM_Menu
		AssertThrows(LLM_Menu_GetProfileLabel.Bind("default"), "the genuine profile reader rejects an unassigned inherited record")
		_LBMD_CompletePerAppFrame()
		AssertEqual(Owner, _LLM_Menu, "the per-app fixture restores the same prior map")
		AssertEqual(Holey, _LLM_Menu["user_profiles"], "the per-app fixture restores the same prior profile array")
		AssertFalse(Holey.Has(1), "the fixture cannot fill or mutate the borrowed sparse array")
	} finally _LLM_Menu := Saved
}
Test("per-app fixture: isolate canonical profiles and restore the genuine borrowed sparse array",
	_LBMD_PerAppFrameIsolatesProfiles)
