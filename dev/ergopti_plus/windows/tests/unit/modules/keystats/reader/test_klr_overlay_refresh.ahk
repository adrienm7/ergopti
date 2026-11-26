; tests/unit/modules/keystats/reader/test_klr_overlay_refresh.ahk

; ==============================================================================
; MODULE: Copy-on-write refresh of the shared reader image
; DESCRIPTION:
; A worker that attached the shared image read-only used to copy all of it
; before applying a ledger tail (6 to 20 s on a 1.1 GB image for 47 KB of new
; data.sql). It now writes through a copy-on-write overlay of that file
; (KLR_OpenOverlayCandidate). These cases pin what the copy guaranteed: the
; result equals a cold rebuild row for row, no reader of the shared file ever
; sees the refresh in progress, and a failure part-way leaves the file intact
; (klr-overlay-refresh-2026-11-20).
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

; Every row of every table of the image, in a fixed order. The cache's own
; bookkeeping (offsets, save time) is excluded: it describes the save, not the
; projection.
_KLROV_Dump(Db) {
	Dump := ""
	Tables := SQLite_Query(Db, "SELECT name FROM main.sqlite_schema WHERE type='table' "
		. "AND name NOT LIKE 'sqlite%' AND name NOT IN ('klr_cache_meta','klr_cache_ledger') ORDER BY name;")
	for Table in Tables {
		Name := Table["name"]
		Columns := SQLite_Query(Db, "PRAGMA main.table_info(" . SQLite_Q(Name) . ");")
		Order := ""
		loop Columns.Length
			Order .= (Order = "" ? "" : ",") . A_Index
		Dump .= "[" . Name . "]`n"
		for Row in SQLite_Query(Db, "SELECT * FROM main." . Name . " ORDER BY " . Order . ";") {
			Line := ""
			for Column, Value in Row
				Line .= Column . "=" . Value . ";"
			Dump .= Line . "`n"
		}
	}
	return Dump
}

_KLROV_ReadImage() {
	Path := KLR_CachePath(_KLRDC_Root())
	return FileRead(Path, "RAW")
}

_KLROV_SameBytes(Left, Right) {
	if Left.Size != Right.Size
		return false
	return DllCall("ntdll\RtlCompareMemory", "Ptr", Left.Ptr, "Ptr", Right.Ptr, "UPtr", Left.Size, "UPtr")
		= Left.Size
}

_KLROV_CountTyping(Db) {
	return SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_typing;")[1]["n"]
}

; Two days in two apps, so the cold build and the refresh cannot differ over
; the n-gram chain across midnight (test_klr_durable_cache owns that case).
_KLROV_WriteBaseLedger() {
	_KLRDC_WriteLedger(_KLRDC_Header()
		. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01", "code.exe", ["a", "b", "c"])
		. _KLRDC_TypingBatch(2, "2026-01-01 10:00:02.000", "2026-01-01", "code.exe", ["a", "b"])
		. _KLRDC_TypingBatch(3, "2026-01-02 09:00:00.000", "2026-01-02", "chrome.exe", ["d", "e"]))
}

_KLROV_Tail() {
	return _KLRDC_TypingBatch(4, "2026-01-02 09:00:05.000", "2026-01-02", "chrome.exe", ["e", "f", "g"])
		. _KLRDC_TypingBatch(5, "2026-01-03 08:00:00.000", "2026-01-03", "notepad.exe", ["h", "i"])
}





; ==================================================
; ==================================================
; ======= 2/ The overlay result is a rebuild =======
; ==================================================
; ==================================================

