; tests/unit/test_llm_menu_backend_model_labels.ahk

; ==============================================================================
; MODULE: LLM Menu Backend/Model Label Tests
; DESCRIPTION:
; The IA submenu parent rows must show display names, not storage ids: the
; backend row reads what its submenu shows for the selected backend, cut
; before the em dash (« API 🌐 », never « Backend : api »), and the model row
; follows the active backend — with backend api it shows the selected API
; entry's automatic name, <provider>/<model> with the model requests use,
; never the stale Ollama tag from before the switch. The Ollama slot
; itself is preserved untouched so switching back restores it.
; ==============================================================================

#Requires AutoHotkey v2.0

; backend-row-selected-option. The Backend row read « Backend : API »; the
; maintainer asked on 2026-09-30 for the selected option as the submenu lists
; it, cut before its em dash, emoji included. The expected text is read from
; the submenu's own checked row, then pinned to the brand it must start with.
_LBMD_BackendRowLabel() {
	global _LLM_Menu
	Assert(_DriverFuncBody("_LLM_Menu_BackendRowLabel") != "",
		"_LLM_Menu_BackendRowLabel must exist in menu_models.ahk")
	SavedMenu := _LLM_Menu
	try {
		for Backend, Expected in Map("api", "API 🌐", "ollama", "Ollama 🦙") {
			_LLM_Menu := Map("backend", Backend, "ollama_port", 11434)
			Checked := ""
			for Row in _LLM_Menu_BackendRows() {
				if Row.Get("checked", false)
					Checked := Row["label"]
			}
			AssertContains(Checked, " — ", Backend . ": the option carries its description after an em dash")
			AssertEqual(Expected, _LLM_Menu_BackendRowLabel(),
				Backend . ": the row names the selected option, emoji included")
			AssertEqual(Expected, Trim(SubStr(Checked, 1, InStr(Checked, "—") - 1)),
				Backend . ": the row is the checked option cut before its em dash")
		}
		_LLM_Menu := Map("backend", "mlx", "ollama_port", 11434)
		AssertEqual(t("menu.llm.backend_unknown"), _LLM_Menu_BackendRowLabel(),
			"a backend the submenu does not offer is named unknown, never blank")
	} finally _LLM_Menu := SavedMenu
	AssertEqual("MLX 🚀", _LLM_Menu_OptionHead("MLX 🚀 — Recommandé — natif"),
		"the head stops at the first em dash")
	AssertEqual("Sans tiret", _LLM_Menu_OptionHead(" Sans tiret "),
		"a label without an em dash is shown whole")
}
Test("backend-row-selected-option: the Backend row names the selected option",
	_LBMD_BackendRowLabel)

_LBMD_ModelDisplayText() {
	global _LLM_Menu, LLM_API_PROVIDERS
	Assert(_DriverFuncBody("_LLM_Menu_ModelDisplayText") != "",
		"_LLM_Menu_ModelDisplayText must exist in menu_models.ahk")
	Assert(_DriverFuncBody("_LLM_Menu_ApiEntryDisplayName") != "",
		"_LLM_Menu_ApiEntryDisplayName must exist in menu_models.ahk")
	SavedMenu := _LLM_Menu
	try {
		_LLM_Menu := Map("backend", "api", "model", "stale-ollama-tag",
			"api_entry_id", "e1",
			"api_entries", [Map("Id", "e1", "Name", "Cerebras",
				"Provider", "cerebras", "BaseUrl", "https://b.invalid/v1",
				"Token", "sekret", "Model", "qwen-3.8-27b")])
		AssertEqual("cerebras/qwen-3.8-27b", _LLM_Menu_ModelDisplayText(),
			"with backend api the row shows the entry's automatic name, not its stored one")
		AssertEqual("cerebras/qwen-3.8-27b",
			_LLM_Menu_ApiEntryDisplayName(_LLM_Menu["api_entries"][1]))
		_LLM_Menu["api_entries"][1]["Model"] := ""
		AssertEqual("cerebras/" . LLM_API_PROVIDERS["cerebras"]["DefaultModel"],
			_LLM_Menu_ModelDisplayText(),
			"an entry without a model is named after the provider default")
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
	Assert(InStr(Main, "_LLM_Menu_BackendRowLabel(") > 0,
		"the backend row must name the selected option")
	Assert(InStr(Main, "_LLM_Menu_ModelDisplayText(") > 0,
		"the model row must use the display-text helper")
	Assert(InStr(Main, 'StrReplace(t("menu.llm.model_backend"), "%s", _LLM_Menu["backend"])') == 0,
		"the backend row must not show the raw storage id")
	Assert(InStr(Main, 'StrReplace(t("menu.llm.model_label"), "%s", _LLM_Menu["model"])') == 0,
		"the model row must not show the raw ollama slot")
}
Test("llm menu: parent rows route through display helpers (llm-menu-label-wiring)",
	_LBMD_RowsUseDisplayHelpers)
