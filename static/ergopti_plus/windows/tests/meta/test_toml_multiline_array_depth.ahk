; tests/meta/test_toml_multiline_array_depth.ahk

; ==============================================================================
; MODULE: TOML Multi-Line Array Bracket-Depth Guard
; DESCRIPTION:
; Static source guard for the multi-line TOML array terminator fix in
; infra/toml/toml_helpers.ahk.
;
; ROOT CAUSE ENCODED:
; The original multi-line array parser used a naive InStr(Line, "]") check to
; detect the closing bracket, so any nested array value or a quoted string
; containing "]" would prematurely terminate the accumulation. The fix replaces
; this with a bracket-depth counter that also tracks quote state, so only an
; unquoted "]" that brings the depth back to zero closes the array.
;
; Specific signatures checked:
;   - "Depth" variable declared inside the continuation block
;   - The depth counter is incremented on "[" and decremented on "]"
;   - The termination condition is (Depth <= 0) not a simple InStr(Line, "]")
;   - Quote-state tracking variable (InStr2) is present
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
	Helper := _DriverFuncBody("_TOML_ArrayBracketDepth")
	Parser := _DriverFuncBody("_ParseTomlFileImpl")
	Assert(Helper != "" && Parser != "",
		"the TOML bracket scanner and parser must both exist")

	; The Depth variable must exist — it is the bracket-depth counter
	Assert(InStr(Helper, "Depth") > 0,
		"toml_helpers.ahk must use a Depth counter for multi-line array bracket tracking")

	; Depth must be incremented when an opening bracket is found
	Assert(InStr(Helper, "Depth++") > 0,
		"toml_helpers.ahk must increment Depth on unquoted '[' (bracket-depth counter)")

	; Depth must be decremented when a closing bracket is found
	Assert(InStr(Helper, "Depth--") > 0,
		"toml_helpers.ahk must decrement Depth on unquoted ']' (bracket-depth counter)")

	; Termination condition must be depth-based, not naive InStr
	Assert(InStr(Parser, "Depth <= 0") > 0,
		'toml_helpers.ahk must terminate the multi-line array accumulation when Depth <= 0, not via naive InStr(Line, "]")')

	Assert(InStr(Helper, "InString") > 0 && InStr(Helper, "Escaped") > 0,
		"the bracket scanner must track quoted strings and escaped quotes")
	CallCount := 0
	Pos := 1
	while Found := InStr(Parser, "_TOML_ArrayBracketDepth(", , Pos) {
		CallCount += 1
		Pos := Found + 1
	}
	Assert(CallCount >= 2,
		"both the opening-line detector and continuation path must share the quote-aware scanner")
	Assert(InStr(Parser, '!InStr(val, "]")') == 0,
		"the opening-line detector must not use the old raw closing-bracket probe")
}
Test("toml_helpers: multi-line array uses bracket-depth counter with quote-state tracking", _TTMAD_BracketDepthCounter)
