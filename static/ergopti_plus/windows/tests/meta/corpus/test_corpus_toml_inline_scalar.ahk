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
; 2. Every replayed case agrees or is pinned in _CTIS_PENDING with its reason.
; ==============================================================================

#Requires AutoHotkey v2.0



global _CTIS_VECTOR_COUNT := 50
global _CTIS_HINT_ONLY_COUNT := 12

; None is decided: which rule the drivers share is a maintainer call.
global _CTIS_WIDER := "the Windows writer proves the exact semantic result of a new inline member or path the shared writer only hints for a same-shape scalar"
global _CTIS_CASE_TWIN := "Windows row identities are exact: a case twin is a distinct key"
global _CTIS_TOKEN := "the Windows reader decodes only plain decimal integers, so an underscored token reads as a string and a same-value write rewrites it"

global _CTIS_PENDING := Map(
	"empty-literal-identity-stays-on-the-whole-parent-route", _CTIS_WIDER,
	"insertion-refused-through-missing-intermediate-parent", _CTIS_WIDER,
	"insertion-refused-through-new-structured-value", _CTIS_WIDER,
	"insertion-refused-through-literal-dotted-key", _CTIS_WIDER,
	"insertion-refused-through-source-case-twin", _CTIS_CASE_TWIN,
	"insertion-refused-through-dotted-implicit-parent", _CTIS_WIDER,
	"canonical-numeric-token-plus9_007_199_254_740_992", _CTIS_TOKEN,
	"canonical-numeric-token-minus9_007_199_254_740_992", _CTIS_TOKEN)

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
	try Content := _TCV_WithoutAddedBom(TOML_BuildConfigDocumentCandidate(Vector["source"], Rows, [])["content"], Vector["source"])
	catch Error as Err
		Refused := Err.Message
	if !Expect["ok"]
		return Refused != "" ? "" : "the batch must be refused, the writer accepted it"
	if Refused != ""
		return "the batch must be accepted, the writer refused: " . Refused
	Difference := _TCV_CandidateDifference(Content, Vector["source"], Expect, Typed["expect"])
	if Difference != "" || !Expect.Has("idempotent") || !Expect["idempotent"]
		return Difference
	Again := _TCV_WithoutAddedBom(TOML_BuildConfigDocumentCandidate(Content, Rows, [])["content"], Content)
	return Again == Content ? "" : "preparing the rows again changed the candidate: " . Again
}

_CTIS_Replay(Vector, Typed) {
	global _CTIS_PENDING
	Difference := _CTIS_Difference(Vector, Typed)
	if _CTIS_PENDING.Has(Vector["id"])
		AssertTrue(Difference != "", Vector["id"] . " now agrees: remove it from _CTIS_PENDING")
	else
		AssertEqual("", Difference, Vector["id"])
}

_CTIS_InventoryIsCurrent() {
	global _CTIS_VECTOR_COUNT, _CTIS_HINT_ONLY_COUNT, _CTIS_PENDING
	Vectors := _CTIS_Corpus()["vectors"]
	AssertEqual(_CTIS_VECTOR_COUNT, Vectors.Length, "inline_scalar_vectors.json changed size")
	HintOnly := 0
	Known := Map()
	for Vector in Vectors {
		Known[Vector["id"]] := true
		HintOnly += Vector["expect"].Has("ok") ? 0 : 1
	}
	AssertEqual(_CTIS_HINT_ONLY_COUNT, HintOnly, "the vectors without a Windows entry changed")
	for Id, Reason in _CTIS_PENDING {
		AssertTrue(Known.Has(Id), "stale pending entry: " . Id)
		AssertTrue(Reason != "", "a pending entry states its reason: " . Id)
	}
}
Test("toml inline scalar corpus: the counts and the pending inventory are current", _CTIS_InventoryIsCurrent)

_CTIS_Register() {
	Typed := _CTIS_TypedCorpus()["vectors"]
	for Index, Vector in _CTIS_Corpus()["vectors"]
		if Vector["expect"].Has("ok")
			Test("toml inline scalar corpus: " . Vector["id"], _CTIS_Replay.Bind(Vector, Typed[Index]))
}
_CTIS_Register()
