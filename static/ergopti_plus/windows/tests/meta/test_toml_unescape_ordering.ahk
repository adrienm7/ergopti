; tests/meta/test_toml_unescape_ordering.ahk

; ==============================================================================
; MODULE: TOML Unescape Ordering Guard
; DESCRIPTION:
; Static source guard for the _WS_UnescapeToml ordering fix in
; lib/wrap_symbols_config.ahk.
;
; ROOT CAUSE ENCODED:
; If _WS_UnescapeToml replaced \" before \\, the sequence \\" would first have
; \" consumed (yielding \") and then \\ could no longer fire, producing a wrong
; result (a literal backslash before a quote instead of just a quote). The fix
; ensures \\ is replaced FIRST so that \\\" correctly becomes \" (backslash +
; quote). This test verifies the ordering by checking that the StrReplace("\\")
; call appears in the source BEFORE the StrReplace("\" . Chr(0x22)) call inside
; the _WS_UnescapeToml function body.
; ==============================================================================

#Requires AutoHotkey v2.0

_TTUO_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}


; ======================================================
; ======================================================
; ======= 1/ _WS_UnescapeToml ordering check ===========
; ======================================================
; ======================================================

_TTUO_UnescapeOrderingCheck() {
	Src := _TTUO_ReadSource("lib/wrap_symbols_config.ahk")
	Assert(Src != "", "lib/wrap_symbols_config.ahk must be readable")

	; Locate the function body
	FuncStart := InStr(Src, "_WS_UnescapeToml(")
	Assert(FuncStart > 0, "_WS_UnescapeToml must be defined in lib/wrap_symbols_config.ahk")

	; Extract a window large enough to cover the two-line body (500 chars is ample)
	Snippet := SubStr(Src, FuncStart, 500)

	; Both replacements must be present in the function
	BackslashPos := InStr(Snippet, "StrReplace(S, " . Chr(0x22) . "\\" . Chr(0x22))
	Assert(BackslashPos > 0,
		'_WS_UnescapeToml must replace \\ with \ (StrReplace for double-backslash not found)')

	QuotePos := InStr(Snippet, "StrReplace(S, " . Chr(0x22) . "\" . Chr(0x22) . " . Chr(0x22)")
	Assert(QuotePos > 0,
		'_WS_UnescapeToml must replace \" with " (StrReplace for backslash-quote not found)')

	; Critical: the \\ replacement must come BEFORE the \" replacement
	Assert(BackslashPos < QuotePos,
		'_WS_UnescapeToml must replace \\ BEFORE \" — wrong order corrupts \\" sequences')
}
Test('wrap_symbols_config: _WS_UnescapeToml replaces \\ before \" (unescape ordering)', _TTUO_UnescapeOrderingCheck)
