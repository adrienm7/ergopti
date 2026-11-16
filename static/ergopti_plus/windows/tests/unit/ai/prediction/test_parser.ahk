; static/ergopti_plus/windows/tests/unit/ai/prediction/test_parser.ahk

; ==============================================================================
; MODULE: LLM Parser Tests (AHK)
; DESCRIPTION:
; Unit + regression tests for ai/engine/api/parser.ahk — the AHK port of the
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

; An incomplete reasoning block must never become a selectable prediction.
TestLLMParser_UnfinishedThinking() {
	AssertEqual("answer ", LLM_Parser_StripThinking("answer <THINK>private`nreasoning"))
	AssertEqual("answer ", LLM_Parser_StripThinking("<think>old</think>answer <thinking>private"))
	AssertEqual("answer", LLM_Parser_StripThinking("<thinking>private</thinking>answer"))
	AssertEqual("answer ", LLM_Parser_StripThinking("answer <thi", true))
	AssertEqual("answer ", LLM_Parser_StripThinking("answer <THINK", true))
	AssertEqual(0, LLM_Parser_ParseResponse("<think>private", "", "", 1, 0, false, 1).Length)
	AssertEqual(0, LLM_Parser_ParseResponse("<thinking>private", "", "", 1, 0, true, 2).Length)
}
Test("LLM parser: unfinished thinking stays private (llm-truncated-thinking)", TestLLMParser_UnfinishedThinking)

TestLLMParser_ResourcePolicy() {
	global _SharedDir
	Limits := JsonParse(FSReadStrict(_SharedDir . "\ai\data\parser_limits.json"))
	Small := "hello"
	AtBytes := Limits["max_operand_bytes"]
	Long := ""
	Loop AtBytes
		Long .= "a"
	AssertTrue(_LLM_Parser_DiffWithinLimits("", Long), "the operand byte limit is inclusive")
	AssertFalse(_LLM_Parser_DiffWithinLimits("", Long . "a"), "one more byte is refused before tokenization")
	Row := Floor(Sqrt(Limits["max_grid_cells"])) - 1
	Square := ""
	Loop Row
		Square .= "b"
	AssertTrue(_LLM_Parser_DiffWithinLimits(Square, Square), "a grid at the inclusive cell bound is admitted")
	AssertFalse(_LLM_Parser_DiffWithinLimits(Square . "b", Square), "a grid above the cell bound is refused")
	Utf8 := ""
	Loop AtBytes // 2
		Utf8 .= "é"
	AssertTrue(_LLM_Parser_DiffWithinLimits("", Utf8), "byte accounting admits complete multibyte text at the limit")
	AssertFalse(_LLM_Parser_DiffWithinLimits("", Utf8 . "é"), "the canonical byte limit is independent of UTF-16 units")
	Original := ""
	Loop 500
		Original .= "a"
	Corrected := ""
	Loop 8000
		Corrected .= "a"
	Prediction := LLM_Parser_ProcessPrediction(Original, Original,
		"TAIL_CORRECTED: " . Corrected . "`nNEXT_WORDS: suite", 1, 15)
	AssertFalse(Prediction is Map, "one oversized model word must be refused instead of entering quadratic DP")
	AssertFalse(LLM_Parser_ProcessPrediction("hello", "hello",
		"TAIL_CORRECTED: hello`nNEXT_WORDS: " . Corrected, 1, 15) is Map,
		"next words cannot bypass the same resource admission through tokenization")
	AssertFalse(LLM_Parser_ProcessPrediction("hello", "hello", Corrected, 1, 15) is Map,
		"raw mode must refuse oversized text before character-array cleanup")
	Prediction := LLM_Parser_ProcessPrediction("hello", "hello", "REWRITE: " . Corrected, 1, 15)
	AssertFalse(Prediction is Map, "rewrite has the same resource admission as continuation")
	Spaces := ""
	Loop 2048
		Spaces .= " "
	Padded := "a" . SubStr(Spaces, 1, 1024) . "a" . Spaces
	AssertTrue(_LLM_Parser_DiffWithinLimits(Padded, "aa"), "the raw short correction fits the first admission")
	AssertFalse(LLM_Parser_ProcessPrediction(Padded, Padded,
		"TAIL_CORRECTED: aa`nNEXT_WORDS: world", 1, 15) is Map,
		"copied trailing spacing must be re-admitted before the actual diff allocation")
	AssertTrue(LLM_Parser_ProcessPrediction(Small, Small,
		"TAIL_CORRECTED: hello`nNEXT_WORDS: world", 1, 15) is Map, "ordinary continuation remains functional")
}
Test("LLM parser: shared byte and diff work limits refuse oversized model words", TestLLMParser_ResourcePolicy)


