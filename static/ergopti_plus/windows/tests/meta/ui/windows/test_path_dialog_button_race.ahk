; tests/meta/ui/windows/test_path_dialog_button_race.ahk

; ==============================================================================
; MODULE: Path Dialog Button Race Regression
; DESCRIPTION:
; Pins the one-shot button-renaming timer to a behaviorally tested boundary.
; The path-copy MsgBox may close between existence, activation, and control
; mutation; every lost-window outcome must return normally from the timer.
; The native paths editor also installs its tested definitive cancellation
; before becoming visible, since the default Close only hides its live HWND.
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

_PDBR_NativePathsEditorBindsCancellation() {
	Body := _DriverFuncBody("FilePathsEditor")
	Assert(Body != "", "the native paths editor must exist for its lifecycle wiring guard")
	Bind := InStr(Body, "_PathsEdNative_BindCancellation(W)")
	Shown := InStr(Body, 'W.Show("Center")')
	Assert(Bind > 0 && Shown > Bind,
		"the actual fallback must install its tested cancellation before the window can receive Close or Escape")
}
Test("native paths editor: fallback installs definitive cancellation before show (native-paths-close-cancellation)",
	_PDBR_NativePathsEditorBindsCancellation)
