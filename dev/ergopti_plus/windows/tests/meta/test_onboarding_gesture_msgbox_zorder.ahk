; tests/meta/test_onboarding_gesture_msgbox_zorder.ahk

; ==============================================================================
; MODULE: Onboarding Gesture-Status MsgBox Z-Order Guard
; DESCRIPTION:
; Regression guard for _Step5_ShowGestureStatus's MsgBox rendering BEHIND the
; +AlwaysOnTop wizard window — the identical z-order bug already fixed one
; function away in _StepConfigDir_Browse (steps_config.ahk) but never applied
; to the gesture-registration status MsgBox.
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaOnboardingGestureMsgBoxZOrder() {
	Body := _DriverFuncBody("_Step5_ShowGestureStatus")
	Assert(Body != "", "_Step5_ShowGestureStatus must exist in ui/onboarding/steps_metrics.ahk")

	DownPos := InStr(Body, "-AlwaysOnTop")
	Assert(DownPos > 0,
		"_Step5_ShowGestureStatus must drop AlwaysOnTop before showing the MsgBox, mirroring _StepConfigDir_Browse")

	MsgBoxPos := InStr(Body, "MsgBox(Msg,")
	Assert(MsgBoxPos > 0, "_Step5_ShowGestureStatus must still call MsgBox(Msg, ...)")
	Assert(DownPos < MsgBoxPos,
		"AlwaysOnTop must be dropped BEFORE the MsgBox call")

	UpPos := InStr(Body, "+AlwaysOnTop", , MsgBoxPos)
	Assert(UpPos > 0 && UpPos > MsgBoxPos,
		"_Step5_ShowGestureStatus must restore AlwaysOnTop AFTER the MsgBox call")
}
Test("onboarding: _Step5_ShowGestureStatus drops/restores AlwaysOnTop around its MsgBox", _MetaOnboardingGestureMsgBoxZOrder)
