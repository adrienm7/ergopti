; tests/unit/test_llm_curl_terminal_classification.ahk
#Requires AutoHotkey v2.0

_LCTC_PingRequiresTransportStatusAndSchema() {
	AssertFalse(_LLM_OllamaPingTerminalOk(7, 0, true, ""), "connection refusal is not readiness")
	AssertFalse(_LLM_OllamaPingTerminalOk(0, 404, true, "<html>no</html>"), "HTTP 404 is not readiness")
	AssertFalse(_LLM_OllamaPingTerminalOk(0, 200, true, "{}"), "an arbitrary JSON service is not Ollama")
	AssertTrue(_LLM_OllamaPingTerminalOk(0, 200, true, '{"version":"0.11.0"}'), "typed Ollama version response is ready")
}
Test("LLM curl terminal: ping requires exit, 2xx and Ollama schema", _LCTC_PingRequiresTransportStatusAndSchema)

_LCTC_DeleteRequiresCompleteTerminalEvidence() {
	AssertFalse(_LLM_OllamaDeleteTerminalOk(7, 0, true, ""), "empty body cannot hide transport refusal")
	AssertFalse(_LLM_OllamaDeleteTerminalOk(0, 500, true, ""), "empty 500 is failure")
	AssertFalse(_LLM_OllamaDeleteTerminalOk(0, 204, false, ""), "missing body artifact is incomplete ownership")
	AssertTrue(_LLM_OllamaDeleteTerminalOk(0, 204, true, ""), "complete empty 204 is success")
}
Test("LLM curl terminal: delete never equates an absent body with success", _LCTC_DeleteRequiresCompleteTerminalEvidence)

_LCTC_UsageNavigatesCanonicalOwner() {
	global LLM_REMOTE_MODEL_PRICES
	LLM_REMOTE_MODEL_PRICES := Map("priced", Map("in", 1.0, "out", 2.0))
	Body := '{"decoy":{"prompt_tokens":900,"completion_tokens":800},"usage":{"prompt_tokens":11,"completion_tokens":22,"total_tokens":33}}'
	Usage := _LLMRemoteExtractUsage("openai", Body, "priced")
	AssertEqual(11, Usage["prompt_tokens"], "nested decoy prompt count must be ignored")
	AssertEqual(22, Usage["completion_tokens"], "nested decoy completion count must be ignored")
	AssertEqual(33, Usage["total_tokens"], "canonical total must be retained")
}
Test("LLM usage: counters come from the provider-owned top-level block", _LCTC_UsageNavigatesCanonicalOwner)
