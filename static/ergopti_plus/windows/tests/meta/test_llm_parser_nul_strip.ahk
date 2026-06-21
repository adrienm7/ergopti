; tests/meta/test_llm_parser_nul_strip.ahk

; ==============================================================================
; MODULE: LLM Parser CleanModelOutput NUL Strip Guard
; DESCRIPTION:
; Static source guard for the _LLM_Parser_CleanModelOutput NUL-byte strip fix
; in modules/llm/parser.ahk.
;
; ROOT CAUSE ENCODED:
; Some models occasionally embed NUL bytes (0x00) or other non-printable ASCII
; control characters in their output. These characters pass through AHK string
; handling but corrupt downstream text injection — a NUL byte mid-string
; terminates the string in many Win32 calls, and other control chars (0x01-0x08,
; 0x0B, 0x0C, 0x0E-0x1F) cause undefined behaviour in text fields. The fix
; adds a RegExReplace pass at the end of _LLM_Parser_CleanModelOutput that
; strips all control characters in the ranges [\x00-\x08\x0B\x0C\x0E-\x1F],
; explicitly preserving \t (0x09), \n (0x0A), and \r (0x0D) which are valid.
; ==============================================================================

#Requires AutoHotkey v2.0

_TLPNS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TLPNS_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; ====================================================================
; ====================================================================
; ======= 1/ _LLM_Parser_CleanModelOutput strips control chars =======
; ====================================================================
; ====================================================================

_TLPNS_ControlCharStrip() {
	Src := _TLPNS_StripLineComments(_TLPNS_ReadSource("modules/llm/parser.ahk"))
	Assert(Src != "", "modules/llm/parser.ahk must be readable")

	Body := _DriverFuncBody("_LLM_Parser_CleanModelOutput")
	Assert(Body != "", "_LLM_Parser_CleanModelOutput must be defined in modules/llm/parser.ahk")

	; The NUL-and-control-char strip regex must be present
	Assert(InStr(Body, "[\x00-\x08\x0B\x0C\x0E-\x1F]") > 0,
		"_LLM_Parser_CleanModelOutput must use RegExReplace to strip [\x00-\x08\x0B\x0C\x0E-\x1F] control characters")

	; Must use RegExReplace (not a simple StrReplace)
	Assert(InStr(Body, "RegExReplace(out") > 0,
		"_LLM_Parser_CleanModelOutput must use RegExReplace to strip NUL and control bytes")
}
Test("llm/parser: _LLM_Parser_CleanModelOutput strips NUL and control chars via RegExReplace", _TLPNS_ControlCharStrip)
