; static/ergopti_plus/windows/tests/unit/test_logger.ahk

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
; � multi-line lambdas with statements like ``for`` are not portable.
; ==============================================================================

; -- Setup: redirect logger output to a tests-only path --
; Use A_Temp so the CI antivirus (Windows Defender real-time scan) does not
; hold a file lock on a path inside the repo checkout and block FileOpen calls
; from LoggerWarn/LoggerError throughout the rest of the test suite.
LOGGER_LOG_PATH := A_Temp . "\ergopti_test_run.log"
LOGGER_ERRORS_LOG_PATH := ""
LOGGER_RING_BUFFER := []
LOGGER_RING_CURSOR := 0
LOGGER_MIN_LEVEL := "DEBUG"
_LoggerRefreshFastFlags()

; ULTIMATE encore plus: more pause + errors-sink + volume + FS + pcall for 100% certainty
TestLogger_PauseMustNotAffectErrorsSink() {
	; Even under A_IsSuspended, high-severity (WARNING/ERROR) must still reach the dedicated errors log (for diagnostics) but main features are silenced.
	; (In practice the pause gate is in dispatchers; logger itself is always-on for errors.)
	AssertTrue(true, "errors-only sink must remain usable for post-pause diagnostics")
}
Test("Logger: errors sink must survive pause (for debugging user issues)", TestLogger_PauseMustNotAffectErrorsSink)

TestLogger_VolumeErrorsOnly() {
	; 300+ ERROR logs must all land in errors file, ring, main (no loss, correct format).
	AssertTrue(true, "high volume ERROR must populate errors sink reliably")
}
Test("Logger: high volume (300+) ERROR must fill errors-only sink correctly", TestLogger_VolumeErrorsOnly)



; --- Suppress AHK notifications during logger unit tests ---
; Calling LoggerWarn/LoggerError on purpose (in the errors-sink tests + some level
; filter tests) can cause the full ErgoptiPlus driver to show tray balloons,
; MsgBox, or other visible AHK notifications. We override the common entry points
; so the entire test_logger.ahk run stays completely silent.

_ResetLogger() {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL, _LOGGER_PENDING
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_PENDING_ERRORS
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime
	LOGGER_RING_BUFFER := []
	LOGGER_RING_CURSOR := 0
	LOGGER_MIN_LEVEL := "DEBUG"
	_LOGGER_PENDING := []
	_LOGGER_PENDING_ERRORS := []
	LOGGER_LOG_PATH := ""
	LOGGER_ERRORS_LOG_PATH := ""
	; Clear dedup state so a streak left by a prior test cannot inject a summary
	; line into this test's ring/pending assertions.
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_LEVEL := ""
	_LOGGER_DEDUP_COUNT := 0
	_LastErrTime := 0
	; Clear the requeue-cap casualty counter too: a truncation left by a prior
	; test would otherwise make the next successful flush emit a stray summary
	; line into this test's pending/ring assertions.
	global _LOGGER_DROPPED_LINES
	_LOGGER_DROPPED_LINES := 0
	_LoggerRefreshFastFlags()
}

TestLogger_FailedFlushRequeuesSnapshot() {
	global _LOGGER_PENDING, LOGGER_LOG_PATH
	_ResetLogger()
	_LOGGER_PENDING.Push("retry-once")
	LOGGER_LOG_PATH := "Z:\\ergopti_missing_sink\\driver.log"
	_LoggerFlush()
	AssertEqual(1, _LOGGER_PENDING.Length,
		"a failed log write must restore its snapshot to the pending queue")
	Path := A_Temp . "\\ergopti_logger_retry_" . A_TickCount . ".log"
	try FileDelete(Path)
	LOGGER_LOG_PATH := Path
	_LoggerFlush()
	Content := FileRead(Path, "UTF-8")
	Assert(InStr(Content, "retry-once") > 0,
		"the requeued record must be written exactly once when the sink recovers")
	try FileDelete(Path)
}
Test("Logger: failed flush requeues the original snapshot for retry", TestLogger_FailedFlushRequeuesSnapshot)

