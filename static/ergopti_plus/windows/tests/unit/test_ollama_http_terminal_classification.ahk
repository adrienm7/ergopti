; tests/unit/test_ollama_http_terminal_classification.ahk

; ==============================================================================
; MODULE: Ollama HTTP Terminal Classification Regression Tests
; DESCRIPTION:
; Proves that transport exit, HTTP status, readable body ownership, and the
; endpoint's canonical JSON schema all agree before readiness, tag publication,
; deletion logging, or a true callback can be emitted.
; ==============================================================================

_OHTC_PingRequiresTransportStatusAndSchema() {
	AssertFalse(_LLM_OllamaPingTerminalOk(7, 0, true, ""), "connection refusal is not readiness")
	AssertFalse(_LLM_OllamaPingTerminalOk(0, 404, true, "<html>no</html>"), "HTTP 404 is not readiness")
	AssertFalse(_LLM_OllamaPingTerminalOk(0, 200, true, "{}"), "an arbitrary JSON service is not Ollama")
	AssertTrue(_LLM_OllamaPingTerminalOk(0, 200, true, '{"version":"0.11.0"}'), "typed Ollama version response is ready")
}
Test("AHK-007 Ollama terminal: ping requires exit, 2xx and version schema (ahk-007-ollama-terminal-classification)",
	_OHTC_PingRequiresTransportStatusAndSchema)

_OHTC_TagsRequireCanonicalModelsArray() {
	AssertEqual(0, _LLM_Ollama_ParseTagNames("<html>not Ollama</html>").Length,
		"non-JSON bytes must not become an installed-model list")
	AssertEqual(0, _LLM_Ollama_ParseTagNames('{"decoy":{"name":"not-a-model"}}').Length,
		"a same-named field outside the canonical models array must be ignored")
	Tags := _LLM_Ollama_ParseTagNames('{"models":[{"name":"qwen:latest"},{"name":""},{"other":"skip"}]}')
	AssertEqual(1, Tags.Length, "only valid canonical model rows may publish")
	AssertEqual("qwen:latest", Tags[1], "the exact canonical model name must survive")
}
Test("AHK-007 Ollama terminal: tags navigate the canonical models array (ahk-007-ollama-terminal-classification)",
	_OHTC_TagsRequireCanonicalModelsArray)

_OHTC_RecordDeleteResult(State, Result) {
	State["callback_calls"] += 1
	State["callback_value"] := Result
}

_OHTC_RecordSuccess(State, *) {
	State["success_calls"] += 1
}

_OHTC_RecordWarning(State, *) {
	State["warning_calls"] += 1
}

_OHTC_DeleteRequiresCompleteTerminalEvidence() {
	AssertFalse(_LLM_OllamaDeleteTerminalOk(7, 0, true, ""), "empty body cannot hide transport refusal")
	AssertFalse(_LLM_OllamaDeleteTerminalOk(0, 500, true, ""), "empty 500 is failure")
	AssertFalse(_LLM_OllamaDeleteTerminalOk(0, 204, false, ""), "missing body artifact is incomplete ownership")
	AssertTrue(_LLM_OllamaDeleteTerminalOk(0, 204, true, ""), "complete empty 204 is success")

	State := Map("callback_calls", 0, "callback_value", true, "success_calls", 0, "warning_calls", 0)
	Terminal := Map("exit", 7, "status", 0, "body_read", true, "body", "")
	Result := _LLM_OllamaFinishDelete(Terminal, "private-model",
		_OHTC_RecordDeleteResult.Bind(State), _OHTC_RecordSuccess.Bind(State), _OHTC_RecordWarning.Bind(State))
	AssertFalse(Result, "the terminal finisher must reject nonzero curl exit")
	AssertEqual(1, State["callback_calls"], "terminal failure must deliver one callback")
	AssertFalse(State["callback_value"], "terminal failure callback must be false")
	AssertEqual(0, State["success_calls"], "terminal failure must never emit LoggerSuccess")
	AssertEqual(1, State["warning_calls"], "terminal failure must emit one warning")
}
Test("AHK-007 Ollama terminal: delete failure never logs or calls success (ahk-007-ollama-terminal-classification)",
	_OHTC_DeleteRequiresCompleteTerminalEvidence)
