; tests/meta/test_space_hold_exception_guard.ahk

#Requires AutoHotkey v2.0

_SHEG_AssertSpaceHoldTryGuard() {
	Funcs := ["_SpaceHoldCtrl", "_SpaceHoldShift", "_SpaceHoldAlt", "_SpaceHoldAltGr", "_SpaceHoldWin"]
	for _, fn in Funcs {
		; Move-resilient: locate each hold function across the whole driver source
		; via the framework helper instead of a pinned modules path
		Body := _DriverFuncBody(fn)
		Assert(Body != "", fn . " must exist in space.ahk")
		
		; We assert that there's a try block protecting the SendInput of the captured char
		Assert(RegExMatch(Body, "try\s*\{[\s\S]*try\s+SendInput") > 0, fn . " must protect SendInput(captured) with an inner try block to avoid unhandled target exceptions (space-hold-exception-guard)")
		
		; We assert that RegExReplace is used to escape characters
		Assert(InStr(Body, 'RegExReplace(captured, "([!#^+{}])", "{$1}")') > 0, fn . " must escape characters for SendInput to prevent unexpected AHK v2 parsing errors (space-hold-exception-guard)")
	}
}

Test("tap_holds: space hold functions guard dynamic SendInput against unhandled exceptions (space-hold-exception-guard)", _SHEG_AssertSpaceHoldTryGuard)