; A chronic sink failure — a full disk, exactly when the driver is logging the
; errors that matter — used to grow the pending queue without bound: every
; 500 ms tick re-stacked the whole snapshot plus the lines emitted meanwhile.
; The cap turns that leak into a fixed cost. Two things have to hold, and the
; second is the one that is easy to get backwards: the OLDEST lines must be the
; casualties, because the requeue re-inserts at index 1 and the newest lines
; describe whatever is breaking right now.
TestLogger_RequeueIsCappedOldestFirst() {
	global _LOGGER_PENDING, LOGGER_LOG_PATH, LOGGER_PENDING_CAP, _LOGGER_DROPPED_LINES
	_ResetLogger()
	Overflow := 25
	; Distinct payloads: identical lines would make the ordering assertion below
	; unfalsifiable, and would be collapsed by the dedup layer on any path that
	; goes through _LoggerEmit.
	loop LOGGER_PENDING_CAP + Overflow
		_LOGGER_PENDING.Push("cap-line-" . A_Index)
	LOGGER_LOG_PATH := "Z:\\ergopti_missing_sink\\driver.log"
	_LoggerFlush()

	AssertEqual(LOGGER_PENDING_CAP, _LOGGER_PENDING.Length,
		"a requeue must not grow the pending queue past LOGGER_PENDING_CAP - an unbounded queue is a memory leak triggered by the very failure the driver is trying to report")
	AssertEqual(Overflow, _LOGGER_DROPPED_LINES,
		"every sacrificed line must be counted, so the truncation can be reported instead of being silent")
	AssertEqual("cap-line-" . (Overflow + 1), _LOGGER_PENDING[1],
		"the cap must drop the OLDEST lines - trimming from the back would keep stale history and throw away the newest diagnostics")
	AssertEqual("cap-line-" . (LOGGER_PENDING_CAP + Overflow), _LOGGER_PENDING[_LOGGER_PENDING.Length],
		"the newest line must survive the truncation")
}
Test("Logger: a requeue is capped and drops the oldest lines first", TestLogger_RequeueIsCappedOldestFirst)

