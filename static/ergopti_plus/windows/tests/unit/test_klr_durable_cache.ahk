; static/ergopti_plus/windows/tests/unit/test_klr_durable_cache.ahk

; ==============================================================================
; MODULE: Durable Reader Cache Tests (klr-reader-durable-cache)
; DESCRIPTION:
; Every projection runs in a disposable worker, so KLRCache always started empty
; and each dashboard open rebuilt the whole history: replay data.sql, project
; every typing payload, GROUP BY everything, then walk every raw event through
; the stateful walker. The cache persists that finished image so the next worker
; only has to apply the bytes appended since.
;
; The load-bearing property is not "it is faster" — it is that the cheap path
; produces the SAME rows as the expensive one. The equivalence case below builds
; one ledger twice, once incrementally through the cache and once cold, and
; compares every derived table the dashboard reads. Everything else here guards
; the conditions under which reusing an image is legitimate at all.
;
; These run against the real vendored SQLite DLL, the real schema and the real
; walker: a stub would prove nothing about a cache whose entire purpose is to
; stand in for that pipeline's output.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================
; ================================================
; ======= 1/ A ledger fixture on real disk =======
; ================================================
; ================================================

global _KLRDC_FixtureRoot := ""
global _KLRDC_FixtureSerial := 0

_KLRDC_AcquireOwnedRoot(Candidate) {
	if DllCall("Kernel32\CreateDirectoryW", "Str", Candidate, "Ptr", 0, "Int")
		return Candidate . "\"
	if (A_LastError = 183)
		throw Error("fixture root already exists")
	throw OSError(A_LastError, "CreateDirectoryW")
}

_KLRDC_Root() {
	global _KLRDC_FixtureRoot, _KLRDC_FixtureSerial
	if (_KLRDC_FixtureRoot != "")
		return _KLRDC_FixtureRoot

	Base := A_Temp . "\ergopti_klr_durable_cache_" . ProcessExist() . "_"
	loop 128 {
		_KLRDC_FixtureSerial += 1
		Candidate := Base . _KLRDC_FixtureSerial
		try {
			_KLRDC_FixtureRoot := _KLRDC_AcquireOwnedRoot(Candidate)
			return _KLRDC_FixtureRoot
		} catch Error as Failure {
			if (Failure.Message = "fixture root already exists")
				continue
			throw Failure
		}
	}
	throw Error("unable to acquire an exclusive durable-cache fixture root")
}

_KLRDC_ReleaseRoot() {
	global _KLRDC_FixtureRoot
	if (_KLRDC_FixtureRoot = "")
		return
	DirDelete(RTrim(_KLRDC_FixtureRoot, "\\"), true)
	_KLRDC_FixtureRoot := ""
}

_KLRDC_RefusesAnOccupiedFixtureRoot() {
	Candidate := A_Temp . "\ergopti_klrdc_occupied_" . A_ScriptHwnd . "_" . A_TickCount
	Sentinel := Candidate . "\sentinel.txt"
	DirCreate(Candidate)
	try {
		FileAppend("do not delete", Sentinel, "UTF-8-RAW")
		Failure := 0
		try _KLRDC_AcquireOwnedRoot(Candidate)
		catch Error as Caught
			Failure := Caught
		AssertTrue(IsObject(Failure),
			"a pre-existing fixture directory belongs to an unknown owner")
		AssertContains(Failure.Message, "fixture root already exists",
			"the failure must identify a collision rather than another setup error")
		AssertEqual("do not delete", FileRead(Sentinel, "UTF-8-RAW"),
			"refusing an occupied root must leave its content untouched")
	} finally {
		try DirDelete(Candidate, true)
	}
}
Test("KLR durable cache: fixture refuses occupied root (klr-cache-fixture-ownership)",
	_KLRDC_RefusesAnOccupiedFixtureRoot)

_KLRDC_LedgerPath() {
	return _KLRDC_Root() . "by_device\dev-one\data.sql"
}

; The reader resolves schema.sql relative to the shared tree. The headless
; runner never boots the driver, so name it here rather than depending on an
; include order that has no reason to guarantee it.
_KLRDC_EnsureSharedDir() {
	global _SharedDir
	if !IsSet(_SharedDir) || (_SharedDir = "")
		_SharedDir := A_ScriptDir . "\..\_shared"
}

