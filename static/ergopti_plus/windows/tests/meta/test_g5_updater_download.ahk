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
	Assert(InStr(Seg, ".terminate()") > 0,
		"_Updater_MonitorStagingWorker must terminate the child worker while suspended (Garantie G5)")
	Assert(InStr(Seg, "Critical(") = 0,
		"_Updater_MonitorStagingWorker must keep cancellation interruptible (Garantie G5)")
	Terminator := _DriverFuncBody("_SR_HandleTerminate")
	TreeKillPos := InStr(Terminator, "taskkill /pid")
	FallbackPos := InStr(Terminator, "ProcessClose(pid)")
	Assert(TreeKillPos > 0 and InStr(Terminator, "/t /f") > TreeKillPos and FallbackPos > TreeKillPos,
		"ShellRunner termination must kill the cmd.exe child tree before its direct-process fallback, otherwise Suspend can leave PowerShell staging alive (Garantie G5)")
}
Test("updater: G5 Guarantee terminates staging worker while suspended", _G5UD_CheckDownloadPollGuards)
