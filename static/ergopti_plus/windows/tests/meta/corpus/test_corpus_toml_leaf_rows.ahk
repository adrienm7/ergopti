; tests/meta/corpus/test_corpus_toml_leaf_rows.ahk

; ==============================================================================
; MODULE: TOML Leaf Rows Corpus Consumer (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/toml/leaf_rows_vectors.json through the writer's own
; row vocabulary and prepare step: _TOML_ConfigPathName spells each operation's
; section, TOML_BuildConfigDocumentCandidate prepares the bytes.
;
; FEATURES & RATIONALE:
; 1. Windows has no leaf-row planner: a caller hands the writer one row per leaf.
;    A malformed operation is therefore never planned here, and those vectors are
;    pinned with that reason.
; 2. Every case agrees or is pinned in _CTLR_PENDING with its reason.
; ==============================================================================

#Requires AutoHotkey v2.0



global _CTLR_VECTOR_COUNT := 12

; None is decided: which rule the drivers share is a maintainer call.
global _CTLR_NO_PLANNER := "Windows has no leaf-row planner to refuse a malformed operation; each caller builds its own rows"
global _CTLR_EMPTY_INLINE := "the Windows writer keeps an inline table emptied by deletions: the assignment is its physical declaration"
global _CTLR_IN_PLACE := "the Windows writer edits an inline member in place and keeps the source spelling, where the shared planner rewrites the table whole"

global _CTLR_PENDING := Map(
	"inline-table-left-empty-by-deletions-is-removed", _CTLR_EMPTY_INLINE,
	"malformed-operation-1-refused", _CTLR_NO_PLANNER,
	"malformed-operation-2-refused", _CTLR_NO_PLANNER,
	"malformed-operation-4-refused", _CTLR_NO_PLANNER,
	"unrelated-numeric-tokens-kept-inside-a-source-shaped-carried-model", _CTLR_IN_PLACE)

_CTLR_CorpusText() {
	static Text := FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\toml\leaf_rows_vectors.json", "UTF-8")
	return Text
}

_CTLR_Corpus() {
	static Corpus := JsonParse(_CTLR_CorpusText())
	return Corpus
}

_CTLR_TypedCorpus() {
	static Corpus := _TCV_ParseTyped(_CTLR_CorpusText())
	return Corpus
}

_CTLR_Rows(Operations, Typed) {
	Rows := []
	for Index, Operation in Operations {
		Parts := Operation["path"].Clone()
		Key := Parts.Pop()
		Update := { Section: _TOML_ConfigPathName(Parts), Key: Key }
		if Operation.Has("delete") && Operation["delete"]
			Update.Delete := 1
		else if Operation.Has("value")
			Update.Value := _TCV_Revive(Typed[Index]["value"])
		else
			throw ValueError("A leaf operation holds neither a value nor a deletion.")
		Rows.Push(Update)
	}
	return Rows
}

_CTLR_Difference(Vector, Typed) {
	Expect := Vector["expect"]
	Source := Vector["source"] is String ? Vector["source"] : ""
	Refused := "", Content := ""
	try {
		Rows := _CTLR_Rows(Vector["operations"], Typed["operations"])
		Content := _TCV_WithoutAddedBom(TOML_BuildConfigDocumentCandidate(Source, Rows, [])["content"], Source)
	} catch Error as Err {
		Refused := Err.Message
	}
	if !Expect["ok"]
		return Refused != "" ? "" : "the chain must be refused, it accepted"
	if Refused != ""
		return "the chain must be accepted, it refused: " . Refused
	return _TCV_CandidateDifference(Content, Source, Expect, Typed["expect"])
}

_CTLR_Replay(Vector, Typed) {
	global _CTLR_PENDING
	Difference := _CTLR_Difference(Vector, Typed)
	if _CTLR_PENDING.Has(Vector["id"])
		AssertTrue(Difference != "", Vector["id"] . " now agrees: remove it from _CTLR_PENDING")
	else
		AssertEqual("", Difference, Vector["id"])
}

_CTLR_InventoryIsCurrent() {
	global _CTLR_VECTOR_COUNT, _CTLR_PENDING
	Vectors := _CTLR_Corpus()["vectors"]
	AssertEqual(_CTLR_VECTOR_COUNT, Vectors.Length, "leaf_rows_vectors.json changed size")
	Known := Map()
	for Vector in Vectors
		Known[Vector["id"]] := true
	for Id, Reason in _CTLR_PENDING {
		AssertTrue(Known.Has(Id), "stale pending entry: " . Id)
		AssertTrue(Reason != "", "a pending entry states its reason: " . Id)
	}
}
Test("toml leaf rows corpus: the count and the pending inventory are current", _CTLR_InventoryIsCurrent)

_CTLR_Register() {
	Typed := _CTLR_TypedCorpus()["vectors"]
	for Index, Vector in _CTLR_Corpus()["vectors"]
		Test("toml leaf rows corpus: " . Vector["id"], _CTLR_Replay.Bind(Vector, Typed[Index]))
}
_CTLR_Register()
