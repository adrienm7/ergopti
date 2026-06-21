; tests/meta/test_health_probe_timer_suspend_guard.ahk

; ==============================================================================
; MODULE: LLM Health-Probe Timer Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for the health-probe-timer-not-suspend-guarded finding.
;
; _LLM_Tray_FireHealthProbe is a 10 s recurring SetTimer callback that opens a
; WinHTTP connection to Ollama and, when the daemon's reachability flips, calls
; LLM_Tray_Build() to rebuild the tray menu. SetTimer callbacks bypass native
; Suspend, so without an A_IsSuspended early-return the paused driver keeps
; pinging Ollama and rebuilding the menu every 10 s - violating the stated
; "pause silences everything" invariant.
;
; The fix adds `if A_IsSuspended return` at the top of _LLM_Tray_FireHealthProbe
; and skips the LLM_Tray_Build() in _LLM_Tray_OnHealthProbeDone when suspended
; (an async probe fired just before Pause could still land and churn the menu).
;
; Meta-static (scans source text) because actions.ahk registers menu/hotkey
; side effects and is not part of the headless run_all include graph; calling
; the function directly would be a load-time error in the runner.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_HPTS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Suspend-guard assertions ==============
; ==================================================
; ==================================================

_HPTS_FireHealthProbeHasSuspendGuard() {
	Src := _HPTS_ReadSource("ui/tray_llm/actions.ahk")
	Seg := _DriverFuncBody("_LLM_Tray_FireHealthProbe")
	Assert(Seg != "", "_LLM_Tray_FireHealthProbe() declaration must exist in actions.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"_LLM_Tray_FireHealthProbe must early-return on A_IsSuspended - its 10 s SetTimer bypasses Suspend and would keep pinging Ollama + rebuilding the tray while paused")
}
Test("LLM tray: _LLM_Tray_FireHealthProbe has an A_IsSuspended guard (health-probe-timer-not-suspend-guarded)", _HPTS_FireHealthProbeHasSuspendGuard)

_HPTS_ProbeDoneSkipsRebuildWhileSuspended() {
	Src := _HPTS_ReadSource("ui/tray_llm/actions.ahk")
	Seg := _DriverFuncBody("_LLM_Tray_OnHealthProbeDone")
	Assert(Seg != "", "_LLM_Tray_OnHealthProbeDone(reachable) declaration must exist in actions.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"_LLM_Tray_OnHealthProbeDone must skip LLM_Tray_Build() while A_IsSuspended - an async probe landing just after Pause would otherwise churn the tray menu")
}
Test("LLM tray: _LLM_Tray_OnHealthProbeDone skips rebuild while suspended (health-probe-timer-not-suspend-guarded)", _HPTS_ProbeDoneSkipsRebuildWhileSuspended)
