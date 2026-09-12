; tests/unit/test_klr_cache_fixture.ahk

; ==============================================================================
; MODULE: Reader Cache Disk Fixtures
; DESCRIPTION: Own synthetic ledgers and verify fixture isolation and teardown.
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
