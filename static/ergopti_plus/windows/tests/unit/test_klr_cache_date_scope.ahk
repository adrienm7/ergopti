; tests/unit/test_klr_cache_date_scope.ahk

; ==============================================================================
; MODULE: Reader Cache Date Scope Tests
; DESCRIPTION: Derive complete refresh scopes from consumed SQL rather than event identifiers.
; ==============================================================================

#Requires AutoHotkey v2.0





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
