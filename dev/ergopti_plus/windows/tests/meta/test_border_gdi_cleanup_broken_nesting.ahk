; tests/meta/test_border_gdi_cleanup_broken_nesting.ahk

; ==============================================================================
; MODULE: Border GDI Cleanup Nesting Meta Test
; DESCRIPTION:
; Static source guard for the border-gdi-cleanup-broken-nesting finding.
;
; _TooltipBuildBorder allocates a DIB section (HBmp) and a memory DC (MemDC).
; When either allocation fails it must release whichever handle DID succeed and
; then bail out. The original code expressed this as a statement-without-braces
; chain ("if HBmp X; if MemDC Y; return"), which AHK v2 reads as the DeleteDC
; and the return being conditional on HBmp -- so on the failure path the
; surviving MemDC leaked and the function pressed on with a null bitmap. Because
; the border is destroyed and recreated on EVERY tooltip show, this leaked a DC
; per show under GDI object pressure.
;
; The current fix publishes both allocations directly into one receipt before
; the failure branch returns. A function-level finally releases that receipt,
; while injected behavioral tests cover partial and refused native cleanup.
; This meta test keeps the production wiring attached to that tested owner.
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
	Build := _DriverFuncBody("_TooltipBuildBorder")
	Assert(InStr(Build, 'GdiReceipt["bitmap"] := DllCall') > 0
		and InStr(Build, 'GdiReceipt["memory_dc"] := DllCall') > 0,
		"both partial handles must publish directly into the finally-owned receipt")
	Assert(!InStr(Block, "DeleteObject") and !InStr(Block, "DeleteDC"),
		"the allocation-failure branch must not bypass the shared GDI owner")

	; The return must be UNCONDITIONAL (its own statement), so the function always
	; bails on failure instead of falling through to operate on a null bitmap. The
	; broken original chained it onto a single-line if-HBmp-DllCall statement.
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





_BGCN_ExceptionalCleanupUsesOneRetainedOwner() {
	Release := _DriverFuncBody("_TooltipBorderGdiRelease")
	Assert(Release != "" and InStr(Release, "SelectObject") > 0,
		"tooltip border cleanup must restore selected GDI objects through one owner")
	Build := _DriverFuncBody("_TooltipBuildBorder")
	Assert(Build != "" and InStr(Build, "finally") > 0
		and InStr(Build, "_TooltipBorderGdiRelease") > 0,
		"every exceptional border build exit must release its partial GDI receipt")
	Assert(InStr(Build, "_TooltipBorderGdiCleanupDebt") > 0,
		"a refused native release must remain owned for a later bounded retry")
}
Test("tooltip: border exceptions retain complete GDI ownership (tooltip-border-exception-ownership)",
	_BGCN_ExceptionalCleanupUsesOneRetainedOwner)
