; tests/unit/test_plc_closure_callable.ahk

; ==============================================================================
; MODULE: ProcessLifecycle Closure/BoundFunc Acceptance Test
; DESCRIPTION:
; Behavioral regression test for finding
; plc-onfocuschange-drops-closures-boundfuncs.
;
; PLC_OnFocusChange / PLC_OnAppLaunch / PLC_OnAppQuit used to guard with
; `Type(Callback) = "Func"`. Type() returns the concrete class name, so a
; closure (Type "Closure") or a bound method (Type "BoundFunc") failed the
; check and was silently dropped - the idiomatic way to register an instance
; handler never reached the subscriber list, with no error logged.
;
; The fix replaces the narrow Type() check with HasMethod(Callback, "Call"),
; which is true for Func, Closure, BoundFunc and any callable object. This
; test registers one closure and one BoundFunc into each callback list and
; asserts the list length grows by exactly the number registered. Before the
; fix the delta is 0 (silently dropped); after the fix it is the count pushed.
;
; The PLC_* functions and their global PLC_*Callbacks arrays are already in the
; run_all.ahk include graph (../adapters/process_lifecycle.ahk) and are called
; behaviorally by test_adapter_compliance_new.ahk, so a direct call here is
; load-safe in the headless runner. Length deltas are measured (never absolute
; counts) because sibling tests also push into these same global arrays.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================================
; ==========================================================
; ======= 1/ Callable fixtures =============================
; ==========================================================
; ==========================================================

; A plain method on a fixture object so .Bind() yields a genuine BoundFunc.
class _PlcClosure_Fixture {
	Handler(AppId, WindowTitle) {
		; No-op: presence in the callback list is what the test asserts, not
		; invocation. Returning is enough to satisfy the focus callback shape.
		return true
	}
}




; ==========================================================
; ==========================================================
; ======= 2/ Acceptance assertions =========================
; ==========================================================
; ==========================================================

; A closure capturing a local must be accepted as a focus callback. Before the
; fix Type()="Closure" failed the "Func" guard and the closure was dropped.
_PlcClosure_FocusAcceptsClosure() {
	global PLC_FocusCallbacks
	local captured := 1
	local closureCb := (AppId, WindowTitle) => captured
	local before := PLC_FocusCallbacks.Length
	PLC_OnFocusChange(closureCb)
	AssertEqual(before + 1, PLC_FocusCallbacks.Length,
		"PLC_OnFocusChange must accept a closure (Type Closure) - HasMethod(Call) covers it; the old Type=Func guard dropped it silently")
}
Test("ProcessLifecycle: onFocusChange accepts a closure (plc-onfocuschange-drops-closures-boundfuncs)", _PlcClosure_FocusAcceptsClosure)

; A bound method must be accepted as a focus callback. Before the fix
; Type()="BoundFunc" failed the "Func" guard and the bound method was dropped.
_PlcClosure_FocusAcceptsBoundFunc() {
	global PLC_FocusCallbacks
	local fixture := _PlcClosure_Fixture()
	local boundCb := fixture.Handler.Bind(fixture)
	local before := PLC_FocusCallbacks.Length
	PLC_OnFocusChange(boundCb)
	AssertEqual(before + 1, PLC_FocusCallbacks.Length,
		"PLC_OnFocusChange must accept a BoundFunc (Type BoundFunc) - the idiomatic instance-handler registration; the old Type=Func guard dropped it silently")
}
Test("ProcessLifecycle: onFocusChange accepts a BoundFunc (plc-onfocuschange-drops-closures-boundfuncs)", _PlcClosure_FocusAcceptsBoundFunc)

; The same generic-callable contract must hold for the launch registration.
_PlcClosure_LaunchAcceptsClosure() {
	global PLC_LaunchCallbacks
	local captured := 1
	local closureCb := (AppId, WindowTitle) => captured
	local before := PLC_LaunchCallbacks.Length
	PLC_OnAppLaunch(closureCb)
	AssertEqual(before + 1, PLC_LaunchCallbacks.Length,
		"PLC_OnAppLaunch must accept a closure - the old Type=Func guard dropped closures and bound methods silently")
}
Test("ProcessLifecycle: onAppLaunch accepts a closure (plc-onfocuschange-drops-closures-boundfuncs)", _PlcClosure_LaunchAcceptsClosure)

; And for the quit registration.
_PlcClosure_QuitAcceptsBoundFunc() {
	global PLC_QuitCallbacks
	local fixture := _PlcClosure_Fixture()
	local boundCb := fixture.Handler.Bind(fixture)
	local before := PLC_QuitCallbacks.Length
	PLC_OnAppQuit(boundCb)
	AssertEqual(before + 1, PLC_QuitCallbacks.Length,
		"PLC_OnAppQuit must accept a BoundFunc - the old Type=Func guard dropped bound methods silently")
}
Test("ProcessLifecycle: onAppQuit accepts a BoundFunc (plc-onfocuschange-drops-closures-boundfuncs)", _PlcClosure_QuitAcceptsBoundFunc)

; A non-callable value must still be rejected (not pushed) so garbage cannot
; enter the callback list and crash PLC_Poll when it iterates and calls each.
_PlcClosure_FocusRejectsNonCallable() {
	global PLC_FocusCallbacks
	local before := PLC_FocusCallbacks.Length
	PLC_OnFocusChange("not a callable")
	AssertEqual(before, PLC_FocusCallbacks.Length,
		"PLC_OnFocusChange must reject a non-callable (HasMethod(Call) is false) so PLC_Poll never tries to call a String")
}
Test("ProcessLifecycle: onFocusChange rejects a non-callable (plc-onfocuschange-drops-closures-boundfuncs)", _PlcClosure_FocusRejectsNonCallable)
