; tests/unit/modules/keystats/test_keystats_app_pair_projection_contract.ahk
;
; ==============================================================================
; MODULE: Native Application Pair Projection Contract Tests
; DESCRIPTION:
; Replays coherent raw focus/typing histories through both SQL ownership lanes
; and the canonical manifest serializer before shared UI endpoint grouping.
; ==============================================================================

_KLRPair_InsertDay(Db, Fixture, Day) {
	Typed := Map()
	Names := Fixture["names"]
	Walk := Fixture["walk"]
	for Index, Slot in Walk {
		Timestamp := Day . " 12:00:00." . Format("{:03d}", (Index - 1) * Fixture["delay_ms"])
		if Index > 1 {
			Entry := Map("type", "app_switch", "timestamp", Timestamp,
				"prev_app", Names[Walk[Index - 1]], "next_app", Names[Slot],
				"duration_ms", Fixture["delay_ms"])
			for Sql in KL_BuildInserts(Entry) {
				AssertTrue(Sql != "", "the canonical switch builder must emit its raw row")
				AssertTrue(SQLite_Exec(Db, Sql))
			}
		}
		if !Typed.Has(Slot) {
			Entry := Map("type", "typing", "timestamp", Timestamp, "app", Names[Slot],
				"text", Fixture["typed_character"],
				"events", [[Fixture["typed_character"], Fixture["delay_ms"], Map("st", "none")]])
			for Sql in KL_BuildInserts(Entry) {
				AssertTrue(Sql != "", "the canonical typing builder must emit its raw row")
				AssertTrue(SQLite_Exec(Db, Sql))
			}
			Typed[Slot] := true
		}
	}
}

_KLRPair_StorageContract(Fixture, Spec) {
	SavedContext := KLW.ctx
	SavedBatch := KLW.batch
	SavedDevice := Keystats.device_id
	SavedLiteral := Keystats._device_id_lit
	SavedId := Keystats.next_event_id
	Db := 0
	try {
		Keystats.device_id := "pair-contract"
		Keystats._device_id_lit := SQLite_Q(Keystats.device_id)
		Keystats.next_event_id := 1
		Db := _KLRShortcut_OpenFixture()
		Loop Spec["days"]
			_KLRPair_InsertDay(Db, Fixture, Fixture["dates"][A_Index])
		AssertTrue(KLR_PrepareTypingProjection(Db))
		AssertTrue(KLR_ClearAggregates(Db))
		AssertTrue(KLR_RebuildAggregates(Db))
		AssertEqual(Fixture["names"].Length * Spec["days"], KLR_RebuildWalkerAggregates(Db, true),
			"the logical replay owns typing while SQL rollups own focus transitions")
		AssertEqual((Fixture["walk"].Length - 1) * Spec["days"],
			SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_app_switch;")[1]["n"])
		Manifest := JsonParse(KLR_BuildManifestJson(Db, Fixture["dates"][1], Fixture["dates"][Spec["days"]]))
		AssertEqual(Spec["manifest"].Count, Manifest.Count)
		for Day, Apps in Spec["manifest"] {
			for Name in Fixture["names"] {
				AssertTrue(Manifest[Day].Has(Name), "the real manifest retains every native application identity")
				Actual := Manifest[Day][Name]
				AssertEqual(Apps[Name]["chars"], Actual["chars"])
				AssertEqual(Apps[Name]["switches_to"].Count, Actual["switches_to"].Count)
				for Target, Count in Apps[Name]["switches_to"]
					AssertEqual(Count, Actual["switches_to"][Target], "directed raw edges remain distinct")
			}
		}
	} finally {
		if Db
			SQLite_Close(Db)
		KLW.ctx := SavedContext
		KLW.batch := SavedBatch
		Keystats.device_id := SavedDevice
		Keystats._device_id_lit := SavedLiteral
		Keystats.next_event_id := SavedId
	}
}

_KLRPair_Fixture := JsonParse(FileRead(A_ScriptDir . "\fixtures\metrics_app_pairs_projection.json", "UTF-8"))
AssertEqual(2, _KLRPair_Fixture["snapshots"].Length, "the app pair contract has one-day and multi-day histories")
for _KLRPair_Spec in _KLRPair_Fixture["snapshots"]
	Test("Keystats: structured app pair storage " . _KLRPair_Spec["days"] . " days (app-pair-storage-contract)",
		_KLRPair_StorageContract.Bind(_KLRPair_Fixture, _KLRPair_Spec))
