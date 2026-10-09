; tests/meta/test_updater_download_receive_timeout.ahk

; ==============================================================================
; MODULE: Updater Download Receive-Timeout Meta Test
; DESCRIPTION:
; Static source guard for finding updater-download-receive-timeout (S-01).
;
; Updater_DownloadAndInstall passed UPDATER_HTTP_RECEIVE_TIMEOUT_MS (30 s, sized for
; the tiny JSON API calls) as the WinHttpRequest receive timeout for the multi-MB
; binary asset GET. For ComObject("WinHttp.WinHttpRequest.5.1") that bounds the whole
; response receive, so a slow/metered link is aborted at 30 s — defeating the 600 s
; SetTimer poll ceiling, which only governs the poll loop, not the WinHTTP layer.
;
; The fix introduces a dedicated UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS (>= the poll
; ceiling) and passes it as the download receive slot. A larger receive budget is
; strictly safer regardless of the exact COM receive semantics, so the fix is applied
; defensively. Meta-static source scan of the driver.
; ==============================================================================

#Requires AutoHotkey v2.0


_UDRT_AssertDownloadReceiveBudget() {
	Body := _DriverFuncBody("_Updater_StartStagingWorker")
	Assert(Body != "", "_Updater_StartStagingWorker must exist")
	Assert(InStr(Body, "UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS") > 0,
		"_Updater_StartStagingWorker must pass the dedicated download timeout to the worker, not the 30 s API budget (updater-download-receive-timeout)")
	SplitPath(A_ScriptDir, , &Root)
	Core := FileRead(StrReplace(Root, "\", "/") . "/modules/updater/core.ahk")
	m := ""
	Assert(RegExMatch(Core, "UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS\s*:=\s*(\d+)", &m) > 0,
		"core.ahk must define UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS (updater-download-receive-timeout)")
	Assert(Integer(m[1]) >= 600000,
		"UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS must be >= the 600 s poll ceiling so the download is not aborted before the poll deadline (updater-download-receive-timeout)")
	Worker := _DriverFuncBody("_Updater_BuildStagingWorkerScript")
	Assert(InStr(Worker, "$Request.ReadWriteTimeout = $TimeoutMs") > 0,
		"the worker must apply the dedicated budget while streaming the binary")
}
Test("updater: download uses a dedicated large receive timeout, not the 30s API budget (updater-download-receive-timeout)", _UDRT_AssertDownloadReceiveBudget)
