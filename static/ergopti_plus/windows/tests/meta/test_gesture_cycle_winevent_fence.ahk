; tests/meta/test_gesture_cycle_winevent_fence.ahk

; ==============================================================================
; MODULE: Gesture Window-Cycle Async-WinEvent Fence Meta Test
; DESCRIPTION:
; Static source guard for finding gesture-cycle-winevent-async-fence (F-L04).
;
; GestureCycleWindows / GestureCycleAppWindows set _GestureCycling := True around a
; programmatic GestureActivateWindow, then clear it synchronously. But the
; EVENT_SYSTEM_FOREGROUND for that activation is delivered ASYNCHRONOUSLY via the
; OUTOFCONTEXT WinEvent hook, after the boolean has already been cleared — so
; _GestureOnForeground recorded our own synthetic activation as a manual one,
; corrupting the recency order (win_next/win_prev would ping-pong between two
; windows instead of advancing).
;
; The fix records each programmatically-activated HWND in a _GestureSelfActivated
; set (before SetForegroundWindow) and has _GestureOnForeground consume a matching
; recent HWND to fence the async event. Meta-static because the OUTOFCONTEXT
; callback cannot run on the headless runner and gestures/ is not in its include
; graph.
; ==============================================================================

#Requires AutoHotkey v2.0


_GCWF_AssertAsyncFence() {
	Fg := _DriverFuncBody("_GestureOnForeground")
	Assert(Fg != "", "_GestureOnForeground must exist")
	Assert(InStr(Fg, "_GestureSelfActivated") > 0,
		"_GestureOnForeground must fence the async WinEvent via the self-activated HWND set, not only the synchronously-cleared _GestureCycling boolean (gesture-cycle-winevent-async-fence)")

	Act := _DriverFuncBody("GestureActivateWindow")
	Assert(Act != "", "GestureActivateWindow must exist")
	RecPos := InStr(Act, "_GestureSelfActivated[HWnd]")
	FgPos := InStr(Act, "WMForceForeground(HWnd)")
	Assert(RecPos > 0,
		"GestureActivateWindow must record the HWND in _GestureSelfActivated so the async WinEvent can be fenced (gesture-cycle-winevent-async-fence)")
	Assert(FgPos > 0, "GestureActivateWindow must delegate foreground activation through WMForceForeground")
	Assert(RecPos < FgPos,
		"GestureActivateWindow must record the self-activated HWND BEFORE foreground activation — the WinEvent may fire before the call returns (gesture-cycle-winevent-async-fence)")
	Force := _DriverFuncBody("WMForceForeground")
	Assert(Force != "", "WMForceForeground must exist in the WindowManager adapter")
	Assert(InStr(Force, "SetForegroundWindow") > 0,
		"WMForceForeground must call SetForegroundWindow inside the WindowManager adapter")
}
Test("gestures: window-cycle fences its own async WinEvent via a self-activated HWND set (gesture-cycle-winevent-async-fence)", _GCWF_AssertAsyncFence)
