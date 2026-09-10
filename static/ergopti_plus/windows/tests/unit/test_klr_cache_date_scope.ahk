; tests/unit/test_klr_cache_date_scope.ahk

; ==============================================================================
; MODULE: Reader Cache Date Scope Tests
; DESCRIPTION: Derive complete refresh scopes from consumed SQL rather than event identifiers.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRDS_SessionScopeEquivalence(Interleave := false, SplitFlushes := false) {
	Db := _WJFM_OpenMemory()
	SavedFlushSize := KLReadConst.REPLAY_FLUSH_ENTRIES
	SavedContext := KLW.ctx
	SavedBatch := KLW.batch
	try {
		if SplitFlushes
			KLReadConst.REPLAY_FLUSH_ENTRIES := 1
		AssertTrue(KLR_LoadSchema(Db))
		Sql := _KLRDC_TypingBatch(1, "2026-01-01 23:59:00.000", "2026-01-01", "scope.exe", ["a", "b"])
			. _KLRDC_TypingBatch(2, "2026-01-02 09:00:00.000", "2026-01-02", "scope.exe", ["c", "d"])
		Closing := _KLRDC_TypingBatch(3, "2026-01-02 10:00:00.000", "2026-01-02", "scope.exe", ["e"])
		Sql .= StrReplace(Closing, ",120,", "," . (KLWConst.SESSION_GAP_MS + 1) . ",")
		if Interleave
			Sql .= _KLRDC_TypingBatch(4, "2026-01-01 23:59:01.000", "2026-01-01", "scope.exe", ["f"])
		AssertTrue(SQLite_Exec(Db, Sql))
		AssertTrue(KLR_PrepareTypingProjection(Db))
		AssertTrue(KLR_RebuildAggregates(Db))
		AssertTrue(KLR_RebuildWalkerAggregates(Db, true) >= 0)
		Query := "SELECT count_total,longest_chars,total_active_ms FROM agg_app_day_session "
			. "WHERE date='2026-01-02' AND app='scope.exe';"
		Cold := SQLite_Query(Db, Query)
		AssertEqual(1, Cold.Length, "the long pause must finalize an actual session")
		Dates := ["2026-01-02"]
		AssertTrue(KLR_ClearAggregates(Db, Dates))
		AssertTrue(KLR_RebuildAggregates(Db, Dates))
		AssertTrue(KLR_RebuildWalkerAggregates(Db, true, Dates) >= 0)
		Scoped := SQLite_Query(Db, Query)
		AssertEqual(1, Scoped.Length)
		AssertEqual(Cold[1]["longest_chars"], Scoped[1]["longest_chars"],
			"session length for the same raw day must not depend on replay scope")
		AssertEqual(Cold[1]["total_active_ms"], Scoped[1]["total_active_ms"])
		AssertEqual(Cold[1]["count_total"], Scoped[1]["count_total"])
		AssertEqual(2, Scoped[1]["longest_chars"])
		AssertEqual(2, Scoped[1]["count_total"], "the observed terminal session must appear exactly once")
		for Table, MaxField in Map("agg_app_day_session", "longest_chars", "agg_app_day_burst", "max_chars") {
			for Day in ["2026-01-01", "2026-01-02"] {
				Query := "SELECT count_total," . MaxField . " AS chars FROM " . Table
					. " WHERE date=" . SQLite_Q(Day) . " AND app='scope.exe';"
				Before := SQLite_Query(Db, Query)
				AssertEqual(1, Before.Length, "terminal activity must survive snapshot projection")
				AssertEqual(Day = "2026-01-01" ? 1 : 2, Before[1]["count_total"])
				AssertEqual(Day = "2026-01-01" && Interleave ? 3 : 2, Before[1]["chars"])
				AssertTrue(KLR_ClearAggregates(Db, [Day]))
				AssertTrue(KLR_RebuildAggregates(Db, [Day]))
				AssertTrue(KLR_RebuildWalkerAggregates(Db, true, [Day]) >= 0)
				AssertEqual(KL_JsonEncode(Before), KL_JsonEncode(SQLite_Query(Db, Query)),
					"daily activity must survive repeat projection independently of neighboring dates")
			}
		}
		AssertTrue(KLW.ctx == SavedContext, "snapshot finalization must not consume the caller context")
		AssertTrue(KLW.batch == SavedBatch)
	} finally {
		KLReadConst.REPLAY_FLUSH_ENTRIES := SavedFlushSize
		SQLite_Close(Db)
	}
}

Test("KLR replay: daily sessions are independent of replay scope (session-replay-day-scope)",
	_KLRDS_SessionScopeEquivalence)

Test("KLR replay: interleaved dates retain daily activity (session-replay-day-scope)",
	() => _KLRDS_SessionScopeEquivalence(true))

Test("KLR replay: split flushes retain terminal daily activity (session-replay-day-scope)",
	() => _KLRDS_SessionScopeEquivalence(true, true))





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
