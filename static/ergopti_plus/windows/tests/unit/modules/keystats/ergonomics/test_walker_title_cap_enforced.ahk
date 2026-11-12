; tests/unit/modules/keystats/ergonomics/test_walker_title_cap_enforced.ahk

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
; cleanup DELETE (macos/modules/keystats/aggregator/sql.lua); the Windows port
; copied the constant across but not the statement that gives it meaning.
;
; SCOPE: behavioural for the live flush (the walker module is loaded by the
; headless runner), source-introspection for the cold rebuild (KLR_* needs a
; real SQLite handle), plus a cross-driver single-source check on the constant.
; ==============================================================================

#Requires AutoHotkey v2.0


_WTC_InsertTitleTyping(Db, Device, Id, Day, App, Title, Events, Text := "a") {
	return SQLite_Exec(Db, "INSERT INTO events_typing "
		. "(device_id,id,ts,date,app,title,is_fullscreen,in_meeting,mouse_clicks,mouse_scrolls,mouse_distance_px,text,events_json) VALUES ("
		. SQLite_Q(Device) . "," . Id . "," . SQLite_Q(Day . "T09:00:00") . "," . SQLite_Q(Day) . ","
		. SQLite_Q(App) . "," . SQLite_Q(Title) . ",0,0,0,0,0," . SQLite_Q(Text) . "," . SQLite_Q(KL_JsonEncode(Events)) . ");")
}

_WTC_TitleManualEvents(Count) {
	Events := []
	Loop Count
		Events.Push([A_Index == Count ? "[BS]" : "a", 10, Map("kc", 65, "sk", 30)])
	; Synthetic output has a real event but must not increase the page's
	; manual character counter; committed Text deliberately has length one.
	Events.Push(["synthetic", 10, Map("s", 1, "st", "hotstring")])
	return Events
}

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
		AssertTrue(_WTC_InsertTitleTyping(Db, "cap-device", 1, "2026-01-01", "cap.exe", "retained", _WTC_TitleManualEvents(1)))
		Loop KLWConst.TITLE_CAP_PER_APP_DAY
			AssertTrue(_WTC_InsertTitleTyping(Db, "cap-device", A_Index + 1, "2026-01-01", "cap.exe", "frequent-" . A_Index, _WTC_TitleManualEvents(2)))
		Dates := Scoped ? ["2026-01-01"] : 0
		AssertTrue(KLR_PrepareTypingProjection(Db))
		AssertTrue(KLR_RebuildAggregates(Db, Dates))
		AssertTrue(KLR_RebuildWalkerAggregates(Db, true, Dates) >= 0)
		Rows := SQLite_Query(Db,
			"SELECT c,ms FROM agg_app_day_titles WHERE title='retained';")
		AssertEqual(1, Rows.Length, "long focus must retain the title under the cap")
		AssertEqual(SplitFlushes ? 60001 : 60000, Rows[1]["ms"],
			"the real window replay must retain focus time across flush boundaries")
		AssertEqual(1, Rows[1]["c"], "a retained title must keep its independently observed manual keystroke count")
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

_WTC_AuthorizeTitleFailure(State, Context, Action, NamePtr, ColumnPtr, DatabasePtr, TriggerPtr) {
	try {
		if Action = State["action"] && NamePtr
			&& StrGet(NamePtr, "UTF-8") = "agg_app_day_titles" {
			State["seen"] := State.Get("seen", 0) + 1
			if State["seen"] <= State.Get("skip", 0)
				return 0
			State["denied"] += 1
			return 1 ; SQLITE_DENY rejects the entire native statement.
		}
	} catch {
		State["callback_failed"] := true
		return 1
	}
	return 0
}

_WTC_ReplayRefusesTitleFailure(Action, Stage) {
	global KLRLastReplayFailure
	SavedFailure := KLRLastReplayFailure
	SavedContext := KLW.ctx
	SavedBatch := KLW.batch
	Db := _WJFM_OpenMemory()
	State := Map("action", Action, "denied", 0, "callback_failed", false)
	Callback := CallbackCreate(_WTC_AuthorizeTitleFailure.Bind(State), "C", 6)
	try {
		AssertTrue(KLR_LoadSchema(Db))
		AssertTrue(KLR_PrepareTypingProjection(Db))
		AssertTrue(SQLite_Exec(Db, "INSERT INTO events_window_switch VALUES "
			. "('failure-device',1,'2026-01-01T10:00:00','2026-01-01','fixture.exe','title','title',23,NULL);"))
		AssertTrue(_WTC_InsertTitleTyping(Db, "failure-device", 1, "2026-01-01", "fixture.exe", "title", _WTC_TitleManualEvents(1)))
		AssertTrue(KLR_PrepareTypingProjection(Db))
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer",
			"Ptr", Db, "Ptr", Callback, "Ptr", 0, "Int"))
		AssertEqual(-1, KLR_RebuildWalkerAggregates(Db, true),
			"a refused title operation must reject the private replay")
		AssertEqual(Stage, KLRLastReplayFailure.Get("sweep", ""))
		AssertTrue(State["denied"] > 0, "the requested SQLite fault must actually occur")
		AssertFalse(State["callback_failed"], "a callback error is not a valid injected fault")
		AssertTrue(KLW.ctx == SavedContext)
		AssertTrue(KLW.batch == SavedBatch)
		AssertEqual(0, KLRReplay.Count, "failed replay must release its temporary owner")
		AssertTrue(SQLite_IsAutocommit(Db))
		Rows := SQLite_Query(Db, "SELECT c,ms FROM agg_app_day_titles;")
		if Stage = "title-cap" {
			AssertEqual(1, Rows.Length, "the final refusal must follow actual aggregate writes")
			AssertEqual(1, Rows[1]["c"])
			AssertEqual(23, Rows[1]["ms"])
		} else
			AssertEqual(0, Rows.Length, "count restoration refusal must precede all replay writes")
		_SQLRD_AssertNoStatements(Db)
	} finally {
		DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer",
			"Ptr", Db, "Ptr", 0, "Ptr", 0, "Int")
		CallbackFree(Callback)
		SQLite_Close(Db)
		KLRLastReplayFailure := SavedFailure
	}
}

