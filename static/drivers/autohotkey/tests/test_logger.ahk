; static/drivers/autohotkey/tests/test_logger.ahk

; ==============================================================================
; MODULE: Logger Tests
; DESCRIPTION:
; Assertions covering the logger's eight variants, severity filtering and
; ring-buffer behaviour. Logger writes to a temp file scoped to the test
; process so we never pollute ErgoptiPlus.log on the dev machine.
;
; FEATURES & RATIONALE:
; Tests are exposed as named helper functions and registered via Test() so
; AHK v2's strict expression parsing for fat-arrow lambdas is not exercised
; — multi-line lambdas with statements like ``for`` are not portable.
; ==============================================================================

; ── Setup: redirect logger output to a tests-only path ──
LOGGER_LOG_PATH := A_ScriptDir . "\test_run.log"
LOGGER_RING_BUFFER := []
LOGGER_RING_CURSOR := 0
LOGGER_MIN_LEVEL := "DEBUG"
_LoggerRefreshFastFlags()

_ResetLogger() {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL, _LOGGER_PENDING
	LOGGER_RING_BUFFER := []
	LOGGER_RING_CURSOR := 0
	LOGGER_MIN_LEVEL := "DEBUG"
	_LOGGER_PENDING := []
	_LoggerRefreshFastFlags()
}




; ===================
; Severity ordering
; ===================
TestLogger_SeverityOrdering() {
	AssertTrue(LOGGER_SEVERITY["DEBUG"] < LOGGER_SEVERITY["INFO"])
	AssertTrue(LOGGER_SEVERITY["INFO"] < LOGGER_SEVERITY["WARNING"])
	AssertTrue(LOGGER_SEVERITY["WARNING"] < LOGGER_SEVERITY["ERROR"])
}
Test("LOGGER_SEVERITY: DEBUG < INFO < WARNING < ERROR", TestLogger_SeverityOrdering)

TestLogger_LifecyclePairs() {
	AssertEqual(LOGGER_SEVERITY["DEBUG"], LOGGER_SEVERITY["TRACE"])
	AssertEqual(LOGGER_SEVERITY["DEBUG"], LOGGER_SEVERITY["DONE"])
	AssertEqual(LOGGER_SEVERITY["INFO"], LOGGER_SEVERITY["START"])
	AssertEqual(LOGGER_SEVERITY["INFO"], LOGGER_SEVERITY["SUCCESS"])
}
Test("LOGGER_SEVERITY: lifecycle pairs share the matching importance level",
	TestLogger_LifecyclePairs)

TestLogger_AllVariantsRegistered() {
	for V in ["DEBUG", "TRACE", "DONE", "INFO", "START", "SUCCESS", "WARNING", "ERROR"] {
		AssertTrue(LOGGER_SEVERITY.Has(V), "missing variant: " . V)
	}
}
Test("LOGGER_SEVERITY: all eight variants are registered",
	TestLogger_AllVariantsRegistered)




; ============================
; Ring buffer push / wrap
; ============================
TestLogger_RingPushOrder() {
	_ResetLogger()
	LoggerInfo("Test", "first")
	LoggerInfo("Test", "second")
	LoggerInfo("Test", "third")
	AssertEqual(3, LOGGER_RING_BUFFER.Length)
	AssertContains(LOGGER_RING_BUFFER[1], "first")
	AssertContains(LOGGER_RING_BUFFER[3], "third")
}
Test("Ring buffer: push under capacity stores in order", TestLogger_RingPushOrder)

TestLogger_RingSnapshotOrder() {
	_ResetLogger()
	LoggerInfo("Test", "a")
	LoggerInfo("Test", "b")
	Snap := LoggerRingBufferSnapshot()
	AssertEqual(2, Snap.Length)
	AssertContains(Snap[1], "a")
	AssertContains(Snap[2], "b")
}
Test("Ring buffer: snapshot returns chronological order under capacity",
	TestLogger_RingSnapshotOrder)

TestLogger_RingWraparound() {
	_ResetLogger()
	loop LOGGER_RING_BUFFER_SIZE + 5 {
		LoggerInfo("Wrap", "msg-" . A_Index)
	}
	AssertEqual(LOGGER_RING_BUFFER_SIZE, LOGGER_RING_BUFFER.Length)
	Snap := LoggerRingBufferSnapshot()
	AssertEqual(LOGGER_RING_BUFFER_SIZE, Snap.Length)
	; Oldest surviving is "msg-6" (5 messages overwritten).
	AssertContains(Snap[1], "msg-6")
	AssertContains(Snap[Snap.Length], "msg-" . (LOGGER_RING_BUFFER_SIZE + 5))
}
Test("Ring buffer: overflow wraps and snapshot reorders chronologically",
	TestLogger_RingWraparound)




