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
	HookDispatcher._OnKeyDown(0, 0xA2, 0x01D) ; repeated LCtrl key-down while held
	HookDispatcher._last_wheel_tick := 0      ; release is outside the recent-wheel window
	HookDispatcher._OnKeyUp(0, 0xA2, 0x01D)   ; LCtrl up

	AssertTrue(TapHoldShouldCancelTap("left_ctrl", 500) != "",
		"Ctrl+wheel must cancel the pending LCtrl tap before release dispatch")
}
Test("tap-hold: Ctrl+wheel cancels the tap action before Ctrl release (ctrl-wheel-no-paste)", _THAC_TrackWheelThroughDispatcher)

_THAC_RepeatedKeyDownPreservesCancellation() {
	_THAC_ResetState()
	HookDispatcher._OnKeyDown(0, 0xA2, 0x01D) ; LCtrl down
	HookDispatcher._OnWheelDown()             ; cancellation boundary
	HookDispatcher._OnKeyDown(0, 0xA2, 0x01D) ; InputHook repeat while held

	AssertTrue(_TH_TapHoldTrackState["left_ctrl"]["canceled_by_activity"],
		"a repeated modifier key-down must not clear wheel cancellation")
	HookDispatcher._OnKeyUp(0, 0xA2, 0x01D)
	AssertTrue(TapHoldShouldCancelTap("left_ctrl", 500) != "",
		"wheel cancellation must survive repeated modifier key-down notifications")
}
Test("tap-hold: repeated modifier key-downs preserve activity cancellation (ctrl-wheel-repeat-no-paste)", _THAC_RepeatedKeyDownPreservesCancellation)

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
		HookDispatcher._OnKeyDown(0, 0xA2, 0x01D) ; repeated key-down must not reset cancellation
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





; ============================================================================
; ======= Full key × activity regression matrix ==============================
; ============================================================================

; Canonical physical event tuples for every tap-hold key exposed by the AHK
; driver. Keeping non-modifiers here (Space, Enter, Tab, Backspace, etc.) is
; intentional: activity cancellation is a tap-hold-engine invariant, not a
; Ctrl/modifier special case.
_THAC_AllKeyCases() {
	return [
		{Id: "escape",     Vk: 0x1B, Sc: 0x001},
		{Id: "tab",        Vk: 0x09, Sc: 0x00F},
		{Id: "caps_lock",  Vk: 0x14, Sc: 0x03A},
		{Id: "left_shift", Vk: 0xA0, Sc: 0x02A},
		{Id: "left_ctrl",  Vk: 0xA2, Sc: 0x01D},
		{Id: "win",        Vk: 0x5B, Sc: 0x15B},
		{Id: "left_alt",   Vk: 0xA4, Sc: 0x038},
		{Id: "space",      Vk: 0x20, Sc: 0x039},
		{Id: "alt_gr",     Vk: 0xA5, Sc: 0x138},
		{Id: "right_ctrl", Vk: 0xA3, Sc: 0x11D},
		{Id: "right_shift",Vk: 0xA1, Sc: 0x036},
		{Id: "enter",      Vk: 0x0D, Sc: 0x01C},
		{Id: "backspace",  Vk: 0x08, Sc: 0x00E},
		{Id: "delete",     Vk: 0x2E, Sc: 0x153}
	]
}

_THAC_InterruptKinds() {
	return [
		"wheel_up", "wheel_down", "wheel_left", "wheel_right",
		"left_down", "left_up", "right_down", "right_up",
		"middle_down", "middle_up", "x1_down", "x1_up", "x2_down", "x2_up",
		"other_key_down", "other_key_up"
	]
}

_THAC_RunInterrupt(Kind) {
	switch Kind {
		case "wheel_up":       HookDispatcher._OnWheelUp()
		case "wheel_down":     HookDispatcher._OnWheelDown()
		case "wheel_left":     HookDispatcher._OnWheelLeft()
		case "wheel_right":    HookDispatcher._OnWheelRight()
		case "left_down":      HookDispatcher._OnLDown()
		case "left_up":        HookDispatcher._OnLUp()
		case "right_down":     HookDispatcher._OnRDown()
		case "right_up":       HookDispatcher._OnRUp()
		case "middle_down":    HookDispatcher._OnMDown()
		case "middle_up":      HookDispatcher._OnMUp()
		case "x1_down":        HookDispatcher._OnX1Down()
		case "x1_up":          HookDispatcher._OnX1Up()
		case "x2_down":        HookDispatcher._OnX2Down()
		case "x2_up":          HookDispatcher._OnX2Up()
		case "other_key_down": HookDispatcher._OnKeyDown(0, 0x56, 0x02F) ; V
		case "other_key_up":   HookDispatcher._OnKeyUp(0, 0x56, 0x02F)
		default: throw Error("Unknown tap-hold interrupt kind: " . Kind)
	}
}

_THAC_WithSingleKeyConfig(KeyCase, CallbackFn) {
	global TapHold
	PreviousTapHold := TapHold
	try {
		TapHold := Map("keys", Map(KeyCase.Id, Map(
			"tap_action", "__matrix_tap",
			"time_activation_seconds", 0.2)), "layers", Map())
		CallbackFn.Call()
	} finally {
		TapHold := PreviousTapHold
		_THAC_ResetState()
	}
}

