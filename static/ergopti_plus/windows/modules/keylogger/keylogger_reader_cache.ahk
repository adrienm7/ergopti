; modules/keylogger/keylogger_reader_cache.ahk

; ==============================================================================
; MODULE: Keylogger Reader Durable Cache (AHK)
; DESCRIPTION:
; Persists the materialised reader database between projection workers, so a
; dashboard open costs one tail append instead of a full rebuild of every
; keystroke ever recorded.
;
; WHY IT EXISTS:
; Every projection runs in a disposable /force worker, so KLRCache always
; started empty and KLR_BuildDatabase took the cold path: replay the whole
; data.sql, project every typing payload, GROUP BY the entire history, then
; walk every raw event through the stateful walker. Measured on an 815 MB
; store: 128 s + 168 s + 82 s + 654 s = 16 min, every single open, growing with
; the ledger. The same store restores its image in 1.3 s.
;
; The store on disk is append-only, so everything the previous worker computed
; is still valid: only the bytes appended since then are new. This module writes
; that computed image to <metrics>/cache/reader.sqlite together with the byte
; offset and file identity it was built from, and hands it back to the next
; worker. KLR_BuildDatabase then takes its existing incremental branch, which
; reads only the tail.
;
; INVARIANTS:
; 1. The cache is a rebuilt projection, never an at-rest store. data.sql stays
;    authoritative (project-windows-at-rest-store-is-data-sql); anything
;    unreadable, stale, or shaped for another format is deleted and rebuilt.
; 2. A cache is only reused when every ledger it was built from is still the
;    same file (volume + file index) and has not shrunk below the recorded
;    offset. At unchanged size its modification receipt must also match.
;    A replaced, compacted, or detectably rewritten ledger forces a cold rebuild.
; 3. Publication is atomic: the image is written to a private temp database and
;    renamed over the previous one, so an interrupted save can never leave a
;    half-written cache for the next worker to trust.
; 4. A refresh recomputes whole affected days, never just the appended rows. The
;    walker is stateful and its context is not persisted with the cache, so
;    folding in a tail alone cannot reproduce cross-event statistics.
; ==============================================================================

#Requires Autohotkey v2.0+

; Bump whenever the cache's tables or the provenance required for reuse change.
; An older image is discarded rather than migrated: it can always
; be rebuilt from data.sql, and a migration path would be one more thing that
; can be wrong about data the user cannot inspect.
; Version 6 retains modification receipts to reject same-size ledger rewrites.
; Reject older images through the close-before-discard path before reusing them.
; Version 9 preserves complete title counts and durations before replay pruning.
; Version 10 retains day-owned session and burst prefixes in private snapshots.
; Version 11 isolates daily ergonomic streak and auto-repeat state.
; Version 12 preserves daily correction runs and terminal cascade prefixes.
; Version 13 keeps trigger input credits within their source day.
; Version 14 preserves literal synthetic-source labels across walker flushes.
global KLR_CACHE_FORMAT_VERSION := "14"

; Republishing the image copies every page of it — 650 MB on the store this was
; built against. An open dashboard refreshes every few seconds, so saving each
; time would write hundreds of megabytes a minute to the user's disk to persist
; a few kilobytes of new events. Skipping a save costs the next worker only the
; re-application of the tail it already had to read.
global KLR_CACHE_MIN_SAVE_INTERVAL_S := 300






; ===========================================
; ===========================================
; ======= 1/ Location and state shape =======
; ===========================================
; ===========================================

KLR_CacheDir(md) {
	return md . "cache\"
}

KLR_CachePath(md) {
	return KLR_CacheDir(md) . "reader.sqlite"
}

; The cache's own bookkeeping lives inside the cached database, so an image and
; the offsets it was built from can never be separated by a partial copy.
KLR_CacheEnsureTables(db) {
	return SQLite_Exec(db,
		"CREATE TABLE IF NOT EXISTS klr_cache_meta ("
		. "key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;"
		. "CREATE TABLE IF NOT EXISTS klr_cache_ledger ("
		. "path TEXT PRIMARY KEY, end_offset INTEGER NOT NULL, "
		. "volume INTEGER NOT NULL, index_high INTEGER NOT NULL, "
		. "index_low INTEGER NOT NULL, size INTEGER NOT NULL, "
		. "write_high INTEGER NOT NULL, write_low INTEGER NOT NULL) WITHOUT ROWID;")
}