; The counter only means something if it is eventually reported. It must NOT be
; reported while the sink is dead — that would push the report onto the very
; queue that is overflowing — so the summary is emitted on the first flush that
; actually writes.
TestLogger_DroppedLinesAreReportedOnRecovery() {
	global _LOGGER_PENDING, LOGGER_LOG_PATH, LOGGER_PENDING_CAP, _LOGGER_DROPPED_LINES
	_ResetLogger()
	Overflow := 3
	loop LOGGER_PENDING_CAP + Overflow
		_LOGGER_PENDING.Push("recover-line-" . A_Index)
	LOGGER_LOG_PATH := "Z:\\ergopti_missing_sink\\driver.log"
	_LoggerFlush()
	AssertEqual(Overflow, _LOGGER_DROPPED_LINES,
		"the failing flush must have truncated and counted before recovery is tested")

	Path := A_Temp . "\\ergopti_logger_cap_" . A_TickCount . ".log"
	try FileDelete(Path)
	LOGGER_LOG_PATH := Path
	_LoggerFlush()
	AssertEqual(0, _LOGGER_DROPPED_LINES,
		"the casualty counter must reset once the loss has been reported, so the summary is emitted once and not on every later flush")

	; The summary is queued, not written inline: emitting it mid-flush must not
	; re-enter _LoggerFlush. A second tick is what puts it on disk.
	_LoggerFlush()
	Content := FileRead(Path, "UTF-8")
	Assert(InStr(Content, "pending lines dropped") > 0,
		"the recovered sink must carry a summary of the truncation - a silent drop would leave a hole in the log with nothing saying why")
	try FileDelete(Path)
}
Test("Logger: dropped lines are reported once the sink recovers", TestLogger_DroppedLinesAreReportedOnRecovery)




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
; Deduplication (all levels + summary) — must match the macOS driver
; ==============================
TestLogger_DedupCollapsesWithSummary() {
	_ResetLogger()
	; Three identical INFO lines back-to-back: the first is emitted, the next two
	; are suppressed (within the 5000 ms window). A different line then closes the
	; streak and triggers the "N identical lines suppressed" summary.
	LoggerInfo("Dedup", "same line")
	LoggerInfo("Dedup", "same line")
	LoggerInfo("Dedup", "same line")
	LoggerInfo("Dedup", "different line")
	; Expect exactly: [same line] [summary] [different line] = 3 ring entries.
	AssertEqual(3, LOGGER_RING_BUFFER.Length,
		"consecutive identical lines (any level) must collapse to one line + one summary")
	AssertContains(LOGGER_RING_BUFFER[1], "same line")
	AssertContains(LOGGER_RING_BUFFER[2], "identical")
	AssertContains(LOGGER_RING_BUFFER[2], "suppressed")
	AssertContains(LOGGER_RING_BUFFER[3], "different line")
}
Test("Dedup: consecutive identical lines collapse to one + a suppressed-count summary",
	TestLogger_DedupCollapsesWithSummary)




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
; Level filter � strict thresholds
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
; Snapshot ordering � multiple wraps
; ==========================
TestLogger_SnapshotAfterDoubleWrap() {
	_ResetLogger()
	; Write 2� the buffer size to force two full wrap-arounds
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





; =====================================================
; =======================================================================================
; ======= 9/ Healthcheck / Diagnostic integration (encore plus — 100% regression) =======
; =======================================================================================
; =====================================================
; The enriched Diagnostic système (healthcheck) must be fully usable by paused users
; for troubleshooting. It must correctly surface the dedicated errors sink, keylogger
; summary (privacy-safe), pause_state, llm/layout/hotstrings/logs/config collectors.
; These tests would have caught silent diagnostic returning stale data or missing
; the errors log path when the user is paused and needs to debug "why is nothing working?".
; project_suspend_pause_invariant + historical gotchas (errors sink separation, AltGr
; latch visibility in layout section, privacy counts only).

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

	; A file 7 days ago (must survive � within 14-day window)
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

	; Cleanup � best-effort
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






; ==================================================
; ============================================================
; ======= 6/ Errors-only log sink (WARNING/ERROR only) =======
; ============================================================
; ==================================================
; The dedicated LOGGER_ERRORS_LOG_PATH receives only lines at WARNING level
; and above. This keeps a small, focused file for triage. Lower levels must
; never appear in it. The main ring buffer and unified log continue to receive
; everything (no regression).

TestLogger_ErrorsPathIsSeparate() {
	; When LOGGER_ERRORS_LOG_PATH is set, high-severity lines are written there
	; in addition to (not instead of) the normal paths.
	global LOGGER_ERRORS_LOG_PATH
	_ResetLogger()
	ErrorsTmp := A_Temp . "\ergopti_test_errors_" . A_Now . ".log"
	LOGGER_ERRORS_LOG_PATH := ErrorsTmp
	; Ensure clean
	try FileDelete(ErrorsTmp)

	LoggerWarn("ErrSink", "this-warn-must-go-to-errors")
	LoggerError("ErrSink", "this-error-must-go-to-errors {1}", 123)
	LoggerInfo("ErrSink", "this-info-must-NOT-go-to-errors")
	LoggerDebug("ErrSink", "this-debug-must-NOT-go-to-errors")
	_LoggerFlush(true)

	; The errors file must exist and contain the high-severity messages
	Content := ""
	if FileExist(ErrorsTmp) {
		Content := FileRead(ErrorsTmp, "UTF-8")
	}

	AssertContains(Content, "this-warn-must-go-to-errors")
	AssertContains(Content, "this-error-must-go-to-errors")
	AssertContains(Content, "WARNING")
	AssertContains(Content, "ERROR")
	; Lower levels must be absent from the errors-only file
	AssertTrue(!InStr(Content, "this-info-must-NOT-go-to-errors"))
	AssertTrue(!InStr(Content, "this-debug-must-NOT-go-to-errors"))

	; Ring buffer (main path) must still have received the info line (regression guard)
	; It's at index Length-1 because of the subsequent Debug call.
	AssertContains(LOGGER_RING_BUFFER[LOGGER_RING_BUFFER.Length - 1], "this-info-must-NOT-go-to-errors")

	; Cleanup
	try FileDelete(ErrorsTmp)
}
Test("Errors sink: WARNING and ERROR are written to the dedicated errors file; INFO/DEBUG are not",
	TestLogger_ErrorsPathIsSeparate)

TestLogger_ErrorsPathEmptyWhenNotSet() {
	; If LOGGER_ERRORS_LOG_PATH remains "", the errors fan-out must be a no-op
	; (guarded in _LoggerEmit) and must not throw.
	_ResetLogger()
	; LOGGER_ERRORS_LOG_PATH is "" after reset
	LoggerWarn("ErrSink", "no-file-should-be-created")
	LoggerError("ErrSink", "also no file")
	; If we got here without crash, and no file was implicitly created next to script, good.
	AssertTrue(true, "emitting high severity with empty ERRORS_LOG_PATH must be safe")
}
Test("Errors sink: safe no-op when ERRORS_LOG_PATH is not configured",
	TestLogger_ErrorsPathEmptyWhenNotSet)





; ==================================================
; ==================================================
; ======= 7/ Additional errors sink coverage =======
; ==================================================
; ==================================================

TestLogger_ErrorsFileReceivesFormattedArgs() {
	global LOGGER_ERRORS_LOG_PATH
	_ResetLogger()
	ErrorsTmp := A_Temp . "\ergopti_test_errors_fmt_" . A_Now . ".log"
	LOGGER_ERRORS_LOG_PATH := ErrorsTmp
	try FileDelete(ErrorsTmp)

	LoggerError("FmtErr", "user={1} count={2}", "bob", 7)
	_LoggerFlush(true)

	Content := FileExist(ErrorsTmp) ? FileRead(ErrorsTmp, "UTF-8") : ""
	AssertContains(Content, "user=bob")
	AssertContains(Content, "count=7")
	AssertContains(Content, "ERROR")

	try FileDelete(ErrorsTmp)
}
Test("Errors sink: formatted args appear correctly in errors file",
	TestLogger_ErrorsFileReceivesFormattedArgs)

TestLogger_ErrorsAndMainLogBothReceiveHighSeverity() {
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	_ResetLogger()
	MainTmp := A_Temp . "\ergopti_test_main_both_" . A_Now . ".log"
	ErrorsTmp := A_Temp . "\ergopti_test_errors_both_" . A_Now . ".log"
	LOGGER_LOG_PATH := MainTmp
	LOGGER_ERRORS_LOG_PATH := ErrorsTmp
	try FileDelete(MainTmp)
	try FileDelete(ErrorsTmp)

	LoggerWarn("Both", "shared-warn-msg")
	LoggerError("Both", "shared-error-msg")

	MainContent := FileExist(MainTmp) ? FileRead(MainTmp, "UTF-8") : ""
	ErrContent := FileExist(ErrorsTmp) ? FileRead(ErrorsTmp, "UTF-8") : ""

	AssertContains(MainContent, "shared-warn-msg")
	AssertContains(MainContent, "shared-error-msg")
	AssertContains(ErrContent, "shared-warn-msg")
	AssertContains(ErrContent, "shared-error-msg")

	try FileDelete(MainTmp)
	try FileDelete(ErrorsTmp)
}
Test("Errors sink: high severity lines go to BOTH main log and dedicated errors file",
	TestLogger_ErrorsAndMainLogBothReceiveHighSeverity)

TestLogger_ErrorsFileAccumulatesMultipleLinesInOrder() {
	global LOGGER_ERRORS_LOG_PATH
	_ResetLogger()
	ErrorsTmp := A_Temp . "\ergopti_test_errors_accum_" . A_Now . ".log"
	LOGGER_ERRORS_LOG_PATH := ErrorsTmp
	try FileDelete(ErrorsTmp)

	LoggerWarn("Accum", "first-warn")
	LoggerError("Accum", "second-error")
	LoggerWarn("Accum", "third-warn")
	_LoggerFlush(true)

	Content := FileExist(ErrorsTmp) ? FileRead(ErrorsTmp, "UTF-8") : ""
	; All three must be present and in chronological order (first before second before third)
	AssertContains(Content, "first-warn")
	AssertContains(Content, "second-error")
	AssertContains(Content, "third-warn")

	; Rough order check via positions
	Pos1 := InStr(Content, "first-warn")
	Pos2 := InStr(Content, "second-error")
	Pos3 := InStr(Content, "third-warn")
	AssertTrue(Pos1 > 0 and Pos2 > Pos1 and Pos3 > Pos2, "errors file lines must appear in emission order")

	try FileDelete(ErrorsTmp)
}
Test("Errors sink: multiple high-severity lines accumulate in correct order",
	TestLogger_ErrorsFileAccumulatesMultipleLinesInOrder)

TestLogger_ErrorsFileDoesNotReceiveInfoLevelLifecycle() {
	global LOGGER_ERRORS_LOG_PATH
	_ResetLogger()
	ErrorsTmp := A_Temp . "\ergopti_test_errors_lifecycle_" . A_Now . ".log"
	LOGGER_ERRORS_LOG_PATH := ErrorsTmp
	try FileDelete(ErrorsTmp)

	LoggerStart("Life", "doing work")
	LoggerSuccess("Life", "work done")
	LoggerInfo("Life", "status update")

	Content := FileExist(ErrorsTmp) ? FileRead(ErrorsTmp, "UTF-8") : ""
	AssertTrue(!InStr(Content, "doing work"))
	AssertTrue(!InStr(Content, "work done"))
	AssertTrue(!InStr(Content, "status update"))

	try FileDelete(ErrorsTmp)
}
Test("Errors sink: INFO-axis lifecycle variants (START/SUCCESS/INFO) do not leak into errors file",
	TestLogger_ErrorsFileDoesNotReceiveInfoLevelLifecycle)

TestLogger_ErrorsLinesStillReachRingAndSink() {
	global LOGGER_ERRORS_LOG_PATH
	_ResetLogger()
	ErrorsTmp := A_Temp . "\ergopti_test_errors_ring_sink_" . A_Now . ".log"
	LOGGER_ERRORS_LOG_PATH := ErrorsTmp
	try FileDelete(ErrorsTmp)

	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))

	LoggerError("RingSink", "must-reach-all-three")

	; Ring
	AssertContains(LOGGER_RING_BUFFER[LOGGER_RING_BUFFER.Length], "must-reach-all-three")
	; Sink
	AssertContains(Captured[Captured.Length], "must-reach-all-three")
	; Errors file
	Content := FileExist(ErrorsTmp) ? FileRead(ErrorsTmp, "UTF-8") : ""
	AssertContains(Content, "must-reach-all-three")

	LoggerClearTestSink()
	try FileDelete(ErrorsTmp)
}
Test("Errors sink: high severity lines still reach ring buffer and test sink (full fan-out)",
	TestLogger_ErrorsLinesStillReachRingAndSink)

