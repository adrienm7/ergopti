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




; ==================================================
; ==================================================
; ======= 2/ Guard assertion =======================
; ==================================================
; ==================================================

_DPSG_DequeuePollHasSuspendGuard() {
	Seg := _DriverFuncBody("_TooltipDequeuePollFn")
	Assert(Seg != "", "_TooltipDequeuePollFn() declaration must exist in the driver source")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"_TooltipDequeuePollFn must check A_IsSuspended -- SetTimer bypasses native Suspend; without this the dequeue poll repaints a tooltip while the driver is paused")
}
Test("tooltip: _TooltipDequeuePollFn has an A_IsSuspended pause guard (dequeue-poll-no-suspend-guard)", _DPSG_DequeuePollHasSuspendGuard)





; ==================================================
; ==================================================
; ======= 3/ Dead poll counter stays deleted =======
; ==================================================
; ==================================================

; The poll fires 10x/s for the entire process lifetime, so anything it does per
; tick is paid ~864 000 times a day. A `static _PollCount` was incremented on
; every one of those ticks and read NOWHERE in the driver (conventions 5.6 --
; no unused code). It was removed by the 2026-07-21 perf pass; this guard keeps
; it from creeping back, and pins the ordering that makes the tick cheap: the
; suspend bail-out must stay the FIRST statement, so a paused driver spends one
; boolean test per tick and nothing else.
_DPSG_DequeuePollHasNoDeadCounter() {
	Seg := _DriverFuncBody("_TooltipDequeuePollFn")
	Assert(Seg != "", "_TooltipDequeuePollFn() declaration must exist in the driver source")
	Assert(InStr(Seg, "_PollCount") == 0,
		"_TooltipDequeuePollFn must not carry a dead poll counter -- _PollCount was incremented 10x/s and never read (conventions 5.6)")
	SuspendPos := InStr(Seg, "A_IsSuspended")
	ItemsPos := InStr(Seg, "_TooltipDequeueItems == 0")
	Assert(ItemsPos > 0, "_TooltipDequeuePollFn must still early-out on an empty dequeue set")
	Assert(SuspendPos < ItemsPos,
		"the A_IsSuspended bail-out must stay the first statement of the tick, so a paused driver pays one boolean test and nothing more")
}
Test("tooltip: the dequeue poll tick carries no dead counter (perf-2026-07-21)", _DPSG_DequeuePollHasNoDeadCounter)
