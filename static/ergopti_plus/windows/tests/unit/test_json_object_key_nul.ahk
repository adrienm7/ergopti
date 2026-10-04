; tests/unit/test_json_object_key_nul.ahk

; ==============================================================================
; MODULE: JSON Object Key Representation Tests
; DESCRIPTION: Unsupported NUL keys must not alias native Map keys silently.
; ==============================================================================

#Requires AutoHotkey v2.0

_JOKN_Reject(Source) {
	AssertThrows(() => JsonParse(Source),
		"a NUL key cannot be returned faithfully in the native Map representation")
}
for Source in ['{"\u0000":1}', '{"prefix\u0000suffix":1}',
	'{"type":"safe","type\u0000hidden":"different"}',
	'{"prefix\u0000one":1,"prefix\u0000two":2}',
	'{"outer":{"\u0000nested":1}}', '[{"safe":1},{"\u0000":2}]']
	Test("JSON: reject unrepresentable object key case " . A_Index . " (json-object-key-nul)",
		_JOKN_Reject.Bind(Source))

_JOKN_Controls() {
	Decoded := JsonParse('{"":1,"\\u0000":2,"\u0001":3,"value":"before\u0000after"}')
	AssertEqual(4, Decoded.Count)
	AssertEqual(1, Decoded[""])
	AssertEqual(2, Decoded["\u0000"])
	AssertEqual(3, Decoded[Chr(1)])
	_KLJR_EqualString("before" . Chr(0) . "after", Decoded["value"], "NUL string value")
}
Test("JSON: preserve representable keys and NUL string values (json-object-key-nul)", _JOKN_Controls)
