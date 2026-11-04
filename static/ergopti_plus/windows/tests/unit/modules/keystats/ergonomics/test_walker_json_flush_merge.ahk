; tests/unit/modules/keystats/ergonomics/test_walker_json_flush_merge.ahk

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

_WJFM_Flush(Db, Device := "merge-device") {
	Sql := KLW_BuildBatchSql(Device)
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

_WJFM_SessionPartitions() {
	SavedBatch := KLW.batch
	Db := _WJFM_OpenMemory()
	Expected := Map()
	try {
		AssertTrue(KLR_LoadSchema(Db))
		loop 3 {
			BatchIndex := A_Index
			loop 2 {
				DeviceIndex := A_Index
				Device := "merge-device-" . DeviceIndex
				KLW_ResetBatch()
				for DayIndex, Day in ["2026-09-08", "2026-09-09"] {
					for AppIndex, App in ["first.exe", "second'quoted.exe"] {
						Key := Device . "|" . Day . "|" . App
						Duration := DeviceIndex * 1000 + DayIndex * 100 + AppIndex * 10 + BatchIndex
						if !Expected.Has(Key)
							Expected[Key] := []
						Expected[Key].Push(Duration)
						KLW_FinalizeSession(Day, App, Map("char_count", 1, "total_ms", Duration))
					}
				}
				_WJFM_Flush(Db, Device)
				Rows := SQLite_Query(Db, "SELECT device_id,date,app,count_total,durations_json"
					. " FROM agg_app_day_session;")
				AssertEqual(Expected.Count, Rows.Length)
				for Row in Rows {
					Key := Row["device_id"] . "|" . Row["date"] . "|" . Row["app"]
					AssertTrue(Expected.Has(Key), "every stored partition must belong to a seeded identity")
					AssertEqual(Expected[Key].Length, Row["count_total"])
					Actual := KL_JsonDecode(Row["durations_json"])
					AssertEqual(KL_JsonEncode(Expected[Key]), KL_JsonEncode(Actual),
						"duration merges must stay inside the exact device/day/app partition")
				}
			}
		}
		AssertEqual(8, Expected.Count)
	} finally {
		KLW.batch := SavedBatch
		SQLite_Close(Db)
	}
}
Test("walker: session flushes isolate device day and app partitions (walker-session-partitions)",
	_WJFM_SessionPartitions)

_WJFM_EsrcControl() {
	SavedBatch := KLW.batch
	Db := _WJFM_OpenMemory()
	AssertTrue(Db != 0)
	try {
		AssertTrue(KLR_LoadSchema(Db))
		for Sources in [Map("manual", 2, "hs", 3), Map("manual", 5, "llm", 7)] {
			KLW_ResetBatch()
			Key := "2026-09-08" . Chr(1) . "merge.exe" . Chr(1) . "a"
			KLW.batch["ngram"]["ngram_chars"][Key] := Map("date", "2026-09-08", "app", "merge.exe", "token", "a", "c", 1, "td", 0,
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

_WJFM_EsrcLiteralLabels(Source) {
	SavedBatch := KLW.batch
	Db := _WJFM_OpenMemory()
	try {
		AssertTrue(KLR_LoadSchema(Db))
		loop 2 {
			KLW_ResetBatch()
			KLW_PushNgram("ngram_chars", "2026-09-12", "fixture.exe", "x", 0, true, Source)
			_WJFM_Flush(Db)
		}
		Rows := SQLite_Query(Db, "SELECT e,esrc_json FROM ngram_chars;")
		AssertEqual(1, Rows.Length)
		AssertEqual(2, Rows[1]["e"])
		Sources := KL_JsonDecode(Rows[1]["esrc_json"])
		AssertEqual(1, Sources.Count, "literal source labels must not create nested JSON members")
		AssertTrue(Sources.Has(Source), "the exact accepted source label must survive replay")
		AssertEqual(2, Sources[Source], "both flushes must contribute to the same literal source")
	} finally {
		KLW.batch := SavedBatch
		if Db
			SQLite_Close(Db)
	}
}
for Source in ["engine.v2", "engine[0]", 'engine"quoted', "engine\path", "engine'quoted"]
	Test("walker: literal synthetic source " . Source . " (walker-esrc-literal-label)",
		_WJFM_EsrcLiteralLabels.Bind(Source))

; SQLite's json_group_object cuts an object key at an embedded NUL, so a merged
; map turned "a\u0000b" into a second "a" key on the Linux writer. Every numeric
; map this walker merges (n-gram sources, error buckets, burst lengths) shares
; KLW_BucketMergeExpr, so each one merges a delta into a stored map holding a
; NUL key through the vendored DLL. The stored key is written in SQL because an
; AutoHotkey Map key ends at its first NUL: "a\0b" and "a" are one Map key, so no
; batch can carry it, while the column can hold it from another writer.
_WJFM_NulMapKey(Kind) {
	SavedBatch := KLW.batch
	Db := _WJFM_OpenMemory()
	try {
		AssertTrue(KLR_LoadSchema(Db))
		loop 2 {
			KLW_ResetBatch()
			Counts := Map("a", 10)
			Row := Map("date", "2026-09-08", "app", "merge.exe")
			switch Kind {
				case "ngram":
					Key := "2026-09-08" . Chr(1) . "merge.exe" . Chr(1) . "x"
					KLW.batch["ngram"]["ngram_chars"][Key] := Map("date", "2026-09-08", "app", "merge.exe", "token", "x", "c", 0, "td", 0,
						"cd", 0, "e", 10, "esrc", Counts)
					Table := "ngram_chars", Column := "esrc_json"
				case "hourly", "hourly_min5":
					Row["hour"] := "10", Row["slot"] := "10:00"
					Row["e"] := 10, Row["em"] := 10, Row["es"] := 0
					Row["e_buckets"] := Counts
					KLW.batch[Kind]["fixture"] := Row
					Table := Kind = "hourly" ? "agg_app_day_hourly" : "agg_app_day_hourly_min5"
					Column := "e_buckets_json"
				case "bursts":
					for Field in ["count_total", "max_cpm", "max_chars", "inter_count", "inter_sum", "inter_sumsq"]
						Row[Field] := 1
					Row["length_buckets"] := Counts
					KLW.batch[Kind]["fixture"] := Row
					Table := "agg_app_day_burst", Column := "length_buckets_json"
			}
			_WJFM_Flush(Db)
			if (A_Index = 1)
				AssertTrue(SQLite_Exec(Db, "UPDATE " . Table . " SET " . Column . " = '{"
					. Chr(34) . "a\u0000b" . Chr(34) . ":1," . Chr(34) . "a" . Chr(34) . ":10}';"),
					"the stored map must take a NUL key from SQL")
		}
		Rows := SQLite_Query(Db, "SELECT json_valid(" . Column . ") AS valid, (SELECT group_concat(h, ',') FROM "
			. "(SELECT hex(key) || '|' || value AS h FROM json_each(" . Column . ") ORDER BY hex(key))) AS keys FROM "
			. Table . ";")
		AssertEqual(1, Rows.Length)
		AssertEqual(1, Rows[1]["valid"], "the merged map must stay valid JSON")
		AssertEqual("61|20,610062|1", Rows[1]["keys"],
			"a NUL key must merge beside its own prefix; json_group_object folds it into a second 'a'")
	} finally {
		KLW.batch := SavedBatch
		SQLite_Close(Db)
	}
}
for Kind in ["ngram", "hourly", "hourly_min5", "bursts"]
	Test("walker: a NUL map key stays distinct across " . Kind . " merges (windows-sqlite-nul-map-keys)",
		_WJFM_NulMapKey.Bind(Kind))


_WCK_CheckRows(Db, Expected) {
	Rows := SQLite_Query(Db, "SELECT date,hex(app) AS app_hex,hex(token) AS token_hex,c,td,cd "
		. "FROM ngram_chars ORDER BY hex(app),hex(token);")
	AssertEqual(Expected.Length, Rows.Length, "every literal tuple must remain a distinct persisted row")
	for Index, Spec in Expected {
		Row := Rows[Index]
		AssertEqual("2026-11-04", Row["date"])
		AssertEqual(Spec[1], Row["app_hex"], "application bytes of row " . Index)
		AssertEqual(Spec[2], Row["token_hex"], "token bytes of row " . Index)
		AssertEqual(Spec[3], Row["c"], "count of row " . Index)
		AssertEqual(Spec[4], Row["td"], "total delay of row " . Index)
		AssertEqual(Spec[5], Row["cd"], "delay count of row " . Index)
	}
}

_WCK_NulToken() {
	SavedBatch := KLW.batch
	Db := _WJFM_OpenMemory()
	try {
		AssertTrue(KLR_LoadSchema(Db))
		KLW_ResetBatch()
		Day := "2026-11-04", App := "A"
		NulToken := "a" . Chr(0) . "b"
		AssertEqual(3, StrLen(NulToken), "the producer really receives all three code units")
		AssertTrue(RegExMatch(NulToken, "\x00") > 0)
		KLW_PushNgram("ngram_chars", Day, App, "a", 80, false, "none")
		KLW_PushNgram("ngram_chars", Day, App, NulToken, 160, false, "none")
		; A literal escape spelling must not alias the escaped NUL.
		KLW_PushNgram("ngram_chars", Day, App, "a" . Chr(2) . "0b", 240, false, "none")
		; Repetition remains additive; this is not a one-row-per-call expectation.
		KLW_PushNgram("ngram_chars", Day, App, "a", 40, false, "none")
		_WJFM_Flush(Db, "composite-key-device")
		_WCK_CheckRows(Db, [["41", "61", 2, 120, 2],
			["41", "610062", 1, 160, 1], ["41", "61023062", 1, 240, 1]])
	} finally {
		KLW.batch := SavedBatch
		SQLite_Close(Db)
	}
}
Test("walker: literal NUL tokens survive genuine producer and SQL flush (walker-composite-nul)", _WCK_NulToken)

_WCK_FieldBoundary() {
	SavedBatch := KLW.batch
	Db := _WJFM_OpenMemory()
	try {
		AssertTrue(KLR_LoadSchema(Db))
		KLW_ResetBatch()
		Day := "2026-11-04"
		KLW_PushNgram("ngram_chars", Day, "A" . Chr(1) . "B", "C", 80, false, "none")
		KLW_PushNgram("ngram_chars", Day, "A", "B" . Chr(1) . "C", 160, false, "none")
		; This app contains an actual Chr(2), followed by the literal text 1B.
		; It must stay distinct from the proposed escape spelling of Chr(1).
		KLW_PushNgram("ngram_chars", Day, "A" . Chr(2) . "1B", "C", 240, false, "none")
		_WJFM_Flush(Db, "composite-key-device")
		_WCK_CheckRows(Db, [["41", "420143", 1, 160, 1],
			["410142", "43", 1, 80, 1], ["41023142", "43", 1, 240, 1]])
	} finally {
		KLW.batch := SavedBatch
		SQLite_Close(Db)
	}
}
Test("walker: literal separators cannot move between application and token fields (walker-composite-boundary)", _WCK_FieldBoundary)

; Genuine replay regression: the accepted typing replay itself reaches the same
; defect. This is not a claim about a measured physical keyboard NUL sequence.
_WCK_TypingReplayNul() {
	SavedBatch := KLW.batch, SavedContext := KLW.ctx
	Db := _WJFM_OpenMemory()
	try {
		AssertTrue(KLR_LoadSchema(Db))
		KLW_ResetBatch()
		KLW.ctx := Map()
		KLW_WalkTypingEntry(Map("timestamp", "2026-11-04 10:00:00.000", "app", "A",
			"events", [["a", 80, Map()], ["a" . Chr(0) . "b", 160, Map()]]))
		_WJFM_Flush(Db, "composite-key-device")
		_WCK_CheckRows(Db, [["41", "61", 1, 80, 1], ["41", "610062", 1, 160, 1]])
	} finally {
		KLW.batch := SavedBatch
		KLW.ctx := SavedContext
		SQLite_Close(Db)
	}
}
Test("walker: accepted typing replay preserves a NUL-bearing literal token (walker-composite-typing)", _WCK_TypingReplayNul)


_WCK_ContextEnvelope() {
	Saved := KLW.ctx
	try {
		KLW.ctx := Map()
		Apps := ["A", "A" . Chr(0) . "B", "A" . Chr(1) . "B", "A" . Chr(2) . "0B"]
		for Index, App in Apps
			KLW_GetAppCtx(App)["codec_probe"] := Index
		AssertEqual(Apps.Length, KLW.ctx.Count, "literal app names must own independent contexts")
		Stored := KL_JsonDecode(KL_JsonEncode(KLW_SerializeCtx()))
		AssertEqual(1, Stored["key_format"])
		KLW.ctx := Map()
		KLW_RestoreCtx(Stored)
		for Index, App in Apps
			AssertEqual(Index, KLW_GetAppCtx(App)["codec_probe"], "versioned context keys round trip")
		KLW_RestoreCtx(Map("legacy-app", Map("p1", "ambiguous legacy state")))
		AssertEqual(0, KLW.ctx.Count, "legacy derived contexts are discarded instead of reinterpreted")
		KLW_RestoreCtx(Map("key_format", 2, "contexts", Stored["contexts"]))
		AssertEqual(0, KLW.ctx.Count, "unknown context key formats fail closed")
	} finally KLW.ctx := Saved
}
Test("walker: encoded application contexts round trip and retire legacy keys (walker-composite-context)", _WCK_ContextEnvelope)

_WCK_CodecVectors() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\keystats\composite_key_vectors.json", "UTF-8"))
	AssertEqual(1, Corpus["version"])
	AssertTrue(Corpus["vectors"].Length >= 8)
	Db := _WJFM_OpenMemory()
	try {
		for Vector in Corpus["vectors"] {
			Fields := Vector["fields"]
			Key := KLW_Key(Fields*)
			AssertFalse(RegExMatch(Key, "\x00"), Vector["id"] . ": internal keys never contain NUL")
			Rows := SQLite_Query(Db, "SELECT hex(" . SQLite_Q(Key) . ") AS encoded;")
			AssertEqual(Vector["encoded_utf8_hex"], Rows[1]["encoded"], Vector["id"] . ": canonical tuple bytes")
		}
	} finally SQLite_Close(Db)
}
Test("walker: shared array vectors pin the Windows internal key codec (walker-composite-codec)", _WCK_CodecVectors)