_KLR_CacheMetaValue(db, Key, Default := "") {
	Rows := SQLite_Query(db,
		"SELECT value FROM klr_cache_meta WHERE key=" . SQLite_Q(Key) . ";")
	return (Rows.Length > 0 && Rows[1].Has("value")) ? Rows[1]["value"] : Default
}





; ==================================
; ==================================
; ======= 2/ Reading a cache =======
; ==================================
; ==================================

; Decide whether a stored ledger row still describes the file on disk.
; A different file (volume/index) or one that shrank below the recorded offset
; means the ledger was replaced or compacted: every offset in the cache is then
; meaningless and the only honest answer is a cold rebuild.
_KLR_CacheLedgerStillValid(Row, logPath) {
	EndOffset := Row.Get("end_offset", -1)
	SnapshotSize := Row.Get("size", -1)
	if !(EndOffset is Integer) || !(SnapshotSize is Integer)
			|| EndOffset < 0 || EndOffset > SnapshotSize {
		KLR_PrefetchDebug(logPath, "KLR cache rejected: invalid consumed offset")
		return false
	}
	Path := Row.Get("path", "")
	if (Path = "") || !FSExists(Path)
		return false
	Current := KLR_LedgerSnapshot(Path)
	if !Current.Get("ok", false)
		return false
	if (Current.Get("volume", -1) != Row.Get("volume", -2))
			|| (Current.Get("index_high", -1) != Row.Get("index_high", -2))
			|| (Current.Get("index_low", -1) != Row.Get("index_low", -2)) {
		KLR_PrefetchDebug(logPath, "KLR cache rejected: ledger replaced " . Path)
		return false
	}
	if (Current.Get("size", 0) < Row.Get("end_offset", 0)) {
		KLR_PrefetchDebug(logPath, "KLR cache rejected: ledger shrank " . Path)
		return false
	}
	if Current["size"] = Row["size"] && !KLR_LedgerWriteTimeIsSame(Current, Row) {
		KLR_PrefetchDebug(logPath, "KLR cache rejected: ledger changed without growth " . Path)
		return false
	}
	return true
}

; Every ledger present on disk must be described by the cache. A device that
; appeared since the image was written has no offset and no replayed walker
; state, and there is no correct partial answer for it.
_KLR_CacheCoversEveryLedger(md, Offsets, logPath) {
	Paths := KLR_ListLedgerPaths(md)
	by_root := md . "by_device\"
	if !DirExist(by_root)
		return Offsets.Count = 0
	for sql_path in Paths {
		if !Offsets.Has(sql_path) {
			KLR_PrefetchDebug(logPath, "KLR cache rejected: new ledger " . sql_path)
			return false
		}
	}
	return true
}

