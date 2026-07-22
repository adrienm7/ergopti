; tests/meta/test_updater_setchannel_blocks_during_download.ahk

; ==============================================================================
; MODULE: Updater_SetChannel Download-Block Meta Test
; DESCRIPTION:
; Static source guard for finding updater-channel-switch-download-race (F27).
;
; Updater_SetChannel persists the new channel and calls Reload unconditionally.
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

	GuardIdx := InStr(Body, "_UpdaterDownloadInProgress")
	Assert(GuardIdx > 0,
		"Updater_SetChannel must reference _UpdaterDownloadInProgress to block the switch while a download is running (updater-channel-switch-download-race)")

	ReloadIdx := InStr(Body, "Reload")
	Assert(ReloadIdx > 0, "Updater_SetChannel must still Reload after the guard")
	Assert(GuardIdx < ReloadIdx,
		"The _UpdaterDownloadInProgress guard must be checked BEFORE Reload -- checking after the restart already began would be too late (updater-channel-switch-download-race)")
}
Test("updater: Updater_SetChannel blocks the channel switch while a download is in progress (updater-channel-switch-download-race)", _USBD_AssertBlocksDuringDownload)
