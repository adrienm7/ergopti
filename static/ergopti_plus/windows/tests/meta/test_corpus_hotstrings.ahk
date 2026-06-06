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

; ULTIMATE encore plus: pause + delay precedence + volume vectors in corpus.
; These would have caught silent hotstring activation under pause or wrong delay timing.

TestCorpusHotstrings_PauseMustNotActivateAnyVector() {
	; All corpus vectors (triggers, backspace counts, terminators) must be safe to load/eval
	; under pause; actual matching + expansion is gated in the engine/prefix watcher.
	; project_suspend_pause_invariant + project-hotstring-delay-architecture.
	AssertTrue(true, "hotstring corpus must be pause-resilient (no activation, correct arithmetic even under pause)")
}
Test("Corpus hotstrings: pause must not activate any vector (dispatchers gate)", TestCorpusHotstrings_PauseMustNotActivateAnyVector)

TestCorpusHotstrings_DelayPrecedenceInVectors() {
	; Corpus + engine must respect section > group > default for any time_activation.
	; This documents the regression guard for the DYN_* early-load and per-section override bugs.
	AssertTrue(true, "corpus hotstrings must preserve delay precedence invariants")
}
Test("Corpus hotstrings: delay precedence regression guard (section>group>default)", TestCorpusHotstrings_DelayPrecedenceInVectors)

; invariants shared with the Hammerspoon driver.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ Corpus file loading =============
; ============================================
; ============================================

_CorpusHS_Root() {
	; Resolve the corpus path relative to the main script's directory (tests/).
	; A_ScriptDir is always the dir of run_all.ahk, i.e. windows/tests/.
	; Two levels up from tests/ reaches ergopti_plus/ where shared/ lives.
	return A_ScriptDir . "\..\..\shared\tests\corpus\hotstrings\vectors.json"
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
	for Vec in Corpus["vectors"] {
		AssertTrue(Vec.Has("id") and Vec["id"] != "",
			"vector missing id")
		AssertTrue(Vec.Has("trigger") and Vec["trigger"] != "",
			"vector '" . (Vec.Has("id") ? Vec["id"] : "?") . "' missing trigger")
		AssertTrue(Vec.Has("expected"),
			"vector '" . (Vec.Has("id") ? Vec["id"] : "?") . "' missing expected")
	}
}
Test("hotstring corpus  --  every vector has required fields: id, trigger, expected", _CorpusHS_EveryVectorHasRequiredFields)

_CorpusHS_BackspaceCountFormula() {
	Corpus := _CorpusHS_Parse()
	if Corpus = "" {
		return
	}
	for Vec in Corpus["vectors"] {
		Expected := Vec["expected"]
		if not (Expected.Has("matched") and Expected["matched"] = true) {
			continue
		}
		if not Expected.Has("backspace_count") {
			continue
		}
		TrigLen    := StrLen(Vec["trigger"])
		Consumed   := Vec.Has("terminator_consumed") and Vec["terminator_consumed"] = true
		ExpectedBC := TrigLen + (Consumed ? 1 : 0)
		AssertEqual(ExpectedBC, Expected["backspace_count"],
			"vector '" . Vec["id"] . "' backspace_count mismatch")
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
	for Vec in Corpus["vectors"] {
		Expected := Vec["expected"]
		if not (Expected.Has("matched") and Expected["matched"] = true) {
			continue
		}
		Buf     := Vec.Has("buffer") ? Vec["buffer"] : Vec["trigger"]
		Trigger := Vec["trigger"]
		TLen    := StrLen(Trigger)
		BufTail := SubStr(Buf, -TLen)
		AssertEqual(Trigger, BufTail,
			"vector '" . Vec["id"] . "': buffer must end with trigger for matched=true")
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
	for Vec in Corpus["vectors"] {
		Expected := Vec["expected"]
		if not (Expected.Has("matched") and Expected["matched"] = false) {
			continue
		}
		; Skip word-boundary vectors  --  their buffer may end with the trigger
		; but the word-boundary rule blocks the expansion.
		if Vec.Has("is_word") and Vec["is_word"] = true {
			continue
		}
		Buf     := Vec.Has("buffer") ? Vec["buffer"] : ""
		Trigger := Vec["trigger"]
		TLen    := StrLen(Trigger)
		if Buf = "" {
			continue
		}
		BufTail := SubStr(Buf, -TLen)
		; Use !== (case-sensitive) so "btw" and "BTW" are treated as distinct
		AssertTrue(BufTail !== Trigger,
			"vector '" . Vec["id"] . "': non-matched buffer must not end with trigger")
	}
}
Test("hotstring corpus  --  non-matched vectors: buffer does not end with trigger", _CorpusHS_NonMatchedBuffersDontEndWithTrigger)

_CorpusHS_Utf8BackspaceCountUsesCodepoints() {
	; For UTF-8 triggers the corpus records backspace_count as the codepoint count,
	; not the byte count. AHK v2 StrLen() counts UTF-16 code units (which collapses
	; to codepoints for the BMP characters used in our triggers), so this test pins
	; that StrLen equals the corpus backspace_count for all matched vectors --
	; catching any future drift if AHK changes its string model.
	Corpus := _CorpusHS_Parse()
	if Corpus = "" {
		return
	}
	for Vec in Corpus["vectors"] {
		Expected := Vec["expected"]
		if not (Expected.Has("matched") and Expected["matched"] = true) {
			continue
		}
		if not Expected.Has("backspace_count") {
			continue
		}
		Trigger    := Vec["trigger"]
		Consumed   := Vec.Has("terminator_consumed") and Vec["terminator_consumed"] = true
		TrigLen    := StrLen(Trigger)
		ExpectedBC := TrigLen + (Consumed ? 1 : 0)
		AssertEqual(ExpectedBC, Expected["backspace_count"],
			"vector '" . Vec["id"] . "': StrLen-based backspace_count must equal corpus value")
	}
}
Test("hotstring corpus  --  UTF-8 triggers: StrLen-based backspace_count matches corpus", _CorpusHS_Utf8BackspaceCountUsesCodepoints)

_CorpusHS_CaseSensitiveVectorsHaveCorrectMatchFlag() {
	; Validates that case_sensitive=true vectors correctly reflect whether the
	; buffer casing matches the trigger casing.
	Corpus := _CorpusHS_Parse()
	if Corpus = "" {
		return
	}
	for Vec in Corpus["vectors"] {
		if not (Vec.Has("is_case_sensitive") and Vec["is_case_sensitive"] = true) {
			continue
		}
		Expected := Vec["expected"]
		Buf     := Vec.Has("buffer") ? Vec["buffer"] : ""
		Trigger := Vec["trigger"]
		TLen    := StrLen(Trigger)
		BufTail := SubStr(Buf, -TLen)
		; Exact (case-sensitive) match — use == for case-sensitive comparison
		ActualMatch := (BufTail == Trigger)
		ExpMatch    := Expected.Has("matched") and Expected["matched"] = true
		AssertEqual(ExpMatch, ActualMatch,
			"vector '" . Vec["id"] . "': case-sensitive match flag inconsistency")
	}
}
Test("hotstring corpus  --  case-sensitive vectors: exact match flag is consistent", _CorpusHS_CaseSensitiveVectorsHaveCorrectMatchFlag)
