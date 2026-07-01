; tests/meta/test_g5_updater_download.ahk

; ==============================================================================
; MODULE: G5 Guarantee Updater Download Meta Test
; DESCRIPTION:
; Static source guard ensuring the background download poll enforces the
; "pause = tout eteint" invariant (G5 Guarantee) and prevents races.
;
; The G5 Guarantee requires that no background fetches proceed or complete
; while the driver is paused. Thus:
; 1. _Updater_PollDownloadAsync MUST check A_IsSuspended and abort the download
;    if it caught the driver in a suspended state.
; 2. The block that writes the file and swaps the binary MUST be wrapped in
;    Critical("On") so that a Suspend hotkey cannot interrupt it mid-write.
; ==============================================================================

#Requires AutoHotkey v2.0

_G5UD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_G5UD_CheckDownloadPollGuards() {
	Src := _G5UD_ReadSource("lib/updater.ahk")
	Seg := _DriverFuncBody("_Updater_PollDownloadAsync")
	
	Assert(Seg != "", "_Updater_PollDownloadAsync must exist in updater.ahk")
	Assert(InStr(Seg, "A_IsSuspended") > 0,
		"_Updater_PollDownloadAsync must check A_IsSuspended and abort (Garantie G5)")
	Assert(InStr(Seg, 'Critical("On")') > 0,
		"_Updater_PollDownloadAsync must use Critical On for the disk swap (Garantie G5)")
}
Test("updater: G5 Guarantee guards present in _Updater_PollDownloadAsync", _G5UD_CheckDownloadPollGuards)
