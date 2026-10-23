; tests/meta/infra/toml/test_json_string_literal_single_source.ahk

; ==============================================================================
; MODULE: JSON/JavaScript String Literal Single-Source Regression Test
; DESCRIPTION:
; Discovers every WebView string-literal helper and pins the raw JSON-content
; serializers which accept user-controlled text. All must delegate to the codec
; that escapes the complete C0 range, rather than maintaining partial copies.
; ==============================================================================

#Requires AutoHotkey v2.0

_JSLSS_AllWebViewStringHelpers() {
	Src := _DriverSourceNoComments()
	Names := Map()
	Pos := 1
	Pattern := "m)^[ \t]*([A-Za-z_][A-Za-z0-9_]*(?:JsStr|JSStr))\([^\r\n]*\)\s*\{"
	while (Found := RegExMatch(Src, Pattern, &Match, Pos)) {
		Names[Match[1]] := true
		Pos := Found + Match.Len
	}
	return Names
}

_JSLSS_EveryWebViewHelperDelegates() {
	Names := _JSLSS_AllWebViewStringHelpers()
	; Twelve helpers exist today; a lower count means the discovery broke.
	Assert(Names.Count >= 12,
		"the discovery must find every JsStr/JSStr helper, including generic and Ollama variants")
	for Name, _ in Names {
		Body := _DriverFuncBody(Name)
		Assert(InStr(Body, "JsonStringLiteral(") > 0,
			Name . " must delegate to the complete shared JSON string encoder")
	}

	for Name in ["_LLMRemoteJsonEscape", "_LLM_MenuApiJsonEscape", "KLR__JsonEscape"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "" && InStr(Body, "JsonStringContents(") > 0,
			Name . " must delegate to the shared unquoted JSON-string encoder")
	}
	for Name in ["KL_JsonStr", "KL_JsonEncodeString"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "" && InStr(Body, "JsonStringLiteral(") > 0,
			Name . " must delegate to the shared quoted JSON-string encoder")
	}
}
Test("JSON strings: every WebView and payload serializer uses one complete encoder (json-string-literal-single-source)",
	_JSLSS_EveryWebViewHelperDelegates)

_JSLSS_ContentsRoundTripEveryControl() {
	Text := "prefix"
	; AutoHotkey strings cannot retain an embedded NUL. Exercise every other C0
	; character plus the JavaScript-only line separators.
	Loop 31
		Text .= Chr(A_Index)
	Text .= Chr(0x2028) . Chr(0x2029) . "suffix"
	Encoded := '"' . JsonStringContents(Text) . '"'
	AssertEqual(Text, JsonParse(Encoded),
		"unquoted JSON contents must round-trip every control and JavaScript line separator")
}
Test("JSON strings: unquoted shared contents round-trip controls (json-string-literal-single-source)",
	_JSLSS_ContentsRoundTripEveryControl)

_JSLSS_LiteralEscapesNatively() {
	; The Versions window escapes a release list of about 2 MB on the thread that
	; runs the keyboard hook: a script loop per code unit took 3 s there.
	for Name in ["JsonStringLiteral", "_JsonEscapeNulFreeRun"] {
		Body := _StripFullLineComments(_DriverFuncBody(Name))
		Assert(Body != "", Name . " must be found")
		Assert(!RegExMatch(Body, "i)\bloop\s+StrLen\("),
			Name . " must not walk its input one code unit at a time")
	}
	Assert(InStr(_StripFullLineComments(_DriverFuncBody("_JsonEscapeNulFreeRun")), "StrReplace(") > 0,
		"the shared JSON string encoder must escape through native replacement passes")
}
Test("JSON strings: the shared encoder escapes in native passes (json-string-literal-single-source)",
	_JSLSS_LiteralEscapesNatively)
