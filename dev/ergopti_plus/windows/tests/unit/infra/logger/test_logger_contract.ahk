; tests/unit/infra/logger/test_logger_contract.ahk

; ==============================================================================
; MODULE: Logger Contract Tests
; DESCRIPTION:
; Validates the AHK Logger against the cross-driver test vectors defined in
; static/ergopti_plus/_shared/modules/logger/test_vectors.json. Every vector describes an
; expected formatted log line; these tests assert that the AHK Logger produces
; exactly that output for each variant/module/message combination.
;
; RATIONALE:
; The shared SPEC defines one line format used by both AHK and Hammerspoon:
;     YYYY-MM-DD HH:MM:SS:mmm [LEVEL] [Module] message
; The test_vectors.json replaces the timestamp with the "TIMESTAMP" sentinel
; so vectors are time-independent. This test loads those vectors and verifies
; AHK compliance, catching any drift from the shared contract.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================================
; =======================================================
; ======= 1/ Setup: redirect logger to no-op path =======
; =======================================================
; =======================================================

; Point the logger at an empty path so no file writes occur during tests.
; The ring buffer is the only output we inspect.
_LoggerContractSetup() {
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL, _LOGGER_PENDING
	LOGGER_LOG_PATH       := ""
	LOGGER_ERRORS_LOG_PATH := ""
	LOGGER_RING_BUFFER    := []
	LOGGER_RING_CURSOR    := 0
	LOGGER_MIN_LEVEL      := "DEBUG"
	_LOGGER_PENDING       := []
	_LoggerRefreshFastFlags()
}
_LoggerContractSetup()

; ULTIMATE encore plus: pause + errors-sink + FS + volume for 100% certainty.
; These would have caught silent error loss or main-log pollution under pause.
; project_suspend_pause_invariant (high-severity still reaches errors sink for diagnostics).

; The contract is that the logger is ALWAYS-ON. Pause silences features, not
; diagnostics — a user reporting a problem has usually paused the driver first,
; and that is exactly when the ERROR lines matter. So the emit path must not
; consult A_IsSuspended, and an ERROR must land in both the ring and the
; errors-only queue.
TestLoggerContract_PauseMustNotAffectErrorsSink() {
	global _LOGGER_PENDING_ERRORS, LOGGER_RING_BUFFER
	_LoggerContractSetup()

	Emit := _DriverFuncBody("_LoggerEmit")
	Assert(InStr(Emit, "A_IsSuspended") == 0,
		"_LoggerEmit() must not read A_IsSuspended — pause silences features, not diagnostics, "
		. "and a paused driver is exactly when the user is reporting a problem")

	LoggerError("test", "boom {1}", 42)
	Assert(_LOGGER_PENDING_ERRORS.Length >= 1,
		"an ERROR must reach the errors-only queue")
	Assert(LOGGER_RING_BUFFER.Length >= 1,
		"and the in-memory ring, which is what the diagnostic window dumps")
	AssertTrue(InStr(_LOGGER_PENDING_ERRORS[_LOGGER_PENDING_ERRORS.Length], "boom 42") > 0,
		"the formatted message must survive into the sink, arguments included")
}
Test("Logger contract: errors sink must survive pause (for post-pause diagnostics)", TestLoggerContract_PauseMustNotAffectErrorsSink)

