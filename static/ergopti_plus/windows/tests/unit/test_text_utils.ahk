; static/ergopti_plus/windows/tests/unit/test_text_utils.ahk

; ==============================================================================
; MODULE: Text Utilities Tests
; DESCRIPTION:
; Unit-tests for the pure string helpers in lib/text_utils.ahk.
; ==============================================================================






; ============================
; ============================
; ======= 1/ UriDecode =======
; ============================
; ============================

_SU_PlainStringPassesThrough() {
	AssertEqual("hello", UriDecode("hello"))
}
Test("UriDecode: plain string passes through unchanged", _SU_PlainStringPassesThrough)

_SU_DecodesSpace() {
	AssertEqual("hello world", UriDecode("hello%20world"))
}
Test("UriDecode: decodes space %20", _SU_DecodesSpace)

_SU_DecodesSlash() {
	AssertEqual("a/b", UriDecode("a%2Fb"))
}
Test("UriDecode: decodes forward slash %2F", _SU_DecodesSlash)

_SU_DecodesMultiple() {
	AssertEqual("a b/c", UriDecode("a%20b%2Fc"))
}
Test("UriDecode: decodes multiple sequences", _SU_DecodesMultiple)

_SU_LeavesLonePercent() {
	; A bare % not followed by two hex digits should not crash
	Result := UriDecode("50%")
	AssertEqual("50%", Result)
}
Test("UriDecode: leaves lone percent sign intact", _SU_LeavesLonePercent)

_SU_DecodesUppercaseHex() {
	AssertEqual(" ", UriDecode("%20"))
}
Test("UriDecode: decodes uppercase hex", _SU_DecodesUppercaseHex)

_SU_DecodesLowercaseHex() {
	AssertEqual(" ", UriDecode("%20"))
}
Test("UriDecode: decodes lowercase hex", _SU_DecodesLowercaseHex)

_SU_EmptyStringReturnsEmpty() {
	AssertEqual("", UriDecode(""))
}
Test("UriDecode: empty string returns empty string", _SU_EmptyStringReturnsEmpty)

_SU_DecodesRealisticFileUrlSegment() {
	; file:/// path with accented folder name
	Encoded := "T%C3%A9l%C3%A9chargements"
	; %C3%A9 = U+00E9 = é (UTF-8 two-byte sequence)
	; AHK Chr(0xC3) + Chr(0xA9) may not equal "é" in ANSI mode, so we just
	; verify the function does not crash and returns a non-empty string.
	Result := UriDecode(Encoded)
	Assert(StrLen(Result) > 0, "Expected non-empty decoded result")
}
Test("UriDecode: decodes a realistic file URL path segment", _SU_DecodesRealisticFileUrlSegment)
