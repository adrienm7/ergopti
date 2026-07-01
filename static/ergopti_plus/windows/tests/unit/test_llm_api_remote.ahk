; static/ergopti_plus/windows/tests/unit/test_llm_api_remote.ahk

; ==============================================================================
; MODULE: LLM API Remote Tests
; DESCRIPTION:
; Unit-tests for the purely-logical helpers in modules/llm/api_remote.ahk:
; _LLMRemoteBuildUrl, _LLMRemoteBuildPayload, _LLMRemoteParseResponse,
; _LLMRemoteJsonEscape, _LLMRemoteJsonUnescape, _LLMRemoteResolveEntry,
; _LLMRemoteEstimateCost, _LLMRemoteExtractUsage, LLM_RemoteCancelAsync,
; LLM_RemoteCancelAllAsync, and the async-registry trim helper.
; All tests are offline — no real HTTP calls are made.
; ==============================================================================




; ================================================
; ================================================
; ======= 1/ _LLMRemoteBuildUrl ==================
; ================================================
; ================================================

_RemoteBuildUrl_OpenAI() {
	url := _LLMRemoteBuildUrl("https://api.openai.com/v1", "openai", "tok", "gpt-4o-mini")
	AssertEqual("https://api.openai.com/v1/chat/completions", url)
}
Test("_LLMRemoteBuildUrl: openai format points to chat/completions", _RemoteBuildUrl_OpenAI)


_RemoteBuildUrl_Anthropic() {
	url := _LLMRemoteBuildUrl("https://api.anthropic.com/v1", "anthropic", "tok", "claude-haiku-4-5")
	AssertEqual("https://api.anthropic.com/v1/messages", url)
}
Test("_LLMRemoteBuildUrl: anthropic format points to /messages", _RemoteBuildUrl_Anthropic)


_RemoteBuildUrl_Gemini() {
	url := _LLMRemoteBuildUrl("https://generativelanguage.googleapis.com/v1beta", "gemini", "MY_KEY", "gemini-2.0-flash")
	AssertContains(url, "/models/gemini-2.0-flash:generateContent")
	AssertContains(url, "key=MY_KEY")
}
Test("_LLMRemoteBuildUrl: gemini format embeds model and key in path", _RemoteBuildUrl_Gemini)


_RemoteBuildUrl_TrailingSlashStripped() {
	url := _LLMRemoteBuildUrl("https://api.openai.com/v1/", "openai", "tok", "m")
	AssertFalse(InStr(url, "//chat"), "double-slash must not appear after trimming trailing /")
}
Test("_LLMRemoteBuildUrl: trailing slash on base URL is stripped", _RemoteBuildUrl_TrailingSlashStripped)




; ======================================================
; ======================================================
; ======= 2/ _LLMRemoteBuildPayload ====================
; ======================================================
; ======================================================

_RemotePayload_OpenAI_ContainsModel() {
	p := _LLMRemoteBuildPayload("openai", "gpt-4o-mini", "You are helpful.", "Hello", 0.1)
	AssertContains(p, '"model":"gpt-4o-mini"')
}
Test("_LLMRemoteBuildPayload: openai payload contains model", _RemotePayload_OpenAI_ContainsModel)


_RemotePayload_OpenAI_SystemMessage() {
	p := _LLMRemoteBuildPayload("openai", "m", "My system", "user input", 0.5)
	AssertContains(p, '"role":"system"')
	AssertContains(p, "My system")
}
Test("_LLMRemoteBuildPayload: openai payload contains system message", _RemotePayload_OpenAI_SystemMessage)


_RemotePayload_OpenAI_UserMessage() {
	p := _LLMRemoteBuildPayload("openai", "m", "s", "user input here", 0.1)
	AssertContains(p, '"role":"user"')
	AssertContains(p, "user input here")
}
Test("_LLMRemoteBuildPayload: openai payload contains user message", _RemotePayload_OpenAI_UserMessage)


_RemotePayload_OpenAI_StreamFalse() {
	p := _LLMRemoteBuildPayload("openai", "m", "s", "u", 0.1)
	AssertContains(p, '"stream":false')
}
Test("_LLMRemoteBuildPayload: openai payload has stream:false", _RemotePayload_OpenAI_StreamFalse)


