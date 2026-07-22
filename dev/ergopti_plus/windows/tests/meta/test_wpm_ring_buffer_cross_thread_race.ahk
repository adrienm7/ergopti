; tests/meta/test_wpm_ring_buffer_cross_thread_race.ahk

; ==============================================================================
; MODULE: WPM Ring Buffer Cross-Thread Race Guard (wpm-ring-buffer-cross-thread-race)
; DESCRIPTION:
; Static source guard for the wpm-ring-buffer-cross-thread-race finding.
;
; WPMWidget_Push (keyboard thread) mutates the recent-keystroke ring buffer
; (Array.Push or _ring[head+1] := entry), while WPMWidget_Calc runs on the
; display tick timer and enumerates that same ring. In AHK's cooperative model
; the keyboard thread can interrupt the tick between for-loop iterations and
; grow / overwrite the array, so the enumerator can observe an inconsistent
; slice. The fix brackets BOTH the ring mutation in WPMWidget_Push and the
; enumeration in WPMWidget_Calc with a saved/restored Critical state so each region runs
; atomically with respect to the other (the regions contain no Send/Sleep, so
; Critical cannot starve the hook).
;
; This is a meta-static test: ui/wpm/ registers GUI / timer state and is NOT in
; the headless run_all include graph, so a source-text guard is the only
; automated net available. It introspects function bodies via _DriverFuncBody
; (whole-tree, split-resilient). ASCII-only per the suite convention. If either
; Critical bracket is removed this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Critical-guard assertions =============
; ==================================================
; ==================================================

_WpmRace_PushGuardsRingMutation() {
	Seg := _DriverFuncBody("WPMWidget_Push")
	Assert(Seg != "", "WPMWidget_Push declaration must exist in ui/wpm/")
	Assert(InStr(Seg, "_ring.Push") > 0,
		"WPMWidget_Push must still own the ring-buffer Push mutation")
	Assert(InStr(Seg, "RingCritical := Critical") > 0,
		"WPMWidget_Push must bracket its ring mutation with Critical so a concurrent WPMWidget_Calc enumeration cannot observe a half-grown or mid-overwritten array")
	Assert(InStr(Seg, "finally") > 0 && InStr(Seg, "Critical(RingCritical)") > 0,
		"WPMWidget_Push must restore the caller's Critical state in finally so it cannot split an outer injection transaction")
}
Test("wpm_widget: WPMWidget_Push brackets the ring mutation with Critical (wpm-ring-buffer-cross-thread-race)", _WpmRace_PushGuardsRingMutation)

_WpmRace_CalcGuardsEnumeration() {
	Seg := _DriverFuncBody("WPMWidget_Calc")
	Assert(Seg != "", "WPMWidget_Calc declaration must exist in ui/wpm/")
	Assert(InStr(Seg, "for _, ev in WPMWidget._ring") > 0,
		"WPMWidget_Calc must still enumerate the ring buffer")
	Assert(InStr(Seg, "RingCritical := Critical") > 0,
		"WPMWidget_Calc must enter Critical before walking the ring so a concurrent WPMWidget_Push cannot grow or overwrite a slot mid-enumeration")
	Assert(InStr(Seg, "finally") > 0 && InStr(Seg, "Critical(RingCritical)") > 0,
		"WPMWidget_Calc must restore the caller's Critical state in finally after the ring walk")
}
Test("wpm_widget: WPMWidget_Calc walks the ring under Critical (wpm-ring-buffer-cross-thread-race)", _WpmRace_CalcGuardsEnumeration)

_WpmRace_ResetRestoresCallerCritical() {
	Seg := _DriverFuncBody("_WPMWidget_ResetRolling")
	Assert(Seg != "", "_WPMWidget_ResetRolling declaration must exist in ui/wpm/")
	Assert(InStr(Seg, "RingCritical := Critical") > 0
		&& InStr(Seg, "finally") > 0
		&& InStr(Seg, "Critical(RingCritical)") > 0,
		"_WPMWidget_ResetRolling must restore the caller's Critical state after replacing the shared ring")
}
Test("wpm_widget: reset preserves outer Critical transaction", _WpmRace_ResetRestoresCallerCritical)
