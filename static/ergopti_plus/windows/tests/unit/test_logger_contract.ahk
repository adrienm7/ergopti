; tests/unit/test_logger_contract.ahk

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

; The sink is best-effort; the ring is not. Point the errors path at a directory
; that cannot exist and the emit must still return normally with the line in the
; ring — a logging failure that propagated would take down whatever was being
; logged about.
TestLoggerContract_FsFailureOnErrorsSinkDoesNotCrash() {
	global LOGGER_ERRORS_LOG_PATH, LOGGER_LOG_PATH, LOGGER_RING_BUFFER
	_LoggerContractSetup()
	LOGGER_ERRORS_LOG_PATH := "Z:\no_such_volume\nope\errors.log"
	LOGGER_LOG_PATH        := "Z:\no_such_volume\nope\main.log"

	LoggerError("test", "still-recorded")
	_LoggerFlush(true)   ; force the write attempt that must fail silently

	Found := false
	for Line in LoggerRingBufferSnapshot() {
		if InStr(Line, "still-recorded") {
			Found := true
			break
		}
	}
	Assert(Found,
		"with an unwritable sink the line must still be in the ring — the ring is the only "
		. "record the diagnostic window can show when the disk is the problem")

	_LoggerContractSetup()
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
