; tests/meta/test_updater_sync_winhttp_blocks.ahk

#Requires AutoHotkey v2.0

_USWB_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

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
	Src := _USWB_ReadSource("lib/updater.ahk")
	Body := _USWB_FuncBodyStripped(Src, "Updater_OneClickUpdate(*) {")
	Assert(Body != "", "Updater_OneClickUpdate must exist in lib/updater.ahk")
	
	SyncIdx := InStr(Body, "Updater_FetchLatestJson(")
	Assert(!SyncIdx, "Updater_OneClickUpdate must not call synchronous Updater_FetchLatestJson (sync-winhttp-blocks-keyboard-on-user-check)")

	AsyncIdx := InStr(Body, "_Updater_FetchLatestJsonAsync(")
	Assert(AsyncIdx > 0, "Updater_OneClickUpdate must use _Updater_FetchLatestJsonAsync (sync-winhttp-blocks-keyboard-on-user-check)")
}

_USWB_AssertDownloadAndInstallAsync() {
	Src := _USWB_ReadSource("lib/updater.ahk")
	Body := _USWB_FuncBodyStripped(Src, "Updater_DownloadAndInstall(Release) {")
	Assert(Body != "", "Updater_DownloadAndInstall must exist in lib/updater.ahk")
	
	SyncReqIdx := InStr(Body, 'Req.Open("GET", AssetUrl, false)')
	Assert(!SyncReqIdx, "Updater_DownloadAndInstall must not use synchronous WinHTTP Open (sync-winhttp-blocks-keyboard-on-user-check)")

	AsyncReqIdx := InStr(Body, 'Req.Open("GET", AssetUrl, true)')
	Assert(AsyncReqIdx > 0, "Updater_DownloadAndInstall must use async WinHTTP Open (sync-winhttp-blocks-keyboard-on-user-check)")
}

_USWB_AssertShowAvailableUpdateAsync() {
	Src := _USWB_ReadSource("lib/updater.ahk")
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
