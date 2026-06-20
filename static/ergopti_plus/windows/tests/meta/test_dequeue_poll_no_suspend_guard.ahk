; tests/meta/test_dequeue_poll_no_suspend_guard.ahk

; ==============================================================================
; MODULE: Dequeue Poll Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for the dequeue-poll-no-suspend-guard finding.
;
; _TooltipDequeuePollFn is a 100 ms repeating SetTimer callback. SetTimer
; callbacks BYPASS native Suspend in AHK v2 (Suspend only disarms hotkeys /
; hotstrings), so when suspend is toggled OUTSIDE the driver's own
; ToggleSuspend (e.g. a global Suspend binding), this poll can keep firing for
; up to ~500 ms inside the _SuspendStateWatchdog gap and rebuild / reveal a
; tooltip while the driver is supposed to be silent -- violating the critical
; "pause = AHK eteint" invariant.
;
; The fix adds `if A_IsSuspended return` at the top of the function. This is a
; meta-static test (scans source text) because A_IsSuspended is a read-only
; built-in that cannot be forced in-process and the callback rebuilds a real
; Gui; calling it headless is unsafe. If the guard is removed, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_DPSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the full function body -- from its declaration to the first closing
; brace at column 0. Returns "" when the declaration is absent.
_DPSG_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertion =======================
; ==================================================
; ==================================================

_DPSG_DequeuePollHasSuspendGuard() {
	Src := _DPSG_ReadSource("lib/tooltip.ahk")
	Seg := _DriverFuncBody("_TooltipDequeuePollFn")
	Assert(Seg != "", "_TooltipDequeuePollFn() declaration must exist in tooltip.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"_TooltipDequeuePollFn must check A_IsSuspended -- SetTimer bypasses native Suspend; without this the dequeue poll repaints a tooltip while the driver is paused")
}
Test("tooltip: _TooltipDequeuePollFn has an A_IsSuspended pause guard (dequeue-poll-no-suspend-guard)", _DPSG_DequeuePollHasSuspendGuard)
