; static/ergopti_plus/windows/tests/unit/test_llm_parser.ahk

; ==============================================================================
; MODULE: LLM Parser Tests (AHK)
; DESCRIPTION:
; Unit + regression tests for modules/llm/parser.ahk — the AHK port of the
; shared semantic-diff parser (process_prediction). This file also closes a
; coverage gap: LLM_Parser_ProcessPrediction was not exercised by any suite
; before, which let a crashing bug in its Levenshtein helper survive unnoticed.
;
; The headline regression: _LLM_Parser_CharLev indexed its DP rows from 0
; (prev[0] / curr[0]), but AHK arrays are 1-based and reject index 0, so the
; helper threw "Invalid index" on every call where both strings were non-empty.
; That call sits in the stale-buffer guard of every advanced-format prediction,
; so EVERY TAIL_CORRECTED/NEXT_WORDS prediction with a non-empty buffer tail
; threw. The bug was found by the cross-driver parity probe against the shared
; Lua oracle (tests/bench_parity_process_prediction.ahk).
; ==============================================================================




; =======================================================
; ===== 1) Levenshtein helper (_LLM_Parser_CharLev) =====
; =======================================================

TestLLMParser_CharLevIdentical() {
	AssertEqual(0, _LLM_Parser_CharLev("abc", "abc"),
		"identical strings have distance 0")
}
Test("LLM CharLev: identical strings -> 0", TestLLMParser_CharLevIdentical)

TestLLMParser_CharLevEmpty() {
	AssertEqual(3, _LLM_Parser_CharLev("", "abc"), "empty vs 'abc' -> 3 insertions")
	AssertEqual(3, _LLM_Parser_CharLev("abc", ""), "'abc' vs empty -> 3 deletions")
}
Test("LLM CharLev: empty operand -> length of the other", TestLLMParser_CharLevEmpty)

TestLLMParser_CharLevSingleSub() {
	; A single substitution — this is exactly the non-empty/non-empty case that
	; used to throw "Invalid index" before the 1-based rewrite.
	AssertEqual(1, _LLM_Parser_CharLev("ab", "ac"), "one substitution -> 1")
	AssertEqual(1, _LLM_Parser_CharLev("envoit", "envoie"), "t -> e is one edit")
}
Test("LLM CharLev: single substitution -> 1 (was the crashing case)",
	TestLLMParser_CharLevSingleSub)

TestLLMParser_CharLevClassicVectors() {
	; Canonical Levenshtein reference values — also pin that `a` is indexed by the
	; OUTER loop variable (the old port indexed it by the inner one, so the cost
	; matrix compared the wrong characters even when it did not crash).
	AssertEqual(3, _LLM_Parser_CharLev("kitten", "sitting"), "kitten/sitting -> 3")
	AssertEqual(2, _LLM_Parser_CharLev("ab", "ba"), "ab/ba -> 2 substitutions")
	AssertEqual(2, _LLM_Parser_CharLev("flaw", "lawn"), "flaw/lawn -> 2")
}
Test("LLM CharLev: classic reference distances", TestLLMParser_CharLevClassicVectors)




; ==========================================================
; ===== 2) Advanced-format prediction no longer throws =====
; ==========================================================

TestLLMParser_AdvancedDoesNotThrow() {
	; Regression for the CharLev "Invalid index" crash: an advanced block with a
	; non-empty buffer tail (so the stale-buffer guard runs CharLev) must parse to
	; a prediction Map instead of throwing.
	pred := LLM_Parser_ProcessPrediction("bonjour messieu", "bonjour messieu",
		"TAIL_CORRECTED: bonjour messieurs`nNEXT_WORDS: ravi", 1, 15)
	AssertTrue(pred is Map,
		"an advanced-format prediction must return a Map, not throw 'Invalid index'")
	AssertTrue(pred.Has("to_type") and pred["to_type"] != "",
		"the parsed prediction must carry a non-empty to_type")
}
Test("LLM parser: advanced-format prediction parses without throwing",
	TestLLMParser_AdvancedDoesNotThrow)

TestLLMParser_StaleBufferDiscarded() {
	; The stale-buffer guard itself must still work: when the corrected tail's last
	; word is fully disjoint from the buffer's last word, the prediction is dropped
	; (returns "" — a stale LLM snapshot). This exercises CharLev returning max_len.
	pred := LLM_Parser_ProcessPrediction("hello world", "hello world",
		"TAIL_CORRECTED: hello zzzzz`nNEXT_WORDS: there", 1, 15)
	AssertTrue(!(pred is Map),
		"a fully-disjoint corrected last word marks a stale snapshot and is discarded")
}
Test("LLM parser: stale-buffer guard discards a disjoint correction",
	TestLLMParser_StaleBufferDiscarded)




; ==============================================================
; ===== 3) Cross-driver parity corpus (process_prediction) =====
; ==============================================================
; The corpus is generated from the SHARED Lua parser (the canonical oracle, via
; tools/build/gen-process-prediction-corpus.lua). Asserting the AHK port matches
; it row-by-row pins macOS ≡ AHK for the physical injection contract — deletes /
; to_type / nw / has_corrections / disable_bold. The `chunks` field is display-only
; and computed differently per driver, so it is excluded from the contract.

