; tests/meta/test_json_string_decoder_single_source.ahk

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
	UpdaterBody := _DriverFuncBody("Updater_ParseBody")
	Assert(UpdaterBody != "" && InStr(UpdaterBody, "JsonStringDecodeContents(") > 0,
		"Updater_ParseBody must decode captured string contents through the shared parser")
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