; Retain a validated worker image read-only; resident callers receive a private
; memory copy for live writes. Returns false whenever anything about the image or the
; ledgers it was built from fails to line up, leaving the caller on its cold
; path.
; @param md {String} Metrics directory, trailing separator included.
; @param logPath {String} Diagnostic sink shared with the rest of the reader.
; @param BeforeDiscard {Integer|Object} Optional deterministic peer-publication seam.
; @returns {Integer} 1 when KLRCache now holds a usable image, 0 otherwise.
KLR_CacheAttach(md, logPath, BeforeDiscard := 0) {
	KLR_CacheReapStages(md, logPath)
	Path := KLR_CachePath(md)
	if !FSExists(Path)
		return 0
	AttachTick := A_TickCount
	; A peer may publish after this reader closes its rejected handle. Retain
	; the observed file identity before opening, never authorize deletion from
	; a fresh snapshot taken only after the rejection decision.
	Observed := KLR_LedgerSnapshot(Path)
	stored := SQLite_Open(Path, SQLiteConst.OPEN_RO)
	if !stored {
		KLR_PrefetchDebug(logPath, "KLR cache rejected: unreadable image")
		if BeforeDiscard
			BeforeDiscard.Call()
		KLR_CacheDiscard(md, logPath, Observed)
		return 0
	}
	restored := 0
	; Windows refuses to delete a file SQLite still holds open, so a rejection is
	; decided here and carried out after the handle is closed. Discarding inside
	; the try block silently failed and left every later worker re-reading and
	; re-rejecting the same dead image.
	rejected := false
	SavedAt := ""
	try {
		Version := _KLR_CacheMetaValue(stored, "format_version")
		SavedAt := _KLR_CacheMetaValue(stored, "saved_at")
		if (Version != KLR_CACHE_FORMAT_VERSION) {
			KLR_PrefetchDebug(logPath,
				"KLR cache rejected: format '" . Version . "'")
			rejected := true
			return 0
		}
		; Worker thresholds are initialized once before any reader call. An old
		; image without this metadata cannot establish which settings it used.
		if _KLR_CacheMetaValue(stored, "walker_timings") != KL_JsonEncode(KLW_TimingValues()) {
			KLR_PrefetchDebug(logPath, "KLR cache rejected: walker timing configuration changed or missing")
			rejected := true
			return 0
		}

		Offsets := Map()
		Snapshots := Map()
		Rows := SQLite_Query(stored,
			"SELECT path, end_offset, volume, index_high, index_low, size, write_high, write_low "
			. "FROM klr_cache_ledger;")
		for Row in Rows {
			if !_KLR_CacheLedgerStillValid(Row, logPath) {
				rejected := true
				return 0
			}
			Offsets[Row["path"]] := Row["end_offset"]
			; These identities describe the bytes used to build the stored image.
			; Reopening the path here cannot establish what that image consumed.
			Snapshots[Row["path"]] := Map("ok", true, "volume", Row["volume"],
				"index_high", Row["index_high"], "index_low", Row["index_low"], "size", Row["size"],
				"write_high", Row["write_high"], "write_low", Row["write_low"])
		}
		if !_KLR_CacheCoversEveryLedger(md, Offsets, logPath) {
			rejected := true
			return 0
		}

		if KLRCache.disposable {
			; Transfer ownership before finally: unchanged projections only SELECT.
			restored := stored
			stored := 0
		} else {
			restored := SQLite_Open(":memory:")
			if !restored {
				KLR_PrefetchDebug(logPath, "KLR cache rejected: no memory database")
				return 0
			}
			if !SQLite_BackupInto(restored, stored) {
				KLR_PrefetchDebug(logPath, "KLR cache rejected: page copy failed")
				try SQLite_Close(restored)
				restored := 0
				rejected := true
				return 0
			}
		}
	} catch KLRLedgerListingError as Err {
		try LoggerError("KLReader", "Metrics cache source discovery failed: {1} Retaining the image.", Err.Message)
		return 0
	} catch Error as Err {
		rejected := true
		try LoggerError("KLReader", "Metrics cache read failed: {1} Rebuilding the rejected image.", Err.Message)
		return 0
	} finally {
		try SQLite_Close(stored)
		if rejected {
			if BeforeDiscard
				BeforeDiscard.Call()
			KLR_CacheDiscard(md, logPath, Observed)
		}
	}

	KLRCache.db := restored
	KLRCache.readonly := KLRCache.disposable
	KLRCache.last_sizes := Offsets
	KLRCache.ledger_snapshots := Snapshots
	KLRCache.pending_snapshots := Map()
	KLRCache.saved_at := SavedAt
	KLR_PrefetchDebug(logPath, "KLR cache attached with " . Offsets.Count
		. " ledger(s), readonly=" . KLRCache.readonly . " in " . (A_TickCount - AttachTick) . "ms.")
	return 1
}

KLR_CacheDiscard(md, logPath, Observed) {
	Path := KLR_CachePath(md)
	if !FSExists(Path)
		return 1
	; Verification pins the candidate against writes and replacement; deletion
	; then checks that same object under an exclusive native handle.
	if FSDeleteVerified(Path, (Candidate) => KLR_LedgerSnapshotIsSame(
			Observed, KLR_LedgerSnapshot(Candidate))) {
		KLR_PrefetchDebug(logPath, "KLR cache discarded")
		return 1
	}
	KLR_PrefetchDebug(logPath, "KLR cache could not be discarded")
	return 0
}

