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
; the default binary. The fix replaces it with a hand-rolled recursive-descent parser
; that works on 64-bit (validated by an encode/decode round-trip of a representative
; entry: strings with escapes, ints, floats, bools, nested arrays/maps, control
; chars and unicode all survive).
;
; Source-scan because test_stubs.ahk defines a minimal flat-regex KL_JsonDecode that
; would shadow a behavioural test; this asserts the production decoder is the real
; 64-bit-capable parser, not the ScriptControl no-op.
; ==============================================================================

#Requires AutoHotkey v2.0


_KJ64_AssertRealDecoder() {
	; Scan the whole driver source so the test survives a file move of the decoder.
	src := _DriverSourceConcat()
	Assert(InStr(src, "KL_JsonEncode(v)") > 0, "keylogger_json.ahk must still define the encoder (sanity)")
	Assert(InStr(src, "_KL_JsonParseValue") > 0,
		"KL_JsonDecode must use the hand-rolled recursive-descent parser so cross-process replay + state.json restore work on the shipped 64-bit binary (keylogger-json-64bit-decode)")
	Assert(!InStr(src, "sc_available"),
		"KL_JsonDecode must no longer no-op on 64-bit via the ScriptControl-availability gate that returned an empty Map() for every line (keylogger-json-64bit-decode)")

}
Test("keylogger: JSON decoder is a 64-bit-capable hand-rolled parser, not the ScriptControl no-op (keylogger-json-64bit-decode)", _KJ64_AssertRealDecoder)
