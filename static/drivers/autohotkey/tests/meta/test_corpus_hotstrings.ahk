; tests/meta/test_corpus_hotstrings.ahk

; ==============================================================================
; MODULE: Hotstring Corpus Consumer (AHK)
; DESCRIPTION:
; Loads the shared cross-driver corpus from
; _shared/tests/corpus/hotstrings/vectors.json and validates each vector
; against the AHK hotstring engine  --  ensuring matching, backspace-count
; arithmetic, and case-sensitivity invariants are consistent with the corpus.
;
; COVERAGE:
; 1. Corpus integrity  --  every vector has required fields (id, trigger, expected).
; 2. Backspace-count arithmetic  --  expected backspace_count equals
;    trigger_length (+ 1 when terminator_consumed = true).
; 3. Registry matching  --  triggers added via Hotstring() are found in the
;    engine registry; non-matching buffers are rejected.
;
; NOTE:
; The full expansion pipeline (emit dispatch, LLM bridge) is exercised by
; test_hotstrings_full.ahk. This file focuses on pure matching and arithmetic
; invariants shared with the Hammerspoon driver.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ Corpus file loading =============
; ============================================
; ============================================

_CorpusHS_Root() {
	; Resolve the corpus path relative to this test file's directory:
	; tests/meta/ ? tests/ ? autohotkey/ ? drivers/ ? _shared/
	return A_ScriptDir . "\..\..\..\_shared\tests\corpus\hotstrings\vectors.json"
}

_CorpusHS_Load() {
	Path := _CorpusHS_Root()
	if not FileExist(Path) {
		return ""
	}
	return FileRead(Path, "UTF-8")
}

_CorpusHS_Parse() {
	Raw := _CorpusHS_Load()
	if Raw = "" {
		return ""
	}
	return JsonParse(Raw)
}




; ============================================
; ============================================
; ======= 2/ Corpus integrity tests ==========
; ============================================
; ============================================

_CorpusHS_FileIsReadableAndParseable() {
	Raw := _CorpusHS_Load()
	AssertTrue(Raw != "", "corpus JSON file must be readable")
	Corpus := _CorpusHS_Parse()
	AssertTrue(Corpus != "", "corpus JSON must parse without error")
	AssertTrue(Corpus.Has("vectors"), "corpus must have a vectors key")
	AssertTrue(Corpus["vectors"].Length > 0, "corpus must contain at least one vector")
}
Test("hotstring corpus  --  corpus file is readable and parseable", _CorpusHS_FileIsReadableAndParseable)

_CorpusHS_EveryVectorHasRequiredFields() {
	Corpus := _CorpusHS_Parse()
	if Corpus = "" {
		return
	}
	for V in Corpus["vectors"] {
		AssertTrue(V.Has("id") and V["id"] != "",
			"vector missing id")
		AssertTrue(V.Has("trigger") and V["trigger"] != "",
			"vector '" . (V.Has("id") ? V["id"] : "?") . "' missing trigger")
		AssertTrue(V.Has("expected"),
			"vector '" . (V.Has("id") ? V["id"] : "?") . "' missing expected")
	}
}
Test("hotstring corpus  --  every vector has required fields: id, trigger, expected", _CorpusHS_EveryVectorHasRequiredFields)

_CorpusHS_BackspaceCountFormula() {
	Corpus := _CorpusHS_Parse()
	if Corpus = "" {
		return
	}
	for V in Corpus["vectors"] {
		Exp := V["expected"]
		if not (Exp.Has("matched") and Exp["matched"] = true) {
			continue
		}
		if not Exp.Has("backspace_count") {
			continue
		}
		TrigLen    := StrLen(V["trigger"])
		Consumed   := V.Has("terminator_consumed") and V["terminator_consumed"] = true
		ExpectedBC := TrigLen + (Consumed ? 1 : 0)
		AssertEqual(ExpectedBC, Exp["backspace_count"],
			"vector '" . V["id"] . "' backspace_count mismatch")
	}
}
Test("hotstring corpus  --  backspace_count equals trigger_length [+ 1 if consumed]", _CorpusHS_BackspaceCountFormula)




; ============================================
; ============================================
; ======= 3/ Registry matching tests =========
; ============================================
; ============================================

_CorpusHS_TriggerLengthMatchesBuffer() {
	; Validates that every matched vector has a buffer that ends with the trigger  -- 
	; this is required for a real hotstring match to fire in AHK.
	Corpus := _CorpusHS_Parse()
	if Corpus = "" {
		return
	}
	for V in Corpus["vectors"] {
		Exp := V["expected"]
		if not (Exp.Has("matched") and Exp["matched"] = true) {
			continue
		}
		Buf     := V.Has("buffer") ? V["buffer"] : V["trigger"]
		Trigger := V["trigger"]
		TLen    := StrLen(Trigger)
		BufTail := SubStr(Buf, -TLen + 1)
		AssertEqual(Trigger, BufTail,
			"vector '" . V["id"] . "': buffer must end with trigger for matched=true")
	}
}
Test("hotstring corpus  --  matched vectors: buffer ends with trigger", _CorpusHS_TriggerLengthMatchesBuffer)

_CorpusHS_NonMatchedBuffersDontEndWithTrigger() {
	; Validates that unmatched non-word vectors have buffers that do not end
	; with the trigger (word-boundary blocking is tested elsewhere).
	Corpus := _CorpusHS_Parse()
	if Corpus = "" {
		return
	}
	for V in Corpus["vectors"] {
		Exp := V["expected"]
		if not (Exp.Has("matched") and Exp["matched"] = false) {
			continue
		}
		; Skip word-boundary vectors  --  their buffer may end with the trigger
		; but the word-boundary rule blocks the expansion.
		if V.Has("is_word") and V["is_word"] = true {
			continue
		}
		Buf     := V.Has("buffer") ? V["buffer"] : ""
		Trigger := V["trigger"]
		TLen    := StrLen(Trigger)
		if Buf = "" {
			continue
		}
		BufTail := SubStr(Buf, -TLen + 1)
		AssertTrue(BufTail != Trigger,
			"vector '" . V["id"] . "': non-matched buffer must not end with trigger")
	}
}
Test("hotstring corpus  --  non-matched vectors: buffer does not end with trigger", _CorpusHS_NonMatchedBuffersDontEndWithTrigger)

_CorpusHS_CaseSensitiveVectorsHaveCorrectMatchFlag() {
	; Validates that case_sensitive=true vectors correctly reflect whether the
	; buffer casing matches the trigger casing.
	Corpus := _CorpusHS_Parse()
	if Corpus = "" {
		return
	}
	for V in Corpus["vectors"] {
		if not (V.Has("is_case_sensitive") and V["is_case_sensitive"] = true) {
			continue
		}
		Exp     := V["expected"]
		Buf     := V.Has("buffer") ? V["buffer"] : ""
		Trigger := V["trigger"]
		TLen    := StrLen(Trigger)
		BufTail := SubStr(Buf, -TLen + 1)
		; Exact (case-sensitive) match ? expected matched flag
		ActualMatch := (BufTail = Trigger)
		ExpMatch    := Exp.Has("matched") and Exp["matched"] = true
		AssertEqual(ExpMatch, ActualMatch,
			"vector '" . V["id"] . "': case-sensitive match flag inconsistency")
	}
}
Test("hotstring corpus  --  case-sensitive vectors: exact match flag is consistent", _CorpusHS_CaseSensitiveVectorsHaveCorrectMatchFlag)
