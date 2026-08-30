; tests/meta/test_spotlight_gdiplus_leak.ahk

; ==============================================================================
; MODULE: Spotlight GDI+ Leak Meta Test
; DESCRIPTION:
; Static source guard for the "spotlight-gdiplus-token-leak-on-error" finding.
; SpotlightMouseAt must wrap its window creation in a try/catch block to ensure
; the GDI+ token and handles are not leaked if an error is thrown.
; ==============================================================================

#Requires AutoHotkey v2.0

_SGL_SpotlightHasTryCatch() {
	; Move-resilient: scan by function name, not a pinned ui/spotlight path.
	Seg := _DriverFuncBody("SpotlightMouseAt")
	Assert(Seg != "", "SpotlightMouseAt declaration must exist")
	
	Assert(InStr(Seg, "try {") > 0,
		"SpotlightMouseAt must wrap window creation in a try block (spotlight-gdiplus-token-leak-on-error)")
		
	Assert(InStr(Seg, "catch as Err {") > 0,
		"SpotlightMouseAt must catch errors to cleanup GDI+ token")
		
	Assert(InStr(Seg, "GdiplusShutdown") > 0,
		"SpotlightMouseAt must call GdiplusShutdown in the catch block")
}
Test("spotlight: SpotlightMouseAt has try/catch to prevent GDI+ token leak", _SGL_SpotlightHasTryCatch)





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
