; tests/meta/test_mouse_suspend_guard.ahk

; ==============================================================================
; MODULE: Mouse Suspend Guard Meta Test
; DESCRIPTION:
; Static source guards for the T-W01 "mouse-handlers-bypass-suspend" finding.
;
; KL_Mouse_OnLUp, KL_Mouse_OnRUp, KL_Mouse_AccumScroll and KL_Mouse_FlushScroll
; are registered via HookDispatcher (mouse button hooks) and SetTimer (scroll
; burst flush). None of these paths go through KL_AppendLog's chokepoint guard
; before reaching KL_BumpMouseClick or writing telemetry — they bypass native
; AHK Suspend and fire regardless of A_IsSuspended.
;
; The fixes:
; 1. KL_Mouse_OnLUp / KL_Mouse_OnRUp: add `if A_IsSuspended { ... return }`
;    BEFORE the call to KL_BumpMouseClick so click-distance counters are not
;    bumped while the driver is paused.
; 2. KL_Mouse_AccumScroll: add `if A_IsSuspended return` at the top so scroll
;    ticks are not accumulated and no timer is armed while paused.
; 3. KL_Mouse_FlushScroll: add `if A_IsSuspended return` at the top so a timer
;    that slipped through the pause transition cannot flush stale scroll data.
; 4. KL_Mouse_Stop: `scroll_flush_fn := unset` must appear after the timer
;    cancellation so re-entry cannot re-arm a stale timer reference.
;
; This is a meta-static test (scans source text) because keylogger_mouse.ahk
; registers top-level HookDispatcher subscribers and cannot be #Included by the
; headless runner without pulling in the full driver.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

_MMSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}





; ====================================================
; ====================================================
; ======= 2/ Suspend-guard ordering assertions =======
; ====================================================
; ====================================================

_MMSG_LUpGuardBeforeBump() {
	Src := _MMSG_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	Body := _DriverFuncBody("KL_Mouse_OnLUp")
	Assert(Body != "", "KL_Mouse_OnLUp must exist in keylogger_mouse.ahk")
	PosGuard := InStr(Body, "A_IsSuspended")
	PosBump  := InStr(Body, "KL_BumpMouseClick")
	Assert(PosGuard > 0,
		"KL_Mouse_OnLUp must check A_IsSuspended — mouse button hooks bypass Suspend; without this guard KL_BumpMouseClick fires while the driver is paused")
	Assert(PosBump > 0,
		"KL_Mouse_OnLUp must call KL_BumpMouseClick")
	Assert(PosGuard < PosBump,
		"KL_Mouse_OnLUp: A_IsSuspended guard must appear BEFORE KL_BumpMouseClick so the click counter is not bumped while paused")
}
Test("mouse: KL_Mouse_OnLUp has A_IsSuspended guard before KL_BumpMouseClick", _MMSG_LUpGuardBeforeBump)


_MMSG_RUpGuardBeforeBump() {
	Src := _MMSG_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	Body := _DriverFuncBody("KL_Mouse_OnRUp")
	Assert(Body != "", "KL_Mouse_OnRUp must exist in keylogger_mouse.ahk")
	PosGuard := InStr(Body, "A_IsSuspended")
	PosBump  := InStr(Body, "KL_BumpMouseClick")
	Assert(PosGuard > 0,
		"KL_Mouse_OnRUp must check A_IsSuspended — mouse button hooks bypass Suspend; without this guard KL_BumpMouseClick fires while the driver is paused")
	Assert(PosBump > 0,
		"KL_Mouse_OnRUp must call KL_BumpMouseClick")
	Assert(PosGuard < PosBump,
		"KL_Mouse_OnRUp: A_IsSuspended guard must appear BEFORE KL_BumpMouseClick so the click counter is not bumped while paused")
}
Test("mouse: KL_Mouse_OnRUp has A_IsSuspended guard before KL_BumpMouseClick", _MMSG_RUpGuardBeforeBump)


