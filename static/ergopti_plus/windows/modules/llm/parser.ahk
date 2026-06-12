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
 * @param {string} text
 * @returns {string}
 */
LLM_Parser_StripThinking(text) {
	if (Type(text) != "String")
		return ""
	out := text
	out := RegExReplace(out, "i)<think>[\s\S]*?</think>\s*", "")
	out := RegExReplace(out, "i)</think>\s*", "")
	return out
}

/**
 * Splits batch output on === separators (macOS Parser.split_blocks).
 * @param {string} raw
 * @returns {Array}
 */
LLM_Parser_SplitBlocks(raw) {
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






; ========================================
; ======= 2/ Core Processing Logic =======
; ========================================

/**
 * Parses one model block into a prediction Map (macOS process_prediction).
 * Returns "" when the block should count as a failed variant.
 *
 * @param {string} full_text - Capped context buffer.
 * @param {string} tail_text - Last N words of the buffer.
 * @param {string} block - Raw model output for one prediction.
 * @param {number} min_words
 * @param {number} max_words
 * @returns {Map|""} { to_type, nw, deletes, chunks, has_corrections, disable_bold }
 */
LLM_Parser_ProcessPrediction(full_text, tail_text, block, min_words := 1, max_words := 15) {
	if (Type(block) != "String" or block = "")
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

		; Build insertable text: prefer delta beyond tail when tail matches prefix of tc.
		to_type := ""
		if (tail_text != "" and InStr(tc, tail_text, true) = 1)
			to_type := SubStr(tc, StrLen(tail_text) + 1)
		else if (tail_text != "" and StrCompare(SubStr(tail_text, -Min(StrLen(tail_text), StrLen(tc))), tc, true) = 0)
			to_type := ""
		else
			to_type := tc

		if (nw != "") {
			last_ch := (StrLen(to_type) > 0) ? SubStr(to_type, -1) : ""
			first_nw := SubStr(nw, 1, 1)
			needs_space := !(last_ch ~= "[\s'’\-]" or last_ch = " " or last_ch = " ")
				&& !(first_nw ~= "[\s.,;)\}%]")
			if (needs_space and to_type != "" and !InStr(to_type, " ", false))
				to_type .= " "
			to_type .= nw
		} else if (to_type = "") {
			to_type := nw
		}

		if RegExReplace(to_type, "[\s\.…]", "") = ""
			return ""

		return Map(
			"deletes", 0,
			"to_type", to_type,
			"nw", nw,
			"has_corrections", (tc != tail_text),
			"chunks", [],
			"disable_bold", false
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
LLM_Parser_ParseResponse(raw, full_text, tail_text, min_words, max_words, is_batch, n_predictions) {
	raw := LLM_Parser_StripThinking(raw)
	if (raw = "")
		return []
	stats := LLM_ApiCommon_NewDedupStats()
	slots := []
	if is_batch {
		for _, block in LLM_Parser_SplitBlocks(raw) {
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
	out := []
	for _, p in slots
		out.Push(_LLM_ApiCommon_PredText(p))
	return out
}