_KLRDC_Cleanup() {
	KLR_ResetCache()
	_KLRDC_ReleaseRoot()
}

_KLRDC_Reset() {
	_KLRDC_Cleanup()
	DirCreate(_KLRDC_Root() . "by_device\dev-one")
}

; Observe teardown without calling the allocating root getter. Keep the existing
; SQLite scenarios as the workload instead of replaying them in duplicate tests.
_KLRDC_CheckTeardown(Scenario) {
	global _KLRDC_FixtureRoot, _KLRDC_FixtureSerial
	KLR_ResetCache()
	_KLRDC_ReleaseRoot()
	BeforeSerial := _KLRDC_FixtureSerial
	Pattern := A_Temp . "\ergopti_klr_durable_cache_" . ProcessExist() . "_*"
	Before := Map()
	loop files Pattern, "D"
		Before[A_LoopFileFullPath] := true
	Failure := 0
	try {
		Scenario.Call()
		AssertTrue(_KLRDC_FixtureSerial > BeforeSerial,
			"the scenario must acquire a real disk fixture")
		AssertEqual("", _KLRDC_FixtureRoot,
			"successful cache scenario teardown must release its fixture root")
		loop files Pattern, "D"
			AssertTrue(Before.Has(A_LoopFileFullPath),
				"cache scenario must not leave a new directory: " . A_LoopFileFullPath)
	} catch Error as Caught {
		Failure := Caught
	} finally {
		try {
			KLR_ResetCache()
			_KLRDC_ReleaseRoot()
		} catch Error as CleanupFailure {
			if IsObject(Failure)
				Failure.Message .= " | fixture cleanup failed: " . CleanupFailure.Message
			else
				Failure := CleanupFailure
		}
	}
	if IsObject(Failure)
		throw Failure
}

; One ingest batch in the exact shape the writer appends: a header comment, a
; transaction, and the COMMIT that closes it.
_KLRDC_TypingBatch(Id, Stamp, Day, App, Chars) {
	Json := ""
	Text := ""
	for Char in Chars {
		Json .= (Json = "" ? "" : ",") . '["' . Char . '",120,{"kc":65,"sk":30}]'
		Text .= Char
	}
	return "`n-- === ingest batch " . Stamp . " (offset 0 -> 0, 1 entry(ies)) ===`n"
		. "BEGIN TRANSACTION;`n"
		. "INSERT OR IGNORE INTO events_typing (device_id, id, ts, date, app, "
		. "app_category, title, url, field_role, layout, document_path, "
		. "is_fullscreen, in_meeting, mouse_clicks, mouse_scrolls, "
		. "mouse_distance_px, pause_before_ms, battery_level, audio_volume, wpm, "
		. "text, rich_text, events_json) VALUES ('dev-one', " . Id . ", '"
		. Stamp . "', '" . Day . "', '" . App . "', 'dev', NULL, NULL, NULL, "
		. "NULL, NULL, 0, 0, 0, 0, 0, 150, NULL, NULL, 120.0, '" . Text
		. "', NULL, '[" . Json . "]');`n"
		. "COMMIT;`n"
}

_KLRDC_Header() {
	return "-- ergopti metrics — device dev-one — schema_version 1`n"
		. "PRAGMA foreign_keys = OFF;`n"
}

_KLRDC_WriteLedger(Content) {
	Path := _KLRDC_LedgerPath()
	try FileDelete(Path)
	FileAppend(Content, Path, "UTF-8-RAW")
}

_KLRDC_AppendLedger(Content) {
	FileAppend(Content, _KLRDC_LedgerPath(), "UTF-8-RAW")
}

