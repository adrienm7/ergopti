; static/ergopti_plus/windows/tests/unit/test_llm_parser_refuses_uninjectable_deletes.ahk

; ==============================================================================
; MODULE: Regression — a prediction needing an erasure reaches the tooltip on
;         Windows only with the exact text it erases
;         (llm-parser-deletes-never-applied, llm-correction-erases)
; DESCRIPTION:
; LLM_Parser_ProcessPrediction returns the full physical-injection record —
; deletes / to_type / nw. `to_type` is deliberately NOT the whole prediction: it
; is only the suffix that survives after `deletes` characters have been erased.
; LLM_Parser_ParseResponse then collapsed that record to a bare `to_type` string,
; and from there the deletion count did not exist anywhere in this driver:
; LLM_Bridge_OnAccept typed the text with no erase step.
;
; ROOT CAUSE ENCODED: accepting an "advanced"-profile correction therefore
; APPENDED the fix to the very characters it was meant to replace —
; "Je vous envoit" + "e ce mail" comes out as "Je vous envoite ce mail". The
; corpus already pins those numbers row by row, which is what made the value look
; covered: the parser was tested, the consumer never was.
;
; The first repair refused every such correction, until the accept path could
; erase. It can since rewrites: a slot that names the text it erases has it
; erased inside the same admission-guarded output as the replacement, and only
; while that text still ends what was typed. The refusal had stayed for
; ordinary corrections, so the advanced prompt never fixed a typo on Windows.
; Every erase-bearing prediction now names its erasure, rewrite or not
; (test_llm_prompt_prediction.ahk drives both end to end); what is still refused
; is an erasure that names nothing.
;
; The set of erase-bearing vectors is derived from the shared corpus rather than
; enumerated here, so a new vector joins this test automatically.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================================
; ======================================================================
; ======= 1/ Every erase-bearing corpus vector names its erasure =======
; ======================================================================
; ======================================================================

_LPRD_CorpusPath() {
	return A_ScriptDir . "\..\..\_shared\tests\corpus\llm\process_prediction_vectors.json"
}

_LPRD_EveryEraseBearingVectorNamesItsErasure() {
	Path := _LPRD_CorpusPath()
	Assert(FileExist(Path) != "", "the shared process_prediction corpus must be readable: " . Path)
	Data := JsonParse(FileRead(Path, "UTF-8"))

	Checked := 0
	for Vec in Data["vectors"] {
		Expd := Vec["expected"]
		if Expd["is_nil"]
			continue
		if (Expd["deletes"] <= 0)
			continue
		if _LPRD_IsRewriteVector(Vec)
			continue
		Checked += 1

		; The count is the shared parser's, vector by vector.
		Pred := LLM_Parser_ProcessPrediction(Vec["full_text"], Vec["tail_text"],
			Vec["block"], Vec["min_words"], Vec["max_words"])
		AssertTrue(Pred is Map, "vector " . Vec["id"] . ": the record must be produced")
		AssertEqual(Expd["deletes"], Pred["deletes"],
			"vector " . Vec["id"] . ": the parser must keep counting the characters to erase")

		; The slot is offered WITH the erasure, and the erasure is exact: the
		; erased text ends the span, and the span ends the context. Offered
		; without it, to_type would be appended to the typo it replaces
		; (llm-parser-deletes-never-applied).
		Slots := LLM_Parser_ParseResponse(Vec["block"], Vec["full_text"], Vec["tail_text"],
			Vec["min_words"], Vec["max_words"], false, 1, , &Edits)
		AssertEqual(1, Slots.Length,
			"vector " . Vec["id"] . ": a correction needing an erasure must be offered (llm-correction-erases)")
		if (Slots.Length != 1)
			continue
		AssertEqual(Expd["to_type"], Slots[1], "vector " . Vec["id"] . ": the slot types to_type")
		AssertTrue(Edits.Has(Slots[1]), "vector " . Vec["id"] . ": the slot carries its erasure")
		if !Edits.Has(Slots[1])
			continue
		Edit := Edits[Slots[1]]
		AssertEqual(Expd["deletes"], Edit["deletes"], "vector " . Vec["id"] . ": Backspaces to send")
		AssertFalse(Edit["rewrite"], "vector " . Vec["id"] . ": a correction is not a rewrite")
		Span := Edit["span"]
		Full := Vec["full_text"]
		AssertEqual(Span, SubStr(Full, StrLen(Full) - StrLen(Span) + 1),
			"vector " . Vec["id"] . ": the span is the end of the context")
		AssertEqual(Edit["deleted_text"],
			SubStr(Span, StrLen(Span) - StrLen(Edit["deleted_text"]) + 1),
			"vector " . Vec["id"] . ": the erased text is the end of the span")
	}

	Assert(Checked >= 3,
		"the corpus must still carry erase-bearing vectors for this test to assert anything (found " . Checked . ") — if they were removed, restore them rather than lowering this floor")
}
Test("LLM parser: a prediction that needs an erasure names the exact text it erases",
	_LPRD_EveryEraseBearingVectorNamesItsErasure)





