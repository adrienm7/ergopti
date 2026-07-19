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

_UFNB_DownloadGuardSpansFinalization() {
	Body := _DriverFuncBody("_Updater_PollDownloadAsync")
	ReadyPos := InStr(Body, "ready := Req.WaitForResponse(0)")
	SavePos := InStr(Body, "Stream.SaveToFile")
	SwapPos := InStr(Body, "Run('cmd /c")
	FailureBranchPos := InStr(Body, "if (failed or Req.Status != 200)")
	Assert(ReadyPos > 0 && SavePos > ReadyPos && SwapPos > SavePos,
		"poll finalization must include persistence and swap launch after the response becomes ready")
	PreFinalization := SubStr(Body, ReadyPos, FailureBranchPos - ReadyPos)
	Assert(!InStr(PreFinalization, "_Updater_EndDownloadTransaction()"),
		"download guard must not be released immediately after WaitForResponse; it must span response persistence")
	Assert(InStr(Body, "_UpdaterDownloadInProgress := false") = 0,
		"only _Updater_EndDownloadTransaction may release the updater guard, preventing an early duplicate install")
}
Test("updater: download guard remains owned through finalization", _UFNB_DownloadGuardSpansFinalization)
