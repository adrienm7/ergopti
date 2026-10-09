; tests/meta/test_graphics_renderer_createwindow_catch.ahk

; ==============================================================================
; MODULE: GR_CreateWindow Try/Catch Meta Test
; DESCRIPTION:
; Regression guard: GR_CreateWindow had no try/catch around its two Win32
; DllCalls (CreateWindowEx, DwmSetWindowAttribute), unlike every sibling
; function in the same adapter (GR_DestroyWindow, GR_Show, GR_Hide all wrap
; theirs). A DllCall exception here (unlike an ordinary Win32 API failure,
; which CreateWindowEx already reports via a falsy return) would propagate
; uncaught out of the adapter.
;
; SCOPE: source introspection of adapters/graphics_renderer.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ Both DllCalls are wrapped in try =========
; =====================================================
; =====================================================

_GRCC_CheckBothDllCallsWrapped() {
	Body := _DriverFuncBody("GR_CreateWindow")
	Assert(Body != "", "GR_CreateWindow must exist in adapters/graphics_renderer.ahk")

	CreatePos := InStr(Body, 'DllCall("User32\CreateWindowEx"')
	Assert(CreatePos > 0, 'GR_CreateWindow must still call DllCall("User32\CreateWindowEx", ...)')

	; The nearest preceding non-whitespace token before the DllCall must be "try".
	Before := Trim(SubStr(Body, Max(1, CreatePos - 20), CreatePos - Max(1, CreatePos - 20)))
	Assert(InStr(Before, "try") > 0,
		"GR_CreateWindow's CreateWindowEx call must be wrapped in try, matching GR_DestroyWindow/GR_Show/GR_Hide in the same adapter")

	DwmPos := InStr(Body, 'DllCall("Dwmapi\DwmSetWindowAttribute"')
	Assert(DwmPos > 0, 'GR_CreateWindow must still call DllCall("Dwmapi\DwmSetWindowAttribute", ...)')

	DwmBefore := Trim(SubStr(Body, Max(1, DwmPos - 20), DwmPos - Max(1, DwmPos - 20)))
	Assert(InStr(DwmBefore, "try") > 0,
		"GR_CreateWindow's DwmSetWindowAttribute call must be wrapped in try, matching every sibling DllCall in this adapter")
}
Test("graphics_renderer: GR_CreateWindow wraps both DllCalls in try, matching its siblings (gr-createwindow-uncaught-dllcall)",
	_GRCC_CheckBothDllCallsWrapped)