global _THAC_MatrixTapHits := 0

_THAC_RecordMatrixTap() {
	global _THAC_MatrixTapHits
	_THAC_MatrixTapHits += 1
}

_THAC_AllInterruptsCancelOneKey(KeyCase) {
	for Kind in _THAC_InterruptKinds() {
		_THAC_WithSingleKeyConfig(KeyCase, _THAC_RunMatrixCase.Bind(KeyCase, Kind))
	}
}

_THAC_RunMatrixCase(KeyCase, Kind) {
	global _THAC_MatrixTapHits
	_THAC_MatrixTapHits := 0
	HookDispatcher._OnKeyDown(0, KeyCase.Vk, KeyCase.Sc)
	_THAC_RunInterrupt(Kind)
	; Hardware repeat after the interrupt belongs to the same physical press and
	; must never erase the cancellation decision.
	HookDispatcher._OnKeyDown(0, KeyCase.Vk, KeyCase.Sc)
	HookDispatcher._OnKeyUp(0, KeyCase.Vk, KeyCase.Sc)
	TapHoldDispatchTap(KeyCase.Id, _THAC_RecordMatrixTap)
	AssertEqual(0, _THAC_MatrixTapHits,
		KeyCase.Id . " must suppress its tap after interrupt=" . Kind)
}

_THAC_IsolatedTapAndFreshPressRecover(KeyCase) {
	global _THAC_MatrixTapHits
	_THAC_WithSingleKeyConfig(KeyCase, _THAC_RunIsolatedAndRecovery.Bind(KeyCase))
}

_THAC_RunIsolatedAndRecovery(KeyCase) {
	global _THAC_MatrixTapHits
	_THAC_MatrixTapHits := 0

	; A wheel before the press is not an intervening event and must not suppress
	; the subsequent isolated tap.
	HookDispatcher._OnWheelDown()
	Sleep(2)
	HookDispatcher._OnKeyDown(0, KeyCase.Vk, KeyCase.Sc)
	HookDispatcher._OnKeyDown(0, KeyCase.Vk, KeyCase.Sc)
	HookDispatcher._OnKeyUp(0, KeyCase.Vk, KeyCase.Sc)
	TapHoldDispatchTap(KeyCase.Id, _THAC_RecordMatrixTap)
	AssertEqual(1, _THAC_MatrixTapHits,
		KeyCase.Id . " isolated tap must still dispatch after earlier wheel activity")

	; A cancellation belongs only to one physical press. The next fresh key-down
	; must reset it and allow a true isolated tap.
	HookDispatcher._OnKeyDown(0, KeyCase.Vk, KeyCase.Sc)
	HookDispatcher._OnWheelUp()
	HookDispatcher._OnKeyUp(0, KeyCase.Vk, KeyCase.Sc)
	AssertTrue(TapHoldShouldCancelTap(KeyCase.Id, 500) != "",
		KeyCase.Id . " first press should be canceled")
	HookDispatcher._OnKeyDown(0, KeyCase.Vk, KeyCase.Sc)
	HookDispatcher._last_wheel_tick := 0
	HookDispatcher._OnKeyUp(0, KeyCase.Vk, KeyCase.Sc)
	TapHoldDispatchTap(KeyCase.Id, _THAC_RecordMatrixTap)
	AssertEqual(2, _THAC_MatrixTapHits,
		KeyCase.Id . " fresh press must clear the prior gesture's cancellation")
}

_THAC_KeyRegistryMatchesMatrix() {
	global _TH_TapHoldVkToKeyId
	Cases := _THAC_AllKeyCases()
	AssertEqual(_TH_TapHoldVkToKeyId.Count, Cases.Length,
		"the regression matrix must cover every AHK tap-hold key id")
	for KeyCase in Cases {
		AssertTrue(_TH_TapHoldVkToKeyId.Has(KeyCase.Vk),
			"tap-hold VK registry missing matrix key " . KeyCase.Id)
		AssertEqual(KeyCase.Id, _TH_TapHoldVkToKeyId[KeyCase.Vk],
			"tap-hold VK registry id mismatch for " . KeyCase.Id)
		AssertEqual(KeyCase.Id, TapHoldResolveKeyIdFromVkSc(KeyCase.Vk, KeyCase.Sc),
			"tap-hold VK/SC resolution mismatch for " . KeyCase.Id)
	}
}
Test("tap-hold: full activity matrix covers every registered key", _THAC_KeyRegistryMatchesMatrix)

for _THAC_RegisteredCase in _THAC_AllKeyCases() {
	Test("tap-hold: every pointer/key interrupt suppresses " . _THAC_RegisteredCase.Id,
		_THAC_AllInterruptsCancelOneKey.Bind(_THAC_RegisteredCase))
	Test("tap-hold: isolated and fresh presses still dispatch " . _THAC_RegisteredCase.Id,
		_THAC_IsolatedTapAndFreshPressRecover.Bind(_THAC_RegisteredCase))
}