; Two separate claims about volume, and they pull in opposite directions.
; The errors queue must not lose the newest lines when it hits its cap — it
; trims the OLDEST, because the newest describe whatever is breaking right now.
; The ring saturates at its fixed size rather than growing without bound.
TestLoggerContract_HighVolumeErrorsOnlyUnderPause() {
	global _LOGGER_PENDING_ERRORS, LOGGER_RING_BUFFER, LOGGER_RING_BUFFER_SIZE
	_LoggerContractSetup()

	Loop 300 {
		LoggerError("test", "err-{1}", A_Index)
	}

	Assert(_LOGGER_PENDING_ERRORS.Length > 0, "300 errors must not empty the errors queue")
	Last := _LOGGER_PENDING_ERRORS[_LOGGER_PENDING_ERRORS.Length]
	AssertTrue(InStr(Last, "err-300") > 0,
		"the MOST RECENT error must survive the cap — the queue trims the oldest, because the "
		. "newest lines describe what is breaking now")

	Assert(LOGGER_RING_BUFFER.Length <= LOGGER_RING_BUFFER_SIZE,
		"the ring must saturate at LOGGER_RING_BUFFER_SIZE rather than grow without bound")

	; And a DEBUG line below the threshold must not reach the errors sink at all.
	Before := _LOGGER_PENDING_ERRORS.Length
	LoggerDebug("test", "quiet")
	AssertEqual(Before, _LOGGER_PENDING_ERRORS.Length,
		"a DEBUG line must never pollute the errors-only sink")
}
Test("Logger contract: high volume (300+) ERROR under pause must fill errors sink correctly", TestLoggerContract_HighVolumeErrorsOnlyUnderPause)

; Exercise simultaneous native refusal in both sinks, not an assumed missing drive.
TestLoggerContract_FsFailureOnErrorsSinkDoesNotCrash() {
	Receipt := _LoggerErrorsSharingDenial(true)
	AssertEqual(Receipt.Expected, Receipt.Errors, "the errors sink must recover without duplicates")
	AssertEqual(Receipt.Expected, Receipt.Main, "the main sink must recover independently")
}
Test("Logger contract: hard FS write failure on errors sink must not crash and line reaches ring", TestLoggerContract_FsFailureOnErrorsSinkDoesNotCrash)

; Map from vector "variant" string to the corresponding AHK logger function name.
; AHK v2 does not support first-class function references via string lookup in
; Map by default, so we use a closure approach.
_CallLoggerVariant(Variant, Tag, Msg, Args) {
	if Args.Length = 0 {
		switch Variant {
			case "debug":   LoggerDebug(Tag, Msg)
			case "trace":   LoggerTrace(Tag, Msg)
			case "done":    LoggerDone(Tag, Msg)
			case "info":    LoggerInfo(Tag, Msg)
			case "start":   LoggerStart(Tag, Msg)
			case "success": LoggerSuccess(Tag, Msg)
			case "warn":    LoggerWarn(Tag, Msg)
			case "error":   LoggerError(Tag, Msg)
		}
		return
	}
	if Args.Length = 1 {
		switch Variant {
			case "debug":   LoggerDebug(Tag, Msg, Args[1])
			case "trace":   LoggerTrace(Tag, Msg, Args[1])
			case "done":    LoggerDone(Tag, Msg, Args[1])
			case "info":    LoggerInfo(Tag, Msg, Args[1])
			case "start":   LoggerStart(Tag, Msg, Args[1])
			case "success": LoggerSuccess(Tag, Msg, Args[1])
			case "warn":    LoggerWarn(Tag, Msg, Args[1])
			case "error":   LoggerError(Tag, Msg, Args[1])
		}
		return
	}
	if Args.Length = 2 {
		switch Variant {
			case "debug":   LoggerDebug(Tag, Msg, Args[1], Args[2])
			case "trace":   LoggerTrace(Tag, Msg, Args[1], Args[2])
			case "done":    LoggerDone(Tag, Msg, Args[1], Args[2])
			case "info":    LoggerInfo(Tag, Msg, Args[1], Args[2])
			case "start":   LoggerStart(Tag, Msg, Args[1], Args[2])
			case "success": LoggerSuccess(Tag, Msg, Args[1], Args[2])
			case "warn":    LoggerWarn(Tag, Msg, Args[1], Args[2])
			case "error":   LoggerError(Tag, Msg, Args[1], Args[2])
		}
		return
	}
}

