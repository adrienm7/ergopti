; tests/meta/modules/llm/prediction/test_ngram_esrc_json_accumulate.ahk

; ==============================================================================
; MODULE: N-gram UPSERT esrc_json Accumulation Test
; DESCRIPTION:
; Regression guard ensuring the ngram UPSERT accumulates esrc_json counts
; instead of overwriting them.
;
; The bug: the ON CONFLICT clause used `esrc_json=excluded.esrc_json`, which
; replaces the stored JSON object with the new batch's object on every flush.
; A row flushed in cycle 1 with {"hotstring":3} and again in cycle 2 with
; {"hotstring":2} would end up with {"hotstring":2} instead of 5.
;
; The merge enumerates literal keys with json_each and sums old and incoming
; values. Source names must never be interpolated as JSON paths: punctuation
; would create nested members instead of updating the original counter.
;
; SCOPE: the real flush, KLW_BuildBatchSql, executed on the real SQLite engine.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

; Flushes one token's sources through the real batch emitter into the database.
_NEA_Flush(Db, Esrc) {
	SavedBatch := KLW.batch
	try {
		KLW_ResetBatch()
		KLW.batch["app_day"][1] := Map("date", "2026-01-01", "app", "fixture.exe", "time_ms", 1)
		KLW.batch["ngram"]["ngram_chars"] := Map("2026-01-01" . Chr(1) . "fixture.exe" . Chr(1) . "a",
			Map("c", 1, "td", 0, "cd", 0, "e", 0, "esrc", Esrc))
		AssertTrue(SQLite_Exec(Db, KLW_BuildBatchSql("esrc-device", false)), "the flush must execute")
	} finally {
		KLW.batch := SavedBatch
	}
}

_NEA_StoredSources(Db) {
	Rows := SQLite_Query(Db, "SELECT c, esrc_json FROM ngram_chars;")
	AssertEqual(1, Rows.Length, "the two flushes must land on one row")
	AssertEqual(3, Rows[1]["c"], "the counts add")
	return JsonParse(Rows[1]["esrc_json"])
}

_NEA_SecondFlushAccumulates() {
	Db := SQLite_Open(":memory:")
	AssertTrue(Db != 0, "the fixture must open an in-memory DB")
	try {
		AssertTrue(KLR_LoadSchema(Db), "the fixture uses the production schema")
		_NEA_Flush(Db, Map("hotstring", 3, "only_first", 7))
		_NEA_Flush(Db, Map("hotstring", 2))
		_NEA_Flush(Db, Map())
		Sources := _NEA_StoredSources(Db)
		AssertEqual(2, Sources.Count, "a key from one flush survives the others")
		AssertEqual(5, Sources["hotstring"], "a later flush must add to the stored count, never replace it")
		AssertEqual(7, Sources["only_first"], "an absent key keeps its stored count")
	} finally {
		SQLite_Close(Db)
	}
}

_NEA_PunctuationStaysALiteralKey() {
	Db := SQLite_Open(":memory:")
	AssertTrue(Db != 0, "the fixture must open an in-memory DB")
	try {
		AssertTrue(KLR_LoadSchema(Db), "the fixture uses the production schema")
		for Count in [1, 2, 4]
			_NEA_Flush(Db, Map("source.v2", Count, 'odd"key[0]', Count))
		Sources := _NEA_StoredSources(Db)
		AssertEqual(2, Sources.Count, "punctuation must not create a nested member")
		AssertEqual(7, Sources["source.v2"], "a dotted name is one key")
		AssertEqual(7, Sources['odd"key[0]'], "quotes and brackets are one key")
	} finally {
		SQLite_Close(Db)
	}
}

Test("ngram-esrc-accumulate: a later flush adds to the stored sources",
	_NEA_SecondFlushAccumulates)

Test("ngram-esrc-accumulate: a source name with punctuation stays one literal key",
	_NEA_PunctuationStaysALiteralKey)
