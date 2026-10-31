; tests/unit/modules/llm/api/test_llm_api_url_template.ahk

; ==============================================================================
; MODULE: API URL Template Corpus (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/llm/api_url_template_vectors.json through
; _shared/modules/llm/api_url_template.ahk, the port of
; _shared/lua/llm/api_url_template.lua that macOS and Linux replay: the
; placeholders of a per-account provider's address, the values that may fill
; one, and the address the add-entry form stores.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Shared corpus ================
; =========================================
; =========================================

_LAUT_Corpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\llm\api_url_template_vectors.json"
	AssertTrue(FileExist(Path) != "", "the API URL template corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

_LAUT_Fields() {
	Corpus := _LAUT_Corpus()
	AssertEqual(Corpus["max_value_length"], ApiUrlTemplateMaxValueLength(), "the value bound")
	Assert(Corpus["fields"].Length >= 6, "the fields vectors must not be empty")
	for Vector in Corpus["fields"] {
		Parsed := ApiUrlTemplateFields(Vector["template"])
		AssertEqual(Vector["valid"] ? true : false, Parsed["valid"], Vector["template"] . ": valid")
		AssertEqual(Vector["fields"].Length, Parsed["fields"].Length, Vector["template"] . ": field count")
		for Index, Name in Vector["fields"]
			AssertEqual(Name, Parsed["fields"][Index], Vector["template"] . ": field " . Index)
	}
}
Test("API URL template: the placeholders of a template", _LAUT_Fields)

_LAUT_Values() {
	Corpus := _LAUT_Corpus()
	Assert(Corpus["values"].Length >= 12, "the value vectors must not be empty")
	for Index, Vector in Corpus["values"] {
		Value := ""
		if Vector.Has("value_repeat") {
			loop Vector["count"]
				Value .= Vector["value_repeat"]
		} else
			Value := Vector["value"]
		AssertEqual(Vector["valid"] ? true : false, ApiUrlTemplateValidValue(Value) ? true : false,
			"value vector " . Index . ": " . Value)
	}
}
Test("API URL template: the values that may fill a placeholder", _LAUT_Values)

_LAUT_Expand() {
	Corpus := _LAUT_Corpus()
	Assert(Corpus["expand"].Length >= 6, "the expand vectors must not be empty")
	for Index, Vector in Corpus["expand"] {
		Result := ApiUrlTemplateExpand(Vector["template"], Vector["values"])
		if Vector.Has("field") {
			AssertFalse(Result.Has("url"), "expand vector " . Index . " is refused")
			AssertEqual(Vector["field"], Result.Get("field", ""), "expand vector " . Index . ": field")
		} else
			AssertEqual(Vector["url"], Result.Get("url", ""), "expand vector " . Index . ": url")
	}
	for Vector in Corpus["placeholder"]
		AssertEqual(Vector["has"] ? true : false, ApiUrlTemplateHasPlaceholder(Vector["url"]), Vector["url"])
}
Test("API URL template: the filled address and the refusal of a bad value", _LAUT_Expand)
