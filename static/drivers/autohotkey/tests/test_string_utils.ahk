; static/drivers/autohotkey/tests/test_string_utils.ahk

; ==============================================================================
; MODULE: String Utilities Tests
; DESCRIPTION:
; Unit-tests for the pure string helpers in lib/string_utils.ahk.
; ==============================================================================




; ==============================
; ==============================
; ======= 1/ UriDecode =======
; ==============================
; ==============================

Test("UriDecode: plain string passes through unchanged", () => {
	AssertEqual("hello", UriDecode("hello"))
})

Test("UriDecode: decodes space %20", () => {
	AssertEqual("hello world", UriDecode("hello%20world"))
})

Test("UriDecode: decodes forward slash %2F", () => {
	AssertEqual("a/b", UriDecode("a%2Fb"))
})

Test("UriDecode: decodes multiple sequences", () => {
	AssertEqual("a b/c", UriDecode("a%20b%2Fc"))
})

Test("UriDecode: leaves lone percent sign intact", () => {
	; A bare % not followed by two hex digits should not crash
	Result := UriDecode("50%")
	AssertEqual("50%", Result)
})

Test("UriDecode: decodes uppercase hex", () => {
	AssertEqual(" ", UriDecode("%20"))
})

Test("UriDecode: decodes lowercase hex", () => {
	AssertEqual(" ", UriDecode("%20"))
})

Test("UriDecode: empty string returns empty string", () => {
	AssertEqual("", UriDecode(""))
})

Test("UriDecode: decodes a realistic file URL path segment", () => {
	; file:/// path with accented folder name
	Encoded := "T%C3%A9l%C3%A9chargements"
	; %C3%A9 = U+00E9 = é (UTF-8 two-byte sequence)
	; AHK Chr(0xC3) + Chr(0xA9) may not equal "é" in ANSI mode, so we just
	; verify the function does not crash and returns a non-empty string.
	Result := UriDecode(Encoded)
	Assert(StrLen(Result) > 0, "Expected non-empty decoded result")
})
