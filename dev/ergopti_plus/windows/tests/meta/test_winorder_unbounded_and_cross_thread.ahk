; tests/meta/test_winorder_unbounded_and_cross_thread.ahk

; ==============================================================================
; MODULE: Gesture Window-Order Cap Meta Test
; DESCRIPTION:
; Static source guard for the winorder-unbounded-and-cross-thread finding.
;
; _GestureOnForeground is a WinEvent OUTOFCONTEXT callback fired on every
; foreground change. It rebuilds _GestureWinOrder by prepending the new HWND
; and copying the rest. Without an upper bound, a machine left running for days
; opening/closing thousands of transient windows accumulates thousands of stale
; HWNDs; each win_next/win_prev gesture then pays an O(n) prune over that list
; and memory slowly climbs.
;
; The fix introduces a GESTURE_WIN_ORDER_MAX cap and breaks the copy loop once
; the cap is reached, plus an A_IsSuspended early-return so the tracker does not
; churn while the driver is paused. This is a meta-static test (scans source
; text) because _GestureOnForeground is a top-level WinEvent callback with OS
; side effects and cannot be exercised on the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.




; ==================================================
; ==================================================
; ======= 2/ Cap + suspend guard assertions ========
; ==================================================
; ==================================================

_WUCT_CapConstantExists() {
	Src := _DriverDirConcat("modules/gestures")
	Assert(InStr(Src, "GESTURE_WIN_ORDER_MAX") > 0,
		"gestures.ahk must define a GESTURE_WIN_ORDER_MAX cap so _GestureWinOrder cannot grow unbounded on long-running sessions")
}
Test("gestures: GESTURE_WIN_ORDER_MAX cap constant exists (winorder-unbounded-and-cross-thread)", _WUCT_CapConstantExists)

_WUCT_OnForegroundCapsLength() {
	Src := _DriverDirConcat("modules/gestures")
	Seg := _DriverFuncBody("_GestureOnForeground")
	Assert(Seg != "", "_GestureOnForeground declaration must exist in gestures.ahk")
	Assert(InStr(Seg, "GESTURE_WIN_ORDER_MAX") > 0,
		"_GestureOnForeground must bound its rebuild by GESTURE_WIN_ORDER_MAX — without the cap the recency list grows without limit and each gesture pays an O(n) prune")
}
Test("gestures: _GestureOnForeground caps _GestureWinOrder length (winorder-unbounded-and-cross-thread)", _WUCT_OnForegroundCapsLength)

_WUCT_OnForegroundHasSuspendGuard() {
	Src := _DriverDirConcat("modules/gestures")
	Seg := _DriverFuncBody("_GestureOnForeground")
	Assert(Seg != "", "_GestureOnForeground declaration must exist in gestures.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"_GestureOnForeground must early-return on A_IsSuspended so the recency tracker does not churn while the driver is paused")
}
Test("gestures: _GestureOnForeground has an A_IsSuspended guard (winorder-unbounded-and-cross-thread)", _WUCT_OnForegroundHasSuspendGuard)
