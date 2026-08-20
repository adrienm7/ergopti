; tests/meta/test_getselection_blocks_and_eats_keys.ahk

; ==============================================================================
; MODULE: GetSelection Fail-Fast ClipWait Guard Meta Test
; DESCRIPTION:
; Static source guard for the finding getselection-blocks-and-eats-keys.
;
; Selection capture runs from case-conversion, search, and gesture actions.
; A synchronous ClipWait stalls the AHK input thread, so completion must be
; polled asynchronously and stale callbacks must be cancelled on new input.
;
; The fix starts Ctrl+C then polls ClipWait(0, 1) from a timer. It captures the
; foreground window, detects physical input, and invokes the continuation only
; while that original context remains valid.
;
; This is a meta-static test: GetSelection touches the real clipboard
; (ClipboardAll / A_Clipboard / ClipWait), so a direct behavioral call is
; unsafe in the headless runner. The test scans hotstring_engine.ahk source
; text instead. If the ClipWait return check is removed, or the timeout is
; raised back toward the old 2 s exposure window, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_GSBlk_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Fail-fast ClipWait guard assertions ===
; ==================================================
; ==================================================

; The public capture API must arm a timer rather than call blocking ClipWait.
_GSBlk_GetSelectionIsTimerDriven() {
	Src := _GSBlk_ReadSource("infra/hotstrings/hotstring_engine.ahk")
	Seg := _DriverFuncBody("GetSelectionAsync")
	Assert(Seg != "", "GetSelectionAsync() declaration must exist in hotstring_engine.ahk")
	Assert(InStr(Seg, "SetTimer(Job[") > 0,
		"GetSelectionAsync must arm a timer instead of waiting in the initiating input thread")
	Assert(InStr(Seg, "ClipWait(") = 0,
		"GetSelectionAsync must not call ClipWait synchronously; only the timer poll may make a zero-timeout probe")
}
Test("hotstring_engine: selection capture is timer-driven (getselection-blocks-and-eats-keys)",
	_GSBlk_GetSelectionIsTimerDriven)

; The poll must cancel a stale selection when the user moves on or changes
; window, preventing delayed output from targeting a new selection.
_GSBlk_PollCancelsStaleContexts() {
	Src := _GSBlk_ReadSource("infra/hotstrings/hotstring_engine.ahk")
	Seg := _DriverFuncBody("_SelectionCapturePoll")
	Assert(InStr(Seg, "A_TimeIdlePhysical") > 0 and InStr(Seg, "WinExist") > 0,
		"selection poll must cancel delayed callbacks after physical input or a foreground-window change")
}
Test("hotstring_engine: selection poll cancels stale contexts (getselection-blocks-and-eats-keys)",
	_GSBlk_PollCancelsStaleContexts)

; The four case-conversion actions must use async capture and their completion
; functions must no-op on an empty/failed capture.
_GSBlk_CaseChordsNoOpOnEmpty() {
	WinSrc := _GSBlk_ReadSource("modules/shortcuts/win.ahk")
	GestSrc := _DriverDirConcat("modules/gestures")
	EmptyGuard := "if (Text = " . Chr(34) . Chr(34) . ")"

	UpperSeg := _DriverFuncBody("_ConvertToUppercaseSelection")
	Assert(InStr(UpperSeg, EmptyGuard) > 0,
		"ConvertToUppercase must no-op on an empty selection (no stale SendInstant)")

	TitleSeg := _DriverFuncBody("_ConvertToTitleCaseSelection")
	Assert(InStr(TitleSeg, EmptyGuard) > 0,
		"ConvertToTitleCase must no-op on an empty selection (no stale SendInstant)")

	GUpperSeg := _DriverFuncBody("_GestureToggleUppercaseSelection")
	Assert(InStr(GUpperSeg, EmptyGuard) > 0,
		"GestureToggleUppercase must no-op on an empty selection (no stale SendInstant)")

	GTitleSeg := _DriverFuncBody("_GestureToggleTitleCaseSelection")
	Assert(InStr(GTitleSeg, EmptyGuard) > 0,
		"GestureToggleTitleCase must no-op on an empty selection (no stale SendInstant)")
}
Test("hotstring_engine: async case-conversion callbacks no-op on empty selection (getselection-blocks-and-eats-keys)",
	_GSBlk_CaseChordsNoOpOnEmpty)

_GSBlk_SuspendCancelsPendingCapture() {
	Seg := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(Seg != "", "Ergopti_OnSuspendEnter() must exist in lifecycle.ahk")
	Assert(InStr(Seg, "GetSelectionCancel()") > 0,
		"suspend must cancel an in-flight clipboard selection capture so its timer cannot inject after pause")
}
Test("hotstring_engine: suspend cancels pending async selection capture (getselection-blocks-and-eats-keys)",
	_GSBlk_SuspendCancelsPendingCapture)
