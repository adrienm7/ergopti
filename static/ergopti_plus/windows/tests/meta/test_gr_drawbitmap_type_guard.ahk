; tests/meta/test_gr_drawbitmap_type_guard.ahk

; ==============================================================================
; MODULE: GR_DrawBitmap Type-Guard Regression Test
; DESCRIPTION:
; Guards that GR_DrawBitmap uses a Type(DrawFn) == "Func" guard instead of a
; nested try/catch around the DrawFn call.
;
; WHY THIS MATTERS (the regression this encodes):
;   A nested try DrawFn / catch block was F46's original fix for preventing
;   an uncallable DrawFn from committing a blank bitmap to the layered window.
;   In AHK v2, even a never-triggered catch frame adds ~2 ms of exception-frame
;   setup overhead on every call. GR_DrawBitmap is called on every tooltip
;   render; at 30+ renders per second that is 60+ ms of wasted overhead per
;   second. The Type() guard is free on the fast path and correct: an actual
;   DrawFn exception propagates through the outer try/finally, which still
;   cleans up GDI resources and skips UpdateLayeredWindow.
;   Re-introducing the nested try/catch here would silently re-add the latency
;   that produced the "Tooltip.Present 15-61 ms" HotPath warnings in the log.
;
; SCOPE: source introspection of adapters/graphics_renderer.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckGrDrawBitmapTypeGuard() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	GrFile := WindowsDir . "\adapters\graphics_renderer.ahk"

	Body := ""
	try Body := FileRead(GrFile)
	Assert(Body != "", "adapters\graphics_renderer.ahk must be readable for the GR_DrawBitmap type-guard meta-test")

	; The file must use the Type() guard — not a nested try/catch on DrawFn.
	Assert(InStr(Body, 'Type(DrawFn) == "Func"'),
		"GR_DrawBitmap must guard DrawFn with a Type() == Func check instead of a nested try/catch")

	; The nested catch-after-DrawFn pattern must be absent — it was the source
	; of the per-render exception-frame overhead.
	Assert(!InStr(Body, "try DrawFn("),
		"GR_DrawBitmap must NOT use 'try DrawFn(...)' — replace with Type() guard (perf-gr-drawbitmap)")
	Assert(!InStr(Body, "catch as Err"),
		"GR_DrawBitmap must NOT have a 'catch as Err' block around DrawFn — replace with Type() guard (perf-gr-drawbitmap)")

	; The outer try/finally for GDI cleanup must still be present.
	Assert(InStr(Body, "} finally {"),
		"GR_DrawBitmap must still have an outer try/finally for GDI resource cleanup (perf-gr-drawbitmap)")
}

Test("meta perf: GR_DrawBitmap uses Type() guard instead of nested try/catch (perf-gr-drawbitmap)",
	_MetaCheckGrDrawBitmapTypeGuard)
