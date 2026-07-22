; tests/meta/test_logger_sync_warning.ahk

#Requires AutoHotkey v2.0

_LSW_AssertWarningFlushBehavior() {
	; Move-resilient: locate _LoggerEmit() across the whole driver source via the
	; framework helper instead of a pinned lib path
	EmitBody := _DriverFuncBody("_LoggerEmit")

	; The force flush condition should check for ERROR, not WARNING
	WarnFlushIdx := InStr(EmitBody, 'LOGGER_SEVERITY[Level] >= LOGGER_SEVERITY["WARNING"] {`n			_LoggerFlush(true)')
	Assert(!WarnFlushIdx, "_LoggerEmit must NOT force flush for WARNING (logger-sync-double-write-on-warning)")
	
	ErrorFlushIdx := InStr(EmitBody, 'LOGGER_SEVERITY["ERROR"]')
	Assert(ErrorFlushIdx > 0, "_LoggerEmit must force flush only for ERROR or higher (logger-sync-double-write-on-warning)")
	
	; The errors log should be written via the flush batching, not inline
	InlineErrorWriteIdx := InStr(EmitBody, "FileOpen(LOGGER_ERRORS_LOG_PATH")
	Assert(!InlineErrorWriteIdx, "_LoggerEmit must NOT write to LOGGER_ERRORS_LOG_PATH inline (logger-sync-double-write-on-warning)")
}

Test("logger: Warnings do not trigger synchronous flushes or inline writes (logger-sync-double-write-on-warning)", _LSW_AssertWarningFlushBehavior)
