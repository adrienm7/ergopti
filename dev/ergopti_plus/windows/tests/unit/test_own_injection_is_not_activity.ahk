; tests/unit/test_own_injection_is_not_activity.ahk

; ==============================================================================
; MODULE: The driver's own injected keys are not user activity
; DESCRIPTION:
; The hook dispatcher's InputHook ("V L0", no I option) observed every injected
; key, and TextSender sent at the calling thread's SendLevel: 2 in every tap-hold
; hotkey thread. SendInput hides a script's own keys from its hooks only while
; no other AutoHotkey keyboard hook runs; with one, it falls back to SendEvent
; (AutoHotkey 2.0.26 keyboard_mouse.cpp), and the dispatcher then counted the
; driver's own synthetic modifier holds and taps as keyboard activity: a hold's
; own Ctrl cancelled the pending tap of another held key and advanced the
; physical-input generation (own-injection-activity-2026-09-25).
; TextSender now sends at SendLevel 0 and the dispatcher ignores level-0 input,
; as the prefix watcher already did, while the layout remap output, which stands
; for a physical key the remap hotkey suppressed, stays visible at its level.
; ==============================================================================

#Requires AutoHotkey v2.0

global _OIA_Levels := []

_OIA_RecordLevel(Keys) {
	global _OIA_Levels
	_OIA_Levels.Push(A_SendLevel)
}

_OIA_TextSenderSendsAtLevelZero() {
	global _AHK_SendInput, _OIA_Levels
	Saved := _AHK_SendInput
	PreviousLevel := A_SendLevel
	_OIA_Levels := []
	_AHK_SendInput := _OIA_RecordLevel
	try {
		; A tap-hold hotkey thread runs at its #InputLevel, 2.
		SendLevel(2)
		TextPressKey("LCtrl", "Down")
		TextPressKey("LCtrl", "Up")
		TextPressKey("Enter", [])
		TextSendMenuMask()
		AssertEqual(4, _OIA_Levels.Length, "every TextSender emission must be recorded")
		for _, Level in _OIA_Levels
			AssertEqual(TEXT_SENDER_SEND_LEVEL, Level,
				"TextSender output must go out at its own SendLevel, never the calling hotkey's")
		AssertEqual(2, A_SendLevel, "the calling thread's SendLevel must be restored")
	} finally {
		_AHK_SendInput := Saved
		SendLevel(PreviousLevel)
	}
}
Test("own injection: TextSender sends at SendLevel 0 from any thread (own-injection-activity-2026-09-25)",
	_OIA_TextSenderSendsAtLevelZero)

_OIA_DispatcherIgnoresTheDriversOwnOutput() {
	global TEXT_SENDER_SEND_LEVEL
	Hook := InputHook(HookDispatcherConst.INPUT_HOOK_OPTS)
	Assert(Hook.MinSendLevel > TEXT_SENDER_SEND_LEVEL,
		"the dispatcher must ignore the driver's own TextSender output, or its synthetic holds count as keyboard activity")
	; RemapKey registers the layout remap hotkeys at input level 2, so their
	; output, the only trace of the physical key they suppress, is sent at 2.
	Assert(Hook.MinSendLevel <= 2,
		"the dispatcher must still see the layout remap output, which stands for a physical key")
	AssertTrue(InStr(HookDispatcherConst.INPUT_HOOK_OPTS, "V") > 0, "the hook must stay visible")
}
Test("own injection: the dispatcher's InputHook ignores the driver's own output (own-injection-activity-2026-09-25)",
	_OIA_DispatcherIgnoresTheDriversOwnOutput)
