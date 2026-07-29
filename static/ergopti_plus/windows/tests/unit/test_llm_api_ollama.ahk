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