; Canonical dump of every derived table a refresh is allowed to touch. Ordering
; is explicit so the comparison cannot pass on row order alone.
_KLRDC_DerivedFingerprint(db) {
	Dump := ""
	Queries := Map(
		"agg_app_day", "SELECT device_id, date, app, chars, pauses, time_ms, "
			. "think_time_ms FROM agg_app_day ORDER BY device_id, date, app",
		"agg_app_day_hourly", "SELECT device_id, date, app, hour, c, e "
			. "FROM agg_app_day_hourly ORDER BY device_id, date, app, hour",
		"agg_app_day_chars_class", "SELECT device_id, date, app, letter, digit, "
			. "punct, space, other FROM agg_app_day_chars_class "
			. "ORDER BY device_id, date, app",
		"ngram_chars", "SELECT device_id, date, app, token, c FROM ngram_chars "
			. "ORDER BY device_id, date, app, token",
		"ngram_bigrams", "SELECT device_id, date, app, token, c "
			. "FROM ngram_bigrams ORDER BY device_id, date, app, token")
	for Label, Sql in Queries {
		Dump .= "[" . Label . "]`n"
		for Row in SQLite_Query(db, Sql . ";") {
			Line := ""
			for Column, Value in Row
				Line .= Column . "=" . Value . ";"
			Dump .= Line . "`n"
		}
	}
	return Dump
}

; One full build through the production entry point, as a fresh worker would.
_KLRDC_BuildAsWorker() {
	KLR_ResetCache()
	KLRCache.disposable := true
	db := KLR_BuildDatabase(_KLRDC_Root())
	AssertTrue(db != 0, "the fixture ledger must produce a reader database")
	return db
}





; ==============================================
; ==============================================
; ======= 2/ The cheap path must not lie =======
; ==============================================
; ==============================================

_KLRDC_RefreshMatchesColdRebuild() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Day1 := _KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a", "b", "c"])
			. _KLRDC_TypingBatch(2, "2026-01-01 10:00:02.000", "2026-01-01",
				"code.exe", ["a", "b"])
		_KLRDC_WriteLedger(Day1)

		; A first worker: nothing cached, so this is the full cold rebuild that
		; also publishes the image for its successor.
		_KLRDC_BuildAsWorker()
		AssertTrue(FSExists(KLR_CachePath(_KLRDC_Root())),
			"a completed cold build must leave a reusable image behind, or every "
			. "later dashboard open pays for the whole history again "
			. "(klr-reader-durable-cache)")

		; A second worker after the writer appended a new day. The new day belongs
		; to another app so the two builds cannot differ over the walker's
		; cross-midnight n-gram chain, which the case below covers on its own.
		_KLRDC_AppendLedger(
			_KLRDC_TypingBatch(3, "2026-01-02 09:00:00.000", "2026-01-02",
				"chrome.exe", ["c", "a", "b"]))
		WarmDb := _KLRDC_BuildAsWorker()
		Warm := _KLRDC_DerivedFingerprint(WarmDb)

		; The same two days with no cache at all.
		AssertTrue(FSDelete(KLR_CachePath(_KLRDC_Root())),
			"the fixture must be able to force a cold rebuild")
		ColdDb := _KLRDC_BuildAsWorker()
		Cold := _KLRDC_DerivedFingerprint(ColdDb)

		AssertTrue(Warm != "", "the fingerprint must actually read rows")
		AssertEqual(Cold, Warm,
			"an incremental refresh must produce exactly what a cold rebuild "
			. "produces: the cache is only legitimate while the cheap path and "
			. "the expensive one agree (klr-reader-durable-cache)")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: a cached refresh equals a cold rebuild (klr-reader-durable-cache)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_RefreshMatchesColdRebuild))

_KLRDC_UnchangedLedgerSkipsRework() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["x", "y"]))
		Before := _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker())

		; A tripwire only a rebuild can trip: an event that exists inside the
		; stored image but in no rollup and in no ledger byte. Returning the image
		; leaves it invisible; recomputing anything over the whole history — the
		; 71 s step this path exists to skip — would fold it into agg_app_day.
		stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()))
		AssertTrue(stored != 0, "the published image must be reopenable")
		try {
			Payload := SQLite_Q('[["z",1,{}],["z",1,{}],["z",1,{}]]')
			AssertTrue(SQLite_Exec(stored,
				"INSERT INTO events_typing (device_id, id, ts, date, app, "
				. "is_fullscreen, in_meeting, mouse_clicks, mouse_scrolls, "
				. "mouse_distance_px, text, events_json) VALUES ('dev-one', 900, "
				. "'2026-01-01 11:00:00.000', '2026-01-01', 'code.exe', 0, 0, 0, "
				. "0, 0, 'zzz', " . Payload . ");"
				. "INSERT INTO klr_reader_typing_payload (device_id, event_id, "
				. "events_json) VALUES ('dev-one', 900, " . Payload . ");"),
				"the tripwire row must be storable")
		} finally {
			try SQLite_Close(stored)
		}

		After := _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker())
		AssertEqual(Before, After,
			"reopening a dashboard against an unchanged ledger must return the "
			. "cached rows untouched: every rollup in that image was computed "
			. "from exactly these bytes, and recomputing them costs O(whole "
			. "history) to derive identical rows (klr-reader-durable-cache)")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: an unchanged ledger returns the cached image (klr-reader-durable-cache)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_UnchangedLedgerSkipsRework))

