; tests/meta/test_gesture_click_hold_transaction.ahk

; ==============================================================================
; MODULE: Gesture Click-Hold Transaction Meta Test
; DESCRIPTION:
; Guards the click-hold acquisition and release transaction.
;
; A synthetic mouse button must be the final successful setup step because a
; failed InputHook or HookDispatcher registration after Click Down leaves Windows
; dragging indefinitely. The release path must also clear state and execute its
; matching Up through a finally-owned transaction.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================
; ====================================================
; ======= 1/ Transaction ordering assertions =========
; ====================================================
; ====================================================

_GCHT_AssertTransaction(Button, ToggleName, ReleaseName, FlagName) {
	Q := Chr(34)
	ToggleBody := _DriverFuncBody(ToggleName)
	ReleaseBody := _DriverFuncBody(ReleaseName)
	Assert(ToggleBody != "", ToggleName . " must exist")
	Assert(ReleaseBody != "", ReleaseName . " must exist")
	Down := "Click(" . Q . Button . Q . ", " . Q . "Down" . Q . ")"
	Up := "Click(" . Q . Button . Q . ", " . Q . "Up" . Q . ")"
	DownIdx := InStr(ToggleBody, Down)
	StartIdx := InStr(ToggleBody, "GestureStartKeyboardWatcher()")
	FirstRegisterIdx := InStr(ToggleBody, "HookDispatcher.Register")
	CatchIdx := InStr(ToggleBody, "catch as e")
	Assert(DownIdx > StartIdx and DownIdx > FirstRegisterIdx,
		ToggleName . " must acquire " . Button . " only after watcher and dispatcher setup (gesture-click-hold-transaction)")
	Assert(CatchIdx > DownIdx and InStr(SubStr(ToggleBody, CatchIdx), Up) > 0,
		ToggleName . " rollback must issue " . Button . " Up after a setup failure (gesture-click-hold-transaction)")
	Assert(InStr(SubStr(ToggleBody, DownIdx), FlagName . " := True") > 0,
		ToggleName . " must publish held state only after the matching Down (gesture-click-hold-transaction)")
	Assert(InStr(ReleaseBody, "finally") > 0 and InStr(ReleaseBody, Up) > 0,
		ReleaseName . " must retain a finally-owned matching Up path (gesture-click-hold-transaction)")
}

_GCHT_LeftTransaction() {
	_GCHT_AssertTransaction("Left", "GestureToggleLeftClick", "GestureReleaseLeftClick", "GestureLeftClickHeld")
}
Test("gestures: left click-hold acquires only after setup and rolls back on failure (gesture-click-hold-transaction)", _GCHT_LeftTransaction)

_GCHT_RightTransaction() {
	_GCHT_AssertTransaction("Right", "GestureToggleRightClick", "GestureReleaseRightClick", "GestureRightClickHeld")
}
Test("gestures: right click-hold acquires only after setup and rolls back on failure (gesture-click-hold-transaction)", _GCHT_RightTransaction)
