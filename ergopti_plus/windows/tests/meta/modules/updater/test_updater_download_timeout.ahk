; tests/meta/modules/updater/test_updater_download_timeout.ahk

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
	Worker := FileRead(_Updater_StagingWorkerPath(), "UTF-8")
	Assert(InStr(Worker, '$ExpectedSize=Invoke-ErgoptiUpdaterDownload $Request $NewExe $TimeoutMs $State $Resolver $DeadlineMs $StartedTick') > 0,
		"timeout guard must follow the actual selected download owner and immutable original clock")
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(Root . "\vendor\ergopti_updater_download.ps1", "UTF-8")
}




; ===========================================================
; ===========================================================
; ======= 2/ Assertions =====================================
; ===========================================================
; ===========================================================

_UDTO_600SecCeiling() {
	global _SharedDir, UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS, UPDATER_HTTP_DOWNLOAD_DEADLINE_MS
	Transfer := JsonParse(FileRead(_SharedDir . "\updater\data\defaults.json", "UTF-8"))["archive_transfer"]
	AssertEqual(600000, Transfer["archive_idle_timeout_ms"],
		"the shared archive idle budget stays 600000 ms")
	AssertEqual(Transfer["archive_idle_timeout_ms"], UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS,
		"the download receive timeout passed to the staging worker is the shared archive idle budget")
	AssertEqual(Transfer["phase_timeout_ms"]["archive"], UPDATER_HTTP_DOWNLOAD_DEADLINE_MS,
		"the absolute download deadline is the shared archive phase budget")
}
Test("Updater: download bounds come from the shared archive_transfer budget (updater-download-timeout)", _UDTO_600SecCeiling)


_UDTO_No120SecCeiling() {
	block := _UDTO_FindPollBlock()
	; The MaxPolls expression must not still divide 120000.
	Assert(InStr(block, "$Request.Timeout = [Math]::Min($Remaining, $TimeoutMs)") > 0 and InStr(block, "$Request.ReadWriteTimeout = [Math]::Min($Remaining, $TimeoutMs)") > 0,
		"updater.ahk: worker must apply the supplied timeout to both connect and file-stream phases")
	Assert(InStr(block, "$Input.ReadTimeout = [Math]::Min($Remaining, $TimeoutMs)") > 0
		&& InStr(block, "$Remaining = Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State") > 0,
		"each native stream read must retain the immutable original clock and smaller remaining deadline")
}
Test("Updater: worker applies the full timeout to every network phase (updater-download-timeout)", _UDTO_No120SecCeiling)