; SQLite authorizer actions: INSERT=18, DELETE=9.
for Spec in [[18, "title-counts"], [9, "title-cap"]]
	Test("reader: native refusal rejects " . Spec[2] . " (title-replay-native-failure)",
		_WTC_ReplayRefusesTitleFailure.Bind(Spec[1], Spec[2]))




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
	Sql := KLW_BuildBatchSql("dev")
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

; KLR_RebuildAggregates groups accepted manual typing counts by source title.
; Without its own bound, one cold rebuild undoes every cleanup the live
; walker ever emitted; the later window replay restores focus time separately.
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
	Path := A_ScriptDir . "\metrics\engine\aggregator\helpers.lua"
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


; These are the exact outgoing-app window rows emitted by the genuine focus
; refresh on a captured A -> B -> A transition. Native acquisition itself is
; already isolated by switch-destination-privacy-owner; this fixture qualifies
; the actual SQLite rebuild and public manifest projection of those rows.
_WTC_WindowTitleAppAttribution(CrossApp) {
	global KLRLastReplayFailure
	SavedFailure := KLRLastReplayFailure
	Db := _WJFM_OpenMemory()
	try {
		AssertTrue(KLR_LoadSchema(Db))
		SecondApp := CrossApp ? "app-b.exe" : "app-a.exe"
		AssertTrue(SQLite_Exec(Db, "INSERT INTO events_window_switch "
			. "(device_id,id,ts,date,app,prev_title,next_title,duration_ms) VALUES "
			. "('title-owner',1,'2026-01-01T10:00:00','2026-01-01','app-a.exe','Title A','Title B',2500),"
			. "('title-owner',2,'2026-01-01T10:00:03','2026-01-01'," . SQLite_Q(SecondApp)
			. ",'Title B','Title A',3500);"))
		AssertTrue(_WTC_InsertTitleTyping(Db, "title-owner", 11, "2026-01-01", "app-a.exe", "Title A", _WTC_TitleManualEvents(3)))
		AssertTrue(_WTC_InsertTitleTyping(Db, "title-owner", 12, "2026-01-01", SecondApp, "Title B", _WTC_TitleManualEvents(4)))
		AssertTrue(_WTC_InsertTitleTyping(Db, "title-owner", 13, "2026-01-01", "app-a.exe", "", _WTC_TitleManualEvents(2)))
		AssertTrue(_WTC_InsertTitleTyping(Db, "title-owner", 14, "2026-01-01", "app-a.exe", "synthetic only",
			[["synthetic", 10, Map("s", 1, "st", "llm")]]))
		AssertTrue(KLR_PrepareTypingProjection(Db))
		AssertTrue(KLR_RebuildAggregates(Db))
		AssertTrue(KLR_RebuildWalkerAggregates(Db, true) >= 0)
		Manifest := KLR_ReadManifestBase(Db, "2026-01-01", "2026-01-01")
		Apps := Manifest["2026-01-01"]
		First := Apps["app-a.exe"]["win_titles"]
		Second := Apps[SecondApp]["win_titles"]
		_TestPrint("# title-app-attribution cross_app=" . CrossApp
			. " a_foreign_title=" . (First.Has("Title B") ? First["Title B"]["c"] : 0)
			. " b_foreign_title=" . (Second.Has("Title A") ? Second["Title A"]["c"] : 0))
		AssertTrue(First.Has("Title A"))
		AssertEqual(2500, First["Title A"]["ms"])
		AssertTrue(Second.Has("Title B"))
		AssertEqual(3500, Second["Title B"]["ms"])
		AssertEqual(3, First["Title A"]["c"], "Title A counts three manual keystrokes including backspace, not one switch or text length")
		AssertEqual(4, Second["Title B"]["c"], "Title B keeps its own four manual keystrokes and excludes synthetic output")
		AssertFalse(First.Has(""), "An empty typing title cannot invent a dashboard window")
		if First.Has("synthetic only")
			AssertEqual(0, First["synthetic only"]["c"], "Synthetic-only output cannot become manual title activity")
		if CrossApp {
			AssertFalse(First.Has("Title B"), "App A must never display app B's independently owned window title")
			AssertFalse(Second.Has("Title A"), "App B must never display app A's independently owned window title")
		} else {
			AssertTrue(First["Title A"]["c"] > 0)
			AssertTrue(First["Title B"]["c"] > 0,
				"A same-application title round-trip must keep both legitimate manual keystroke counters")
		}
	} finally {
		SQLite_Close(Db)
		KLRLastReplayFailure := SavedFailure
	}
}
for _WTC_CrossApp in [false, true]
	Test("Reader window title app owner: " . (_WTC_CrossApp ? "cross-app" : "same-app control") . " (window-title-app-attribution)",
		_WTC_WindowTitleAppAttribution.Bind(_WTC_CrossApp))