; The one place the cheap path deliberately differs, pinned so it cannot drift
; into something larger. The walker's n-gram chain has no time or day boundary:
; a cold rebuild walks every event of a device in one stream, so it emits a
; bigram joining the last keystroke before midnight to the first one after — a
; pair separated, here, by 23 hours. A refresh replays whole affected days with
; a fresh context, so that token is not produced.
;
; This is a bounded and defensible loss: it is at most one token per n-gram
; width per app per day boundary, and a "pair" the user typed hours apart is
; noise in the first place. What must NOT happen is a refresh dropping or
; double-counting anything inside the day it recomputes, which the equivalence
; case above owns.
_KLRDC_RefreshDoesNotChainAcrossDays() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 23:59:00.000", "2026-01-01",
				"code.exe", ["a", "b"]))
		_KLRDC_BuildAsWorker()
		_KLRDC_AppendLedger(
			_KLRDC_TypingBatch(2, "2026-01-02 09:00:00.000", "2026-01-02",
				"code.exe", ["c", "d"]))
		db := _KLRDC_BuildAsWorker()

		Tokens := ""
		for Row in SQLite_Query(db, "SELECT token FROM ngram_bigrams "
				. "WHERE date='2026-01-02' ORDER BY token;")
			Tokens .= (Tokens = "" ? "" : ",") . Row["token"]
		AssertEqual("cd", Tokens,
			"a refreshed day must contain exactly the pairs typed inside it: "
			. "'bc' would mean the walker chained across a 9-hour gap, and any "
			. "missing pair would mean the day was not fully replayed "
			. "(klr-reader-durable-cache)")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: a refreshed day does not chain n-grams to the day before (klr-reader-durable-cache)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_RefreshDoesNotChainAcrossDays))





; A worker refreshes its restored image in place, so a tail that stops half-way
; leaves rows applied whose rollups were never recomputed. Publishing that would
; show numbers nobody computed, so the build must fail outright and leave the
; image on disk untouched for the next attempt.
_KLRDC_TornTailAbandonsTheImage() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a", "b"]))
		_KLRDC_BuildAsWorker()
		CachePath := KLR_CachePath(_KLRDC_Root())
		AssertTrue(FSExists(CachePath), "the first build must publish an image")

		; The writer is caught mid-append: a transaction with no COMMIT yet.
		Torn := _KLRDC_TypingBatch(2, "2026-01-01 10:00:04.000", "2026-01-01",
			"code.exe", ["c", "d"])
		_KLRDC_AppendLedger(SubStr(Torn, 1, InStr(Torn, "COMMIT;") - 1))

		KLR_ResetCache()
		KLRCache.disposable := true
		AssertEqual(0, KLR_BuildDatabase(_KLRDC_Root()),
			"a torn tail must fail the build instead of returning an image whose "
			. "applied rows have no rollups (klr-reader-durable-cache)")
		AssertTrue(FSExists(CachePath),
			"the last good image must survive a failed refresh: the next worker "
			. "re-applies the same tail from it")

		; The writer finishes its batch.
		_KLRDC_AppendLedger("COMMIT;`n")
		db := _KLRDC_BuildAsWorker()
		Rows := SQLite_Query(db,
			"SELECT chars FROM agg_app_day WHERE date='2026-01-01';")
		AssertTrue(Rows.Length = 1 && Rows[1]["chars"] = 4,
			"once the transaction closes, the retry must land every keystroke of "
			. "both batches")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: a torn tail abandons the refresh (klr-reader-durable-cache)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_TornTailAbandonsTheImage))

_KLRDC_StoredOffset() {
	stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
	AssertTrue(stored != 0, "the published image must be readable")
	try {
		Rows := SQLite_Query(stored, "SELECT end_offset FROM klr_cache_ledger;")
		return (Rows.Length > 0) ? Rows[1]["end_offset"] : -1
	} finally {
		try SQLite_Close(stored)
	}
}

