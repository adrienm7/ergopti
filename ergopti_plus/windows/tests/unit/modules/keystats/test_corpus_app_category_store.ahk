; tests/unit/modules/keystats/test_corpus_app_category_store.ahk

; ==============================================================================
; MODULE: App Category Store Corpus Consumer (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/metrics/app_category_store_vectors.json: the "decode"
; half through the production _KL_AppCat_DecodeStore, the "edits" half through the
; pure edit functions (_KL_AppCat_SetRecord, which KL_AppCat_CommitEdit calls,
; _KL_AppCat_RenameCategory and _KL_AppCat_ImportMissing).
;
; FEATURES & RATIONALE:
; 1. A decoded document holds { type, score } records in a Map keyed by the lower
;    case process name, so a vector's names are compared lower-cased.
; 2. No shared vector decides the fate of an unknown member: Windows follows the
;    shared codec and drops it, which is pinned here.
; ==============================================================================

#Requires AutoHotkey v2.0

_KACS_Corpus() {
	static Corpus := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\metrics\app_category_store_vectors.json", "UTF-8"))
	return Corpus
}

_KACS_Replay(Vector) {
	Model := 0
	Refused := false
	try Model := _KL_AppCat_DecodeStore(Vector["document"], "corpus")
	catch Error
		Refused := true
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

; A failed edit answers its refusal, as the shared codec's nil reason does.
_KACS_ApplyOp(Categories, Op) {
	switch Op["op"] {
		case "set": _KL_AppCat_SetRecord(Categories, Op["app"], Op["category"], Op["score"])
		case "rename": return _KL_AppCat_RenameCategory(Categories, Op["from"], Op["to"])
		case "import": return _KL_AppCat_ImportMissing(Categories, Op["entries"])
		default: throw ValueError("Unknown corpus edit: " . Op["op"])
	}
	return ""
}

_KACS_ReplayEdit(Vector) {
	Categories := Map()
	for Name, Record in Vector["start"]
		_KL_AppCat_SetRecord(Categories, Name, Record["type"], Record["score"])
	for Op in Vector["ops"] {
		Refused := false, Answer := ""
		try Answer := _KACS_ApplyOp(Categories, Op)
		catch ValueError
			Refused := true
		ShouldRefuse := Op.Has("ok") ? !Op["ok"] : (Op.Has("refused") && Op["refused"])
		AssertEqual(ShouldRefuse ? 1 : 0, Refused ? 1 : 0, Vector["id"] . ": the verdict of " . Op["op"])
		if Op.Has("renamed")
			AssertEqual(Op["renamed"], Answer, Vector["id"] . ": the renamed count")
		if Op.Has("added")
			AssertEqual(Op["added"], Answer, Vector["id"] . ": the added count")
	}
	AssertEqual(Vector["apps"].Count, Categories.Count, Vector["id"] . ": the application count")
	for Name, Record in Vector["apps"] {
		Got := Categories[StrLower(Name)]
		AssertTrue(Got["type"] == Record["type"], Vector["id"] . ": " . Name . " type")
		AssertEqual(Record["score"], Got["score"], Vector["id"] . ": " . Name . " score")
	}
}

_KACS_EditCountIsCurrent() {
	AssertEqual(8, _KACS_Corpus()["edits"].Length, "app_category_store_vectors.json changed: review the edit replay")
}
Test("app category store corpus: the edit count is current", _KACS_EditCountIsCurrent)

_KACS_UnknownMembersAreDropped() {
	Source := '{"schema":"ergopti.app_categories","version":1,"apps":{"safari":{"type":"Web","score":0,"future":[1]}},"extra":true}'
	Model := _KL_AppCat_DecodeStore(Source, "corpus")
	Candidate := Model["categories"].Clone()
	_KL_AppCat_SetRecord(Candidate, "Safari", "Work", 1)
	Content := _KL_AppCat_RenderStore(Candidate, Model)
	AssertFalse(InStr(Content, "future") > 0, "a record's unknown member is dropped")
	AssertFalse(InStr(Content, "extra") > 0, "a document's unknown member is dropped")
	AssertContains(Content, '"type":"Work"', "the edit itself is published")
}
Test("app category store: unknown members are dropped at the next save, as the shared codec does", _KACS_UnknownMembersAreDropped)

_KACS_Register() {
	for Vector in _KACS_Corpus()["decode"]
		Test("app category store corpus: decode " . Vector["id"], _KACS_Replay.Bind(Vector))
	for Vector in _KACS_Corpus()["edits"]
		Test("app category store corpus: edit " . Vector["id"], _KACS_ReplayEdit.Bind(Vector))
}
_KACS_Register()
