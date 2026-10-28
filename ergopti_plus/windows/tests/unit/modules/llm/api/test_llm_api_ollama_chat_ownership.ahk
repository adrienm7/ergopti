; tests/unit/modules/llm/api/test_llm_api_ollama_chat_ownership.ahk

; ==============================================================================
; MODULE: Ollama Chat Completion Ownership Tests
; DESCRIPTION:
; A chat response owns its canonical assistant content, including an empty
; result. Reasoning, metadata and provider errors must never become predictions
; through the Windows-only thinking and legacy-regex fallback paths.
; ==============================================================================

#Requires AutoHotkey v2.0





_OllamaChatOwnership_Rejected(Raw) {
	global _LLM_Ollama_IsReady
	PreviousReady := _LLM_Ollama_IsReady
	_LLM_Ollama_IsReady := true
	State := Map("successes", 0, "failures", 0)
	try {
		Parsed := LLM_ParseOllamaChatResponse(Raw)
		AssertTrue(!(Parsed is String) || Parsed == "",
			"non-completion fields must never be promoted to assistant content")
		_LLM_OllamaParseAsyncBody(Raw,
			(*) => State["successes"] += 1,
			(*) => State["failures"] += 1)
		AssertEqual(0, State["successes"], "a rejected chat response must publish no prediction")
		AssertEqual(1, State["failures"], "a rejected chat response must settle failure exactly once")
	} finally {
		_LLM_Ollama_IsReady := PreviousReady
	}
}

_OllamaChatOwnership_Accepted(Raw, Expected) {
	global _LLM_Ollama_IsReady
	PreviousReady := _LLM_Ollama_IsReady
	_LLM_Ollama_IsReady := true
	State := Map("successes", 0, "failures", 0, "text", "")
	try {
		AssertEqual(Expected, LLM_ParseOllamaChatResponse(Raw),
			"the decoded top-level completion must preserve its own text")
		_LLM_OllamaParseAsyncBody(Raw,
			(Text) => (State["successes"] += 1, State["text"] := Text),
			(*) => State["failures"] += 1)
		AssertEqual(1, State["successes"], "a valid completion must still settle success exactly once")
		AssertEqual(0, State["failures"], "a valid completion must not be refused")
		AssertEqual(Expected, State["text"], "the callback must receive only the owned completion")
	} finally {
		_LLM_Ollama_IsReady := PreviousReady
	}
}

for ChatCase in [
	["reasoning only", '{"message":{"content":"","thinking":"private reasoning"}}'],
	["reasoning after whitespace", '{"message":{"content":"  ","thinking":"private reasoning"}}'],
	["canonical empty before root decoy", '{"message":{"content":""},"response":"legacy decoy"}'],
	["missing content before root decoy", '{"message":{},"response":"legacy decoy"}'],
	["null content before root decoy", '{"message":{"content":null},"response":"legacy decoy"}'],
	["invalid message before root decoy", '{"message":"invalid","response":"legacy decoy"}'],
	["nested legacy response", '{"metadata":{"response":"nested decoy"}}'],
	["provider error before chat decoy", '{"error":"model failed","message":{"content":"chat decoy"}}'],
	["provider error before legacy decoy", '{"error":"model failed","response":"legacy decoy"}'],
	["non-object root", '[{"response":"array decoy"}]'],
	["non-string legacy response", '{"response":42}']
] {
	Test("Ollama chat: reject " . ChatCase[1] . " (ollama-chat-content-ownership)",
		_OllamaChatOwnership_Rejected.Bind(ChatCase[2]))
}

for ChatCase in [
	["canonical content", '{"message":{"content":"  answer  ","thinking":"private reasoning"}}', "answer"],
	["chat before legacy decoy", '{"response":"legacy decoy","message":{"content":"answer"}}', "answer"],
	["legacy root before metadata decoy", '{"metadata":{"response":"nested decoy"},"response":"legacy answer"}', "legacy answer"],
	["escaped legacy content", '{"response":"line one\nline two"}', "line one`nline two"]
] {
	Test("Ollama chat: accept " . ChatCase[1] . " (ollama-chat-content-ownership)",
		_OllamaChatOwnership_Accepted.Bind(ChatCase[2], ChatCase[3]))
}


_ORPR_Success(State, Text) {
	State["successes"] += 1
	State["text"] := Text
}

_ORPR_Failure(State, Failure := 0) {
	State["failures"] += 1
	State["failure"] := Failure
}

