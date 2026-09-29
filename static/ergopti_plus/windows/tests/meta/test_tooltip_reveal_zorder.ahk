; tests/meta/test_tooltip_reveal_zorder.ahk

; ==============================================================================
; MODULE: Tooltip Reveal Z-Order Meta Test
; DESCRIPTION:
; Source guard for the tooltip-border-zorder finding. The layered border ring is
; a second top-level window that must stack above the opaque content Gui.
; ShowWindow with a show command never places a window in the z-order: it reveals
; the window in the slot it already holds. A pooled border is older than the
; content it is reused for, so revealing it that way left the ring underneath the
; content, visible only through the rounded-region corners.
;
; The behavioural twin (unit/test_tooltip_border_zorder.ahk) proves the stacking
; with real windows; this guard keeps the whole class closed: no tooltip surface
; may be revealed by ShowWindow or GR_Show, and the one reveal routine must place
; the content before the border through the explicit SetWindowPos seam.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================
; ================================================
; ======= 1/ Reveal ordering source guards =======
; ================================================
; ================================================

_TRZ_RevealPlacesBorderAfterContent() {
	Body := _DriverFuncBody("_TooltipRevealPreparedSurfaces")
	Assert(Body != "", "the tooltip reveal routine must remain discoverable")
	Assert(InStr(Body, "ShowWindow") == 0 and InStr(Body, "GR_Show(") == 0,
		"the reveal must not rely on ShowWindow, which keeps the stale z-order slot")
	ContentTop := InStr(Body, "Native.ShowOnTop(ContentHwnd)")
	BorderTop := InStr(Body, "Native.ShowOnTop(Surface.Border.Hwnd)")
	Assert(ContentTop > 0 and BorderTop > ContentTop,
		"the content must be placed first and the border raised last, directly above it")
}
Test("tooltip: reveal raises the border above the content (tooltip-border-zorder)",
	_TRZ_RevealPlacesBorderAfterContent)

_TRZ_NoTooltipSurfaceBypassesTheReveal() {
	Src := _StripFullLineComments(_DriverDirConcat("ui/tooltip"))
	Assert(Src != "", "the ui/tooltip sources must be readable for the reveal guard")
	Assert(InStr(Src, "User32\SetWindowPos") > 0,
		"the tooltip module must still contain its native placement calls")
	Assert(InStr(Src, "GR_Show(") == 0,
		"no tooltip surface may be revealed with GR_Show, which keeps its z-order slot")
	Assert(!RegExMatch(Src, 'ShowWindow",\s*"Ptr",\s*[^,]+,\s*"Int",\s*[1-9]'),
		"tooltip ShowWindow calls may only hide; every reveal goes through the ordered seam")
	Assert(RegExMatch(Src, 'SetWindowPos",\s*"Ptr",\s*Hwnd,\s*"Ptr",\s*this\.InsertAfter') > 0,
		"the reveal seam must pass its explicit insert-after window to SetWindowPos")
}
Test("tooltip: no surface is revealed outside the ordered seam (tooltip-border-zorder)",
	_TRZ_NoTooltipSurfaceBypassesTheReveal)
