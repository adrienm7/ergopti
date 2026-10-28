; tests/unit/modules/llm/api/test_llm_api_ollama_stream_nul.ahk

; ==============================================================================
; MODULE: Ollama Stream NUL Boundary Tests
; DESCRIPTION:
; A raw NUL is valid UTF-8 but invalid JSON. The real final-flush reader must
; not truncate it and report a valid prefix as the entire response. The native
; file contains a complete success record followed by the invalid byte and an
; error record; no curl process or transport acknowledgement is simulated.
; ==============================================================================

#Requires AutoHotkey v2.0





_OllamaStreamNul_Boundary(AfterLine, Newline) {
	global _LLM_Ollama_ActiveStreams, _LLM_Ollama_IsReady, _LLM_ManagedBootstrap
	SavedStreams := _LLM_Ollama_ActiveStreams
	SavedReady := _LLM_Ollama_IsReady
	SavedBootstrap := _LLM_ManagedBootstrap
	_LLM_Ollama_IsReady := true
	_LLM_ManagedBootstrap := 0
	Path := A_Temp . "\ergopti_stream_nul_" . A_TickCount . "_" . Random(1, 1000000)
	Handle := {Pid: 0, ProcessOwner: 0, Cancelled: false,
		TmpPayload: Path . ".json", TmpStdout: Path . ".out"}
	_LLM_Ollama_ActiveStreams := [Handle]
	Events := Map("partials", 0, "successes", 0, "failures", 0, "text", "")
	try {
		Prefix := '{"message":{"content":"visible before NUL"},"done":true}'
			. (AfterLine ? "`n" : "")
		Suffix := '{"error":"must not be hidden"}' . (Newline ? "`n" : "")
		FileAppend(Prefix, Handle.TmpStdout, "UTF-8-RAW")
		_TLAO_AppendRawBytes(Handle.TmpStdout, [0])
		FileAppend(Suffix, Handle.TmpStdout, "UTF-8-RAW")
		; Read back the actual file so a missing NUL cannot qualify a failure.
		Reader := FileOpen(Handle.TmpStdout, "r")
		Assert(IsObject(Reader), "the private native stream file must open")
		try {
			Bytes := Buffer(Reader.Length)
			AssertEqual(Bytes.Size, Reader.RawRead(Bytes), "the complete native byte image must be observed")
		} finally Reader.Close()
		Offset := StrPut(Prefix, "UTF-8") - 1
		AssertEqual(0, NumGet(Bytes, Offset, "UChar"), "the native byte image must contain the actual raw NUL")
		AssertEqual(StrPut(Prefix, "UTF-8") + StrPut(Suffix, "UTF-8") - 1, Bytes.Size,
			"the authenticated native file must retain both complete records around the NUL")
		State := Map("acc", "", "last_pos", 0)
		_LLM_Ollama_StreamFinalFlush(Handle, State,
			(*) => Events["partials"] += 1,
			(Text) => (Events["successes"] += 1, Events["text"] := Text),
			(*) => Events["failures"] += 1)
		FileAppend("RECEIPT ollama-stream-nul-boundary after_line=" . AfterLine . " newline=" . Newline
			. " native_bytes=" . Bytes.Size . " nul_offset=" . Offset . " raw_nul=1"
			. " last_pos=" . State["last_pos"] . " partials=" . Events["partials"]
			. " successes=" . Events["successes"] . " failures=" . Events["failures"] . "`n", "*", "UTF-8-RAW")
		AssertEqual(0, Events["successes"], "raw NUL and its hidden error must never become a successful prefix completion")
		AssertEqual(1, Events["failures"], "the genuine final flush must settle the invalid response exactly once")
		AssertEqual("", Events["text"], "no truncated text may cross the success callback")
		AssertFalse(FileExist(Handle.TmpStdout), "the actual output must retire after invalid-response settlement")
		AssertEqual(0, _LLM_Ollama_ActiveStreams.Length, "the actual stream registry must retire the handle")
	} finally {
		if FileExist(Handle.TmpStdout)
			FileDelete(Handle.TmpStdout)
		_LLM_Ollama_ActiveStreams := SavedStreams
		_LLM_Ollama_IsReady := SavedReady
		_LLM_ManagedBootstrap := SavedBootstrap
	}
}

; Invalid responses emit genuine warnings; park the observer state around them.
_OllamaStreamNul_Case(AfterLine, Newline) {
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	PreviousCritical := Critical("On")
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedOptional := Map()
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
		SavedExtra[Name] := %Name%
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
	try {
		AssertFalse(SavedLogger.FlushActive, "A foreign logger flush cannot be detached by a stream test.")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_TEST_SINK := 0, _LOGGER_REPEAT_ENABLED := false
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		Critical("Off")
		_OllamaStreamNul_Boundary(AfterLine, Newline)
	} finally {
		Critical("On")
		try {
			_TLOG_RestoreLoggerState(SavedLogger)
			for Name, Value in SavedExtra
				%Name% := Value
			for Name, Saved in SavedOptional
				%Name% := Saved.Present ? Saved.Value : unset
		} finally Critical(PreviousCritical)
	}
}

for AfterLine in [false, true] {
	for Newline in [false, true] {
		Test("Ollama stream: raw NUL after_line=" . AfterLine . " newline=" . Newline
			. " refuses a false completion (ollama-stream-nul-boundary)",
			_OllamaStreamNul_Case.Bind(AfterLine, Newline))
	}
}