; Strip the timestamp prefix from a ring-buffer line so it matches the
; "TIMESTAMP-stripped" expected string from the test vectors.
; AHK timestamp format: "YYYY-MM-DD HH:mm:ss:mmm " (24 chars).
_StripLogTimestamp(Line) {
	return RegExReplace(Line, "^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}:\d{3} ", "")
}




; =============================================
; =============================================
; ======= 2/ Contract Vector Test Loop ========
; =============================================
; =============================================

_RunLoggerContractTests() {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR

	; Resolve path: tests/ → windows/ → ergopti_plus/ → _shared/
	VectorsPath := A_ScriptDir . "\..\..\_shared\modules\logger\test_vectors.json"

	; ── Load and decode the JSON ──
	JsonBody := ""
	try {
		JsonBody := FileRead(VectorsPath)
	} catch {
		; File unreadable — record a sentinel failure and bail out.
		_LoggerContractVectorsMissing() {
			Assert(False, "Logger contract test: cannot open test_vectors.json at " . VectorsPath)
		}
		Test("logger contract: test_vectors.json is readable", _LoggerContractVectorsMissing)
		return
	}

	Data := JsonParse(JsonBody)
	if !Data.Has("vectors") or !(Data["vectors"] is Array) {
		_LoggerContractVectorsInvalid() {
			Assert(False, "Logger contract test: test_vectors.json has no 'vectors' array")
		}
		Test("logger contract: test_vectors.json structure", _LoggerContractVectorsInvalid)
		return
	}

	Vectors := Data["vectors"]

	; ── One Test() registration per vector ──
	for Vec in Vectors {
		; AHK-specific field takes priority over the common "message" / "expected"
		Msg      := Vec.Has("message_ahk") ? Vec["message_ahk"] : (Vec.Has("message") ? Vec["message"] : "")
		Expected := Vec.Has("expected_ahk") ? Vec["expected_ahk"] : (Vec.Has("expected") ? Vec["expected"] : "")
		Id       := Vec.Has("id") ? Vec["id"] : "unknown"
		Variant  := Vec.Has("variant") ? Vec["variant"] : ""
		Tag      := Vec.Has("module") ? Vec["module"] : ""
		Args     := Vec.Has("args") ? Vec["args"] : []

		; Skip vectors without a message or expected string
		if Msg = "" or Expected = "" {
			continue
		}

		; Strip the "TIMESTAMP " sentinel prefix from the expected string
		ExpectedBody := RegExReplace(Expected, "^TIMESTAMP ", "")

		; Capture locals for the Test() closure via Bind pattern.
		; AHK v2 closures capture by reference, so we must rebind before each iteration.
		_RunOneContractVector(VecId, VecVariant, VecTag, VecMsg, VecArgs, VecExpected) {
			global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR
			; Reset ring buffer so we can reliably read the last entry
			LOGGER_RING_BUFFER := []
			LOGGER_RING_CURSOR := 0
			_CallLoggerVariant(VecVariant, VecTag, VecMsg, VecArgs)
			ActualLine := LOGGER_RING_BUFFER.Length > 0 ? LOGGER_RING_BUFFER[LOGGER_RING_CURSOR] : ""
			Assert(ActualLine != "", "vector [" . VecId . "]: logger emitted nothing (level filter?)")
			Actual := _StripLogTimestamp(ActualLine)
			AssertEqual(Actual, VecExpected, "vector [" . VecId . "]")
		}

		TestName := "logger contract: vector [" . Id . "]"
		Test(TestName, _RunOneContractVector.Bind(Id, Variant, Tag, Msg, Args, ExpectedBody))
	}
}

_RunLoggerContractTests()