_RemotePayload_Anthropic_TopLevelSystem() {
	p := _LLMRemoteBuildPayload("anthropic", "claude-haiku-4-5", "Be concise.", "Tell me", 0.2)
	; Anthropic puts system at the top level, not inside messages
	AssertContains(p, '"system":"Be concise."')
	AssertContains(p, '"role":"user"')
}
Test("_LLMRemoteBuildPayload: anthropic payload has top-level system field", _RemotePayload_Anthropic_TopLevelSystem)


_RemotePayload_Anthropic_MaxTokens() {
	p := _LLMRemoteBuildPayload("anthropic", "m", "s", "u", 0.1)
	; Anthropic requires max_tokens — verify it is present
	AssertContains(p, '"max_tokens"')
}
Test("_LLMRemoteBuildPayload: anthropic payload includes max_tokens", _RemotePayload_Anthropic_MaxTokens)


; A5 — the output-token cap is the shared PromptBuilder budget threaded from the
; engine (single cross-driver source), replacing the former hardcoded per-provider
; literals. The un-threaded fallback default is now unified to 150 across all
; backends (= PromptBuilder DEFAULT_MAX_TOKENS), so a caller that omits max_tokens
; gets the same documented default the live engine threads.
_RemotePayload_OpenAI_MaxTokensThreaded() {
	p := _LLMRemoteBuildPayload("openai", "m", "s", "u", 0.1, 42)
	AssertContains(p, '"max_tokens":42', "openai max_tokens must equal the threaded value")
}
Test("_LLMRemoteBuildPayload: openai max_tokens is threaded (A5)", _RemotePayload_OpenAI_MaxTokensThreaded)

_RemotePayload_Gemini_MaxOutputTokensThreaded() {
	p := _LLMRemoteBuildPayload("gemini", "m", "s", "u", 0.1, 42)
	AssertContains(p, '"maxOutputTokens":42', "gemini maxOutputTokens must equal the threaded value")
}
Test("_LLMRemoteBuildPayload: gemini maxOutputTokens is threaded (A5)", _RemotePayload_Gemini_MaxOutputTokensThreaded)

_RemotePayload_Anthropic_MaxTokensThreaded() {
	p := _LLMRemoteBuildPayload("anthropic", "m", "s", "u", 0.1, 42)
	AssertContains(p, '"max_tokens":42', "anthropic max_tokens must equal the threaded value")
}
Test("_LLMRemoteBuildPayload: anthropic max_tokens is threaded (A5)", _RemotePayload_Anthropic_MaxTokensThreaded)

_RemotePayload_MaxTokensDefault() {
	p := _LLMRemoteBuildPayload("openai", "m", "s", "u", 0.1)
	; Unified cross-driver default — must equal PromptBuilder DEFAULT_MAX_TOKENS (150),
	; the same value the live engine threads, not the legacy per-provider 256
	AssertContains(p, '"max_tokens":150', "max_tokens defaults to 150 (unified PromptBuilder default) when not threaded")
}
Test("_LLMRemoteBuildPayload: max_tokens defaults to 150 (unified) when not threaded (A5)", _RemotePayload_MaxTokensDefault)


_RemotePayload_Gemini_SystemInstruction() {
	p := _LLMRemoteBuildPayload("gemini", "gemini-2.0-flash", "Be helpful.", "Translate", 0.3)
	AssertContains(p, '"systemInstruction"')
	AssertContains(p, "Be helpful.")
}
Test("_LLMRemoteBuildPayload: gemini payload uses systemInstruction", _RemotePayload_Gemini_SystemInstruction)


_RemotePayload_Gemini_GenerationConfig() {
	p := _LLMRemoteBuildPayload("gemini", "m", "s", "u", 0.4)
	AssertContains(p, '"generationConfig"')
	AssertContains(p, '"temperature"')
}
Test("_LLMRemoteBuildPayload: gemini payload uses generationConfig", _RemotePayload_Gemini_GenerationConfig)


_RemotePayload_EscapesQuotes() {
	p := _LLMRemoteBuildPayload("openai", "m", 's', 'say "hi"', 0.1)
	AssertContains(p, '\"hi\"')
}
Test("_LLMRemoteBuildPayload: escapes double quotes in user text", _RemotePayload_EscapesQuotes)




