; tests/unit/test_walker_json_flush_merge.ahk

; ==============================================================================
; MODULE: Walker JSON Flush Merge Tests
; DESCRIPTION:
; Real SQLite receipts prove that batch boundaries do not discard distributions.
; ==============================================================================

#Requires AutoHotkey v2.0

_WJFM_OpenMemory() {
	static ModuleHandle := 0
	; SQLite initialization and DB pointers must outlive individual DllCall loads.
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	AssertTrue(ModuleHandle != 0, "the SQLite module must remain loaded while its DB is owned")
	Db := SQLite_Open(":memory:")
	AssertTrue(Db != 0)
	return Db
}

_WJFM_Flush(Db) {
	Sql := KLW_BuildBatchSql("'merge-device'")
	AssertTrue(Sql != "", "the seeded batch must emit SQL")
	AssertTrue(SQLite_Exec(Db, Sql), "the real walker SQL must execute")
}

_WJFM_Histograms(Kind) {
	SavedBatch := KLW.batch
	Db := _WJFM_OpenMemory()
	AssertTrue(Db != 0)
	try {
		AssertTrue(KLR_LoadSchema(Db))
		ExpectedTotal := 0
		for Buckets in [Map("100", 2, "200", 3), Map("100", 5, "300", 7), Map()] {
			BatchTotal := 0
			for , Value in Buckets
				BatchTotal += Value
			ExpectedTotal += BatchTotal
			KLW_ResetBatch()
			Row := Map("date", "2026-09-08", "app", "merge.exe")
			switch Kind {
				case "hourly", "hourly_min5":
					Row["hour"] := "10"
					Row["slot"] := "10:00"
					Row["e"] := BatchTotal
					Row["em"] := 1
					Row["es"] := 1
					Row["e_buckets"] := Buckets
					Table := Kind = "hourly" ? "agg_app_day_hourly" : "agg_app_day_hourly_min5"
					Column := "e_buckets_json"
					Counter := "e"
				case "bursts":
					for Field in ["count_total", "max_cpm", "max_chars", "inter_count", "inter_sum", "inter_sumsq"]
						Row[Field] := 1
					Row["count_total"] := BatchTotal
					Row["length_buckets"] := Buckets
					Table := "agg_app_day_burst"
					Column := "length_buckets_json"
					Counter := "count_total"
			}
			KLW.batch[Kind]["fixture"] := Row
			_WJFM_Flush(Db)
			Rows := SQLite_Query(Db, "SELECT " . Counter . " AS total, " . Column . " AS payload FROM " . Table . ";")
			AssertEqual(1, Rows.Length)
			AssertEqual(ExpectedTotal, Rows[1]["total"], "numeric totals must survive every flush, including an empty delta")
			StoredBuckets := KL_JsonDecode(Rows[1]["payload"])
			StoredTotal := 0
			for , Value in StoredBuckets
				StoredTotal += Value
			AssertEqual(ExpectedTotal, StoredTotal, "the fixture's distribution mass must be conserved across flushes")
		}
		Rows := SQLite_Query(Db, "SELECT " . Column . " AS payload FROM " . Table . ";")
		AssertEqual(1, Rows.Length)
		Buckets := KL_JsonDecode(Rows[1]["payload"])
		AssertTrue(Buckets is Map)
		AssertEqual(3, Buckets.Count, "both disjoint keys must survive the second flush")
		AssertEqual(7, Buckets["100"], "the shared bucket must add both batches")
		AssertEqual(3, Buckets["200"])
		AssertEqual(7, Buckets["300"])
	} finally {
		KLW.batch := SavedBatch
		SQLite_Close(Db)
	}
}

for Kind in ["hourly", "hourly_min5", "bursts"]
	Test("walker: JSON histogram survives successive " . Kind . " flushes (walker-json-flush-merge)", _WJFM_Histograms.Bind(Kind))

_WJFM_Sessions(Capped) {
	SavedBatch := KLW.batch
	Db := _WJFM_OpenMemory()
	AssertTrue(Db != 0)
	try {
		AssertTrue(KLR_LoadSchema(Db))
		PerBatch := Capped ? KLWConst.SESSION_DURATIONS_CAP - 1 : 2
		Loop 2 {
			BatchIndex := A_Index
			KLW_ResetBatch()
			Loop PerBatch {
				Duration := (BatchIndex - 1) * PerBatch + A_Index
				KLW_FinalizeSession("2026-09-08", "merge.exe",
					Map("char_count", 1, "total_ms", Duration))
			}
			_WJFM_Flush(Db)
		}
		Rows := SQLite_Query(Db, "SELECT count_total, durations_json FROM agg_app_day_session;")
		AssertEqual(1, Rows.Length)
		AssertEqual(PerBatch * 2, Rows[1]["count_total"])
		Durations := KL_JsonDecode(Rows[1]["durations_json"])
		AssertTrue(Durations is Array)
		ExpectedCount := Min(PerBatch * 2, KLWConst.SESSION_DURATIONS_CAP)
		AssertEqual(ExpectedCount, Durations.Length)
		Loop ExpectedCount
			AssertEqual(A_Index, Durations[A_Index], "earliest session durations must retain their order")
	} finally {
		KLW.batch := SavedBatch
		SQLite_Close(Db)
	}
}

for Capped in [false, true]
	Test("walker: ordered session durations survive flushes capped=" . Capped . " (walker-json-flush-merge)", _WJFM_Sessions.Bind(Capped))

_WJFM_EsrcControl() {
	SavedBatch := KLW.batch
	Db := _WJFM_OpenMemory()
	AssertTrue(Db != 0)
	try {
		AssertTrue(KLR_LoadSchema(Db))
		for Sources in [Map("manual", 2, "hs", 3), Map("manual", 5, "llm", 7)] {
			KLW_ResetBatch()
			Key := "2026-09-08" . Chr(1) . "merge.exe" . Chr(1) . "a"
			KLW.batch["ngram"]["ngram_chars"][Key] := Map("c", 1, "td", 0,
				"cd", 0, "e", 1, "esrc", Sources)
			_WJFM_Flush(Db)
		}
		Rows := SQLite_Query(Db, "SELECT c, esrc_json FROM ngram_chars;")
		AssertEqual(1, Rows.Length)
		AssertEqual(2, Rows[1]["c"])
		Sources := KL_JsonDecode(Rows[1]["esrc_json"])
		AssertEqual(3, Sources.Count)
		AssertEqual(7, Sources["manual"])
		AssertEqual(3, Sources["hs"])
		AssertEqual(7, Sources["llm"])
	} finally {
		KLW.batch := SavedBatch
		SQLite_Close(Db)
	}
}
Test("walker: existing error-source merge remains additive (walker-json-flush-merge)", _WJFM_EsrcControl)
