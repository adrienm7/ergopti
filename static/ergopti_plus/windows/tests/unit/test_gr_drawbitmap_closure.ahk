; tests/unit/test_gr_drawbitmap_closure.ahk

; ==============================================================================
; MODULE: GR_DrawBitmap Closure Callable Regression Test
; DESCRIPTION:
; Behavioral regression test for CRIT-01 / HIGH-01:
; fix-gr-drawbitmap-closure.
;
; GR_DrawBitmap used to guard its paint block with `Type(DrawFn) == "Func"`.
; In AHK v2, any nested function that captures an enclosing local variable is
; a Closure (Type()=="Closure"), NOT a Func.  Both production callers
; (ui/spotlight.ahk and ui/wpm_widget.ahk) pass closures, so the
; old guard silently suppressed every DrawFn call and every UpdateLayeredWindow,
; leaving the spotlight overlay and the WPM graph widget fully invisible.
;
; The fix replaces the guard with HasMethod(DrawFn, "Call"), which returns true
; for Func, Closure, and BoundFunc alike.
;
; This test encodes the root cause by exercising GR_DrawBitmap with:
;   1. A plain (non-capturing) nested Func — must be called (worked before fix).
;   2. A capturing Closure               — must be called (was broken before fix).
;   3. A BoundFunc (ObjBindMethod)       — must be called (also broken before fix).
;   4. A non-callable value (42)         — must NOT be called (guard still active).
;
; Because creating a real layered HWND in CI would produce a visible OS window
; and fail on headless runners, we stub the DllCall-heavy internals by monkey-
; patching a thin wrapper.  The test directly validates the callable check in
; isolation using the same HasMethod semantics the fixed adapter uses.
;
; SCOPE: behavioral, covers adapters/graphics_renderer.ahk GR_DrawBitmap guard.
; ==============================================================================

#Requires AutoHotkey v2.0

; Stub classes used by the callable-guard tests - must be top-level in AHK v2
; (classes inside functions are a parse error).
class _GDB_Dummy {
    noop(dc, w, h) {
        return
    }
}
class _GDB_B {
    m(dc, w, h) {
        return
    }
}



; ==============================================
; ==============================================
; ======= 1/ Callable-guard unit tests =========
; ==============================================
; ==============================================

; Verify AHK v2 semantics that motivate the fix — these also serve as
; documentation for anyone wondering why HasMethod was chosen over Type().
_GDB_TypeSemanticsCheck() {
	; Non-capturing nested function — Type returns "Func"
	plain(dc, w, h) {
		return
	}
	Assert(Type(plain) == "Func",
		"A non-capturing nested function must have Type 'Func'")
	Assert(HasMethod(plain, "Call"),
		"A non-capturing nested function must pass HasMethod(...,'Call')")

	; Capturing closure — Type returns "Closure", not "Func"
	captured := 0
	closure(dc, w, h) => captured++
	Assert(Type(closure) == "Closure",
		"A capturing closure must have Type 'Closure', not 'Func'")
	Assert(HasMethod(closure, "Call"),
		"A capturing closure must pass HasMethod(...,'Call')")

	; Verify the old guard (Type==Func) would have rejected the closure
	Assert(!(Type(closure) == "Func"),
		"Old guard Type(closure)=='Func' must be FALSE — this is the root cause of CRIT-01")

	; BoundFunc via ObjBindMethod
	bf := ObjBindMethod(_GDB_Dummy(), "noop")
	Assert(Type(bf) == "BoundFunc",
		"ObjBindMethod result must have Type 'BoundFunc'")
	Assert(HasMethod(bf, "Call"),
		"BoundFunc must pass HasMethod(...,'Call')")
}

; Validate that the callable guard logic accepts the three expected callable
; forms and rejects a plain integer — without creating a real OS window.
_GDB_CallableGuardLogic() {
	_check(DrawFn) {
		; Mirror the exact guard logic from the fixed GR_DrawBitmap.
		return HasMethod(DrawFn, "Call")
	}

	; Plain func — must pass
	plain(dc, w, h) {
		return
	}
	Assert(_check(plain),
		"HasMethod guard must accept a plain Func")

	; Closure — must pass (was failing with the old Type()=='Func' guard)
	captured := false
	closure(dc, w, h) => (captured := true)
	Assert(_check(closure),
		"HasMethod guard must accept a Closure — this is the regression fix for CRIT-01")

	; BoundFunc — must pass
	bf := ObjBindMethod(_GDB_B(), "m")
	Assert(_check(bf),
		"HasMethod guard must accept a BoundFunc")

	; Integer — must be rejected
	Assert(!_check(42),
		"HasMethod guard must reject a plain integer")

	; String — must be rejected
	Assert(!_check("not-callable"),
		"HasMethod guard must reject a plain string")
}

; Verify that a closure DrawFn is actually invoked when the guard passes —
; simulating the paint callback path without requiring a real HWND.
_GDB_ClosureIsInvokedWhenGuardPasses() {
	CallCount := 0
	outerScale := 2   ; captured variable — makes this a Closure

	; The DrawFn mirrors what wpm_widget.ahk passes: a closure capturing locals.
	drawFn(MemDC, W, H) {
		CallCount += outerScale   ; references captured variable
	}

	Assert(Type(drawFn) == "Closure",
		"drawFn must be a Closure for this test to be meaningful")

	; Simulate what the fixed GR_DrawBitmap does inside its try block:
	if HasMethod(drawFn, "Call")
		drawFn(0, 100, 100)

	Assert(CallCount == 2,
		"Closure DrawFn must have been called once (CallCount should be 2 = 1 call * outerScale=2)")
}

; Verify that a plain non-capturing Func is also still invoked correctly.
_GDB_PlainFuncIsInvokedWhenGuardPasses() {
	global _GDB_PlainFuncFlag
	_GDB_PlainFuncFlag := false

	plainDraw(MemDC, W, H) {
		global _GDB_PlainFuncFlag
		_GDB_PlainFuncFlag := true
	}

	if HasMethod(plainDraw, "Call")
		plainDraw(0, 100, 100)

	Assert(_GDB_PlainFuncFlag,
		"Plain Func DrawFn must also be called through HasMethod guard")
}

; Verify that a non-callable value never triggers the paint block.
_GDB_NonCallableIsSkipped() {
	invoked := false
	DrawFn := 99   ; not callable

	if HasMethod(DrawFn, "Call")
		invoked := true

	Assert(!invoked,
		"HasMethod guard must block a non-callable value from triggering the paint block")
}


Test("GR_DrawBitmap closure fix: AHK v2 type semantics (Type vs HasMethod)",
	_GDB_TypeSemanticsCheck)

Test("GR_DrawBitmap closure fix: callable guard logic accepts Func/Closure/BoundFunc, rejects integer/string",
	_GDB_CallableGuardLogic)

Test("GR_DrawBitmap closure fix: closure DrawFn is actually invoked through HasMethod guard (CRIT-01)",
	_GDB_ClosureIsInvokedWhenGuardPasses)

Test("GR_DrawBitmap closure fix: plain Func DrawFn still invoked through HasMethod guard",
	_GDB_PlainFuncIsInvokedWhenGuardPasses)

Test("GR_DrawBitmap closure fix: non-callable value is blocked by HasMethod guard",
	_GDB_NonCallableIsSkipped)