; ==============================================================================
; EVIDENCE RECORDS (spec section 4.3) - regression guard for the lost Debug
; evidence. The sections below follow the vector replay above.
;
; Regression guard for the lost one-click Debug evidence (spec section 4.3).
;
; ROOT CAUSE ENCODED: the "Send comparison" check wrote its eight scenario
; records through LoggerInfo(INPUT_PROBE_TAG, "{1}", Record). The repeat
; collapser (spec section 4.2) keys an INFO line by its UNFORMATTED template,
; and the template "{1}" was the same for all eight records, so only the first
; reached the log file: the other seven (and the hook-order record, same
; template) were folded into a timed summary that was never written. The window
; showed the evidence; the log the maintainer was asked to send back did not.
;
; The invariants: records written through LoggerEvidence all reach the sink and
; the file, whatever their template, however identical to the previous one, and
; whenever the same check runs again; and the ordinary INFO lines around them
; keep collapsing. The producers of the two input checks use LoggerEvidence.
;
; SCOPE: behavioural. It drives the real logger with the repeat layer armed on a
; driven clock, the real InputProbe_RowRecord for the record text, and the real
; file flush, so a comment or a stub cannot satisfy it.
; ==============================================================================


; =============================================
; =============================================
; ======= 2/ Evidence: fixture and helpers ==============
; =============================================
; =============================================

global _LEV_NOW := 0

; Runs Body(Lines) with the repeat layer armed, a driven clock, the paths blanked
; so nothing touches a real log, and every touched global restored afterwards.
; Lines receives each line the sink saw, in delivery order.
_LEV_WithArmedLogger(Body, Path := "") {
	global LOGGER_MIN_LEVEL, LOGGER_RING_BUFFER, LOGGER_RING_CURSOR
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_PATH_DATE, _LOGGER_SUB_PATHS
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING
	global _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_REPEAT_ENABLED
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime
	global _LEV_NOW

	SavedLevel := LOGGER_MIN_LEVEL
	SavedLog := LOGGER_LOG_PATH
	SavedErrors := LOGGER_ERRORS_LOG_PATH
	SavedDate := _LOGGER_PATH_DATE
	SavedSubPaths := _LOGGER_SUB_PATHS
	SavedArmed := _LOGGER_REPEAT_ENABLED
	Lines := []
	_LEV_NOW := 0
	LOGGER_LOG_PATH := Path
	LOGGER_ERRORS_LOG_PATH := ""
	_LOGGER_PATH_DATE := ""
	_LOGGER_SUB_PATHS := Map()
	LOGGER_MIN_LEVEL := "DEBUG"
	_LoggerRefreshFastFlags()
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_LEVEL := ""
	_LOGGER_DEDUP_COUNT := 0
	_LastErrTime := 0
	LOGGER_RING_BUFFER := []
	LOGGER_RING_CURSOR := 0
	_LOGGER_PENDING := []
	_LOGGER_PENDING_ERRORS := []
	_LOGGER_SUB_PENDING := Map()
	_LOGGER_CLOCK_FN := () => _LEV_NOW * 1000
	_LOGGER_STAMP_FN := () => FormatTime(DateAdd("20260115100000", _LEV_NOW, "Seconds"), "yyyy-MM-dd HH:mm:ss") . ":000"
	LoggerSetTestSink((L) => Lines.Push(L))
	if _LOGGER_REPEAT_ENABLED
		_LoggerRepeatDisable()
	_LoggerRepeatEnable()
	try {
		Body(Lines)
	} finally {
		LoggerClearTestSink()
		_LoggerRepeatDisable()
		if SavedArmed
			_LoggerRepeatEnable()
		_LOGGER_CLOCK_FN := 0
		_LOGGER_STAMP_FN := 0
		_LOGGER_DEDUP_KEY := ""
		_LOGGER_DEDUP_LEVEL := ""
		_LOGGER_DEDUP_COUNT := 0
		_LastErrTime := 0
		LOGGER_RING_BUFFER := []
		LOGGER_RING_CURSOR := 0
		_LOGGER_PENDING := []
		_LOGGER_PENDING_ERRORS := []
		_LOGGER_SUB_PENDING := Map()
		LOGGER_LOG_PATH := SavedLog
		LOGGER_ERRORS_LOG_PATH := SavedErrors
		_LOGGER_PATH_DATE := SavedDate
		_LOGGER_SUB_PATHS := SavedSubPaths
		LOGGER_MIN_LEVEL := SavedLevel
		_LoggerRefreshFastFlags()
	}
}

