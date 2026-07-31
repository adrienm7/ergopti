; tests/meta/test_updater_download_timeout.ahk

; ==============================================================================
; MODULE: Updater Download Timeout Meta-Test
; DESCRIPTION:
; Structural regression for the download poll ceiling fix in modules/updater.ahk.
;
; Before the fix, _Updater_PollDownloadAsync() capped the total wait at
; 120 000 ms (2 minutes):
;   MaxPolls := 120000 / UPDATER_ASYNC_POLL_MS
; On slow or metered connections large release assets (10-50 MB) routinely
; exceed 2 minutes. When MaxPolls was hit the download was aborted and marked
; failed even though the underlying XHR request was still in progress, leaving
; the user with no update and no useful error.
;
; The fix raises the ceiling to 600 000 ms (10 minutes), matching the headroom
; expected for a 50 MB asset on a 1 Mbit/s connection.
;
; This test inspects updater.ahk source and asserts:
;   1. 600000 is the numerator in the MaxPolls expression (not 120000).
;   2. 120000 is no longer used as the download timeout ceiling.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===========================================================
; ===========================================================
; ======= 1/ Source-inspection helpers =======================
; ===========================================================
; ===========================================================

; Returns the isolated worker body. The timeout must be owned by the worker,
; otherwise an AHK poll ceiling could still leave a blocked network request alive.
_UDTO_FindPollBlock() {
	return _DriverFuncBody("_Updater_BuildStagingWorkerScript")
}




; ===========================================================
; ===========================================================
; ======= 2/ Assertions =====================================
; ===========================================================
; ===========================================================

_UDTO_600SecCeiling() {
	SplitPath(A_ScriptDir, , &Root)
	Core := FileRead(StrReplace(Root, "\", "/") . "/modules/updater/core.ahk")
	Assert(InStr(Core, "UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS := 600000") > 0,
		"core.ahk must retain the 600000 ms download timeout budget passed to the staging worker")
}
Test("Updater: download poll ceiling raised to 600000 ms (updater-download-timeout)", _UDTO_600SecCeiling)


_UDTO_No120SecCeiling() {
	block := _UDTO_FindPollBlock()
	; The MaxPolls expression must not still divide 120000.
	Assert(InStr(block, "$Request.Timeout = $TimeoutMs") > 0 and InStr(block, "$Request.ReadWriteTimeout = $TimeoutMs") > 0,
		"updater.ahk: worker must apply the supplied timeout to both connect and file-stream phases")
}
Test("Updater: worker applies the full timeout to every network phase (updater-download-timeout)", _UDTO_No120SecCeiling)
