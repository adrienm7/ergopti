; modules/llm/parser.ahk

; ==============================================================================
; MODULE: LLM Output Parser (AHK)
; DESCRIPTION:
; Mirrors macos/modules/llm/parser.lua — turns raw model text into insertable
; predictions (to_type / nw / chunks). Without this layer, /api/chat responses
; that carry TAIL_CORRECTED / NEXT_WORDS tags never become tooltip slots.
; ==============================================================================

#Requires AutoHotkey v2.0






; =======================================
; ======= 1/ Cleanup & Extraction =======
; =======================================

/**
 * Removes XML-style thinking segments from model output.
 * Handles both <think>…</think> (DeepSeek / Qwen3) and <thinking>…</thinking>
 * (Claude extended-thinking / some Ollama bridges). Uses non-greedy .*? so that
 * when multiple blocks appear only the content between matching tags is stripped,
 * not everything from the first opening tag to the last closing tag.
 * @param {string} text
 * @returns {string}
 */
LLM_Parser_StripThinking(text) {
	if (Type(text) != "String")
		return ""
	out := text
	; Strip <thinking>…</thinking> first (longer tag — no overlap with <think>).
	; The s) flag makes . match newlines; .*? stops at the FIRST </thinking>.
	out := RegExReplace(out, "si)<thinking>.*?</thinking>\s*", "")
	; Strip any unclosed </thinking> remnant (truncated model output).
	out := RegExReplace(out, "i)</thinking>\s*", "")
	; Strip <think>…</think> (DeepSeek / Qwen3 short tag).
	out := RegExReplace(out, "si)<think>.*?</think>\s*", "")
	; Strip any unclosed </think> remnant.
	out := RegExReplace(out, "i)</think>\s*", "")
	return out
}

/**
 * Splits batch output on === separators (macOS Parser.split_blocks).
 * @param {string} raw
 * @returns {Array}
 */
; max_count (default 0 = unlimited) caps output to prevent a hallucinating
; model from allocating memory for thousands of === separators before the
; caller's slots.Length guard fires (llm-split-batch-no-cap fix).
LLM_Parser_SplitBlocks(raw, max_count := 0) {
	blocks := []
	if (raw == "")
		return blocks
	work := raw . "==="
	pos := 1
	while RegExMatch(work, "s)(.*?)===", &m, pos) {
		piece := Trim(m[1], " `t`r`n")
		if (piece != "")
			blocks.Push(piece)
		pos := m.Pos + m.Len
		if (max_count > 0 and blocks.Length >= max_count)
			break
	}
	if (blocks.Length == 0 and raw != "")
		blocks.Push(Trim(raw, " `t`r`n"))
	return blocks
}

_LLM_Parser_Trim(s) {
	return Trim(s, " `t`r`n")
}

_LLM_Parser_CleanModelOutput(text) {
	if (Type(text) != "String")
		return ""
	out := text
	out := RegExReplace(out, "\*\*", "")
	out := RegExReplace(out, Chr(96), "")
	out := RegExReplace(out, '"', "")
	out := RegExReplace(out, "<[^>]+>", "")
	out := RegExReplace(out, "i)^Voici la suite\s*:?\s*", "")
	out := RegExReplace(out, "i)^Je propose\s*:?\s*", "")
	out := RegExReplace(out, "i)^Suite finale\s*[:.\-]*\s*", "")
	out := RegExReplace(out, "i)</body>\s*</html>", "")
	out := RegExReplace(out, "i)^SUITE\s*:\s*", "")
	out := RegExReplace(out, "i)\[TAIL_CORRECTED\]", "TAIL_CORRECTED:")
	out := RegExReplace(out, "i)\[NEXT_WORDS\]", "NEXT_WORDS:")
	out := RegExReplace(out, "i)TAIL_CORRECTED\s*:", "TAIL_CORRECTED:")
	out := RegExReplace(out, "i)NEXT_WORDS\s*:", "NEXT_WORDS:")
	out := RegExReplace(out, "im)(^|\n)(NEXT)\s*:", "$1NEXT_WORDS:")
	; Strip NUL bytes and other non-printable ASCII control characters (but keep \t, \n, \r)
	out := RegExReplace(out, "[\x00-\x08\x0B\x0C\x0E-\x1F]", "")
	return out
}

_LLM_Parser_EnforceWordLimits(text, max_w) {
	if (text == "")
		return ""
	if !(max_w is Number) or max_w <= 0
		return RegExReplace(text, "\s+$", "")
	count := 0
	rebuilt := ""
	pos := 1
	while RegExMatch(text, "(\S+)(\s*)", &m, pos) {
		count += 1
		if (count > max_w)
			break
		rebuilt .= m[1]
		if (count < max_w)
			rebuilt .= m[2]
		pos := m.Pos + m.Len
	}
	return RegExReplace(rebuilt, "\s+$", "")
}

