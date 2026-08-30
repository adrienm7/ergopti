; static/ergopti_plus/windows/tests/unit/test_llm_api_ollama.ahk

; ==============================================================================
; MODULE: LLM API Ollama Tests
; DESCRIPTION:
; Unit-tests for the purely-logical helpers in modules/llm/api_ollama.ahk:
; LLM_BuildOllamaPayload, LLM_ParseOllamaResponse, LLM_UnescapeJSON,
; LLM_OllamaCancelAllAsync, the unknown-id poll path, and the async-registry
; trimming logic. All tests are offline — no real HTTP calls are made.
; ==============================================================================




; =====================================================
; =====================================================
; ======= 1/ LLM_BuildOllamaPayload ===================
; =====================================================
; =====================================================

_OllamaPayload_ContainsModel() {
	payload := LLM_BuildOllamaPayload("qwen2.5:3b", "sys", "hello", 0.1)
	AssertContains(payload, '"model":"qwen2.5:3b"')
}
Test("LLM_BuildOllamaPayload: contains model field", _OllamaPayload_ContainsModel)


_OllamaPayload_ContainsSystem() {
	payload := LLM_BuildOllamaPayload("m", "My system prompt", "user text", 0.1)
	AssertContains(payload, '"role":"system"')
	AssertContains(payload, "My system prompt")
}
Test("LLM_BuildOllamaPayload: contains system field", _OllamaPayload_ContainsSystem)


_OllamaPayload_ContainsPrompt() {
	payload := LLM_BuildOllamaPayload("m", "sys", "user context here", 0.5)
	AssertContains(payload, '"role":"user"')
	AssertContains(payload, "user context here")
}
Test("LLM_BuildOllamaPayload: contains user message", _OllamaPayload_ContainsPrompt)


_OllamaPayload_StreamFalseByDefault() {
	payload := LLM_BuildOllamaPayload("m", "s", "u", 0.1)
	AssertContains(payload, '"stream":false')
}
Test("LLM_BuildOllamaPayload: stream is false by default", _OllamaPayload_StreamFalseByDefault)


_OllamaPayload_StreamTrueWhenRequested() {
	payload := LLM_BuildOllamaPayload("m", "s", "u", 0.1, true)
	AssertContains(payload, '"stream":true')
}
Test("LLM_BuildOllamaPayload: stream is true when requested", _OllamaPayload_StreamTrueWhenRequested)


_OllamaPayload_ContainsTemperature() {
	payload := LLM_BuildOllamaPayload("m", "s", "u", 0.7)
	AssertContains(payload, '"temperature":0.7')
}
Test("LLM_BuildOllamaPayload: contains temperature in options", _OllamaPayload_ContainsTemperature)


_OllamaPayload_EscapesQuotesInPrompt() {
	payload := LLM_BuildOllamaPayload("m", "s", 'say "hello"', 0.1)
	; The double quote inside the user text must be escaped to \" in the JSON
	AssertContains(payload, '\"hello\"')
}
Test("LLM_BuildOllamaPayload: escapes double quotes in user text", _OllamaPayload_EscapesQuotesInPrompt)


_OllamaPayload_EscapesNewlineInSystem() {
	payload := LLM_BuildOllamaPayload("m", "line1`nline2", "u", 0.1)
	AssertContains(payload, "\n")
}
Test("LLM_BuildOllamaPayload: escapes newlines in system prompt", _OllamaPayload_EscapesNewlineInSystem)


_OllamaPayload_PreservesUnicodeInJson() {
	payload := LLM_BuildOllamaPayload("m", "sys", "éà résumé ★", 0.1)
	AssertContains(payload, "é")
	AssertContains(payload, "★")
}
Test("LLM_BuildOllamaPayload: preserves UTF-8 context in JSON (curl payload file)", _OllamaPayload_PreservesUnicodeInJson)


_OllamaPayload_StopSequencesIncluded() {
	; Chr(96) x3 = ``` — backtick is AHK's escape char and cannot appear literally
	; in a string literal; use Chr(96) for each backtick to avoid escape processing.
	ThreeBackticks := Chr(96) . Chr(96) . Chr(96)
	stops := [ThreeBackticks, "`n`n"]
	payload := LLM_BuildOllamaPayload("m", "s", "u", 0.1, false, stops)
	AssertContains(payload, '"stop"')
	AssertContains(payload, '"' . ThreeBackticks . '"')
}
Test("LLM_BuildOllamaPayload: stop_sequences included when provided", _OllamaPayload_StopSequencesIncluded)


_OllamaPayload_StopSequencesAbsentWhenEmpty() {
	payload := LLM_BuildOllamaPayload("m", "s", "u", 0.1, false, "")
	; Implementation defaults to standard stop tokens (STOP_BATCH/STOP_LINE) if empty,
	; so the "stop" field IS present in the JSON options.
	AssertContains(payload, '"stop"', "stop field must be present (defaults to standard stops)")
}
Test("LLM_BuildOllamaPayload: stop field present (defaulted) when no stop sequences", _OllamaPayload_StopSequencesAbsentWhenEmpty)


; A5 — num_predict is the shared PromptBuilder max_tokens threaded from the
; engine (single cross-driver source), not the former local mw*4 re-derivation.
_OllamaPayload_NumPredictFromMaxTokens() {
	payload := LLM_BuildOllamaPayload("m", "s", "u", 0.1, false, "", 42)
	AssertContains(payload, '"num_predict":42', "num_predict must equal the threaded max_tokens")
}
Test("LLM_BuildOllamaPayload: num_predict equals the threaded max_tokens (A5)", _OllamaPayload_NumPredictFromMaxTokens)

_OllamaPayload_NumPredictDefault() {
	payload := LLM_BuildOllamaPayload("m", "s", "u", 0.1)
	AssertContains(payload, '"num_predict":150', "num_predict defaults to the PromptBuilder default 150")
}
Test("LLM_BuildOllamaPayload: num_predict defaults to PromptBuilder default (A5)", _OllamaPayload_NumPredictDefault)




; ===================================================
; ===================================================
; ======= 2/ LLM_ParseOllamaResponse =================
; ===================================================
; ===================================================

_OllamaParseResponse_ExtractsText() {
	raw := '{"model":"qwen2.5:3b","response":"hello world","done":true}'
	result := LLM_ParseOllamaResponse(raw)
	AssertEqual("hello world", result)
}
Test("LLM_ParseOllamaResponse: extracts response field", _OllamaParseResponse_ExtractsText)


_OllamaParseResponse_EmptyOnMissingField() {
	raw := '{"model":"qwen2.5:3b","done":false}'
	result := LLM_ParseOllamaResponse(raw)
	AssertEqual("", result)
}
Test("LLM_ParseOllamaResponse: returns empty when response field absent", _OllamaParseResponse_EmptyOnMissingField)


_OllamaParseResponse_EmptyOnEmptyInput() {
	result := LLM_ParseOllamaResponse("")
	AssertEqual("", result)
}
Test("LLM_ParseOllamaResponse: returns empty on empty input", _OllamaParseResponse_EmptyOnEmptyInput)


_OllamaParseResponse_UnescapesNewlines() {
	raw := '{"response":"line1\nline2","done":true}'
	result := LLM_ParseOllamaResponse(raw)
	AssertContains(result, "`n")
}
Test("LLM_ParseOllamaResponse: unescapes \\n sequences", _OllamaParseResponse_UnescapesNewlines)


