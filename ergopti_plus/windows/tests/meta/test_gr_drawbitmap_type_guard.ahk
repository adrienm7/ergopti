; tests/meta/test_gr_drawbitmap_type_guard.ahk

; ==============================================================================
; MODULE: GR_DrawBitmap Callable-Guard Regression Test
; DESCRIPTION:
; Guards that GR_DrawBitmap uses a HasMethod(DrawFn, "Call") callable guard
; instead of a nested try/catch or the over-narrow Type()=="Func" string check.
;
; WHY THIS MATTERS (the two regressions this encodes):
;   1. PERF (perf-gr-drawbitmap): A nested try DrawFn / catch block was F46's
;      original fix. In AHK v2, even a never-triggered catch frame adds ~2 ms of
;      exception-frame overhead on every call. GR_DrawBitmap is called on every
;      tooltip render; at 30+ renders per second that is 60+ ms per second of
;      wasted overhead. The callable guard is free on the fast path; exceptions
;      propagate through the outer try/finally so GDI resources are always
;      released and UpdateLayeredWindow is never called on a partial bitmap.
;   2. CORRECTNESS (fix-gr-drawbitmap-closure): Type()=="Func" is false for any
;      nested function that captures an enclosing local — those are Closures, a
;      distinct AHK v2 subclass. Both real callers (spotlight.ahk, wpm_widget.ahk)
;      pass such closures, so the old guard silently suppressed every paint call
;      and UpdateLayeredWindow, leaving spotlight and WPM widget fully invisible.
;      HasMethod(DrawFn, "Call") is true for Func, Closure, and BoundFunc alike.
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
	PublicBody := _DriverFuncBody("GR_DrawBitmap")
	Body := _DriverFuncBody("_GRDrawBitmapRun")
	Assert(PublicBody != "" and Body != "",
		"the public adapter and its transaction owner must both be readable")
	Assert(InStr(PublicBody, "_GRDrawBitmapRun(Handle, DrawFn)"),
		"GR_DrawBitmap must delegate every non-zero frame to its tested owner")

	; The file must use HasMethod callable guard — not the narrow Type()=="Func" string.
	Assert(InStr(Body, 'HasMethod(DrawFn, "Call")'),
		'GR_DrawBitmap must guard DrawFn with HasMethod(DrawFn, "Call") to accept Closures and BoundFuncs')

	; The old Type()=="Func" guard is forbidden — it rejected all real callers (closures).
	Assert(!InStr(Body, 'Type(DrawFn) == "Func"'),
		'GR_DrawBitmap must NOT use Type(DrawFn) == "Func" — it rejects Closures (fix-gr-drawbitmap-closure)')

	; The nested catch-after-DrawFn pattern must be absent — it was the source
	; of the per-render exception-frame overhead.
	Assert(!InStr(Body, "try DrawFn("),
		"GR_DrawBitmap must NOT use try DrawFn(...) — replace with callable guard (perf-gr-drawbitmap)")
	Assert(!InStr(Body, "catch as Err"),
		"GR_DrawBitmap must NOT have a catch-as-Err block around DrawFn — replace with callable guard (perf-gr-drawbitmap)")

	; The outer try/finally must begin before any native allocation and settle one
	; receipt, including the pre-paint acquisition path.
	Assert(InStr(Body, "} finally {")
		and InStr(Body, "_GRBitmapSettle(Receipt, Native)"),
		"the native owner must settle the complete GDI receipt (perf-gr-drawbitmap)")
}

Test("meta perf+correctness: GR_DrawBitmap uses HasMethod callable guard (perf-gr-drawbitmap, fix-gr-drawbitmap-closure)",
	_MetaCheckGrDrawBitmapTypeGuard)
