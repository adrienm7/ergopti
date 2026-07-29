; tests/meta/test_wmexists_is_not_a_handle.ahk

; ==============================================================================
; MODULE: WMExists Return-Value Misuse Regression Test
; DESCRIPTION:
; WMExists() is an EXISTENCE PREDICATE — `return WinExist(Spec) ? true : false`.
; Its boolean is not a window handle. GestureScreenshotWindow assigned it to a
; variable named HWnd and built the spec "ahk_id " . HWnd, which resolves to
; "ahk_id 1": WinGetPos then threw, the surrounding catch logged
; "screenshot_window: WinGetPos failed" and returned, so the default tap_4
; gesture could never once capture a window. The failure was invisible because
; the catch turned a permanent defect into a routine-looking warning.
;
; FEATURES & RATIONALE:
; 1. Behavioural anchor: asserts the adapter really does answer with a boolean,
;    so the premise of the guard is checked against the live function rather
;    than assumed from its docstring.
; 2. Loops the CLASS, not the one site that bit us: every `X := WMExists(...)`
;    in the whole driver is found from source, and each is rejected if that same
;    variable is later concatenated into an "ahk_id " spec. A new caller making
;    the same mistake joins this test automatically.
; ==============================================================================

#Requires AutoHotkey v2.0

; The adapter's contract: a predicate, never a handle. If this ever starts
; returning a real HWND the class guard below becomes unnecessary — and this
; assertion is what will say so, instead of the guard silently going vacuous.
_WINH_AdapterAnswersWithABoolean() {
	Body := _DriverFuncBody("WMExists")
	Assert(Body != "", "WMExists must exist as a driver function")
	Assert(InStr(Body, "? true : false") > 0,
		'WMExists must remain an existence PREDICATE returning true/false — a caller that '
		. 'treats its result as a window handle builds the spec "ahk_id 1" and every '
		. 'WinGetPos/WinGetTitle against it throws')
}
Test("window_manager: WMExists answers with a boolean, not a handle", _WINH_AdapterAnswersWithABoolean)

; Class guard — find every variable assigned from WMExists() anywhere in the
; driver and prove none of them is used to build an "ahk_id" spec.
_WINH_NoWMExistsResultUsedAsHandle() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable")

	Offenders := ""
	Checked := 0
	Pos := 1
	while (FoundPos := RegExMatch(Src, "im)^\s*(\w+)\s*:=\s*WMExists\s*\(", &M, Pos)) {
		Pos := FoundPos + M.Len
		VarName := M[1]
		Checked += 1
		; Only the assigned variable matters, and only downstream of the
		; assignment — a same-named variable earlier in another function cannot
		; be the one this line produced.
		Tail := SubStr(Src, FoundPos, 4000)
		if RegExMatch(Tail, 'i)ahk_id\s*"\s*\.\s*' . VarName . '\b')
			Offenders .= "`n  - '" . VarName . "' assigned from WMExists() is concatenated into an ahk_id spec"
	}

	Assert(Checked > 0,
		"the scan must find at least one WMExists() assignment — if none remain, delete this "
		. "guard deliberately rather than letting it pass vacuously")
	Assert(Offenders == "",
		'a WMExists() boolean must never be used as a window handle:' . Offenders
		. '`nUse WMGetFocused()["hwnd"] (or another adapter that returns a real handle) instead.')
}
Test("gestures: no WMExists() boolean is ever used as a window handle", _WINH_NoWMExistsResultUsedAsHandle)

; The specific site that shipped broken, pinned so a revert is loud.
_WINH_ScreenshotWindowUsesARealHandle() {
	Body := _DriverFuncBody("GestureScreenshotWindow")
	Assert(Body != "", "GestureScreenshotWindow must exist")
	Assert(InStr(Body, 'WMGetFocused()["hwnd"]') > 0,
		'GestureScreenshotWindow must source its handle from WMGetFocused()["hwnd"] — with '
		. 'WMExists it captured nothing at all and reported only a WinGetPos warning')
	Assert(!RegExMatch(Body, "i)HWnd\s*:=\s*WMExists\s*\("),
		"GestureScreenshotWindow must not assign WMExists() to its handle variable")
}
Test("gestures: window screenshot resolves a real window handle", _WINH_ScreenshotWindowUsesARealHandle)
