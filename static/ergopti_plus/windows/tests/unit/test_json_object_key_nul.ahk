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

_JOKN_MemberSourceSpans() {
	Source := ' { "layouts" : { "valid" : {"id":"valid"}, "\u0072etired" : [false, null, 1.25e+2, {"comma":"},:"}] }, "tail":true } '
	Spans := JsonObjectMemberSpans(Source, ["layouts"])
	AssertEqual(2, Spans.Count, "decoded object membership")
	AssertEqual('{"id":"valid"}', Spans["valid"]["text"])
	Expected := '[false, null, 1.25e+2, {"comma":"},:"}]'
	AssertEqual(Expected, Spans["retired"]["text"], "primitive identities and nested delimiters remain raw")
	AssertEqual(Expected, SubStr(Source, Spans["retired"]["start"], Spans["retired"]["length"]))
	AssertEqual('"\u0072etired" : ' . Expected, Spans["retired"]["member_text"], "escaped key and spacing remain raw")
	AssertEqual(Spans["retired"]["member_text"],
		SubStr(Source, Spans["retired"]["member_start"], Spans["retired"]["member_length"]))
	AssertEqual('true', JsonObjectMemberSpans(Source)["tail"]["text"])
	AssertEqual('1', JsonObjectMemberSpans('{"": {"a.b": {"x":1}}}', ["", "a.b"])["x"]["text"],
		"parts name decoded keys rather than dotted paths")
	AssertEqual('2', JsonObjectMemberSpans('{"x":1,"\u0078":2}')["x"]["text"],
		"the span API preserves the generic parser's last-member-wins identity")
	AssertEqual(0, JsonObjectMemberSpans('{"empty":{}}', ["empty"]).Count)
	Quoted := '{"a\"b": {"value":"é\uD83D\uDE00"},"Case":1,"case":2}'
	AssertEqual('"é\uD83D\uDE00"', JsonObjectMemberSpans(Quoted, ['a"b'])["value"]["text"],
		"decoded quoted keys and Unicode source spelling remain exact")
	AssertEqual(3, JsonObjectMemberSpans(Quoted).Count, "native JSON member names retain case identity")
	Parsed := JsonParse(Quoted), Cased := JsonObjectMemberSpans(Quoted)
	AssertEqual(3, Parsed.Count, "full parser retains simultaneous cased keys")
	AssertEqual(1, Parsed["Case"]), AssertEqual(2, Parsed["case"])
	AssertEqual("1", Cased["Case"]["text"]), AssertEqual("2", Cased["case"]["text"])
	AssertEqual(Parsed.CaseSense, Cased.CaseSense, "descriptor map uses the same identity as the parser")
	Paths := '{"Node":{"value":1},"node":{"value":2}}'
	AssertEqual("1", JsonObjectMemberSpans(Paths, ["Node"])["value"]["text"])
	AssertEqual("2", JsonObjectMemberSpans(Paths, ["node"])["value"]["text"],
		"decoded path parts distinguish simultaneous cased parent members")
}
Test("JSON: public member spans preserve exact source and decoded object identity (json-member-spans)",
	_JOKN_MemberSourceSpans)

_JOKN_MemberSpanRefusals() {
	for Source in ['{"layouts":{}} trailing', '{"layouts":{}} {"second":1}',
		'{"layouts":{"safe":1},"later":[1,]}', '{"layouts":{"safe":1},"\u0000":2}',
		'{"layouts":{"prefix\u0000suffix":1}}', '{"layouts":{"safe":1},"later":1e999}']
		AssertThrows(JsonObjectMemberSpans.Bind(Source, ["layouts"]),
			"the entire source must satisfy the unchanged generic JSON parser")
	for Source in ['[]', 'null', 'false', '1', '"object"']
		AssertThrows(JsonObjectMemberSpans.Bind(Source), "a selected non-object cannot supply member spans")
	AssertThrows(() => JsonObjectMemberSpans('{"array":[]}', ["array"]))
	AssertThrows(() => JsonObjectMemberSpans('{"x":1}', ["missing"]))
	AssertThrows(() => JsonObjectMemberSpans('{"x":1}', "x"))
	AssertThrows(() => JsonObjectMemberSpans('{"x":1}', [1]))
}
Test("JSON: public member spans retain whole-document and path refusals (json-member-spans)",
	_JOKN_MemberSpanRefusals)


_JOKN_MemberPathNulRefusals() {
	AssertThrows(() => JsonObjectMemberSpans('{"layouts":{"safe":1}}', ["layouts" . Chr(0) . "hidden"]),
		"a decoded path part cannot alias its representable prefix at NUL")
	AssertThrows(() => JsonObjectMemberSpans('{"":{"safe":1}}', [Chr(0) . "hidden"]),
		"a decoded path part cannot alias the empty member name at NUL")
	AssertThrows(() => JsonObjectMemberSpans('{"outer":{"layouts":{"safe":1}}}',
		["outer", "layouts" . Chr(0) . "hidden"]), "every decoded path component is validated")
	AssertEqual("1", JsonObjectMemberSpans('{"\\u0000":{"safe":1}}', ["\u0000"])["safe"]["text"],
		"literal backslash-u text is a representable decoded path key")
}
Test("JSON: public member paths refuse native NUL aliases before lookup (json-member-spans)",
	_JOKN_MemberPathNulRefusals)