; A killed worker cannot execute CacheSave's finally block. Only recognize
; completed Ergopti images whose hidden producer window no longer exists.
; Unknown/truncated files and SQLite recovery companions need separate review.
KLR_CacheReapStages(md, logPath) {
	Loop Files KLR_CachePath(md) . ".stage.*", "F" {
		if !RegExMatch(A_LoopFileName, "^reader\.sqlite\.stage\.([1-9]\d{0,9})\.(\d{1,10})$", &Owner)
			continue
		Hwnd := Integer(Owner[1])
		if Hwnd > 0xFFFFFFFF || Integer(Owner[2]) > 0xFFFFFFFF
				|| DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
			continue
		try {
			Deleted := FSDeleteVerified(A_LoopFileFullPath, _KLR_CacheStageIsOwned)
			KLR_PrefetchDebug(logPath, "KLR orphan cache stage " . (Deleted ? "retired" : "retained"))
		} catch Error {
			KLR_PrefetchDebug(logPath, "KLR orphan cache stage retained: verification failed")
		}
	}
}

_KLR_CacheStageIsOwned(Path) {
	for Suffix in ["-journal", "-wal", "-shm"] {
		if FSStrictExists(Path . Suffix)
			return false
	}
	Db := SQLite_Open(Path, SQLiteConst.OPEN_RO)
	if !Db
		return false
	try {
		Rows := SQLite_Query(Db, "SELECT name FROM sqlite_schema WHERE type='table' AND name IN "
			. "('klr_cache_meta','klr_cache_ledger','events_typing','agg_app_day');")
		if Rows.Length != 4
			return false
		Version := _KLR_CacheMetaValue(Db, "format_version")
		return Version = "3" || Version = "4" || Version = "5" || Version = "6" || Version = "7" || Version = "8" || Version = "9" || Version = "10" || Version = "11" || Version = "12" || Version = "13" || Version = KLR_CACHE_FORMAT_VERSION
	} finally SQLite_Close(Db)
}





; ==================================
; ==================================
; ======= 3/ Writing a cache =======
; ==================================
; ==================================

; Persist the published projection and the offsets it consumed.
;
; The image goes to a private temp database first and is renamed over the
; previous one, because the next worker has no way to tell a truncated copy from
; a complete one — it would simply trust it. A failed save is not fatal: the
; next open falls back to the cold path and tries again.
; @param db {Integer} Published database handle to copy.
; @param sizes {Map} Ledger path to the byte offset consumed from it.
; @param md {String} Metrics directory, trailing separator included.
; @param logPath {String} Diagnostic sink shared with the rest of the reader.
; @param snapshots {Map} Same-handle identities paired with the consumed offsets.
; @returns {Integer} 1 when a complete image is in place, 0 otherwise.
KLR_CacheSave(db, sizes, md, logPath, snapshots) {
	if !db || !(sizes is Map) || !(snapshots is Map) || snapshots.Count != sizes.Count
		return 0
	Dir := KLR_CacheDir(md)
	try DirCreate(Dir)
	catch {
		KLR_PrefetchDebug(logPath, "KLR cache save failed: cache directory")
		return 0
	}
	; The guard is derived state too; install the cache ignore rule before it.
	Ignore := Dir . ".gitignore"
	if !FSExists(Ignore)
		try FSWriteCreateDurable(Ignore,
			"# Rebuilt reader projection. Derived from data.sql, never synced.`n*`n")
	Guard := FSOpenExclusiveGuard(KLR_CachePath(md) . ".publish.lock")
	if !Guard {
		KLR_PrefetchDebug(logPath, "KLR cache save skipped: publication guard unavailable")
		return 0
	}
	Result := 0
	try {
		if _KLR_CacheMustRetainPeer(sizes, snapshots, md, logPath)
			KLR_PrefetchDebug(logPath, "KLR cache save skipped: existing image retained")
		else
			Result := _KLR_CacheSaveGuarded(db, sizes, md, logPath, snapshots)
	} finally {
		if !FSCloseExclusiveGuard(Guard) {
			Result := 0
			try LoggerError("KLReader", "Metrics cache publication guard release failed.")
		}
	}
	return Result
}

