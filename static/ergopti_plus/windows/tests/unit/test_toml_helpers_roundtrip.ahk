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


_TTHRT_IntegerBounds() {
	Cases := [
		["9223372036854775807", 9223372036854775807],
		["-9223372036854775808", -9223372036854775808]
	]
	for Boundary in Cases {
		AssertEqual(Boundary[2], TOML_CoerceValue(Boundary[1]),
			"shared coercer must preserve an in-range boundary")
		AssertEqual(Boundary[2], TomlCoerceValue(Boundary[1]),
			"config coercer must preserve an in-range boundary")
	}
}
Test("toml integer coercion: signed 64-bit boundaries are exact", _TTHRT_IntegerBounds)


_TTHRT_IntegerOverflowRemainsInvalid() {
	for Raw in [
		"9223372036854775808",
		"-9223372036854775809",
		"18446744073709551616",
		"18446744073709552116"
	] {
		SharedValue := TOML_CoerceValue(Raw)
		ConfigValue := TomlCoerceValue(Raw)
		AssertTrue(SharedValue is String,
			"shared coercer must not wrap out-of-range integer " . Raw)
		AssertEqual(Raw, SharedValue,
			"shared coercer must preserve invalid integer lexeme " . Raw)
		AssertTrue(ConfigValue is String,
			"config coercer must not wrap out-of-range integer " . Raw)
		AssertEqual(Raw, ConfigValue,
			"config coercer must preserve invalid integer lexeme " . Raw)
	}
}
Test("toml integer coercion: overflow cannot alias a valid value",
	_TTHRT_IntegerOverflowRemainsInvalid)


_TTHRT_FloatOverflowRemainsInvalid() {
	Overflow := "1"
	Loop 309
		Overflow .= "0"
	Overflow .= ".0"
	for Raw in [Overflow, "-" . Overflow] {
		SharedValue := TOML_CoerceValue(Raw)
		ConfigValue := TomlCoerceValue(Raw)
		AssertTrue(SharedValue is String,
			"shared coercer must not publish non-finite float " . SubStr(Raw, 1, 8))
		AssertEqual(Raw, SharedValue,
			"shared coercer must preserve overflowing float lexeme")
		AssertTrue(ConfigValue is String,
			"config coercer must not publish non-finite float " . SubStr(Raw, 1, 8))
		AssertEqual(Raw, ConfigValue,
			"config coercer must preserve overflowing float lexeme")
		ExpectedType := ""
		AssertFalse(TomlConfigValueMatchesManifest(
			"hotstrings.autocorrection.accents", "time_activation_seconds",
			ConfigValue, &ExpectedType),
			"manifest boundary must reject an overflowing float lexeme")
	}
	AssertEqual(1.5, TOML_CoerceValue("1.5"),
		"shared coercer must retain ordinary finite floats")
	AssertEqual(-1.5, TomlCoerceValue("-1.5"),
		"config coercer must retain ordinary finite floats")
}
Test("toml float coercion: overflow cannot publish infinity",
	_TTHRT_FloatOverflowRemainsInvalid)

_TTHRT_NumberBoundaryRejectsBothOverflowClasses() {
	IntegerOverflow := "18446744073709552116"
	FloatOverflow := "1"
	Loop 309
		FloatOverflow .= "0"
	FloatOverflow .= ".0"
	AssertFalse(TOML_TryParseNumber(IntegerOverflow, &Parsed),
		"combined numeric boundary must reject an overflowing integer")
	AssertEqual(IntegerOverflow, CS_CoerceValue(IntegerOverflow),
		"metrics TOML reader must preserve an overflowing integer lexeme")
	AssertFalse(TOML_TryParseNumber(FloatOverflow, &Parsed),
		"combined numeric boundary must reject a non-finite float")
	AssertTrue(TOML_TryParseNumber("42", &Parsed))
	AssertEqual(42, Parsed)
	AssertTrue(TOML_TryParseNumber("0.75", &Parsed))
	AssertEqual(0.75, Parsed)
}
Test("toml numeric boundary: integers and floats share overflow rejection",
	_TTHRT_NumberBoundaryRejectsBothOverflowClasses)
