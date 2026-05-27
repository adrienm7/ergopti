; tests/test_logger_contract.ahk

; ==============================================================================
; MODULE: Logger Contract Tests
; DESCRIPTION:
; Validates the AHK Logger against the cross-driver test vectors defined in
; static/ergopti_plus/_shared/logger/test_vectors.json. Every vector describes an
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
	global LOGGER_LOG_PATH, LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL, _LOGGER_PENDING
	LOGGER_LOG_PATH  := ""
	LOGGER_RING_BUFFER  := []
	LOGGER_RING_CURSOR  := 0
	LOGGER_MIN_LEVEL    := "DEBUG"
	_LOGGER_PENDING     := []
	_LoggerRefreshFastFlags()
}
_LoggerContractSetup()

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

	; Resolve path: tests/ is at A_ScriptDir; _shared/ is two dirs up then down.
	VectorsPath := A_ScriptDir . "\..\..\._shared\logger\test_vectors.json"
	VectorsPath := StrReplace(VectorsPath, "\..", "\..")  ; keep as-is (StrReplace is no-op here)
	; Correct path: tests/ → autohotkey/ → drivers/ → _shared/
	VectorsPath := A_ScriptDir . "\..\..\_shared\logger\test_vectors.json"

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
