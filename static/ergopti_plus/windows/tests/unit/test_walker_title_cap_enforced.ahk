; tests/unit/test_walker_title_cap_enforced.ahk

; ==============================================================================
; MODULE: Per-App-Day Title Cap Enforcement (walker-title-cap-declared-but-dead)
; DESCRIPTION:
; KLWConst.TITLE_CAP_PER_APP_DAY was declared on Windows and read by nobody: a
; repo-wide grep returned exactly one hit, the declaration itself. Neither the
; live walker flush (KLW_BuildBatchSql) nor the cold rebuild
; (KLR_RebuildAggregates) bounded agg_app_day_titles, so the table — and the
; win_titles list projected from it into the prefetch blob the dashboard
; downloads — grew one permanent row per distinct window title.
;
; ROOT CAUSE ENCODED: a declared cap is not an enforced cap. Any app whose title
; carries variable content (browser tabs, chat unread counts, editor "file:line"
; captions, terminal progress spinners) produces a fresh title on every switch,
; so the set is unbounded by construction. The macOS twin has always run the
; cleanup DELETE (macos/modules/keylogger/aggregator/sql.lua); the Windows port
; copied the constant across but not the statement that gives it meaning.
;
; SCOPE: behavioural for the live flush (the walker module is loaded by the
; headless runner), source-introspection for the cold rebuild (KLR_* needs a
; real SQLite handle), plus a cross-driver single-source check on the constant.
; ==============================================================================

#Requires AutoHotkey v2.0

_WTC_ReplayPreservesRetainedTitleCount(SplitFlushes := false, Scoped := false) {
	Db := _WJFM_OpenMemory()
	SavedFlushSize := KLReadConst.REPLAY_FLUSH_ENTRIES
	try {
		AssertTrue(KLR_LoadSchema(Db))
		Sql := "INSERT INTO events_window_switch "
			. "(device_id,id,ts,date,app,prev_title,next_title,duration_ms) VALUES "
			. "('cap-device',1,'2026-01-01T10:00:00','2026-01-01','cap.exe','','retained',0)"
			. ",('cap-device',2,'2026-01-01T10:01:00','2026-01-01','cap.exe','retained','',60000)"
		Loop KLWConst.TITLE_CAP_PER_APP_DAY {
			Title := SQLite_Q("frequent-" . A_Index)
			for Id in [A_Index * 2 + 1, A_Index * 2 + 2]
				Sql .= ",('cap-device'," . Id . ",'2026-01-01T11:00:00',"
					. "'2026-01-01','cap.exe',''," . Title . ",0)"
		}
		if SplitFlushes {
			KLReadConst.REPLAY_FLUSH_ENTRIES := 1
			Sql .= ",('cap-device',9999,'2026-01-01T09:00:00',"
				. "'2026-01-01','cap.exe','retained','',1)"
		}
		AssertTrue(SQLite_Exec(Db, Sql . ";"))
		AssertTrue(SQLite_Exec(Db, "INSERT INTO agg_app_day_titles VALUES "
			. "('cap-device','2025-12-31','cap.exe','untouched',7,9);"))
		Dates := Scoped ? ["2026-01-01"] : 0
		AssertTrue(KLR_PrepareTypingProjection(Db))
		AssertTrue(KLR_RebuildAggregates(Db, Dates))
		AssertTrue(KLR_RebuildWalkerAggregates(Db, true, Dates) >= 0)
		Rows := SQLite_Query(Db,
			"SELECT c,ms FROM agg_app_day_titles WHERE title='retained';")
		AssertEqual(1, Rows.Length, "long focus must retain the title under the cap")
		AssertEqual(SplitFlushes ? 60001 : 60000, Rows[1]["ms"],
			"the real window replay must retain focus time across flush boundaries")
		AssertEqual(1, Rows[1]["c"], "a retained title must keep its raw switch count")
		AssertEqual(KLWConst.TITLE_CAP_PER_APP_DAY,
			SQLite_Query(Db, "SELECT COUNT(*) AS n FROM agg_app_day_titles WHERE date='2026-01-01';")[1]["n"],
			"the final projection must still enforce the title cap")
		Other := SQLite_Query(Db, "SELECT c,ms FROM agg_app_day_titles WHERE title='untouched';")
		AssertEqual(1, Other.Length)
		AssertEqual(7, Other[1]["c"])
		AssertEqual(9, Other[1]["ms"])
	} finally {
		KLReadConst.REPLAY_FLUSH_ENTRIES := SavedFlushSize
		SQLite_Close(Db)
	}
}

