; tests/unit/test_llm_menu_backend_model_labels.ahk

; ==============================================================================
; MODULE: LLM Menu Backend/Model Label Tests
; DESCRIPTION:
; The IA submenu parent rows must show display names, not storage ids: the
; backend row reads "Backend: API", never "Backend: api", and the model row
; follows the active backend — with backend api it shows the selected API
; entry's model (falling back to the provider default, exactly what requests
; use), never the stale Ollama tag from before the switch. The Ollama slot
; itself is preserved untouched so switching back restores it.
; ==============================================================================

#Requires AutoHotkey v2.0

_LBMD_BackendDisplayName() {
	Assert(_DriverFuncBody("_LLM_Menu_BackendDisplayName") != "",
		"_LLM_Menu_BackendDisplayName must exist in menu_models.ahk")
	AssertEqual("API", _LLM_Menu_BackendDisplayName("api"))
	AssertEqual("Ollama", _LLM_Menu_BackendDisplayName("ollama"))
	AssertEqual("weird", _LLM_Menu_BackendDisplayName("weird"),
		"an unknown backend falls back to its id, never blanks")
}
Test("llm menu: backend row shows display names (llm-menu-backend-label)",
	_LBMD_BackendDisplayName)

_LBMD_ModelDisplayText() {
	global _LLM_Menu, LLM_API_PROVIDERS
	Assert(_DriverFuncBody("_LLM_Menu_ModelDisplayText") != "",
		"_LLM_Menu_ModelDisplayText must exist in menu_models.ahk")
	SavedMenu := _LLM_Menu
	try {
		_LLM_Menu := Map("backend", "api", "model", "stale-ollama-tag",
			"api_entry_id", "e1",
			"api_entries", [Map("Id", "e1", "Name", "Cerebras",
				"Provider", "cerebras", "BaseUrl", "https://b.invalid/v1",
				"Token", "sekret", "Model", "qwen-3.8-27b")])
		AssertEqual("qwen-3.8-27b", _LLM_Menu_ModelDisplayText(),
			"with backend api the row shows the entry model, not the ollama tag")
		_LLM_Menu["api_entries"][1]["Model"] := ""
		AssertEqual(LLM_API_PROVIDERS["cerebras"]["DefaultModel"],
			_LLM_Menu_ModelDisplayText(),
			"an entry without model falls back to the provider default")
		_LLM_Menu["api_entry_id"] := "ghost"
		AssertEqual("", _LLM_Menu_ModelDisplayText(),
			"an unknown entry never resurrects the stale ollama tag")
		_LLM_Menu["backend"] := "ollama"
		_LLM_Menu["api_entry_id"] := "e1"
		AssertEqual("stale-ollama-tag", _LLM_Menu_ModelDisplayText(),
			"with backend ollama the preserved slot shows untouched")
	} finally _LLM_Menu := SavedMenu
}
Test("llm menu: model row follows the active backend (llm-menu-model-label)",
	_LBMD_ModelDisplayText)

; The EmitRow cases must route both labels through the helpers instead of
; the raw storage slots. Scanned comment-stripped so prose can never
; satisfy the assertions.
_LBMD_RowsUseDisplayHelpers() {
	Main := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_EmitRow"))
	Assert(Main != "", "_LLM_Menu_EmitRow must remain source-visible")
	Assert(InStr(Main, "_LLM_Menu_BackendDisplayName(") > 0,
		"the backend row must use the display-name helper")
	Assert(InStr(Main, "_LLM_Menu_ModelDisplayText(") > 0,
		"the model row must use the display-text helper")
	Assert(InStr(Main, 'StrReplace(t("menu.llm.model_backend"), "%s", _LLM_Menu["backend"])') == 0,
		"the backend row must not show the raw storage id")
	Assert(InStr(Main, 'StrReplace(t("menu.llm.model_label"), "%s", _LLM_Menu["model"])') == 0,
		"the model row must not show the raw ollama slot")
}
Test("llm menu: parent rows route through display helpers (llm-menu-label-wiring)",
	_LBMD_RowsUseDisplayHelpers)
