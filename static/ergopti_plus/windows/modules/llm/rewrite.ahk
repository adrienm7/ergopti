; modules/llm/rewrite.ahk

; ==============================================================================
; MODULE: Rewrite Request Helpers (AHK)
; DESCRIPTION:
; AutoHotkey port of _shared/lua/llm/rewrite.lua. A "rewrite" prompt asks the
; model to rewrite the sentence being typed (expand abbreviations, fix spelling,
; punctuation and typography) instead of predicting the next words.
;
; FEATURES & RATIONALE:
; 1. A rewrite prompt is recognised by its output tag ("REWRITE:"), the same
;    prompt-sniffing convention as PREFIX/TAIL and TAIL_CORRECTED, so a custom
;    prompt cloned from the built-in rewrite profile behaves as one too.
; 2. The rewritten span is the current sentence: the buffer suffix after the
;    last sentence terminator followed by spacing, or after the last line
;    break. A sentence just finished ("… jeudi.") is still the current one.
; 3. The span is an exact suffix of the buffer, so the parser aligns the
;    rewrite against it and the accept step erases exactly what it replaces.
; 4. The token budget grows with the span: the continuation budget (a few
;    words) would truncate a rewritten sentence it has already erased.
;
; Every terminator and spacing character is in the BMP, so scanning UTF-16
; code units finds the same boundaries as the Lua codepoint scan: a surrogate
; unit can never be mistaken for one. Lengths that reach the user (the token
; budget, the Backspace count) are counted in codepoints, like the Lua module.
;
; Pinned with the Lua module by _shared/tests/corpus/llm/rewrite_vectors.json.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Module Constants =========
; =====================================
; =====================================

; Output tag a rewrite prompt asks for; its presence in the system prompt is
; what makes a profile a rewrite profile
global LLM_REWRITE_OUTPUT_TAG := "REWRITE:"

; Characters that end a sentence when spacing follows them
global LLM_REWRITE_SENTENCE_TERMINATORS := [".", "!", "?", Chr(0x2026)]

; Characters that separate words, line breaks included
global LLM_REWRITE_SPACING := [" ", "`t", "`n", "`r", Chr(0x00A0), Chr(0x202F)]

; Floor of the rewrite token budget, enough for a short rewritten sentence
global LLM_REWRITE_MIN_MAX_TOKENS := 64

; Tokens budgeted per codepoint of the span: abbreviations expand to several
; times their typed length
global LLM_REWRITE_TOKENS_PER_CHAR := 2

; Fixed overhead for the output tag and the model's spacing
global LLM_REWRITE_TOKEN_BUDGET_OVERHEAD := 16





; ================================
; ================================
; ======= 2/ Public API ==========
; ================================
; ================================

/**
 * Tells whether a system prompt asks for a rewrite instead of a continuation.
 * The tag is matched case-sensitively, like the Lua string.find.
 * @param {String} SystemPrompt The profile's system prompt or raw prompt.
 * @returns {Integer} True when the prompt requests the rewrite tag.
 */
LLM_Rewrite_IsRewritePrompt(SystemPrompt) {
	global LLM_REWRITE_OUTPUT_TAG
	if !(SystemPrompt is String)
		return false
	return InStr(SystemPrompt, LLM_REWRITE_OUTPUT_TAG, true) > 0
}

/**
 * Tells whether a profile is a rewrite profile, from whichever prompt it uses.
 * @param {Map} Profile A profile record (system_single and/or raw_prompt).
 * @returns {Integer} True when one of its prompts requests the rewrite tag.
 */
LLM_Rewrite_IsRewriteProfile(Profile) {
	if !(Profile is Map)
		return false
	return LLM_Rewrite_IsRewritePrompt(Profile.Get("raw_prompt", ""))
		|| LLM_Rewrite_IsRewritePrompt(Profile.Get("system_single", ""))
}

/**
 * Returns the current sentence: the suffix of the buffer to rewrite.
 * Trailing spacing and the sentence's own final terminators belong to the
 * span; the scan starts before them so a just-finished sentence is kept.
 * @param {String} Buffer The typed text, most recent character last.
 * @returns {String} Exact suffix of Buffer, without leading spacing ("" when blank).
 */
LLM_Rewrite_SentenceSpan(Buffer) {
	if !(Buffer is String)
		throw TypeError("LLM_Rewrite_SentenceSpan expects a string buffer, got " . Type(Buffer) . ".")
	Length := StrLen(Buffer)
	Index := Length
	while (Index >= 1 && _LLM_Rewrite_IsSpacing(SubStr(Buffer, Index, 1)))
		Index -= 1
	while (Index >= 1 && _LLM_Rewrite_IsTerminator(SubStr(Buffer, Index, 1)))
		Index -= 1

	Start := 1
	Position := Index
	while (Position >= 1) {
		Char := SubStr(Buffer, Position, 1)
		if (Char == "`n" || Char == "`r") {
			Start := Position + 1
			break
		}
		if (_LLM_Rewrite_IsSpacing(Char) && Position > 1
				&& _LLM_Rewrite_IsTerminator(SubStr(Buffer, Position - 1, 1))) {
			Start := Position + 1
			break
		}
		Position -= 1
	}
	while (Start <= Length && _LLM_Rewrite_IsSpacing(SubStr(Buffer, Start, 1)))
		Start += 1
	if (Start > Index)
		return ""
	return SubStr(Buffer, Start)
}

/**
 * Returns the completion token budget for rewriting a span.
 * @param {String} Span The sentence to rewrite.
 * @returns {Integer} Budget large enough to retype the expanded sentence.
 */
LLM_Rewrite_MaxTokens(Span) {
	global LLM_REWRITE_MIN_MAX_TOKENS, LLM_REWRITE_TOKENS_PER_CHAR
	global LLM_REWRITE_TOKEN_BUDGET_OVERHEAD
	Length := LLM_Rewrite_CodepointLength((Span is String) ? Span : "")
	return Max(LLM_REWRITE_MIN_MAX_TOKENS,
		Length * LLM_REWRITE_TOKENS_PER_CHAR + LLM_REWRITE_TOKEN_BUDGET_OVERHEAD)
}

/**
 * Counts the codepoints of a string. AutoHotkey strings are UTF-16, so a
 * character outside the BMP (an emoji) is two code units but one character,
 * and one Backspace erases it whole.
 * @param {String} Text The text to measure.
 * @returns {Integer} Number of codepoints; a lone surrogate counts as one.
 */
LLM_Rewrite_CodepointLength(Text) {
	if !(Text is String)
		throw TypeError("LLM_Rewrite_CodepointLength expects a string, got " . Type(Text) . ".")
	return _TextCodepointLength(Text)
}





; =====================================
; =====================================
; ======= 3/ Internal Helpers =========
; =====================================
; =====================================

; @param {String} Char One UTF-16 code unit.
; @returns {Integer} True for a space, tab, line break, NBSP or NNBSP.
_LLM_Rewrite_IsSpacing(Char) {
	global LLM_REWRITE_SPACING
	for Spacing in LLM_REWRITE_SPACING
		if (Char == Spacing)
			return true
	return false
}

; @param {String} Char One UTF-16 code unit.
; @returns {Integer} True for a sentence terminator.
_LLM_Rewrite_IsTerminator(Char) {
	global LLM_REWRITE_SENTENCE_TERMINATORS
	for Terminator in LLM_REWRITE_SENTENCE_TERMINATORS
		if (Char == Terminator)
			return true
	return false
}