; Publishing copies every page of the image. On the store this was built
; against that is 650 MB, and an open dashboard refreshes every few seconds:
; saving each time would pour hundreds of megabytes a minute onto the user's
; disk to record a handful of keystrokes. A skipped save costs the next worker
; only the tail it was going to read anyway.
_KLRDC_SaveIsThrottled() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Published := _KLRDC_StoredOffset()
		AssertTrue(Published > 0,
			"the first build must publish an image with a real offset")

		_KLRDC_AppendLedger(
			_KLRDC_TypingBatch(2, "2026-01-01 10:00:03.000", "2026-01-01",
				"code.exe", ["b"]))
		db := _KLRDC_BuildAsWorker()
		AssertEqual(Published, _KLRDC_StoredOffset(),
			"a refresh moments after the last publish must not rewrite the whole "
			. "image (klr-reader-durable-cache)")

		Rows := SQLite_Query(db,
			"SELECT chars FROM agg_app_day WHERE date='2026-01-01';")
		AssertTrue(Rows.Length = 1 && Rows[1]["chars"] = 2,
			"throttling the save must not hold back the refresh itself: this "
			. "dashboard still has to show both keystrokes")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: publishing the image is throttled (klr-reader-durable-cache)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_SaveIsThrottled))





; ==================================================
; ==================================================
; ======= 3/ When an image may not be reused =======
; ==================================================
; ==================================================

_KLRDC_LegacyJsonImageIsRefused() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		Before := _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker())
		CachePath := KLR_CachePath(_KLRDC_Root())
		KLR_ResetCache()
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), A_Temp . "\ergopti_klrdc.log"),
			"the freshly produced image must be valid before changing its version")
		KLR_ResetCache()
		Stored := SQLite_Open(CachePath)
		AssertTrue(Stored != 0)
		try {
			AssertTrue(SQLite_Exec(Stored,
				"UPDATE klr_cache_meta SET value='1' WHERE key='format_version';"))
			AssertEqual("1", _KLR_CacheMetaValue(Stored, "format_version"))
		} finally {
			SQLite_Close(Stored)
		}
		AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), A_Temp . "\ergopti_klrdc.log"),
			"images built with truncating JSON flushes must force reconstruction")
		AssertFalse(FSExists(CachePath), "the rejected image must be retired")
		AssertEqual(Before, _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker()),
			"the original ledger must remain available for a clean rebuild")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: legacy JSON image forces rebuild (walker-json-cache-version)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_LegacyJsonImageIsRefused))

_KLRDC_ReadonlyImage(Disposable) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a", "b"]))
		Before := _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker())
		CachePath := KLR_CachePath(_KLRDC_Root())
		AssertTrue(FSExists(CachePath))
		KLR_ResetCache()
		KLRCache.disposable := Disposable
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), A_Temp . "\ergopti_klrdc.log"))
		Db := KLRCache.db
		AssertEqual(Disposable ? 1 : 0,
			DllCall(SQLiteConst.DLL . "\sqlite3_db_readonly", "Ptr", Db, "AStr", "main", "Int"),
			"only a disposable worker may retain the read-only image")
		AssertEqual(Before, _KLRDC_DerivedFingerprint(Db))
		if Disposable {
			AssertEqual(Db, KLR_BuildDatabase(_KLRDC_Root()),
				"an unchanged worker must keep its validated image")
			AssertEqual(Before, _KLRDC_DerivedFingerprint(Db))
			_KLRDC_AppendLedger(_KLRDC_TypingBatch(2,
				"2026-01-01 10:00:02.000", "2026-01-01", "code.exe", ["c"]))
			Db := KLR_BuildDatabase(_KLRDC_Root())
			AssertTrue(Db != 0, "a tail must materialize a writable candidate")
			AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_db_readonly",
				"Ptr", Db, "AStr", "main", "Int"))
			Rows := SQLite_Query(Db, "SELECT SUM(chars) AS chars FROM agg_app_day;")
			AssertEqual(3, Rows[1]["chars"], "the appended tail must reach the projection exactly once")
			Warm := _KLRDC_DerivedFingerprint(Db)
			KLR_ResetCache()
			AssertTrue(FSDelete(CachePath), "reset must release every cache file handle")
			AssertEqual(Warm, _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker()))
		} else {
			AssertTrue(SQLite_Exec(Db, "CREATE TABLE readonly_live_control (value INTEGER);"),
				"resident attachment must still support its private live writes")
		}
		KLR_ResetCache()
		KLRCache.disposable := Disposable
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), A_Temp . "\ergopti_klrdc.log"))
		KLR_ResetCache()
		AssertTrue(FSDelete(CachePath), "reset must close a freshly attached image before deletion")
	} finally {
		_KLRDC_Cleanup()
	}
}
for Disposable in [false, true]
	Test("KLR durable cache: readonly reuse disposable=" . Disposable . " (klr-readonly-image)",
		_KLRDC_CheckTeardown.Bind(_KLRDC_ReadonlyImage.Bind(Disposable)))

