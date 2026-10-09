; tests/meta/test_logger_fanout_batched.ahk

; ==============================================================================
; MODULE: Logger Fan-out Batched Meta Test
; DESCRIPTION:
; Regression guard ensuring _LoggerFanOut does not call FileAppend synchronously
; on every matching log line. Fan-out lines must be buffered in
; _LOGGER_SUB_PENDING and drained in batches by _LoggerFlush, the same pattern
; used by the main log queue.
;
; SCOPE: source introspection of infra/logger.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_LFOB_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_LFOB_CheckFanOutNoDirectAppend() {
	Src := _LFOB_ReadSource("infra/logger.ahk")
	Assert(Src != "", "infra/logger.ahk must be readable")

	FanOut := _DriverFuncBody("_LoggerFanOut")
	Assert(FanOut != "", "_LoggerFanOut must exist in infra/logger.ahk")

	Assert(!InStr(FanOut, "FileAppend"),
		"_LoggerFanOut must not call FileAppend directly — buffer in _LOGGER_SUB_PENDING and drain in _LoggerFlush")
}

_LFOB_CheckSubPendingQueue() {
	Src := _LFOB_ReadSource("infra/logger.ahk")
	Assert(Src != "", "infra/logger.ahk must be readable")

	Assert(InStr(Src, "_LOGGER_SUB_PENDING"),
		"infra/logger.ahk must declare _LOGGER_SUB_PENDING for batched fan-out line buffering")
}

_LFOB_CheckFlushDrainsSubPending() {
	Src := _LFOB_ReadSource("infra/logger.ahk")
	Assert(Src != "", "infra/logger.ahk must be readable")

	; The public wrapper serializes ownership; the owned implementation performs
	; the actual snapshot and sink writes.
	Flush := _DriverFuncBody("_LoggerFlushOwned")
	Assert(Flush != "", "_LoggerFlushOwned must exist in infra/logger.ahk")

	Assert(InStr(Flush, "_LOGGER_SUB_PENDING"),
		"_LoggerFlushOwned must drain _LOGGER_SUB_PENDING to write batched fan-out lines")
	Assert(InStr(Flush, "_LoggerRequeueSub(Name, Lines)"),
		"a failed or unresolved sub-file sink must requeue its exact snapshot")
	Assert(InStr(Flush, "SubWritten := _LoggerAppendComplete("),
		"_LoggerFlushOwned must require a complete append receipt before dropping a sub-file batch")
	Requeue := _DriverFuncBody("_LoggerRequeueSub")
	Assert(Requeue != "", "_LoggerRequeueSub must exist for failed sub-file writes")
	Assert(InStr(Requeue, "Restored.Push(Line)") && InStr(Requeue, "Critical("),
		"sub-file retries must preserve order while synchronizing with new log entries")
}


Test("meta logger-fanout: _LoggerFanOut does not call FileAppend directly",
	_LFOB_CheckFanOutNoDirectAppend)

Test("meta logger-fanout: _LOGGER_SUB_PENDING queue declared for fan-out batching",
	_LFOB_CheckSubPendingQueue)

Test("meta logger-fanout: _LoggerFlush drains _LOGGER_SUB_PENDING",
	_LFOB_CheckFlushDrainsSubPending)
