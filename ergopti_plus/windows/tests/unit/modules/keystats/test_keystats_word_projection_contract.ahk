; tests/unit/modules/keystats/test_keystats_word_projection_contract.ahk
;
; ==============================================================================
; MODULE: Completed Word Projection Contract Tests
; DESCRIPTION:
; Pins the real walker and SQLite reader inputs used by the shared UI fixture.
; Corrected completions are stored once in e, separately from clean c counts.
; ==============================================================================

_KLRWord_Events(Scalars, Delay) {
	Events := []
	for Scalar in Scalars
		Events.Push([Scalar, Delay, Map("st", "none")])
	return Events
}

_KLRWord_AssertRows(Actual, Expected, Label) {
	for Tab in ["w", "w_bg"] {
		AssertTrue(Actual.Has(Tab), Label . " must publish the word category")
		AssertEqual(Expected[Tab].Count, Actual[Tab].Count, Label . " preserves word keys")
		for Token, Item in Expected[Tab] {
			AssertTrue(Actual[Tab].Has(Token), Label . " retains " . Token)
			for Counter in ["c", "e"]
				AssertEqual(Item[Counter], Actual[Tab][Token][Counter],
					Label . " preserves the stored clean/corrected split")
		}
	}
}

_KLRWord_CompletionContract(Fixture, Spec) {
	SavedContext := KLW.ctx
	SavedBatch := KLW.batch
	Db := 0
	try {
		Scalars := Spec["events"].Clone()
		AssertEqual(" ", Scalars.Pop(), "each history ends at a real word boundary")
		KLW.ctx := Map()
		KLW_ResetBatch()
		KLW_WalkTypingEntry(Map("timestamp", Fixture["timestamp"],
			"app", Fixture["app"], "events", _KLRWord_Events(Scalars, Fixture["delay_ms"])))
		Day := SubStr(Fixture["timestamp"], 1, 10)
		WordKey := Day . Chr(1) . Fixture["app"] . Chr(1) . Spec["target_word"]
		Before := KLW.batch["ngram"]["ngram_words"]
		for Counter in ["c", "e"]
			AssertEqual(Spec["before_target"][Counter],
				Before.Has(WordKey) ? Before[WordKey][Counter] : 0,
				"Backspaces do not complete the pending word before its separator")
		KLW_WalkTypingEntry(Map("timestamp", Fixture["boundary_timestamp"],
			"app", Fixture["app"], "events", _KLRWord_Events([" "], Fixture["delay_ms"])))
		Completed := 0
		for _, Item in KLW.batch["ngram"]["ngram_words"]
			Completed += Item["c"] + Item["e"]
		Boundaries := 0
		for Scalar in Spec["events"]
			if Scalar == " "
				Boundaries += 1
		AssertEqual(Boundaries, Completed, "multiple corrections count once per completed word")
		AssertEqual(Spec["snapshot"]["expected_words"], Completed)
		Db := _KLRShortcut_OpenFixture()
		AssertTrue(SQLite_Exec(Db, KLW_BuildBatchSql(SQLite_Q("word-contract"), false)),
			"the real SQL writer must persist the completed history")
		Expected := Spec["snapshot"]["range"]["historical"]
		Historical := JsonParse(KLR_BuildNgramsJson(Db, Day, Day, [Fixture["app"]]))
		_KLRWord_AssertRows(Historical, Expected, "historical reader")
		Today := JsonParse(KLR_BuildTodayIdxJson(Db, [Fixture["app"]], true, Day))
		AssertTrue(Today.Has(Fixture["app"]), "today reader retains its app scope")
		_KLRWord_AssertRows(Today[Fixture["app"]], Expected, "today reader")
	} finally {
		if Db
			SQLite_Close(Db)
		KLW.ctx := SavedContext
		KLW.batch := SavedBatch
	}
}

_KLRWord_Fixture := JsonParse(FileRead(A_ScriptDir . "\fixtures\metrics_word_projection.json", "UTF-8"))
AssertEqual(10, _KLRWord_Fixture["cases"].Length, "the native word contract has ten distinct histories")
for _KLRWord_Spec in _KLRWord_Fixture["cases"]
	Test("Keystats: completed word storage " . _KLRWord_Spec["id"] . " (word-completion-storage-contract)",
		_KLRWord_CompletionContract.Bind(_KLRWord_Fixture, _KLRWord_Spec))