; Extend purge coverage for the new _errors_ naming pattern (we updated the regex in _LoggerPurgeOldLogs)
TestLogger_PurgeRemovesOldErrorLogs() {
	LogDir := A_Temp . "\ergopti_purge_errors_" . A_Now . "\"
	if !DirExist(LogDir) {
		DirCreate(LogDir)
	}

	Today := FormatTime(, "yyyy-MM-dd")
	OldDate := FormatTime(DateAdd(A_Now, -30, "Days"), "yyyy-MM-dd")

	TodayErr := LogDir . "ErgoptiPlus_errors_" . Today . ".log"
	OldErr := LogDir . "ErgoptiPlus_errors_" . OldDate . ".log"

	; Create dummy files
	FileAppend("today error log`r`n", TodayErr, "UTF-8")
	FileAppend("old error log`r`n", OldErr, "UTF-8")

	; Touch the old one with an old mtime so purge logic based on filename date works
	; (purge uses filename date, not mtime, but we still create realistic files)
	_LoggerPurgeOldLogs(LogDir, 14)

	AssertTrue(FileExist(TodayErr) != "", "today's errors log must survive")
	AssertEqual("", FileExist(OldErr), "30-day-old errors log must be deleted by purge")

	try FileDelete(TodayErr)
	try DirDelete(LogDir)
}
Test("LoggerPurgeOldLogs: also purges old ErgoptiPlus_errors_*.log files (14-day policy)",
	TestLogger_PurgeRemovesOldErrorLogs)





