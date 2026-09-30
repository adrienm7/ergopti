; tests/unit/test_llm_menu_prediction_count.ahk

; ==============================================================================
; MODULE: LLM Menu Prediction Count Tests
; DESCRIPTION:
; The count rows (1 to 10 suggestions) read one locale key per plural form:
; menu.llm.prediction_count_label_one for one, _other for every other count.
; They used to read a single key and inject an "s" after the noun, a rule only
; French and English follow, so every other locale rendered a wrong plural.
; The count row itself heads the generation submenu, as on macOS and Linux,
; instead of sitting at the top level of the AI menu.
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

; The count is a generation parameter: it heads the generation submenu on every
; driver, and the top level no longer draws a row of its own for it.
_LLMPC_CountHeadsGenerationRows() {
	global _LLM_Menu, LLM_MENU_N_OPTIONS
	Assert(_DriverFuncBody("_LLM_Menu_GenerationRows") != "",
		"_LLM_Menu_GenerationRows must exist in menu_settings.ahk")
	SavedMenu := _LLM_Menu
	try {
		_LLM_Menu := SavedMenu.Clone()
		_LLM_Menu["n_predictions"] := 4
		Rows := _LLM_Menu_GenerationRows()
		Assert(Rows.Length > 0, "the generation submenu must have rows")
		Head := Rows[1]
		AssertEqual(StrReplace(t("menu.llm.num_predictions_label"), "%s", 4), Head.Get("label", ""),
			"the suggestion count must be the first generation parameter")
		Assert(Head.Has("items") && Head["items"] is Array,
			"the count row must open its choices")
		AssertEqual(LLM_MENU_N_OPTIONS.Length, Head["items"].Length,
			"the count row keeps one choice per option")
	} finally _LLM_Menu := SavedMenu
	Emit := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_EmitRow"))
	Assert(Emit != "", "_LLM_Menu_EmitRow must remain source-visible")
	Assert(InStr(Emit, 'case "llm_profile":') > 0,
		"the dispatch must still answer its declared rows")
	Assert(!InStr(Emit, 'case "llm_num_predictions":'),
		"the top level must not draw a suggestion count row of its own")
}
Test("llm menu: the suggestion count heads the generation submenu (llm-count-row)",
	_LLMPC_CountHeadsGenerationRows)
