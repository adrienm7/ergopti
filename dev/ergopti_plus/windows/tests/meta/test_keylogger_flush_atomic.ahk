; tests/meta/test_keylogger_flush_atomic.ahk

; ==============================================================================
; MODULE: Keylogger Flush Atomic Snapshot Meta Test
; DESCRIPTION:
; Static source guard for the "keylogger-flush-race-condition" audit finding.
;
; ROOT CAUSE ENCODED:
; KL_FlushBuffer() and KL_Mouse_FlushScroll() both accessed and then cleared
; shared buffer state in two separate steps. A Critical InputHook callback
; (KL_Hook_OnChar) can interrupt a timer pseudo-thread between those two steps,
; writing a new event into the buffer that is then wiped by the deferred clear —
; losing that event permanently without any error signal.
;
; The fix uses an atomic snapshot: under Critical("On"), all fields are copied
; into local snap_* variables AND cleared in the same critical section. Only
; after the caller's previous Critical state is restored does processing begin
; on the local copies.
;
; This meta-static test verifies the pattern is present and ordered correctly so
; a regression (splitting the snapshot from the reset, or restoring Critical
; before the reset) immediately fails CI.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ KL_FlushBuffer atomic snapshot ========
; ==================================================
; ==================================================

_KLFA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_KLFA_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

_KLFA_FlushBufferCritical() {
	Raw := _KLFA_ReadSource("modules/keylogger/keylogger.ahk")
	Src := _KLFA_StripComments(Raw)
	Body := _DriverFuncBody("KL_FlushBuffer")
	Assert(Body != "", "KL_FlushBuffer() must exist in modules/keylogger/keylogger.ahk")

	Assert(InStr(Body, "Critical(" . Chr(34) . "On" . Chr(34) . ")") > 0,
		"KL_FlushBuffer must open a Critical section before reading shared buffer state (keylogger-flush-race-condition)")

	Assert(InStr(Body, "snap_events") > 0,
		"KL_FlushBuffer must snapshot buffer_events into snap_events before clearing (keylogger-flush-race-condition)")

	Assert(InStr(Body, "Critical(previous_critical)") > 0,
		"KL_FlushBuffer must restore the caller Critical state after the atomic snapshot")

	; Ordering: Critical(On) must precede the snapshot, which must precede Critical(Off)
	PosOn   := InStr(Body, "Critical(" . Chr(34) . "On" . Chr(34) . ")")
	PosSnap := InStr(Body, "snap_events")
	PosOff  := InStr(Body, "Critical(previous_critical)")
	Assert(PosOn < PosSnap,
		"Critical(On) must appear before snap_events — snapshot must be taken inside the lock")
	Assert(PosSnap < PosOff,
		"snap_events must appear before Critical(Off) — buffer reset must complete inside the lock")
}
Test("keylogger: KL_FlushBuffer takes an atomic snapshot under Critical(On) before clearing (keylogger-flush-race-condition)", _KLFA_FlushBufferCritical)





; =======================================================
; =======================================================
; ======= 2/ KL_Mouse_FlushScroll atomic snapshot =======
; =======================================================
; =======================================================

_KLFA_MouseFlushScrollCritical() {
	Raw := _KLFA_ReadSource("modules/keylogger/keylogger_mouse.ahk")
	Src := _KLFA_StripComments(Raw)
	Body := _DriverFuncBody("KL_Mouse_FlushScroll")
	Assert(Body != "", "KL_Mouse_FlushScroll() must exist in modules/keylogger/keylogger_mouse.ahk")

	Assert(InStr(Body, "Critical(" . Chr(34) . "On" . Chr(34) . ")") > 0,
		"KL_Mouse_FlushScroll must open a Critical section before reading KLMouse scroll state")

	Assert(InStr(Body, "KLMouse.scroll_ticks   := 0") > 0 or InStr(Body, "KLMouse.scroll_ticks := 0") > 0,
		"KL_Mouse_FlushScroll must clear KLMouse.scroll_ticks inside the Critical section")

        Assert(InStr(Body, "Critical(previous_critical)") > 0,
                "KL_Mouse_FlushScroll must restore the caller's Critical state after the atomic snapshot")

	Assert(InStr(Body, "MF_ShouldFilter") > 0,
		"KL_Mouse_FlushScroll must still call MF_ShouldFilter after releasing Critical")

        ; Restoring the prior Critical state must happen before MF_ShouldFilter,
        ; which can yield the timer thread.
        PosOff := InStr(Body, "Critical(previous_critical)")
	PosMF  := InStr(Body, "MF_ShouldFilter")
	Assert(PosOff < PosMF,
                "Critical restoration must appear before MF_ShouldFilter — the helper must not extend its own lock across a yielding call")
}
Test("keylogger: KL_Mouse_FlushScroll releases Critical before MF_ShouldFilter (keylogger-flush-race-condition)", _KLFA_MouseFlushScrollCritical)
