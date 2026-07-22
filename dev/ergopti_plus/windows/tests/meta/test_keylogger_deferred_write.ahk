; tests/meta/test_keylogger_deferred_write.ahk

#Requires AutoHotkey v2.0

_KDW_AssertDeferredWrite() {
	AppendBody := _DriverFuncBody("KL_AppendLog")

	InlineWriteIdx := InStr(AppendBody, "fh.Write(")
	Assert(!InlineWriteIdx, "KL_AppendLog must NOT call fh.Write() inline (kl-synchronous-disk-write-on-keystroke)")

	IngestBody := _DriverFuncBody("KL_IngestOnce")

	DeferredWriteIdx := InStr(IngestBody, "fh.Write(")
	Assert(DeferredWriteIdx > 0, "KL_IngestOnce must write pending_snapshot to disk (kl-synchronous-disk-write-on-keystroke)")
}

Test("keylogger: Keystroke log writes are deferred off the hot path (kl-synchronous-disk-write-on-keystroke)", _KDW_AssertDeferredWrite)