_LLM_Parser_ApplyFrenchTypography(s) {
	if (s == "")
		return s
	s := StrReplace(s, "'", "’")
	s := RegExReplace(s, " ([?!;])", " $1")
	s := RegExReplace(s, " :", " :")
	return s
}

_LLM_Parser_LastWord(s) {
	if RegExMatch(s, "([\w’']+)[\s  ]*$", &m)
		return m[1]
	return ""
}

_LLM_Parser_CharLev(a, b) {
	m := StrLen(a)
	n := StrLen(b)
	if (m = 0)
		return n
	if (n = 0)
		return m
	; AHK arrays are 1-based and reject index 0, so the classic 0..n Levenshtein
	; rows are shifted by +1: array slot k holds the value for DP column k-1.
	; (The previous port used 0-based indices — prev[0]/curr[0] — which threw
	; "Invalid index" on every call where both strings were non-empty, i.e. on
	; every real advanced-format prediction; it also indexed `a` by the inner
	; loop variable instead of the outer one, mismatching the chars being compared.)
	prev := []
	Loop n + 1
		prev.Push(A_Index - 1)          ; prev[k] = k-1  → DP prev[0..n]
	Loop m {
		i := A_Index
		curr := [i]                     ; curr[1] = i  → DP curr[0] (first column)
		Loop n {
			j := A_Index
			cost := (SubStr(a, i, 1) = SubStr(b, j, 1)) ? 0 : 1
			curr.Push(Min(prev[j + 1] + 1, curr[j] + 1, prev[j] + cost))
		}
		prev := curr
	}
	return prev[n + 1]
}






; ===============================================
; ======= 1.1) Two-tier token diff (port) =======
; ===============================================
; Faithful AHK port of the shared Lua parser's token-level diff
; (_shared/lua/llm/parser.lua: get_chars / tokenize / token_sub_cost /
; token_diff_ops). These drive the intra-word physical injection so the AHK
; driver deletes only the changed characters instead of retyping whole words.
; UTF-8 chars are iterated one codepoint at a time (BMP — French accents — only).

; Split a string into an array of characters (one per codepoint).
_LLM_Parser_GetChars(s) {
	chars := []
	Loop Parse, s
		chars.Push(A_LoopField)
	return chars
}

; Tokenize into semantic elements: words (type 1), whitespace runs (type 2) and
; single punctuation chars (type 3). Typographic apostrophes bind to the word.
_LLM_Parser_Tokenize(s) {
	tokens := []
	current := ""
	current_type := 0
	Loop Parse, s {
		c := A_LoopField
		if (c ~= "\s" or c = Chr(0x00A0) or c = Chr(0x202F))
			tokenType := 2
		else if (c ~= "[\w']" or c = Chr(0x2019) or Ord(c) >= 128)
			tokenType := 1
		else
			tokenType := 3
		if (tokenType = 3) {
			if (current != "")
				tokens.Push(current)
			tokens.Push(c)
			current := ""
			current_type := 0
		} else if (tokenType = current_type) {
			current .= c
		} else {
			if (current != "")
				tokens.Push(current)
			current := c
			current_type := tokenType
		}
	}
	if (current != "")
		tokens.Push(current)
	return tokens
}

; Cost of substituting two tokens: 0 if equal, 1000 across types or beyond a 40%
; edit-distance threshold (so unrelated words are never "corrected" into each
; other), else the raw char-level Levenshtein distance.
_LLM_Parser_TokenSubCost(t1, t2) {
	if (t1 == t2)
		return 0
	type1 := (t1 ~= "\s") ? 2 : ((t1 ~= "[\w" . Chr(0x2019) . "']") ? 1 : 3)
	type2 := (t2 ~= "\s") ? 2 : ((t2 ~= "[\w" . Chr(0x2019) . "']") ? 1 : 3)
	if (type1 != type2)
		return 1000
	c1 := _LLM_Parser_GetChars(t1)
	c2 := _LLM_Parser_GetChars(t2)
	n1 := c1.Length
	n2 := c2.Length
	; matrix[i][j] for DP indices 0..n1 x 0..n2, stored 1-based at (i+1, j+1).
	matrix := []
	Loop n1 + 1 {
		row := []
		Loop n2 + 1
			row.Push(0)
		matrix.Push(row)
	}
	Loop n1 + 1
		matrix[A_Index][1] := A_Index - 1
	Loop n2 + 1
		matrix[1][A_Index] := A_Index - 1
	Loop n1 {
		i := A_Index
		Loop n2 {
			j := A_Index
			cost := (c1[i] == c2[j]) ? 0 : 1
			matrix[i + 1][j + 1] := Min(matrix[i][j + 1] + 1, matrix[i + 1][j] + 1, matrix[i][j] + cost)
		}
	}
	dist := matrix[n1 + 1][n2 + 1]
	max_len := Max(n1, n2)
	threshold := Max(1, Floor(max_len * 0.4))
	if (dist > threshold)
		return 1000
	return dist
}

