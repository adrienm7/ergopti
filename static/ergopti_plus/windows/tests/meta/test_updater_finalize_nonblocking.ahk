; tests/meta/test_updater_finalize_nonblocking.ahk
#Requires AutoHotkey v2.0

_UFNB_FinalizerRunsNoStagingIo() {
	Body := _DriverFuncBody("_Updater_PollDownloadAsync")
	Assert(Body != "", "_Updater_PollDownloadAsync must exist")
	Assert(InStr(Body, "Critical(") = 0,
		"download finalization must not hold Critical across process hand-off (updater-finalize-nonblocking)")
	for Forbidden in ["ADODB.Stream", "ResponseBody", "SaveToFile", "FileAppend(", "FileGetSize(", "FileDelete(", "Sleep("] {
		Assert(InStr(Body, Forbidden) = 0,
			"download completion must not perform " . Forbidden . " on the AHK hook thread (updater-finalize-nonblocking)")
	}
	Assert(InStr(Body, 'Stdout != "READY"') > 0 and InStr(Body, "Run(A_ComSpec") > 0,
		"download completion must require worker readiness before the bounded swap hand-off")
}
Test("updater: download completion keeps staging I/O out of the hook thread (updater-finalize-nonblocking)", _UFNB_FinalizerRunsNoStagingIo)

_UFNB_DownloadGuardSpansFinalization() {
	Body := _DriverFuncBody("_Updater_PollDownloadAsync")
	StartBody := _DriverFuncBody("_Updater_StartStagingWorker")
	Assert(StartBody != "", "_Updater_StartStagingWorker must exist")
	SpawnPos := InStr(StartBody, "ShellRunner_Spawn")
	Assert(SpawnPos > 0 and InStr(StartBody, "_UpdaterDownloadWorker.start()") > SpawnPos,
		"the staging worker must be launched through the asynchronous ShellRunner adapter")
	StartCallPos := InStr(StartBody, "_UpdaterDownloadWorker.start()")
	EndPos := InStr(StartBody, "_Updater_EndDownloadTransaction()")
	TimerPos := InStr(StartBody, "SetTimer(_Updater_MonitorStagingWorker")
	Assert(StartCallPos > SpawnPos and EndPos > StartCallPos and TimerPos > EndPos,
		"the download guard may release only on failed worker launch; a successful launch must arm monitoring and retain ownership until completion or cancellation")
	Assert(InStr(Body, "_UpdaterDownloadInProgress := false") = 0,
		"only _Updater_EndDownloadTransaction may release the updater guard, preventing an early duplicate install")
}
Test("updater: download guard remains owned through finalization", _UFNB_DownloadGuardSpansFinalization)
