; tests/unit/modules/llm/menu/test_llm_menu_backend_model_labels.ahk

; ==============================================================================
; MODULE: LLM Menu Model Button Labels
; DESCRIPTION:
; The tray's one model button (maintainer, 2026-10-27) reads the backend's
; emoji, then the model: "🦙 qwen3:4b", "🌐 OpenAI/gpt-4o-mini". The emoji
; comes from _shared/modules/llm/backends.json and the API form names the
; provider by its display name. The shown model follows the active backend:
; with backend api it is the selected entry, never the stale Ollama tag. The
; model the page adds is validated against the shared identifier corpus.
; ==============================================================================

#Requires AutoHotkey v2.0



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


; model-button-emoji-first: each backend form, with the emoji read from the
; shared file independently of the driver's loader.
_LBMD_SelectorCaptionForms() {
	global _LLM_Menu, LLM_API_PROVIDERS, _SharedDir
	Shared := JsonParse(FileRead(_SharedDir . "\modules\llm\backends.json", "UTF-8"))["backends"]
	AssertEqual(Shared["ollama"]["emoji"] . " qwen3:4b", LLM_ModelSelectorCaption("ollama", "qwen3:4b"))
	AssertEqual(Shared["mlx"]["emoji"] . " Qwen3-4B", LLM_ModelSelectorCaption("mlx", "Qwen3-4B"))
	SavedMenu := _LLM_Menu
	try {
		_LLM_Menu := Map("backend", "api", "model", "stale-ollama-tag", "api_entry_id", "e1",
			"api_entries", [Map("Id", "e1", "Name", "Mine", "Provider", "cerebras",
				"BaseUrl", "https://b.invalid/v1", "Token", "sekret", "Model", "qwen-3.8-27b")])
		Label := LLM_API_PROVIDERS["cerebras"]["Label"]
		AssertEqual(Label . "/qwen-3.8-27b", _LLM_Menu_ModelCaptionText(),
			"the API button names the provider's display name, then the model")
		AssertEqual(Shared["api"]["emoji"] . " " . Label . "/qwen-3.8-27b",
			LLM_ModelSelectorCaption("api", _LLM_Menu_ModelCaptionText()))
		_LLM_Menu["api_entries"][1]["Model"] := ""
		AssertEqual(Label . "/" . LLM_API_PROVIDERS["cerebras"]["DefaultModel"], _LLM_Menu_ModelCaptionText(),
			"an entry without a model is named after the model its requests use")
		_LLM_Menu["backend"] := "ollama"
		AssertEqual("stale-ollama-tag", _LLM_Menu_ModelCaptionText(), "a local backend shows its model")
	} finally _LLM_Menu := SavedMenu
	Refused := false
	try LLM_ModelSelectorCaption("kanata", "x")
	catch ValueError
		Refused := true
	AssertTrue(Refused, "an unknown backend is refused")
	Refused := false
	try LLM_ModelSelectorCaption("ollama", "")
	catch ValueError
		Refused := true
	AssertTrue(Refused, "an empty model text is refused")
}
Test("model-button-emoji-first: each backend form starts with the shared emoji",
	_LBMD_SelectorCaptionForms)

; The identifiers the page lets the user add, against the corpus the page,
; macOS and Linux validate too.
_LBMD_ModelIdentifierCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\model_identifiers.json", "UTF-8"))
	for Backend in ["ollama", "mlx"] {
		for Id in Corpus[Backend]["valid"]
			AssertTrue(LLM_ValidModelIdentifier(Backend, Id), Backend . " accepts '" . Id . "'")
		for Id in Corpus[Backend]["invalid"]
			AssertFalse(LLM_ValidModelIdentifier(Backend, Id), Backend . " refuses '" . Id . "'")
	}
	AssertFalse(LLM_ValidModelIdentifier("api", "gpt-4o"), "only local backends add models")
}
Test("model-selector-page: added model identifiers follow the shared corpus",
	_LBMD_ModelIdentifierCorpus)