; Semi-global token diff between orig and corr. Returns an array of op Maps:
; { type: "equal"|"del"|"ins"|"sub", t1?, t2? }. Free leading deletion on orig
; (d[i][0] = 0) lets the corrected tail align without leading-context artifacts.
_LLM_Parser_TokenDiffOps(orig, corr) {
	tokens1 := _LLM_Parser_Tokenize(orig)
	tokens2 := _LLM_Parser_Tokenize(corr)
	len1 := tokens1.Length
	len2 := tokens2.Length
	; d[i][j] for DP indices 0..len1 x 0..len2, stored 1-based at (i+1, j+1).
	d := []
	Loop len1 + 1 {
		row := []
		Loop len2 + 1
			row.Push(0)
		d.Push(row)
	}
	sum2 := 0
	Loop len2 {
		j := A_Index
		sum2 += _LLM_Parser_GetChars(tokens2[j]).Length
		d[1][j + 1] := sum2
	}
	Loop len1 {
		i := A_Index
		Loop len2 {
			j := A_Index
			cost_del := d[i][j + 1] + _LLM_Parser_GetChars(tokens1[i]).Length
			cost_ins := d[i + 1][j] + _LLM_Parser_GetChars(tokens2[j]).Length
			cost_sub := d[i][j] + _LLM_Parser_TokenSubCost(tokens1[i], tokens2[j])
			d[i + 1][j + 1] := Min(cost_del, cost_ins, cost_sub)
		}
	}
	i := len1
	j := len2
	ops := []
	while (i > 0 or j > 0) {
		if (j = 0) {
			ops.InsertAt(1, Map("type", "del", "t1", tokens1[i]))
			i -= 1
		} else if (i = 0) {
			ops.InsertAt(1, Map("type", "ins", "t2", tokens2[j]))
			j -= 1
		} else if (tokens1[i] == tokens2[j]) {
			ops.InsertAt(1, Map("type", "equal", "t1", tokens1[i], "t2", tokens2[j]))
			i -= 1
			j -= 1
		} else {
			cost_del := d[i][j + 1] + _LLM_Parser_GetChars(tokens1[i]).Length
			cost_ins := d[i + 1][j] + _LLM_Parser_GetChars(tokens2[j]).Length
			cost_sub := d[i][j] + _LLM_Parser_TokenSubCost(tokens1[i], tokens2[j])
			min_cost := Min(cost_del, cost_ins, cost_sub)
			if (min_cost = cost_sub) {
				ops.InsertAt(1, Map("type", "sub", "t1", tokens1[i], "t2", tokens2[j]))
				i -= 1
				j -= 1
			} else if (min_cost = cost_del) {
				ops.InsertAt(1, Map("type", "del", "t1", tokens1[i]))
				i -= 1
			} else {
				ops.InsertAt(1, Map("type", "ins", "t2", tokens2[j]))
				j -= 1
			}
		}
	}
	return ops
}

; Extract the word tokens (letters / digits / apostrophes) of a string, used to
; detect and strip tc/nw overlap. Mirrors the Lua get_word_tokens gmatch.
_LLM_Parser_WordTokens(text) {
	words := []
	pos := 1
	while (RegExMatch(text, "[\w" . Chr(0x2019) . "']+", &m, pos)) {
		words.Push(m[0])
		pos := m.Pos + m.Len
	}
	return words
}

; Character-level prefix/suffix isolation of two words into equal/insert chunks
; (display only — feeds disable_bold). Mirrors the Lua intra_word_diff.
_LLM_Parser_IntraWordDiff(w1, w2) {
	c1 := _LLM_Parser_GetChars(w1)
	c2 := _LLM_Parser_GetChars(w2)
	p_len := 0
	while (p_len < c1.Length and p_len < c2.Length and c1[p_len + 1] == c2[p_len + 1])
		p_len += 1
	s_len := 0
	while (s_len < (c1.Length - p_len) and s_len < (c2.Length - p_len) and c1[c1.Length - s_len] == c2[c2.Length - s_len])
		s_len += 1
	prefix := ""
	mid := ""
	suffix := ""
	Loop c2.Length {
		if (A_Index <= p_len)
			prefix .= c2[A_Index]
		else if (A_Index <= c2.Length - s_len)
			mid .= c2[A_Index]
		else
			suffix .= c2[A_Index]
	}
	chunks := []
	if (prefix != "")
		chunks.Push(Map("type", "equal", "text", prefix))
	if (mid != "")
		chunks.Push(Map("type", "insert", "text", mid))
	if (suffix != "")
		chunks.Push(Map("type", "equal", "text", suffix))
	return chunks
}






