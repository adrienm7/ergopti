; tests/unit/infra/logger/test_logger_native64_dedup_owner.ahk

; ==============================================================================
; MODULE: Logger Native64 Deduplication Clock Tests
; DESCRIPTION:
; Real public LoggerInfo drives the actual ring, pending queue and test sink.
; The existing clock port advances logical full64 milliseconds; no physical
; 49-day wait, filesystem append or repeat-collapsing behavior is claimed.
; ==============================================================================

#Requires AutoHotkey v2.0

_LND_With(Scenario) {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, LOGGER_SUB_FILES
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime
	global _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED
	global _LOGGER_MIN_SEVERITY, _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED
	global _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED, _LOGGER_FLUSH_ACTIVE
	global _LOGGER_APPEND_DEBTS, _LOGGER_APPEND_DEBT_REPAIRS, _LOGGER_APPEND_OWNERS
	global LOGGER_RING_BUFFER_SIZE, LOGGER_DEDUP_WINDOW_MS
	PreviousCritical := Critical("On"), Saved := 0, Extra := 0, Primary := 0
	State := {Now: 1000, ClockCalls: 0, Lines: []}
	Clock := () => (State.ClockCalls += 1, State.Now)
	Sink := (Line) => State.Lines.Push(Line)
	try {
		AssertFalse(_LOGGER_FLUSH_ACTIVE, "A running foreign flush cannot be borrowed by the fixture")
		AssertEqual(0, _LOGGER_APPEND_DEBTS.Count, "Foreign rollback debt must not be discarded")
		AssertEqual(0, _LOGGER_APPEND_DEBT_REPAIRS.Count, "Foreign repair custody must not be replaced")
		AssertEqual(0, _LOGGER_APPEND_OWNERS.Count, "Foreign append ownership must not be replaced")
		AssertTrue(LOGGER_RING_BUFFER_SIZE >= 3, "The genuine ring must retain this short scenario")
		AssertEqual(5000, LOGGER_DEDUP_WINDOW_MS, "The actual public suppression contract is five seconds")
		Saved := _TLOG_CaptureLoggerState()
		Extra := {Clock: _LOGGER_CLOCK_FN, Stamp: _LOGGER_STAMP_FN, Sink: _LOGGER_TEST_SINK,
			Repeat: _LOGGER_REPEAT_ENABLED, Severity: _LOGGER_MIN_SEVERITY,
			Debug: _LOGGER_DEBUG_ENABLED, Info: _LOGGER_INFO_ENABLED,
			Warn: _LOGGER_WARN_ENABLED, Error: _LOGGER_ERROR_ENABLED}
		LOGGER_RING_BUFFER := [], LOGGER_RING_CURSOR := 0
		_LOGGER_PENDING := [], _LOGGER_PENDING_ERRORS := []
		_LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map(), LOGGER_SUB_FILES := []
		LOGGER_LOG_PATH := "", LOGGER_ERRORS_LOG_PATH := ""
		_LOGGER_DEDUP_KEY := "", _LOGGER_DEDUP_LEVEL := "", _LOGGER_DEDUP_COUNT := 0, _LastErrTime := 0
		; This independently exercised always-on layer precedes repeat collapsing.
		; Disarm repeat explicitly rather than fabricate its calendar timestamps.
		_LOGGER_REPEAT_ENABLED := false
		LOGGER_MIN_LEVEL := "INFO"
		_LoggerRefreshFastFlags()
		_LOGGER_CLOCK_FN := Clock
		_LOGGER_STAMP_FN := 0
		LoggerSetTestSink(Sink)
		Scenario.Call(State)
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Extra) {
				AssertTrue(_LOGGER_CLOCK_FN == Clock && _LOGGER_TEST_SINK == Sink,
					"The fixture's exact clock and sink references must still be owned before restoration")
			}
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			try {
				if IsObject(Saved)
					_TLOG_RestoreLoggerState(Saved)
				if IsObject(Extra) {
					_LOGGER_CLOCK_FN := Extra.Clock, _LOGGER_STAMP_FN := Extra.Stamp
					_LOGGER_TEST_SINK := Extra.Sink, _LOGGER_REPEAT_ENABLED := Extra.Repeat
					_LOGGER_MIN_SEVERITY := Extra.Severity, _LOGGER_DEBUG_ENABLED := Extra.Debug
					_LOGGER_INFO_ENABLED := Extra.Info, _LOGGER_WARN_ENABLED := Extra.Warn
					_LOGGER_ERROR_ENABLED := Extra.Error
				}
			} catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			} finally Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
}

