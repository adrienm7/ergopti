; static/ergopti_plus/windows/tests/unit/test_remote_parse_first_content_match.ahk

; ==============================================================================
; MODULE: LLM Remote Parser Multi-Block Regression Tests
; DESCRIPTION:
; Behavioral regression for finding remote-parse-first-content-match.
;
; _LLMRemoteParseResponse used to extract the FIRST "content"/"text" string it
; found via a first-match regex. On a multi-block response (an Anthropic
; ``thinking`` block before the ``text`` block, or an OpenRouter ``reasoning``
; field before ``choices``) that grabbed the wrong text — the tooltip showed
; the chain-of-thought fragment instead of the actual completion.
;
; The fix navigates the canonical JSON path per format with JsonParse
; (anthropic: first content[] block with type=="text"; openai:
; choices[1].message.content; gemini: candidates[1].content.parts[].text) and
; only falls back to the legacy regex when the structured path misses. These
; tests feed adversarial bodies whose FIRST matching string is a decoy and
; assert the real answer is returned.
;
; api_remote.ahk is #Included by run_all.ahk (it is pure logic with no network
; side effects at parse time), so this is a behavioral headless-unit test that
; calls _LLMRemoteParseResponse directly.
; ==============================================================================




; ===============================================================
; ===============================================================
; ======= 1/ Anthropic thinking-then-text ordering ==============
; ===============================================================
; ===============================================================

; Anthropic with a leading thinking block: the first "text" string in the body
; is the chain-of-thought; the answer is the second content[] block (type text).
; First-match regex returned the thinking text; structured nav returns the answer.
_RPFCM_Anthropic_SkipsThinkingBlock() {
	body := '{"content":[{"type":"thinking","text":"Let me reason about this"},{"type":"text","text":"the answer"}]}'
	result := _LLMRemoteParseResponse("anthropic", body)
	AssertEqual("the answer", result,
		"anthropic parser must return the text block, not the leading thinking block (remote-parse-first-content-match)")
}
Test("_LLMRemoteParseResponse: anthropic skips leading thinking block (remote-parse-first-content-match)", _RPFCM_Anthropic_SkipsThinkingBlock)


; Sanity: a plain single text block still resolves (no regression on the common case).
_RPFCM_Anthropic_PlainTextBlock() {
	body := '{"content":[{"type":"text","text":"hello world"}]}'
	result := _LLMRemoteParseResponse("anthropic", body)
	AssertEqual("hello world", result,
		"anthropic parser must still extract a plain single text block")
}
Test("_LLMRemoteParseResponse: anthropic plain text block still resolves (remote-parse-first-content-match)", _RPFCM_Anthropic_PlainTextBlock)




; ===============================================================
; ===============================================================
; ======= 2/ OpenAI decoy field before choices ==================
; ===============================================================
; ===============================================================

; OpenAI / OpenRouter body carrying a decoy "content"-like field (a reasoning
; trace serialised before the real choices array). First-match regex grabbed the
; decoy; structured nav walks choices[1].message.content and returns the answer.
_RPFCM_OpenAI_SkipsReasoningDecoy() {
	body := '{"reasoning":{"content":"thinking out loud"},"choices":[{"message":{"role":"assistant","content":"final answer"}}]}'
	result := _LLMRemoteParseResponse("openai", body)
	AssertEqual("final answer", result,
		"openai parser must navigate choices[1].message.content, not the leading reasoning decoy (remote-parse-first-content-match)")
}
Test("_LLMRemoteParseResponse: openai skips leading reasoning content decoy (remote-parse-first-content-match)", _RPFCM_OpenAI_SkipsReasoningDecoy)


; Sanity: the canonical single-choice body still resolves after the rewrite.
_RPFCM_OpenAI_CanonicalChoice() {
	body := '{"choices":[{"message":{"role":"assistant","content":"Hello there"}}]}'
	result := _LLMRemoteParseResponse("openai", body)
	AssertEqual("Hello there", result,
		"openai parser must still extract the canonical choices[1].message.content")
}
Test("_LLMRemoteParseResponse: openai canonical choice still resolves (remote-parse-first-content-match)", _RPFCM_OpenAI_CanonicalChoice)




; ===============================================================
; ===============================================================
; ======= 3/ Gemini multi-part + malformed fallback =============
; ===============================================================
; ===============================================================

; Gemini: the first text part of the first candidate is the answer — the
; cross-driver corpus contract (gemini_multipart_uses_first) takes the FIRST
; part, consistent with the first-match policy this whole file verifies for the
; anthropic/openai navigators. A later part is a continuation/decoy, not a
; fragment to concatenate.
_RPFCM_Gemini_UsesFirstPart() {
	body := '{"candidates":[{"content":{"parts":[{"text":"foo"},{"text":"bar"}]}}]}'
	result := _LLMRemoteParseResponse("gemini", body)
	AssertEqual("foo", result,
		"gemini parser must return the FIRST text part of the first candidate (remote-parse-first-content-match)")
}
Test("_LLMRemoteParseResponse: gemini uses the first text part (remote-parse-first-content-match)", _RPFCM_Gemini_UsesFirstPart)


; Malformed body (HTTP error page) must still return "" via the regex fallback,
; never throw — the caller treats "" as a clean network failure.
_RPFCM_MalformedBodyReturnsEmpty() {
	result := _LLMRemoteParseResponse("openai", "<html>502 Bad Gateway</html>")
	AssertEqual("", result,
		"a non-JSON error body must parse to empty string, not throw")
}
Test("_LLMRemoteParseResponse: malformed body returns empty (remote-parse-first-content-match)", _RPFCM_MalformedBodyReturnsEmpty)

_RPFCM_RecognizedEmptyNeverPromotesDecoy() {
	Vectors := [
		["openai", '{"reasoning":{"content":"secret"},"choices":[{"message":{"content":""}}]}'],
		["anthropic", '{"content":[{"type":"thinking","text":"secret"},{"type":"text","text":""}]}'],
		["gemini", '{"metadata":{"text":"secret"},"candidates":[{"content":{"parts":[{"text":""}]}}]}']
	]
	for Vector in Vectors
		AssertEqual("", _LLMRemoteParseResponse(Vector[1], Vector[2]),
			Vector[1] . " recognized-empty canonical output must not promote a decoy")
}
Test("_LLMRemoteParseResponse: recognized empty output suppresses compatibility fallback", _RPFCM_RecognizedEmptyNeverPromotesDecoy)

_RPFCM_CompleteFieldInsideMalformedEnvelopeIsRejected() {
	Vectors := [
		["openai", '{"choices":[{"message":{"content":"wrong partial output"}}]'],
		["anthropic", '{"content":[{"type":"text","text":"wrong partial output"}]'],
		["gemini", '{"candidates":[{"content":{"parts":[{"text":"wrong partial output"}]}}]']
	]
	for Vector in Vectors
		AssertEqual("", _LLMRemoteParseResponse(Vector[1], Vector[2]),
			Vector[1] . " malformed envelope must never regex-recover a complete field")
}
Test("_LLMRemoteParseResponse: malformed complete-field envelopes are terminal failures", _RPFCM_CompleteFieldInsideMalformedEnvelopeIsRejected)
