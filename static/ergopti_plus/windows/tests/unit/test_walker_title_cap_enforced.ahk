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
	InsertPos := InStr(Body, "INSERT INTO agg_app_day_titles")
	DeletePos := InStr(Body, "DELETE FROM agg_app_day_titles")
	Assert(InsertPos > 0, "prerequisite: the cold rebuild must still repopulate agg_app_day_titles")
	Assert(DeletePos > InsertPos,
		"KLR_RebuildAggregates must trim agg_app_day_titles back to the cap AFTER repopulating it — a cold rebuild otherwise reintroduces every distinct title the user's apps ever produced (walker-title-cap-declared-but-dead)")
	Assert(InStr(Body, "KLWConst.TITLE_CAP_PER_APP_DAY") > 0,
		"the cold rebuild must bound the group with the same constant the live flush uses, not a second literal")
	Assert(InStr(Body, "ORDER BY (t.c + t.ms) DESC") > 0,
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
