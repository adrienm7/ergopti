; tests/meta/corpus/test_corpus_toml_batch_write.ahk

; ==============================================================================
; MODULE: TOML Batch Writer Corpus Consumer (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/toml/batch_write_vectors.json through the Windows
; prepare step, TOML_BuildConfigDocumentCandidate (source bytes and rows give the
; candidate bytes or a refusal), and decodes the candidate with TOML_ParseDocument
; for the decoded checks.
;
; FEATURES & RATIONALE:
; 1. The refusal detail is the Lua writer's prose and the source-read count its
;    port: the Windows writer has its own wording and takes the source as an
;    argument, so a refusal is compared by verdict only.
; 2. A JSON boolean reaches the writer as a TOML_Bool (support/toml_corpus_values):
;    read as the integer JsonParse answers, it is written and compared as a number.
; 3. Every case agrees: the shared writer is the reference. A vector's expected
;    snapshot is the earlier read the prepare step compares its source with.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Corpus ===================
; =====================================
; =====================================

global _CTBW_VECTOR_COUNT := 144

_CTBW_CorpusText() {
	static Text := FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\toml\batch_write_vectors.json", "UTF-8")
	return Text
}

_CTBW_Corpus() {
	static Corpus := JsonParse(_CTBW_CorpusText())
	return Corpus
}

_CTBW_TypedCorpus() {
	static Corpus := _TCV_ParseTyped(_CTBW_CorpusText())
	return Corpus
}





; =============================
; =============================
; ======= 2/ The replay =======
; =============================
; =============================

; Returns "" when the writer agrees with the vector, else the first difference.
_CTBW_Difference(Vector, Typed) {
	Expect := Vector["expect"]
	Refused := ""
	Content := ""
	try {
		Rows := _TCV_Rows(Vector["rows"], Typed["rows"])
		Candidate := Vector.Has("expected_snapshot")
			? TOML_BuildConfigDocumentCandidate(Vector["source"], Rows, [], Vector["expected_snapshot"]["content"])
			: TOML_BuildConfigDocumentCandidate(Vector["source"], Rows, [])
		Content := Candidate["content"]
	} catch Error as Err {
		Refused := Err.Message
	}
	if !Expect["ok"]
		return Refused != "" ? "" : "the batch must be refused, the writer accepted it"
	if (Refused != "")
		return "the batch must be accepted, the writer refused: " . Refused
	return _TCV_CandidateDifference(Content, Vector["source"], Expect, Typed["expect"])
}

_CTBW_ReplayVector(Vector, Typed) {
	AssertEqual("", _CTBW_Difference(Vector, Typed), Vector["id"])
}





; ============================
; ============================
; ======= 3/ The tests =======
; ============================
; ============================

_CTBW_CountIsCurrent() {
	global _CTBW_VECTOR_COUNT
	AssertEqual(_CTBW_VECTOR_COUNT, _CTBW_Corpus()["vectors"].Length, "batch_write_vectors.json changed size")
}
Test("toml batch write corpus: the count is current", _CTBW_CountIsCurrent)

_CTBW_RegisterVectors() {
	Typed := _CTBW_TypedCorpus()["vectors"]
	for Index, Vector in _CTBW_Corpus()["vectors"]
		Test("toml batch write corpus: " . Vector["id"], _CTBW_ReplayVector.Bind(Vector, Typed[Index]))
}
_CTBW_RegisterVectors()
