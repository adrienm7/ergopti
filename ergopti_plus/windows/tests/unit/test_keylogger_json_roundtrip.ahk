; tests/unit/test_keylogger_json_roundtrip.ahk

; ==============================================================================
; MODULE: Keylogger JSON String Roundtrip Tests
; DESCRIPTION: JSON publication must retain every UTF-16 code unit, including NUL.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLJR_EqualString(Expected, Actual, Stage := "") {
	AssertTrue(Actual is String)
	AssertEqual(StrLen(Expected), StrLen(Actual), Stage . ": the codec must preserve the complete string length")
	loop StrLen(Expected)
		AssertEqual(NumGet(StrPtr(Expected), (A_Index - 1) * 2, "UShort"),
			NumGet(StrPtr(Actual), (A_Index - 1) * 2, "UShort"),
			"the codec must preserve code unit " . A_Index)
}

_KLJR_Roundtrip(Value) {
	_KLJR_EqualString(Value, JsonParse(JsonStringLiteral(Value)), "shared literal")
	_KLJR_EqualString(Value, JsonParse(JsonStringLiteral(Value, true)), "HTML-safe literal")
	_KLJR_EqualString(Value, KL_JsonDecode(KL_JsonEncode(Value)), "keylogger scalar")
	Nested := Map("value", Value, "items", [Value])
	Decoded := KL_JsonDecode(KL_JsonEncode(Nested))
	AssertTrue(Decoded is Map)
	_KLJR_EqualString(Value, Decoded["value"], "map value")
	_KLJR_EqualString(Value, Decoded["items"][1], "array value")
}
for Value in [Chr(0), Chr(0) . "tail", "prefix" . Chr(0) . "tail", "prefix" . Chr(0),
	"", "é" . Chr(0) . "界" . Chr(0x1F642), '"\' . Chr(10), "0"]
	Test("keylogger JSON: complete string roundtrip case " . A_Index . " (keylogger-json-roundtrip)",
		_KLJR_Roundtrip.Bind(Value))

_KLJR_ControlAlphabet() {
	Value := ""
	loop 32
		Value .= Chr(A_Index - 1)
	Value .= '"\&<>' . Chr(0x2028) . Chr(0x2029) . Chr(0x1F642)
	_KLJR_Roundtrip(Value)
	; Native Map truncates keys at NUL before encoding can observe them. Keep
	; NUL in the value coverage above; verify representable keys independently.
	KeyValue := SubStr(Value, 2)
	Input := Map(KeyValue, "retained")
	for InputKey in Input
		_KLJR_EqualString(KeyValue, InputKey, "native map input key")
	Decoded := KL_JsonDecode(KL_JsonEncode(Input))
	AssertTrue(Decoded is Map)
	AssertEqual(1, Decoded.Count)
	for Key, Item in Decoded {
		_KLJR_EqualString(KeyValue, Key, "map key")
		AssertEqual("retained", Item)
	}
}
Test("keylogger JSON: control alphabet survives values and map keys (keylogger-json-roundtrip)",
	_KLJR_ControlAlphabet)
