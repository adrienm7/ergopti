; tests/meta/test_toml_multiline_array_depth.ahk

; ==============================================================================
; MODULE: TOML Multi-Line Array Bracket-Depth Guard
; DESCRIPTION:
; Behavioral guard for the multi-line TOML array terminator fix.
;
; ROOT CAUSE ENCODED:
; The original multi-line array parser used a naive InStr(Line, "]") check to
; detect the closing bracket, so any nested array value or a quoted string
; containing "]" would prematurely terminate the accumulation. The fix replaces
; this with a bracket-depth counter that also tracks quote state, so only an
; unquoted "]" that brings the depth back to zero closes the array.
;
; Parser results cover quoted brackets together with nested arrays,
; independent of the scanner's local variable names and implementation.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================================
; ===================================================================
; ======= 1/ Bracket depth counter in multi-line array parser =======
; ===================================================================
; ===================================================================

_TTMAD_OpeningLineIgnoresQuotedClosingBracket() {
	Path := A_Temp . "\ergopti-toml-multiline-opener-" . A_ScriptHwnd . ".toml"
	try {
		try FileDelete(Path)
		FileAppend(
			'[sample]`nitems = ["x]y",`n  "second"`n]`nafter = "kept"`n',
			Path, "UTF-8")
		Parsed := ParseTomlFile(Path)
		AssertTrue(Parsed["sample"]["items"] is Array,
			"a quoted ] on the opening line must not turn the array into raw text")
		AssertEqual(2, Parsed["sample"]["items"].Length)
		AssertEqual("x]y", Parsed["sample"]["items"][1])
		AssertEqual("second", Parsed["sample"]["items"][2])
		AssertEqual("kept", Parsed["sample"]["after"],
			"parsing the multiline array must preserve following keys")
	} finally {
		global _ParseTomlCache
		if _ParseTomlCache.Has(Path)
			_ParseTomlCache.Delete(Path)
		try FileDelete(Path)
	}
}
Test("toml_helpers: quoted closing bracket on array opener stays multiline",
	_TTMAD_OpeningLineIgnoresQuotedClosingBracket)

_TTMAD_BracketDepthCounter() {
	Source := '[sample]`nitems = [`n["quoted]value", [1, 2]]`n]`nafter = "kept"`n'
	Parsed := _ParseTomlFileImpl("nested-quoted-bracket-fixture", false, false, Source)
	AssertEqual(1, Parsed["sample"]["items"].Length)
	Nested := Parsed["sample"]["items"][1]
	AssertEqual(2, Nested.Length)
	AssertEqual("quoted]value", Nested[1])
	AssertEqual(2, Nested[2].Length)
	AssertEqual(1, Nested[2][1])
	AssertEqual(2, Nested[2][2])
	AssertEqual("kept", Parsed["sample"]["after"])
}
Test("toml_helpers: multi-line array uses bracket-depth counter with quote-state tracking", _TTMAD_BracketDepthCounter)