; ==============================
; Level filtering
; ==============================
TestLogger_LevelFilterDropDebug() {
	global LOGGER_MIN_LEVEL
	_ResetLogger()
	LOGGER_MIN_LEVEL := "INFO"
	_LoggerRefreshFastFlags()
	LoggerDebug("Test", "should-be-dropped")
	AssertEqual(0, LOGGER_RING_BUFFER.Length)
}
Test("Level filter: DEBUG messages are dropped when min level is INFO",
	TestLogger_LevelFilterDropDebug)

TestLogger_LevelFilterPassInfo() {
	global LOGGER_MIN_LEVEL
	_ResetLogger()
	LOGGER_MIN_LEVEL := "INFO"
	_LoggerRefreshFastFlags()
	LoggerInfo("Test", "should-pass")
	AssertEqual(1, LOGGER_RING_BUFFER.Length)
}
Test("Level filter: INFO passes when min level is INFO",
	TestLogger_LevelFilterPassInfo)

TestLogger_LevelFilterPassWarnError() {
	global LOGGER_MIN_LEVEL
	_ResetLogger()
	LOGGER_MIN_LEVEL := "INFO"
	_LoggerRefreshFastFlags()
	LoggerWarn("Test", "warn")
	LoggerError("Test", "error")
	AssertEqual(2, LOGGER_RING_BUFFER.Length)
}
Test("Level filter: WARNING and ERROR pass under INFO threshold",
	TestLogger_LevelFilterPassWarnError)




; =========================
; Format string handling
; =========================
; AHK Format uses ``{N}`` placeholders (printf-like with a colon for flags),
; not ``%s`` / ``%d`` from C. The logger's _LoggerEmit forwards the message
; through Format(Msg, Args*) so callers must use AHK syntax.
TestLogger_FormatString() {
	_ResetLogger()
	LoggerInfo("Fmt", "value={1}", "hello")
	AssertContains(LOGGER_RING_BUFFER[1], "value=hello")
}
Test("Format args: {1} placeholder is interpolated", TestLogger_FormatString)

TestLogger_FormatNumber() {
	_ResetLogger()
	LoggerInfo("Fmt", "count={1}", 42)
	AssertContains(LOGGER_RING_BUFFER[1], "count=42")
}
Test("Format args: {1} placeholder accepts numbers", TestLogger_FormatNumber)

TestLogger_FormatMalformedFallback() {
	_ResetLogger()
	; A genuinely malformed format string would crash Format; the logger
	; catches the exception and writes the raw message instead.
	LoggerInfo("Fmt", "missing arg: {99}")
	AssertEqual(1, LOGGER_RING_BUFFER.Length)
}
Test("Format args: missing-arg format string still produces a line",
	TestLogger_FormatMalformedFallback)




; ==========================
; Tag and level rendering
; ==========================
TestLogger_LineHasTag() {
	_ResetLogger()
	LoggerInfo("MyTag", "x")
	AssertContains(LOGGER_RING_BUFFER[1], "[MyTag]")
}
Test("Output line: contains the tag", TestLogger_LineHasTag)

TestLogger_LineHasLevel() {
	_ResetLogger()
	LoggerWarn("Tag", "x")
	AssertContains(LOGGER_RING_BUFFER[1], "WARNING")
}
Test("Output line: contains the level name", TestLogger_LineHasLevel)

TestLogger_LineHasTimestamp() {
	_ResetLogger()
	LoggerInfo("Tag", "x")
	AssertTrue(RegExMatch(LOGGER_RING_BUFFER[1], "^\d{4}-") > 0)
}
Test("Output line: contains a timestamp prefix", TestLogger_LineHasTimestamp)




; ==========================
; All eight variants emit
; ==========================
TestLogger_DebugEmits() {
	_ResetLogger()
	LoggerDebug("T", "dbg")
	AssertEqual(1, LOGGER_RING_BUFFER.Length)
	AssertContains(LOGGER_RING_BUFFER[1], "DEBUG")
}
Test("LoggerDebug: emits a DEBUG line", TestLogger_DebugEmits)

TestLogger_TraceEmits() {
	_ResetLogger()
	LoggerTrace("T", "trc")
	AssertEqual(1, LOGGER_RING_BUFFER.Length)
	AssertContains(LOGGER_RING_BUFFER[1], "TRACE")
}
Test("LoggerTrace: emits a TRACE line", TestLogger_TraceEmits)

TestLogger_DoneEmits() {
	_ResetLogger()
	LoggerDone("T", "done")
	AssertEqual(1, LOGGER_RING_BUFFER.Length)
	AssertContains(LOGGER_RING_BUFFER[1], "DONE")
}
Test("LoggerDone: emits a DONE line", TestLogger_DoneEmits)

