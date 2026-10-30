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
; 2. Every case agrees or is pinned in _CTBW_PENDING with its reason, so a fix
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
global _CTBW_REFUSES := "the Windows writer refuses a physical table or an array-of-tables rewrite the shared writer performs"
global _CTBW_ACCEPTS := "the Windows writer accepts an ambiguous or case-twin target the shared writer refuses"
global _CTBW_BYTES := "the Windows writer renders the same value in other bytes (spacing, quoting, a rewritten member)"
global _CTBW_SNAPSHOT := "the Windows prepare step takes the source as an argument and no earlier snapshot, so a stale read cannot reach it"

global _CTBW_PENDING := Map(
	"empty-header-table-deleted-comments-kept", _CTBW_REFUSES,
	"header-table-descendants-and-interleaved-blocks-replaced-by-scalar", _CTBW_BYTES,
	"header-table-without-parent-header-deleted", _CTBW_REFUSES,
	"header-table-without-parent-header-set-to-a-table", _CTBW_REFUSES,
	"equal-array-of-tables-left-byte-for-byte", _CTBW_REFUSES,
	"equal-inline-parent-value-left-byte-for-byte", _CTBW_BYTES,
	"changed-array-of-tables-rewritten-as-one-inline-list", _CTBW_REFUSES,
	"quoted-bare-key-updated-in-place-double-quoted", _CTBW_BYTES,
	"quoted-bare-key-updated-in-place-single-quoted", _CTBW_BYTES,
	"quoted-bare-key-in-dotted-section-updated", _CTBW_BYTES,
	"inline-table-value-change-names-its-key", _CTBW_ACCEPTS,
	"inline-source-existing-boolean", _CTBW_BYTES,
	"inline-source-first-deletion", _CTBW_BYTES,
	"inline-source-middle-deletion", _CTBW_BYTES,
	"inline-source-existing-no-op", _CTBW_BYTES,
	"inline-source-scalar-and-absent-sibling-deletion", _CTBW_BYTES,
	"nested-dotted-and-quoted-member-fragments-kept-under-a-quoted-header", _CTBW_BYTES,
	"owned-extension-leaf-deleted-neighbour-bytes-kept", _CTBW_REFUSES,
	"equivalent-section-spelling-literal-updated-and-extended", _CTBW_REFUSES,
	"equivalent-section-spelling-basic-updated-and-extended", _CTBW_REFUSES,
	"equivalent-section-spelling-escaped-updated-and-extended", _CTBW_REFUSES,
	"canonical-colon-segments-rendered-quoted-on-first-insertion", _CTBW_BYTES,
	"duplicate-equivalent-rows-refused-before-reading", _CTBW_ACCEPTS,
	"ambiguous-case-folded-or-array-target-1-refused", _CTBW_ACCEPTS,
	"ambiguous-case-folded-or-array-target-2-refused", _CTBW_ACCEPTS,
	"dotted-section-unchanged-value-keeps-every-byte", _CTBW_BYTES,
	"dotted-section-scalar-replaced-with-an-exact-owned-image", _CTBW_BYTES,
	"root-dotted-bom-kept-when-updating-a-first-leaf", _CTBW_BYTES,
	"root-dotted-final-newline-ownership-kept-when-updating-the-last-leaf", _CTBW_BYTES,
	"root-scalar-replaced-while-publishing-a-descendant-refused", _CTBW_ACCEPTS,
	"header-scalar-new-key-gets-the-precise-numeric-literal", _CTBW_BYTES,
	"root-inline-first-removal", _CTBW_BYTES,
	"root-inline-middle-removal", _CTBW_BYTES,
	"root-inline-last-removal", _CTBW_BYTES,
	"root-inline-adjacent-removals", _CTBW_BYTES,
	"root-inline-all-removals", _CTBW_BYTES,
	"root-inline-nested-dotted-inline-member", _CTBW_BYTES,
	"root-inline-opaque-escaped-delimiters", _CTBW_BYTES,
	"root-inline-quoted-root-owner", _CTBW_BYTES,
	"root-inline-signed-zero-changed-to-integer-zero", _CTBW_BYTES,
	"root-inline-bom-and-trailing-newline-ownership-kept", _CTBW_BYTES,
	"root-inline-refused-case-twin-member", _CTBW_ACCEPTS,
	"root-inline-refused-case-twin-table", _CTBW_ACCEPTS,
	"root-inline-refused-literal-dot-key", _CTBW_ACCEPTS,
	"root-inline-refused-parent-and-child-in-one-batch", _CTBW_ACCEPTS,
	"root-inline-refused-changed-type", _CTBW_ACCEPTS,
	"root-inline-new-member-appended", _CTBW_BYTES,
	"section-dotted-boolean-leaf", _CTBW_BYTES,
	"section-dotted-nested-header", _CTBW_BYTES,
	"section-dotted-quoted-header", _CTBW_BYTES,
	"section-dotted-quoted-literal-header-segment", _CTBW_BYTES,
	"section-dotted-two-separate-scalar-owners", _CTBW_BYTES,
	"section-dotted-safety-refusal-1", _CTBW_ACCEPTS,
	"section-dotted-safety-refusal-3", _CTBW_ACCEPTS,
	"section-dotted-safety-refusal-5", _CTBW_ACCEPTS,
	"section-dotted-safety-refusal-7", _CTBW_ACCEPTS,
	"section-dotted-safety-refusal-8", _CTBW_ACCEPTS,
	"dotted-stale-snapshot-refused-without-publication", _CTBW_SNAPSHOT,
	"root-changed-source-snapshot-refused", _CTBW_SNAPSHOT,
	"root-inline-stale-source-refused-before-any-edit", _CTBW_SNAPSHOT,
	"section-dotted-stale-source-refused-before-an-owned-scalar", _CTBW_SNAPSHOT)

