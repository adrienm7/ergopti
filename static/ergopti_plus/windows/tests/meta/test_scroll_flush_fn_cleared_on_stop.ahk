; tests/meta/test_scroll_flush_fn_cleared_on_stop.ahk

; ==============================================================================
; MODULE: Scroll Flush Function Cleared On Stop Meta Test
; DESCRIPTION:
; Static source guard for the T-W10 finding: KL_Mouse_Stop must clear the
; scroll_flush_fn reference after cancelling its timer.
;
; KLMouse.scroll_flush_fn holds a bound function reference that is passed to
; SetTimer as the one-shot scroll-burst flush callback. KL_Mouse_AccumScroll
; and KL_Mouse_AccumScrollH both call SetTimer(KLMouse.scroll_flush_fn, ...)
; to re-arm the timer on every wheel tick. If KL_Mouse_Stop cancels the timer
; but leaves the reference live, a scroll event that fires on the AHK message
; queue between the SetTimer cancel and the subscriber unregister can silently
; re-arm the timer with the stale reference — reintroducing the burst-flush
; timer after the module has been torn down.
;
; The fix: assign `scroll_flush_fn := unset` immediately after the
; SetTimer(..., 0) cancellation so any re-entry during the drain call
; (KL_Mouse_FlushScroll) finds the property unset rather than a live callable.
;
; This is a meta-static test (source scan) because keylogger_mouse.ahk owns
; top-level hotkey subscriptions and cannot be #Included by the headless runner
; without blocking clean exit. If the clear is removed, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helper =====================
; ===================================================
; ===================================================

_SFFC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ===================================================
; ===================================================
; ======= 2/ Guard assertion ========================
; ===================================================
; ===================================================

_SFFC_StopClearsScrollFlushFn() {
	Src  := _SFFC_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	Body := _DriverFuncBody("KL_Mouse_Stop")
	Assert(Body != "", "KL_Mouse_Stop must exist in keylogger_mouse.ahk")
	Assert(InStr(Body, "scroll_flush_fn := unset") > 0,
		"KL_Mouse_Stop must assign scroll_flush_fn := unset after cancelling the timer — without this a late wheel tick arriving during teardown can re-arm a stale reference and keep the flush timer alive past Stop()")
}
Test("keylogger_mouse: KL_Mouse_Stop clears scroll_flush_fn reference", _SFFC_StopClearsScrollFlushFn)