TestLogger_StartEmits() {
	_ResetLogger()
	LoggerStart("T", "start")
	AssertEqual(1, LOGGER_RING_BUFFER.Length)
	AssertContains(LOGGER_RING_BUFFER[1], "START")
}
Test("LoggerStart: emits a START line", TestLogger_StartEmits)

TestLogger_SuccessEmits() {
	_ResetLogger()
	LoggerSuccess("T", "success")
	AssertEqual(1, LOGGER_RING_BUFFER.Length)
	AssertContains(LOGGER_RING_BUFFER[1], "SUCCESS")
}
Test("LoggerSuccess: emits a SUCCESS line", TestLogger_SuccessEmits)

TestLogger_ErrorEmits() {
	_ResetLogger()
	LoggerError("T", "err")
	AssertEqual(1, LOGGER_RING_BUFFER.Length)
	AssertContains(LOGGER_RING_BUFFER[1], "ERROR")
}
Test("LoggerError: emits an ERROR line", TestLogger_ErrorEmits)




; ==========================
; Level filter — strict thresholds
; ==========================
TestLogger_LevelFilterDropTrace() {
	global LOGGER_MIN_LEVEL
	_ResetLogger()
	LOGGER_MIN_LEVEL := "INFO"
	_LoggerRefreshFastFlags()
	LoggerTrace("T", "dropped")
	AssertEqual(0, LOGGER_RING_BUFFER.Length)
}
Test("Level filter: TRACE is dropped when min level is INFO", TestLogger_LevelFilterDropTrace)

TestLogger_LevelFilterDropDone() {
	global LOGGER_MIN_LEVEL
	_ResetLogger()
	LOGGER_MIN_LEVEL := "INFO"
	_LoggerRefreshFastFlags()
	LoggerDone("T", "dropped")
	AssertEqual(0, LOGGER_RING_BUFFER.Length)
}
Test("Level filter: DONE is dropped when min level is INFO", TestLogger_LevelFilterDropDone)

TestLogger_LevelErrorThreshold() {
	global LOGGER_MIN_LEVEL
	_ResetLogger()
	LOGGER_MIN_LEVEL := "ERROR"
	_LoggerRefreshFastFlags()
	LoggerWarn("T", "dropped")
	LoggerInfo("T", "dropped")
	LoggerError("T", "kept")
	AssertEqual(1, LOGGER_RING_BUFFER.Length)
	AssertContains(LOGGER_RING_BUFFER[1], "ERROR")
}
Test("Level filter: ERROR threshold drops WARN and INFO", TestLogger_LevelErrorThreshold)




; ==========================
; Ring buffer size constant
; ==========================
TestLogger_RingBufferSizePositive() {
	AssertTrue(LOGGER_RING_BUFFER_SIZE > 0)
}
Test("LOGGER_RING_BUFFER_SIZE: positive constant defined", TestLogger_RingBufferSizePositive)

TestLogger_RingBufferSizeReasonable() {
	; Must be at least 10 to be useful, at most 10000 to avoid memory waste
	AssertTrue(LOGGER_RING_BUFFER_SIZE >= 10)
	AssertTrue(LOGGER_RING_BUFFER_SIZE <= 10000)
}
Test("LOGGER_RING_BUFFER_SIZE: between 10 and 10000", TestLogger_RingBufferSizeReasonable)




; ==========================
; Snapshot ordering — multiple wraps
; ==========================
TestLogger_SnapshotAfterDoubleWrap() {
	_ResetLogger()
	; Write 2× the buffer size to force two full wrap-arounds
	Total := LOGGER_RING_BUFFER_SIZE * 2 + 3
	loop Total {
		LoggerInfo("Wrap2", "msg-" . A_Index)
	}
	Snap := LoggerRingBufferSnapshot()
	AssertEqual(LOGGER_RING_BUFFER_SIZE, Snap.Length)
	; The last message in the snapshot must be the very last emitted
	AssertContains(Snap[Snap.Length], "msg-" . Total)
}
Test("Ring buffer: snapshot is correct after double wrap-around",
	TestLogger_SnapshotAfterDoubleWrap)




; ==========================
; Daily-rotation log purge
; ==========================
; Helper: writes a log file with a date-stamp, optionally back-dated, then
; touches its timestamp via FileSetTime so tests don't depend on real wall time.
TestLogger_MakeOldLog(LogDir, DateStr) {
	Path := LogDir . "ErgoptiPlus_" . DateStr . ".log"
	fh := FileOpen(Path, "w", "UTF-8")
	fh.Write("test content")
	fh.Close()
	return Path
}

