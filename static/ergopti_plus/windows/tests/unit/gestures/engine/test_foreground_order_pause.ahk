; tests/unit/gestures/engine/test_foreground_order_pause.ahk

; ==============================================================================
; MODULE: Gesture Window-Order Tracker Cap and Pause
; DESCRIPTION:
; _GestureOnForeground is the WinEvent callback that keeps the recency order
; window cycling walks (winorder-unbounded-and-cross-thread). WinEvent hooks
; keep firing under native Suspend, so a paused driver must leave the order
; untouched: the recency it would record is stale by the resume. A running
; callback prepends the new window and drops entries past GESTURE_WIN_ORDER_MAX,
; so a long session cannot grow the list without bound. The callback is fed
; plain HWND numbers; no window is created, focused or activated.
; ==============================================================================

#Requires AutoHotkey v2.0

_GFOP_Deliver(HWnd) {
	; EVENT_SYSTEM_FOREGROUND for a window object (IdObject 0).
	_GestureOnForeground(0, 0x0003, HWnd, 0, 0, 0, 0)
}

_GFOP_PausedForegroundKeepsOrder() {
	global _GestureWinOrder, _GestureCycling, _GestureSelfActivated, GESTURE_WIN_ORDER_MAX
	Saved := [_GestureWinOrder, _GestureCycling, _GestureSelfActivated]
	WasSuspended := A_IsSuspended
	try {
		_GestureCycling := false
		_GestureSelfActivated := Map()
		_GestureWinOrder := [0x1101, 0x1102]
		Suspend(true)
		_GFOP_Deliver(0x1103)
		AssertEqual(2, _GestureWinOrder.Length, "a paused foreground change must not record a window")
		AssertEqual(0x1101, _GestureWinOrder[1], "a paused foreground change must keep the recency order")

		Suspend(false)
		_GFOP_Deliver(0x1103)
		AssertEqual(3, _GestureWinOrder.Length, "positive control: a running foreground change records its window")
		AssertEqual(0x1103, _GestureWinOrder[1], "the newest foreground window comes first")

		Full := []
		loop GESTURE_WIN_ORDER_MAX
			Full.Push(0x2000 + A_Index)
		_GestureWinOrder := Full
		_GFOP_Deliver(0x3001)
		AssertEqual(GESTURE_WIN_ORDER_MAX, _GestureWinOrder.Length,
			"the recency order must stay within GESTURE_WIN_ORDER_MAX")
		AssertEqual(0x3001, _GestureWinOrder[1], "a capped order still records the newest window first")
		AssertEqual(0x2000 + GESTURE_WIN_ORDER_MAX - 1, _GestureWinOrder[GESTURE_WIN_ORDER_MAX],
			"a capped order drops its oldest entry")
	} finally {
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		_GestureWinOrder := Saved[1]
		_GestureCycling := Saved[2]
		_GestureSelfActivated := Saved[3]
	}
}
Test("gestures: a paused foreground change keeps the capped window order (winorder-unbounded-and-cross-thread)",
	_GFOP_PausedForegroundKeepsOrder)
