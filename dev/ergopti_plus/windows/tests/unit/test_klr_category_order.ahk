; tests/unit/test_klr_category_order.ahk

; ==============================================================================
; MODULE: Reader Category Ordering Tests
; DESCRIPTION: Categories follow reserved screen-order IDs despite clock corrections.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCAT_Refresh(EmptyLatest := false, TiedStamp := false) {
	SavedBatch := KLW.batch
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		LastStamp := TiedStamp ? "2026-01-01 10:00:00.000" : "2026-01-01 09:59:00.000"
		Ledger := _KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"])
		Ledger .= StrReplace(_KLRDC_TypingBatch(2, LastStamp,
			"2026-01-01", "fixture.exe", ["b"]), "'dev', NULL", "'web', NULL")
		if EmptyLatest
			Ledger .= StrReplace(_KLRDC_TypingBatch(3, "2026-01-01 09:58:00.000",
				"2026-01-01", "fixture.exe", ["c"]), "'dev', NULL", "'', NULL")
		_KLRDC_WriteLedger(Ledger)
		Db := _KLRDC_BuildAsWorker()
		Query := "SELECT category FROM agg_app_day WHERE device_id='dev-one' AND date='2026-01-01' AND app='fixture.exe';"
		AssertEqual("web", SQLite_Query(Db, Query)[1]["category"], "cold replay must retain the last nonempty category in screen order")
		KLRCache.disposable := false
		KLW_ResetBatch()
		AssertEqual(Db, KLR_BuildDatabase(_KLRDC_Root()))
		AssertEqual("web", SQLite_Query(Db, Query)[1]["category"],
			"resident SQL refresh must preserve screen order when the wall clock moves backward")
	} finally {
		KLW.batch := SavedBatch
		_KLRDC_Cleanup()
	}
}
Test("KLR category: backward clock preserves reserved screen order (klr-category-order)",
	_KLRDC_CheckTeardown.Bind(_KLRCAT_Refresh))
Test("KLR category: latest empty category preserves prior nonempty value (klr-category-order)",
	_KLRDC_CheckTeardown.Bind(_KLRCAT_Refresh.Bind(true)))
Test("KLR category: tied timestamps retain the event-id tiebreaker (klr-category-order)",
	_KLRDC_CheckTeardown.Bind(_KLRCAT_Refresh.Bind(false, true)))