_OllamaParseResponse_UnescapesQuotes() {
	raw := '{"response":"say \"hi\"","done":true}'
	result := LLM_ParseOllamaResponse(raw)
	AssertContains(result, '"hi"')
}
Test("LLM_ParseOllamaResponse: unescapes escaped quotes", _OllamaParseResponse_UnescapesQuotes)


_OllamaParseResponse_EmptyResponseFieldReturnsEmpty() {
	raw := '{"response":"","done":true}'
	result := LLM_ParseOllamaResponse(raw)
	AssertEqual("", result)
}
Test("LLM_ParseOllamaResponse: empty response field returns empty string", _OllamaParseResponse_EmptyResponseFieldReturnsEmpty)


_OllamaParseChatResponse_ExtractsMessageContent() {
	raw := '{"model":"qwen3.5:0.8b","message":{"role":"assistant","content":"bonjour le monde"},"done":true}'
	result := LLM_ParseOllamaChatResponse(raw)
	AssertEqual("bonjour le monde", result)
}
Test("LLM_ParseOllamaChatResponse: extracts message.content from /api/chat", _OllamaParseChatResponse_ExtractsMessageContent)


_OllamaParseChatResponse_FallsBackToLegacyGenerate() {
	raw := '{"model":"qwen2.5:3b","response":"legacy path","done":true}'
	result := LLM_ParseOllamaChatResponse(raw)
	AssertEqual("legacy path", result)
}
Test("LLM_ParseOllamaChatResponse: falls back to legacy response field", _OllamaParseChatResponse_FallsBackToLegacyGenerate)


_OllamaPayload_ThinkDisabled() {
	payload := LLM_BuildOllamaPayload("qwen3.5:0.8b", "sys", "ctx", 0.1)
	AssertContains(payload, '"think":false')
}
Test("LLM_BuildOllamaPayload: think is false for qwen3 models", _OllamaPayload_ThinkDisabled)


_OllamaPayload_StopCrNotEmpty() {
	payload := LLM_BuildOllamaPayload("m", "s", "u", 0.1)
	AssertFalse(RegExMatch(payload, ',""\]'), "stop array must not contain an empty token (\\r was dropped)")
	AssertContains(payload, '\r')
}
Test("LLM_BuildOllamaPayload: carriage-return stop serialises as \\r not empty string", _OllamaPayload_StopCrNotEmpty)


_OllamaPayload_AppendsNoThinkForQwen3() {
	payload := LLM_BuildOllamaPayload("qwen3.5:0.8b", "PREFIX and TAIL", "full", 0.1, false, "", 15, false, "tail")
	AssertContains(payload, "/no_think")
}
Test("LLM_BuildOllamaPayload: appends /no_think for reasoning models", _OllamaPayload_AppendsNoThinkForQwen3)




; ================================================
; ================================================
; ======= 3/ LLM_UnescapeJSON ====================
; ================================================
; ================================================

_UnescapeJSON_NewlineSequence() {
	result := LLM_UnescapeJSON("hello\nworld")
	AssertEqual("hello`nworld", result)
}
Test("LLM_UnescapeJSON: converts \\n to newline", _UnescapeJSON_NewlineSequence)


_UnescapeJSON_TabSequence() {
	result := LLM_UnescapeJSON("col1\tcol2")
	AssertEqual("col1`tcol2", result)
}
Test("LLM_UnescapeJSON: converts \\t to tab", _UnescapeJSON_TabSequence)


_UnescapeJSON_EscapedQuote() {
	result := LLM_UnescapeJSON('say \"hi\"')
	AssertEqual('say "hi"', result)
}
Test("LLM_UnescapeJSON: converts backslash-quote to double quote", _UnescapeJSON_EscapedQuote)


_UnescapeJSON_EscapedBackslash() {
	result := LLM_UnescapeJSON("path\\\\dir")
	AssertEqual("path\\dir", result)
}
Test("LLM_UnescapeJSON: converts \\\\\\\\ to single backslash", _UnescapeJSON_EscapedBackslash)


_UnescapeJSON_PlainStringUnchanged() {
	result := LLM_UnescapeJSON("plain text")
	AssertEqual("plain text", result)
}
Test("LLM_UnescapeJSON: plain string without escapes is unchanged", _UnescapeJSON_PlainStringUnchanged)


; Regression: an escaped backslash immediately followed by another escape
; sequence used to silently lose the backslash entirely. The neutralising
; sentinel used to be Chr(0) -- AHK strings are internally null-terminated,
; so StrReplace() with a null character truncates/drops it instead of
; substituting it, corrupting anything the sentinel touched. Verified with a
; standalone probe: StrReplace("a\\\nb", "\\", Chr(0)) produced a 4-char
; result instead of the correct 5 (sentinel, real backslash, "n", intact).
; Chr(0xE000) (a Unicode private-use codepoint, never null) fixes it.
_UnescapeJSON_BackslashAdjacentToAnotherEscape() {
	result := LLM_UnescapeJSON("a\\\nb")
	AssertEqual("a\`nb", result, "an escaped backslash immediately before another escape sequence must not be dropped")
}
Test("LLM_UnescapeJSON: an escaped backslash adjacent to another escape sequence is not lost",
	_UnescapeJSON_BackslashAdjacentToAnotherEscape)




; ====================================================
; ====================================================
; ======= 4/ Async registry — cancel helpers =========
; ====================================================
; ====================================================

