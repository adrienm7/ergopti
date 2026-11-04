; tests/meta/corpus/test_corpus_terminators_and_llm_rows.ahk

; ==============================================================================
; MODULE: Delimiter Restoration and AI Row Corpus Consumers (Windows)
; DESCRIPTION:
; Replays hotstrings/terminator_restoration_vectors.json through the real plan of
; a restoration, and keystats/llm_events_vectors.json through the real row builder
; into the real schema.
;
; FEATURES & RATIONALE:
; 1. The first replay of the AI rows found a real bug: a missing predictions list
;    was stored as '{}', so the dashboard read a value where the shared rows hold
;    none.
; 2. Row comparisons go through SQLite quote(): it tells NULL from an empty string.
; ==============================================================================

#Requires AutoHotkey v2.0

_CTLR_Read(Relative) {
	return JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\" . Relative, "UTF-8"))
}

; An owner holding what the vector stored, resolved over the shipped catalogue.
_CTLR_Owner(States) {
	Defaults := _HotstringsTerminatorDefaults()
	Builtin := Map()
	Builtin.CaseSense := "On"
	for Key, Default in Defaults {
		Enabled := States.Has(Key) ? States[Key] : Default.Enabled
		Builtin[Key] := { Enabled: Enabled, Consume: Default.Consume }
	}
	Stored := Map("enabled", Map(), "consume", Map())
	Stored["enabled"].CaseSense := "On"
	for Key, Value in States
		Stored["enabled"][Key] := Value
	return { Builtin: Builtin, Stored: Stored }
}

_CTLR_TerminatorVector(Vector) {
	States := Vector["states"] is Map ? Vector["states"] : Map()
	Owner := _CTLR_Owner(States)
	Defaults := _HotstringsTerminatorDefaults()
	Changes := Map()
	for Key, Default in Defaults
		Changes[Key] := Map("enabled", Default.Enabled ? 1 : 0, "consume", Default.Consume ? 1 : 0)
	Plan := _HotstringsTerminatorBuiltinPlan(Owner, Changes)
	Expected := Vector["expected_personal"] is Map ? Vector["expected_personal"] : Map()
	Kept := Plan.Stored["enabled"]
	AssertEqual(Expected.Count, Kept.Count, Vector["id"] . ": only personal leaves stay")
	for Key, Value in Expected
		AssertEqual(Value ? 1 : 0, Kept[Key] ? 1 : 0, Vector["id"] . ": " . Key)
	for Update in Plan.Updates
		AssertTrue(Defaults.Has(Update.Key), Vector["id"] . ": a restoration writes shipped leaves only")
	for Key, Default in Defaults
		AssertEqual(Default.Enabled ? 1 : 0, Plan.State[Key].Enabled ? 1 : 0, Vector["id"] . ": " . Key)
}

_CTLR_Terminators() {
	Vectors := _CTLR_Read("hotstrings\terminator_restoration_vectors.json")
	AssertEqual(4, Vectors.Length, "the restoration vectors changed")
	Defaults := _HotstringsTerminatorDefaults()
	AssertTrue(Defaults["space"].Enabled, "space ships enabled")
	AssertFalse(Defaults["slash"].Enabled, "slash ships disabled")
	AssertTrue(Defaults["star"].Enabled, "star ships enabled")
	AssertTrue(Defaults["star"].Consume, "only the magic key slot ships consumed")
	AssertFalse(Defaults["comma"].Consume, "comma ships unconsumed")
	for Vector in Vectors
		_CTLR_TerminatorVector(Vector)
}
Test("corpus: a delimiter restoration keeps personal leaves (corpus-terminator-llm-rows)", _CTLR_Terminators)

_CTLR_LlmRow(Db, Vector, Id) {
	Event := Vector["event"]
	Entry := Map("timestamp", "2026-03-04 11:00:00.000")
	for Name, Value in Event
		Entry[Name] := Value
	AssertTrue(SQLite_Exec(Db, KL_BuildInsertLlm(Entry, Id, Event["kind"])), Vector["id"])
	for Column, Expected in Vector["row"] {
		Rows := SQLite_Query(Db, "SELECT quote(" . Column . ") AS v FROM events_llm WHERE id = " . Id . ";")
		AssertEqual(1, Rows.Length, Vector["id"])
		Quoted := Expected is String ? "'" . StrReplace(Expected, "'", "''") . "'"
			: Expected is Number ? String(Expected) : "NULL"
		AssertEqual(Quoted, Rows[1]["v"], Vector["id"] . " " . Column)
	}
}

_CTLR_LlmRows() {
	Corpus := _CTLR_Read("keystats\llm_events_vectors.json")
	AssertEqual(5, Corpus["cases"].Length, "the AI row vectors changed")
	Db := _WJFM_OpenMemory()
	try {
		AssertTrue(KLR_LoadSchema(Db))
		for Index, Vector in Corpus["cases"]
			_CTLR_LlmRow(Db, Vector, 1000 + Index)
		; INSERT OR IGNORE turns the schema's CHECK into a row that never lands.
		for Index, Kind in Corpus["refused_kinds"] {
			Id := 2000 + Index
			SQLite_Exec(Db, KL_BuildInsertLlm(Map("timestamp", "2026-03-04 11:00:00.000", "app", "x"), Id, Kind))
			AssertEqual(0, SQLite_Query(Db, "SELECT id FROM events_llm WHERE id = " . Id . ";").Length,
				"the schema refuses the kind '" . Kind . "'")
		}
	} finally {
		SQLite_Close(Db)
	}
}
Test("corpus: an AI event writes the shared row (corpus-terminator-llm-rows)", _CTLR_LlmRows)
