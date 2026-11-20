; tests/unit/modules/keystats/reader/test_klr_replay_scope.ahk

; ==============================================================================
; MODULE: App-day scope of a worker refresh
; DESCRIPTION:
; A worker refresh replayed every app of every day a ledger tail named, 4 to
; 33 s on a heavy day for a few new keystrokes. It now replays only the
; (device, day, app) the tail inserted into or deleted from, and a whole day
; when the tail touches the per-day system sweep (KLR_ReplayScopeBegin). These
; cases pin both halves: the result equals a cold rebuild row for row, and an
; app the tail left alone is not replayed (klr-replay-scope-2026-11-20).
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Fixture =======
; ==========================
; ==========================

_KLRRS_Batch(Stamp, Rows) {
	return "`n-- === ingest batch " . Stamp . " (offset 0 -> 0, 1 entry(ies)) ===`n"
		. "BEGIN TRANSACTION;`n" . Rows . "COMMIT;`n"
}

_KLRRS_Window(Id, Stamp, Day, App, Prev, Next, Ms) {
	return _KLRRS_Batch(Stamp, "INSERT OR IGNORE INTO events_window_switch (device_id, id, ts, date, app, "
		. "prev_title, next_title, duration_ms) VALUES ('dev-one', " . Id . ", '" . Stamp . "', '" . Day
		. "', '" . App . "', '" . Prev . "', '" . Next . "', " . Ms . ");`n")
}

_KLRRS_System(Id, Stamp, Day, Action, Meta) {
	return _KLRRS_Batch(Stamp, "INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, "
		. "metadata_json) VALUES ('dev-one', " . Id . ", '" . Stamp . "', '" . Day . "', '" . Action
		. "', '" . Meta . "');`n")
}

; Typing with a title, so the title cap and focus time take part.
_KLRRS_Typing(Id, Stamp, Day, App, Title, Chars) {
	return StrReplace(_KLRDC_TypingBatch(Id, Stamp, Day, App, Chars),
		"'dev', NULL, NULL, NULL,", "'dev', '" . Title . "', NULL, NULL,")
}

; One day, two apps typing with window focus, plus a day with a system event.
; Each app types on one day only, so a cold build cannot chain n-grams across
; midnight where a refresh would not (test_klr_durable_cache owns that case).
_KLRRS_WriteBase() {
	_KLRDC_WriteLedger(_KLRDC_Header()
		. _KLRRS_Typing(1, "2026-02-01 09:00:00.000", "2026-02-01", "code.exe", "main.ahk", ["a", "b", "c", "d"])
		. _KLRRS_Typing(2, "2026-02-01 09:00:03.000", "2026-02-01", "chrome.exe", "docs", ["x", "y", "z"])
		. _KLRRS_Window(3, "2026-02-01 09:00:04.000", "2026-02-01", "code.exe", "main.ahk", "lib.ahk", 4000)
		. _KLRRS_Typing(4, "2026-02-01 09:00:06.000", "2026-02-01", "code.exe", "lib.ahk", ["e", "f"])
		. _KLRRS_Window(5, "2026-02-01 09:00:07.000", "2026-02-01", "chrome.exe", "docs", "mail", 7000)
		. _KLRRS_System(6, "2026-02-01 12:00:00.000", "2026-02-01", "unlock", '{"duration_ms":60000}')
		. _KLRRS_Typing(7, "2026-02-02 10:00:00.000", "2026-02-02", "notepad.exe", "notes", ["n", "o"]))
}

; A refresh through the production worker path.
_KLRRS_Refresh(Tail) {
	_KLRDC_AppendLedger(Tail)
	return _KLRDC_BuildAsWorker()
}

_KLRRS_ColdDump() {
	KLR_ResetCache()
	AssertTrue(FSDelete(KLR_CachePath(_KLRDC_Root())), "the fixture must be able to force a cold rebuild")
	return _KLROV_Dump(_KLRDC_BuildAsWorker())
}

; Plants a walker-owned value no replay of chrome.exe on 2026-02-01 could keep.
_KLRRS_PlantTripwire() {
	Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()))
	AssertTrue(Stored != 0, "the saved image must open for the tripwire")
	try AssertTrue(SQLite_Exec(Stored, "UPDATE agg_app_day_chars_class SET other=other+1000 "
		. "WHERE date='2026-02-01' AND app='chrome.exe';"), "the tripwire must be written")
	finally SQLite_Close(Stored)
}

