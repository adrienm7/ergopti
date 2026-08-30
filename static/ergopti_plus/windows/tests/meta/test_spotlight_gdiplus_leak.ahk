; tests/meta/test_spotlight_gdiplus_leak.ahk

; ==============================================================================
; MODULE: Spotlight GDI+ Leak Meta Test
; DESCRIPTION:
; Static source guard for the "spotlight-gdiplus-token-leak-on-error" finding.
; SpotlightMouseAt must reserve one session owner before allocation and settle
; its exact receipt on every startup or publication failure.
; ==============================================================================

#Requires AutoHotkey v2.0

_SGL_SpotlightHasSessionTransaction() {
	; Move-resilient: scan by function name, not a pinned ui/spotlight path.
	Seg := _DriverFuncBody("SpotlightMouseAt")
	Assert(Seg != "", "SpotlightMouseAt declaration must exist")
	Assert(InStr(Seg, "_SpotlightClaimStart") > 0,
		"SpotlightMouseAt must reserve its builder before native allocation")
	Assert(InStr(Seg, "_SpotlightSessionAcquireGdi") > 0
		and InStr(Seg, "_SpotlightPublishStart") > 0,
		"SpotlightMouseAt must acquire and publish one exact session receipt")
	Assert(InStr(Seg, "_SpotlightSessionSettle(Receipt)") > 0
		and InStr(Seg, "_SpotlightAbandonStart") > 0,
		"failed Spotlight startup must settle its local receipt before releasing the reservation")
	Release := _DriverFuncBody("_SpotlightSessionRelease")
	Assert(InStr(Release, "Native.Shutdown") > 0
		and InStr(Release, "Native.FreeModule") > 0,
		"the session receipt must pair GDI+ startup and module load in reverse")
}
Test("spotlight: startup is one exact ownership transaction (spotlight-session-transaction)",
	_SGL_SpotlightHasSessionTransaction)





_SGL_PartialWindowAcquisitionHasAnOwner() {
	Acquire := _DriverFuncBody("_SpotlightCreateOverlayWindow")
	Assert(Acquire != "",
		"Spotlight must expose one testable owner for create/draw/show acquisition")
	Assert(InStr(Acquire, "finally") > 0
		and InStr(Acquire, "ResolvedDestroy.Call(Hwnd)") > 0,
		"a window whose draw or show step fails must be destroyed before ownership is lost")

	Paint := _DriverFuncBody("_SpotlightDrawWithGdiPlus")
	Assert(Paint != "", "Spotlight must expose one owner for its GDI+ Graphics context")
	Assert(InStr(Paint, "finally") > 0
		and InStr(Paint, "Native.DeleteGraphics(pGfx)") > 0,
		"the GDI+ Graphics context must be deleted when the caller's paint callback throws")
}
Test("spotlight: partial overlay acquisition retains cleanup ownership",
	_SGL_PartialWindowAcquisitionHasAnOwner)





_SGL_PerPaintBrushesAndPensHaveAnOwner() {
	Release := _DriverFuncBody("_SpotlightPaintRelease")
	Assert(Release != "" and InStr(Release, "DeleteBrush") > 0
		and InStr(Release, "DeletePen") > 0,
		"Spotlight brush and pen handles must share one testable cleanup receipt")
	Circle := _DriverFuncBody("_SpotlightDrawCircleResources")
	Cross := _DriverFuncBody("_SpotlightDrawCrossResources")
	Assert(Circle != "" and Cross != "",
		"both Spotlight shapes must draw through receipt-owned resource helpers")
	Assert(InStr(Circle, "_SpotlightPaintRun") > 0
		and InStr(Cross, "_SpotlightPaintRun") > 0,
		"every shape exit must settle partial GDI+ paint ownership")
	RunPaint := _DriverFuncBody("_SpotlightPaintRun")
	Assert(InStr(RunPaint, "_SpotlightPaintSettle") > 0,
		"the shared shape runner must retain refused cleanup debt")
}
Test("spotlight: every brush and pen is exception-owned (spotlight-paint-resource-ownership)",
	_SGL_PerPaintBrushesAndPensHaveAnOwner)
