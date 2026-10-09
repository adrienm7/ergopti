; tests/meta/test_updater_setchannel_blocks_during_download.ahk

; ==============================================================================
; MODULE: Updater_SetChannel Download-Block Meta Test
; DESCRIPTION:
; Static source guard for finding updater-channel-switch-download-race (F27).
;
; Updater_SetChannel persists the new channel and begins a deferred Reload.
; The self-update download's WinHttp Req and poll-timer chain are tracked only
; as local closures inside Updater_DownloadAndInstall / _Updater_PollDownloadAsync
; -- never registered in the shared _UpdaterAsyncRequests map that channel-switch
; cancellation drains. Switching channel mid-download orphaned the partial file
; and abandoned the download with zero log trace.
;
; The fix blocks the channel switch while _UpdaterDownloadInProgress is true,
; reusing the same flag F10's reentrancy guard also reads. This is a
; meta-static test (calling Updater_SetChannel for real would execute Reload
; and restart the headless runner), mirroring the sibling
; test_updater_setchannel_cancels_async.ahk's approach.
; ==============================================================================

#Requires AutoHotkey v2.0


_USBD_AssertBlocksDuringDownload() {
	Body := _DriverFuncBody("Updater_SetChannel")
	Assert(Body != "", "Updater_SetChannel(Channel) declaration must exist")

	ReadIdx := InStr(Body, "DownloadActive := _UpdaterDownloadInProgress")
	BranchIdx := InStr(Body, "if DownloadActive", , ReadIdx)
	ReturnIdx := InStr(Body, "return false", , BranchIdx)
	PersistIdx := InStr(Body, "ConfigCommitBorrowedUpdates(", , ReturnIdx)
	Assert(ReadIdx > 0 and BranchIdx > ReadIdx and ReturnIdx > BranchIdx
		and PersistIdx > ReturnIdx,
		"Updater_SetChannel must branch and return on the real download flag before persistence")

	ReloadIdx := InStr(Body, "_Updater_BeginDeferredChannelReload(")
	Assert(ReloadIdx > 0,
		"Updater_SetChannel must still hand off to deferred Reload after the guard")
	Assert(ReturnIdx < ReloadIdx,
		"The _UpdaterDownloadInProgress guard must be checked BEFORE Reload -- checking after the restart already began would be too late (updater-channel-switch-download-race)")
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
