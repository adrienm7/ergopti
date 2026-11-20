; tests/unit/core/text/toml/test_json_decode_fast_path.ahk

; ==============================================================================
; MODULE: JSON Decode Fast-Path Tests
; DESCRIPTION:
; JsonParse reads plain members and elements by anchored matches. The exact
; walk, entered without the pattern set, is the reference: every shipped
; document and every edge case must decode to the same tree, the same value
; types and the same decode counters, and every refusal must keep its message.
; ==============================================================================

; A canonical text of a decoded value: kinds, types, key order and code units.
_JsonDecodeFast_Canon(Value) {
	if (Value is Map) {
		Text := "{"
		for Key, Item in Value
			Text .= _JsonDecodeFast_Units(Key) . ":" . _JsonDecodeFast_Canon(Item) . ","
		return Text . "}"
	}
	if (Value is Array) {
		Text := "["
		for Item in Value
			Text .= _JsonDecodeFast_Canon(Item) . ","
		return Text . "]"
	}
	if IsObject(Value)
		return Value == JSON_NULL ? "null" : "object?"
	return Type(Value) . "(" . _JsonDecodeFast_Units(String(Value)) . ")"
}

_JsonDecodeFast_Units(Text) {
	Units := ""
	loop StrLen(Text)
		Units .= Format("{:04x}", NumGet(StrPtr(Text), (A_Index - 1) * 2, "UShort"))
	return Units
}

; The outcome of one decoder over Text: its canonical tree and counters, or its refusal.
_JsonDecodeFast_Outcome(Text, Fast) {
	Tally := _JsonDecodeCounters()
	Units := Tally.StringUnits, Containers := Tally.Containers
	try {
		if Fast {
			Value := JsonParse(Text)
		} else {
			Pos := 1
			Value := _JsonParseValue(&Text, &Pos, 0)
			_JsonSkipWs(&Text, &Pos)
			if (Pos <= StrLen(Text))
				throw Error("JSON: unexpected trailing data at position " . Pos . ".", -1)
		}
		Result := _JsonDecodeFast_Canon(Value)
	} catch as Err {
		Result := "refused " . Type(Err) . ": " . Err.Message
	}
	return Result . " units=" . (Tally.StringUnits - Units) . " containers=" . (Tally.Containers - Containers)
}

_JsonDecodeFast_AssertSame(Text, Label) {
	AssertEqual(_JsonDecodeFast_Outcome(Text, false), _JsonDecodeFast_Outcome(Text, true),
		"JsonParse must decode as the exact walk does: " . Label)
}

_JsonDecodeFast_ShippedDocuments() {
	global _SharedDir
	Paths := [_SharedDir . "\menu\data\menu_manifest.json", _SharedDir . "\ai\data\api_providers.json"]
	for Path in Paths {
		AssertTrue(FileExist(Path) != "", "the shipped document must exist: " . Path)
		_JsonDecodeFast_AssertSame(FileRead(Path, "UTF-8"), Path)
	}
}
Test("JSON decode: shipped documents decode as the exact walk does (json-decode-fast-path)",
	_JsonDecodeFast_ShippedDocuments)

_JsonDecodeFast_EdgeCases() {
	Cases := ['{}', '[]', '{"a":1}', '{"a":1,}', '[1,]', '{"a" : 1 , "b" :"x" }', '{"a":-0}', '{"a":0123}',
		'{"a":1-2}', '{"a":1.5}', '{"a":1e5}', '{"a":123456789012345678}', '{"a":1234567890123456789}',
		'{"a":9223372036854775808}', '{"a":truex}', '{"a":nul}', '{"a":"x\ny"}', '{"a\u0000":1}',
		'{"a":"\u0000"}', '{"a":"😀"}', '{"a":"``x"}', '{"a":[1,"b",true,false,null,{"c":[]}]}',
		'[ 1 , 2 ]', '[1 2]', '{"a":1 "b":2}', '{"a":1}x', ' {"a":{"b":{"c":1}}} ', '{"a":"b","a":"c"}',
		'"plain"', '12', '-', '{"a":}', '{"a"}', '{a:1}', '{"a":"x', '["x', '{"a":[1,2,3', '{"a":tru}',
		'[true,false,null]', '{"":1,"":2}', '[ ]', '{ }', '[-0, 0, -1, 1e-3]', '{"a":01}', '{"a":--1}',
		'{"a":1.}', '{"a":"x"   ,   "b"  :  [  ]  }', '{"a":"x' . Chr(9) . 'y"}', '{"a":"' . Chr(0xD800) . '"}',
		'{"' . Chr(0xDC00) . '":1}', '{"a":"' . Chr(0xD83D) . Chr(0xDE00) . '"}', '{"a":"' . Chr(0) . '"}',
		'{"a":{"b":1}' . Chr(10) . ',"c":[{"d":"e"},2]}']
	for Text in Cases
		_JsonDecodeFast_AssertSame(Text, Text)
}
Test("JSON decode: plain and refused edge cases decode as the exact walk does (json-decode-fast-path)",
	_JsonDecodeFast_EdgeCases)
