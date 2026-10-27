; tests/unit/modules/keystats/test_keystats_case_projection_contract.ahk
;
; ==============================================================================
; MODULE: Native Case Projection Contract Tests
; DESCRIPTION:
; Pins original scalar boundaries, corrections, Greek word spelling and dotless
; I through the actual walker, SQLite writer and historical/today readers.
; ==============================================================================

_KLRCase_AssertProjection(Actual, Expected) {
	for Tab in ["c", "bg", "tg", "qg", "w"] {
		AssertTrue(Actual.Has(Tab), "the native reader must publish the case fixture category")
		AssertEqual(Expected[Tab].Count, Actual[Tab].Count, "native case fixture keys remain distinct")
		for Token, Item in Expected[Tab] {
			AssertTrue(Actual[Tab].Has(Token), "the reader preserves original Unicode spelling")
			for Counter in ["c", "e"]
				AssertEqual(Item[Counter], Actual[Tab][Token][Counter],
					"case projection inputs preserve original occurrence and error counts")
		}
	}
}

_KLRCase_StorageContract(Fixture, Spec) {
	SavedContext := KLW.ctx
	SavedBatch := KLW.batch
	Db := 0
	try {
		Events := []
		for Scalar in Spec["events"]
			Events.Push([Scalar, Fixture["delay_ms"], Map("st", "none")])
		KLW.ctx := Map()
		KLW_ResetBatch()
		KLW_WalkTypingEntry(Map("timestamp", Fixture["timestamp"],
			"app", Fixture["app"], "events", Events))
		Day := SubStr(Fixture["timestamp"], 1, 10)
		App := KLW.batch["app_day"][Day . Chr(1) . Fixture["app"]]
		AssertEqual(Spec["events"].Length, App["chars"], "the fixture preserves independent native events")
		AssertEqual(Spec["manifest"][Day][Fixture["app"]]["chars"], App["chars"])
		Db := _KLRShortcut_OpenFixture()
		AssertTrue(SQLite_Exec(Db, KLW_BuildBatchSql(SQLite_Q("case-contract"), false)))
		Expected := Spec["range"]["historical"]
		Historical := JsonParse(KLR_BuildNgramsJson(Db, Day, Day, [Fixture["app"]]))
		_KLRCase_AssertProjection(Historical, Expected)
		Today := JsonParse(KLR_BuildTodayIdxJson(Db, [Fixture["app"]], true, Day))
		AssertTrue(Today.Has(Fixture["app"]), "the today reader must retain the case fixture application")
		_KLRCase_AssertProjection(Today[Fixture["app"]], Expected)
	} finally {
		if Db
			SQLite_Close(Db)
		KLW.ctx := SavedContext
		KLW.batch := SavedBatch
	}
}

_KLRCase_Fixture := JsonParse(FileRead(A_ScriptDir . "\fixtures\metrics_case_projection.json", "UTF-8"))
AssertEqual(5, _KLRCase_Fixture["cases"].Length, "the native case contract has five distinct histories")
for _KLRCase_Spec in _KLRCase_Fixture["cases"]
	Test("Keystats: case projection " . _KLRCase_Spec["id"] . " (case-storage-contract)",
		_KLRCase_StorageContract.Bind(_KLRCase_Fixture, _KLRCase_Spec))
