; static/ergopti_plus/windows/tests/unit/test_llm_rewrite.ahk

; ==============================================================================
; MODULE: Rewrite Request Helpers (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/llm/rewrite_vectors.json, which the shared Lua
; module (macOS, Linux) replays too, through modules/llm/rewrite.ahk: the
; sentence a rewrite prompt rewrites, its token budget, and which prompts are
; rewrite prompts. Also pins that the shipped "rewrite" built-in is a rewrite
; profile and that the other built-ins are not, since the engine decides the
; whole request shape (tail, budget, erasure) from that answer.
;
; ROOT CAUSE ENCODED:
; A rewrite prompt sent through the continuation path got a five-word tail and
; a few-word budget: the model rewrote a fragment, and the truncated answer
; could not replace the sentence the user was typing.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================
; ===================================================
; ======= 1/ Shared corpus (rewrite_vectors) ========
; ===================================================
; ===================================================

_LRW_Corpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\llm\rewrite_vectors.json"
	AssertTrue(FileExist(Path) != "", "the rewrite corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

_LRW_SentenceVectors() {
	Checked := 0
	for Vector in _LRW_Corpus()["sentence_vectors"] {
		Span := LLM_Rewrite_SentenceSpan(Vector["buffer"])
		AssertEqual(Vector["span"], Span, Vector["id"] . ": span")
		; The span is what the parser aligns and the accept erases: it must be
		; the exact end of the buffer, never a re-spaced copy of it.
		AssertEqual(Span, SubStr(Vector["buffer"], StrLen(Vector["buffer"]) - StrLen(Span) + 1),
			Vector["id"] . ": the span is an exact suffix of the buffer")
		Checked += 1
	}
	AssertTrue(Checked >= 10, "expected at least 10 sentence vectors, found " . Checked)
}
Test("LLM rewrite: the sentence span replays the shared corpus", _LRW_SentenceVectors)

_LRW_MaxTokensVectors() {
	Checked := 0
	for Vector in _LRW_Corpus()["max_tokens_vectors"] {
		AssertEqual(Vector["max_tokens"], LLM_Rewrite_MaxTokens(Vector["span"]),
			Vector["id"] . ": max_tokens")
		Checked += 1
	}
	AssertTrue(Checked >= 4, "expected at least 4 budget vectors, found " . Checked)
}
Test("LLM rewrite: the token budget replays the shared corpus", _LRW_MaxTokensVectors)

_LRW_PromptVectors() {
	Checked := 0
	for Vector in _LRW_Corpus()["prompt_vectors"] {
		AssertEqual(Vector["is_rewrite"] ? true : false,
			LLM_Rewrite_IsRewritePrompt(Vector["prompt"]) ? true : false,
			Vector["id"] . ": is_rewrite")
		Checked += 1
	}
	AssertTrue(Checked >= 4, "expected at least 4 prompt vectors, found " . Checked)
}
Test("LLM rewrite: rewrite prompt detection replays the shared corpus", _LRW_PromptVectors)





; ===========================================
; ===========================================
; ======= 2/ Driver-specific contract =======
; ===========================================
; ===========================================

; The corpus is BMP-only; a character outside it is two UTF-16 units in AHK
; but one Backspace and one codepoint in the shared count.
_LRW_CodepointsNotCodeUnits() {
	Emoji := Chr(0x1F600)
	AssertEqual(2, StrLen(Emoji), "precondition: AHK stores the emoji as a surrogate pair")
	AssertEqual(1, LLM_Rewrite_CodepointLength(Emoji), "one emoji is one codepoint")
	AssertEqual(4, LLM_Rewrite_CodepointLength("ok " . Emoji), "the count covers mixed text")
	AssertEqual(0, LLM_Rewrite_CodepointLength(""), "the empty string has no codepoint")
	AssertEqual(LLM_Rewrite_MaxTokens("a"), LLM_Rewrite_MaxTokens(Emoji),
		"the budget counts codepoints, as the shared module does")
	AssertEqual("ok " . Emoji, LLM_Rewrite_SentenceSpan("Fin. ok " . Emoji),
		"a surrogate pair never splits the span")
}
Test("LLM rewrite: lengths are codepoints, not UTF-16 units", _LRW_CodepointsNotCodeUnits)

_LRW_SpanRejectsNonString() {
	AssertThrows(() => LLM_Rewrite_SentenceSpan(0),
		"a buffer that is not a string is a caller bug, not an empty sentence")
}
Test("LLM rewrite: the span refuses a non-string buffer", _LRW_SpanRejectsNonString)

_LRW_ShippedProfiles() {
	global LLM_PROFILE_BUILTIN_ORDER
	AssertTrue(LLM_Rewrite_IsRewriteProfile(LLM_FindProfile("rewrite")),
		"the shipped rewrite built-in must be recognised as a rewrite profile")
	Checked := 0
	for Id in LLM_PROFILE_BUILTIN_ORDER {
		Profile := LLM_FindProfile(Id)
		AssertTrue(Profile is Map, "every built-in in the menu order must exist in profiles.json: " . Id)
		; The tone ladder profiles are rewrites too: they rewrite a selection; so
		; are the live translations, which rewrite the sentence being typed
		IsRewrite := (Id == "rewrite" || SubStr(Id, 1, 5) == "tone_"
			|| SubStr(Id, 1, 10) == "translate_")
		AssertEqual(IsRewrite, LLM_Rewrite_IsRewriteProfile(Profile) ? true : false,
			"the built-in '" . Id . "' is " . (IsRewrite ? "a rewrite" : "a continuation"))
		Checked += 1
	}
	AssertEqual(11, Checked,
		"the eleven built-ins, rewrite, the tone ladder and the translations included, must be checked")
	AssertTrue(LLM_Rewrite_IsRewriteProfile(Map("id", "user_x", "raw_prompt", "Reply REWRITE: <t>")),
		"a custom prompt cloned from the rewrite one is a rewrite prompt through its raw prompt too")
	AssertFalse(LLM_Rewrite_IsRewriteProfile(""), "no profile is no rewrite")
}
Test("LLM rewrite: the shipped built-ins are classified from their prompts", _LRW_ShippedProfiles)
