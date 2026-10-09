; tests/unit/test_klr_worker_memory_bound.ahk

; ==============================================================================
; MODULE: Metrics projection worker memory bound
; DESCRIPTION:
; The live driver's projection worker ("--keylogger-prefetch-worker typing
; <dir> full") used about 1 GB. Its writable candidate was a ":memory:"
; database: a cold build and every refresh that found new ledger bytes (the
; clone of the file-backed image) held the whole reader image in the worker's
; memory. Measured on a synthetic 20 MB ledger: a 234 MB image, a SQLite
; high-water mark of 280 MB for the cold build and 282 MB for a refresh; the
; image is 650 MB on the store the cache was built against. The worker's
; candidate is now SQLite's private on-disk database with a bounded page cache
; (KLR_OpenCandidate), so only that bound of the image is resident
; (klr-worker-memory-bound-2026-09-27).
; Every path that writes a candidate is covered: the one-pass cold build, a
; refresh, the newest-first cold build a store above 32 MB of ledger takes
; (the 815 MB store's), and the upgrade of an image saved with a clear-payload
; table. The ledger here makes SQLite generate tens of megabytes of mouse
; events, which no walker replays, so the image is large and the build fast;
; the page cache bound is lowered so the image dwarfs it.
; ==============================================================================

#Requires AutoHotkey v2.0

; SQLite's process-wide heap high-water mark, in bytes, reset when Reset.
_KLRWM_HighWater(Reset := false) {
	return DllCall(SQLiteConst.DLL . "\sqlite3_memory_highwater", "Int", Reset ? 1 : 0, "Int64")
}

; One ingest batch of Rows mouse events of about five kilobytes each, generated
; by SQLite itself: a small ledger that materialises a large image. One INSERT
; per row, as the keylogger writes its ledger (keylogger_sql.ahk). A single
; multi-row INSERT ... SELECT is not a ledger's shape: under the newest-first
; build's first-wins triggers SQLite journals that one statement, in memory
; under temp_store=MEMORY, which measured 63 MB for a 57 MB image where one
; INSERT per row peaks at 5 MB for a 42 MB image.
_KLRWM_BallastBatch(Rows) {
	Sql := "`n-- === ingest batch 2025-06-01 10:00:00.000 (offset 0 -> 0, 1 entry(ies)) ===`n"
		. "BEGIN TRANSACTION;`n"
	Loop Rows
		Sql .= "INSERT OR IGNORE INTO events_mouse (device_id, id, ts, date, kind, app, meta_json) VALUES ("
			. "'dev-one', " . (1000000 + A_Index) . ", '2025-06-01 10:00:00.000', '2025-06-01', 'click', "
			. "'ballast.exe', hex(randomblob(2500)));`n"
	return Sql . "COMMIT;`n"
}

; Builds as a fresh worker would and returns the SQLite high-water mark of the
; build, in bytes.
_KLRWM_WorkerBuild(&Db) {
	KLR_ResetCache()
	KLRCache.disposable := true
	_KLRWM_HighWater(true)
	Db := KLR_BuildDatabase(_KLRDC_Root())
	return _KLRWM_HighWater()
}

; Peak must stay under a quarter of the Image-byte image.
_KLRWM_AssertBounded(Peak, Image, What) {
	AssertTrue(Peak < Image // 4, Format("{1} must not hold its image in memory: SQLite peaked at {2} bytes"
		. " for a {3}-byte image", What, Peak, Image))
}

_KLRWM_WorkerStaysBounded() {
	SavedBound := KLReadConst.WORKER_PAGE_CACHE_KIB
	SavedMinLedger := KLRRebuild.min_ledger_bytes
	SavedObserver := KLRRebuild.observer
	try {
		; A 4 MB page cache against an image of about 42 MB.
		KLReadConst.WORKER_PAGE_CACHE_KIB := 4096
		; This small ledger is the one-pass build's; the newest-first one is forced below.
		KLRRebuild.min_ledger_bytes := 0x7FFFFFFF
		_KLRDC_EnsureSharedDir()
		_KLRDC_Reset()
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRWM_BallastBatch(8000)
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a", "b"]))
		Cold := _KLRWM_WorkerBuild(&Db)
		AssertTrue(Db != 0, "the cold build must produce the reader database")
		AssertEqual(8000, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_mouse;")[1]["n"],
			"the ballast must be part of the image")
		Image := FileGetSize(KLR_CachePath(_KLRDC_Root()))
		AssertTrue(Image > 32 * 1048576, "the saved image must dwarf the page cache bound; it is " . Image . " bytes")
		_KLRWM_AssertBounded(Cold, Image, "a cold build")

		; New bytes: the refresh writes a private copy of the file-backed image.
		_KLRDC_AppendLedger(_KLRDC_TypingBatch(2, "2026-01-02 10:00:00.000", "2026-01-02", "fixture.exe", ["c"]))
		Warm := _KLRWM_WorkerBuild(&Db)
		AssertTrue(Db != 0, "the refresh must produce the reader database")
		AssertEqual(1, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM agg_app_day WHERE date='2026-01-02';")[1]["n"],
			"the refresh must project the new day")
		_KLRWM_AssertBounded(Warm, Image, "a refresh")

		; A large store's cold build, newest day first (KLR_BuildColdSegmented).
		FileDelete(KLR_CachePath(_KLRDC_Root()))
		KLRRebuild.min_ledger_bytes := 0
		Rounds := 0
		KLRRebuild.observer := (Info) => Rounds += 1
		Segmented := _KLRWM_WorkerBuild(&Db)
		AssertTrue(Db != 0, "the newest-first build must produce the reader database")
		AssertTrue(Rounds > 0, "the newest-first build must own this cold build")
		AssertEqual(8000, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_mouse;")[1]["n"],
			"the ballast must be part of the newest-first image")
		Image := FileGetSize(KLR_CachePath(_KLRDC_Root()))
		_KLRWM_AssertBounded(Segmented, Image, "a newest-first cold build")

		; An image saved with a main-schema payload table is upgraded in a private
		; copy, never rebuilt (KLR_CacheAttach).
		KLR_ResetCache()
		Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()))
		AssertTrue(Stored != 0, "the saved image must open for the fixture's payload table")
		try AssertTrue(SQLite_Exec(Stored, "CREATE TABLE main.klr_reader_typing_payload(events_json TEXT);"))
		finally SQLite_Close(Stored)
		KLRCache.disposable := true
		_KLRWM_HighWater(true)
		AssertEqual(1, KLR_CacheAttach(_KLRDC_Root(), ""), "the image must be upgraded, not rebuilt")
		Upgrade := _KLRWM_HighWater()
		AssertFalse(KLRCache.readonly, "the upgrade must write a private copy")
		AssertEqual(0, SQLite_Query(KLRCache.db, "SELECT COUNT(*) AS n FROM sqlite_schema "
			. "WHERE name='klr_reader_typing_payload';")[1]["n"], "the upgrade must drop the payload table")
		_KLRWM_AssertBounded(Upgrade, Image, "an image upgrade")
	} finally {
		KLReadConst.WORKER_PAGE_CACHE_KIB := SavedBound
		KLRRebuild.min_ledger_bytes := SavedMinLedger
		KLRRebuild.observer := SavedObserver
		_KLRDC_Cleanup()
	}
}
Test("KLR worker: a cold build, a refresh, a newest-first build and an upgrade keep the reader image out of memory (klr-worker-memory-bound-2026-09-27)",
	_KLRDC_CheckTeardown.Bind(_KLRWM_WorkerStaysBounded))