Test("reader: title cap retains counts after focus replay (title-cap-count-conservation)",
	_WTC_ReplayPreservesRetainedTitleCount)

Test("reader: title cap retains durations across flushes (title-cap-count-conservation)",
	() => _WTC_ReplayPreservesRetainedTitleCount(true))

Test("reader: scoped title replay preserves neighboring days (title-cap-count-conservation)",
	() => _WTC_ReplayPreservesRetainedTitleCount(true, true))




; =====================================================================
; =====================================================================
; ======= 1/ The live flush emits the cleanup DELETE ==================
; =====================================================================
; =====================================================================

; Seed one app-day with more titles than the cap and return the emitted SQL.
_WTC_BuildSqlForSeededTitles(AppDays, TitlesPerAppDay) {
	KLW_ResetBatch()
	for _, App in AppDays {
		Loop TitlesPerAppDay {
			Key := "2026-01-01" . Chr(1) . App . Chr(1) . "t" . A_Index
			KLW.batch["titles"][Key] := Map(
				"date", "2026-01-01", "app", App,
				"title", "t" . A_Index, "c", 1, "ms", A_Index)
		}
	}
	Sql := KLW_BuildBatchSql("'dev'")
	KLW_ResetBatch()
	return Sql
}

_WTC_CountOccurrences(Haystack, Needle) {
	Count := 0
	Pos := 1
	while (Pos := InStr(Haystack, Needle, , Pos)) {
		Count += 1
		Pos += StrLen(Needle)
	}
	return Count
}

_WTC_FlushEmitsCappedDelete() {
	Sql := _WTC_BuildSqlForSeededTitles(["chrome.exe"], 150)
	Assert(InStr(Sql, "INSERT INTO agg_app_day_titles") > 0,
		"prerequisite: the seeded titles must reach the emitted SQL at all")
	Assert(InStr(Sql, "DELETE FROM agg_app_day_titles") > 0,
		"the per-app-day title cap must be ENFORCED, not just declared — agg_app_day_titles is otherwise unbounded and every surviving row is projected into the dashboard prefetch blob (walker-title-cap-declared-but-dead)")
	Assert(InStr(Sql, "LIMIT " . KLWConst.TITLE_CAP_PER_APP_DAY) > 0,
		"the cleanup DELETE must bound the group with KLWConst.TITLE_CAP_PER_APP_DAY rather than an inlined number, so the constant has exactly one meaning")
	Assert(InStr(Sql, "ORDER BY (c + ms) DESC") > 0,
		"the survivors must be ranked by (c + ms) like the macOS twin — a title matters either because it was seen often or because it held focus for a long time")
}
Test("walker: the batch flush enforces the per-app-day title cap (walker-title-cap-declared-but-dead)",
	_WTC_FlushEmitsCappedDelete)


; One cleanup per app-day touched, not one per title: the DELETE is a
; whole-group trim, so emitting it per row would send 150 identical statements
; through SQLite for a single app-day.
_WTC_OneDeletePerAppDay() {
	Sql := _WTC_BuildSqlForSeededTitles(["chrome.exe", "code.exe"], 5)
	Assert(_WTC_CountOccurrences(Sql, "DELETE FROM agg_app_day_titles") = 2,
		"exactly one cleanup DELETE must be emitted per distinct (date, app) in the batch — 2 apps x 5 titles must produce 2 DELETEs, not 10")
	Assert(_WTC_CountOccurrences(Sql, "INSERT INTO agg_app_day_titles") = 10,
		"prerequisite: all 10 seeded title rows must still be inserted")
}
Test("walker: one title-cap cleanup per app-day, not per title (walker-title-cap-declared-but-dead)",
	_WTC_OneDeletePerAppDay)