TestLogger_PurgeRemovesOldFiles() {
	LogDir := A_Temp . "\ergopti_purge_test_" . A_Now . "\"
	if !DirExist(LogDir) {
		DirCreate(LogDir)
	}

	; Today's file (must survive)
	Today := FormatTime(, "yyyy-MM-dd")
	TodayPath := TestLogger_MakeOldLog(LogDir, Today)

	; A file 7 days ago (must survive — within 14-day window)
	Recent := SubStr(DateAdd(A_Now, -7, "Days"), 1, 8)
	RecentDateStr := SubStr(Recent, 1, 4) . "-" . SubStr(Recent, 5, 2) . "-" . SubStr(Recent, 7, 2)
	RecentPath := TestLogger_MakeOldLog(LogDir, RecentDateStr)

	; A file 30 days ago (must be deleted)
	Old := SubStr(DateAdd(A_Now, -30, "Days"), 1, 8)
	OldDateStr := SubStr(Old, 1, 4) . "-" . SubStr(Old, 5, 2) . "-" . SubStr(Old, 7, 2)
	OldPath := TestLogger_MakeOldLog(LogDir, OldDateStr)

	_LoggerPurgeOldLogs(LogDir, 14)

	AssertTrue(FileExist(TodayPath) != "", "today's log should survive")
	AssertTrue(FileExist(RecentPath) != "", "7-day-old log should survive (within 14 days)")
	AssertEqual("", FileExist(OldPath), "30-day-old log should be deleted")

	; Cleanup — best-effort
	try FileDelete(TodayPath)
	try FileDelete(RecentPath)
	try DirDelete(LogDir)
}
Test("LoggerPurgeOldLogs: deletes files older than max age, keeps recent ones",
	TestLogger_PurgeRemovesOldFiles)

TestLogger_PurgeIgnoresUnrelatedFiles() {
	; Files not matching the ErgoptiPlus_YYYY-MM-DD.log pattern must not be touched.
	LogDir := A_Temp . "\ergopti_purge_unrelated_" . A_Now . "\"
	if !DirExist(LogDir) {
		DirCreate(LogDir)
	}
	OtherPath := LogDir . "random_file.log"
	fh := FileOpen(OtherPath, "w", "UTF-8")
	fh.Write("not ours")
	fh.Close()

	_LoggerPurgeOldLogs(LogDir, 1)

	AssertTrue(FileExist(OtherPath) != "", "non-matching file must not be deleted")
	try FileDelete(OtherPath)
	try DirDelete(LogDir)
}
Test("LoggerPurgeOldLogs: leaves files that don't match the pattern alone",
	TestLogger_PurgeIgnoresUnrelatedFiles)

TestLogger_PurgeMissingDir() {
	; A non-existent dir must not throw.
	NoDir := A_Temp . "\definitely_missing_" . A_Now . "\"
	_LoggerPurgeOldLogs(NoDir, 14)
	AssertTrue(true, "purge with missing dir should not throw")
}
Test("LoggerPurgeOldLogs: missing directory is silently ignored",
	TestLogger_PurgeMissingDir)





; ==================================================
; =================================================
; ======= 5/ Test sink (injectable capture) =======
; =================================================
; ==================================================

TestLogger_SinkReceivesLine() {
	_ResetLogger()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	LoggerInfo("Sink", "hello-sink")
	AssertEqual(1, Captured.Length)
	AssertContains(Captured[1], "hello-sink")
	LoggerClearTestSink()
}
Test("Test sink: sink receives the emitted line", TestLogger_SinkReceivesLine)

TestLogger_SinkReceivesLevel() {
	_ResetLogger()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	LoggerInfo("Sink", "level-check")
	AssertEqual(1, Captured.Length)
	AssertContains(Captured[1], "[INFO]")
	LoggerClearTestSink()
}
Test("Test sink: emitted line contains the level name", TestLogger_SinkReceivesLevel)

TestLogger_SinkNotCalledWhenFiltered() {
	global LOGGER_MIN_LEVEL
	_ResetLogger()
	LOGGER_MIN_LEVEL := "INFO"
	_LoggerRefreshFastFlags()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	LoggerDebug("Sink", "should-be-filtered")
	AssertEqual(0, Captured.Length)
	LoggerClearTestSink()
}
Test("Test sink: sink is not called for filtered-out messages",
	TestLogger_SinkNotCalledWhenFiltered)

TestLogger_SinkClearedByReset() {
	_ResetLogger()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	LoggerClearTestSink()
	LoggerInfo("Sink", "should-not-reach-sink")
	AssertEqual(0, Captured.Length)
}
Test("Test sink: cleared sink does not receive subsequent lines",
	TestLogger_SinkClearedByReset)
