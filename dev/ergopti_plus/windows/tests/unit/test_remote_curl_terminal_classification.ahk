; tests/unit/test_remote_curl_terminal_classification.ahk

; ==============================================================================
; MODULE: Remote Provider Terminal Classification Regression Tests
; DESCRIPTION:
; Exercises the production classifier shared by curl and WinHTTP. One parsed
; provider root must own completion text and usage; transport/HTTP failures,
; provider errors, malformed JSON, canonical empties, and nested metric decoys
; cannot be promoted to successful output.
; ==============================================================================

_RCTC_Terminal(ExitCode, Status, BodyRead, Body) {
	return Map("exit", ExitCode, "status", Status, "body_read", BodyRead, "body", Body)
}

_RCTC_TransportAndHttpFailuresPrecedeBodyParsing() {
	ErrorBody := '{"error":{"content":"world"}}'
	for Terminal in [
		_RCTC_Terminal(7, 0, true, ErrorBody),
		_RCTC_Terminal(0, 401, true, ErrorBody),
		_RCTC_Terminal(0, 200, false, ErrorBody)
	] {
		Result := _LLMRemoteClassifyTerminal("openai", Terminal, "")
		AssertFalse(Result["terminal_ok"], "incomplete terminal evidence must fail before provider parsing")
		AssertFalse(Result["ok"], "transport failure must never promote an error content field")
		AssertEqual("", Result["text"], "transport failure must carry no completion")
	}
}
Test("AHK-007 remote terminal: exit status and readable body precede parsing (ahk-007-remote-terminal-classification)",
	_RCTC_TransportAndHttpFailuresPrecedeBodyParsing)

_RCTC_OneRootOwnsCompletionAndCanonicalUsage() {
	global LLM_REMOTE_MODEL_PRICES
	LLM_REMOTE_MODEL_PRICES := Map("priced", Map("in", 1.0, "out", 2.0))
	Vectors := [
		["openai", '{"reasoning":{"content":"decoy"},"decoy":{"prompt_tokens":900,"completion_tokens":800},'
			. '"choices":[{"message":{"content":"final answer"}}],'
			. '"usage":{"prompt_tokens":11,"completion_tokens":22,"total_tokens":33}}'],
		["anthropic", '{"decoy":{"input_tokens":900,"output_tokens":800},'
			. '"content":[{"type":"text","text":"final answer"}],'
			. '"usage":{"input_tokens":11,"output_tokens":22}}'],
		["gemini", '{"decoy":{"promptTokenCount":900,"candidatesTokenCount":800},'
			. '"candidates":[{"content":{"parts":[{"text":"final answer"}]}}],'
			. '"usageMetadata":{"promptTokenCount":11,"candidatesTokenCount":22,"totalTokenCount":33}}']
	]
	for Vector in Vectors {
		Result := _LLMRemoteClassifyTerminal(Vector[1], _RCTC_Terminal(0, 200, true, Vector[2]), "priced")
		AssertTrue(Result["terminal_ok"], Vector[1] . " complete 2xx terminal evidence must reach provider classification")
		AssertTrue(Result["ok"], Vector[1] . " canonical completion must succeed")
		AssertEqual("final answer", Result["text"], Vector[1] . " canonical completion must beat a decoy")
		AssertEqual(11, Result["usage"]["prompt_tokens"], Vector[1] . " nested usage decoy must be ignored")
		AssertEqual(22, Result["usage"]["completion_tokens"], Vector[1] . " canonical completion count must survive")
		AssertEqual(33, Result["usage"]["total_tokens"], Vector[1] . " canonical total count must survive")
	}
}
Test("AHK-007 remote terminal: one parsed root owns completion and usage (ahk-007-remote-terminal-classification)",
	_RCTC_OneRootOwnsCompletionAndCanonicalUsage)

