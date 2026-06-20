; tests/meta/test_llm_pointer_watch_not_stopped_on_suspend.ahk

; ==============================================================================
; MODULE: LLM Pointer-Watch Suspend Reactor Meta Test
; DESCRIPTION:
; Static source guard for the llm-pointer-watch-not-stopped-on-suspend finding.
;
; The pointer-watch lifecycle was tied to bridge Start/Stop, not to the suspend
; reactor. Ergopti_OnSuspendEnter cancelled the debounce timer, hid the tooltip
; and stopped the warm-up retry, but left the pointer-dismiss poll armed -- so
; the 50 ms MouseGetPos poll and ~9 pass-through mouse hotkeys stayed live for
; the entire pause, breaching the "pause = tout eteint" invariant.
;
; The fix calls _LLM_PointerWatch_Stop() from Ergopti_OnSuspendEnter and
; re-arms it from Ergopti_OnSuspendResume only when the bridge is active. This
; test scans both reactor bodies and asserts the stop + conditional re-arm wiring
; is present.
;
; Meta-static because ErgoptiPlus.ahk is the top-level entry point (registers
; hotkeys, builds the tray) and is not part of the headless run_all include
; graph.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_PwssReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_PwssFuncBody(Src, FuncDef) {
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
; ======= 2/ Reactor wiring assertions =============
; ==================================================
; ==================================================

_PwssSuspendEnterStopsPointerWatch() {
	Src := _PwssReadSource("ErgoptiPlus.ahk")
	Seg := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(Seg != "", "Ergopti_OnSuspendEnter() declaration must exist in ErgoptiPlus.ahk")
	Assert(InStr(Seg, "_LLM_PointerWatch_Stop()") > 0,
		"Ergopti_OnSuspendEnter must stop the LLM pointer-dismiss watcher -- its SetTimer poll + mouse hotkeys bypass native Suspend and would keep running for the whole pause")
}
Test("ErgoptiPlus: Ergopti_OnSuspendEnter stops the LLM pointer watcher (llm-pointer-watch-not-stopped-on-suspend)", _PwssSuspendEnterStopsPointerWatch)

_PwssSuspendResumeRearmsPointerWatch() {
	Src := _PwssReadSource("ErgoptiPlus.ahk")
	Seg := _DriverFuncBody("Ergopti_OnSuspendResume")
	Assert(Seg != "", "Ergopti_OnSuspendResume() declaration must exist in ErgoptiPlus.ahk")
	Assert(InStr(Seg, "_LLM_PointerWatch_Start()") > 0,
		"Ergopti_OnSuspendResume must re-arm the LLM pointer-dismiss watcher stopped on suspend so dismiss-on-pointer works again after unpause")
	Assert(InStr(Seg, "_LLM_Bridge_Active") > 0,
		"Ergopti_OnSuspendResume must gate the pointer-watch re-arm on _LLM_Bridge_Active so it does not start the watcher when the bridge is off")
}
Test("ErgoptiPlus: Ergopti_OnSuspendResume re-arms pointer watcher only when bridge active (llm-pointer-watch-not-stopped-on-suspend)", _PwssSuspendResumeRearmsPointerWatch)