; Only a currently admissible peer can establish newer consumed history.
; The caller holds the exclusive writer guard through the eventual replacement.
_KLR_CacheMustRetainPeer(sizes, snapshots, md, logPath) {
	Path := KLR_CachePath(md)
	if !FSExists(Path)
		return false
	Peer := SQLite_Open(Path, SQLiteConst.OPEN_RO)
	if !Peer {
		KLR_PrefetchDebug(logPath, "KLR cache peer comparison failed: image open")
		return true
	}
	try {
		if _KLR_CacheMetaValue(Peer, "format_version") != KLR_CACHE_FORMAT_VERSION
				|| _KLR_CacheMetaValue(Peer, "walker_timings") != KL_JsonEncode(KLW_TimingValues())
			return false
		Offsets := Map()
		Regresses := false
		Rows := SQLite_Query(Peer,
			"SELECT path,end_offset,volume,index_high,index_low,size,write_high,write_low FROM klr_cache_ledger;")
		for Row in Rows {
			if !_KLR_CacheLedgerStillValid(Row, logPath)
				return false
			LedgerPath := Row["path"]
			Offsets[LedgerPath] := Row["end_offset"]
			Row["ok"] := true
			if !sizes.Has(LedgerPath)
				Regresses := true
			else if KLR_LedgerFileIsSame(Row, snapshots.Get(LedgerPath, 0))
					&& Row["end_offset"] > sizes[LedgerPath]
				Regresses := true
		}
		return _KLR_CacheCoversEveryLedger(md, Offsets, logPath) && Regresses
	} catch {
		; An uncertain read cannot authorize overwriting an unobserved peer.
		; Ordinary cache admission owns rejection and removal of corrupt images.
		KLR_PrefetchDebug(logPath, "KLR cache peer comparison failed: metadata read")
		return true
	} finally SQLite_Close(Peer)
}

