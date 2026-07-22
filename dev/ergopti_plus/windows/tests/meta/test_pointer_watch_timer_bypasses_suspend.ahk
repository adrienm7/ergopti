; tests/meta/test_pointer_watch_timer_bypasses_suspend.ahk

; ==============================================================================
; MODULE: LLM Pointer-Watch Tick Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for the pointer-watch-timer-bypasses-suspend finding.
;
; _LLM_PointerWatch_OnMoveTick is a recurring 50 ms SetTimer callback. AHK
; SetTimer threads bypass native Suspend, so without an explicit guard the tick
; body (MouseGetPos + branch) keeps firing ~20x/s for the entire pause, even
; though no dismissal occurs. This breaches the "pause = tout eteint" invariant
; and contends -- however slightly -- for the message pump.
;
; The fix adds `if A_IsSuspended return` at the top of the tick so the poll is
; inert while paused. This test scans the function body and asserts the guard
; is present.
;
; Meta-static because modules/keymap/llm_bridge.ahk registers top-level state and
; is not part of the headless run_all include graph.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Suspend-guard assertion ===============
; ==================================================
; ==================================================

_PwtsMoveTickHasSuspendGuard() {
	; Move-resilient: locate _LLM_PointerWatch_OnMoveTick across the whole driver
	; source via the framework helper instead of a pinned llm_bridge.ahk path.
	Seg := _DriverFuncBody("_LLM_PointerWatch_OnMoveTick")
	Assert(Seg != "", "_LLM_PointerWatch_OnMoveTick(*) declaration must exist in llm_bridge.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"_LLM_PointerWatch_OnMoveTick must early-return on A_IsSuspended -- SetTimer threads bypass native Suspend, so the 50 ms MouseGetPos poll would keep firing while paused")
}
Test("LLM: _LLM_PointerWatch_OnMoveTick has an A_IsSuspended pause guard (pointer-watch-timer-bypasses-suspend)", _PwtsMoveTickHasSuspendGuard)