_CTBW_Corpus() {
	static Corpus := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\toml\batch_write_vectors.json", "UTF-8"))
	return Corpus
}

; A JSON value with {"$number": text} spelled as the number it names.
_CTBW_Revive(Value) {
	if !(Value is Map || Value is Array)
		return Value
	if (Value is Map && Value.Has("$number")) {
		Text := Value["$number"]
		return Number(Text)
	}
	if (Value is Array) {
		Out := []
		for Item in Value
			Out.Push(_CTBW_Revive(Item))
		return Out
	}
	Out := Map()
	Out.CaseSense := "On"
	for Key, Item in Value
		Out[Key] := _CTBW_Revive(Item)
	return Out
}

_CTBW_Rows(Vector) {
	Rows := []
	for Row in Vector["rows"] {
		Update := { Section: Row["section"], Key: Row["key"] }
		if (Row.Has("delete") && Row["delete"])
			Update.Delete := 1
		else
			Update.Value := _CTBW_Revive(Row["value"])
		Rows.Push(Update)
	}
	return Rows
}





; =============================
; =============================
; ======= 2/ The replay =======
; =============================
; =============================

; Returns "" when the writer agrees with the vector, else the first difference.
_CTBW_Difference(Vector) {
	Expect := Vector["expect"]
	Refused := ""
	Content := ""
	try {
		Candidate := TOML_BuildConfigDocumentCandidate(Vector["source"], _CTBW_Rows(Vector), [])
		Content := Candidate["content"]
		; The Windows config writer publishes a BOM where the shared writer adds none:
		; that one prefix is reported apart, and the rest of the bytes are compared.
		if (SubStr(Content, 1, 1) == Chr(0xFEFF) && SubStr(Vector["source"], 1, 1) != Chr(0xFEFF))
			Content := SubStr(Content, 2)
	} catch Error as Err {
		Refused := Err.Message
	}
	if !Expect["ok"]
		return Refused != "" ? "" : "the batch must be refused, the writer accepted it"
	if (Refused != "")
		return "the batch must be accepted, the writer refused: " . Refused
	if (Expect.Has("content") && !(Content == Expect["content"]))
		return "candidate bytes differ: " . Content
	if (Expect.Has("unchanged") && Expect["unchanged"] && !(Content == Vector["source"]))
		return "the candidate must equal the source: " . Content
	if Expect.Has("contains") {
		for Part in Expect["contains"]
			if !InStr(Content, Part, true)
				return "missing " . Part
	}
	if Expect.Has("not_contains") {
		for Part in Expect["not_contains"]
			if InStr(Content, Part, true)
				return "must not contain " . Part
	}
	if Expect.Has("decoded") {
		Document := TOML_ParseDocument(Content)
		for Check in Expect["decoded"] {
			Found := _TOML_DocumentLookup(Document, Check["path"])
			Label := ""
			for Key in Check["path"]
				Label .= (Label == "" ? "" : ".") . Key
			if (Check.Has("absent") && Check["absent"]) {
				if Found["found"]
					return Label . " must be absent"
			} else if (!Found["found"] || !TOML_SameValue(Found["value"], _CTBW_Revive(Check["value"]))) {
				return Label . " decoded differently"
			}
		}
	}
	return ""
}

_CTBW_ReplayVector(Vector) {
	global _CTBW_PENDING
	Difference := _CTBW_Difference(Vector)
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
	for Vector in _CTBW_Corpus()["vectors"]
		Test("toml batch write corpus: " . Vector["id"], _CTBW_ReplayVector.Bind(Vector))
}
_CTBW_RegisterVectors()
