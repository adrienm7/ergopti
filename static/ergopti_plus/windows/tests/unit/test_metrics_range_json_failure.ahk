; tests/unit/test_metrics_range_json_failure.ahk

; ==============================================================================
; MODULE: Range JSON Failure Tests
; DESCRIPTION: A late native read refusal cannot replace the last complete output.
; ==============================================================================

#Requires AutoHotkey v2.0

_MRJF_Authorize(State, Context, Action, NamePtr, ColumnPtr, DatabasePtr, TriggerPtr) {
	try {
		if Action == 20 && NamePtr && ColumnPtr
			&& StrGet(NamePtr, "UTF-8") == "ngram_scancodes"
			&& StrGet(ColumnPtr, "UTF-8") == "scancode" {
			State["reads"] += 1
			if State["reads"] == State["deny_at"] {
				State["denied"] += 1
				return 1
			}
		}
	} catch {
		State["failed"] := true
		return 1
	}
	return 0
}

_MRJF_Publish(Db) {
	AssertTrue(KLR_LoadSchema(Db))
	Root := A_Temp . "\range_json_refusal_" . A_ScriptHwnd
	AssertTrue(DllCall("CreateDirectoryW", "Str", Root, "Ptr", 0, "Int"))
	Callback := 0
	try {
		Path := Root . "\output.json"
		Previous := '{"previous":1}'
		AssertTrue(KLPF_WriteAtomic(Path, Previous))
		State := Map("reads", 0, "deny_at", 0, "denied", 0, "failed", false)
		Callback := CallbackCreate(_MRJF_Authorize.Bind(State), "C", 6)
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer",
			"Ptr", Db, "Ptr", Callback, "Ptr", 0, "Int"))
		; SELECT and GROUP BY may each authorize the same column. Calibrate the
		; exact historical query before denying the first subsequent today read.
		History := JsonParse(KLR_BuildNgramsJson(Db, "", "2030-01-01", []))
		AssertEqual(13, History.Count)
		HistoricalReads := State["reads"]
		AssertTrue(HistoricalReads > 0)
		AssertEqual(0, State["denied"])
		State["reads"] := 0
		State["deny_at"] := HistoricalReads + 1
		AssertThrows(() => KLPF_WriteAtomic(Path,
			KLR_BuildRangeSplitTodayJson(Db, "", "", [], "2030-01-02")),
			"a late today-query refusal must reject the complete serialized result")
		AssertFalse(State["failed"])
		AssertEqual(HistoricalReads + 1, State["reads"],
			"all historical read authorizations must precede the refused today query")
		AssertEqual(1, State["denied"], "the real SQLite fault must occur")
		AssertEqual(Previous, FileRead(Path, "UTF-8-RAW"), "partial history cannot replace the prior output")
		_SQLRD_AssertNoStatements(Db)
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer",
			"Ptr", Db, "Ptr", 0, "Ptr", 0, "Int"))
		AssertTrue(KLPF_WriteAtomic(Path,
			KLR_BuildRangeSplitTodayJson(Db, "", "", [], "2030-01-02")))
		Result := JsonParse(FileRead(Path, "UTF-8-RAW"))
		AssertEqual(13, Result["historical"].Count)
		AssertEqual(0, Result["today"].Count)
		_SQLRD_AssertNoStatements(Db)
	} finally {
		DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer", "Ptr", Db, "Ptr", 0, "Ptr", 0, "Int")
		if Callback
			CallbackFree(Callback)
		DirDelete(Root, true)
	}
}

Test("metrics range JSON: late native refusal preserves output and retries (metrics-range-json-failure)",
	_SQLRD_WithDatabase.Bind(_MRJF_Publish))
