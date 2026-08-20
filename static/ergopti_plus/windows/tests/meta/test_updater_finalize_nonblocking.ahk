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
	Assert(InStr(Body, 'Stdout != "READY"') > 0
		and InStr(Body, "_Updater_StartSwapTransaction(") > 0,
		"download completion must require staging readiness before the bounded native swap hand-off")
	Assert(InStr(Body, "Run(") = 0 and InStr(Body, "ExitApp(") = 0,
		"staging completion must neither fire-and-forget a shell nor create a launch-to-exit gap")
}
Test("updater: download completion keeps staging I/O out of the hook thread (updater-finalize-nonblocking)", _UFNB_FinalizerRunsNoStagingIo)

_UFNB_DownloadGuardSpansFinalization() {
	Body := _DriverFuncBody("_Updater_PollDownloadAsync")
	StartBody := _DriverFuncBody("_Updater_StartStagingWorker")
	Assert(StartBody != "", "_Updater_StartStagingWorker must exist")
	SpawnPos := InStr(StartBody, "ShellRunner_SpawnTreeOwned")
	Assert(SpawnPos > 0 and InStr(StartBody, "Worker.start()") > SpawnPos,
		"the staging worker must be launched through the asynchronous tree-owned ShellRunner adapter")
	StartCallPos := InStr(StartBody, "Worker.start()")
	EndPos := InStr(StartBody, "_Updater_EndDownloadTransaction(StagingEpoch)")
	TimerPos := InStr(StartBody, "SetTimer(_Updater_MonitorStagingWorker")
	Assert(StartCallPos > SpawnPos and EndPos > StartCallPos and TimerPos > EndPos,
		"the download guard may release only on failed worker launch; a successful launch must arm monitoring and retain ownership until completion or cancellation")
	Assert(InStr(Body, "_UpdaterDownloadInProgress := false") = 0,
		"only _Updater_EndDownloadTransaction may release the updater guard, preventing an early duplicate install")
}
Test("updater: download guard remains owned through finalization", _UFNB_DownloadGuardSpansFinalization)

_UFNB_HandshakePollsOnlyZeroTimeoutHandles() {
	PollBody := _DriverFuncBody("_Updater_PollSwapHandshake")
	WaitBody := _DriverFuncBody("_Updater_WaitHandleState")
	NativeWaitBody := _DriverFuncBody("PLC_WaitHandle")
	Assert(PollBody != "" and WaitBody != "" and NativeWaitBody != "",
		"the swap handshake poller and process-lifecycle wait adapter must exist")
	Assert(InStr(WaitBody, "PLC_WaitHandle(Handle, 0)") > 0
		and InStr(NativeWaitBody, "WaitForSingleObject") > 0
		and InStr(NativeWaitBody, '"UInt", TimeoutMs') > 0,
		"AHK may only zero-time probe swap handles; blocking waits belong to the detached child")
	for Forbidden in ["Sleep(", "FileRead(", "FileExist(", "Run(", "RunWait(", "WinHttp", "Critical("] {
		Assert(InStr(PollBody, Forbidden) = 0,
			"the swap handshake timer must not perform " . Forbidden . " on the keyboard thread")
	}
}

Test("updater: swap handshake timer is nonblocking and performs no I/O",
	_UFNB_HandshakePollsOnlyZeroTimeoutHandles)