_LLMPP_IsNil(Pred) {
	if !IsObject(Pred)
		return true
	if (Pred is Map)
		return Pred.Count == 0
	return false
}

_LLMPP_RunVector(Vec) {
	Expd := Vec["expected"]
	Pred := LLM_Parser_ProcessPrediction(Vec["full_text"], Vec["tail_text"],
		Vec["block"], Vec["min_words"], Vec["max_words"])
	if Expd["is_nil"] {
		AssertTrue(_LLMPP_IsNil(Pred),
			"vector " . Vec["id"] . ": expected no prediction (nil)")
		return
	}
	AssertTrue(!_LLMPP_IsNil(Pred), "vector " . Vec["id"] . ": expected a prediction")
	AssertEqual(Expd["deletes"], Pred["deletes"], "vector " . Vec["id"] . ": deletes")
	AssertEqual(Expd["to_type"], Pred["to_type"], "vector " . Vec["id"] . ": to_type")
	AssertEqual(Expd["nw"], Pred["nw"], "vector " . Vec["id"] . ": nw")
	; Normalise booleans (the parser may yield 0/1 or true/false).
	AssertEqual(Expd["has_corrections"] ? true : false, Pred["has_corrections"] ? true : false,
		"vector " . Vec["id"] . ": has_corrections")
	AssertEqual(Expd["disable_bold"] ? true : false, Pred["disable_bold"] ? true : false,
		"vector " . Vec["id"] . ": disable_bold")
}

_LLMPP_RegisterCorpus() {
	CorpusPath := A_ScriptDir . "\..\..\_shared\tests\corpus\llm\process_prediction_vectors.json"
	if !FileExist(CorpusPath) {
		Test("LLM process_prediction corpus: file exists",
			() => AssertTrue(false, "corpus not found: " . CorpusPath))
		return
	}
	Data := JsonParse(FileRead(CorpusPath, "UTF-8"))
	for Vec in Data["vectors"] {
		; .Bind, never an inline fat-arrow over a loop-scoped copy — see
		; project_ahk_loop_capture_copy_freezes_nothing.
		Test("LLM pp-parity [" . Vec["id"] . "]", _LLMPP_RunVector.Bind(Vec))
	}
}
_LLMPP_RegisterCorpus()

/**
 * Exercises complete-word overlap through both parsing and injectable slot output.
 * @param {String} Tail Current complete word.
 * @param {String} NextWord First word returned by the model.
 * @param {String} Expected Exact downstream insertion.
 */
_LLMPP_UnicodeWordOverlap(Tail, NextWord, Expected) {
	Buffer := "hello " . Tail
	Block := "TAIL_CORRECTED: " . Buffer . "`nNEXT_WORDS: " . NextWord . " tomorrow"
	Prediction := LLM_Parser_ProcessPrediction(Buffer, Buffer, Block, 1, 0)
	AssertTrue(Prediction is Map, "valid whole-word Unicode output must produce a prediction")
	AssertEqual(0, Prediction["deletes"], "word overlap must not erase the existing buffer")
	AssertEqual(Expected, Prediction["to_type"], "only complete repeated words may disappear")
	Slots := LLM_Parser_ParseResponse(Block, Buffer, Buffer, 1, 0, false, 1)
	AssertEqual(1, Slots.Length, "the production response path must retain the injectable slot")
	AssertEqual(Expected, Slots[1], "the real Windows response path must preserve exact physical output")
}

_LLMPP_RegisterUnicodeWordOverlap() {
	for Pair in [["café", "caféine", " caféine tomorrow"], ["thé", "théâtre", " théâtre tomorrow"],
		["tea", "theatre", " theatre tomorrow"], ["tea", "tea", " tomorrow"],
		["café", "café", " tomorrow"], ["é", "é", " tomorrow"], ["漢", "漢", " tomorrow"]] {
		Test("LLM Unicode overlap " . Pair[1] . " -> " . Pair[2] . " (unicode-word-overlap)",
			_LLMPP_UnicodeWordOverlap.Bind(Pair[1], Pair[2], Pair[3]))
	}
}
_LLMPP_RegisterUnicodeWordOverlap()

TestLLMParser_RawSeparatorParity(tail, block, expected) {
	pred := LLM_Parser_ProcessPrediction(tail, tail, block, 1, 0)
	AssertTrue(pred is Map, "raw completion must produce a prediction")
	AssertEqual(0, pred["deletes"], "a raw completion never deletes the input tail")
	AssertEqual(expected, pred["to_type"], "physical insertion must preserve its separator")
	AssertEqual(expected, pred["nw"], "raw next-word metadata must match the physical insertion")
}
Test("LLM raw separator parity: joins adjacent ASCII words",
	TestLLMParser_RawSeparatorParity.Bind("hello", "world", " world"))
Test("LLM raw separator parity: preserves an already-separated ASCII tail",
	TestLLMParser_RawSeparatorParity.Bind("hello ", "world", "world"))
Test("LLM raw separator parity: does not separate an apostrophe suffix",
	TestLLMParser_RawSeparatorParity.Bind("l'", "arbre", "arbre"))