; ========================================
; ======= 2/ Core Processing Logic =======
; ========================================

/**
 * Parses one model block into a prediction Map (macOS process_prediction).
 * Returns "" when the block should count as a failed variant.
 *
 * Crash firewall: the actual parsing lives in _LLM_Parser_ProcessPredictionImpl
 * and is invoked here under try/catch. ProcessPrediction runs deep inside the
 * async poll / SetTimer callbacks of the prediction engine, where AHK SWALLOWS
 * any thrown exception — a crash on adversarial model output (an unexpected
 * token shape the prefix/suffix anchor loops did not anticipate) would silently
 * abort the variant with zero diagnostics. Catching here degrades such an edge
 * crash to a failed variant WITH a warning log line instead of a silent swallow.
 *
 * @param {string} full_text - Capped context buffer.
 * @param {string} tail_text - Last N words of the buffer.
 * @param {string} block - Raw model output for one prediction.
 * @param {number} min_words
 * @param {number} max_words
 * @returns {Map|""} { to_type, nw, deletes, chunks, has_corrections, disable_bold }
 */
LLM_Parser_ProcessPrediction(full_text, tail_text, block, min_words := 1, max_words := 15) {
	try {
		return _LLM_Parser_ProcessPredictionImpl(full_text, tail_text, block, min_words, max_words)
	} catch as err {
		; Snippet of the offending block so the log carries enough context to
		; reproduce the edge input that tripped the parser.
		snippet := (Type(block) = "String") ? SubStr(block, 1, 120) : Type(block)
		try LoggerWarn("LLM.parser", "ProcessPrediction crashed on model output — variant dropped: {1} | block: «{2}».", err.Message, snippet)
		return ""
	}
}

/**
 * Internal implementation of LLM_Parser_ProcessPrediction — see that function
 * for the contract. Kept private so the public entry point can wrap it in the
 * crash firewall (the async callbacks that drive it swallow thrown errors).
 *
 * @param {string} full_text
 * @param {string} tail_text
 * @param {string} block
 * @param {number} min_words
 * @param {number} max_words
 * @returns {Map|""}
 */