_LTPS_Repeat(Text, Count) {
    Out := ""
    loop Count
        Out .= Text
    return Out
}

_LTPS_Observe(Name, Fn, Expected, SourceUnits, Count) {
    Failure := 0, Value := 0
    Started := BootClockWallMs()
    try Value := Fn.Call()
    catch Any as ErrorObject
        Failure := ErrorObject
    Elapsed := BootClockWallMs() - Started
    Row := Map("stage", Name, "count", Count, "source_units", SourceUnits,
        "elapsed_ms", Elapsed, "threw", IsObject(Failure),
        "error_type", IsObject(Failure) ? Type(Failure) : "",
        "error_message", IsObject(Failure) ? SubStr(Failure.Message, 1, 200) : "")
    if Value is String {
        Row["output_units"] := StrLen(Value)
        Row["matches_expected"] := Value == Expected
    } else if Value is Array {
        Row["slots"] := Value.Length
        Row["matches_expected"] := Expected == "" ? Value.Length == 0 : (Value.Length == 1 && Value[1] == Expected)
    } else
        Row["matches_expected"] := false
    return Row
}

_LTPS_Run(Kind, Closed) {
    Open := "<" . Kind . ">", Close := "</" . Kind . ">"
    Rows := []
    ; These sizes characterize native PCRE's actual optimization and exception
    ; behavior. They are well inside the existing HTTP response byte limit.
    for Count in [2000, 4000, 8000] {
        Raw := _LTPS_Repeat(Closed ? Open . "p" . Close : Open, Count) . (Closed ? "answer" : "")
        Expected := Closed ? "answer" : ""
        Pattern := "si)" . Open . ".*?" . Close . "\s*"
        ; The isolated first pass shows whether this PCRE build quickly rejects
        ; an absent closing literal or instead revisits every possible opener.
        Rows.Push(_LTPS_Observe("closed-block-regex", RegExReplace.Bind(Raw, Pattern, ""),
            Closed ? "answer" : Raw, StrLen(Raw), Count))
        Rows.Push(_LTPS_Observe("strip-thinking", LLM_Parser_StripThinking.Bind(Raw), Expected, StrLen(Raw), Count))
        Rows.Push(_LTPS_Observe("parse-response", LLM_Parser_ParseResponse.Bind(Raw, "", "", 1, 0, false, 1),
            Expected, StrLen(Raw), Count))
    }
    _TestPrint("# THINKING_REGEX " . KL_JsonEncode(Map("kind", Kind, "closed", Closed,
        "runtime", A_AhkVersion, "rows", Rows)))
    ; Collect every observation before asserting, so a failing first pass does
    ; not hide the other sizes or the actual full parser's behavior.
    for Row in Rows {
        AssertFalse(Row["threw"], "real thinking processing must not throw on bounded model output: " . Row["stage"])
        AssertTrue(Row["matches_expected"], "complete blocks preserve the answer and unfinished private blocks stay absent: " . Row["stage"])
    }
}
for _LTPS_Kind in ["think", "thinking"] {
    Test("LLM thinking PCRE: closed " . _LTPS_Kind . " control (thinking-regex-resource)", _LTPS_Run.Bind(_LTPS_Kind, true))
    Test("LLM thinking PCRE: repeated unclosed " . _LTPS_Kind . " (thinking-regex-resource)", _LTPS_Run.Bind(_LTPS_Kind, false))
}
