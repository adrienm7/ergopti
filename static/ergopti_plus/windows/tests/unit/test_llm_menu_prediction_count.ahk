; tests/unit/test_llm_menu_prediction_count.ahk

; ==============================================================================
; MODULE: LLM Menu Prediction Count Tests
; DESCRIPTION:
; The count rows (1 to 10 suggestions) read one locale key per plural form:
; menu.llm.prediction_count_label_one for one, _other for every other count.
; They used to read a single key and inject an "s" after the noun, a rule only
; French and English follow, so every other locale rendered a wrong plural.
; ==============================================================================

#Requires AutoHotkey v2.0

_LLMPC_CountRowsUsePluralKeys() {
	global _LLM_Menu, LLM_MENU_N_OPTIONS
	Assert(_DriverFuncBody("_LLM_Menu_NRows") != "",
		"_LLM_Menu_NRows must exist in menu_settings.ahk")
	One := t("menu.llm.prediction_count_label_one")
	Other := t("menu.llm.prediction_count_label_other")
	Assert(One != "menu.llm.prediction_count_label_one" && InStr(One, "%d"),
		"the singular key must resolve to a template with %d, got: " . One)
	Assert(Other != "menu.llm.prediction_count_label_other" && InStr(Other, "%d"),
		"the plural key must resolve to a template with %d, got: " . Other)
	SavedMenu := _LLM_Menu
	try {
		_LLM_Menu := Map("n_predictions", 3)
		Rows := _LLM_Menu_NRows()
		AssertEqual(LLM_MENU_N_OPTIONS.Length, Rows.Length, "one row per count option")
		for Index, N in LLM_MENU_N_OPTIONS {
			Expected := StrReplace((N == 1) ? One : Other, "%d", N)
			AssertEqual(Expected, Rows[Index]["label"],
				"count " . N . " must read the " . ((N == 1) ? "singular" : "plural") . " key")
			AssertEqual(N == 3, Rows[Index]["checked"], "only the active count is ticked")
		}
	} finally _LLM_Menu := SavedMenu
}
Test("llm menu: count rows read the one/other plural keys (llm-count-plural)",
	_LLMPC_CountRowsUsePluralKeys)
