; static/ergopti_plus/windows/tests/meta/test_updater_scheduler_off_typing_path.ahk

; ==============================================================================
; MODULE: Updater Scheduler Off The Typing Path
; DESCRIPTION:
; The automatic-check schedule reads the Storage port (the registry) and may
; dispatch a network check, so it runs only from its own one-shot timer and the
; WM_POWERBROADCAST handler, never from a hotkey, hotstring or input-hook
; callback, where a registry read or a network dispatch would delay keystrokes.
; Hotkeys are registered all over the driver, so the guard is structural: no
; driver file outside modules/updater references a scheduler entry point.
; ==============================================================================

_USOTP_SchedulerEntryPoints() {
	return ["_Updater_ScheduleDecision", "_Updater_RecordBackgroundCheck", "Updater_BackgroundTick",
		"_Updater_ReevaluateAfterWake", "_Updater_RearmBackgroundOwner", "_Updater_CheckState"]
}

_USOTP_NoDriverFileOutsideTheUpdaterReachesTheScheduler() {
	; run_all.ahk runs from the driver's tests folder; the driver tree is its parent.
	Root := RegExReplace(A_ScriptDir, "\\tests$")
	AssertTrue(Root != A_ScriptDir, "the suite must run from the driver's tests folder")
	Scanned := 0
	Offenders := ""
	loop files, Root . "\*.ahk", "R" {
		Rel := SubStr(A_LoopFileFullPath, StrLen(Root) + 2)
		if RegExMatch(Rel, "i)^(tests|_generated|modules\\updater)\\")
			continue
		Source := FileRead(A_LoopFileFullPath, "UTF-8")
		Scanned += 1
		for _, Name in _USOTP_SchedulerEntryPoints()
			if InStr(Source, Name . "(")
				Offenders .= Rel . " -> " . Name . "`n"
	}
	AssertTrue(Scanned >= 100, "the scan must cover the driver tree, scanned " . Scanned . " file(s)")
	AssertEqual("", Offenders, "the update-check scheduler must stay off the hotkey and hotstring paths")
	for _, Name in _USOTP_SchedulerEntryPoints()
		Assert(_DriverFuncBody(Name) != "", Name . " must exist in the updater module, or this scan proves nothing")
}
Test("meta updater: the check scheduler is reachable only from the updater's timer and wake handler",
	_USOTP_NoDriverFileOutsideTheUpdaterReachesTheScheduler)
