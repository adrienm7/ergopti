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

for Case in [
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
	Test("Ollama chat: reject " . Case[1] . " (ollama-chat-content-ownership)",
		_OllamaChatOwnership_Rejected.Bind(Case[2]))
}

for Case in [
	["canonical content", '{"message":{"content":"  answer  ","thinking":"private reasoning"}}', "answer"],
	["chat before legacy decoy", '{"response":"legacy decoy","message":{"content":"answer"}}', "answer"],
	["legacy root before metadata decoy", '{"metadata":{"response":"nested decoy"},"response":"legacy answer"}', "legacy answer"],
	["escaped legacy content", '{"response":"line one\nline two"}', "line one`nline two"]
] {
	Test("Ollama chat: accept " . Case[1] . " (ollama-chat-content-ownership)",
		_OllamaChatOwnership_Accepted.Bind(Case[2], Case[3]))
}
