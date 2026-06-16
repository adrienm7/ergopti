; tests/meta/test_toml_multiline_array_depth.ahk

; ==============================================================================
; MODULE: TOML Multi-Line Array Bracket-Depth Guard
; DESCRIPTION:
; Static source guard for the multi-line TOML array terminator fix in
; lib/toml/toml_helpers.ahk.
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

_TTMAD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TTMAD_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; ===================================================================
; ===================================================================
; ======= 1/ Bracket depth counter in multi-line array parser =======
; ===================================================================
; ===================================================================

_TTMAD_BracketDepthCounter() {
	Src := _TTMAD_StripLineComments(_TTMAD_ReadSource("lib/toml/toml_helpers.ahk"))
	Assert(Src != "", "lib/toml/toml_helpers.ahk must be readable")

	; The Depth variable must exist — it is the bracket-depth counter
	Assert(InStr(Src, "Depth") > 0,
		"toml_helpers.ahk must use a Depth counter for multi-line array bracket tracking")

	; Depth must be incremented when an opening bracket is found
	Assert(InStr(Src, "Depth++") > 0,
		"toml_helpers.ahk must increment Depth on unquoted '[' (bracket-depth counter)")

	; Depth must be decremented when a closing bracket is found
	Assert(InStr(Src, "Depth--") > 0,
		"toml_helpers.ahk must decrement Depth on unquoted ']' (bracket-depth counter)")

	; Termination condition must be depth-based, not naive InStr
	Assert(InStr(Src, "Depth <= 0") > 0,
		'toml_helpers.ahk must terminate the multi-line array accumulation when Depth <= 0, not via naive InStr(Line, "]")')

	; Quote-state flag (InStr2) must be present to skip ] inside strings
	Assert(InStr(Src, "InStr2") > 0,
		"toml_helpers.ahk must track quote state (InStr2) so ] inside quoted strings does not close the array prematurely")
}
Test("toml_helpers: multi-line array uses bracket-depth counter with quote-state tracking", _TTMAD_BracketDepthCounter)