_KLRRS_CharsClass(Db, App, Column) {
	Rows := SQLite_Query(Db, "SELECT " . Column . " AS v FROM agg_app_day_chars_class "
		. "WHERE date='2026-02-01' AND app=" . SQLite_Q(App) . ";")
	AssertEqual(1, Rows.Length, App . " must have its character classes of the day")
	return Rows[1]["v"]
}





; ========================================
; ========================================
; ======= 2/ Equal to a cold build =======
; ========================================
; ========================================

_KLRRS_CaseEqualsCold(Tail, Why) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	_KLRRS_WriteBase()
	_KLRDC_BuildAsWorker()
	Warm := _KLROV_Dump(_KLRRS_Refresh(Tail))
	Cold := _KLRRS_ColdDump()
	AssertTrue(InStr(Warm, "[agg_app_day_titles]`n") > 0, Why . ": the dump must read the image")
	AssertEqual(Cold, Warm, Why . ": a scoped refresh must equal a cold rebuild of the same ledger, "
		. "row for row (klr-replay-scope-2026-11-20)")
}

_KLRRS_ScopedRefreshesEqualCold() {
	try {
		_KLRRS_CaseEqualsCold(
			_KLRRS_Typing(10, "2026-02-01 09:00:09.000", "2026-02-01", "code.exe", "lib.ahk", ["g", "h", "i"]),
			"new typing of one app")
		_KLRRS_CaseEqualsCold(
			_KLRRS_Window(11, "2026-02-01 09:00:10.000", "2026-02-01", "code.exe", "lib.ahk", "main.ahk", 9000)
			. _KLRRS_Typing(12, "2026-02-01 09:00:11.000", "2026-02-01", "code.exe", "main.ahk", ["j"]),
			"a focus change and typing of one app")
		_KLRRS_CaseEqualsCold(
			_KLRRS_System(13, "2026-02-01 13:00:00.000", "2026-02-01", "wake", '{"duration_ms":30000}')
			. _KLRRS_Typing(14, "2026-02-01 13:00:01.000", "2026-02-01", "chrome.exe", "mail", ["k"]),
			"a system event, which rebuilds the whole day")
		_KLRRS_CaseEqualsCold(
			_KLRRS_Typing(15, "2026-02-03 08:00:00.000", "2026-02-03", "word.exe", "report", ["r", "s"])
			. _KLRRS_Typing(16, "2026-02-01 09:00:12.000", "2026-02-01", "code.exe", "lib.ahk", ["t"]),
			"typing on a new day and on an old one")
		; Bytes already consumed, appended again: INSERT OR IGNORE changes nothing.
		_KLRRS_CaseEqualsCold(
			_KLRRS_Typing(2, "2026-02-01 09:00:03.000", "2026-02-01", "chrome.exe", "docs", ["x", "y", "z"]),
			"a re-appended row")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR replay scope: an app-scoped refresh equals a cold rebuild row for row (klr-replay-scope-2026-11-20)",
	_KLRDC_CheckTeardown.Bind(_KLRRS_ScopedRefreshesEqualCold))





; ===============================================
; ===============================================
; ======= 3/ Only the touched apps replay =======
; ===============================================
; ===============================================

_KLRRS_UntouchedAppIsNotReplayed() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRRS_WriteBase()
		Before := _KLRRS_CharsClass(_KLRDC_BuildAsWorker(), "code.exe", "letter")
		_KLRRS_PlantTripwire()
		; New keystrokes of code.exe only: chrome.exe's rows of that day stay as stored.
		Db := _KLRRS_Refresh(
			_KLRRS_Typing(20, "2026-02-01 09:00:20.000", "2026-02-01", "code.exe", "lib.ahk", ["u"]))
		AssertEqual(Before + 1, _KLRRS_CharsClass(Db, "code.exe", "letter"), "the touched app must be replayed")
		AssertTrue(_KLRRS_CharsClass(Db, "chrome.exe", "other") >= 1000,
			"a refresh must not replay an app the tail did not touch (klr-replay-scope-2026-11-20)")

		; A system event belongs to the whole day: every app of it is replayed.
		Db := _KLRRS_Refresh(
			_KLRRS_System(21, "2026-02-01 14:00:00.000", "2026-02-01", "wake", '{"duration_ms":1000}'))
		AssertTrue(_KLRRS_CharsClass(Db, "chrome.exe", "other") < 1000,
			"a tail touching the day's system sweep must rebuild every app of that day")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR replay scope: an app the tail did not touch is not replayed, a system event replays the day (klr-replay-scope-2026-11-20)",
	_KLRDC_CheckTeardown.Bind(_KLRRS_UntouchedAppIsNotReplayed))
