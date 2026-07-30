; tests/meta/test_border_gdi_cleanup_broken_nesting.ahk

; ==============================================================================
; MODULE: Border GDI Cleanup Nesting Meta Test
; DESCRIPTION:
; Static source guard for the border-gdi-cleanup-broken-nesting finding.
;
; _TooltipShowBorder allocates a DIB section (HBmp) and a memory DC (MemDC).
; When either allocation fails it must release whichever handle DID succeed and
; then bail out. The original code expressed this as a statement-without-braces
; chain ("if HBmp X; if MemDC Y; return"), which AHK v2 reads as the DeleteDC
; and the return being conditional on HBmp -- so on the failure path the
; surviving MemDC leaked and the function pressed on with a null bitmap. Because
; the border is destroyed and recreated on EVERY tooltip show, this leaked a DC
; per show under GDI object pressure.
;
; The fix wraps the cleanup in explicit braces with parenthesized single guards
; and an UNCONDITIONAL return. This is a meta-static test (scans source text)
; because the function issues real GDI DllCalls and cannot run headless. If the
; broken single-line chain is reintroduced, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Returns the brace block starting at the given header line, from the header up
; to and including the first closing brace at the source's 4-space function-body
; indentation. Returns "" when the header is absent.
_BGCN_BlockAt(Src, Header) {
	Idx := InStr(Src, Header)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n    }")
	if End
		return SubStr(Rest, 1, End + 5)
	return Rest
}


; ==================================================
; ==================================================
; ======= 2/ Cleanup-nesting assertions ============
; ==================================================
; ==================================================

_BGCN_CleanupReleasesBothAndReturns() {
	Src := _DriverDirConcat("ui/tooltip")
	Block := _BGCN_BlockAt(Src, "if (!HBmp or !MemDC) {")
	Assert(Block != "", "the ui/tooltip module must contain the !HBmp-or-!MemDC GDI-failure block")

	; Both handles must be released through parenthesized single-line guards so
	; the surviving handle is never leaked on a partial-allocation failure.
	Assert(InStr(Block, "if (HBmp)") > 0,
		"GDI-failure cleanup must guard the bitmap delete with an if (HBmp) statement")
	Assert(InStr(Block, "if (MemDC)") > 0,
		"GDI-failure cleanup must guard the DC delete with an if (MemDC) statement")

	; The return must be UNCONDITIONAL (its own statement), so the function always
	; bails on failure instead of falling through to operate on a null bitmap. The
	; broken original chained it onto a single-line if-HBmp-DllCall statement.
	BrokenChain := InStr(Block, "if HBmp DllCall") > 0
		or InStr(Block, "if MemDC DllCall") > 0
	Assert(!BrokenChain,
		"GDI-failure cleanup must NOT use the single-line if-HBmp-DllCall chain -- it makes the DeleteDC and return conditional on HBmp, leaking the surviving MemDC")
	; A `return` that is the ENTIRE statement on its line is unconditional; one
	; chained after an `if` on the same line is not, and that chaining is the
	; regression above. Matching the statement shape rather than a literal eight
	; spaces is what the invariant actually needs — the old form pinned the
	; driver's indentation, so re-indenting it to the project's tab convention
	; turned a correct file into a red test.
	Assert(RegExMatch(Block, "m)^[ \t]*return[ \t]*$") > 0,
		"GDI-failure cleanup must contain an unconditional return — a return that is its own statement, not one chained after an if — so it always bails on a failed GDI allocation")
}
Test("tooltip: _TooltipShowBorder GDI-failure cleanup releases both handles and returns (border-gdi-cleanup-broken-nesting)", _BGCN_CleanupReleasesBothAndReturns)