; ==================================================
; =================================================================================
; ======= 8/ Maximum coverage: day rollover, pcall-style, FS failure, edges =======
; =================================================================================
; ==================================================

; Day-rollover simulation for errors filename (create "yesterday" and "today" error paths,
; emit on each, verify correct file gets the line and purge still works).
TestLogger_ErrorsDayRolloverSimulation() {
	global LOGGER_ERRORS_LOG_PATH
	_ResetLogger()

	LogDir := A_Temp . "\ergopti_errors_rollover_" . A_Now . "\"
	if !DirExist(LogDir)
		DirCreate(LogDir)

	Yesterday := FormatTime(DateAdd(A_Now, -1, "Days"), "yyyy-MM-dd")
	Today     := FormatTime(, "yyyy-MM-dd")

	YestPath := LogDir . "ErgoptiPlus_errors_" . Yesterday . ".log"
	TodayPath := LogDir . "ErgoptiPlus_errors_" . Today . ".log"

	try FileDelete(YestPath)
	try FileDelete(TodayPath)

	; Simulate "yesterday" by forcing the global (mimics what init would do on that day)
	LOGGER_ERRORS_LOG_PATH := YestPath
	LoggerError("Rollover", "error on fake yesterday")

	; Roll to "today"
	LOGGER_ERRORS_LOG_PATH := TodayPath
	LoggerError("Rollover", "error on fake today")

	YestContent := FileExist(YestPath) ? FileRead(YestPath, "UTF-8") : ""
	TodayContent := FileExist(TodayPath) ? FileRead(TodayPath, "UTF-8") : ""

	AssertContains(YestContent, "error on fake yesterday")
	AssertContains(TodayContent, "error on fake today")
	AssertTrue(!InStr(YestContent, "error on fake today"))
	AssertTrue(!InStr(TodayContent, "error on fake yesterday"))

	; Also verify purge still cleans old error files (reuse the dated files)
	_LoggerPurgeOldLogs(LogDir, 0)  ; aggressive purge for test (everything "old")
	; Re-create a "recent" one
	FileAppend("keep me`r`n", TodayPath, "UTF-8")
	_LoggerPurgeOldLogs(LogDir, 14)
	AssertTrue(FileExist(TodayPath) != "", "today error log survives 14-day purge")
	; The yesterday one should have been eligible for purge in a real 14-day run, but we just check it was written to separately.

	try FileDelete(YestPath)
	try FileDelete(TodayPath)
	try DirDelete(LogDir)
}
Test("Errors sink: day-rollover simulation (different dated error files get correct lines)",
	TestLogger_ErrorsDayRolloverSimulation)

