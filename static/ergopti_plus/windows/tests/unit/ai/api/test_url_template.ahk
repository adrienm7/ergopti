; tests/unit/ai/api/test_url_template.ahk

; ==============================================================================
; MODULE: API URL Template Corpus (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/llm/api_url_template_vectors.json through
; _shared/ai/data/api_url_template.ahk, the port of
; _shared/ai/engine/api/url_template.lua that macOS and Linux replay: the
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

_LAUT_Optional() {
	Section := _LAUT_Corpus()["optional_address"]
	Assert(Section["values"].Length >= 10, "the optional address vectors must not be empty")
	for Vector in Section["values"] {
		Url := ApiUrlTemplateOptionalUrl(Section["block"], Vector["value"])
		if Vector.Has("refused")
			AssertTrue(Url is Integer && Url == 0, Vector["value"] . " is refused")
		else
			AssertEqual(Vector["url"], Url, Vector["value"])
	}
	for Index, Vector in Section["blocks"]
		AssertEqual(Vector["valid"] ? true : false, ApiUrlTemplateOptionalProblem(Vector["block"]) == "",
			"block vector " . Index)
	AssertEqual("", ApiUrlTemplateOptionalProblem(""), "no block at all is fine")
}
Test("API URL template: the optional field keeps or replaces the address", _LAUT_Optional)

; The catalogue's block must parse, and every locale must name its real suffix.
_LAUT_OptionalLocales() {
	global _SharedDir, LLM_API_PROVIDERS
	Optional := LLM_API_PROVIDERS["dashscope"]["OptionalAddress"]
	AssertTrue(Optional is Map, "DashScope offers the workspace domain")
	Count := 0
	Loop Files _SharedDir . "\core\i18n\data\locales\*.json" {
		Count += 1
		Locale := JsonParse(FileRead(A_LoopFileFullPath, "UTF-8"))
		AssertContains(Locale["menu.llm.api_prompt_field_invalid." . Optional["field"]], Optional["host_suffix"],
			A_LoopFileName . " names the suffix the check enforces")
		AssertContains(Locale["menu.llm.api_prompt_field." . Optional["field"]], "maas.aliyuncs.com",
			A_LoopFileName . " shows a real example")
	}
	AssertEqual(21, Count, "every locale")
}
Test("API URL template: every locale names the suffix of the optional field", _LAUT_OptionalLocales)
