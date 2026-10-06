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


/** Exercises one true boundary through the actual native numeric allocator and Win32 menu. */
_LLMPC_GenerationBoundary(Key) {
	global _LLM_Menu, _SharedDir, LLM_MENU_N_OPTIONS
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\generation_boundaries.json", "UTF-8"))
	Expected := Corpus["boundaries"][Key]
	Saved := _LLM_Menu
	Frame := _MR_GetMenuDef(Expected["section"])
	Original := Frame[1]
	Native := 0
	try {
		_LLM_Menu := Saved.Clone()
		_LLM_Menu["n_predictions"] := _LLM_DefaultFor("llm_num_predictions")
		_LLM_Menu["ctx_chars"] := _LLM_DefaultFor("llm_context_length", 500)
		_LLM_Menu["min_words"] := _LLM_DefaultFor("llm_min_words", 3)
		_LLM_Menu["max_words"] := _LLM_DefaultFor("llm_max_words", 15)
		_LLM_Menu["temperature"] := Format("{:.2f}", Float(_LLM_DefaultFor("llm_temperature", "0.10")) + 0)
		Rows := _LLM_Menu_GenerationRows()
		AssertEqual(9, Rows.Length, "the independent default numeric order has no optional reset")
		Position := Key == "count" ? 2 : Key == "context" ? 5 : 8
		AssertTrue(Rows[Position]["separator"])
		AssertEqual(LLM_MENU_N_OPTIONS.Length, Rows[1]["items"].Length)
		AssertTrue(HasMethod(Rows[3]["action"], "Call"))
		AssertTrue(HasMethod(Rows[4]["action"], "Call"))
		AssertTrue(HasMethod(Rows[6]["action"], "Call"))
		AssertTrue(HasMethod(Rows[7]["action"], "Call"))
		AssertTrue(HasMethod(Rows[9]["action"], "Call"))
		Native := Menu()
		MenuRenderer_AppendRows(Native, "llm_generation_menu", "llm_generation_values", Rows)
		AssertEqual(Rows.Length, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"))
		Flags := DllCall("GetMenuState", "ptr", Native.Handle, "uint", Position - 1, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF && (Flags & 0x800) != 0, "the actual native boundary remains a separator")
		Frame[1] := Map("type", "label", "id", "generation_boundary_marker", "i18n", Corpus["published_marker_key"],
			"platforms", Original["platforms"], "unavailable", "hide")
		Rows := _LLM_Menu_GenerationRows()
		AssertEqual(9, Rows.Length)
		AssertEqual(t(Corpus["published_marker_key"]), Rows[Position].Get("label", ""), "the true native allocator consumes its shared declaration")
		AssertTrue(Rows[Position]["disabled"])
		AssertFalse(Rows[Position].Has("action"))
		AssertTrue(HasMethod(Rows[9]["action"], "Call"))
		Frame[1] := Map("type", "command", "id", "unowned_generation_boundary", "i18n", Corpus["published_marker_key"],
			"platforms", Original["platforms"], "unavailable", "hide")
		AssertEqual(0, _LLM_Menu_GenerationRows().Length, "a refused boundary cannot fall back to native presentation")
		AssertEqual(_LLM_DefaultFor("llm_num_predictions"), _LLM_Menu["n_predictions"])
		AssertEqual(_LLM_DefaultFor("llm_context_length", 500), _LLM_Menu["ctx_chars"])
	} finally {
		Frame[1] := Original
		_LLM_Menu := Saved
		if Native is Menu
			_CTC_ReleaseMenu(Native)
	}
}
for Key in ["count", "context", "words"]
	Test("generation boundaries: authentic numeric owner " . Key, _LLMPC_GenerationBoundary.Bind(Key))