_KLROV_RefreshEqualsColdRebuild() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLROV_WriteBaseLedger()
		_KLRDC_BuildAsWorker()
		_KLRDC_AppendLedger(_KLROV_Tail())
		Before := _KLROV_ReadImage()

		; A worker whose save waits for its read, as a Studio read does: the
		; refresh itself must leave the shared file as it found it.
		KLR_ResetCache()
		KLRCache.disposable := true
		KLRCache.defer_saves := true
		WarmDb := KLR_BuildDatabase(_KLRDC_Root())
		AssertTrue(WarmDb != 0, "the refresh must produce the reader database")
		AssertTrue(SQLite_IsCopyOnWrite(WarmDb),
			"a worker that attached the shared image must refresh it through a copy-on-write overlay, "
			. "not a copy of the whole image (klr-overlay-refresh-2026-11-20)")
		AssertTrue(_KLROV_SameBytes(Before, _KLROV_ReadImage()),
			"the refresh must not write a byte of the image other workers share")
		Warm := _KLROV_Dump(WarmDb)

		; The save then replaces the file this overlay still maps, and the next
		; worker starts from what it saved. The image was saved moments ago, so
		; the save cadence is lifted for this one save.
		KLRCache.saved_at := ""
		AssertTrue(KLR_CacheCommitDeferredSave(), "the refreshed image must be saved after its read")
		AssertFalse(_KLROV_SameBytes(Before, _KLROV_ReadImage()), "the save must publish the refreshed image")
		AssertEqual(Warm, _KLROV_Dump(KLRCache.db), "saving must not change the overlay it copies")
		KLR_ResetCache()
		KLRCache.disposable := true
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), ""), "the saved refresh must be admitted")
		AssertEqual(Warm, _KLROV_Dump(KLRCache.db), "the saved image must hold the refresh")
		KLR_ResetCache()

		AssertTrue(FSDelete(KLR_CachePath(_KLRDC_Root())), "the fixture must be able to force a cold rebuild")
		Cold := _KLROV_Dump(_KLRDC_BuildAsWorker())
		AssertTrue(InStr(Warm, "[ngram_bigrams]`n") && InStr(Warm, "app=notepad.exe"),
			"the dump must read the refreshed rows")
		AssertEqual(Cold, Warm,
			"a refresh through the overlay must equal a cold rebuild of the same ledger, row for row, "
			. "in every table of the image (klr-overlay-refresh-2026-11-20)")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR overlay refresh: the refresh equals a cold rebuild row for row and leaves the shared file alone (klr-overlay-refresh-2026-11-20)",
	_KLRDC_CheckTeardown.Bind(_KLROV_RefreshEqualsColdRebuild))





; ===================================================
; ===================================================
; ======= 3/ No reader sees a partial refresh =======
; ===================================================
; ===================================================

_KLROV_ReadersNeverSeePartialState() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Peer := 0
	Overlay := 0
	Second := 0
	try {
		_KLROV_WriteBaseLedger()
		Expected := _KLROV_Dump(_KLRDC_BuildAsWorker())
		KLR_ResetCache()
		; Another worker reading the shared image throughout.
		Peer := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
		AssertTrue(Peer != 0, "the peer must open the shared image")
		Source := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
		Overlay := SQLite_OpenCopyOnWrite(Source, 1048576, 4096)
		SQLite_Close(Source)

		; Half a refresh: a transaction left open and a day's rollups dropped.
		AssertTrue(SQLite_Exec(Overlay, "BEGIN;"
			. "DELETE FROM agg_app_day WHERE date='2026-01-01';"
			. "DELETE FROM ngram_bigrams;"))
		AssertTrue(SQLite_Exec(Overlay, StrReplace(StrReplace(_KLROV_Tail(),
			"BEGIN TRANSACTION;", ""), "COMMIT;", "")))
		AssertEqual(5, _KLROV_CountTyping(Overlay), "the overlay must see its own writes")
		AssertEqual(Expected, _KLROV_Dump(Peer),
			"a reader of the shared image must not see a refresh in progress")

		; A second worker attaching now overlays the same untouched file.
		Source := SQLite_Open(KLR_CachePath(_KLRDC_Root()), SQLiteConst.OPEN_RO)
		Second := SQLite_OpenCopyOnWrite(Source, 1048576, 4096)
		SQLite_Close(Source)
		AssertEqual(Expected, _KLROV_Dump(Second), "a second overlay must start from the shared image")

		; Committed but never published: still invisible to every reader.
		AssertTrue(SQLite_Exec(Overlay, "COMMIT;"))
		AssertEqual(Expected, _KLROV_Dump(Peer), "a committed overlay must stay private")
		AssertEqual(Expected, _KLROV_Dump(Second), "overlays must not share pages they wrote")
		Closed := Overlay
		AssertEqual(SQLiteConst.OK, SQLite_CloseChecked(Overlay), "the overlay must close")
		Overlay := 0
		AssertFalse(SQLite_IsCopyOnWrite(Closed), "a closed overlay must release its mapping")
		AssertEqual(Expected, _KLROV_Dump(Second), "closing one overlay must not disturb another")
	} finally {
		for Db in [Peer, Overlay, Second]
			if Db
				SQLite_Close(Db)
		_KLRDC_Cleanup()
	}
}
Test("KLR overlay refresh: readers of the shared image never see a refresh in progress (klr-overlay-refresh-2026-11-20)",
	_KLRDC_CheckTeardown.Bind(_KLROV_ReadersNeverSeePartialState))