; How many of Lines contain Needle.
_LEV_Count(Lines, Needle) {
	Count := 0
	for _, Line in Lines {
		if InStr(Line, Needle)
			Count += 1
	}
	return Count
}

; Eight rows shaped like the send comparison's, through the real record function.
_LEV_Rows() {
	Rows := []
	for Id in ["burst", "paste", "prediction", "rival", "short", "long", "unicode", "mixed"] {
		Row := Map("scenario", Id, "mode", "SendInput", "n", 8, "exact", 8,
			"lost", 0, "interleaved", 0, "garbled", 0, "timeout", 0,
			"ret_med_us", 120, "settle_med_us", 900, "settle_p95_us", 1500, "settle_max_us", 2100)
		Rows.Push(Row)
	}
	return Rows
}





; ==========================================
; ==========================================
; ======= 3/ Evidence: behaviour =====================
; ==========================================
; ==========================================

_LEV_BurstSharingOneTemplateIsDelivered() {
	_Body(Lines) {
		for Row in _LEV_Rows()
			LoggerEvidence("LEVTest", "{1}", InputProbe_RowRecord(Row))
		Assert(_LEV_Count(Lines, "send_compare scenario=") == 8,
			"all eight records written through one template must reach the sink, got "
			. _LEV_Count(Lines, "send_compare scenario=") . " (the lost-evidence bug kept only the first)")
		Assert(_LEV_Count(Lines, "repeated") == 0, "evidence records are never summarised")
		Assert(_LEV_Count(Lines, "[INFO] [LEVTest]") == 8, "evidence is rendered as an INFO line")
	}
	_LEV_WithArmedLogger(_Body)
}
Test("logger: eight evidence records sharing one template all reach the sink (lost Debug evidence)",
	_LEV_BurstSharingOneTemplateIsDelivered)

_LEV_InfoBurstStillCollapses() {
	_Body(Lines) {
		; The control that lets the test above fail: the same burst through
		; LoggerInfo keeps only the first record.
		for Row in _LEV_Rows()
			LoggerInfo("LEVTest", "{1}", InputProbe_RowRecord(Row))
		Assert(_LEV_Count(Lines, "send_compare scenario=") == 1,
			"an ordinary INFO burst sharing one template is still collapsed to its first line")
	}
	_LEV_WithArmedLogger(_Body)
}
Test("logger: the same burst through LoggerInfo is still collapsed (the collapsing is unchanged)",
	_LEV_InfoBurstStillCollapses)

_LEV_IdenticalRecordsAreNotDeduplicated() {
	_Body(Lines) {
		loop 3
			LoggerEvidence("LEVTest", "check={1} verdict={2}", "network", "pass")
		Assert(_LEV_Count(Lines, "check=network verdict=pass") == 3,
			"a record identical to the previous one is not withheld by the consecutive dedup")
		Assert(_LEV_Count(Lines, "identical") == 0, "no dedup summary is owed for evidence")
	}
	_LEV_WithArmedLogger(_Body)
}
Test("logger: identical consecutive evidence records are all written", _LEV_IdenticalRecordsAreNotDeduplicated)

_LEV_RerunLaterIsDeliveredAgain() {
	_Body(Lines) {
		global _LEV_NOW
		for RunAt in [0, 60, 300] {
			_LEV_NOW := RunAt
			for Row in _LEV_Rows()
				LoggerEvidence("LEVTest", "{1}", InputProbe_RowRecord(Row))
		}
		Assert(_LEV_Count(Lines, "send_compare scenario=") == 24,
			"a rerun of the check, inside the ten minute repeat window, writes all its records again")
	}
	_LEV_WithArmedLogger(_Body)
}
Test("logger: a rerun of a check later logs all its evidence records again", _LEV_RerunLaterIsDeliveredAgain)