; An empty titles batch must not emit a cleanup at all — otherwise every ingest
; tick would pay a DELETE scan for a table nothing touched.
_WTC_NoTitlesNoDelete() {
	Sql := _WTC_BuildSqlForSeededTitles([], 0)
	Assert(InStr(Sql, "DELETE FROM agg_app_day_titles") = 0,
		"a batch with no window titles must emit no title cleanup")
}
Test("walker: no title cleanup when the batch has no titles (walker-title-cap-declared-but-dead)",
	_WTC_NoTitlesNoDelete)




; =====================================================================
; =====================================================================
; ======= 2/ The cold rebuild cannot reintroduce the unbounded set ====
; =====================================================================
; =====================================================================

; KLR_RebuildAggregates replays the entire events_window_switch history with a
; GROUP BY. Without its own bound, one cold rebuild undoes every cleanup the
; live walker ever emitted.
_WTC_ColdRebuildIsBounded() {
	Body := _DriverFuncBody("KLR_RebuildAggregates")
	Assert(Body != "", "KLR_RebuildAggregates must exist in the driver source")
	InsertPos := InStr(Body, "KLR_RebuildTitleCounts(db, Dates)")
	DeletePos := InStr(Body, "KLR_TrimTitles(db, Dates)")
	Assert(InsertPos > 0, "prerequisite: the cold rebuild must still repopulate agg_app_day_titles")
	Assert(DeletePos > InsertPos,
		"KLR_RebuildAggregates must trim agg_app_day_titles back to the cap AFTER repopulating it — a cold rebuild otherwise reintroduces every distinct title the user's apps ever produced (walker-title-cap-declared-but-dead)")
	TrimBody := _DriverFuncBody("KLR_TrimTitles")
	Assert(TrimBody != "", "the delegated title cap must exist")
	Assert(InStr(TrimBody, "DELETE FROM agg_app_day_titles") > 0,
		"the helper must execute the actual cap, not only declare its name")
	Assert(InStr(TrimBody, "KLWConst.TITLE_CAP_PER_APP_DAY") > 0,
		"the cold rebuild must bound the group with the same constant the live flush uses, not a second literal")
	Assert(InStr(TrimBody, "ORDER BY (t.c + t.ms) DESC") > 0,
		"the cold rebuild must keep the same (c + ms) ranking as the live flush, otherwise the two paths disagree on which titles survive")
}
Test("reader: the cold aggregate rebuild bounds agg_app_day_titles (walker-title-cap-declared-but-dead)",
	_WTC_ColdRebuildIsBounded)




; =====================================================================
; =====================================================================
; ======= 3/ Single source across drivers =============================
; =====================================================================
; =====================================================================

; The cap is a cross-driver contract: macOS trims to it on every flush and the
; dashboards render whatever survives. Two drivers silently disagreeing on how
; many titles an app-day keeps would make the same data look different per host.
_WTC_CapMatchesSharedContract() {
	; Two levels up from tests/ (windows/tests/ → windows/ → ergopti_plus/).
	Path := A_ScriptDir . "\..\..\_shared\lua\keylogger\aggregator_helpers.lua"
	Src := ""
	try Src := FileRead(Path, "UTF-8")
	Assert(Src != "", "the shared aggregator contract must be readable at " . Path)
	Assert(RegExMatch(Src, "M\.TITLE_CAP_PER_APP_DAY\s*=\s*(\d+)", &M) > 0,
		"the shared aggregator contract must still declare TITLE_CAP_PER_APP_DAY")
	Assert(KLWConst.TITLE_CAP_PER_APP_DAY = Integer(M[1]),
		"KLWConst.TITLE_CAP_PER_APP_DAY (" . KLWConst.TITLE_CAP_PER_APP_DAY . ") must equal the shared contract value (" . M[1] . ") — the two drivers must keep the same number of titles per app-day or the same capture renders differently per host")
}
Test("walker: the title cap matches the shared cross-driver contract (walker-title-cap-declared-but-dead)",
	_WTC_CapMatchesSharedContract)
