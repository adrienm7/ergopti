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
; enumeration in WPMWidget_Calc with Critical "On"/"Off" so each region runs
; atomically with respect to the other (the regions contain no Send/Sleep, so
; Critical cannot starve the hook).
;
; This is a meta-static test: lib/metrics/wpm_widget.ahk registers GUI / timer
; state and is NOT in the headless run_all include graph, so a source-text
; guard is the only automated net available. ASCII-only per the suite
; convention. If either Critical bracket is removed this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; A_ScriptDir is the runner dir (tests\); its parent is the windows\ root.
_WpmRace_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the full function body from its declaration to the first closing brace
; at column 0 (AHK functions close with `}` flush-left). Returns "" when absent.
_WpmRace_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}




; ==================================================
; ==================================================
; ======= 2/ Critical-guard assertions =============
; ==================================================
; ==================================================

_WpmRace_PushGuardsRingMutation() {
	Src := _WpmRace_ReadSource("lib/metrics/wpm_widget.ahk")
	Seg := _WpmRace_FuncBody(Src, "WPMWidget_Push(")
	Assert(Seg != "", "WPMWidget_Push declaration must exist in wpm_widget.ahk")
	Assert(InStr(Seg, "_ring.Push") > 0,
		"WPMWidget_Push must still own the ring-buffer Push mutation")
	Assert(InStr(Seg, Chr(34) . "On" . Chr(34)) > 0 && InStr(Seg, "Critical") > 0,
		"WPMWidget_Push must bracket its ring mutation with Critical so a concurrent WPMWidget_Calc enumeration cannot observe a half-grown or mid-overwritten array")
	Assert(InStr(Seg, Chr(34) . "Off" . Chr(34)) > 0,
		"WPMWidget_Push must release Critical (Critical Off) after the ring mutation so the hook is not held longer than the few non-blocking lines")
}
Test("wpm_widget: WPMWidget_Push brackets the ring mutation with Critical (wpm-ring-buffer-cross-thread-race)", _WpmRace_PushGuardsRingMutation)

_WpmRace_CalcGuardsEnumeration() {
	Src := _WpmRace_ReadSource("lib/metrics/wpm_widget.ahk")
	Seg := _WpmRace_FuncBody(Src, "WPMWidget_Calc()")
	Assert(Seg != "", "WPMWidget_Calc declaration must exist in wpm_widget.ahk")
	Assert(InStr(Seg, "for _, ev in WPMWidget._ring") > 0,
		"WPMWidget_Calc must still enumerate the ring buffer")
	Assert(InStr(Seg, "Critical") > 0 && InStr(Seg, Chr(34) . "On" . Chr(34)) > 0,
		"WPMWidget_Calc must enter Critical before walking the ring so a concurrent WPMWidget_Push cannot grow or overwrite a slot mid-enumeration")
	Assert(InStr(Seg, Chr(34) . "Off" . Chr(34)) > 0,
		"WPMWidget_Calc must release Critical (Critical Off) after the ring walk")
}
Test("wpm_widget: WPMWidget_Calc walks the ring under Critical (wpm-ring-buffer-cross-thread-race)", _WpmRace_CalcGuardsEnumeration)