; ==================================================
; ==================================================
; ======= 2/ Plain completions are untouched =======
; ==================================================
; ==================================================

; The refusal must be surgical. A filter that dropped everything would satisfy
; section 1 while silently disabling predictions altogether.
_LPRD_ZeroDeleteVectorsStillProduceSlots() {
	Path := _LPRD_CorpusPath()
	Assert(FileExist(Path) != "", "the shared process_prediction corpus must be readable: " . Path)
	Data := JsonParse(FileRead(Path, "UTF-8"))

	Produced := 0
	for Vec in Data["vectors"] {
		Expd := Vec["expected"]
		if Expd["is_nil"]
			continue
		if (Expd["deletes"] != 0 or Expd["to_type"] == "")
			continue
		Slots := LLM_Parser_ParseResponse(Vec["block"], Vec["full_text"], Vec["tail_text"],
			Vec["min_words"], Vec["max_words"], false, 1)
		if (Slots.Length > 0)
			Produced += 1
	}

	Assert(Produced >= 3,
		"ordinary completions (deletes = 0) must still reach the tooltip — only " . Produced . " vector(s) survived, which means the refusal is dropping predictions it was never meant to touch")
}
Test("LLM parser: ordinary completions still produce slots after the refusal",
	_LPRD_ZeroDeleteVectorsStillProduceSlots)





; ==================================================================
; ==================================================================
; ======= 3/ A rewrite reaches the tooltip with its erasure ========
; ==================================================================
; ==================================================================

; Whether a corpus vector exercises the rewrite mode of the shared parser.
_LPRD_IsRewriteVector(Vec) {
	return InStr(_LLM_Parser_CleanModelOutput(Vec["block"]), "REWRITE:", true) > 0
}

_LPRD_RewriteVectorsBecomeSlotsWithTheirErasure() {
	Path := _LPRD_CorpusPath()
	Assert(FileExist(Path) != "", "the shared process_prediction corpus must be readable: " . Path)
	Data := JsonParse(FileRead(Path, "UTF-8"))

	Checked := 0
	for Vec in Data["vectors"] {
		if !_LPRD_IsRewriteVector(Vec)
			continue
		Expd := Vec["expected"]
		Slots := LLM_Parser_ParseResponse(Vec["block"], Vec["full_text"], Vec["tail_text"],
			Vec["min_words"], Vec["max_words"], false, 1, , &Edits)
		if Expd["is_nil"] {
			AssertEqual(0, Slots.Length, "vector " . Vec["id"] . ": a refused rewrite offers nothing")
			continue
		}
		Checked += 1
		AssertEqual(1, Slots.Length, "vector " . Vec["id"] . ": a rewrite becomes a tooltip slot")
		AssertEqual(Expd["to_type"], Slots[1], "vector " . Vec["id"] . ": the slot types to_type")
		AssertTrue(Edits.Has(Slots[1]), "vector " . Vec["id"] . ": the slot carries its erasure")
		Edit := Edits[Slots[1]]
		AssertEqual(Expd["deletes"], Edit["deletes"], "vector " . Vec["id"] . ": Backspaces to send")
		AssertEqual(Vec["tail_text"], Edit["span"], "vector " . Vec["id"] . ": the span it rewrites")
		Span := Edit["span"]
		AssertEqual(Edit["deleted_text"],
			SubStr(Span, StrLen(Span) - StrLen(Edit["deleted_text"]) + 1),
			"vector " . Vec["id"] . ": the erased text is the end of the span")
	}
	Assert(Checked >= 3,
		"the corpus must carry erase-bearing rewrite vectors (found " . Checked . ")")
}
Test("LLM parser: a rewrite reaches the tooltip with the exact text it erases",
	_LPRD_RewriteVectorsBecomeSlotsWithTheirErasure)
