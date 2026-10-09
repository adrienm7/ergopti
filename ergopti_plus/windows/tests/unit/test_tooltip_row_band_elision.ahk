; tests/unit/test_tooltip_row_band_elision.ahk

; ==============================================================================
; MODULE: Tooltip row background-band elision
; DESCRIPTION:
; _TooltipBuildGui sets the Gui BackColor to _TooltipMixTintHex(Items[1].ColorHex)
; and then, for EVERY row, added a full-width Text control painted with
; _TooltipMixTintHex(row.ColorHex). For row 1 that is the same pure function over
; the same input, and the band spans a strict sub-rectangle of the client area the
; BackColor brush already fills — a provably pixel-identical repaint costing one
; CreateWindowEx plus one SetFont. Roughly 97 % of renders are single-row, so the
; waste was paid on almost every preview.
;
; ROOT CAUSE ENCODED: the band was written as an unconditional per-row primitive.
; It is only ever needed when the row's tint DIFFERS from the surface underneath.
;
; SCOPE: behavioural for the predicate (pure, no GDI), plus a source guard that
; _TooltipBuildGui actually consults it — a correct predicate nobody calls fixes
; nothing. _TooltipBuildGui itself creates real windows and cannot run headlessly.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================================
; ================================================================
; ======= 1/ The predicate ======================================
; ================================================================
; ================================================================

_TRBE_IdenticalTintNeedsNoBand() {
	AssertFalse(_TooltipRowNeedsBand("202124", "202124"),
		"a row whose tint already equals the Gui background must not get a band — the control repaints pixels that are already correct, for one CreateWindowEx and one SetFont per render")
	AssertFalse(_TooltipRowNeedsBand("3A2140", "3A2140"),
		"the elision must hold for any colour, not just the default background")
}

_TRBE_DistinctTintKeepsItsBand() {
	AssertTrue(_TooltipRowNeedsBand("3A2140", "202124"),
		"a row carrying its own tint must still get its band, or a multi-category stack loses its per-row colour and every row reads as the first row's group")
	AssertTrue(_TooltipRowNeedsBand("202124", "3A2140"),
		"the comparison must be symmetric — the reference is the Gui background, whichever colour that happens to be")
}





; ================================================================
; ================================================================
; ======= 2/ The builder consults it ============================
; ================================================================
; ================================================================

_TRBE_BuilderUsesThePredicate() {
	Body := _DriverFuncBody("_TooltipBuildGui")
	Assert(Body != "", "_TooltipBuildGui() must exist in the driver source")
	Assert(InStr(Body, "_TooltipRowNeedsBand") > 0,
		"_TooltipBuildGui must gate the per-row background band on _TooltipRowNeedsBand — an unconditional band repaints the Gui background colour on the ~97 % of renders that are single-row")
	Assert(InStr(Body, "_TOOLTIP_SEP_COLOR_HEX") > 0,
		"the 1 px inter-row separator is a DIFFERENT colour from every row band and must never be elided along with them")
}


Test("tooltip band elision: a row matching the Gui background needs no band",
	_TRBE_IdenticalTintNeedsNoBand)
Test("tooltip band elision: a row with its own tint keeps its band",
	_TRBE_DistinctTintKeepsItsBand)
Test("tooltip band elision: _TooltipBuildGui consults the predicate",
	_TRBE_BuilderUsesThePredicate)
