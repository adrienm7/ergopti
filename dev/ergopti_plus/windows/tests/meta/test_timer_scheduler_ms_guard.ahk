; tests/meta/test_timer_scheduler_ms_guard.ahk

; ==============================================================================
; MODULE: TimerEvery Invalid-Duration Guard
; DESCRIPTION:
; Static ordering guard for TimerEvery duration validation in
; adapters/timer_scheduler.ahk.
;
; ROOT CAUSE ENCODED:
; SetTimer with a period of 0 in AHK v2 does not create a one-shot timer —
; it actually removes the existing timer for the given function. If a caller
; passed IntervalSec = 0 or a very small value that rounded down to 0 ms,
; TimerEvery would silently unregister the timer. Clamping it to 1 ms instead
; creates an accidental hot loop. The adapter must reject the duration before
; allocating a handle or calling SetTimer.
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
; ======= 1/ TimerEvery validates before ownership =============
; ==============================================================
; ==============================================================

_TTSMG_MsZeroGuard() {
	Src := _TTSMG_StripLineComments(_TTSMG_ReadSource("adapters/timer_scheduler.ahk"))
	Assert(Src != "", "adapters/timer_scheduler.ahk must be readable")

	Body := _DriverFuncBody("TimerEvery")
	Assert(Body != "", "TimerEvery must be defined in adapters/timer_scheduler.ahk")

	ValidatePos := InStr(Body, "_TimerAdapterDurationMs(IntervalSec")
	AllocatePos := InStr(Body, "_TimerAdapterNextId()")
	NativePos := InStr(Body, "_TimerAdapterCommitNative(Handle, BoundFn, Ms)")
	Assert(ValidatePos > 0, "TimerEvery must use the strict duration validator")
	Assert(AllocatePos > ValidatePos,
		"TimerEvery must reject invalid duration before allocating handle ownership")
	Assert(NativePos > AllocatePos,
		"native registration must remain after validation and handle construction")
	CommitBody := _DriverFuncBody("_TimerAdapterCommitNative")
	NativeBody := _DriverFuncBody("_TimerAdapterSetNative")
	Assert(InStr(CommitBody, "NativeSetFn.Call(BoundFn, IntervalMs)") > 0
			&& InStr(NativeBody, "SetTimer(BoundFn, IntervalMs)") > 0,
		"the atomic registration helper must still reach the native SetTimer primitive")
	Validator := _DriverFuncBody("_TimerAdapterDurationMs")
	AssertContains(Validator, "Ms < 1",
		"sub-millisecond durations that round to zero must be rejected, not clamped")
}
Test("timer_scheduler: TimerEvery rejects invalid duration before ownership (timer-duration-validation)",
	_TTSMG_MsZeroGuard)
