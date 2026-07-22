; tests/meta/test_gesture_click_hold_released_on_suspend.ahk

; ==============================================================================
; MODULE: Gesture Click-Hold Released on Suspend Meta Test
; DESCRIPTION:
; Regression guard for the AHK-12 click-hold-on-suspend fix.
;
; A gesture left/right click-hold (SendEvent "{LButton Down}") can be active
; when the user pauses the driver. AHK timer callbacks bypass native Suspend,
; so the InputHook installed by GestureStartKeyboardWatcher() keeps firing. If
; GestureOnKeyDown does not check A_IsSuspended, the button stays logically held
; in the suspended window — the user cannot release it without physically clicking,
; and further keystrokes mis-fire because the virtual button is still pressed.
;
; The fix adds an A_IsSuspended guard in GestureOnKeyDown that (a) stops the
; InputHook, (b) releases BOTH the left and right click-hold states by calling
; GestureReleaseLeftClick() AND GestureReleaseRightClick(), and (c) returns
; early so no further key processing occurs.
;
; Separately, Ergopti_OnSuspendEnter() also calls the two release helpers
; unconditionally so any hold active at the moment of suspend is released even
; before the InputHook fires again.
;
; This test asserts both paths are present.
;
; SCOPE: source introspection of modules/gestures/click.ahk and lib/lifecycle.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_GCHRS_ReadClickSrc() {
	return _DriverDirConcat("modules/gestures")
}

_GCHRS_ReadLifecycleSrc() {
	return _DriverDirConcat("lib")
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_GCHRS_KeyDownSuspendGuardPresent() {
	Src := _GCHRS_ReadClickSrc()
	Assert(Src != "", "modules/gestures/ source must be readable")

	Body := _DriverFuncBody("GestureOnKeyDown")
	Assert(Body != "", "GestureOnKeyDown must be defined in modules/gestures/click.ahk")

	Assert(InStr(Body, "A_IsSuspended") > 0,
		"GestureOnKeyDown must check A_IsSuspended — InputHooks bypass native Suspend and would otherwise keep a click-hold active while the driver is paused (AHK-12)")
}

Test("gestures: GestureOnKeyDown checks A_IsSuspended (gesture-click-hold-released-on-suspend)",
	_GCHRS_KeyDownSuspendGuardPresent)


_GCHRS_KeyDownReleasesLeftClickOnSuspend() {
	Body := _DriverFuncBody("GestureOnKeyDown")
	Assert(Body != "", "GestureOnKeyDown must be defined — prerequisite for this test")

	SuspendPos := InStr(Body, "A_IsSuspended")
	ReleasePos := InStr(Body, "GestureReleaseLeftClick()")

	Assert(ReleasePos > 0,
		"GestureOnKeyDown suspend branch must call GestureReleaseLeftClick() — a held left button must be released when the driver is paused so it does not remain logically pressed in the target window (AHK-12)")
	Assert(SuspendPos < ReleasePos,
		"GestureReleaseLeftClick() must appear after the A_IsSuspended check in GestureOnKeyDown — the release is conditional on the suspend state")
}

Test("gestures: GestureOnKeyDown releases left click-hold when suspended (gesture-click-hold-released-on-suspend)",
	_GCHRS_KeyDownReleasesLeftClickOnSuspend)


_GCHRS_KeyDownReleasesRightClickOnSuspend() {
	Body := _DriverFuncBody("GestureOnKeyDown")
	Assert(Body != "", "GestureOnKeyDown must be defined — prerequisite for this test")

	SuspendPos  := InStr(Body, "A_IsSuspended")
	ReleasePos  := InStr(Body, "GestureReleaseRightClick()")

	Assert(ReleasePos > 0,
		"GestureOnKeyDown suspend branch must call GestureReleaseRightClick() — a held right button must also be released on suspend to match the left-click fix (AHK-12)")
}

Test("gestures: GestureOnKeyDown releases right click-hold when suspended (gesture-click-hold-released-on-suspend)",
	_GCHRS_KeyDownReleasesRightClickOnSuspend)


_GCHRS_SuspendEnterReleasesClickHolds() {
	Src := _GCHRS_ReadLifecycleSrc()
	Assert(Src != "", "lib/ source must be readable")

	Body := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(Body != "", "Ergopti_OnSuspendEnter must be defined in lib/lifecycle.ahk")

	Assert(InStr(Body, "GestureReleaseLeftClick()") > 0,
		"Ergopti_OnSuspendEnter must call GestureReleaseLeftClick() — the click-hold must be released at the moment of suspend, not only when the InputHook fires next (AHK-12)")
	Assert(InStr(Body, "GestureReleaseRightClick()") > 0,
		"Ergopti_OnSuspendEnter must call GestureReleaseRightClick() — both hold states must be cleared unconditionally on suspend so no phantom button press leaks into the suspended window (AHK-12)")
}

Test("lifecycle: Ergopti_OnSuspendEnter releases both click-hold states (gesture-click-hold-released-on-suspend)",
	_GCHRS_SuspendEnterReleasesClickHolds)