_RCTC_ValidProviderErrorAndMalformedJsonAreTerminal() {
	Cases := [
		['{"error":{"content":"world"}}', "provider_error"],
		['{"choices":[{"message":{"content":"wrong partial output"}}]', "malformed_json"]
	]
	for Vector in Cases {
		Result := _LLMRemoteClassifyTerminal("openai", _RCTC_Terminal(0, 200, true, Vector[1]), "")
		AssertTrue(Result["terminal_ok"], "HTTP success alone must not decide provider success")
		AssertFalse(Result["ok"], Vector[2] . " must fail provider classification")
		AssertEqual(Vector[2], Result["reason"], "classification reason must remain explicit")
		AssertEqual("", Result["text"], "failed classification must carry no completion")
	}
}
Test("AHK-007 remote terminal: provider errors and malformed envelopes stay failures (ahk-007-remote-terminal-classification)",
	_RCTC_ValidProviderErrorAndMalformedJsonAreTerminal)

_RCTC_RecordSuccess(State, Text, Usage) {
	State["success_calls"] += 1
	State["text"] := Text
	State["usage"] := Usage
}

_RCTC_RecordFailure(State, *) {
	State["fail_calls"] += 1
}

_RCTC_ReadTerminal(State, *) {
	return State["terminal"]
}

_RCTC_RecordCleanup(State, *) {
	State["cleanup_calls"] += 1
}

_RCTC_RunPoll(Terminal) {
	global _LLM_Remote_Async
	ReqId := 700700 + _LLM_Remote_Async.Count
	State := Map(
		"terminal", Terminal, "success_calls", 0, "fail_calls", 0,
		"cleanup_calls", 0, "text", "", "usage", 0)
	Entry := Map(
		"transport", "curl", "pid", 77, "cancelled", false,
		"tmp_payload", "payload", "tmp_stdout", "stdout", "tmp_config", "config",
		"tmp_status", "status", "tmp_exit", "exit", "format", "openai",
		"model_id_at_dispatch", "", "start_tick", A_TickCount, "timeout_ms", 10000,
		"on_success", _RCTC_RecordSuccess.Bind(State), "on_fail", _RCTC_RecordFailure.Bind(State))
	Port := Map(
		"process_exists", (*) => false,
		"read_terminal", _RCTC_ReadTerminal.Bind(State),
		"cleanup", _RCTC_RecordCleanup.Bind(State))
	_LLM_Remote_Async[ReqId] := Entry
	try _LLMRemote_PollCurl(ReqId, Port)
	finally {
		if _LLM_Remote_Async.Has(ReqId)
			_LLM_Remote_Async.Delete(ReqId)
	}
	return State
}

_RCTC_RealCurlPollUsesTypedTerminalClassifier() {
	Failure := _RCTC_RunPoll(_RCTC_Terminal(0, 401, true,
		'{"choices":[{"message":{"content":"must not publish"}}],"usage":{"total_tokens":99}}'))
	AssertEqual(0, Failure["success_calls"], "HTTP 401 must never reach on_success")
	AssertEqual(1, Failure["fail_calls"], "HTTP 401 must reach on_fail exactly once")
	AssertEqual(1, Failure["cleanup_calls"], "terminal failure must clean its exact owner once")

	Success := _RCTC_RunPoll(_RCTC_Terminal(0, 200, true,
		'{"choices":[{"message":{"content":"owned answer"}}],"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}'))
	AssertEqual(1, Success["success_calls"], "canonical 2xx completion must reach on_success once")
	AssertEqual(0, Success["fail_calls"], "canonical 2xx completion must not reach on_fail")
	AssertEqual("owned answer", Success["text"], "the poll must forward the classified canonical text")
	AssertEqual(5, Success["usage"]["total_tokens"], "the poll must forward usage from the same classified root")
	AssertEqual(1, Success["cleanup_calls"], "successful terminal publication must clean its owner once")
}
Test("AHK-007 remote terminal: real curl poll consumes the typed classifier (ahk-007-remote-terminal-classification)",
	_RCTC_RealCurlPollUsesTypedTerminalClassifier)