; Stage and replace while the caller owns the cache directory's writer guard.
_KLR_CacheSaveGuarded(db, sizes, md, logPath, snapshots) {
	if !db || !(sizes is Map) || !(snapshots is Map) || snapshots.Count != sizes.Count
		return 0
	try {
		if SQLite_Query(db, "SELECT name FROM main.sqlite_schema WHERE name='klr_reader_typing_payload';").Length
			throw Error("Ordered typing payloads must not belong to the durable main schema.")
	} catch Error as Failure {
		try LoggerError("KLReader", "Metrics cache publication refused: {1}.", Failure.Message)
		return 0
	}
	for LedgerPath, EndOffset in sizes {
		if !(EndOffset is Integer) || EndOffset < 0 {
			KLR_PrefetchDebug(logPath, "KLR cache save refused: invalid consumed offset")
			return 0
		}
		Consumed := snapshots.Get(LedgerPath, 0)
		Current := KLR_LedgerSnapshot(LedgerPath)
		if !KLR_LedgerFileIsSame(Consumed, Current)
				|| Consumed.Get("size", -1) < EndOffset || Current.Get("size", -1) < EndOffset
				|| (Current["size"] = Consumed["size"] && !KLR_LedgerWriteTimeIsSame(Current, Consumed)) {
			KLR_PrefetchDebug(logPath, "KLR cache save refused: consumed ledger identity changed " . LedgerPath)
			return 0
		}
	}
	SaveTick := A_TickCount
	Dir := KLR_CacheDir(md)
	try DirCreate(Dir)
	catch as Err {
		KLR_PrefetchDebug(logPath, "KLR cache save failed: " . Err.Message)
		return 0
	}
	; A_ScriptHwnd is unique per process, so two workers staging at the same
	; millisecond cannot share a scratch name and splice each other's pages.
	Path := KLR_CachePath(md)
	Staged := Path . ".stage." . A_ScriptHwnd . "." . A_TickCount
	try FSDelete(Staged)

	dest := SQLite_Open(Staged)
	if !dest {
		; Native opening can create the owned file before reporting an error.
		try FSDelete(Staged)
		KLR_PrefetchDebug(logPath, "KLR cache save failed: staging open")
		return 0
	}
	saved := false
	try {
		if !SQLite_BackupInto(dest, db) {
			KLR_PrefetchDebug(logPath, "KLR cache save failed: page copy")
			return 0
		}
		if !KLR_CacheEnsureTables(dest) {
			KLR_PrefetchDebug(logPath, "KLR cache save failed: state tables")
			return 0
		}
		Sql := "BEGIN IMMEDIATE;DELETE FROM klr_cache_meta;"
			. "DELETE FROM klr_cache_ledger;"
			. "INSERT INTO klr_cache_meta (key, value) VALUES ('format_version',"
			. SQLite_Q(KLR_CACHE_FORMAT_VERSION) . "),('saved_at',"
			. SQLite_Q(A_Now) . "),('walker_timings',"
			. SQLite_Q(KL_JsonEncode(KLW_TimingValues())) . ");"
		for LedgerPath, EndOffset in sizes {
			Snapshot := snapshots[LedgerPath]
			Sql .= "INSERT INTO klr_cache_ledger (path, end_offset, volume, "
				. "index_high, index_low, size, write_high, write_low) VALUES ("
				. SQLite_Q(LedgerPath) . "," . EndOffset . ","
				. Snapshot["volume"] . "," . Snapshot["index_high"] . ","
				. Snapshot["index_low"] . "," . Snapshot["size"] . ","
				. Snapshot["write_high"] . "," . Snapshot["write_low"] . ");"
		}
		Sql .= "COMMIT;"
		if !SQLite_Exec(dest, Sql) {
			KLR_PrefetchDebug(logPath, "KLR cache save failed: state write")
			return 0
		}
		saved := true
	} finally {
		try SQLite_Close(dest)
		if !saved
			try FSDelete(Staged)
	}

	if !FSAtomicMoveReplace(Staged, Path) {
		KLR_PrefetchDebug(logPath, "KLR cache save failed: atomic publish")
		try FSDelete(Staged)
		return 0
	}
	KLR_PrefetchDebug(logPath, "KLR cache saved in "
		. (A_TickCount - SaveTick) . "ms")
	return 1
}





; ===============================================
; ===============================================
; ======= 4/ What a tail actually changed =======
; ===============================================
; ===============================================


; Days touched by the bytes a tail appended.
;
; Read from the tail's own SQL text rather than from the database, because the
; obvious database answer is wrong on real data: the event id is NOT a monotonic
; sequence. The writer's counter restarts after an interrupted append, so the
; live store holds rows dated 2026-09-05 with id 672224 sitting behind rows
; dated 2026-09-04 with id 860941. Any rule of the form "ids above the previous
; maximum" therefore classifies a whole day as unchanged and the refresh
; recomputes nothing at all — measured, not imagined
; (klr-reader-durable-cache).
;
; Every event INSERT the writer emits carries its day as a 'YYYY-MM-DD' literal,
; so scanning the appended bytes names each affected day. A literal that appears
; inside typed text widens the scope by one day, which costs a little work and
; cannot cost correctness: recomputing a day is complete either way.
;
; Recomputing those days in full — rather than folding just the new events in —
; is what keeps a refresh identical to a cold rebuild: the walker replaces its
; JSON bucket columns wholesale on write, so a tail-only replay would truncate
; them to the tail.
; @param tails {Map} Ledger path to the tail record that was applied.
; @returns {Array} The affected days, possibly none.
KLR_CacheAffectedDates(tails) {
	Seen := Map()
	if !(tails is Map)
		return []
	for LedgerPath, Tail in tails {
		Sql := (Tail is Map) ? Tail.Get("sql", "") : ""
		Position := 1
		while Position := RegExMatch(Sql, "'(\d{4}-\d{2}-\d{2})'", &Found,
				Position) {
			Seen[Found[1]] := true
			Position += Found.Len[0]
		}
	}
	Dates := []
	for Value in Seen
		Dates.Push(Value)
	return Dates
}