_LLM_Parser_ProcessPredictionImpl(full_text, tail_text, block, min_words := 1, max_words := 15) {
	if (Type(block) != "String" or StrLen(Trim(block)) == 0)
		return ""
	full_text := (Type(full_text) = "String") ? full_text : ""
	tail_text := (Type(tail_text) = "String") ? tail_text : ""
	block := StrReplace(block, "'", "’")
	block := _LLM_Parser_CleanModelOutput(block)

	is_advanced := (InStr(block, "TAIL_CORRECTED") or InStr(block, "NEXT_WORDS"))

	if is_advanced {
		tc := ""
		nw := ""
		if RegExMatch(block, "i)TAIL_CORRECTED\s*:\s*(.*?)(?:\r?\n|$)", &m)
			tc := _LLM_Parser_Trim(m[1])
		if RegExMatch(block, "i)NEXT_WORDS\s*:\s*(.*?)(?:\r?\n|$)", &m)
			nw := _LLM_Parser_Trim(m[1])
		tc := RegExReplace(tc, "\s*\]$", "")
		tc := RegExReplace(tc, '^"', "")
		tc := RegExReplace(tc, '"$', "")
		nw := RegExReplace(nw, "\s*\]$", "")
		nw := RegExReplace(nw, '^"', "")
		nw := RegExReplace(nw, '"$', "")
		tc := _LLM_Parser_ApplyFrenchTypography(tc)
		nw := _LLM_Parser_ApplyFrenchTypography(nw)
		nw := RegExReplace(nw, "^[\s\.…]+", "")
		nw := RegExReplace(nw, "[\s\.…]+$", "")
		nw := _LLM_Parser_EnforceWordLimits(nw, max_words)
		; Cap tc the same way. Its capture is bounded only by line length, and it
		; feeds _LLM_Parser_TokenDiffOps — an O(n^2) dynamic program whose per-cell
		; body allocates a fresh char array twice and a full (n1+1)x(n2+1) matrix
		; once. len1 is clamped downstream but len2 was not, so a model in a
		; repetition loop could emit a multi-KB TAIL_CORRECTED line and stall the
		; keystroke thread (the poll chain shares AHK's single thread with the
		; keyboard hook). The crash firewall catches exceptions, not elapsed time,
		; so this degraded to a hang with nothing logged. A correction can never
		; legitimately exceed the prediction budget.
		tc := _LLM_Parser_EnforceWordLimits(tc, max_words)
		if (nw = "")
			return ""
		if (tc = "" and nw != "")
			tc := _LLM_Parser_Trim(RegExReplace(tail_text, '^"', ""))
		if (tc = "" and nw = "")
			return ""

		orig_last := _LLM_Parser_LastWord(full_text)
		tc_last := _LLM_Parser_LastWord(tc)
		if (orig_last != "" and tc_last != "") {
			max_len := Max(StrLen(orig_last), StrLen(tc_last))
			dist := _LLM_Parser_CharLev(StrLower(orig_last), StrLower(tc_last))
			if (max_len > 0 and dist >= max_len)
				return ""
		}

		; --- Faithful port of the shared Lua advanced path (intra-word token diff) ---
		normalized_full := full_text
		tc_norm := tc

		; Match the user's trailing spaces so we never cut mid-word.
		if RegExMatch(normalized_full, "([\s" . Chr(0x00A0) . Chr(0x202F) . "]+)$", &mts) {
			if !(tc_norm ~= "[\s" . Chr(0x00A0) . Chr(0x202F) . "]$")
				tc_norm .= mts[1]
		}

		; Strip overlap between the tail of tc_norm and the head of nw (dup words).
		tc_words := _LLM_Parser_WordTokens(tc_norm)
		nw_words := _LLM_Parser_WordTokens(nw)
		overlap_words := 0
		Loop Min(tc_words.Length, nw_words.Length) {
			ii := A_Index
			matched := true
			Loop ii {
				jj := A_Index
				if (StrLower(tc_words[tc_words.Length - ii + jj]) != StrLower(nw_words[jj])) {
					matched := false
					break
				}
			}
			if matched
				overlap_words := ii
		}
		nw_norm := nw
		if (overlap_words > 0) {
			nw_toks := _LLM_Parser_Tokenize(nw_norm)
			words_skipped := 0
			slice_idx := 1
			Loop nw_toks.Length {
				ti := A_Index
				if (nw_toks[ti] ~= "[\w" . Chr(0x2019) . "']")
					words_skipped += 1
				if (words_skipped = overlap_words) {
					slice_idx := ti + 1
					break
				}
			}
			rem := ""
			Loop nw_toks.Length {
				if (A_Index >= slice_idx)
					rem .= nw_toks[A_Index]
			}
			nw_norm := RegExReplace(rem, "^[\s" . Chr(0x00A0) . Chr(0x202F) . "]+", "")
		}

		; Space handling between tc_norm and nw_norm.
		last_char := SubStr(tc_norm, -1)
		first_char := SubStr(nw_norm, 1, 1)
		needs_space := !(last_char ~= "[\s'" . Chr(0x2019) . "\-]" or last_char = Chr(0x00A0) or last_char = Chr(0x202F) or first_char ~= "[\s.,;)}%\]]" or nw_norm = "")
		if needs_space
			nw_norm := " " . nw_norm

		; Sliding window of the buffer context, snapped to a word boundary.
		nf_len := StrLen(normalized_full)
		window_size := Min(nf_len, Max(60, StrLen(tc_norm) + 30))
		orig_context := SubStr(normalized_full, nf_len - window_size + 1)
		if (window_size < nf_len and !(orig_context ~= "^[\s" . Chr(0x00A0) . Chr(0x202F) . "]")) {
			snap := RegExMatch(orig_context, "[\s" . Chr(0x00A0) . Chr(0x202F) . "]")
			if (snap)
				orig_context := SubStr(orig_context, snap)
		}

		; 1. Diff strictly against TAIL_CORRECTED.
		ops := _LLM_Parser_TokenDiffOps(orig_context, tc_norm)

		; 2. Strip leading context (free deletes + leading inserted spaces).
		stripped_ops := []
		while (ops.Length > 0 and ops[1]["type"] = "del")
			stripped_ops.Push(ops.RemoveAt(1))
		while (ops.Length > 0 and ops[1]["type"] = "ins" and ops[1]["t2"] ~= "^[\s" . Chr(0x00A0) . Chr(0x202F) . "]+$")
			stripped_ops.Push(ops.RemoveAt(1))

		; 3. Append NEXT_WORDS strictly as downstream insertions.
		if (nw_norm != "") {
			for ti2, tk in _LLM_Parser_Tokenize(nw_norm)
				ops.Push(Map("type", "ins", "t2", tk))
		}

		if (ops.Length = 0)
			return ""

		; 4. Locate the first actual change in the alignment.
		first_change_idx := -1
		for oi, op in ops {
			if (op["type"] != "equal") {
				first_change_idx := oi
				break
			}
		}

		; Context matched perfectly; the model only appended words.
		if (first_change_idx = -1)
			return Map("deletes", 0, "to_type", "", "nw", nw_norm, "has_corrections", false, "chunks", [], "disable_bold", false)

		; 5. Physical injection (intra-word prefix optimization on the first sub).
		true_deletes := 0
		true_to_type := ""
		Loop ops.Length {
			pidx := A_Index
			if (pidx < first_change_idx)
				continue
			op := ops[pidx]
			if (pidx = first_change_idx and op["type"] = "sub") {
				c1 := _LLM_Parser_GetChars(op["t1"])
				c2 := _LLM_Parser_GetChars(op["t2"])
				p_len := 0
				while (p_len < c1.Length and p_len < c2.Length and c1[p_len + 1] == c2[p_len + 1])
					p_len += 1
				true_deletes += (c1.Length - p_len)
				Loop c2.Length {
					if (A_Index > p_len)
						true_to_type .= c2[A_Index]
				}
			} else {
				ty := op["type"]
				if (ty = "equal") {
					true_deletes += StrLen(op["t1"])
					true_to_type .= op["t2"]
				} else if (ty = "del") {
					true_deletes += StrLen(op["t1"])
				} else if (ty = "ins") {
					true_to_type .= op["t2"]
				} else if (ty = "sub") {
					true_deletes += StrLen(op["t1"])
					true_to_type .= op["t2"]
				}
			}
		}

		; Safety circuit breaker against massive unprompted deletions.
		max_allowed_dels := Max(20, StrLen(tc_norm) + 10)
		if (true_deletes > max_allowed_dels)
			return ""
		if (RegExReplace(true_to_type, "[\s\.…]", "") = "")
			return ""

		; 6. Visual ops → display_nw / has_corrections / disable_bold.
		first_op := ops[first_change_idx]
		needs_anchor := false
		if (first_op["type"] = "del") {
			needs_anchor := true
		} else if (first_op["type"] = "sub") {
			vc1 := _LLM_Parser_GetChars(first_op["t1"])
			vc2 := _LLM_Parser_GetChars(first_op["t2"])
			if (vc1.Length > 0 and vc2.Length > 0 and vc1[1] != vc2[1])
				needs_anchor := true
		} else if (first_op["type"] = "ins") {
			if (first_op["t2"] ~= "^[\w" . Chr(0x2019) . "']")
				needs_anchor := true
		}

		visual_ops := []
		if (needs_anchor and first_change_idx = 1 and stripped_ops.Length > 0) {
			anchor_text := ""
			ak := stripped_ops.Length
			while (ak >= 1) {
				; stripped_ops may hold leading-space "ins" ops (t2 only, no t1);
				; default to "" so neither concat nor Ord() throws "Key not found".
				stk := stripped_ops[ak].Has("t1") ? stripped_ops[ak]["t1"] : ""
				anchor_text := stk . anchor_text
				if (stk != "" and (stk ~= "[\w" . Chr(0x2019) . "']" or Ord(stk) >= 128))
					break
				ak -= 1
			}
			visual_ops.Push(Map("type", "equal", "t1", anchor_text, "t2", anchor_text))
		} else if (needs_anchor) {
			ak := first_change_idx - 1
			while (ak >= 1) {
				visual_ops.InsertAt(1, ops[ak])
				; ops[ak] may be an "ins" op (t2 only, no t1) — guard the key access
				; and skip empty tokens so Ord() never sees an absent value.
				atk := ops[ak].Has("t1") ? ops[ak]["t1"] : ""
				if (atk != "" and (atk ~= "[\w" . Chr(0x2019) . "']" or Ord(atk) >= 128))
					break
				ak -= 1
			}
		}
		Loop ops.Length {
			if (A_Index >= first_change_idx)
				visual_ops.Push(ops[A_Index])
		}

		; Boundary where strictly-new (orange) words begin.
		last_anchor_idx := 0
		bk := visual_ops.Length
		while (bk >= 1) {
			vop := visual_ops[bk]
			if (vop["type"] != "ins") {
				t1v := vop.Has("t1") ? vop["t1"] : ""
				if (RegExReplace(t1v, "[\s" . Chr(0x00A0) . Chr(0x202F) . "]", "") != "") {
					last_anchor_idx := bk
					break
				}
			}
			bk -= 1
		}
		nw_start_idx := visual_ops.Length + 1
		if (last_anchor_idx > 0) {
			anchor_op := visual_ops[last_anchor_idx]
			if (anchor_op["type"] = "del") {
				found_word := false
				cj := last_anchor_idx + 1
				while (cj <= visual_ops.Length) {
					vj := visual_ops[cj]
					vt2 := vj.Has("t2") ? vj["t2"] : ""
					if (vj["type"] = "ins" and vt2 ~= "[\w" . Chr(0x2019) . "']") {
						found_word := true
					} else if (found_word and !(vt2 ~= "[\w" . Chr(0x2019) . "']")) {
						nw_start_idx := cj
						break
					}
					cj += 1
				}
				if (!found_word)
					nw_start_idx := visual_ops.Length + 1
			} else {
				nw_start_idx := last_anchor_idx + 1
				while (nw_start_idx <= visual_ops.Length) {
					vop := visual_ops[nw_start_idx]
					vt2 := vop.Has("t2") ? vop["t2"] : ""
					if (vop["type"] = "equal" and vt2 ~= "^[\s" . Chr(0x00A0) . Chr(0x202F) . "]+$")
						nw_start_idx += 1
					else
						break
				}
			}
		} else {
			nw_start_idx := 1
		}

		display_nw := ""
		Loop visual_ops.Length {
			if (A_Index >= nw_start_idx) {
				vop := visual_ops[A_Index]
				display_nw .= vop.Has("t2") ? vop["t2"] : ""
			}
		}

		; Drop the NW ops from the chunk source.
		kept := []
		Loop visual_ops.Length {
			if (A_Index < nw_start_idx)
				kept.Push(visual_ops[A_Index])
		}
		visual_ops := kept

		; Build + merge UI chunks (needed for has_corrections + disable_bold).
		raw_chunks := []
		has_corr := false
		for vi, op in visual_ops {
			ty := op["type"]
			if (ty = "equal") {
				raw_chunks.Push(Map("type", "equal", "text", op.Has("t2") ? op["t2"] : ""))
			} else if (ty = "ins") {
				has_corr := true
				raw_chunks.Push(Map("type", "insert", "text", op["t2"]))
			} else if (ty = "sub") {
				has_corr := true
				; A "sub" op always carries both tokens, but guard the key access
				; and skip empty tokens so Ord() never operates on an absent value.
				w1 := op.Has("t1") ? op["t1"] : ""
				w2 := op.Has("t2") ? op["t2"] : ""
				is_word1 := (w1 != "") and ((w1 ~= "[\w" . Chr(0x2019) . "']") or (Ord(w1) >= 128))
				is_word2 := (w2 != "") and ((w2 ~= "[\w" . Chr(0x2019) . "']") or (Ord(w2) >= 128))
				if (is_word1 and is_word2) {
					for si, sc in _LLM_Parser_IntraWordDiff(w1, w2)
						raw_chunks.Push(sc)
				} else {
					raw_chunks.Push(Map("type", "insert", "text", w2))
				}
			} else if (ty = "del") {
				has_corr := true
			}
		}

		chunks := []
		for ci, c in raw_chunks {
			if (chunks.Length > 0 and chunks[chunks.Length]["type"] = c["type"])
				chunks[chunks.Length]["text"] := chunks[chunks.Length]["text"] . c["text"]
			else
				chunks.Push(Map("type", c["type"], "text", c["text"]))
		}

		; Clear orphaned gray chunks; trip the safety guard on silent deletions.
		only_equals := true
		for ci2, c in chunks {
			if (c["type"] != "equal") {
				only_equals := false
				break
			}
		}
		if only_equals {
			chunks := []
			if (true_deletes > 0) {
				appended_len := StrLen(true_to_type)
				if (true_deletes > 10 or appended_len = 0)
					return ""
			}
		}

		disable_bold := (chunks.Length > 0 and chunks[chunks.Length]["type"] = "insert" and (display_nw ~= "\S") > 0)

		return Map(
			"deletes", true_deletes,
			"to_type", true_to_type,
			"nw", display_nw,
			"has_corrections", has_corr,
			"chunks", chunks,
			"disable_bold", disable_bold
		)
	}

	; Basic / line mode (macOS parser.lua else branch)
	nw := Trim(block)
	if RegExMatch(nw, "([^\r\n]+)", &line)
		nw := line[1]
	nw := RegExReplace(nw, "i)^\[?NEXT\]?\s*:?\s*", "")
	nw := RegExReplace(nw, "i)^SUITE\s*:\s*", "")
	nw := RegExReplace(nw, "i)^Suite finale\s*[:.\-]*\s*", "")
	nw := RegExReplace(nw, "^[-•*]+\s*", "")
	nw := RegExReplace(nw, "^[\s\.…]+", "")
	nw := RegExReplace(nw, "[\s\.…]+$", "")
	nw := _LLM_Parser_ApplyFrenchTypography(nw)
	if (InStr(nw, "www.") or InStr(nw, "http") or InStr(nw, "</"))
		return ""

	; Strip buffer suffix overlap (last 20 words window)
	full_words := []
	pos := 1
	while RegExMatch(full_text, "(\S+)", &m, pos) {
		full_words.Push(m[1])
		pos := m.Pos + m.Len
	}
	nw_words := []
	pos := 1
	while RegExMatch(nw, "(\S+)", &m, pos) {
		nw_words.Push(m[1])
		pos := m.Pos + m.Len
	}
	start_idx := Max(1, full_words.Length - 19)
	loop (full_words.Length - start_idx + 1) {
		i := start_idx + A_Index - 1
		buf_suffix_count := full_words.Length - i + 1
		if (buf_suffix_count <= nw_words.Length) {
			match := true
			loop buf_suffix_count {
				bw := RegExReplace(full_words[i + A_Index - 1], "[[:punct:][:cntrl:]]", "")
				pw := RegExReplace(nw_words[A_Index], "[[:punct:][:cntrl:]]", "")
				if (StrLower(bw) != StrLower(pw) or bw = "") {
					match := false
					break
				}
			}
			if match {
				remaining := []
				loop (nw_words.Length - buf_suffix_count)
					remaining.Push(nw_words[buf_suffix_count + A_Index])
				nw := ""
				for _, w in remaining
					nw .= (nw = "" ? w : " " w)
				break
			}
		}
	}

	nw := RegExReplace(nw, "\s*\]$", "")
	nw := RegExReplace(nw, "\s+$", "")
	nw := _LLM_Parser_EnforceWordLimits(nw, max_words)
	if (nw = "")
		return ""

	to_type := nw
	deletes := 0
	if (to_type != "" and tail_text != "") {
		t_last := SubStr(tail_text, -1)
		is_space := (t_last ~= "\s" or t_last = " " or t_last = " ")
		is_apos := (t_last ~= "['’]")
		type_start := SubStr(to_type, 1, 1)
		if (!is_space and !is_apos and !(type_start ~= "[\s.,;?!]"))
			to_type := " " to_type
		else if (is_space and RegExMatch(to_type, "^\s+"))
			to_type := RegExReplace(to_type, "^\s+", "")
	}

	if RegExReplace(to_type, "[\s\.…]", "") = ""
		return ""

	word_count := 0
	pos := 1
	while RegExMatch(to_type, "\S+", &m, pos) {
		word_count += 1
		pos := m.Pos + m.Len
	}
	if (word_count < min_words)
		return ""

	return Map(
		"deletes", deletes,
		"to_type", to_type,
		"nw", nw,
		"has_corrections", false,
		"chunks", [],
		"disable_bold", false
	)
}

