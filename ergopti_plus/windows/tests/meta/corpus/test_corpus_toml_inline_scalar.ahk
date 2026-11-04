; tests/meta/corpus/test_corpus_toml_inline_scalar.ahk

; ==============================================================================
; MODULE: TOML Inline Scalar Corpus Consumer (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/toml/inline_scalar_vectors.json through the Windows
; prepare step, TOML_BuildConfigDocumentCandidate.
;
; FEATURES & RATIONALE:
; 1. The Windows writer has no source hint step: it proves an inline edit on the
;    parsed document instead of naming the parents a direct write may address. A
;    vector asserting only expect.hint_parents therefore has no Windows entry; those
;    are counted, and the others are replayed for their verdict and their bytes.
; 2. Every replayed case agrees: the shared writer is the reference.
; ==============================================================================

#Requires AutoHotkey v2.0



global _CTIS_VECTOR_COUNT := 50
global _CTIS_HINT_ONLY_COUNT := 12

; None is decided: which rule the drivers share is a maintainer call.
_CTIS_CorpusText() {
	static Text := FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\toml\inline_scalar_vectors.json", "UTF-8")
	return Text
}

_CTIS_Corpus() {
	static Corpus := JsonParse(_CTIS_CorpusText())
	return Corpus
}

_CTIS_TypedCorpus() {
	static Corpus := _TCV_ParseTyped(_CTIS_CorpusText())
	return Corpus
}

_CTIS_Difference(Vector, Typed) {
	Expect := Vector["expect"]
	Rows := _TCV_Rows(Vector["rows"], Typed["rows"])
	Refused := "", Content := ""
	try Content := TOML_BuildConfigDocumentCandidate(Vector["source"], Rows, [])["content"]
	catch Error as Err
		Refused := Err.Message
	if !Expect["ok"]
		return Refused != "" ? "" : "the batch must be refused, the writer accepted it"
	if Refused != ""
		return "the batch must be accepted, the writer refused: " . Refused
	Difference := _TCV_CandidateDifference(Content, Vector["source"], Expect, Typed["expect"])
	if Difference != "" || !Expect.Has("idempotent") || !Expect["idempotent"]
		return Difference
	Again := TOML_BuildConfigDocumentCandidate(Content, Rows, [])["content"]
	return Again == Content ? "" : "preparing the rows again changed the candidate: " . Again
}

_CTIS_Replay(Vector, Typed) {
	AssertEqual("", _CTIS_Difference(Vector, Typed), Vector["id"])
}

_CTIS_InventoryIsCurrent() {
	global _CTIS_VECTOR_COUNT, _CTIS_HINT_ONLY_COUNT
	Vectors := _CTIS_Corpus()["vectors"]
	AssertEqual(_CTIS_VECTOR_COUNT, Vectors.Length, "inline_scalar_vectors.json changed size")
	HintOnly := 0
	for Vector in Vectors
		HintOnly += Vector["expect"].Has("ok") ? 0 : 1
	AssertEqual(_CTIS_HINT_ONLY_COUNT, HintOnly, "the vectors without a Windows entry changed")
}
Test("toml inline scalar corpus: the counts are current", _CTIS_InventoryIsCurrent)

_CTIS_Register() {
	Typed := _CTIS_TypedCorpus()["vectors"]
	for Index, Vector in _CTIS_Corpus()["vectors"]
		if Vector["expect"].Has("ok")
			Test("toml inline scalar corpus: " . Vector["id"], _CTIS_Replay.Bind(Vector, Typed[Index]))
}
_CTIS_Register()
