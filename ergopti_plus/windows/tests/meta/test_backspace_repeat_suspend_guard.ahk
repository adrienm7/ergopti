; tests/meta/test_backspace_repeat_suspend_guard.ahk

; ==============================================================================
; MODULE: BackSpace Key-Repeat Suspend Guard Meta Test
; DESCRIPTION:
; Regression guard for LOW-01: backspace key-repeat ignored suspend.
;
; The plain-backspace key-repeat loops on LAlt (SC038) and RCtrl (SC11D) spin
; "while KS_IsDown(...)" sending a BackSpace each iteration. AHK SetTimer/Hotkey
; callbacks bypass native Suspend, so once the loop was running, toggling the
; script to suspended (password field, manual pause) did NOT stop the deletes —
; the loop kept eating characters until the physical key was released.
;
; The fix adds "if A_IsSuspended\n\tbreak" as the first statement of each loop
; body so a suspend mid-repeat aborts the deletion. This test extracts each loop
; body and asserts the A_IsSuspended check is present, so a regression that drops
; the guard fails CI.
;
; SCOPE: source introspection of platform/remap/lalt.ahk and rctrl.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Extracts a brace-delimited block whose header contains Marker, via balanced
; brace-walking from the first "{" after the marker.
_BRSG_BlockBody(Src, Marker) {
	Idx := InStr(Src, Marker)
	if (!Idx)
		return ""
	OpenPos := InStr(Src, "{", , Idx)
	if (!OpenPos)
		return ""
	depth := 0
	i := OpenPos
	Len := StrLen(Src)
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0)
				return SubStr(Src, Idx, i - Idx + 1)
		}
		i++
	}
	return SubStr(Src, Idx)
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertions ======================
; ==================================================
; ==================================================

_BRSG_LAltLoopGuarded() {
	Src := _DriverSourceConcat()
	LoopBody := _BRSG_BlockBody(Src, "while KS_IsDown(" . Chr(34) . "SC038" . Chr(34) . ")")
	Assert(LoopBody != "", "LAlt backspace-repeat loop (while KS_IsDown(SC038)) must exist in lalt.ahk")
	Assert(InStr(LoopBody, "A_IsSuspended") > 0,
		"LAlt backspace-repeat loop must break on A_IsSuspended so a suspend mid-repeat stops the deletes (LOW-01)")
}

_BRSG_RCtrlLoopGuarded() {
	Src := _DriverSourceConcat()
	LoopBody := _BRSG_BlockBody(Src, "while KS_IsDown(" . Chr(34) . "SC11D" . Chr(34) . ")")
	Assert(LoopBody != "", "RCtrl backspace-repeat loop (while KS_IsDown(SC11D)) must exist in rctrl.ahk")
	Assert(InStr(LoopBody, "A_IsSuspended") > 0,
		"RCtrl backspace-repeat loop must break on A_IsSuspended so a suspend mid-repeat stops the deletes (LOW-01)")
}

Test("meta backspace-repeat-suspend: LAlt loop breaks on A_IsSuspended (LOW-01)", _BRSG_LAltLoopGuarded)
Test("meta backspace-repeat-suspend: RCtrl loop breaks on A_IsSuspended (LOW-01)", _BRSG_RCtrlLoopGuarded)
