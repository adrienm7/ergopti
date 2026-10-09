; tests/unit/test_klr_durable_cache.ahk

; ==============================================================================
; MODULE: Durable Reader Cache Equivalence Tests
; DESCRIPTION: Compare cached refreshes with cold replay and preserve publication cadence.
; ==============================================================================

#Requires AutoHotkey v2.0





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
				. "INSERT INTO klr_reader_typing_counts (device_id, event_id, "
				. "chars) VALUES ('dev-one', 900, 3);"),
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
