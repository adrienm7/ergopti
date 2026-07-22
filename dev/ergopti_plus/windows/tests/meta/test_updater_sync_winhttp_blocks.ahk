; tests/meta/test_updater_sync_winhttp_blocks.ahk

#Requires AutoHotkey v2.0

_USWB_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	if RegExMatch(Rest, "m)^\}", &Match)
		Rest := SubStr(Rest, 1, Match.Pos)
	return Rest
}

_USWB_AssertOneClickUpdateAsync() {
	Src := _DriverDirConcat("lib/updater")
	Body := _USWB_FuncBodyStripped(Src, "Updater_OneClickUpdate(*) {")
	Assert(Body != "", "Updater_OneClickUpdate must exist in lib/updater.ahk")
	
	SyncIdx := InStr(Body, "Updater_FetchLatestJson(")
	Assert(!SyncIdx, "Updater_OneClickUpdate must not call synchronous Updater_FetchLatestJson (sync-winhttp-blocks-keyboard-on-user-check)")

	AsyncIdx := InStr(Body, "_Updater_FetchLatestJsonAsync(")
	Assert(AsyncIdx > 0, "Updater_OneClickUpdate must use _Updater_FetchLatestJsonAsync (sync-winhttp-blocks-keyboard-on-user-check)")
}

_USWB_AssertDownloadAndInstallAsync() {
	Src := _DriverDirConcat("lib/updater")
	Body := _USWB_FuncBodyStripped(Src, "Updater_DownloadAndInstall(Release) {")
	Assert(Body != "", "Updater_DownloadAndInstall must exist in lib/updater.ahk")
	
	Assert(InStr(Body, "ComObject(") = 0 and InStr(Body, "Req.Open(") = 0,
		"Updater_DownloadAndInstall must not create any WinHTTP object on the keyboard thread (sync-winhttp-blocks-keyboard-on-user-check)")
	WorkerIdx := InStr(Body, "_Updater_StartStagingWorker(")
	Assert(WorkerIdx > 0, "Updater_DownloadAndInstall must dispatch the isolated staging worker asynchronously (sync-winhttp-blocks-keyboard-on-user-check)")
}

_USWB_AssertShowAvailableUpdateAsync() {
	Src := _DriverDirConcat("lib/updater")
	Body := _USWB_FuncBodyStripped(Src, "Updater_ShowAvailableUpdate(*) {")
	Assert(Body != "", "Updater_ShowAvailableUpdate must exist in lib/updater.ahk")

	SyncIdx := InStr(Body, "Updater_FetchLatestJson(")
	Assert(!SyncIdx, "Updater_ShowAvailableUpdate must not call synchronous Updater_FetchLatestJson — it blocks keyboard remapping on the menu/notification path (sync-winhttp-blocks-keyboard-on-user-check)")

	AsyncIdx := InStr(Body, "_Updater_FetchLatestJsonAsync(")
	Assert(AsyncIdx > 0, "Updater_ShowAvailableUpdate must use _Updater_FetchLatestJsonAsync (sync-winhttp-blocks-keyboard-on-user-check)")
}

Test("updater: OneClickUpdate is async (sync-winhttp-blocks-keyboard-on-user-check)", _USWB_AssertOneClickUpdateAsync)
Test("updater: DownloadAndInstall is async (sync-winhttp-blocks-keyboard-on-user-check)", _USWB_AssertDownloadAndInstallAsync)
Test("updater: ShowAvailableUpdate is async (sync-winhttp-blocks-keyboard-on-user-check)", _USWB_AssertShowAvailableUpdateAsync)