; Same guarantee the retired LLM_OllamaCancelAsync test asserted — cancelling an
; in-flight request must flip the flag the poll tick reads — but exercised against
; the entry shape _LLM_Ollama_DispatchAsync actually creates. The old fixture
; injected a "http" key that no production code path ever writes, which is exactly
; how a dead WinHTTP branch kept looking like a supported transport: the only test
; that touched it fabricated the shape it needed. No COM object here, because the
; live Ollama transport is a curl child identified by its pid.
_OllamaCancel_FlagsProductionShapedEntry() {
	global _LLM_Ollama_Async
	fake_id := 99901
	_LLM_Ollama_Async[fake_id] := Map(
		"pid", 0, "tmp_payload", "", "tmp_stdout", "",
		"on_success", (*) => 0, "on_fail", (*) => 0,
		"cancelled", false, "start_tick", A_TickCount,
		"timeout_ms", 1000, "payload_snip", "")
	LLM_OllamaCancelAllAsync()
	AssertTrue(_LLM_Ollama_Async[fake_id]["cancelled"],
		"the cancel must flip the flag on an entry shaped as production creates it — the poll tick reads that flag, and deleting the entry is the tick's job, not the cancel's")
	_LLM_Ollama_Async.Delete(fake_id)
}
Test("LLM_OllamaCancelAllAsync: flags an entry shaped exactly as the dispatcher creates it", _OllamaCancel_FlagsProductionShapedEntry)


; The retired singular cancel carried this guarantee for its req_id argument; the
; surviving req_id-taking entry point is the curl poll tick, which a stale
; SetTimer closure can still reach after the registry entry is gone. AHK v2 throws
; on Map[missing_key], so the lookup must go through .Has() — assert the behaviour,
; not the spelling.
_OllamaPollCurl_NoOpOnMissingId() {
	global _LLM_Ollama_Async
	before_count := _LLM_Ollama_Async.Count
	_LLM_Ollama_PollCurl(999999)
	AssertEqual(before_count, _LLM_Ollama_Async.Count,
		"a poll tick for an id no longer in the registry must return silently, not throw and not mutate the registry")
}
Test("_LLM_Ollama_PollCurl: no-op when the request id is no longer in the registry", _OllamaPollCurl_NoOpOnMissingId)


_OllamaPidReceipt_RecordSuccess(State, Text) {
	State["success_calls"] += 1
	State["text"] := Text
}

_OllamaPidReceipt_RecordFailure(State, *) {
	State["fail_calls"] += 1
}

_OllamaPidReceipt_CompleteGenerationPrecedesDeadline() {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending
	ReqId := 999001
	State := Map("success_calls", 0, "fail_calls", 0,
		"close_calls", 0, "terminate_calls", 0, "text", "")
	Port := Map(
		"open_process", (*) => 9201,
		"close_process", (*) => (State["close_calls"] += 1, true),
		"terminate_process", (*) => (State["terminate_calls"] += 1, true),
		"read_terminal", (*) => Map(
			"complete", true, "exit", 0, "status", 200,
			"body_read", true,
			"body", '{"message":{"content":"owned generation"}}'))
	ProcessOwner := _LLM_CurlAdoptProcess(4245, Port)
	_LLM_Ollama_Pending := ""
	_LLM_Ollama_Async[ReqId] := Map(
		"pid", 4245,
		"process_owner", ProcessOwner,
		"tmp_payload", "payload",
		"tmp_stdout", "body",
		"tmp_status", "status",
		"tmp_exit", "exit",
		"on_success", _OllamaPidReceipt_RecordSuccess.Bind(State),
		"on_fail", _OllamaPidReceipt_RecordFailure.Bind(State),
		"cancelled", false,
		"start_tick", A_TickCount - 100000,
		"timeout_ms", 1,
		"payload_snip", "fixture")
	try {
		_LLM_Ollama_PollCurl(ReqId, Port)
		AssertEqual(1, State["success_calls"],
			"(ahk2-04-curl-receipt-first) a complete generation receipt must beat the wall deadline")
		AssertEqual(0, State["fail_calls"],
			"the committed generation must not be reclassified as timeout")
		AssertEqual("owned generation", State["text"],
			"the exact terminal body must reach the generation callback")
		AssertEqual(0, State["terminate_calls"],
			"a complete receipt must never terminate the process owner")
		AssertEqual(1, State["close_calls"],
			"the exact retained process handle must be closed once")
		AssertFalse(_LLM_Ollama_Async.Has(ReqId),
			"the completed generation must retire its registry slot")
	} finally {
		if _LLM_Ollama_Async.Has(ReqId)
			_LLM_Ollama_Async.Delete(ReqId)
		_LLM_Ollama_Pending := ""
	}
}
Test("Ollama generation poll: terminal receipt precedes recycled PID and deadline "
	. "(ahk2-04-curl-receipt-first)",
	_OllamaPidReceipt_CompleteGenerationPrecedesDeadline)


_OllamaPidReceipt_CancelUsesExactHandle() {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending
	ReqId := 999002
	State := Map("success_calls", 0, "fail_calls", 0,
		"close_calls", 0, "terminate_calls", 0,
		"terminated_handle", 0)
	Port := Map(
		"open_process", (*) => 9202,
		"close_process", (*) => (State["close_calls"] += 1, true),
		"terminate_process", (Handle) => (
			State["terminate_calls"] += 1,
			State["terminated_handle"] := Handle,
			true),
		"read_terminal", (*) => Map(
			"complete", false, "exit", -1, "status", 0,
			"body_read", false, "body", ""))
	ProcessOwner := _LLM_CurlAdoptProcess(4246, Port)
	_LLM_Ollama_Pending := ""
	_LLM_Ollama_Async[ReqId] := Map(
		"pid", 4246, "process_owner", ProcessOwner,
		"tmp_payload", "payload", "tmp_stdout", "body",
		"tmp_status", "status", "tmp_exit", "exit",
		"on_success", _OllamaPidReceipt_RecordSuccess.Bind(State),
		"on_fail", _OllamaPidReceipt_RecordFailure.Bind(State),
		"cancelled", true, "start_tick", A_TickCount,
		"timeout_ms", 100000, "payload_snip", "fixture")
	try {
		_LLM_Ollama_PollCurl(ReqId, Port)
		AssertEqual(1, State["terminate_calls"],
			"cancel must terminate the exact retained generation handle once")
		AssertEqual(9202, State["terminated_handle"],
			"cancel must not reopen the recyclable numeric PID")
		AssertEqual(1, State["close_calls"],
			"cancel must close the exact generation handle once")
		AssertEqual(0, State["success_calls"],
			"cancelled generation must never publish success")
		AssertEqual(0, State["fail_calls"],
			"the existing cancellation contract remains callback-silent")
		AssertFalse(_LLM_Ollama_Async.Has(ReqId),
			"cancel must retire the exact generation registry slot")
	} finally {
		if _LLM_Ollama_Async.Has(ReqId)
			_LLM_Ollama_Async.Delete(ReqId)
		_LLM_Ollama_Pending := ""
	}
}
Test("Ollama generation poll: cancellation terminates only the exact process handle "
	. "(ahk2-04-curl-exact-process-owner)",
	_OllamaPidReceipt_CancelUsesExactHandle)


