; tests/unit/test_klr_projection_late_page_failure.ahk

; ==============================================================================
; MODULE: Late Projection Page Failure Tests
; DESCRIPTION:
; A committed projection page cannot escape a subsequently rejected worker.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLPL_Authorize(State, Context, Action, NamePtr, ColumnPtr, DatabasePtr, TriggerPtr) {
	try {
		Name := NamePtr ? StrGet(NamePtr, "UTF-8") : ""
		if Action == 18 && Name == "klr_reader_typing_counts" {
			State["inserts"] += 1
			if State["inserts"] == 129 {
				State["denied"] += 1
				return 1
			}
		}
		if Action == 22 && Name == "COMMIT" && State["inserts"] > 0
			State["page_commits"] += 1
	} catch {
		State["callback_failed"] := true
		return 1
	}
	return 0
}

_KLPL_PreserveImageAndRetry() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Callback := 0
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"]))
		Db := _KLRDC_BuildAsWorker()
		AssertFalse(KLRCache.readonly, "the disposable private candidate must own the fault hook")
		Before := _KLRDC_DerivedFingerprint(Db)
		Offset := KLRCache.last_sizes[_KLRDC_LedgerPath()]
		Tail := ""
		loop 130
			Tail .= _KLRDC_TypingBatch(A_Index + 1, "2026-01-01 10:00:01.000",
				"2026-01-01", "fixture.exe", ["b"])
		_KLRDC_AppendLedger(Tail)
		State := Map("inserts", 0, "page_commits", 0, "denied", 0, "callback_failed", false)
		Callback := CallbackCreate(_KLPL_Authorize.Bind(State), "C", 6)
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer",
			"Ptr", Db, "Ptr", Callback, "Ptr", 0, "Int"))
		AssertEqual(0, KLR_BuildDatabase(_KLRDC_Root()))
		AssertFalse(State["callback_failed"])
		AssertEqual(129, State["inserts"], "the fault must occur after a complete 128-row page")
		AssertEqual(1, State["page_commits"], "one earlier projection page must have committed")
		AssertEqual(1, State["denied"], "the native SQLite refusal must actually occur")
		AssertEqual(0, KLRCache.db, "a partially prepared worker must be discarded")
		AssertEqual(0, KLRCache.last_sizes.Count)
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), ""))
		AssertEqual(Offset, KLRCache.last_sizes[_KLRDC_LedgerPath()])
		AssertEqual(Before, _KLRDC_DerivedFingerprint(KLRCache.db))
		AssertEqual(1, SQLite_Query(KLRCache.db, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
		AssertEqual(1, SQLite_Query(KLRCache.db, "SELECT COUNT(*) AS n FROM klr_reader_typing_counts;")[1]["n"],
			"the committed private page must not leak into the published image")
		Retry := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(Retry != 0)
		AssertEqual(131, SQLite_Query(Retry, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"])
		AssertEqual(131, SQLite_Query(Retry, "SELECT SUM(chars) AS n FROM agg_app_day;")[1]["n"],
			"retry must recover every discarded page exactly once")
		AssertEqual(FileGetSize(_KLRDC_LedgerPath()), KLRCache.last_sizes[_KLRDC_LedgerPath()])
	} finally {
		try _KLRDC_Cleanup()
		finally {
			if Callback
				CallbackFree(Callback)
		}
	}
}

Test("KLR projection: late page refusal preserves image and retries (klr-projection-late-page)",
	_KLRDC_CheckTeardown.Bind(_KLPL_PreserveImageAndRetry))
