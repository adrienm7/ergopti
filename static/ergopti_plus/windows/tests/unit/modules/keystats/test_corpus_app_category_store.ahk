; tests/unit/modules/keystats/test_corpus_app_category_store.ahk

; ==============================================================================
; MODULE: App Category Store Corpus Consumer (Windows)
; DESCRIPTION:
; Replays the "decode" half of _shared/tests/corpus/metrics/app_category_store_vectors.json
; through the production _KL_AppCat_DecodeStore. The "edits" half names operations
; the Windows store does not have as pure functions (rename, import): the store's
; edits are durable transactions, so that half has no entry point here.
;
; FEATURES & RATIONALE:
; 1. A decoded document holds { type, score } records in a Map keyed by the lower
;    case process name, so a vector's names are compared lower-cased.
; 2. A case that disagrees is pinned in _KACS_PENDING with its reason, so a fix
;    forces the inventory to shrink.
; ==============================================================================

#Requires AutoHotkey v2.0

; The flat string form stays until the store's runtime no longer needs it: the
; defaults and the discoveries are written as strings and 17 test files pin that.
global _KACS_PENDING := Map(
	"legacy_entry_that_is_a_string",
	"Windows reads a flat string map, the form every other driver refuses; dropping it needs its first-run file, its discoveries and their tests rewritten")

_KACS_Corpus() {
	static Corpus := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\metrics\app_category_store_vectors.json", "UTF-8"))
	return Corpus
}

_KACS_Replay(Vector) {
	global _KACS_PENDING
	Model := 0
	Refused := false
	try Model := _KL_AppCat_DecodeStore(Vector["document"], "corpus")
	catch Error
		Refused := true
	if _KACS_PENDING.Has(Vector["id"]) {
		AssertFalse(Refused, Vector["id"] . " is now refused: remove it from _KACS_PENDING")
		return
	}
	if (Vector.Has("refused") && Vector["refused"]) {
		AssertTrue(Refused, Vector["id"] . " must be refused")
		return
	}
	AssertFalse(Refused, Vector["id"] . " must be accepted")
	AssertEqual(Vector["legacy"] ? 0 : 1, Model["versioned"] ? 1 : 0, Vector["id"] . ": the layout")
	Apps := Vector["apps"]
	AssertEqual(Apps.Count, Model["categories"].Count, Vector["id"] . ": the application count")
	for Name, Record in Apps {
		Key := StrLower(Name)
		AssertTrue(Model["categories"].Has(Key), Vector["id"] . " holds " . Name)
		Got := Model["categories"][Key]
		AssertTrue(Got is Map, Vector["id"] . ": " . Name . " is a record")
		AssertTrue(Got["type"] == Record["type"], Vector["id"] . ": " . Name . " type")
		AssertEqual(Record["score"], Got["score"], Vector["id"] . ": " . Name . " score")
	}
}

_KACS_ScoreRangeIsShared() {
	Corpus := _KACS_Corpus()
	AssertEqual(13, Corpus["decode"].Length, "app_category_store_vectors.json changed: review the decode replay")
	AssertEqual(-2, KLAppCatConst.MIN_SCORE)
	AssertEqual(2, KLAppCatConst.MAX_SCORE)
	AssertEqual("ergopti.app_categories", KLAppCatConst.STORE_SCHEMA)
}
Test("app category store corpus: the schema and the score range are the shared ones", _KACS_ScoreRangeIsShared)

_KACS_Register() {
	for Vector in _KACS_Corpus()["decode"]
		Test("app category store corpus: decode " . Vector["id"], _KACS_Replay.Bind(Vector))
}
_KACS_Register()
