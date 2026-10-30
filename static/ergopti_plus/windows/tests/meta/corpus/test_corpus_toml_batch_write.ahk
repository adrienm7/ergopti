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
; 3. Every case agrees or is pinned in _CTBW_PENDING with its reason, so a fix
;    forces the inventory to shrink and a new divergence turns the suite red.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Corpus and pending =======
; =====================================
; =====================================

global _CTBW_VECTOR_COUNT := 144

; Why the Windows writer differs, per class. None is decided: which rule the
; drivers share is a maintainer call.
global _CTBW_REFUSES_SCALAR := "the Windows writer refuses a scalar over a retained table: a stale flat row must not destroy a user subtree"
global _CTBW_WIDER := "the Windows writer proves an exact semantic result for a type change, a literal-dot key or a table delete in an inline or dotted owner; the shared writer only hints same-type scalars there"
global _CTBW_CASE_TWIN := "Windows row identities are exact: a case twin is a distinct key the writer edits or creates alone (pinned by test_toml_writer_admission and config-personal-file-case-alias); the shared writer refuses the ambiguity"
global _CTBW_SNAPSHOT := "the Windows prepare step takes the source as an argument and no earlier snapshot, so a stale read cannot reach it"

global _CTBW_PENDING := Map(
	"header-table-descendants-and-interleaved-blocks-replaced-by-scalar", _CTBW_REFUSES_SCALAR,
	"ambiguous-case-folded-or-array-target-1-refused", _CTBW_CASE_TWIN,
	"ambiguous-case-folded-or-array-target-2-refused", _CTBW_CASE_TWIN,
	"root-inline-refused-case-twin-member", _CTBW_CASE_TWIN,
	"root-inline-refused-case-twin-table", _CTBW_CASE_TWIN,
	"section-dotted-safety-refusal-7", _CTBW_CASE_TWIN,
	"section-dotted-safety-refusal-8", _CTBW_CASE_TWIN,
	"inline-table-value-change-names-its-key", _CTBW_WIDER,
	"root-inline-refused-literal-dot-key", _CTBW_WIDER,
	"root-inline-refused-changed-type", _CTBW_WIDER,
	"section-dotted-safety-refusal-1", _CTBW_WIDER,
	"section-dotted-safety-refusal-3", _CTBW_WIDER,
	"section-dotted-safety-refusal-5", _CTBW_WIDER,
	"dotted-stale-snapshot-refused-without-publication", _CTBW_SNAPSHOT,
	"root-changed-source-snapshot-refused", _CTBW_SNAPSHOT,
	"root-inline-stale-source-refused-before-any-edit", _CTBW_SNAPSHOT,
	"section-dotted-stale-source-refused-before-an-owned-scalar", _CTBW_SNAPSHOT)

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
		Candidate := TOML_BuildConfigDocumentCandidate(Vector["source"], _TCV_Rows(Vector["rows"], Typed["rows"]), [])
		Content := _TCV_WithoutAddedBom(Candidate["content"], Vector["source"])
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
	global _CTBW_PENDING
	Difference := _CTBW_Difference(Vector, Typed)
	if _CTBW_PENDING.Has(Vector["id"])
		AssertTrue(Difference != "", Vector["id"] . " now agrees: remove it from _CTBW_PENDING")
	else
		AssertEqual("", Difference, Vector["id"])
}





; ============================
; ============================
; ======= 3/ The tests =======
; ============================
; ============================

_CTBW_CountAndPendingAreCurrent() {
	global _CTBW_VECTOR_COUNT, _CTBW_PENDING
	Vectors := _CTBW_Corpus()["vectors"]
	AssertEqual(_CTBW_VECTOR_COUNT, Vectors.Length, "batch_write_vectors.json changed size")
	Known := Map()
	for Vector in Vectors
		Known[Vector["id"]] := true
	for Id, Reason in _CTBW_PENDING {
		AssertTrue(Known.Has(Id), "stale pending entry: " . Id)
		AssertTrue(Reason != "", "a pending entry states its reason: " . Id)
	}
}
Test("toml batch write corpus: the count and the pending inventory are current", _CTBW_CountAndPendingAreCurrent)

_CTBW_RegisterVectors() {
	Typed := _CTBW_TypedCorpus()["vectors"]
	for Index, Vector in _CTBW_Corpus()["vectors"]
		Test("toml batch write corpus: " . Vector["id"], _CTBW_ReplayVector.Bind(Vector, Typed[Index]))
}
_CTBW_RegisterVectors()
