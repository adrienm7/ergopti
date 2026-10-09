; tests/meta/test_keylogger_deferred_write.ahk

#Requires AutoHotkey v2.0

_KDW_AssertDeferredWrite() {
	AppendBody := _DriverFuncBody("KL_AppendLog")

	InlineWriteIdx := InStr(AppendBody, "fh.Write(")
	Assert(!InlineWriteIdx, "KL_AppendLog must NOT call fh.Write() inline (kl-synchronous-disk-write-on-keystroke)")
	Assert(InStr(AppendBody, "_KL_JournalAppendDefault(") = 0,
		"KL_AppendLog must not call the receipt-validating journal writer inline")

	IngestBody := _DriverFuncBody("KL_IngestOnce")

	DeferredWriteIdx := InStr(IngestBody, "_KL_JournalAppendDefault(fh, line)")
	Assert(DeferredWriteIdx > 0,
		"KL_IngestOnce must write pending_snapshot through the counted, rollback-safe journal writer off the hot path")
}

Test("keylogger: Keystroke log writes are deferred off the hot path (kl-synchronous-disk-write-on-keystroke)", _KDW_AssertDeferredWrite)
