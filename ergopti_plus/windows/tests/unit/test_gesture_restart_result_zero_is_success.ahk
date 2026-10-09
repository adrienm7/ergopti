; tests/unit/test_gesture_restart_result_zero_is_success.ahk

; ==============================================================================
; MODULE: Gesture Touchpad-Restart Result Parsing Regression Test
; DESCRIPTION:
; Regression guard for gesture-restart-zero-reads-as-false: a SUCCESSFUL
; touchpad restart was always reported to the user as a failure.
;
; ROOT CAUSE ENCODED: _GestureRestartReadResult received a `String|false` from
; FSRead and compared it against `false` with the loose `=` operator. The
; PowerShell helper writes its exit code as a bare string
; ([System.IO.File]::WriteAllText, no newline) and SUCCESS is "0" — a numeric
; string, so comparing it loosely against false yields TRUE in AHK v2. Every run
; took the "result missing" branch, logged an ERROR and returned False, which
; made the `return (Result = "0")` success path unreachable. Failure runs write
; "1" and were correct only by accident.
;
; The invariant this pins is about TYPES, not values: the success payload and
; the failure sentinel must be distinguished with `is String`, because there is
; no value comparison that can separate the string "0" from boolean false.
;
; SCOPE: behavioural. modules/gestures/config.ahk is loaded by run_all.ahk, so
; the function is called directly against real temp files — no source scan, so
; the test cannot be fooled by a comment mentioning the operator.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ The exit code the helper really writes ================
; ==================================================================
; ==================================================================

; Write Content to a scratch file and return its path. Uses a unique name so a
; parallel run cannot collide (tests/meta/test_atomic_write_unique_scratch.ahk
; enforces the same discipline in the driver).
_GRZ_ScratchWith(Content) {
	Path := A_Temp . "\ergopti_grz_" . A_TickCount . "_" . A_Index . ".txt"
	try FileDelete(Path)
	FileAppend(Content, Path, "UTF-8-RAW")
	return Path
}

_GRZ_SuccessCodeIsRead() {
	; Exactly what the helper writes on success: the single character "0", no
	; trailing newline (WriteAllText, not WriteAllLines).
	Path := _GRZ_ScratchWith("0")
	Ok := _GestureRestartReadResult(Path)
	try FileDelete(Path)
	Assert(Ok == true,
		'a result file containing the success code "0" must read as SUCCESS. It reads as failure whenever the '
		. 'String|false return is value-compared against false: "0" = false is TRUE in AHK v2, so the '
		. 'success branch becomes unreachable and a working touchpad restart always reports failure. '
		. 'Type-check with "is String" instead (gesture-restart-zero-reads-as-false)')
}

_GRZ_FailureCodeIsRead() {
	Path := _GRZ_ScratchWith("1")
	Ok := _GestureRestartReadResult(Path)
	try FileDelete(Path)
	Assert(Ok == false,
		"a result file containing a non-zero exit code must read as FAILURE")
}

_GRZ_TrailingWhitespaceStillSucceeds() {
	; Defence in depth: if the helper ever gains a newline, success must survive.
	Path := _GRZ_ScratchWith("0`r`n")
	Ok := _GestureRestartReadResult(Path)
	try FileDelete(Path)
	Assert(Ok == true,
		"the success code must still be recognised with trailing whitespace — the value is trimmed before comparison")
}

_GRZ_MissingFileIsFailure() {
	; The sentinel path: FSRead returns boolean false, which MUST still be
	; treated as "no result published". Fixing the trap must not break this.
	Path := A_Temp . "\ergopti_grz_does_not_exist_" . A_TickCount . ".txt"
	try FileDelete(Path)
	Ok := _GestureRestartReadResult(Path)
	Assert(Ok == false,
		"a missing result file must read as FAILURE — FSRead returns boolean false there, and the type check must "
		. "keep rejecting it")
}


Test('gestures: the touchpad-restart success code "0" is not mistaken for the false sentinel (gesture-restart-zero-reads-as-false)',
	_GRZ_SuccessCodeIsRead)
Test("gestures: a non-zero touchpad-restart exit code reads as failure (gesture-restart-zero-reads-as-false)",
	_GRZ_FailureCodeIsRead)
Test("gestures: the touchpad-restart success code survives trailing whitespace (gesture-restart-zero-reads-as-false)",
	_GRZ_TrailingWhitespaceStillSucceeds)
Test("gestures: a missing touchpad-restart result file still reads as failure (gesture-restart-zero-reads-as-false)",
	_GRZ_MissingFileIsFailure)
