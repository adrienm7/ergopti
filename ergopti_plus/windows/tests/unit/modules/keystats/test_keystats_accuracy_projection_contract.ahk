; tests/unit/modules/keystats/test_keystats_accuracy_projection_contract.ahk
;
; ==============================================================================
; MODULE: Native Accuracy Projection Contract Tests
; DESCRIPTION:
; Proves original control-marker and literal-error rows with the real walker,
; SQLite writer and readers, before shared UI case folding changes their keys.
; ==============================================================================

_KLRAccuracy_Contract(Fixture, Spec) {
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
		Key := Day . Chr(1) . Fixture["app"] . Chr(1) . Spec["token"]
		Rows := KLW.batch["ngram"][Spec["table"]]
		AssertTrue(Rows.Has(Key), "the actual native history must produce the fixture token")
		for Counter in ["c", "e"]
			AssertEqual(Spec[Counter], Rows[Key][Counter], "the native row pins the fixture counter")
		Db := _KLRShortcut_OpenFixture()
		AssertTrue(SQLite_Exec(Db, KLW_BuildBatchSql(SQLite_Q("accuracy-contract"), false)))
		Historical := JsonParse(KLR_BuildNgramsJson(Db, Day, Day, [Fixture["app"]]))
		Today := JsonParse(KLR_BuildTodayIdxJson(Db, [Fixture["app"]], true, Day))
		AssertTrue(Today.Has(Fixture["app"]), "the native today reader must retain its application")
		for Projection in [Historical, Today[Fixture["app"]]] {
			AssertTrue(Projection.Has(Spec["tab"]), "the native reader must publish the fixture tab")
			AssertTrue(Projection[Spec["tab"]].Has(Spec["token"]), "the reader preserves token case")
			for Counter in ["c", "e"]
				AssertEqual(Spec[Counter], Projection[Spec["tab"]][Spec["token"]][Counter],
					"both readers preserve the original correction counters")
		}
	} finally {
		if Db
			SQLite_Close(Db)
		KLW.ctx := SavedContext
		KLW.batch := SavedBatch
	}
}

_KLRAccuracy_Fixture := JsonParse(FileRead(A_ScriptDir . "\fixtures\metrics_accuracy_projection.json", "UTF-8"))
AssertEqual(9, _KLRAccuracy_Fixture["cases"].Length, "native accuracy fixture has nine histories")
for _KLRAccuracy_Spec in _KLRAccuracy_Fixture["cases"]
	Test("Keystats: original token accuracy " . _KLRAccuracy_Spec["id"] . " (accuracy-storage-contract)",
		_KLRAccuracy_Contract.Bind(_KLRAccuracy_Fixture, _KLRAccuracy_Spec))