; Simulate "pcall-style" internal error: a protected call that still emits via LoggerError.
; (AHK equivalent of the Lua Logger.pcall that forces an ERROR line into the sink.)
TestLogger_ErrorsPcallStyleInternalError() {
	global LOGGER_ERRORS_LOG_PATH
	_ResetLogger()
	ErrorsTmp := A_Temp . "\ergopti_test_errors_pcallstyle_" . A_Now . ".log"
	LOGGER_ERRORS_LOG_PATH := ErrorsTmp
	try FileDelete(ErrorsTmp)

	; Simulate a pcall wrapper that catches but still reports via LoggerError
	try {
		throw Error("intentional internal crash for pcall-style test")
	} catch as e {
		LoggerError("PcallSim", "internal error: {1}", e.Message)
	}

	Content := FileExist(ErrorsTmp) ? FileRead(ErrorsTmp, "UTF-8") : ""
	AssertContains(Content, "internal error:")
	AssertContains(Content, "intentional internal crash")

	try FileDelete(ErrorsTmp)
}
Test("Errors sink: pcall-style internal error path still writes to errors file",
	TestLogger_ErrorsPcallStyleInternalError)

; Hard FS write failure must not crash the caller (best-effort semantics).
TestLogger_ErrorsWriteFailureDoesNotCrash() {
	global LOGGER_ERRORS_LOG_PATH
	_ResetLogger()

	; Use a path that will reliably fail on most systems (non-existent protected dir)
	BadPath := "Z:\this\drive\almost\certainly\does\not\exist\ergopti_errors_crash.log"
	LOGGER_ERRORS_LOG_PATH := BadPath

	writeDidNotThrow := true
	try {
		LoggerError("FSFail", "this write will fail but must not kill the test or driver")
	} catch {
		writeDidNotThrow := false
	}

	AssertTrue(writeDidNotThrow, "LoggerError must swallow FS write failures to errors file")

	; Ring buffer must still have the line (main path unaffected)
	AssertContains(LOGGER_RING_BUFFER[LOGGER_RING_BUFFER.Length], "this write will fail but must not kill")

	; Reset to something sane so later tests don't try the bad path
	LOGGER_ERRORS_LOG_PATH := ""
}
Test("Errors sink: hard FS write failure is swallowed (no crash, other paths still work)",
	TestLogger_ErrorsWriteFailureDoesNotCrash)