_ORPR_Raw(Mode, PrivateText) {
	Value := JsonStringLiteral(PrivateText)
	if Mode == "success"
		return '{"message":{"content":' . Value . '}}'
	if Mode == "thinking"
		return '{"message":{"content":"","thinking":' . Value . '}}'
	if Mode == "malformed"
		return '{"message":{"content":' . Value
	if Mode == "provider-error"
		return '{"error":' . Value . '}'
	if Mode == "non-object"
		return '[' . Value . ']'
	throw ValueError("Unknown private response fixture.")
}

_ORPR_PrivateResponseDiagnostics(Mode) {
	global _LLM_Ollama_IsReady, _LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN, _LOGGER_PATH_DATE
	global _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED, _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	PreviousCritical := Critical("On")
	SavedLogger := _TLOG_CaptureLoggerState(), SavedExtra := Map(), SavedOptional := Map()
	Saved := Map("ready", _LLM_Ollama_IsReady, "bootstrap", _LLM_ManagedBootstrap,
		"origin", LLM_OLLAMA_BASE_URL)
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_REPEAT_ENABLED", "_LOGGER_CLOCK_FN", "_LOGGER_STAMP_FN", "_LOGGER_PATH_DATE",
		"_LOGGER_DEBUG_ENABLED", "_LOGGER_INFO_ENABLED", "_LOGGER_WARN_ENABLED", "_LOGGER_ERROR_ENABLED"]
		SavedExtra[Name] := %Name%
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := {Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0}
	Lines := [], State := Map("successes", 0, "failures", 0, "text", "", "failure", 0)
	PrivateText := "SCREEN_PRIVATE_DIAGNOSTIC_" . Mode
	try {
		AssertFalse(SavedLogger.FlushActive, "a foreign logger flush cannot be detached")
		_ResetLogger()
		LOGGER_SUB_FILES := [], _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0, _LOGGER_PATH_DATE := ""
		_HealthCheckWarnCount := 0, _HealthCheckLastError := "", _HealthCheckErrCount := 0, _ED_Policy := 0
		LoggerSetTestSink((Line) => Lines.Push(Line))
		LoggerInfo("LLM.ollama", "The diagnostic observer is active.")
		AssertEqual(1, Lines.Length, "the real formatted logger must reach its actual sink")
		_LLM_Ollama_IsReady := true
		_LLM_ManagedBootstrap := 0
		LLM_OLLAMA_BASE_URL := "http://127.0.0.1:1"
		Custody := LLM_OllamaCaptureOriginCustody()
		Entry := Map("requester_current", 0, "redact", true, "payload_snip", "",
			"origin_custody", Custody, "base_url", Custody.Call("origin"),
			"presence_generation", LLM_AuxGeneration())
		AssertTrue(_LLM_Ollama_PresenceStillCurrent(Entry), "the real origin owner must admit this response")
		_LLM_OllamaParseAsyncBody(_ORPR_Raw(Mode, PrivateText),
			_ORPR_Success.Bind(State), _ORPR_Failure.Bind(State), Entry)
		Success := Mode == "success"
		AssertEqual(Success ? 1 : 0, State["successes"])
		AssertEqual(Success ? 0 : 1, State["failures"])
		if Success
			AssertEqual(PrivateText, State["text"], "redacted diagnostics cannot erase the actual completion")
		else {
			AssertTrue(State["failure"] is Map, "the failure must keep its typed public result")
			AssertFalse(InStr(_LLM_Vision_FailureReason(State["failure"]), PrivateText, true),
				"a later vision failure logger must not recover the private response from its failure result")
		}
		AssertTrue(Lines.Length > 1, "redaction must preserve the response diagnostic instead of suppressing logs")
		for Line in Lines
			AssertFalse(InStr(Line, PrivateText, true), "the existing redaction owner must cover every diagnostic branch")
	} finally {
		_LLM_Ollama_IsReady := Saved["ready"]
		_LLM_ManagedBootstrap := Saved["bootstrap"]
		LLM_OLLAMA_BASE_URL := Saved["origin"]
		_TLOG_RestoreLoggerState(SavedLogger)
		for Name, Value in SavedExtra
			%Name% := Value
		for Name, Value in SavedOptional
			%Name% := Value.Present ? Value.Value : unset
		Critical(PreviousCritical)
	}
}

for _ORPR_Mode in ["success", "thinking", "malformed", "provider-error", "non-object"]
	Test("Ollama private response: " . _ORPR_Mode . " preserves diagnostic redaction (ollama-private-response-diagnostics)",
		_ORPR_PrivateResponseDiagnostics.Bind(_ORPR_Mode))
