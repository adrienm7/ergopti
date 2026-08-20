; tests/meta/test_g5_updater_download.ahk

; ==============================================================================
; MODULE: G5 Guarantee Updater Download Meta Test
; DESCRIPTION:
; Static source guard ensuring the background download poll enforces the
; "pause = tout eteint" invariant (G5 Guarantee) and prevents races.
;
; The G5 Guarantee requires that no background fetches proceed or complete
; while the driver is paused. Thus:
; 1. The staging monitor MUST check A_IsSuspended and terminate the worker.
; 2. The AHK completion callback must remain interruptible because disk work is
;    owned by the worker process, not protected by Critical on the hook thread.
; ==============================================================================

#Requires AutoHotkey v2.0

_G5UD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_G5UD_CheckDownloadPollGuards() {
	Src := _G5UD_ReadSource("modules/updater.ahk")
	Seg := _DriverFuncBody("_Updater_MonitorStagingWorker")
	
	Assert(Seg != "", "_Updater_MonitorStagingWorker must exist in updater.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"_Updater_MonitorStagingWorker must check A_IsSuspended and abort (Garantie G5)")
	Assert(InStr(Seg, "_Updater_CancelSelfUpdateForSuspend") > 0,
		"the monitor backstop must route through the synchronous suspend-event owner")
	Assert(InStr(Seg, "Critical(") = 0,
		"_Updater_MonitorStagingWorker must keep cancellation interruptible (Garantie G5)")
	CancelBody := _DriverFuncBody("_Updater_CancelSelfUpdateTransaction")
	EnterBody := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(InStr(CancelBody, "Worker.terminate()") > 0
		and InStr(CancelBody, "_Updater_CloseSwapOwner(Owner, true)") > 0,
		"the shared suspend cancellation must terminate staging and exact swap owners")
	Assert(InStr(EnterBody, "_Updater_CancelSelfUpdateForSuspend") > 0,
		"Pause itself must cancel synchronously so a rapid Resume cannot hide from a later state poll")
	StartBody := _DriverFuncBody("_Updater_StartStagingWorker")
	Assert(StartBody != "", "_Updater_StartStagingWorker must exist in updater.ahk")
	Assert(InStr(StartBody, "ShellRunner_SpawnTreeOwned") > 0
		&& !RegExMatch(StartBody, "\bShellRunner_Spawn\("),
		"updater staging must use the Job-owned process-tree runner; PID-only cancellation can leave PowerShell alive after Suspend (Garantie G5)")
}
Test("updater: G5 Guarantee terminates staging worker while suspended", _G5UD_CheckDownloadPollGuards)
