; static/ergopti_plus/windows/tests/unit/test_toml_helpers_roundtrip.ahk

; ==============================================================================
; MODULE: TOML Helpers Round-Trip Tests
; DESCRIPTION:
; Regression suite for TOML_Unescape in infra/toml/toml_helpers.ahk.
;
; ROOT CAUSE ENCODED:
; The original sequential-StrReplace implementation applied "\\" → "\" first,
; which left a bare backslash that the subsequent "\n" → newline pass would then
; mis-consume. "C:\\notes" became "C:\notes" after step 1, then "C:<NL>otes"
; after step 3. The fix replaces the multi-pass approach with a single
; left-to-right character scan so no produced backslash can be re-consumed by a
; later substitution.
; ==============================================================================





; =========================================================
; =========================================================
; ======= 1/ TOML_Unescape behavioral regression ==========
; =========================================================
; =========================================================

_TTHRT_BackslashNLiteral() {
	; The sequence backslash + letter-n written literally in a TOML value means
	; a literal backslash followed by the letter n — NOT a real newline.
	; Before the fix: \\ → \ first, then \n → newline turned "\n" into a real
	; newline even when the source had no escape sequence intended.
	; Note: in AHK v2 a lone \ inside a double-quoted string is a literal backslash.
	AssertEqual("\" . "n", TOML_Unescape("\" . "\n"), "literal backslash+n must not become newline")
}
Test("toml_helpers: TOML_Unescape literal backslash-n stays literal", _TTHRT_BackslashNLiteral)


_TTHRT_WindowsPath() {
	; "C:\\notes" is the TOML on-disk encoding of the value C:\notes.
	; Before the fix: \\ → \ gave C:\notes, then \n → newline gave "C:<NL>otes".
	AssertEqual("C:\notes", TOML_Unescape("C:\\notes"), "Windows path round-trip")
}
Test("toml_helpers: TOML_Unescape Windows path C:\\notes decodes correctly", _TTHRT_WindowsPath)


_TTHRT_RealNewline() {
	; The two-character sequence backslash + n inside a TOML string is the
	; standard escape for a real newline — it must decode to a real newline.
	AssertEqual("`n", TOML_Unescape("\n"), "escaped \n must become real newline")
}
Test("toml_helpers: TOML_Unescape \n -> real newline", _TTHRT_RealNewline)


_TTHRT_EscapedQuote() {
	; Backslash + double-quote is the TOML escape for a literal double-quote.
	AssertEqual(Chr(34), TOML_Unescape('\"'), "escaped quote must become real quote")
}
Test('toml_helpers: TOML_Unescape \" -> real quote', _TTHRT_EscapedQuote)


_TTHRT_EscapedTab() {
	AssertEqual("`t", TOML_Unescape("\t"), "escaped \t must become real tab")
}
Test("toml_helpers: TOML_Unescape \t -> real tab", _TTHRT_EscapedTab)


_TTHRT_EscapedCr() {
	AssertEqual("`r", TOML_Unescape("\r"), "escaped \r must become real CR")
}
Test("toml_helpers: TOML_Unescape \r -> real CR", _TTHRT_EscapedCr)


_TTHRT_DoubleBackslash() {
	; "\\" on disk (two backslashes in the TOML source) must decode to a single
	; backslash and nothing more — no further escape processing must occur.
	AssertEqual("\", TOML_Unescape("\\"), "double-backslash decodes to single backslash")
}
Test("toml_helpers: TOML_Unescape \\\\ -> single backslash", _TTHRT_DoubleBackslash)


_TTHRT_NoBackslash() {
	; Strings without any backslash must pass through unchanged.
	AssertEqual("hello world", TOML_Unescape("hello world"), "plain string passes through unchanged")
}
Test("toml_helpers: TOML_Unescape plain string is unchanged", _TTHRT_NoBackslash)


_TTHRT_ArraySplitEscapedBackslash() {
	; ["a\\", "b"] should yield two elements: "a\" and "b"
	; The old accumulator lookbehind saw "\" in cur before the closing quote
	; and wrongly kept in_str=true, merging the comma as part of the first element.
	Q := Chr(34)
	raw := "[" . Q . "a\\" . Q . ", " . Q . "b" . Q . "]"
	result := TOML_CoerceValue(raw)
	AssertEqual(2, result.Length, "TOML_CoerceValue: escaped backslash array must yield 2 elements")
	AssertEqual("a\", result[1], "TOML_CoerceValue: first element must be a backslash")
	AssertEqual("b", result[2], "TOML_CoerceValue: second element must be b")
}
Test("toml_helpers: TOML_CoerceValue splits array with escaped-backslash element correctly", _TTHRT_ArraySplitEscapedBackslash)


_TTHRT_HeterogeneousArray() {
	Result := TOML_CoerceValue('["a", 1, true]')
	AssertEqual("Array", Type(Result), "TOML mixed array must decode to an Array")
	AssertEqual(3, Result.Length, "TOML mixed array must preserve every value")
	AssertEqual("String", Type(Result[1]), "mixed array first value keeps its string type")
	AssertEqual("a", Result[1], "mixed array first value keeps its exact content")
	AssertEqual("Integer", Type(Result[2]), "mixed array second value keeps its integer type")
	AssertEqual(1, Result[2], "mixed array second value keeps its exact content")
	AssertEqual("Integer", Type(Result[3]), "TOML true uses the AHK boolean integer type")
	AssertEqual(true, Result[3], "mixed array third value keeps its true value")
}
Test("toml_helpers: TOML mixed arrays preserve every typed value", _TTHRT_HeterogeneousArray)
