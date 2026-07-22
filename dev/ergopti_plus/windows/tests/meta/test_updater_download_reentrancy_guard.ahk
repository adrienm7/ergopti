; tests/meta/test_updater_download_reentrancy_guard.ahk

; ==============================================================================
; MODULE: Updater Download Re-entrancy Guard Meta Test
; DESCRIPTION:
; Static source guard for finding updater-download-reentrancy (F10).
;
; Two independent "Update now" triggers (the TrayTip update prompt and the
; changelog's "Install this version" button, each opening its own dialog)
; could both reach Updater_DownloadAndInstall before the first download
; finished, opening a second async WinHTTP request against the SAME staging
; file and racing two ADODB.Stream.SaveToFile writes with no lock.
;
; The fix adds an early _UpdaterDownloadInProgress check with a return BEFORE
; any side-effecting work (DirCreate/Req.Open) begins, and makes
; Updater_ShowUpdatePrompt a singleton so a second trigger cannot even open a
; second dialog. Meta-static source scan -- calling Updater_DownloadAndInstall
; for real would need a live WinHTTP round-trip.
; ==============================================================================

#Requires AutoHotkey v2.0


_UDRG_AssertReentrancyGuard() {
	Body := _DriverFuncBody("Updater_DownloadAndInstall")
	Assert(Body != "", "Updater_DownloadAndInstall must exist")

	GuardIdx := InStr(Body, "if _UpdaterDownloadInProgress")
	Assert(GuardIdx > 0,
		"Updater_DownloadAndInstall must check _UpdaterDownloadInProgress before proceeding (updater-download-reentrancy)")

	DispatchIdx := InStr(Body, "_Updater_StartStagingWorker(")
	Assert(DispatchIdx > 0, "Updater_DownloadAndInstall must dispatch the isolated staging worker")
	Assert(GuardIdx < DispatchIdx,
		"The _UpdaterDownloadInProgress guard must run before worker dispatch, otherwise two update dialogs can stage the same target concurrently")
	Assert(InStr(Body, "DirCreate(") = 0 and InStr(Body, "Req.Open(") = 0,
		"Updater_DownloadAndInstall must not perform staging disk or HTTP work on the AHK thread")
}
Test("updater: Updater_DownloadAndInstall has a re-entrancy guard before any side effect (updater-download-reentrancy)", _UDRG_AssertReentrancyGuard)


_UDRG_AssertPromptSingleton() {
	Body := _DriverFuncBody("Updater_ShowUpdatePrompt")
	Assert(Body != "", "Updater_ShowUpdatePrompt must exist")
	Assert(InStr(Body, "IsSet(_Updater_PromptGui)") > 0,
		"Updater_ShowUpdatePrompt must be a singleton -- a second call while a prompt is already open must reuse it instead of opening a duplicate dialog that can trigger a second concurrent download (updater-download-reentrancy)")
}
Test("updater: Updater_ShowUpdatePrompt is a singleton (updater-download-reentrancy)", _UDRG_AssertPromptSingleton)