_KLRDC_ReadonlyPublicationLock() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Reader := 0
	Candidate := 0
	Reopened := 0
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Offsets := KLR_CopyOffsets(KLRCache.last_sizes)
		Snapshots := KLR_CopyLedgerSnapshots(KLRCache.ledger_snapshots)
		CachePath := KLR_CachePath(_KLRDC_Root())
		KLR_ResetCache()
		Reader := SQLite_Open(CachePath, SQLiteConst.OPEN_RO)
		AssertTrue(Reader != 0)
		Before := _KLRDC_DerivedFingerprint(Reader)
		Candidate := SQLite_CloneMemory(Reader)
		AssertTrue(Candidate != 0)
		AssertTrue(SQLite_Exec(Candidate,
			"CREATE TABLE readonly_publication_marker (value INTEGER);"
			. "INSERT INTO readonly_publication_marker VALUES (37);"))
		AssertEqual(0, KLR_CacheSave(Candidate, Offsets, _KLRDC_Root(), A_Temp . "\ergopti_klrdc.log", Snapshots),
			"a native reader must refuse replacement without invalidating the old image")
		AssertEqual(Before, _KLRDC_DerivedFingerprint(Reader))
		Reopened := SQLite_Open(CachePath, SQLiteConst.OPEN_RO)
		AssertTrue(Reopened != 0)
		Rows := SQLite_Query(Reopened,
			"SELECT COUNT(*) AS n FROM sqlite_master WHERE name='readonly_publication_marker';")
		AssertEqual(0, Rows[1]["n"], "failed publication must not modify the canonical image")
		SQLite_Close(Reopened)
		Reopened := 0
		SQLite_Close(Reader)
		Reader := 0
		AssertEqual(1, KLR_CacheSave(Candidate, Offsets, _KLRDC_Root(), A_Temp . "\ergopti_klrdc.log", Snapshots))
		Reopened := SQLite_Open(CachePath, SQLiteConst.OPEN_RO)
		AssertTrue(Reopened != 0)
		Rows := SQLite_Query(Reopened, "SELECT value FROM readonly_publication_marker;")
		AssertEqual(1, Rows.Length)
		AssertEqual(37, Rows[1]["value"])
	} finally {
		try {
			if Reopened
				SQLite_Close(Reopened)
			if Reader
				SQLite_Close(Reader)
			if Candidate
				SQLite_Close(Candidate)
		} finally {
			_KLRDC_Cleanup()
		}
	}
}
Test("KLR durable cache: readonly reader fences atomic publication (klr-readonly-image)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_ReadonlyPublicationLock))

_KLRDC_ReadonlyOwnershipCannotChange() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Db := _KLRDC_BuildAsWorker()
		AssertEqual(1, DllCall(SQLiteConst.DLL . "\sqlite3_db_readonly",
			"Ptr", Db, "AStr", "main", "Int"))
		KLRCache.disposable := false
		Failure := 0
		try KLR_BuildDatabase(_KLRDC_Root())
		catch as Err
			Failure := Err
		AssertTrue(Failure is Error)
		AssertContains(Failure.Message, "resident ownership")
		AssertEqual(Db, KLRCache.db, "invalid ownership must not replace the existing handle")
		AssertTrue(_KLRDC_DerivedFingerprint(Db) != "")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: readonly ownership cannot become resident (klr-readonly-image)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_ReadonlyOwnershipCannotChange))