_OllamaProcessCleanup_WithDebtIsolated(TestFn) {
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupDebtCounter
	global _LLM_CurlCleanupRetryTimer
	OldDebt := _LLM_CurlCleanupDebt
	OldCounter := _LLM_CurlCleanupDebtCounter
	OldTimer := _LLM_CurlCleanupRetryTimer
	_LLM_CurlCleanupDebt := Map()
	_LLM_CurlCleanupDebtCounter := 0
	_LLM_CurlCleanupRetryTimer := (*) => 0
	try TestFn.Call()
	finally {
		if HasMethod(_LLM_CurlCleanupRetryTimer, "Call")
			SetTimer(_LLM_CurlCleanupRetryTimer, 0)
		_LLM_CurlCleanupDebt := OldDebt
		_LLM_CurlCleanupDebtCounter := OldCounter
		_LLM_CurlCleanupRetryTimer := OldTimer
	}
}

_OllamaProcessCleanup_CloseRefusalRetainsOwner() {
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupRetryTimer
	State := Map("close_calls", 0, "accept_close", false)
	CloseProcess(Handle) {
		State["close_calls"] += 1
		return State["accept_close"]
	}
	Port := Map("close_process", CloseProcess)
	Owner := Map("pid", 4301, "handle", 9301, "released", false)

	AssertFalse(_LLM_CurlReleaseProcess(Owner, false, Port),
		"a refused CloseHandle receipt must keep curl cleanup non-terminal")
	AssertFalse(Owner["released"],
		"refused close must not publish a false released state")
	AssertEqual(9301, Owner["handle"],
		"the exact refused process handle must remain owned")
	AssertEqual(1, _LLM_CurlCleanupDebt.Count,
		"callers may retire immediately, so shared retry debt must retain the owner")

	State["accept_close"] := true
	_LLM_CurlCleanupRetryTimer := 0
	AssertTrue(LLM_CurlRetryCleanupDebt())
	AssertTrue(Owner["released"])
	AssertEqual(0, Owner["handle"])
	AssertEqual(0, _LLM_CurlCleanupDebt.Count)
	AssertEqual(2, State["close_calls"])
}
Test("Ollama process cleanup: close refusal retains exact ownership "
	. "(ollama-process-close-debt)",
	_OllamaProcessCleanup_WithDebtIsolated.Bind(
		_OllamaProcessCleanup_CloseRefusalRetainsOwner))

_OllamaProcessCleanup_TerminationRefusalKeepsHandleOpen() {
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupRetryTimer
	State := Map("terminate_calls", 0, "wait_calls", 0, "close_calls", 0,
		"accept_terminate", false)
	TerminateProcess(Handle) {
		State["terminate_calls"] += 1
		return State["accept_terminate"]
	}
	WaitProcess(Handle) {
		State["wait_calls"] += 1
		return 258
	}
	CloseProcess(Handle) {
		State["close_calls"] += 1
		return true
	}
	Port := Map(
		"terminate_process", TerminateProcess,
		"wait_process", WaitProcess,
		"close_process", CloseProcess)
	Owner := Map("pid", 4302, "handle", 9302, "released", false)

	AssertFalse(_LLM_CurlReleaseProcess(Owner, true, Port),
		"a live process whose termination was refused must remain owned")
	AssertFalse(Owner["released"])
	AssertEqual(9302, Owner["handle"],
		"termination refusal must preserve the exact process capability")
	AssertEqual(0, State["close_calls"],
		"the last exact handle must not close while its process is still alive")
	AssertEqual(1, _LLM_CurlCleanupDebt.Count)

	State["accept_terminate"] := true
	_LLM_CurlCleanupRetryTimer := 0
	AssertTrue(LLM_CurlRetryCleanupDebt())
	AssertTrue(Owner["released"])
	AssertEqual(0, Owner["handle"])
	AssertEqual(0, _LLM_CurlCleanupDebt.Count)
	AssertEqual(2, State["terminate_calls"])
	AssertEqual(1, State["close_calls"])
}
Test("Ollama process cleanup: termination refusal retains exact ownership "
	. "(ollama-process-termination-debt)",
	_OllamaProcessCleanup_WithDebtIsolated.Bind(
		_OllamaProcessCleanup_TerminationRefusalKeepsHandleOpen))

_OllamaProcessCleanup_ReentrantCloseCannotRetireOwner() {
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupRetryTimer
	State := Map("close_calls", 0, "reentered", false,
		"nested_result", "unset", "accept_close", false)
	Owner := Map("pid", 4303, "handle", 9303, "released", false)
	Port := 0
	CloseProcess(Handle) {
		State["close_calls"] += 1
		if !State["reentered"] {
			State["reentered"] := true
			State["nested_result"] :=
				_LLM_CurlReleaseProcess(Owner, false, Port)
		}
		return State["accept_close"]
	}
	Port := Map("close_process", CloseProcess)

	AssertFalse(_LLM_CurlReleaseProcess(Owner, false, Port))
	AssertFalse(State["nested_result"],
		"reentrant release must observe the in-flight exact-handle owner")
	AssertEqual(1, State["close_calls"],
		"the same handle must not receive overlapping close calls")
	AssertFalse(Owner["released"])
	AssertEqual(9303, Owner["handle"])
	AssertEqual(1, _LLM_CurlCleanupDebt.Count,
		"nested and outer refusals must deduplicate one exact cleanup debt")

	State["accept_close"] := true
	_LLM_CurlCleanupRetryTimer := 0
	AssertTrue(LLM_CurlRetryCleanupDebt())
	AssertTrue(Owner["released"])
	AssertEqual(0, _LLM_CurlCleanupDebt.Count)
	AssertEqual(2, State["close_calls"])
}
Test("Ollama process cleanup: reentrant close keeps one exact owner "
	. "(ollama-process-cleanup-reentrancy)",
	_OllamaProcessCleanup_WithDebtIsolated.Bind(
		_OllamaProcessCleanup_ReentrantCloseCannotRetireOwner))


_OllamaCancelAllAsync_FlagsAll() {
	global _LLM_Ollama_Async
	; Inject two fake entries
	_LLM_Ollama_Async[99902] := Map("http", "", "on_success", (*) => 0, "on_fail", (*) => 0, "cancelled", false)
	_LLM_Ollama_Async[99903] := Map("http", "", "on_success", (*) => 0, "on_fail", (*) => 0, "cancelled", false)
	LLM_OllamaCancelAllAsync()
	AssertTrue(_LLM_Ollama_Async[99902]["cancelled"])
	AssertTrue(_LLM_Ollama_Async[99903]["cancelled"])
	_LLM_Ollama_Async.Delete(99902)
	_LLM_Ollama_Async.Delete(99903)
}
Test("LLM_OllamaCancelAllAsync: cancels every in-flight entry", _OllamaCancelAllAsync_FlagsAll)


