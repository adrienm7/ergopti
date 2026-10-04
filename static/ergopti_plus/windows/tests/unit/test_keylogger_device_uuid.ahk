; static/ergopti_plus/windows/tests/unit/test_keylogger_device_uuid.ahk

; ==============================================================================
; MODULE: Keylogger Device UUID Tests
; DESCRIPTION:
; Native GUID integer fields must keep their numeric order in persistent identity
; text. Literal fixtures and the native GUID formatter provide independent oracles.
; No device configuration, journal, registry or input state is opened.
; ==============================================================================

#Requires AutoHotkey v2.0+

_KLDU_Fill(Guid, Data1, Data2, Data3, Data4) {
	AssertEqual(16, Guid.Size)
	NumPut("UInt", Data1, "UShort", Data2, "UShort", Data3, Guid)
	for Index, Value in Data4
		NumPut("UChar", Value, Guid, Index + 7)
	return 0
}

_KLDU_Literal(Data1, Data2, Data3, Data4, Expected) {
	AssertEqual(Expected, KL_UuidV4(_KLDU_Fill.Bind(, Data1, Data2, Data3, Data4)),
		"canonical identity text must preserve native integer fields and Data4 bytes")
}
Test("device UUID: native integer fields retain order (device-uuid-format)",
	_KLDU_Literal.Bind(0x12345678, 0x9ABC, 0x4DEF, [0x8F, 0xED, 1, 0x23, 0x45, 0x67, 0x89, 0xAB],
		"12345678-9abc-4def-8fed-0123456789ab"))
Test("device UUID: unsigned field and maximum tail (device-uuid-format)",
	_KLDU_Literal.Bind(0xFEDCBA98, 0x7654, 0x4321, [0xBF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
		"fedcba98-7654-4321-bfff-ffffffffffff"))
Test("device UUID: zero padding and lowercase text (device-uuid-format)",
	_KLDU_Literal.Bind(1, 2, 0x4003, [0x80, 4, 0, 0, 0, 0, 0, 5],
		"00000001-0002-4003-8004-000000000005"))

_KLDU_NativeReference() {
	Captured := { Guid: 0 }
	Create := (Guid) => _KLDU_CreateNative(Captured, Guid)
	Actual := KL_UuidV4(Create)
	Text := Buffer(78, 0)
	Written := DllCall("ole32\StringFromGUID2", "Ptr", Captured.Guid, "Ptr", Text, "Int", 39, "Int")
	AssertEqual(39, Written, "the independent native formatter must succeed")
	Expected := StrLower(SubStr(StrGet(Text, "UTF-16"), 2, 36))
	AssertEqual(Expected, Actual, "device text must agree with the native formatter for the same GUID")
	AssertTrue(RegExMatch(Actual, "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
}

_KLDU_CreateNative(Captured, Guid) {
	Captured.Guid := Guid
	Result := DllCall("ole32\CoCreateGuid", "Ptr", Guid, "Int")
	AssertEqual(0, Result, "the native comparison fixture must obtain a GUID")
	return Result
}
Test("device UUID: actual native GUID formatter agrees (device-uuid-format)", _KLDU_NativeReference)

_KLDU_DefaultNative() {
	Actual := KL_UuidV4()
	AssertTrue(RegExMatch(Actual, "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"),
		"the actual supported native producer must retain its UUID version and variant")
}
Test("device UUID: default native producer retains version (device-uuid-format)", _KLDU_DefaultNative)

; A failed native producer must not persist zero bytes or an apparently valid ID.
_KLDU_Failure(Result, Fill) {
	Create := (Guid) => _KLDU_Refuse(Guid, Result, Fill)
	Caught := 0
	try KL_UuidV4(Create)
	catch as Failure
		Caught := Failure
	AssertTrue(IsObject(Caught), "a failed GUID producer must escape before returning an identity")
	if Result is Integer
		AssertContains(Caught.Message, Format("0x{:08X}", Result & 0xFFFFFFFF), "the failure preserves its complete HRESULT")
	else
		AssertEqual("TypeError", Type(Caught), "invalid producer state must fail explicitly")
}

_KLDU_Refuse(Guid, Result, Fill) {
	if Fill
		_KLDU_Fill(Guid, 0x12345678, 0x9ABC, 0x4DEF, [0x8F, 0xED, 1, 0x23, 0x45, 0x67, 0x89, 0xAB])
	return Result
}
Test("device UUID: negative HRESULT rejects zero identity (device-uuid-failure)", _KLDU_Failure.Bind(-2147024882, false))
Test("device UUID: failed filled buffer is refused (device-uuid-failure)", _KLDU_Failure.Bind(-2147467259, true))
Test("device UUID: nonzero success code is not S_OK (device-uuid-failure)", _KLDU_Failure.Bind(1, true))
Test("device UUID: invalid producer result fails fast (device-uuid-failure)", _KLDU_Failure.Bind("", false))
