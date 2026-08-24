; tests/meta/test_health_probe_timer_suspend_guard.ahk

; ==============================================================================
; MODULE: LLM Health-Probe Timer Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for the health-probe-timer-not-suspend-guarded finding.
;
; _LLM_Menu_FireHealthProbe is a 10 s recurring SetTimer callback that opens a
; WinHTTP connection to Ollama and, when the daemon's reachability flips, calls
; LLM_Menu_Build() to rebuild the tray menu. SetTimer callbacks bypass native
; Suspend, so without an A_IsSuspended early-return the paused driver keeps
; pinging Ollama and rebuilding the menu every 10 s - violating the stated
; "pause silences everything" invariant.
;
; The fix adds `if A_IsSuspended return` at the top of _LLM_Menu_FireHealthProbe
; and skips the LLM_Menu_Build() in _LLM_Menu_OnHealthProbeDone when suspended
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
	Src := _HPTS_ReadSource("ui/menu/menu_llm/actions.ahk")
	Seg := _DriverFuncBody("_LLM_Menu_FireHealthProbe")
	Assert(Seg != "", "_LLM_Menu_FireHealthProbe() declaration must exist in actions.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"_LLM_Menu_FireHealthProbe must early-return on A_IsSuspended - its 10 s SetTimer bypasses Suspend and would keep pinging Ollama + rebuilding the tray while paused")
}
Test("LLM tray: _LLM_Menu_FireHealthProbe has an A_IsSuspended guard (health-probe-timer-not-suspend-guarded)", _HPTS_FireHealthProbeHasSuspendGuard)

_HPTS_ProbeDoneSkipsRebuildWhileSuspended() {
	Src := _HPTS_ReadSource("ui/menu/menu_llm/actions.ahk")
	Seg := _DriverFuncBody("_LLM_Menu_OnHealthProbeDone")
	OwnerGuard := _DriverFuncBody("_LLM_Menu_AuxOwnerIsCurrent")
	Assert(Seg != "", "_LLM_Menu_OnHealthProbeDone(reachable) declaration must exist in actions.ahk")
	Assert(OwnerGuard != "", "the shared auxiliary menu-owner guard must exist")
	Assert(InStr(Seg, "_LLM_Menu_AuxOwnerIsCurrent(Owner)") > 0
			&& InStr(OwnerGuard, "A_IsSuspended") > 0,
		"_LLM_Menu_OnHealthProbeDone must delegate to the shared Suspend-aware owner guard before rebuilding the tray")
}
Test("LLM tray: _LLM_Menu_OnHealthProbeDone skips rebuild while suspended (health-probe-timer-not-suspend-guarded)", _HPTS_ProbeDoneSkipsRebuildWhileSuspended)





; ==================================================
; ==================================================
; ======= 3/ Idle-gate assertions ==================
; ==================================================
; ==================================================

; The 10 s tick spawns a curl.exe child every time it fires
; (LLM_OllamaIsRunning_Async runs curl and then polls the PID), so a machine
; left alone paid 8640 process spawns a day to repaint a tray dot nobody was
; looking at. The fix gates that spawn on A_TimeIdlePhysical.
;
; POSITION matters as much as presence, hence the offset comparisons. The gate
; must sit AFTER the throttle: _LLM_Menu_OnHealthProbeDone rebuilds the menu on a
; state flip, the rebuild re-enters this helper with Force, and only the 3 s
; throttle breaks the resulting build → probe → flip → build loop. A future
; "simplification" hoisting `if Force` to the top of the function would reopen
; that loop AND neuter the pause guard, while leaving the token-presence
; assertions above still green.
_HPTS_FireHealthProbeIsIdleGated() {
	Seg := _DriverFuncBody("_LLM_Menu_FireHealthProbe")
	Assert(Seg != "", "_LLM_Menu_FireHealthProbe() declaration must exist in the driver source")
	IdlePos := InStr(Seg, "A_TimeIdlePhysical")
	ConstPos := InStr(Seg, "LLM_HEALTH_PROBE_IDLE_MAX_MS")
	ThrottlePos := InStr(Seg, "last_health_probe_tick")
	SpawnPos := InStr(Seg, "LLM_OllamaIsRunning_Async")
	ForcePos := InStr(Seg, "!Force")
	SuspendPos := InStr(Seg, "A_IsSuspended")
	Assert(IdlePos > 0 and ConstPos > 0,
		"_LLM_Menu_FireHealthProbe must idle-gate on A_TimeIdlePhysical against the named LLM_HEALTH_PROBE_IDLE_MAX_MS ceiling - without it the 10 s tick spawns a curl.exe child 8640 times a day to refresh a dot nobody is looking at")
	Assert(ThrottlePos > 0 and IdlePos > ThrottlePos,
		"the idle gate must sit AFTER the 3 s throttle - above it, the tray-build Force bypass would skip the throttle too and a rebuild storm would spawn one curl child per rebuild")
	Assert(SpawnPos > 0 and IdlePos < SpawnPos,
		"the idle gate must sit BEFORE the LLM_OllamaIsRunning_Async spawn - a gate placed after it would save nothing")
	Assert(ForcePos > 0,
		"the idle gate must honour a caller-supplied Force bypass - the tray-build path needs an on-demand refresh the gate cannot veto")
	Assert(SuspendPos > 0 and SuspendPos < ForcePos,
		"the A_IsSuspended guard must stay AHEAD of the Force bypass - a paused driver stays silent no matter which caller asks for a refresh")
}
Test("LLM tray: _LLM_Menu_FireHealthProbe idle-gates its curl spawn (perf-2026-07-21)", _HPTS_FireHealthProbeIsIdleGated)

; The gate must not cost freshness on the one path where the user IS looking.
; A_TimeIdlePhysical only notices the tray click while AHK's mouse hook happens
; to be installed, and it is installed here purely as a side effect of
; nav_layer.ahk declaring wheel hotkeys — too incidental to hang the refresh on,
; so the tray-build path states its intent explicitly instead.
_HPTS_MenuBuildForcesHealthProbe() {
	Seg := _DriverFuncBody("_LLM_Menu_EmitRow")
	Assert(Seg != "", "_LLM_Menu_EmitRow() declaration must exist in the driver source")
	Assert(InStr(Seg, "_LLM_Menu_FireHealthProbe(true)") > 0,
		"the model row must call _LLM_Menu_FireHealthProbe(true) - without the Force argument the idle gate would leave a stale health dot on the very menu the user just opened")
	Assert(RegExMatch(_DriverSourceNoComments(), "m)^global LLM_HEALTH_PROBE_IDLE_MAX_MS\s*:=\s*\d+") > 0,
		"LLM_HEALTH_PROBE_IDLE_MAX_MS must be declared once as a named global constant - an inline 60000 in the guard would be a magic number")
}
Test("LLM tray: the tray-build health probe forces past the idle gate (perf-2026-07-21)", _HPTS_MenuBuildForcesHealthProbe)