_OllamaCancelAllAsync_NoOpOnEmptyRegistry() {
	global _LLM_Ollama_Async
	; Clear the registry then call — must not throw
	_LLM_Ollama_Async := Map()
	LLM_OllamaCancelAllAsync()
	AssertEqual(0, _LLM_Ollama_Async.Count)
}
Test("LLM_OllamaCancelAllAsync: no-op when registry is empty", _OllamaCancelAllAsync_NoOpOnEmptyRegistry)


; A coalesced job is parked in _LLM_Ollama_Pending while one request is in flight.
; On suspend the engine calls LLM_OllamaCancelAllAsync; it must DROP the pending
; job so the already-armed poll tick cannot re-dispatch it (a fresh curl POST +
; PII temp-file write) after the driver is paused, and must fail the displaced
; job exactly once (async contract). Regression: ollama-pending-survives-suspend.
_OllamaCancelAllAsync_ClearsPendingAndFailsOnce() {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending
	_LLM_Ollama_Async := Map()
	_LLM_Ollama_Async[99910] := Map("http", "", "on_success", (*) => 0, "on_fail", (*) => 0, "cancelled", false)
	failed := 0
	_LLM_Ollama_Pending := Map("on_success", (*) => 0, "on_fail", (*) => failed += 1)
	LLM_OllamaCancelAllAsync()
	AssertFalse(_LLM_Ollama_Pending is Map, "LLM_OllamaCancelAllAsync must clear _LLM_Ollama_Pending so a poll tick cannot re-dispatch curl + a PII write after suspend")
	AssertEqual(1, failed, "the displaced pending job's on_fail must fire exactly once")
	_LLM_Ollama_Async.Delete(99910)
	_LLM_Ollama_Pending := ""
}
Test("LLM_OllamaCancelAllAsync: clears the coalesced pending job and fails it once (ollama-pending-survives-suspend)", _OllamaCancelAllAsync_ClearsPendingAndFailsOnce)




; ===================================================
; ===================================================
; ======= 5/ Async registry — trim helper ============
; ===================================================
; ===================================================

_OllamaTrimRegistry_DropsOldestWhenAtCap() {
	global _LLM_Ollama_Async, LLM_OLLAMA_MAX_INFLIGHT
	; Fill the registry exactly to the cap, then add one — trim must remove
	; the first entry inserted (insertion-order semantics of AHK Maps)
	_LLM_Ollama_Async := Map()
	base_id := 88000
	loop LLM_OLLAMA_MAX_INFLIGHT
		_LLM_Ollama_Async[base_id + A_Index] := Map("cancelled", false)
	AssertEqual(LLM_OLLAMA_MAX_INFLIGHT, _LLM_Ollama_Async.Count)
	; _LLM_Ollama_TrimAsyncRegistry only trims when Count >= MAX_INFLIGHT
	_LLM_Ollama_TrimAsyncRegistry()
	AssertEqual(LLM_OLLAMA_MAX_INFLIGHT - 1, _LLM_Ollama_Async.Count)
	AssertFalse(_LLM_Ollama_Async.Has(base_id + 1), "oldest entry must have been removed")
	; Restore empty registry for subsequent tests
	_LLM_Ollama_Async := Map()
}
Test("_LLM_Ollama_TrimAsyncRegistry: removes oldest entry when at cap", _OllamaTrimRegistry_DropsOldestWhenAtCap)


_OllamaTrimRegistry_ReentrantSuccessor(State, *) {
	global _LLM_Ollama_Async
	State["callbacks"] += 1
	if State["callbacks"] != 1
		return
	_LLM_Ollama_TrimAsyncRegistry()
	_LLM_Ollama_Async[88013] := Map("cancelled", false, "on_fail", (*) => 0)
}

_OllamaTrimRegistry_DetachesBeforeReentrantCallback() {
	global _LLM_Ollama_Async, LLM_OLLAMA_MAX_INFLIGHT
	OldMax := LLM_OLLAMA_MAX_INFLIGHT
	State := Map("callbacks", 0)
	LLM_OLLAMA_MAX_INFLIGHT := 2
	_LLM_Ollama_Async := Map(
		88011, Map("cancelled", false,
			"on_fail", _OllamaTrimRegistry_ReentrantSuccessor.Bind(State)),
		88012, Map("cancelled", false, "on_fail", (*) => 0))
	Err := ""
	try _LLM_Ollama_TrimAsyncRegistry()
	catch as Caught
		Err := Caught.Message
	finally LLM_OLLAMA_MAX_INFLIGHT := OldMax
	try {
		AssertEqual("", Err,
			"Ollama trim must not delete an owner already detached by reentrant work")
		AssertEqual(1, State["callbacks"],
			"the displaced Ollama owner must emit exactly one terminal callback")
		AssertFalse(_LLM_Ollama_Async.Has(88011),
			"the displaced owner must be absent before its callback starts")
		AssertTrue(_LLM_Ollama_Async.Has(88012),
			"the surviving Ollama request must remain registered")
		AssertTrue(_LLM_Ollama_Async.Has(88013),
			"the callback's successor must not be trimmed or removed by its predecessor")
		AssertEqual(2, _LLM_Ollama_Async.Count,
			"Ollama trim plus one reentrant successor must finish exactly at the cap")
	} finally {
		_LLM_Ollama_Async := Map()
	}
}
Test("api_ollama: trim detaches owner before reentrant callback (async-trim-detach-before-callback)",
	_OllamaTrimRegistry_DetachesBeforeReentrantCallback)


_OllamaTrimRegistry_NoOpBelowCap() {
	global _LLM_Ollama_Async, LLM_OLLAMA_MAX_INFLIGHT
	_LLM_Ollama_Async := Map()
	_LLM_Ollama_Async[77001] := Map("cancelled", false)
	_LLM_Ollama_TrimAsyncRegistry()
	; Count should remain 1 because we are below the cap
	AssertEqual(1, _LLM_Ollama_Async.Count)
	_LLM_Ollama_Async := Map()
}
Test("_LLM_Ollama_TrimAsyncRegistry: no-op when registry is below cap", _OllamaTrimRegistry_NoOpBelowCap)




; ====================================================
; ====================================================
; ======= 5b/ _LLM_Ollama_DoSpawn — cancel/suspend ===
; ====================================================
; ====================================================

