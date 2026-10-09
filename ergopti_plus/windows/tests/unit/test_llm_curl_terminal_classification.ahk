; tests/unit/test_llm_curl_terminal_classification.ahk
#Requires AutoHotkey v2.0

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