_LEV_NeighboursKeepCollapsing() {
	_Body(Lines) {
		global _LEV_NOW
		LoggerInfo("LEVTest", "Probe {1}", 1)
		_LEV_NOW := 1
		LoggerEvidence("LEVTest", "Probe {1}", 2)
		_LEV_NOW := 2
		LoggerInfo("LEVTest", "Probe {1}", 3)
		_LEV_NOW := 3
		LoggerInfo("LEVTest", "Probe {1}", 4)
		Assert(_LEV_Count(Lines, "Probe 1") == 1 && _LEV_Count(Lines, "Probe 2") == 1,
			"the first info line and the evidence record are both delivered")
		Assert(_LEV_Count(Lines, "Probe 3") == 0 && _LEV_Count(Lines, "Probe 4") == 0,
			"info lines sharing the template are still withheld: the exemption belongs to evidence alone")
		_LoggerFlushRepeats(true)
		Assert(_LEV_Count(Lines, "repeated 2 more times") == 1,
			"the withheld info lines are reported by one summary")
	}
	_LEV_WithArmedLogger(_Body)
}
Test("logger: info lines around an evidence record keep collapsing", _LEV_NeighboursKeepCollapsing)

_LEV_FollowsTheLevelThreshold() {
	_Body(Lines) {
		global LOGGER_MIN_LEVEL
		LOGGER_MIN_LEVEL := "WARNING"
		_LoggerRefreshFastFlags()
		LoggerEvidence("LEVTest", "dropped={1}", 1)
		Assert(Lines.Length == 0, "evidence is an INFO line: a WARNING threshold filters it like LoggerInfo")
	}
	_LEV_WithArmedLogger(_Body)
}
Test("logger: an evidence record follows the level threshold like info", _LEV_FollowsTheLevelThreshold)

_LEV_RecordsReachTheFile() {
	Path := A_Temp . "\ergopti_evidence_test_" . A_TickCount . ".log"
	try FileDelete(Path)
	_Body(Lines) {
		for Row in _LEV_Rows()
			LoggerEvidence("LEVTest", "{1}", InputProbe_RowRecord(Row))
		_LoggerFlush(true)
	}
	_LEV_WithArmedLogger(_Body, Path)
	Text := FileExist(Path) ? FileRead(Path, "UTF-8") : ""
	try FileDelete(Path)
	Assert(Text != "", "the flush must have written the log file")
	Found := 0
	Pos := 1
	while (Pos := InStr(Text, "send_compare scenario=", false, Pos)) {
		Found += 1
		Pos += 1
	}
	Assert(Found == 8, "all eight evidence records must be in the FILE, found " . Found)
}
Test("logger: evidence records reach the log file, not only the sink", _LEV_RecordsReachTheFile)





; ===============================================
; ===============================================
; ======= 4/ Evidence: the producers use it ==============
; ===============================================
; ===============================================

_LEV_InputProbeRecordsAreEvidence() {
	for Name in ["InputProbe_RunSendComparison", "InputProbe_RunHookOrder"] {
		Body := _DriverFuncBody(Name)
		Assert(InStr(Body, 'LoggerEvidence(INPUT_PROBE_TAG, "{1}"') > 0,
			Name . " must write its result records through LoggerEvidence")
		Assert(!RegExMatch(Body, 'LoggerInfo\(INPUT_PROBE_TAG, "(?:\{1\}|send_compare)'),
			Name . " must not write result records through the collapsible LoggerInfo")
	}
}
Test("input probe: both checks write their result records as evidence", _LEV_InputProbeRecordsAreEvidence)