; F23: the deferred SetTimer(-1) spawn must never write the PII payload file
; or launch curl once the request has been cancelled — mirrors the sibling
; poll functions' "cancelled" re-check.
_OllamaDoSpawn_SkipsWhenCancelled() {
	global _LLM_Ollama_Async
	fake_id := 99930
	tmp_payload := A_Temp . "\ergopti_test_dospawn_cancel_" . fake_id . ".json"
	tmp_stdout := A_Temp . "\ergopti_test_dospawn_cancel_" . fake_id . ".out"
	try FSDelete(tmp_payload)
	failed := 0
	job := Map("on_success", (*) => 0, "on_fail", (*) => failed += 1)
	_LLM_Ollama_Async[fake_id] := Map("pid", 0, "tmp_payload", tmp_payload, "tmp_stdout", tmp_stdout,
		"on_success", job["on_success"], "on_fail", job["on_fail"], "cancelled", true,
		"start_tick", A_TickCount, "timeout_ms", 5000, "payload_snip", "")
	_LLM_Ollama_DoSpawn(fake_id, '{"model":"m"}', tmp_payload, tmp_stdout, job)
	AssertFalse(FileExist(tmp_payload) != "", "a cancelled deferred spawn must never write the PII payload file to disk")
	AssertFalse(_LLM_Ollama_Async.Has(fake_id), "the cancelled entry must be removed from the registry")
	AssertEqual(1, failed, "on_fail must fire exactly once for a spawn skipped due to cancellation")
	try FSDelete(tmp_payload)
}
Test("_LLM_Ollama_DoSpawn: skips writing payload + launching curl when cancelled before dispatch (F23)", _OllamaDoSpawn_SkipsWhenCancelled)


; F23: the deferred spawn must also never fire once the driver is suspended,
; even though no cancel was issued (the two menu/engine paths that call
; LLM_OllamaCancelAllAsync on suspend are a separate safety net — this guard
; is the last line of defence inside the spawn itself).
_OllamaDoSpawn_SkipsWhenSuspended() {
	global _LLM_Ollama_Async
	fake_id := 99931
	tmp_payload := A_Temp . "\ergopti_test_dospawn_susp_" . fake_id . ".json"
	tmp_stdout := A_Temp . "\ergopti_test_dospawn_susp_" . fake_id . ".out"
	try FSDelete(tmp_payload)
	failed := 0
	job := Map("on_success", (*) => 0, "on_fail", (*) => failed += 1)
	_LLM_Ollama_Async[fake_id] := Map("pid", 0, "tmp_payload", tmp_payload, "tmp_stdout", tmp_stdout,
		"on_success", job["on_success"], "on_fail", job["on_fail"], "cancelled", false,
		"start_tick", A_TickCount, "timeout_ms", 5000, "payload_snip", "")
	Suspend(1)
	try {
		_LLM_Ollama_DoSpawn(fake_id, '{"model":"m"}', tmp_payload, tmp_stdout, job)
	} finally {
		Suspend(0)
	}
	AssertFalse(FileExist(tmp_payload) != "", "a deferred spawn firing after Suspend must never write the PII payload file to disk")
	AssertEqual(1, failed, "on_fail must fire exactly once for a spawn skipped due to suspend")
	try FSDelete(tmp_payload)
}
Test("_LLM_Ollama_DoSpawn: skips writing payload + launching curl when driver is suspended (F23)", _OllamaDoSpawn_SkipsWhenSuspended)


; F23: an entry that vanished before the tick fired (e.g. TrimAsyncRegistry
; already evicted it and fired on_fail) must be a silent no-op — calling
; on_fail again here would violate the "exactly once" async contract.
_OllamaDoSpawn_MissingEntryIsSilentNoOp() {
	global _LLM_Ollama_Async
	fake_id := 99932
	if _LLM_Ollama_Async.Has(fake_id)  ; ensure absent — Map.Delete() throws on a missing key
		_LLM_Ollama_Async.Delete(fake_id)
	failed := 0
	job := Map("on_success", (*) => 0, "on_fail", (*) => failed += 1)
	tmp_payload := A_Temp . "\ergopti_test_dospawn_missing_" . fake_id . ".json"
	_LLM_Ollama_DoSpawn(fake_id, '{"model":"m"}', tmp_payload, tmp_payload, job)
	AssertEqual(0, failed, "a spawn tick for an already-evicted entry must not re-fire on_fail")
	try FSDelete(tmp_payload)
}
Test("_LLM_Ollama_DoSpawn: missing registry entry is a silent no-op, not a second on_fail (F23)", _OllamaDoSpawn_MissingEntryIsSilentNoOp)


_OllamaDoSpawn_CancelDuringWrite(State, Path, Payload) {
	State["writes"] += 1
	LLM_OllamaCancelAllAsync()
	return true
}

_OllamaDoSpawn_RecordUnexpectedRun(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	State["runs"] += 1
	Pid := 99933
	ProcessOwner := Map("pid", Pid, "handle", 99933, "released", false)
}

_OllamaDoSpawn_CancelledWhileWriting() {
	global _LLM_Ollama_ActiveStreams, _LLM_Ollama_Async, _LLM_Ollama_Pending
	fake_id := 99933
	State := Map("writes", 0, "runs", 0, "polls", 0, "deletes", 0, "failed", 0)
	Port := Map(
		"write", _OllamaDoSpawn_CancelDuringWrite.Bind(State),
		"delete", (Path) => (State["deletes"] += 1, true),
		"run", _OllamaDoSpawn_RecordUnexpectedRun.Bind(State),
		"poll", (ReqId) => State["polls"] += 1)
	_LLM_Ollama_Async := Map()
	_LLM_Ollama_ActiveStreams := []
	_LLM_Ollama_Pending := ""
	job := Map("on_success", (*) => 0, "on_fail", (*) => State["failed"] += 1)
	_LLM_Ollama_Async[fake_id] := Map("pid", 0, "process_owner", 0,
		"tmp_payload", "write-race.json", "tmp_stdout", "write-race.out",
		"tmp_status", "write-race.status", "tmp_exit", "write-race.exit",
		"on_success", job["on_success"], "on_fail", job["on_fail"], "cancelled", false,
		"start_tick", A_TickCount, "timeout_ms", 5000, "payload_snip", "")
	try {
		_LLM_Ollama_DoSpawn(fake_id, '{"model":"m"}', "write-race.json",
			"write-race.out", job, Port)
		AssertEqual(1, State["writes"], "the payload write seam must run once")
		AssertEqual(0, State["runs"], "cancellation during payload write must prevent the curl launch")
		AssertEqual(0, State["polls"], "a cancelled pre-launch request must not arm a poll")
		AssertFalse(_LLM_Ollama_Async.Has(fake_id), "the cancelled request must be retired before launch")
		AssertEqual(1, State["failed"], "cancellation during payload write must fail exactly once")
	} finally {
		_LLM_Ollama_Async := Map()
		_LLM_Ollama_ActiveStreams := []
		_LLM_Ollama_Pending := ""
	}
}
Test("_LLM_Ollama_DoSpawn: cancellation during payload write prevents curl launch (AHK-153)", _OllamaDoSpawn_CancelledWhileWriting)