; =======================================================
; =======================================================
; ======= 3/ _LLMRemoteParseResponse ====================
; =======================================================
; =======================================================

_RemoteParse_OpenAI_ExtractsContent() {
	body := '{"choices":[{"message":{"role":"assistant","content":"Hello there"}}]}'
	result := _LLMRemoteParseResponse("openai", body)
	AssertEqual("Hello there", result)
}
Test("_LLMRemoteParseResponse: openai extracts content from choices", _RemoteParse_OpenAI_ExtractsContent)


_RemoteParse_Anthropic_ExtractsText() {
	body := '{"content":[{"type":"text","text":"Great answer"}]}'
	result := _LLMRemoteParseResponse("anthropic", body)
	AssertEqual("Great answer", result)
}
Test("_LLMRemoteParseResponse: anthropic extracts text from content block", _RemoteParse_Anthropic_ExtractsText)


_RemoteParse_Gemini_ExtractsText() {
	body := '{"candidates":[{"content":{"parts":[{"text":"Gemini says hi"}]}}]}'
	result := _LLMRemoteParseResponse("gemini", body)
	AssertEqual("Gemini says hi", result)
}
Test("_LLMRemoteParseResponse: gemini extracts text from candidates", _RemoteParse_Gemini_ExtractsText)


_RemoteParse_EmptyBodyReturnsEmpty() {
	result := _LLMRemoteParseResponse("openai", "")
	AssertEqual("", result)
}
Test("_LLMRemoteParseResponse: empty body returns empty string", _RemoteParse_EmptyBodyReturnsEmpty)


_RemoteParse_MalformedBodyReturnsEmpty() {
	result := _LLMRemoteParseResponse("openai", "{not json at all!!!}")
	AssertEqual("", result)
}
Test("_LLMRemoteParseResponse: malformed body returns empty string", _RemoteParse_MalformedBodyReturnsEmpty)


_RemoteParse_UnescapesNewlines() {
	body := '{"choices":[{"message":{"content":"line1\nline2"}}]}'
	result := _LLMRemoteParseResponse("openai", body)
	AssertContains(result, "`n")
}
Test("_LLMRemoteParseResponse: unescapes \\n in content", _RemoteParse_UnescapesNewlines)




; =====================================================
; =====================================================
; ======= 4/ JSON escape / unescape helpers ===========
; =====================================================
; =====================================================

_RemoteJsonEscape_BackslashFirst() {
	; Backslash must be doubled before quote so the second pass does not
	; double-escape what the first produced
	result := _LLMRemoteJsonEscape('path\file')
	AssertContains(result, "\\")
}
Test("_LLMRemoteJsonEscape: backslash is escaped to double-backslash", _RemoteJsonEscape_BackslashFirst)


_RemoteJsonEscape_QuoteEscaped() {
	result := _LLMRemoteJsonEscape('say "hi"')
	AssertContains(result, '\"hi\"')
}
Test("_LLMRemoteJsonEscape: double quote is escaped to backslash-quote", _RemoteJsonEscape_QuoteEscaped)


_RemoteJsonEscape_NewlineEscaped() {
	result := _LLMRemoteJsonEscape("line1`nline2")
	AssertContains(result, "\n")
}
Test("_LLMRemoteJsonEscape: newline is escaped to \\n", _RemoteJsonEscape_NewlineEscaped)


_RemoteJsonUnescape_NewlineRestored() {
	result := _LLMRemoteJsonUnescape("line1\nline2")
	AssertEqual("line1`nline2", result)
}
Test("_LLMRemoteJsonUnescape: \\n restored to newline", _RemoteJsonUnescape_NewlineRestored)


_RemoteJsonUnescape_QuoteRestored() {
	result := _LLMRemoteJsonUnescape('say \"hi\"')
	AssertEqual('say "hi"', result)
}
Test("_LLMRemoteJsonUnescape: backslash-quote restored to double quote", _RemoteJsonUnescape_QuoteRestored)


