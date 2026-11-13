; tests/meta/updater/test_setchannel_blocks_during_download.ahk

; ==============================================================================
; MODULE: Updater_SetChannel Download-Block Meta Test
; DESCRIPTION:
; Behaviour guard for finding updater-channel-switch-download-race (F27).
;
; Updater_SetChannel persists the new channel and begins a deferred Reload.
; The self-update download's WinHttp Req and poll-timer chain are tracked only
; as local closures inside Updater_DownloadAndInstall / _Updater_PollDownloadAsync
; -- never registered in the shared _UpdaterAsyncRequests map that channel-switch
; cancellation drains. Switching channel mid-download orphaned the partial file
; and abandoned the download with zero log trace.
;
; The fix blocks the channel switch while _UpdaterDownloadInProgress is true,
; reusing the same flag F10's reentrancy guard also reads. The real function runs
; over its write and reload ports, so a broken guard writes or reloads here and
; never restarts the headless runner. The action lease below stays a source scan:
; a span across a worker handoff has no observable answer in this process.
; ==============================================================================

#Requires AutoHotkey v2.0


_USBD_AssertBlocksDuringDownload() {
	global _UpdaterDownloadInProgress, UPDATER_CHANNEL
	Saved := _UpdaterDownloadInProgress
	Target := UPDATER_CHANNEL == "dev" ? "main" : "dev"
	Writes := 0, Reloads := 0
	WriteFn := (*) => (Writes += 1, true)
	ReloadFn := (*) => (Reloads += 1, true)
	_UpdaterDownloadInProgress := true
	try
		Answer := Updater_SetChannel(Target, unset, false, (*) => 0, WriteFn, ReloadFn, (*) => 0, (*) => 0, (*) => 0)
	finally
		_UpdaterDownloadInProgress := Saved
	AssertEqual(false, Answer, "a channel switch is refused while a download runs")
	AssertEqual(0, Writes, "the refused channel is not persisted")
	AssertEqual(0, Reloads, "no restart begins under a running download (updater-channel-switch-download-race)")
	Assert(UPDATER_CHANNEL != Target, "the channel in force is unchanged")
}
Test("updater: Updater_SetChannel blocks the channel switch while a download is in progress (updater-channel-switch-download-race)", _USBD_AssertBlocksDuringDownload)

_USBD_DownloadLeaseSpansStagingHandoff() {
	Body := _DriverFuncBody("Updater_DownloadAndInstall")
	ReserveBody := _DriverFuncBody(
		"_Updater_TryReserveDownloadTransaction")
	Assert(Body != "" and ReserveBody != "",
		"the download path and reservation helper must exist")
	AcquireIdx := InStr(Body, "_Updater_AcquireAsyncActionLease(")
	RefusalIdx := InStr(Body, "if !IsObject(ActionOwner)")
	RefusalReturnIdx := RefusalIdx > 0
		? InStr(Body, "return false", , RefusalIdx) : 0
	BeginIdx := InStr(Body, "_Updater_BeginDownloadTransaction(")
	WorkerIdx := InStr(Body, "_Updater_StartStagingWorker(")
	FinallyIdx := WorkerIdx > 0 ? InStr(Body, "finally", , WorkerIdx) : 0
	ReleaseIdx := FinallyIdx > 0
		? InStr(Body, "_Updater_ReleaseAsyncActionLease(", , FinallyIdx) : 0
	ClaimIdx := InStr(ReserveBody, "_UpdaterDownloadInProgress := true")
	RequestIdx := InStr(ReserveBody,
		"_UpdaterDownloadRequest := Request", , ClaimIdx)
	Assert(AcquireIdx > 0 and RefusalIdx > AcquireIdx
		and RefusalReturnIdx > RefusalIdx and BeginIdx > RefusalReturnIdx
		and WorkerIdx > BeginIdx and ClaimIdx > 0 and RequestIdx > ClaimIdx
		and FinallyIdx > WorkerIdx and ReleaseIdx > FinallyIdx,
		"download action refusal must return before lifecycle begin, while the exact reserved request and accepted action lease span worker handoff until finally")
}
Test("updater AHK-31: download action lease spans staging handoff (updater-channel-replacement-transaction)",
	_USBD_DownloadLeaseSpansStagingHandoff)
