; static/ergopti_plus/windows/tests/test_llm_api_ollama.ahk

; ==============================================================================
; MODULE: LLM API Ollama Tests
; DESCRIPTION:
; Unit-tests for the purely-logical helpers in modules/llm/api_ollama.ahk:
; LLM_BuildOllamaPayload, LLM_ParseOllamaResponse, LLM_UnescapeJSON,
; LLM_OllamaCancelAsync, LLM_OllamaCancelAllAsync, and the async-registry
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




; ====================================================
; ====================================================
; ======= 4/ Async registry — cancel helpers =========
; ====================================================
; ====================================================

_OllamaCancelAsync_FlagsEntry() {
	global _LLM_Ollama_Async
	; Inject a fake entry into the registry so we can cancel it without HTTP
	fake_id := 99901
	_LLM_Ollama_Async[fake_id] := Map("http", "", "on_success", (*) => 0, "on_fail", (*) => 0, "cancelled", false)
	LLM_OllamaCancelAsync(fake_id)
	AssertTrue(_LLM_Ollama_Async[fake_id]["cancelled"])
	_LLM_Ollama_Async.Delete(fake_id)
}
Test("LLM_OllamaCancelAsync: sets cancelled flag on in-flight entry", _OllamaCancelAsync_FlagsEntry)


_OllamaCancelAsync_NoOpOnMissingId() {
	global _LLM_Ollama_Async
	before_count := _LLM_Ollama_Async.Count
	; Must not throw when the id does not exist
	LLM_OllamaCancelAsync(999999)
	AssertEqual(before_count, _LLM_Ollama_Async.Count)
}
Test("LLM_OllamaCancelAsync: no-op when request id not found", _OllamaCancelAsync_NoOpOnMissingId)


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