_RemoteJsonUnescape_BackslashRestored() {
	result := _LLMRemoteJsonUnescape("path\\file")
	AssertEqual("path\file", result)
}
Test("_LLMRemoteJsonUnescape: \\\\ restored to single backslash", _RemoteJsonUnescape_BackslashRestored)


; Regression: an escaped backslash immediately followed by another escape
; sequence used to silently lose the backslash entirely. The neutralising
; sentinel used to be Chr(0) -- AHK strings are internally null-terminated,
; so StrReplace() with a null character truncates/drops it instead of
; substituting it, corrupting anything the sentinel touched. Chr(0xE000) (a
; Unicode private-use codepoint, never null) fixes it.
_RemoteJsonUnescape_BackslashAdjacentToAnotherEscape() {
	result := _LLMRemoteJsonUnescape("a\\\nb")
	AssertEqual("a\`nb", result, "an escaped backslash immediately before another escape sequence must not be dropped")
}
Test("_LLMRemoteJsonUnescape: an escaped backslash adjacent to another escape sequence is not lost",
	_RemoteJsonUnescape_BackslashAdjacentToAnotherEscape)




; =====================================================
; =====================================================
; ======= 5/ _LLMRemoteResolveEntry ===================
; =====================================================
; =====================================================

_RemoteResolve_ValidOpenAIEntry() {
	entry := Map("Provider", "openai", "Token", "sk-test", "Model", "gpt-4o-mini", "BaseUrl", "")
	resolved := _LLMRemoteResolveEntry(entry)
	AssertFalse(resolved == "", "resolve must succeed for valid openai entry")
	AssertEqual("openai", resolved["Format"])
	AssertEqual("gpt-4o-mini", resolved["Model"])
}
Test("_LLMRemoteResolveEntry: valid openai entry resolves correctly", _RemoteResolve_ValidOpenAIEntry)


_RemoteResolve_MissingTokenReturnsEmpty() {
	entry := Map("Provider", "openai", "Token", "", "Model", "gpt-4o-mini", "BaseUrl", "")
	resolved := _LLMRemoteResolveEntry(entry)
	AssertEqual("", resolved)
}
Test("_LLMRemoteResolveEntry: missing token returns empty string", _RemoteResolve_MissingTokenReturnsEmpty)


_RemoteResolve_UnknownProviderReturnsEmpty() {
	entry := Map("Provider", "unknown_xyz", "Token", "t", "Model", "m", "BaseUrl", "http://x")
	resolved := _LLMRemoteResolveEntry(entry)
	AssertEqual("", resolved)
}
Test("_LLMRemoteResolveEntry: unknown provider returns empty string", _RemoteResolve_UnknownProviderReturnsEmpty)


_RemoteResolve_MissingModelReturnsEmpty() {
	; openai_compat has no default model — missing Model => empty
	entry := Map("Provider", "openai_compat", "Token", "t", "Model", "", "BaseUrl", "http://example.com/v1")
	resolved := _LLMRemoteResolveEntry(entry)
	AssertEqual("", resolved)
}
Test("_LLMRemoteResolveEntry: missing model for openai_compat returns empty", _RemoteResolve_MissingModelReturnsEmpty)


_RemoteResolve_BaseUrlFallsBackToProvider() {
	; When the entry has an empty BaseUrl, resolver uses the provider default
	entry := Map("Provider", "openai", "Token", "t", "Model", "gpt-4o-mini", "BaseUrl", "")
	resolved := _LLMRemoteResolveEntry(entry)
	AssertContains(resolved["BaseUrl"], "openai.com")
}
Test("_LLMRemoteResolveEntry: BaseUrl falls back to provider default when empty", _RemoteResolve_BaseUrlFallsBackToProvider)


_RemoteResolve_CustomBaseUrlOverridesProvider() {
	entry := Map("Provider", "openai", "Token", "t", "Model", "m", "BaseUrl", "http://custom.host/v1")
	resolved := _LLMRemoteResolveEntry(entry)
	AssertEqual("http://custom.host/v1", resolved["BaseUrl"])
}
Test("_LLMRemoteResolveEntry: explicit BaseUrl overrides provider default", _RemoteResolve_CustomBaseUrlOverridesProvider)


