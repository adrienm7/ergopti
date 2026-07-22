; tests/meta/test_timer_scheduler_ms_guard.ahk

; ==============================================================================
; MODULE: TimerEvery Ms <= 0 Guard
; DESCRIPTION:
; Static source guard for the TimerEvery Ms <= 0 guard fix in
; adapters/timer_scheduler.ahk.
;
; ROOT CAUSE ENCODED:
; SetTimer with a period of 0 in AHK v2 does not create a one-shot timer —
; it actually removes the existing timer for the given function. If a caller
; passed IntervalSec = 0 or a very small value that rounded down to 0 ms,
; TimerEvery would silently unregister the timer instead of creating a periodic
; one. The fix adds a guard: if Ms <= 0, set Ms := 1 to ensure the minimum
; viable interval.
; ==============================================================================

#Requires AutoHotkey v2.0

_TTSMG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TTSMG_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ==============================================================
; ==============================================================
; ======= 1/ TimerEvery guards against Ms <= 0 =================
; ==============================================================
; ==============================================================

_TTSMG_MsZeroGuard() {
	Src := _TTSMG_StripLineComments(_TTSMG_ReadSource("adapters/timer_scheduler.ahk"))
	Assert(Src != "", "adapters/timer_scheduler.ahk must be readable")

	Body := _DriverFuncBody("TimerEvery")
	Assert(Body != "", "TimerEvery must be defined in adapters/timer_scheduler.ahk")

	; The guard must be present
	Assert(InStr(Body, "Ms <= 0") > 0,
		"TimerEvery must guard against Ms <= 0 to prevent SetTimer(fn, 0) from silently removing the timer")

	; The correction must set Ms to 1
	Assert(InStr(Body, "Ms := 1") > 0,
		"TimerEvery must set Ms := 1 when Ms <= 0 to enforce a minimum viable interval")
}
Test("timer_scheduler: TimerEvery clamps Ms to 1 when the computed value is <= 0", _TTSMG_MsZeroGuard)
