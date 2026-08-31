; tests/meta/test_keylogger_json_64bit_decode.ahk

; ==============================================================================
; MODULE: Keylogger JSON 64-bit Decode Meta Test
; DESCRIPTION:
; Static source guard for finding keylogger-json-64bit-decode (F-H05).
;
; KL_JsonDecode used ComObject("ScriptControl"), which is x86-only, and explicitly
; short-circuited to an empty Map() when A_PtrSize != 4 (i.e. on the shipped 64-bit
; AutoHotkey64.exe). The consequence: cross-process cold-replay of today.log decoded
; every line to a typeless empty Map and skipped it while the persisted offset
; advanced past it (permanent metrics loss), AND KL_LoadState parsed state.json
; through the same no-op so today_log_offset reset to 0 and the resume point was
; lost — so the module header's "crash-safe replay" guarantee was non-functional on
; the default binary. The current wrapper delegates to the strict resident parser,
; which is pure AHK and therefore works in the shipped 64-bit process.
;
; The source assertion prevents a regression to the x86 ScriptControl path, while
; the behavioral cases below prove the production wrapper rejects malformed input.
; ==============================================================================

#Requires AutoHotkey v2.0


_KJ64_AssertRealDecoder() {
	Path := A_ScriptDir . "\..\modules\keylogger\keylogger_json.ahk"
	Assert(FileExist(Path), "the production keylogger JSON codec must exist")
	src := FileRead(Path, "UTF-8")
	Assert(InStr(src, "KL_JsonEncode(v)") > 0, "keylogger_json.ahk must still define the encoder (sanity)")
	Assert(InStr(src, "_KL_JsonNormalizeNull(JsonParse(s))") > 0,
		"KL_JsonDecode must share the strict resident 64-bit JSON boundary")
	Assert(!InStr(src, "_KL_JsonParseValue"),
		"the divergent permissive keylogger JSON parser must not be reintroduced")
	Assert(!InStr(src, "sc_available"),
		"KL_JsonDecode must no longer no-op on 64-bit via the ScriptControl-availability gate that returned an empty Map() for every line (keylogger-json-64bit-decode)")

}
Test("keylogger: JSON decoder uses the strict 64-bit resident parser, not ScriptControl (keylogger-json-64bit-decode)", _KJ64_AssertRealDecoder)

_KJ64_DecodeRejected(Input) {
	Decoded := KL_JsonDecode(Input)
	return Decoded is Map and Decoded.Count == 0
}

_KJ64_RejectsTrailingDocumentData() {
	AssertTrue(_KJ64_DecodeRejected('{"request_id":7} trailing'),
		"the keylogger decoder must reject a valid object followed by corrupt data")
}
Test("keylogger JSON: trailing document data is rejected (keylogger-json-strict)",
	_KJ64_RejectsTrailingDocumentData)

_KJ64_RejectsInvalidStringEscapes() {
	AssertTrue(_KJ64_DecodeRejected('{"value":"\q"}'),
		"the keylogger decoder must reject an escape forbidden by JSON")
	AssertTrue(_KJ64_DecodeRejected('{"value":"\uD800"}'),
		"the keylogger decoder must reject an isolated UTF-16 surrogate")
}
Test("keylogger JSON: invalid string escapes are rejected (keylogger-json-strict)",
	_KJ64_RejectsInvalidStringEscapes)

_KJ64_RejectsUnrepresentableNumbers() {
	AssertTrue(_KJ64_DecodeRejected('{"request_id":18446744073709551617}'),
		"the keylogger decoder must not wrap an out-of-range request id to 1")
	AssertTrue(_KJ64_DecodeRejected('{"value":1e309}'),
		"the keylogger decoder must not publish infinity")
}
Test("keylogger JSON: unrepresentable numbers are rejected (keylogger-json-strict)",
	_KJ64_RejectsUnrepresentableNumbers)

_KJ64_PreservesLegacyNullSentinel() {
	Decoded := KL_JsonDecode('{"value":null,"nested":[null]}')
	AssertTrue(Decoded is Map and Decoded.Has("value"),
		"a valid keylogger JSON object must still decode")
	AssertEqual("", Decoded["value"],
		"JSON null must retain the keylogger codec's empty-string representation")
	AssertTrue(Decoded["nested"] is Array)
	AssertEqual("", Decoded["nested"][1],
		"nested JSON null values must retain the legacy representation")
}
Test("keylogger JSON: strict delegation preserves null compatibility (keylogger-json-strict)",
	_KJ64_PreservesLegacyNullSentinel)