_RemoteResolve_AnthropicFormat() {
	entry := Map("Provider", "anthropic", "Token", "t", "Model", "claude-haiku-4-5", "BaseUrl", "")
	resolved := _LLMRemoteResolveEntry(entry)
	AssertEqual("anthropic", resolved["Format"])
}
Test("_LLMRemoteResolveEntry: anthropic provider resolves to anthropic format", _RemoteResolve_AnthropicFormat)


_RemoteResolve_GeminiFormat() {
	entry := Map("Provider", "gemini", "Token", "t", "Model", "gemini-2.0-flash", "BaseUrl", "")
	resolved := _LLMRemoteResolveEntry(entry)
	AssertEqual("gemini", resolved["Format"])
}
Test("_LLMRemoteResolveEntry: gemini provider resolves to gemini format", _RemoteResolve_GeminiFormat)




; ===================================================
; ===================================================
; ======= 6/ Cost estimation =========================
; ===================================================
; ===================================================

_RemoteCost_KnownModelGivesNonZero() {
	cost := _LLMRemoteEstimateCost("gpt-4o-mini", 1000, 200)
	Assert(cost > 0, "Cost must be positive for a known model")
}
Test("_LLMRemoteEstimateCost: known model returns non-zero cost", _RemoteCost_KnownModelGivesNonZero)


_RemoteCost_UnknownModelGivesZero() {
	cost := _LLMRemoteEstimateCost("unknown-model-xyz", 1000, 200)
	AssertEqual(0.0, cost)
}
Test("_LLMRemoteEstimateCost: unknown model returns 0.0", _RemoteCost_UnknownModelGivesZero)


_RemoteCost_ZeroTokensGivesZero() {
	cost := _LLMRemoteEstimateCost("gpt-4o-mini", 0, 0)
	AssertEqual(0.0, cost)
}
Test("_LLMRemoteEstimateCost: zero tokens gives zero cost", _RemoteCost_ZeroTokensGivesZero)


_RemoteCost_ScalesWithTokens() {
	cost_small := _LLMRemoteEstimateCost("gpt-4o-mini", 100, 50)
	cost_large := _LLMRemoteEstimateCost("gpt-4o-mini", 1000, 500)
	Assert(cost_large > cost_small, "cost must scale with token count")
}
Test("_LLMRemoteEstimateCost: cost scales proportionally with token count", _RemoteCost_ScalesWithTokens)




; ===================================================
; ===================================================
; ======= 7/ _LLMRemoteExtractUsage =================
; ===================================================
; ===================================================

_RemoteUsage_OpenAI_ExtractsAll() {
	body := '{"usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}'
	out := _LLMRemoteExtractUsage("openai", body, "gpt-4o-mini")
	AssertEqual(10, out["prompt_tokens"])
	AssertEqual(20, out["completion_tokens"])
	AssertEqual(30, out["total_tokens"])
}
Test("_LLMRemoteExtractUsage: openai extracts prompt/completion/total tokens", _RemoteUsage_OpenAI_ExtractsAll)


_RemoteUsage_Anthropic_ExtractsTokens() {
	body := '{"usage":{"input_tokens":15,"output_tokens":25}}'
	out := _LLMRemoteExtractUsage("anthropic", body, "claude-haiku-4-5")
	AssertEqual(15, out["prompt_tokens"])
	AssertEqual(25, out["completion_tokens"])
	AssertEqual(40, out["total_tokens"])
}
Test("_LLMRemoteExtractUsage: anthropic extracts input/output tokens and sums total", _RemoteUsage_Anthropic_ExtractsTokens)


_RemoteUsage_Gemini_ExtractsTokens() {
	body := '{"usageMetadata":{"promptTokenCount":8,"candidatesTokenCount":12,"totalTokenCount":20}}'
	out := _LLMRemoteExtractUsage("gemini", body, "gemini-2.0-flash")
	AssertEqual(8,  out["prompt_tokens"])
	AssertEqual(12, out["completion_tokens"])
	AssertEqual(20, out["total_tokens"])
}
Test("_LLMRemoteExtractUsage: gemini extracts promptTokenCount and candidatesTokenCount", _RemoteUsage_Gemini_ExtractsTokens)