_OllamaStreaming_CancelDuringTempDir(State) {
	State["temp_dirs"] += 1
	LLM_OllamaCancelStreams()
	return A_Temp
}

_OllamaStreaming_CancelledWhileOpeningTempDir() {
	global _LLM_Ollama_ActiveStreams
	State := Map("temp_dirs", 0, "writes", 0, "runs", 0, "failed", 0)
	Port := Map(
		"temp_dir", _OllamaStreaming_CancelDuringTempDir.Bind(State),
		"write", (Path, Payload) => (State["writes"] += 1, true),
		"run", _OllamaStreaming_RecordUnexpectedRun.Bind(State))
	_LLM_Ollama_ActiveStreams := []
	try {
		handle := LLM_OllamaGenerate_Streaming("m", "s", "private text", 0.1,
			(*) => 0, (*) => 0, (*) => State["failed"] += 1,
			"", "", false, "", Port)
		AssertTrue(handle.Cancelled, "cancelling during private-directory setup must mark the pre-launch stream handle")
		AssertEqual(1, State["temp_dirs"], "the private-directory seam must run once")
		AssertEqual(0, State["writes"], "cancellation during private-directory setup must prevent the payload write")
		AssertEqual(0, State["runs"], "cancellation during private-directory setup must prevent the curl launch")
		AssertEqual(1, State["failed"], "the cancelled pre-write stream must fail exactly once")
		AssertEqual(0, _LLM_Ollama_ActiveStreams.Length, "a cancelled pre-write stream must leave no active handle")
	} finally {
		_LLM_Ollama_ActiveStreams := []
	}
}
Test("LLM_OllamaGenerate_Streaming: cancellation during private-directory setup prevents payload write (AHK-153)", _OllamaStreaming_CancelledWhileOpeningTempDir)


_OllamaStreaming_CancelDuringWrite(State, Path, Payload) {
	State["writes"] += 1
	LLM_OllamaCancelStreams()
	return true
}

_OllamaStreaming_RecordUnexpectedRun(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	State["runs"] += 1
	Pid := 99934
	ProcessOwner := Map("pid", Pid, "handle", 99934, "released", false)
}

_OllamaStreaming_CancelledWhileWriting() {
	global _LLM_Ollama_ActiveStreams
	State := Map("writes", 0, "runs", 0, "failed", 0)
	Port := Map(
		"temp_dir", (*) => A_Temp,
		"write", _OllamaStreaming_CancelDuringWrite.Bind(State),
		"run", _OllamaStreaming_RecordUnexpectedRun.Bind(State))
	_LLM_Ollama_ActiveStreams := []
	try {
		handle := LLM_OllamaGenerate_Streaming("m", "s", "private text", 0.1,
			(*) => 0, (*) => 0, (*) => State["failed"] += 1,
			"", "", false, "", Port)
		AssertTrue(handle.Cancelled, "cancelling during a payload write must mark the pre-launch stream handle")
		AssertEqual(1, State["writes"], "the streaming payload write seam must run once")
		AssertEqual(0, State["runs"], "a cancelled streaming payload write must not launch curl")
		AssertEqual(1, State["failed"], "the cancelled streaming request must fail exactly once")
		AssertEqual(0, _LLM_Ollama_ActiveStreams.Length, "a cancelled pre-launch stream must leave no active handle")
	} finally {
		_LLM_Ollama_ActiveStreams := []
	}
}
Test("LLM_OllamaGenerate_Streaming: cancellation during payload write prevents curl launch (AHK-153)", _OllamaStreaming_CancelledWhileWriting)


_OllamaStreamErrorOverridesPartialText() {
	Partials := []
	State := Map("acc", "", "last_pos", 0)
	_LLM_Ollama_ConsumeStreamChunk(
		'{"message":{"content":"partial"},"done":false}' . "`n",
		State, (Text) => Partials.Push(Text))
	_LLM_Ollama_ConsumeStreamChunk(
		'{"error":"model runner stopped"}' . "`n",
		State, (Text) => Partials.Push(Text))
	Result := _LLM_Ollama_StreamTerminalResult(State)
	AssertFalse(Result["ok"],
		"a provider error must remain terminal even after valid partial text")
	AssertContains(Result["error"], "model runner stopped")
	AssertEqual("partial", State["acc"],
		"diagnostics may retain accepted partial text without promoting it to success")
	CompletedState := Map("acc", "", "last_pos", 0)
	_LLM_Ollama_ConsumeStreamChunk(
		'{"message":{"content":"complete"},"done":true}' . "`n",
		CompletedState, (*) => 0)
	Completed := _LLM_Ollama_StreamTerminalResult(CompletedState)
	AssertTrue(Completed["ok"], "a canonical done envelope must still complete")
	AssertEqual("complete", Completed["text"])
}
Test("Ollama stream: provider error overrides accumulated text (AHK-072)",
	_OllamaStreamErrorOverridesPartialText)

_OllamaStreamParserReturnsTypedVerdicts() {
	EmptyToken := _LLM_Ollama_ParseStreamLine(
		'{"message":{"content":""},"done":true}')
	AssertTrue(EmptyToken["ok"], "an empty final token is a valid stream envelope")
	AssertTrue(EmptyToken["done"])
	AssertEqual("", EmptyToken["token"])
	Malformed := _LLM_Ollama_ParseStreamLine("{not json")
	AssertFalse(Malformed["ok"], "malformed JSON must not collapse into an empty token")
	Assert(Malformed["error"] != "", "malformed JSON needs a durable failure reason")
}
Test("Ollama stream: parser distinguishes empty tokens from failures (AHK-072)",
	_OllamaStreamParserReturnsTypedVerdicts)

_TLAO_AppendRawBytes(Path, Bytes) {
	Payload := Buffer(Bytes.Length)
	for Index, Byte in Bytes
		NumPut("UChar", Byte, Payload, Index - 1)
	Handle := DllCall("Kernel32\CreateFileW", "Str", Path,
		"UInt", 0x40000000, "UInt", 0x3, "Ptr", 0, "UInt", 4,
		"UInt", 0x80, "Ptr", 0, "Ptr")
	Assert(Handle != -1, "test fixture must open its growing stream")
	try {
		EndPos := 0
		Assert(DllCall("Kernel32\SetFilePointerEx", "Ptr", Handle,
			"Int64", 0, "Int64*", &EndPos, "UInt", 2, "Int"),
			"test fixture must seek to the growing stream tail")
		Written := 0
		Assert(DllCall("Kernel32\WriteFile", "Ptr", Handle, "Ptr", Payload,
			"UInt", Payload.Size, "UInt*", &Written, "Ptr", 0, "Int"),
			"test fixture must write its raw byte fragment")
		AssertEqual(Bytes.Length, Written,
			"test fixture must publish every requested raw byte")
	} finally {
		DllCall("Kernel32\CloseHandle", "Ptr", Handle)
	}
}