; ===========================================================
; ===========================================================
; ======= 4/ A failed refresh leaves the image intact =======
; ===========================================================
; ===========================================================

; @param Tail {String} Ledger bytes whose refresh must fail.
; @param Why {String} The failure the case injects.
_KLROV_AssertFailureKeepsImage(Tail, Why) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	_KLROV_WriteBaseLedger()
	Expected := _KLROV_Dump(_KLRDC_BuildAsWorker())
	Before := _KLROV_ReadImage()
	_KLRDC_AppendLedger(Tail)
	KLR_ResetCache()
	KLRCache.disposable := true
	AssertEqual(0, KLR_BuildDatabase(_KLRDC_Root()),
		Why . ": a worker must fail loud rather than publish a refresh it could not finish")
	AssertFalse(KLRCache.db, Why . ": the failed overlay must not survive as the published image")
	AssertTrue(_KLROV_SameBytes(Before, _KLROV_ReadImage()), Why . ": the shared image must stay intact")
	KLR_ResetCache()
	KLRCache.disposable := true
	AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), ""), Why . ": the old image must still be admitted")
	AssertEqual(Expected, _KLROV_Dump(KLRCache.db), Why . ": the old image must keep its rows")
}

_KLROV_FailedApplyKeepsImage() {
	try {
		; A statement SQLite refuses halfway through the second batch.
		_KLROV_AssertFailureKeepsImage(_KLROV_Tail()
			. "`n-- === ingest batch 2026-01-03 09:00:00.000 (offset 0 -> 0, 1 entry(ies)) ===`n"
			. "BEGIN TRANSACTION;`nINSERT INTO events_typing (device_id) VALUES ('dev-one');`nCOMMIT;`n",
			"a refused tail statement")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR overlay refresh: a statement failing mid-apply leaves the shared image intact (klr-overlay-refresh-2026-11-20)",
	_KLRDC_CheckTeardown.Bind(_KLROV_FailedApplyKeepsImage))

_KLROV_FullOverlayFailsLoud() {
	SavedSlack := KLReadConst.WORKER_OVERLAY_SLACK_BYTES
	SavedPerByte := KLReadConst.WORKER_OVERLAY_SLACK_PER_TAIL_BYTE
	try {
		; One granule of growth against a tail that needs megabytes.
		KLReadConst.WORKER_OVERLAY_SLACK_BYTES := 1
		KLReadConst.WORKER_OVERLAY_SLACK_PER_TAIL_BYTE := 0
		_KLROV_AssertFailureKeepsImage(_KLRWM_BallastBatch(2000), "an overlay out of growth room")
	} finally {
		KLReadConst.WORKER_OVERLAY_SLACK_BYTES := SavedSlack
		KLReadConst.WORKER_OVERLAY_SLACK_PER_TAIL_BYTE := SavedPerByte
		_KLRDC_Cleanup()
	}
}
Test("KLR overlay refresh: an overlay out of growth room fails loud and leaves the image intact (klr-overlay-refresh-2026-11-20)",
	_KLRDC_CheckTeardown.Bind(_KLROV_FullOverlayFailsLoud))
