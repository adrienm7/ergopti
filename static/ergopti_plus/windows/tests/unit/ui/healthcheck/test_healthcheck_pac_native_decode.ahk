; tests/unit/ui/healthcheck/test_healthcheck_pac_native_decode.ahk

; ==============================================================================
; MODULE: Diagnostics PAC Native Decoder Edge Cases
; DESCRIPTION:
; Independent literal RAW byte vectors exercise the actual PAC decoder and its
; native strict UTF16 boundary. No HTTP, decoder, adapter or policy is replaced.
; Existing HTTP tests own transport and inclusive byte-limit qualification.
; ==============================================================================

#Requires AutoHotkey v2.0

_HCPDU_Case(Mode) {
	Vectors := Map(
		"le-high", [0xFF, 0xFE, 0x41, 0, 0, 0xD8, 0x42, 0],
		"le-low", [0xFF, 0xFE, 0x41, 0, 0, 0xDC, 0x42, 0],
		"be-high", [0xFE, 0xFF, 0, 0x41, 0xD8, 0, 0, 0x42],
		"be-low", [0xFE, 0xFF, 0, 0x41, 0xDC, 0, 0, 0x42],
		"utf8-nul", [0x41, 0, 0x42],
		"utf16le-nul", [0xFF, 0xFE, 0x41, 0, 0, 0, 0x42, 0],
		"utf8-bom-only", [0xEF, 0xBB, 0xBF],
		"le-bom-only", [0xFF, 0xFE],
		"be-bom-only", [0xFE, 0xFF],
		"utf8-bom-valid", [0xEF, 0xBB, 0xBF, 0x41, 0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80, 0xEF, 0xBF, 0xBD])
	Bytes := Vectors[Mode], Raw := Buffer(Bytes.Length, 0)
	for Index, Byte in Bytes
		NumPut("UChar", Byte, Raw, Index - 1)
	Address := Raw.Ptr
	Result := _HC_PacDecodeSource(Raw, 1048576)
	AssertTrue(Result is Map, "The real decoder must return an explicit source verdict")
	AssertEqual(Address, Raw.Ptr, "Decoding must not replace the caller's RAW buffer")
	AssertEqual(Bytes.Length, Raw.Size, "Decoding must preserve the exact source length")
	for Index, Byte in Bytes
		AssertEqual(Byte, NumGet(Raw, Index - 1, "UChar"), "Decoding must preserve every original source byte")
	if Mode != "utf8-bom-valid" {
		AssertTrue(Result.Has("error") && Result["error"] is String && Result["error"] != "",
			"Malformed text, embedded NUL or an empty BOM payload requires an explicit refusal")
		AssertFalse(Result.Has("body"), "Refusal must not expose replacement or truncated text as an admitted body")
		return
	}
	AssertFalse(Result.Has("error"), "A valid UTF8 BOM with non-ASCII, astral and literal replacement characters must be admitted")
	AssertEqual("UTF-8", Result["encoding"])
	AssertEqual(13, Result["raw_bytes"], "The original byte count includes the BOM")
	AssertEqual(10, Result["normalized_bytes"], "The normalized UTF8 byte count excludes only the BOM")
	Body := Result["body"], Units := [0x41, 0xE9, 0xD83D, 0xDE00, 0xFFFD]
	AssertEqual(Units.Length, StrLen(Body), "The admitted body must preserve every UTF16 unit")
	for Index, Unit in Units
		AssertEqual(Unit, NumGet(StrPtr(Body), (Index - 1) * 2, "UShort"),
			"The independently specified Unicode text must survive exact native decoding")
}

for _HCPDU_Mode in ["le-high", "le-low", "be-high", "be-low", "utf8-nul", "utf16le-nul",
	"utf8-bom-only", "le-bom-only", "be-bom-only", "utf8-bom-valid"]
	Test("PAC decoder: " . _HCPDU_Mode . " preserves strict source text (diagnostics-pac-native-decode)",
		_HCPDU_Case.Bind(_HCPDU_Mode))