_OllamaStreamReaderPreservesSplitUtf8() {
	Cases := [
		Map("bytes", [0xC3, 0xA9], "text", Chr(0xE9)),
		Map("bytes", [0xE2, 0x82, 0xAC], "text", Chr(0x20AC)),
		Map("bytes", [0xF0, 0x9F, 0x99, 0x82], "text", Chr(0x1F642))
	]
	for CaseIndex, CaseData in Cases {
		loop CaseData["bytes"].Length - 1 {
			SplitAt := A_Index
			Path := A_Temp . "\ergopti_ollama_utf8_split_" . A_TickCount
				. "_" . CaseIndex . "_" . SplitAt . ".bin"
			try {
				First := []
				Rest := []
				for Index, Byte in CaseData["bytes"] {
					if Index <= SplitAt
						First.Push(Byte)
					else
						Rest.Push(Byte)
				}
				_TLAO_AppendRawBytes(Path, First)
				State := Map("last_pos", 0)
				AssertEqual("", _LLM_Ollama_ReadStreamText(Path, State),
					"a poll must retain an incomplete UTF-8 code point")
				AssertEqual(0, State["last_pos"],
					"an incomplete code point must not advance the byte cursor")
				Rest.Push(0x0A)
				_TLAO_AppendRawBytes(Path, Rest)
				AssertEqual(CaseData["text"] . "`n",
					_LLM_Ollama_ReadStreamText(Path, State),
					"the next poll must reconstruct the exact UTF-8 code point")
				AssertEqual(CaseData["bytes"].Length + 1, State["last_pos"],
					"the cursor must advance only through complete newline records")
			} finally {
				try FileDelete(Path)
			}
		}
	}
}

Test("Ollama stream: growing-file reader preserves split UTF-8 code points (AHK-081)",
	_OllamaStreamReaderPreservesSplitUtf8)

_OllamaStreamReaderBoundsUnterminatedRecords() {
	Path := A_Temp . "\ergopti_ollama_record_limit_" . A_TickCount . ".txt"
	try {
		FileAppend("123456789", Path, "UTF-8-RAW")
		State := Map("last_pos", 0)
		Failure := ""
		try _LLM_Ollama_ReadStreamText(Path, State, false, 8)
		catch as Err
			Failure := Err.Message
		AssertContains(Failure, "record exceeds 8 bytes",
			"a non-delimited record at the read ceiling must fail instead of being re-read forever")
		AssertEqual(0, State["last_pos"],
			"a rejected oversized record must not advance the JSONL checkpoint")

		FileDelete(Path)
		FileAppend("a`nb`nc`nd`ne`n", Path, "UTF-8-RAW")
		State := Map("last_pos", 0)
		AssertEqual("a`nb`nc`nd`n", _LLM_Ollama_ReadStreamText(Path, State, true, 8),
			"the terminal reader must drain only one bounded group of complete records")
		AssertTrue(State["stream_bytes_pending"],
			"the terminal reader must advertise records left for its next deferred slice")
		AssertEqual("e`n", _LLM_Ollama_ReadStreamText(Path, State, true, 8),
			"the next bounded terminal slice must preserve the remaining record")
		AssertFalse(State["stream_bytes_pending"],
			"the pending marker must clear only once the terminal tail is exhausted")
	} finally {
		try FileDelete(Path)
	}
}
Test("Ollama stream: reader bounds malformed records and terminal slices (AHK-156)",
	_OllamaStreamReaderBoundsUnterminatedRecords)




; ===================================================
; ===================================================
; ======= 6/ Stream UID helper =======================
; ===================================================
; ===================================================

_OllamaStreamUid_IsUnique() {
	uid1 := _LLM_Ollama_NextStreamUid()
	uid2 := _LLM_Ollama_NextStreamUid()
	AssertFalse(uid1 == uid2, "consecutive UIDs must differ")
}
Test("_LLM_Ollama_NextStreamUid: consecutive calls return distinct values", _OllamaStreamUid_IsUnique)


_OllamaStreamUid_IsNonEmpty() {
	uid := _LLM_Ollama_NextStreamUid()
	Assert(StrLen(uid) > 0, "UID must be non-empty")
}
Test("_LLM_Ollama_NextStreamUid: returns non-empty string", _OllamaStreamUid_IsNonEmpty)




; =====================================================
; =====================================================
; ======= 6/ LLM_Ollama_SetPort =======================
; =====================================================
; =====================================================

; Guards the user-configurable Ollama port: LLM_Ollama_SetPort must rebuild
; LLM_OLLAMA_BASE_URL from the new port (so every request follows it) and reject
; out-of-range / non-integer input without corrupting the live URL.

_OllamaSetPort_ValidApplies() {
	global LLM_OLLAMA_BASE_URL
	ok := LLM_Ollama_SetPort(13434)
	AssertTrue(ok, "a valid in-range port must be accepted")
	AssertEqual("http://localhost:13434", LLM_OLLAMA_BASE_URL, "base URL must rebuild from the new port")
	LLM_Ollama_SetPort(11434)  ; restore the default for downstream tests
}
Test("LLM_Ollama_SetPort: valid port applies and rebuilds the base URL", _OllamaSetPort_ValidApplies)


_OllamaSetPort_RejectsLow() {
	global LLM_OLLAMA_BASE_URL
	LLM_Ollama_SetPort(11434)
	ok := LLM_Ollama_SetPort(80)
	AssertFalse(ok, "privileged ports below 1024 must be rejected")
	AssertEqual("http://localhost:11434", LLM_OLLAMA_BASE_URL, "a rejected port must leave the URL unchanged")
}
Test("LLM_Ollama_SetPort: rejects ports below 1024", _OllamaSetPort_RejectsLow)


_OllamaSetPort_RejectsHigh() {
	LLM_Ollama_SetPort(11434)
	AssertFalse(LLM_Ollama_SetPort(70000), "ports above 65535 must be rejected")
}
Test("LLM_Ollama_SetPort: rejects ports above 65535", _OllamaSetPort_RejectsHigh)


_OllamaSetPort_RejectsNonInteger() {
	LLM_Ollama_SetPort(11434)
	AssertFalse(LLM_Ollama_SetPort("abc"), "non-integer input must be rejected")
}
Test("LLM_Ollama_SetPort: rejects non-integer input", _OllamaSetPort_RejectsNonInteger)