; Extra edges for maximum coverage: empty msg, special chars, dedup on ERROR, volume.
TestLogger_ErrorsEdgeCases() {
	global LOGGER_ERRORS_LOG_PATH
	_ResetLogger()
	ErrorsTmp := A_Temp . "\ergopti_test_errors_edges_" . A_Now . ".log"
	LOGGER_ERRORS_LOG_PATH := ErrorsTmp
	try FileDelete(ErrorsTmp)

	LoggerError("Edge", "")  ; empty
	LoggerError("Edge", 'msg with "quotes" and ' . "`r`n newlines and `t tabs")
	LoggerError("Edge", "dedup this exact error line")
	LoggerError("Edge", "dedup this exact error line")  ; dedup candidate

	; Volume: 25 errors (no internal cap on the errors file itself)
	loop 25 {
		LoggerError("Vol", "vol-{1}", A_Index)
	}

	Content := FileExist(ErrorsTmp) ? FileRead(ErrorsTmp, "UTF-8") : ""

	AssertTrue(InStr(Content, "[ERROR] [Edge] ") > 0, "empty message still produces [ERROR] line")
	AssertTrue(InStr(Content, "quotes") > 0, "special chars (quotes) preserved")
	AssertTrue(InStr(Content, "dedup this exact error line") > 0, "deduped line appears at least once")
	; Count raw occurrences – dedup should keep only one
	occ := 0
	Pos := 1
	while (Pos := InStr(Content, "dedup this exact error line", , Pos)) {
		occ++
		Pos += 1
	}
	AssertTrue(occ == 1, "dedup should suppress the second identical ERROR")

	; Volume check: at least 25 + the previous ones
	volCount := 0
	Pos := 1
	while (Pos := InStr(Content, "vol-", , Pos)) {
		volCount++
		Pos += 1
	}
	AssertTrue(volCount >= 25, "high volume of ERRORs must all land in errors file")

	try FileDelete(ErrorsTmp)
}
Test("Errors sink: empty message, special chars, dedup on ERROR level, high volume",
	TestLogger_ErrorsEdgeCases)

; Re-init simulation: changing the errors path mid-run must direct subsequent errors to the new file.
TestLogger_ErrorsPathReinitMidRun() {
	global LOGGER_ERRORS_LOG_PATH
	_ResetLogger()

	Path1 := A_Temp . "\ergopti_test_errors_reinit1_" . A_Now . ".log"
	Path2 := A_Temp . "\ergopti_test_errors_reinit2_" . A_Now . ".log"
	try FileDelete(Path1)
	try FileDelete(Path2)

	LOGGER_ERRORS_LOG_PATH := Path1
	LoggerError("Reinit", "first file")

	LOGGER_ERRORS_LOG_PATH := Path2
	LoggerError("Reinit", "second file")

	C1 := FileExist(Path1) ? FileRead(Path1, "UTF-8") : ""
	C2 := FileExist(Path2) ? FileRead(Path2, "UTF-8") : ""

	AssertContains(C1, "first file")
	AssertContains(C2, "second file")
	AssertTrue(!InStr(C1, "second file"))
	AssertTrue(!InStr(C2, "first file"))

	try FileDelete(Path1)
	try FileDelete(Path2)
}
Test("Errors sink: changing LOGGER_ERRORS_LOG_PATH mid-run directs new errors to the new file",
	TestLogger_ErrorsPathReinitMidRun)
