; tests/unit/test_llm_api_entry_names.ahk

; ==============================================================================
; MODULE: Automatic API Entry Names (Windows)
; DESCRIPTION:
; Regression api-entry-auto-name. The dialog that adds an API entry asked for a
; name last, and every row showed whatever was typed. The maintainer asked on
; 2026-09-30 for each entry to read <provider>/<model>, such as
; "cerebras/qwen-3.8-27b", with no name to type:
; - the shared corpus (api_entry_names_vectors.json), which macOS and Linux
;   replay through _shared/lua/llm/api_entry_names.lua, pins the port;
; - the rows show the automatic name, never a name an earlier build stored;
; - two entries of one provider and model read apart;
; - the dialog asks the provider, URL, key and model, and no name.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Shared corpus ================
; =========================================
; =========================================

_LAEN_Corpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\llm\api_entry_names_vectors.json"
	AssertTrue(FileExist(Path) != "", "the API entry names corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

_LAEN_HostVectors() {
	Corpus := _LAEN_Corpus()
	Assert(Corpus["host"].Length >= 5, "the host vectors must not be empty")
	for Vector in Corpus["host"]
		AssertEqual(Vector["host"], _LLM_ApiEntryHost(Vector["url"]), "host of '" . Vector["url"] . "'")
}
Test("api-entry-auto-name: the host of a base URL follows the shared corpus", _LAEN_HostVectors)

_LAEN_NameVectors() {
	Corpus := _LAEN_Corpus()
	Assert(Corpus["names"].Length >= 5, "the name vectors must not be empty")
	for Vector in Corpus["names"] {
		Names := _LLM_ApiEntryNames(Vector["entries"])
		AssertEqual(Vector["names"].Length, Names.Length, Vector["id"] . ": one name per entry")
		for Index, Expected in Vector["names"]
			AssertEqual(Expected, Names[Index], Vector["id"] . ": entry " . Index)
	}
}
Test("api-entry-auto-name: entry names follow the shared corpus", _LAEN_NameVectors)





; =========================================
; =========================================
; ======= 2/ The menu =====================
; =========================================
; =========================================

; An entry saved by an earlier build, with the name the user typed then.
_LAEN_Entry(Id, Name, Model, BaseUrl := "https://api.cerebras.ai/v1") {
	return Map("Id", Id, "Name", Name, "Provider", "cerebras", "BaseUrl", BaseUrl,
		"Token", "sekret", "Model", Model)
}

; The labels of the entry rows, the rows before the Add row.
_LAEN_EntryLabels() {
	Labels := []
	for Row in _LLM_Menu_ApiEntriesRows() {
		if (Row.Get("label", "") == t("menu.llm.api_add_entry"))
			break
		Labels.Push(Row["label"])
	}
	return Labels
}

_LAEN_RowsShowAutomaticNames() {
	global _LLM_Menu, LLM_API_PROVIDERS
	SavedMenu := _LLM_Menu
	try {
		_LLM_Menu := Map("backend", "api", "api_entry_id", "a", "api_entries", [
			_LAEN_Entry("a", "Ma clé perso", "qwen-3.8-27b"),
			_LAEN_Entry("b", "Autre", "llama-3.3-70b")])
		Labels := _LAEN_EntryLabels()
		AssertEqual(2, Labels.Length)
		AssertEqual("cerebras/qwen-3.8-27b", Labels[1], "a typed name from an earlier build is not shown")
		AssertEqual("cerebras/llama-3.3-70b", Labels[2])
		AssertEqual("cerebras/qwen-3.8-27b", _LLM_Menu_ApiEntryDisplayName(_LLM_Menu["api_entries"][1]),
			"the model row names the active entry the same way")
		_LLM_Menu["api_entries"][1]["Model"] := ""
		AssertEqual("cerebras/" . LLM_API_PROVIDERS["cerebras"]["DefaultModel"],
			_LLM_Menu_ApiEntryDisplayName(_LLM_Menu["api_entries"][1]),
			"an entry without a model is named after the model its requests use")
	} finally _LLM_Menu := SavedMenu
}
Test("api-entry-auto-name: rows name each entry after its provider and model", _LAEN_RowsShowAutomaticNames)

_LAEN_DuplicatesReadApart() {
	global _LLM_Menu
	SavedMenu := _LLM_Menu
	try {
		_LLM_Menu := Map("backend", "api", "api_entry_id", "a", "api_entries", [
			_LAEN_Entry("a", "Un", "qwen-3.8-27b"),
			_LAEN_Entry("b", "Deux", "qwen-3.8-27b"),
			_LAEN_Entry("c", "Trois", "qwen-3.8-27b", "http://localhost:8080/v1")])
		Labels := _LAEN_EntryLabels()
		AssertEqual("cerebras/qwen-3.8-27b (api.cerebras.ai)", Labels[1])
		AssertEqual("cerebras/qwen-3.8-27b (api.cerebras.ai, 2)", Labels[2],
			"another key at the same address is told apart by its order")
		AssertEqual("cerebras/qwen-3.8-27b (localhost:8080)", Labels[3],
			"another address is told apart by its host")
		AssertEqual(Labels[2], _LLM_Menu_ApiEntryDisplayName(_LLM_Menu["api_entries"][2]),
			"one entry is named as the list names it")
	} finally _LLM_Menu := SavedMenu
}
Test("api-entry-auto-name: two entries of one provider and model read apart", _LAEN_DuplicatesReadApart)

; The dialog asks four fields and no name: provider, URL, key, model. Scanned
; comment-stripped so prose cannot satisfy it.
_LAEN_DialogAsksNoName() {
	Code := _StripFullLineComments(_DriverFuncBody("_LLM_Menu_PromptApiEntry"))
	Assert(Code != "", "_LLM_Menu_PromptApiEntry must remain source-visible")
	for Key in ["api_prompt_provider", "api_prompt_url", "api_prompt_token", "api_prompt_model"]
		Assert(InStr(Code, Key) > 0, "the dialog must still prompt " . Key)
	AssertEqual(0, InStr(Code, "api_prompt_name"), "the dialog asks no name")
	Asked := 0
	Pos := 1
	while (Pos := InStr(Code, "InputBox(", true, Pos)) {
		Asked += 1
		Pos += 1
	}
	AssertEqual(4, Asked, "the dialog has four fields: provider, URL, key and model")
	AssertContains(Code, '"Name",     provider_id . "/" . new_model',
		"the stored name is the automatic one, for the builds that still read it")
}
Test("api-entry-auto-name: adding an entry asks no name", _LAEN_DialogAsksNoName)
