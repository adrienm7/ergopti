; tests/meta/test_path_dialog_button_race.ahk

; ==============================================================================
; MODULE: Path Dialog Button Race Regression
; DESCRIPTION:
; Pins the one-shot button-renaming timer to a behaviorally tested boundary.
; The path-copy MsgBox may close between existence, activation, and control
; mutation; every lost-window outcome must return normally from the timer.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Timer Callback Wiring ========
; =========================================
; =========================================

_PDBR_ChangeButtonNamesUsesRaceBoundary() {
	Body := _DriverFuncBody("ChangeButtonNames")
	Assert(Body != "", "ChangeButtonNames must exist in the Windows shortcuts module")
	Assert(InStr(Body, "_ChangeButtonNamesWith(") > 0,
		"the one-shot timer callback must delegate its window effects to the tested race boundary")
}
Test("shortcuts: path dialog button rename uses race boundary (path-dialog-button-race)",
	_PDBR_ChangeButtonNamesUsesRaceBoundary)
