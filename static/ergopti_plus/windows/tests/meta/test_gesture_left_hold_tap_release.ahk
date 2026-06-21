; tests/meta/test_gesture_left_hold_tap_release.ahk

; ==============================================================================
; MODULE: Gesture Left-Hold Tap-Release Meta Test
; DESCRIPTION:
; Regression guard for gesture-left-hold-tap-release.
;
; A held synthetic left-click (triple-tap -> GestureToggleLeftClick) used to be
; released only by a right-click or a keystroke, never by a one-finger tap (a
; physical left-click). So after engaging the hold, a one-finger tap left it
; active and the next triple-tap toggled the stale hold OFF instead of
; re-engaging a fresh left-click-down -- the user saw alternating "works /
; nothing / works".
;
; The fix subscribes the left hold to mouse_ldown as well as mouse_rdown via
; HookDispatcher, so a one-finger tap releases it; teardown unsubscribes both.
; These guards assert both halves so the release-on-tap behaviour cannot
; silently regress. They introspect the function bodies via the move-resilient
; _DriverFuncBody helper, so they survive any future file move.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================================
; =========================================================
; ======= 1/ Engage subscribes the tap-release path =======
; =========================================================
; =========================================================

_GLHTR_ToggleLeftSubscribesLDown() {
	Body := _DriverFuncBody("GestureToggleLeftClick")
	Assert(Body != "", "GestureToggleLeftClick must exist in the gestures driver")
	Assert(InStr(Body, 'HookDispatcher.Register("mouse_ldown", GestureReleaseLeftClick)') > 0,
		"GestureToggleLeftClick must subscribe mouse_ldown so a one-finger tap (left-click) releases the left hold (gesture-left-hold-tap-release)")
	Assert(InStr(Body, 'HookDispatcher.Register("mouse_rdown", GestureReleaseLeftClick)') > 0,
		"GestureToggleLeftClick must keep the mouse_rdown (right-click) release path (gesture-left-hold-tap-release)")
}
Test("gestures: left hold releases on a one-finger tap via mouse_ldown (gesture-left-hold-tap-release)", _GLHTR_ToggleLeftSubscribesLDown)





; ============================================================
; ============================================================
; ======= 2/ Release unsubscribes the tap-release path =======
; ============================================================
; ============================================================

_GLHTR_ReleaseLeftUnsubscribesLDown() {
	Body := _DriverFuncBody("GestureReleaseLeftClick")
	Assert(Body != "", "GestureReleaseLeftClick must exist in the gestures driver")
	Assert(InStr(Body, 'HookDispatcher.Unregister("mouse_ldown", GestureReleaseLeftClick)') > 0,
		"GestureReleaseLeftClick must unsubscribe mouse_ldown on teardown (gesture-left-hold-tap-release)")
}
Test("gestures: left hold unsubscribes mouse_ldown on release (gesture-left-hold-tap-release)", _GLHTR_ReleaseLeftUnsubscribesLDown)
