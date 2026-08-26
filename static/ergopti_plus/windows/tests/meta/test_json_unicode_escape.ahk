; tests/meta/test_json_unicode_escape.ahk

; ==============================================================================
; MODULE: JSON String Validation Tests
; DESCRIPTION:
; Behavioural coverage for raw controls and strict UTF-16 surrogate escapes.
; ==============================================================================

#Requires AutoHotkey v2.0

_TJU_RawControlsThrow() {
	Loop 31 {
		Control := Chr(A_Index)
		AssertThrows(() => JsonParse('"before' . Control . 'after"'),
			"raw JSON control U+" . Format("{:04X}", A_Index) . " must throw")
	}
}
Test("JSON parser: raw string controls are rejected (json-string-controls)",
	_TJU_RawControlsThrow)

_TJU_ValidSurrogatePairDecodes() {
	AssertEqual(Chr(0x1F600), JsonParse('"\uD83D\uDE00"'),
		"a valid UTF-16 surrogate pair must decode to its scalar value")
}
Test("JSON parser: valid surrogate pairs decode (json-string-controls)",
	_TJU_ValidSurrogatePairDecodes)

_TJU_IsolatedSurrogatesThrow() {
	AssertThrows(() => JsonParse('"\uD83D"'),
		"an isolated high surrogate must throw")
	AssertThrows(() => JsonParse('"\uD83D\u0041"'),
		"a high surrogate followed by a non-low escape must throw")
	AssertThrows(() => JsonParse('"\uDE00"'),
		"an isolated low surrogate must throw")
}
Test("JSON parser: isolated surrogate halves are rejected (json-string-controls)",
	_TJU_IsolatedSurrogatesThrow)
