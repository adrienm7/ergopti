; tests/unit/test_tap_hold_activity_cancel.ahk

; ============================================================================
; MODULE: Tap-Hold Activity-Cancellation Regression Tests
; DESCRIPTION:
; A tap-hold modifier must not emit its tap action after it was used with
; another input. In particular, Ctrl down -> wheel (browser zoom) -> Ctrl up
; must not fire the Ctrl tap action (historically paste). The same invariant
; applies to Ctrl+C/Ctrl+V and mouse-button activity.
; ============================================================================





_THAC_ResetState() {
	global _TH_TapHoldTrackState
	_TH_TapHoldTrackState := Map()
	HookDispatcher._last_wheel_tick := 0
}

_THAC_TrackWheelThroughDispatcher() {
	_THAC_ResetState()
	HookDispatcher._OnKeyDown(0, 0xA2, 0x01D) ; LCtrl down
	HookDispatcher._OnWheelDown()             ; Ctrl+wheel zoom
	HookDispatcher._last_wheel_tick := 0      ; release is outside the recent-wheel window
	HookDispatcher._OnKeyUp(0, 0xA2, 0x01D)   ; LCtrl up

	AssertTrue(TapHoldShouldCancelTap("left_ctrl", 500) != "",
		"Ctrl+wheel must cancel the pending LCtrl tap before release dispatch")
}
Test("tap-hold: Ctrl+wheel cancels the tap action before Ctrl release (ctrl-wheel-no-paste)", _THAC_TrackWheelThroughDispatcher)

_THAC_TrackOtherKeyThroughDispatcher() {
	_THAC_ResetState()
	HookDispatcher._OnKeyDown(0, 0xA2, 0x01D) ; LCtrl down
	HookDispatcher._OnKeyDown(0, 0x56, 0x02F) ; V down (not a tap-hold key)
	AssertTrue(_TH_TapHoldTrackState["left_ctrl"]["canceled_by_activity"],
		"the non-tap key event must mark the held LCtrl as activity-canceled")
	HookDispatcher._OnKeyUp(0, 0xA2, 0x01D)   ; LCtrl up

	AssertTrue(TapHoldShouldCancelTap("left_ctrl", 500) != "",
		"another key used with Ctrl must cancel the pending LCtrl tap")
}
Test("tap-hold: another key cancels the modifier tap (ctrl-chord-no-paste)", _THAC_TrackOtherKeyThroughDispatcher)

_THAC_MouseActivityCancelsThroughDispatcher() {
	_THAC_ResetState()
	HookDispatcher._OnKeyDown(0, 0xA3, 0x11D) ; RCtrl down
	HookDispatcher._OnLDown()                ; mouse click while held
	HookDispatcher._OnKeyUp(0, 0xA3, 0x11D)  ; RCtrl up

	AssertTrue(TapHoldShouldCancelTap("right_ctrl", 500) != "",
		"mouse activity while Ctrl is held must cancel the pending RCtrl tap")
}
Test("tap-hold: mouse activity cancels the modifier tap (ctrl-mouse-no-paste)", _THAC_MouseActivityCancelsThroughDispatcher)

_THAC_SameKeyDownDoesNotCancelItsOwnTap() {
	_THAC_ResetState()
	HookDispatcher._OnKeyDown(0, 0xA2, 0x01D) ; LCtrl down
	HookDispatcher._OnKeyDown(0, 0xA2, 0x01D) ; repeated LCtrl event

	AssertEqual("", TapHoldShouldCancelTap("left_ctrl", 500),
		"the tap-hold key's own repeated key-down must not count as other activity")
}
Test("tap-hold: the modifier key itself does not cancel its tap (ctrl-own-keydown)", _THAC_SameKeyDownDoesNotCancelItsOwnTap)

global _THAC_TapActionHits := 0

_THAC_RecordTapAction() {
	global _THAC_TapActionHits
	_THAC_TapActionHits += 1
}

_THAC_WheelDoesNotFireConfiguredTapAction() {
	global _THAC_TapActionHits, GESTURE_ACTIONS, TapHold
	_THAC_ResetState()
	_THAC_TapActionHits := 0
	ActionId := "__test_ctrl_wheel_no_tap"
	HadAction := GESTURE_ACTIONS.Has(ActionId)
	PreviousAction := HadAction ? GESTURE_ACTIONS[ActionId] : 0
	PreviousTapHold := TapHold
	try {
		GESTURE_ACTIONS[ActionId] := {Fn: _THAC_RecordTapAction}
		TapHold := Map("keys", Map("left_ctrl", Map(
			"tap_action", ActionId,
			"time_activation_seconds", 0.2)), "layers", Map())

		HookDispatcher._OnKeyDown(0, 0xA2, 0x01D)
		HookDispatcher._OnWheelDown()
		HookDispatcher._last_wheel_tick := 0
		HookDispatcher._OnKeyUp(0, 0xA2, 0x01D)
		_TapHoldFireAction("left_ctrl")

		AssertEqual(0, _THAC_TapActionHits,
			"Ctrl+wheel release must not invoke the configured tap action")
	} finally {
		TapHold := PreviousTapHold
		if HadAction
			GESTURE_ACTIONS[ActionId] := PreviousAction
		else
			GESTURE_ACTIONS.Delete(ActionId)
		_THAC_ResetState()
	}
}
Test("tap-hold: Ctrl+wheel does not dispatch the configured tap action (ctrl-wheel-no-dispatch)", _THAC_WheelDoesNotFireConfiguredTapAction)
