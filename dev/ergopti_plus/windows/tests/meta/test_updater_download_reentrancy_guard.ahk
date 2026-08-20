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
; The fix test-and-claims _UpdaterDownloadInProgress plus the exact request in
; one short Critical transaction, restores the caller's Critical state, and only
; then dispatches the isolated staging worker. Updater_ShowUpdatePrompt is also
; a singleton so a second trigger cannot even open a second dialog. Meta-static
; source scan -- calling Updater_DownloadAndInstall for real would launch the
; staging subprocess.
; ==============================================================================

#Requires AutoHotkey v2.0


_UDRG_AssertReentrancyGuard() {
	Body := _StripFullLineComments(
		_DriverFuncBody("Updater_DownloadAndInstall"))
	BeginBody := _StripFullLineComments(
		_DriverFuncBody("_Updater_BeginDownloadTransaction"))
	ReserveBody := _StripFullLineComments(
		_DriverFuncBody("_Updater_TryReserveDownloadTransaction"))
	Assert(Body != "" and BeginBody != "" and ReserveBody != "",
		"the public download path and its begin/reservation helpers must exist")

	StartIdx := InStr(BeginBody, "LoggerStart(")
	ReserveCallIdx := InStr(BeginBody,
		"_Updater_TryReserveDownloadTransaction(")
	Assert(StartIdx > 0 and ReserveCallIdx > StartIdx,
		"download START must become observable before publishing the cancellable transaction owner (updater-download-logger-order)")

	CriticalIdx := InStr(ReserveBody, 'Critical("On")')
	GuardIdx := InStr(ReserveBody,
		"else if _UpdaterDownloadInProgress", , CriticalIdx)
	DuplicateIdx := InStr(ReserveBody,
		"Outcome.DuplicateDownload := true", , GuardIdx)
	ClaimIdx := InStr(ReserveBody,
		"_UpdaterDownloadInProgress := true", , DuplicateIdx)
	RequestIdx := InStr(ReserveBody,
		"_UpdaterDownloadRequest := Request", , ClaimIdx)
	Assert(CriticalIdx > 0 and GuardIdx > CriticalIdx
		and DuplicateIdx > GuardIdx and ClaimIdx > DuplicateIdx
		and RequestIdx > ClaimIdx,
		"the reservation helper must test-and-claim _UpdaterDownloadInProgress atomically (updater-download-reentrancy)")

	RestoreIdx := InStr(ReserveBody, "finally", , RequestIdx)
	CriticalOffIdx := InStr(ReserveBody,
		"Critical(PreviousCritical", , RestoreIdx)
	BeginIdx := InStr(Body, "_Updater_BeginDownloadTransaction(")
	DispatchIdx := InStr(Body, "_Updater_StartStagingWorker(")
	Assert(DispatchIdx > 0, "Updater_DownloadAndInstall must dispatch the isolated staging worker")
	Assert(RestoreIdx > RequestIdx and CriticalOffIdx > RestoreIdx
		and BeginIdx > 0 and DispatchIdx > BeginIdx,
		"The atomic reservation must restore the caller's Critical state before worker dispatch; otherwise subprocess launch and later staging work can freeze the keyboard thread")
	Assert(InStr(ReserveBody, "Logger") == 0
		and InStr(ReserveBody, "File") == 0
		and InStr(ReserveBody, "ComObject(") == 0,
		"the Critical reservation helper must remain scalar-only -- logging, file I/O, and COM belong outside the atomic span")
	Assert(InStr(Body, "DirCreate(") = 0 and InStr(Body, "Req.Open(") = 0,
		"Updater_DownloadAndInstall must not perform staging disk or HTTP work on the AHK thread")
}
Test("updater: Updater_DownloadAndInstall restores Critical before staging dispatch (updater-download-reentrancy)", _UDRG_AssertReentrancyGuard)


_UDRG_AssertPromptSingleton() {
	Body := _DriverFuncBody("Updater_ShowUpdatePrompt")
	Assert(Body != "", "Updater_ShowUpdatePrompt must exist")
	Assert(InStr(Body, "IsSet(_Updater_PromptGui)") > 0,
		"Updater_ShowUpdatePrompt must be a singleton -- a second call while a prompt is already open must reuse it instead of opening a duplicate dialog that can trigger a second concurrent download (updater-download-reentrancy)")
}
Test("updater: Updater_ShowUpdatePrompt is a singleton (updater-download-reentrancy)", _UDRG_AssertPromptSingleton)