_MMSG_AccumScrollHasSuspendGuard() {
	Src := _MMSG_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	Body := _DriverFuncBody("KL_Mouse_AccumScroll")
	Assert(Body != "", "KL_Mouse_AccumScroll must exist in keylogger_mouse.ahk")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"KL_Mouse_AccumScroll must check A_IsSuspended — SetTimer-backed scroll accumulation bypasses Suspend; without this guard ticks are counted and a flush timer is armed while paused")
}
Test("mouse: KL_Mouse_AccumScroll has A_IsSuspended guard", _MMSG_AccumScrollHasSuspendGuard)


_MMSG_FlushScrollHasSuspendGuard() {
	Src := _MMSG_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	Body := _DriverFuncBody("KL_Mouse_FlushScroll")
	Assert(Body != "", "KL_Mouse_FlushScroll must exist in keylogger_mouse.ahk")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"KL_Mouse_FlushScroll must check A_IsSuspended — a one-shot timer armed before pause fires after Suspend is set; without this guard stale scroll data is flushed to the log while paused")
}
Test("mouse: KL_Mouse_FlushScroll has A_IsSuspended guard", _MMSG_FlushScrollHasSuspendGuard)


; keylogger-mouse-scroll-suspend-reset: unlike KL_Mouse_ParkTick (which resets
; prev_x/prev_y/park_last_x on its suspended path), KL_Mouse_FlushScroll's
; A_IsSuspended branch used to return without clearing scroll_start/scroll_last.
; A one-shot flush timer armed just before a Suspend, then firing WHILE
; suspended, left those timestamps stale for the whole pause window; the next
; post-resume scroll then flushed a duration/velocity spanning the entire pause
; instead of just the burst that actually occurred.
_MMSG_FlushScrollResetsAccumulatorWhenSuspended() {
	Body := _DriverFuncBody("KL_Mouse_FlushScroll")
	Assert(Body != "", "KL_Mouse_FlushScroll must exist in keylogger_mouse.ahk")

	GuardPos := InStr(Body, "A_IsSuspended")
	Assert(GuardPos > 0, "KL_Mouse_FlushScroll must check A_IsSuspended")

	; All four accumulator fields must be reset, and the reset must happen
	; INSIDE the suspended branch (before its own "return"), not merely
	; somewhere later in the function (that would only cover the non-suspended path).
	SuspendedBranchEnd := InStr(Body, "return", , GuardPos)
	Assert(SuspendedBranchEnd > 0, "KL_Mouse_FlushScroll's A_IsSuspended branch must contain a return")
	SuspendedBranch := SubStr(Body, GuardPos, SuspendedBranchEnd - GuardPos)

	; Column-aligned assignments (KLMouse.scroll_ticks   := 0) use variable
	; whitespace before `:=`, matching the existing non-suspended reset block's
	; style — tolerate any run of spaces there instead of assuming exactly one.
	for _, Field in ["scroll_ticks", "scroll_h_ticks", "scroll_start", "scroll_last"]
		Assert(RegExMatch(SuspendedBranch, "KLMouse\." . Field . "\s*:=\s*0"),
			"KL_Mouse_FlushScroll's A_IsSuspended branch must reset KLMouse." . Field
			. " := 0 before returning — mirroring KL_Mouse_ParkTick's own suspended-path "
			. "reset — otherwise stale pre-suspend timestamps corrupt the next post-resume "
			. "flush's duration/velocity (keylogger-mouse-scroll-suspend-reset)")
}
Test("mouse: KL_Mouse_FlushScroll resets the scroll accumulator on its suspended path (keylogger-mouse-scroll-suspend-reset)",
	_MMSG_FlushScrollResetsAccumulatorWhenSuspended)


_MMSG_StopClearsScrollFlushFn() {
	Src := _MMSG_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	Body := _DriverFuncBody("KL_Mouse_Stop")
	Assert(Body != "", "KL_Mouse_Stop must exist in keylogger_mouse.ahk")
	Assert(InStr(Body, "scroll_flush_fn := unset") > 0,
		"KL_Mouse_Stop must set scroll_flush_fn := unset after cancelling the timer so re-entry cannot re-arm the stale bound reference")
}
Test("mouse: KL_Mouse_Stop clears scroll_flush_fn after cancellation", _MMSG_StopClearsScrollFlushFn)


