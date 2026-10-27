; tests/unit/modules/keystats/test_keystats_unicode_projection_contract.ahk
;
; ==============================================================================
; MODULE: Native Unicode Projection Contract Tests
; DESCRIPTION:
; Pins valid Unicode histories through the actual walker, SQLite writer and
; readers. Literal Unicode must never become a text-decoding instruction.
; ==============================================================================

_KLRUnicode_AssertProjection(Actual, Expected) {
	for Tab in ["c", "bg", "tg"] {
		AssertTrue(Actual.Has(Tab), "the native reader must publish this category")
		AssertEqual(Expected[Tab].Count, Actual[Tab].Count, "native Unicode keys remain distinct")
		for Token, Item in Expected[Tab] {
			AssertTrue(Actual[Tab].Has(Token), "the native reader retains the exact Unicode token")
			for Counter in ["c", "e"]
				AssertEqual(Item[Counter], Actual[Tab][Token][Counter],
					"native Unicode counters retain their scalar boundaries")
		}
	}
}

_KLRUnicode_StorageContract(Fixture, Spec) {
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
		AssertEqual(Spec["events"].Length, App["chars"], "the fixture contains independent scalar events")
		AssertEqual(Spec["manifest"][Day][Fixture["app"]]["chars"], App["chars"])
		Db := _KLRShortcut_OpenFixture()
		AssertTrue(SQLite_Exec(Db, KLW_BuildBatchSql(SQLite_Q("unicode-contract"), false)))
		Expected := Spec["range"]["historical"]
		Historical := JsonParse(KLR_BuildNgramsJson(Db, Day, Day, [Fixture["app"]]))
		_KLRUnicode_AssertProjection(Historical, Expected)
		Today := JsonParse(KLR_BuildTodayIdxJson(Db, [Fixture["app"]], true, Day))
		AssertTrue(Today.Has(Fixture["app"]), "the native today reader must retain its application")
		_KLRUnicode_AssertProjection(Today[Fixture["app"]], Expected)
	} finally {
		if Db
			SQLite_Close(Db)
		KLW.ctx := SavedContext
		KLW.batch := SavedBatch
	}
}

_KLRUnicode_Fixture := JsonParse(FileRead(A_ScriptDir . "\fixtures\metrics_unicode_projection.json", "UTF-8"))
AssertEqual(5, _KLRUnicode_Fixture["cases"].Length, "the native Unicode contract has five histories")
for _KLRUnicode_Spec in _KLRUnicode_Fixture["cases"]
	Test("Keystats: Unicode projection " . _KLRUnicode_Spec["id"] . " (unicode-storage-contract)",
		_KLRUnicode_StorageContract.Bind(_KLRUnicode_Fixture, _KLRUnicode_Spec))
