; tests/meta/test_gesture_keywatcher_suspend.ahk

; ==============================================================================
; MODULE: Gesture Keyboard Watcher Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for the clickhold-inputhook-drops-keys finding.
;
; GestureOnKeyDown is the OnKeyDown callback for the InputHook installed by
; GestureStartKeyboardWatcher while a click-hold mode is active. InputHooks in
; AHK v2 bypass Suspend — they continue to suppress and re-deliver keystrokes
; even when A_IsSuspended is true and all hotkeys are disabled.
;
; Without this guard, a user who pauses the driver while holding a click-toggle
; would have every keystroke silently consumed by the hook and re-injected at
; Level 3 — Ergopti-level — contrary to the project's "pause = tout éteint"
; invariant (pause means no driver intervention on input).
;
; The fix: add an A_IsSuspended check at the top of GestureOnKeyDown. When
; true, release the held clicks and re-send the swallowed key at level 0
; (plain OS key, no Ergopti remapping) then return immediately.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ GestureOnKeyDown suspend guard =========
; ===================================================
; ===================================================

_GKWS_SuspendGuardInOnKeyDown() {
	Body := _DriverFuncBody("GestureOnKeyDown")
	Assert(Body != "", "GestureOnKeyDown must exist in modules/gestures.ahk")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"GestureOnKeyDown must check A_IsSuspended — InputHooks bypass Suspend and would otherwise suppress/re-inject keystrokes at Level 3 while the driver is paused (clickhold-inputhook-drops-keys)")
}
Test("gestures: GestureOnKeyDown has A_IsSuspended guard (clickhold-inputhook-drops-keys)", _GKWS_SuspendGuardInOnKeyDown)

_GKWS_InputHookIsNonConsuming() {
	Body := _DriverFuncBody("GestureStartKeyboardWatcher")
	Assert(Body != "", "GestureStartKeyboardWatcher must exist in modules/gestures.ahk")
	Assert(InStr(Body, 'InputHook("V L3")') > 0 || InStr(Body, "InputHook('V L3')") > 0, "GestureStartKeyboardWatcher must use 'V' option to make the hook non-consuming (clickhold-inputhook-drops-keys)")

	BodyOnKeyDown := _DriverFuncBody("GestureOnKeyDown")
	Assert(InStr(BodyOnKeyDown, "SendLevel") == 0, "GestureOnKeyDown must not re-send keys using SendLevel, as the hook is now non-consuming")
}
Test("gestures: GestureStartKeyboardWatcher uses non-consuming 'V' hook (clickhold-inputhook-drops-keys)", _GKWS_InputHookIsNonConsuming)
