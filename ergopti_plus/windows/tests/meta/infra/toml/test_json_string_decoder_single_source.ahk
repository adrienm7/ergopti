; tests/meta/infra/toml/test_json_string_decoder_single_source.ahk

; ==============================================================================
; MODULE: JSON String Decoder Single-Source Regression Test
; DESCRIPTION:
; Pins every compatibility decoder to the complete shared JSON parser. Valid
; escape sequences must never be decoded by partial ordered replacement lists.
; ==============================================================================

#Requires AutoHotkey v2.0

_JSDS_AllDecodersDelegate() {
	for Name in ["_LLMRemoteJsonUnescape", "LLM_UnescapeJSON"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "" && InStr(Body, "JsonStringDecodeContents(") > 0,
			Name . " must delegate to the shared complete JSON string decoder")
	}
	; Release metadata validates the whole release object with the complete parser
	; and decodes only the member it reads, through the parser's own object
	; grammar, rather than from a captured string slice: it never needs the
	; contents decoder, and no partial replacement may decode the notes.
	UpdaterBody := _DriverFuncBody("Updater_ParseBody")
	Assert(UpdaterBody != "" && InStr(UpdaterBody, "_Updater_ReleaseMember(") > 0,
		"Updater_ParseBody must read the notes through the shared release member decoder")
	MemberBody := _DriverFuncBody("_Updater_ReleaseMember")
	Assert(MemberBody != "" && InStr(MemberBody, "JsonObjectMembers(") > 0,
		"the release member decoder must use the shared JSON member selection")
	SelectionBody := _DriverFuncBody("JsonObjectMembers")
	Assert(SelectionBody != "" && InStr(SelectionBody, "_JsonParseObject(") > 0,
		"the JSON member selection must decode through the complete parser's object grammar")
	for Name, Body in Map("Updater_ParseBody", UpdaterBody, "_Updater_ReleaseMember", MemberBody) {
		Assert(!InStr(Body, "StrReplace(") && !InStr(Body, "RegExMatch(") && !InStr(Body, "RegExReplace("),
			Name . " must not decode release text with a partial replacement or pattern")
	}
	DecoderBody := _DriverFuncBody("_Updater_DecodeRelease")
	Assert(DecoderBody != "" && InStr(DecoderBody, "JsonParse(") > 0,
		"the release decoder must use the complete shared JSON parser")
}
Test("JSON decode: every compatibility boundary uses one complete decoder (json-string-decoder-single-source)",
	_JSDS_AllDecodersDelegate)

_JSDS_ProductionBoundariesRoundTripEveryEscape() {
	Expected := 'quote" slash/ backslash\ literal\n'
	Expected .= Chr(8) . "tab`t newline`n formfeed" . Chr(12) . " return`r"
	Expected .= Chr(0x2028) . Chr(0x2029) . Chr(0x1F642)
	Contents := JsonStringContents(Expected)

	AssertEqual(Expected, _LLMRemoteJsonUnescape(Contents),
		"remote-provider compatibility decoding must preserve every JSON escape")
	AssertEqual(Expected, LLM_UnescapeJSON(Contents),
		"Ollama/profile compatibility decoding must preserve every JSON escape")
	AssertEqual(Expected, Updater_ParseBody('{"body":' . JsonStringLiteral(Expected) . '}'),
		"updater release-body decoding must preserve every JSON escape")

	SurrogateContents := "\ud83d\ude42"
	AssertEqual(Chr(0x1F642), _LLMRemoteJsonUnescape(SurrogateContents),
		"remote decoder must combine a valid surrogate pair")
	AssertEqual(Chr(0x1F642), LLM_UnescapeJSON(SurrogateContents),
		"Ollama decoder must combine a valid surrogate pair")
}
Test("JSON decode: production boundaries round-trip every escape (json-string-decoder-single-source)",
	_JSDS_ProductionBoundariesRoundTripEveryEscape)
