; tests/meta/test_toml_unescape_ordering.ahk

; ==============================================================================
; MODULE: TOML Unescape Ordering Guard
; DESCRIPTION:
; Static source guard for the _WS_UnescapeToml ordering fix in
; infra/wrap_symbols_config.ahk.
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

; ======================================================
; ======================================================
; ======= 1/ _WS_UnescapeToml ordering check ===========
; ======================================================
; ======================================================

_TTUO_UnescapeOrderingCheck() {
	; Move-resilient: extract _WS_UnescapeToml()'s body by name via the framework
	; helper instead of a pinned infra/wrap_symbols_config.ahk read. The helper anchors
	; on the DEFINITION, so the earlier call site no longer confuses the extraction.
	Snippet := _DriverFuncBody("_WS_UnescapeToml")
	Assert(Snippet != "", "_WS_UnescapeToml must be defined in infra/wrap_symbols_config.ahk")

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