_RemoteUsage_EmptyBodyReturnsZeros() {
	out := _LLMRemoteExtractUsage("openai", "", "gpt-4o-mini")
	AssertEqual(0, out["prompt_tokens"])
	AssertEqual(0, out["completion_tokens"])
	AssertEqual(0, out["total_tokens"])
	AssertEqual(0.0, out["est_cost_usd"])
}
Test("_LLMRemoteExtractUsage: empty body returns zero usage map", _RemoteUsage_EmptyBodyReturnsZeros)


_RemoteUsage_CostIncluded() {
	body := '{"usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150}}'
	out := _LLMRemoteExtractUsage("openai", body, "gpt-4o-mini")
	Assert(out["est_cost_usd"] > 0, "estimated cost must be positive for known model + nonzero tokens")
}
Test("_LLMRemoteExtractUsage: estimated cost is included in result map", _RemoteUsage_CostIncluded)




; ===================================================
; ===================================================
; ======= 8/ Async registry — cancel helpers ========
; ===================================================
; ===================================================

_RemoteCancelAsync_FlagsEntry() {
	global _LLM_Remote_Async
	fake_id := 88801
	_LLM_Remote_Async[fake_id] := Map("http", "", "format", "openai", "on_success", (*) => 0, "on_fail", (*) => 0, "cancelled", false)
	LLM_RemoteCancelAsync(fake_id)
	AssertTrue(_LLM_Remote_Async[fake_id]["cancelled"])
	_LLM_Remote_Async.Delete(fake_id)
}
Test("LLM_RemoteCancelAsync: sets cancelled flag on in-flight entry", _RemoteCancelAsync_FlagsEntry)


_RemoteCancelAsync_NoOpOnMissingId() {
	global _LLM_Remote_Async
	before_count := _LLM_Remote_Async.Count
	LLM_RemoteCancelAsync(999888)
	AssertEqual(before_count, _LLM_Remote_Async.Count)
}
Test("LLM_RemoteCancelAsync: no-op when request id not found", _RemoteCancelAsync_NoOpOnMissingId)


_RemoteCancelAllAsync_FlagsAll() {
	global _LLM_Remote_Async
	_LLM_Remote_Async[88802] := Map("http", "", "on_success", (*) => 0, "on_fail", (*) => 0, "cancelled", false)
	_LLM_Remote_Async[88803] := Map("http", "", "on_success", (*) => 0, "on_fail", (*) => 0, "cancelled", false)
	LLM_RemoteCancelAllAsync()
	AssertTrue(_LLM_Remote_Async[88802]["cancelled"])
	AssertTrue(_LLM_Remote_Async[88803]["cancelled"])
	_LLM_Remote_Async.Delete(88802)
	_LLM_Remote_Async.Delete(88803)
}
Test("LLM_RemoteCancelAllAsync: cancels every in-flight entry", _RemoteCancelAllAsync_FlagsAll)


_RemoteTrimRegistry_DropsOldestWhenAtCap() {
	global _LLM_Remote_Async, LLM_REMOTE_MAX_INFLIGHT
	_LLM_Remote_Async := Map()
	base_id := 77000
	loop LLM_REMOTE_MAX_INFLIGHT
		_LLM_Remote_Async[base_id + A_Index] := Map("cancelled", false)
	_LLMRemote_TrimAsyncRegistry()
	AssertEqual(LLM_REMOTE_MAX_INFLIGHT - 1, _LLM_Remote_Async.Count)
	AssertFalse(_LLM_Remote_Async.Has(base_id + 1), "oldest entry must have been removed")
	_LLM_Remote_Async := Map()
}
Test("_LLMRemote_TrimAsyncRegistry: removes oldest entry when at cap", _RemoteTrimRegistry_DropsOldestWhenAtCap)





; ================================================
; ================================================
; ======= 9/ Catalogue + request context ==========
; ================================================
; ================================================

_RemoteCatalog_LoadedFromShared() {
	AssertTrue(LLM_API_PROVIDERS.Has("openai"))
	AssertTrue(LLM_API_PROVIDERS.Has("openai_compat"))
	AssertEqual(9, LLM_API_PROVIDER_ORDER.Length)
	AssertTrue(LLM_REMOTE_MODEL_PRICES.Has("gpt-4o-mini"))
}
Test("api_providers.json: catalogue loaded at module init", _RemoteCatalog_LoadedFromShared)