_LND_Observe(State, Expected, Label) {
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LastErrTime, _LOGGER_DEDUP_COUNT
	Rows := LoggerRingBufferSnapshot()
	_TestPrint("# logger-native64-observe label=" . Label . " now=" . State.Now . " now_type=" . Type(State.Now)
		. " last=" . _LastErrTime . " last_type=" . Type(_LastErrTime) . " clock_calls=" . State.ClockCalls
		. " ring=" . Rows.Length . " pending=" . _LOGGER_PENDING.Length . " sink=" . State.Lines.Length
		. " dedup_count=" . _LOGGER_DEDUP_COUNT)
	AssertEqual(Expected, Rows.Length, Label . ": the actual ring must contain exactly the admitted rows")
	AssertEqual(Expected, State.Lines.Length, Label . ": the genuine sink must observe every admitted row")
	AssertEqual(Expected, _LOGGER_PENDING.Length, Label . ": the real pending queue must retain every row")
	AssertEqual(0, _LOGGER_PENDING_ERRORS.Length, "INFO must not enter the dedicated error queue")
	for Index, Line in Rows {
		AssertEqual(Line, State.Lines[Index], "Sink order and actual ring order must agree")
		AssertEqual(Line, _LOGGER_PENDING[Index], "Pending order and actual ring order must agree")
	}
	return Rows
}

_LND_Boundary(State) {
	global _LOGGER_DEDUP_COUNT, _LastErrTime, LOGGER_DEDUP_WINDOW_MS
	Origin := 0x100000000 + 1000
	State.Now := Origin
	LoggerInfo("Native64Dedup", "boundary-copy")
	Rows := _LND_Observe(State, 1, "first accepted emission")
	AssertContains(Rows[1], "[INFO] [Native64Dedup] boundary-copy")
	AssertEqual(Origin, _LastErrTime, "Accepted origins retain all native64 bits")
	State.Now := Origin + LOGGER_DEDUP_WINDOW_MS - 1
	LoggerInfo("Native64Dedup", "boundary-copy")
	_LND_Observe(State, 1, "inside the actual five-second window")
	AssertEqual(1, _LOGGER_DEDUP_COUNT)
	AssertEqual(Origin, _LastErrTime, "A suppression must not move the accepted origin")
	State.Now := Origin + LOGGER_DEDUP_WINDOW_MS
	LoggerInfo("Native64Dedup", "boundary-copy")
	Rows := _LND_Observe(State, 3, "the exact five-second boundary")
	AssertContains(Rows[2], "[INFO] [logger] " . Chr(0x2191) . " 1 identical line suppressed")
	AssertContains(Rows[3], "[INFO] [Native64Dedup] boundary-copy")
	AssertEqual(0, _LOGGER_DEDUP_COUNT)
	AssertEqual(State.Now, _LastErrTime)
	AssertTrue(State.ClockCalls >= 3, "The genuine clock port must participate in every public emission")
}

_LND_LongGap(State) {
	global _LOGGER_DEDUP_COUNT, _LastErrTime
	Origin := State.Now
	LoggerInfo("Native64Dedup", "quiet-source")
	Rows := _LND_Observe(State, 1, "first quiet-source emission")
	AssertContains(Rows[1], "[INFO] [Native64Dedup] quiet-source")
	AssertEqual(Origin, _LastErrTime)
	State.Now := Origin + 0x100000000 + 1
	AssertTrue(State.Now - Origin > 5000 && State.Now > 0xFFFFFFFF,
		"The logical clock must advance monotonically by more than an entire DWORD era")
	LoggerInfo("Native64Dedup", "quiet-source")
	Rows := _LND_Observe(State, 2, "a genuinely new line after the full64 gap")
	AssertContains(Rows[2], "[INFO] [Native64Dedup] quiet-source")
	AssertEqual(0, _LOGGER_DEDUP_COUNT, "A new era must not become another suppression")
	AssertEqual(State.Now, _LastErrTime)
	AssertTrue(State.ClockCalls >= 2)
}

_LND_PriorSummary(State) {
	global _LOGGER_DEDUP_COUNT, _LastErrTime
	Origin := State.Now
	LoggerInfo("Native64Dedup", "summarized-source")
	_LND_Observe(State, 1, "first summarized-source emission")
	State.Now := Origin + 1
	LoggerInfo("Native64Dedup", "summarized-source")
	_LND_Observe(State, 1, "one actually withheld identical line")
	AssertEqual(1, _LOGGER_DEDUP_COUNT)
	AssertEqual(Origin, _LastErrTime)
	State.Now := Origin + 0x100000000 + 1
	LoggerInfo("Native64Dedup", "summarized-source")
	Rows := _LND_Observe(State, 3, "old summary then the newly admitted line")
	AssertContains(Rows[2], "[INFO] [logger] " . Chr(0x2191) . " 1 identical line suppressed")
	AssertContains(Rows[3], "[INFO] [Native64Dedup] summarized-source")
	AssertEqual(0, _LOGGER_DEDUP_COUNT)
	AssertEqual(State.Now, _LastErrTime)
	AssertTrue(State.ClockCalls >= 3)
}

Test("Logger native64 dedup: the short window includes 4999ms and ends at 5000ms (logger-dedup-native64-owner)",
	_LND_With.Bind(_LND_Boundary))
Test("Logger native64 dedup: an identical line after a DWORD era is admitted (logger-dedup-native64-owner)",
	_LND_With.Bind(_LND_LongGap))
Test("Logger native64 dedup: a prior suppression is summarized before the new era line (logger-dedup-native64-owner)",
	_LND_With.Bind(_LND_PriorSummary))
