; infra/llm_diff.ahk

; ==============================================================================
; MODULE: LLM Diff Engine
; DESCRIPTION:
; Computes diff chunks between the user's current text buffer tail and an LLM
; prediction so the tooltip can colorise corrections (green) vs. next-words
; (orange). Mirrors the semantic diff logic from macos/modules/llm/parser.lua
; at the AHK level.
;
; ALGORITHM:
; 1. Tokenise both strings into word/space/punctuation tokens.
; 2. Find the longest common prefix of tokens between buffer tail and prediction.
; 3. Everything matching the prefix is "equal" (shown in green on the active
;    slot — it is the correction that matches what the user typed).
; 4. Tokens past the prefix that appear in the prediction but not the buffer
;    are "insert" chunks (shown in orange for next-words content).
; 5. The result is an Array of { type: "equal"|"insert", text: "..." } chunks
;    plus a NextWords string (the trailing new words, used separately by the
;    renderer).
;
; LIMITATIONS VS. HS PARSER:
; - No full LCS / Wagner-Fischer matrix — just prefix matching. This handles
;   the common case (LLM extends the user's tail) correctly. Intra-word typo
;   colorisation (individual character-level diff) is not implemented.
; - No French typography normalisation; results are not NFD-normalised.
;   Both are acceptable for a Windows driver tooltip display.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Public Interface =======
; ===================================
; ===================================

/**
 * Compute diff chunks for a single LLM prediction against the buffer tail.
 * Returns an object compatible with LLM_TooltipShow's slot format.
 *
 * @param {string} buffer_tail  The last N chars of the user's active buffer.
 * @param {string} prediction   The full prediction text from the LLM.
 * @returns {Object} { Text, Chunks, NextWords, HasCorrections }
 *   Text          — plain concatenated string (used for Tab insertion).
 *   Chunks        — Array of { type: "equal"|"insert", text: "..." }.
 *   NextWords     — trailing new-word segment (rendered in orange separately).
 *   HasCorrections — true when any chunk type == "equal" (corrections exist).
 */
LLM_Diff_Compute(buffer_tail, prediction) {
	if (Type(buffer_tail) != "String" or Type(prediction) != "String")
		return { Text: prediction, Chunks: [], NextWords: prediction, HasCorrections: false }
	if (prediction == "")
		return { Text: "", Chunks: [], NextWords: "", HasCorrections: false }

	; Tokenise both strings.
	buf_tokens  := _LLM_Diff_Tokenize(buffer_tail)
	pred_tokens := _LLM_Diff_Tokenize(prediction)

	; Find common prefix length (word-level match, case-sensitive).
	prefix_len := 0
	max_cmp := Min(buf_tokens.Length, pred_tokens.Length)
	loop max_cmp {
		if (buf_tokens[A_Index] == pred_tokens[A_Index])
			prefix_len := A_Index
		else
			break
	}

	; Build chunks: equal = prefix, insert = remainder.
	chunks := []
	equal_text := ""
	loop prefix_len {
		equal_text .= pred_tokens[A_Index]
	}
	if (equal_text != "")
		chunks.Push({ type: "equal", text: equal_text })

	insert_text := ""
	i := prefix_len + 1
	while (i <= pred_tokens.Length) {
		insert_text .= pred_tokens[i]
		i++
	}
	if (insert_text != "")
		chunks.Push({ type: "insert", text: insert_text })

	; Trim leading whitespace from the equal chunk (mirrors HS clean_leading_spaces).
	if (chunks.Length > 0 and chunks[1].type == "equal")
		chunks[1].text := LTrim(chunks[1].text)

	; Evaluate HasCorrections after the trim so a chunk that becomes empty
	; after stripping leading spaces is not counted as a real correction
	has_corrections := (chunks.Length > 0 and chunks[1].type == "equal" and chunks[1].text != "")

	return {
		Text:           prediction,
		Chunks:         chunks,
		NextWords:      insert_text,
		HasCorrections: has_corrections
	}
}





; ===================================
; ===================================
; ======= 2/ Internal helpers =======
; ===================================
; ===================================

; Tokenise a string into an array of word / space / punctuation tokens,
; mirroring the Lua tokenize() function in parser.lua. Each token is either:
;   • a sequence of word characters (letters, digits, apostrophes)
;   • a sequence of whitespace characters
;   • a single punctuation / symbol character
_LLM_Diff_Tokenize(text) {
	tokens := []
	if (text == "")
		return tokens
	current := ""
	; 0 = none, 1 = word, 2 = space, 3 = punct
	current_type := 0

	loop parse, text {
		c := A_LoopField
		if RegExMatch(c, "[\w']") or Ord(c) >= 128   ; >= 128 catches accented, CJK, emoji, etc.
			t := 1
		else if (c == " " or c == "`t" or Ord(c) == 160)   ; 160 = nbsp
			t := 2
		else
			t := 3

		if (t == 3) {
			; Punctuation: flush current, then emit this char as its own token.
			if (current != "")
				tokens.Push(current)
			tokens.Push(c)
			current := ""
			current_type := 0
		} else if (t == current_type) {
			current .= c
		} else {
			if (current != "")
				tokens.Push(current)
			current := c
			current_type := t
		}
	}
	if (current != "")
		tokens.Push(current)
	return tokens
}