; F-M09: the privacy filter (MF_ShouldFilter) must run BEFORE the counter bump, so a
; click/scroll in a password field / disabled app / private-browsing window does not
; accrue into session_clicks/session_scrolls — counts that ride into a later typing row.
; This is distinct from the suspend ordering above (which guards A_IsSuspended).
_MMSG_LUpFilterBeforeBump() {
	Body := _DriverFuncBody("KL_Mouse_OnLUp")
	PosFilter := InStr(Body, "MF_ShouldFilter")
	PosBump   := InStr(Body, "KL_BumpMouseClick")
	Assert(PosFilter > 0 and PosBump > 0 and PosFilter < PosBump,
		"KL_Mouse_OnLUp must consult MF_ShouldFilter BEFORE KL_BumpMouseClick so a filtered window does not bump the click count (mouse-counter-privacy-filter)")
}
Test("mouse: KL_Mouse_OnLUp filters before bumping the click count (mouse-counter-privacy-filter)", _MMSG_LUpFilterBeforeBump)

_MMSG_RUpFilterBeforeBump() {
	Body := _DriverFuncBody("KL_Mouse_OnRUp")
	PosFilter := InStr(Body, "MF_ShouldFilter")
	PosBump   := InStr(Body, "KL_BumpMouseClick")
	Assert(PosFilter > 0 and PosBump > 0 and PosFilter < PosBump,
		"KL_Mouse_OnRUp must consult MF_ShouldFilter BEFORE KL_BumpMouseClick (mouse-counter-privacy-filter)")
}
Test("mouse: KL_Mouse_OnRUp filters before bumping the click count (mouse-counter-privacy-filter)", _MMSG_RUpFilterBeforeBump)

_MMSG_MUpFilterBeforeBump() {
	Body := _DriverFuncBody("KL_Mouse_OnMUp")
	PosFilter := InStr(Body, "MF_ShouldFilter")
	PosBump   := InStr(Body, "KL_BumpMouseClick")
	Assert(PosFilter > 0 and PosBump > 0 and PosFilter < PosBump,
		"KL_Mouse_OnMUp must consult MF_ShouldFilter BEFORE KL_BumpMouseClick (mouse-counter-privacy-filter)")
}
Test("mouse: KL_Mouse_OnMUp filters before bumping the click count (mouse-counter-privacy-filter)", _MMSG_MUpFilterBeforeBump)

_MMSG_AccumScrollFiltersBeforeBump() {
	Body := _DriverFuncBody("KL_Mouse_AccumScroll")
	PosFilter := InStr(Body, "MF_ShouldFilter")
	PosBump   := InStr(Body, "KL_BumpMouseScroll")
	Assert(PosFilter > 0 and PosBump > 0 and PosFilter < PosBump,
		"KL_Mouse_AccumScroll must consult MF_ShouldFilter BEFORE KL_BumpMouseScroll so a filtered window does not bump the scroll count (mouse-counter-privacy-filter)")
}
Test("mouse: KL_Mouse_AccumScroll filters before bumping the scroll count (mouse-counter-privacy-filter)", _MMSG_AccumScrollFiltersBeforeBump)

_MMSG_AccumScrollHFiltersBeforeBump() {
	Body := _DriverFuncBody("KL_Mouse_AccumScrollH")
	PosFilter := InStr(Body, "MF_ShouldFilter")
	PosBump   := InStr(Body, "KL_BumpMouseScroll")
	Assert(PosFilter > 0 and PosBump > 0 and PosFilter < PosBump,
		"KL_Mouse_AccumScrollH must consult MF_ShouldFilter BEFORE KL_BumpMouseScroll (mouse-counter-privacy-filter)")
}
Test("mouse: KL_Mouse_AccumScrollH filters before bumping the scroll count (mouse-counter-privacy-filter)", _MMSG_AccumScrollHFiltersBeforeBump)