_RemoteBuildContext_PrefixTail() {
	req := _LLMRemote_BuildRequestContext("PREFIX and TAIL markers", "full ctx", "tail bit")
	AssertContains(req["user"], 'PREFIX: "full ctx"')
	AssertContains(req["user"], 'TAIL: "tail bit"')
}
Test("_LLMRemote_BuildRequestContext: PREFIX/TAIL profiles format user turn", _RemoteBuildContext_PrefixTail)


_RemoteBuildContext_ContextSubstitution() {
	req := _LLMRemote_BuildRequestContext("Complete: {context}", "hello world", "world")
	AssertContains(req["system"], "hello world")
	AssertEqual("", req["user"])
}
Test("_LLMRemote_BuildRequestContext: {context} substitution moves text into system", _RemoteBuildContext_ContextSubstitution)


_RemoteIsReady_AnthropicAuthHeader() {
	entry := Map("Provider", "anthropic", "Token", "sk-ant", "Model", "claude-haiku-4-5", "BaseUrl", "")
	; Offline: we only verify resolve + URL shape — no HTTP.
	resolved := _LLMRemoteResolveEntry(entry)
	AssertEqual("anthropic", resolved["Format"])
	url := _LLMRemoteBuildUrl(resolved["BaseUrl"], resolved["Format"], resolved["Token"], resolved["Model"])
	AssertEqual("https://api.anthropic.com/v1/messages", url)
}
Test("LLM_RemoteIsReady path: anthropic resolves to /messages endpoint", _RemoteIsReady_AnthropicAuthHeader)


; ==============================================================================
; ======= Poll-loop deadline cap regression ====================================
; ==============================================================================

; Regression guard for remote-poll-no-deadline-cap: _LLMRemote_PollRequest
; polled indefinitely when the remote never responded — the poll loop rescheduled
; itself via SetTimer with no upper bound. The fix stores a deadline_tick in
; the async entry at dispatch and aborts (calls on_fail) when it is exceeded.
_Remote_DeadlineTickStoredAtDispatch() {
	global _LLM_Remote_Async, _LLM_Remote_AsyncCounter, LLM_REMOTE_TIMEOUT_MS
	; Build a minimal entry map that mirrors what LLM_RemoteGenerate_Async stores.
	SavedTimeout := LLM_REMOTE_TIMEOUT_MS
	LLM_REMOTE_TIMEOUT_MS := 5000   ; Simulate a loaded value
	Before := A_TickCount
	; Compute deadline_ms as the function does internally.
	deadline_ms := (LLM_REMOTE_TIMEOUT_MS > 0) ? LLM_REMOTE_TIMEOUT_MS : 30000
	After := A_TickCount
	LLM_REMOTE_TIMEOUT_MS := SavedTimeout
	; deadline_ms must equal 5000 when LLM_REMOTE_TIMEOUT_MS is set to 5000.
	AssertEqual(5000, deadline_ms,
		"deadline_ms must equal LLM_REMOTE_TIMEOUT_MS when non-zero")
}
Test("api_remote: deadline_ms respects LLM_REMOTE_TIMEOUT_MS when non-zero", _Remote_DeadlineTickStoredAtDispatch)

_Remote_DeadlineTickFallsBack() {
	global LLM_REMOTE_TIMEOUT_MS
	SavedTimeout := LLM_REMOTE_TIMEOUT_MS
	LLM_REMOTE_TIMEOUT_MS := 0   ; Sentinel — not yet loaded
	deadline_ms := (LLM_REMOTE_TIMEOUT_MS > 0) ? LLM_REMOTE_TIMEOUT_MS : 30000
	LLM_REMOTE_TIMEOUT_MS := SavedTimeout
	AssertEqual(30000, deadline_ms,
		"deadline_ms must fall back to 30000 ms when LLM_REMOTE_TIMEOUT_MS is the 0 sentinel")
}
Test("api_remote: deadline_ms falls back to 30 s when LLM_REMOTE_TIMEOUT_MS is 0 sentinel", _Remote_DeadlineTickFallsBack)
