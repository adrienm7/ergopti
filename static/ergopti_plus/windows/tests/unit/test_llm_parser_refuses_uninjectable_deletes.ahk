; static/ergopti_plus/windows/tests/unit/test_llm_parser_refuses_uninjectable_deletes.ahk

; ==============================================================================
; MODULE: Regression — a prediction needing an erasure must never reach the
;         tooltip on Windows (llm-parser-deletes-never-applied)
; DESCRIPTION:
; LLM_Parser_ProcessPrediction returns the full physical-injection record —
; deletes / to_type / nw. `to_type` is deliberately NOT the whole prediction: it
; is only the suffix that survives after `deletes` characters have been erased.
; LLM_Parser_ParseResponse then collapsed that record to a bare `to_type` string,
; and from there the deletion count did not exist anywhere in this driver:
; LLM_Bridge_OnAccept types the text with no erase step.
;
; ROOT CAUSE ENCODED: accepting an "advanced"-profile correction therefore
; APPENDED the fix to the very characters it was meant to replace —
; "Je vous envoit" + "e ce mail" comes out as "Je vous envoite ce mail". The
; corpus already pins those numbers row by row, which is what made the value look
; covered: the parser was tested, the consumer never was.
;
; Until the accept path can erase (it lives in modules/keymap/llm_bridge.ahk and
; the tooltip slot layer, neither of which carries the count today), the honest
; behaviour is to REFUSE the suggestion: a missing correction is recoverable by
; hand, a garbled sentence is not. This test pins that refusal AND pins that the
; parser keeps measuring the erasure, so the day the erase step lands the count
; is still there to drive it.
;
; The set of erase-bearing vectors is derived from the shared corpus rather than
; enumerated here, so a new vector joins this test automatically.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================================
; ===============================================================
; ======= 1/ Every erase-bearing corpus vector is refused =======
; ===============================================================
; ===============================================================

_LPRD_CorpusPath() {
	return A_ScriptDir . "\..\..\_shared\tests\corpus\llm\process_prediction_vectors.json"
}

_LPRD_EveryEraseBearingVectorIsRefused() {
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
		Checked += 1

		; The parser must still COUNT the erasure — the fix refuses the prediction,
		; it does not stop measuring it. Losing the measurement would make the
		; eventual erase step unimplementable.
		Pred := LLM_Parser_ProcessPrediction(Vec["full_text"], Vec["tail_text"],
			Vec["block"], Vec["min_words"], Vec["max_words"])
		AssertTrue(Pred is Map, "vector " . Vec["id"] . ": the record must still be produced")
		AssertEqual(Expd["deletes"], Pred["deletes"],
			"vector " . Vec["id"] . ": the parser must keep counting the characters to erase")

		Slots := LLM_Parser_ParseResponse(Vec["block"], Vec["full_text"], Vec["tail_text"],
			Vec["min_words"], Vec["max_words"], false, 1)
		AssertEqual(0, Slots.Length,
			"vector " . Vec["id"] . ": a prediction needing " . Expd["deletes"] . " character(s) erased must not become a tooltip slot. to_type is only the suffix that survives the erasure, and the Windows accept path types without erasing — so offering it appends the fix to the typo and corrupts the user's sentence (llm-parser-deletes-never-applied)")
	}

	Assert(Checked >= 3,
		"the corpus must still carry erase-bearing vectors for this test to assert anything (found " . Checked . ") — if they were removed, restore them rather than lowering this floor")
}
Test("LLM parser: a prediction that needs an erasure is refused, not appended",
	_LPRD_EveryEraseBearingVectorIsRefused)





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
