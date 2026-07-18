; tests/meta/test_updater_finalize_nonblocking.ahk
#Requires AutoHotkey v2.0

_UFNB_FinalizerDoesNotHoldCriticalAcrossIo() {
	Body := _DriverFuncBody("_Updater_PollDownloadAsync")
	Assert(Body != "", "_Updater_PollDownloadAsync must exist")
	Assert(InStr(Body, "Critical(") = 0,
		"download finalization must not hold Critical across COM, file I/O, process launch, or Sleep (updater-finalize-nonblocking)")
	Assert(InStr(Body, "Stream.SaveToFile") > 0 and InStr(Body, "FileAppend(BatLines") > 0 and InStr(Body, "Run(") > 0,
		"the nonblocking guard must cover the real download finalization side effects")
}
Test("updater: download finalization performs I/O outside Critical (updater-finalize-nonblocking)", _UFNB_FinalizerDoesNotHoldCriticalAcrossIo)