/**
 * Full post-API parse path — mirrors api_ollama.lua post_and_parse.
 * @returns {Array} Slot strings (to_type) ready for the tooltip.
 */
LLM_Parser_ParseResponse(raw, full_text, tail_text, min_words, max_words, is_batch, n_predictions, &out_stats := "") {
	raw := LLM_Parser_StripThinking(raw)
	if (raw = "")
		return []
	stats := LLM_ApiCommon_NewDedupStats()
	slots := []
	if is_batch {
		; Pass n_predictions as the hard cap so a hallucinating model cannot
		; generate thousands of === separators and saturate memory before the
		; slots.Length guard ever fires (llm-split-batch-no-cap fix).
		for _, block in LLM_Parser_SplitBlocks(raw, n_predictions) {
			if (slots.Length >= n_predictions)
				break
			pred := LLM_Parser_ProcessPrediction(full_text, tail_text, block, min_words, max_words)
			if (pred != "")
				LLM_ApiCommon_InsertPrediction(slots, pred, stats, true)
		}
	} else {
		pred := LLM_Parser_ProcessPrediction(full_text, tail_text, raw, min_words, max_words)
		if (pred != "")
			LLM_ApiCommon_InsertPrediction(slots, pred, stats, true)
	}
	if IsSet(out_stats)
		out_stats := stats
	out := []
	for _, p in slots
		out.Push(_LLM_ApiCommon_PredText(p))
	return out
}