_KLRDC_ReplacedLedgerIsRefused() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		CachePath := KLR_CachePath(_KLRDC_Root())
		AssertTrue(FSExists(CachePath), "the first build must publish an image")

		; A compaction rewrites data.sql as a different file. Every byte offset
		; in the image now names the wrong bytes.
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"])
			. _KLRDC_TypingBatch(2, "2026-01-01 10:00:05.000", "2026-01-01",
				"code.exe", ["b"]))

		KLR_ResetCache()
		Attached := KLR_CacheAttach(_KLRDC_Root(), A_Temp . "\ergopti_klrdc.log")
		AssertEqual(0, Attached,
			"a replaced ledger must force a cold rebuild: its offsets no longer "
			. "point at the bytes the image was built from")
		AssertFalse(FSExists(CachePath),
			"a refused image must be deleted, not left for the next worker to "
			. "reject again")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: a replaced ledger refuses the image (klr-reader-durable-cache)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_ReplacedLedgerIsRefused))

_KLRDC_NewDeviceIsRefused() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01",
				"code.exe", ["a"]))
		_KLRDC_BuildAsWorker()

		; A second machine's ledger appears. It has no offset in the image and no
		; replayed walker state, and there is no correct partial answer for it.
		SecondDir := _KLRDC_Root() . "by_device\dev-two"
		DirCreate(SecondDir)
		FileAppend(_KLRDC_Header(), SecondDir . "\data.sql", "UTF-8-RAW")

		KLR_ResetCache()
		AssertEqual(0, KLR_CacheAttach(_KLRDC_Root(), A_Temp . "\ergopti_klrdc.log"),
			"a ledger the image never saw must force a cold rebuild")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR durable cache: an unknown device ledger refuses the image (klr-reader-durable-cache)",
	_KLRDC_CheckTeardown.Bind(_KLRDC_NewDeviceIsRefused))





; ============================================
; ============================================
; ======= 4/ Scoping a refresh by date =======
; ============================================
; ============================================

_KLRDC_DateScopeSelectsNothingWhenEmpty() {
	; The distinction that keeps a bug from becoming a silent full rebuild: no
	; scope at all means every row, an EMPTY scope means none.
	AssertEqual("", _KLR_DateScope(0, "date"),
		"a missing scope must leave the rollup unrestricted")
	AssertEqual(" AND 0", _KLR_DateScope([], "date"),
		"an empty scope must select nothing, never everything")
	AssertEqual(" AND date IN ('2026-01-01')", _KLR_DateScope(["2026-01-01"], "date"),
		"a scoped rollup must restrict its source table to those days")
}
Test("KLR durable cache: an empty date scope selects nothing (klr-reader-durable-cache)",
	_KLRDC_DateScopeSelectsNothingWhenEmpty)

_KLRDC_AffectedDatesFollowTheTail() {
	AssertEqual(0, KLR_CacheAffectedDates(Map()).Length,
		"with nothing appended, no day can have changed")

	Tails := Map("ledger", Map("sql",
		_KLRDC_TypingBatch(2, "2026-01-02 09:00:00.000", "2026-01-02",
			"code.exe", ["z"])))
	Dates := KLR_CacheAffectedDates(Tails)
	AssertEqual(1, Dates.Length,
		"only the day the appended bytes carry may be recomputed; got "
		. Dates.Length)
	AssertEqual("2026-01-02", Dates[1],
		"the affected day must be the one the appended event carries")

	; The event id cannot be the source of truth here: the writer's counter
	; restarts after an interrupted append, so the live store really does hold a
	; 2026-09-05 row with a LOWER id than a 2026-09-04 one. A rule based on "ids
	; above the previous maximum" reports zero affected days for a whole day of
	; typing, and the refresh silently recomputes nothing.
	Restarted := Map("ledger", Map("sql",
		_KLRDC_TypingBatch(1, "2026-09-05 08:00:00.000", "2026-09-05",
			"code.exe", ["q"])))
	AssertEqual("2026-09-05", KLR_CacheAffectedDates(Restarted)[1],
		"a tail whose ids restarted below the stored maximum must still name its "
		. "day (klr-reader-durable-cache)")
}
Test("KLR durable cache: affected days follow the appended bytes (klr-reader-durable-cache)",
	_KLRDC_AffectedDatesFollowTheTail)
