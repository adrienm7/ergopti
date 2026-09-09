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
;    offset. A replaced or compacted ledger forces a cold rebuild.
; 3. Publication is atomic: the image is written to a private temp database and
;    renamed over the previous one, so an interrupted save can never leave a
;    half-written cache for the next worker to trust.
; 4. A refresh recomputes whole affected days, never just the appended rows. The
;    walker is stateful and its context is not persisted with the cache, so
;    folding in a tail alone cannot reproduce cross-event statistics.
; ==============================================================================

#Requires Autohotkey v2.0+

; Bump whenever the cache's own tables, or the projection tables it stores,
; change shape. An older image is discarded rather than migrated: it can always
; be rebuilt from data.sql, and a migration path would be one more thing that
; can be wrong about data the user cannot inspect.
; Version 4 persists numeric typing counts instead of clear ordered payloads.
; Reject older images through the close-before-discard path before reusing them.
global KLR_CACHE_FORMAT_VERSION := "4"

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
		. "index_low INTEGER NOT NULL, size INTEGER NOT NULL) WITHOUT ROWID;")
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
	return true
}

; Every ledger present on disk must be described by the cache. A device that
; appeared since the image was written has no offset and no replayed walker
; state, and there is no correct partial answer for it.
_KLR_CacheCoversEveryLedger(md, Offsets, logPath) {
	by_root := md . "by_device\"
	if !DirExist(by_root)
		return Offsets.Count = 0
	loop files, by_root . "*", "D" {
		sql_path := A_LoopFileFullPath . "\data.sql"
		if !FileExist(sql_path)
			continue
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
; @returns {Integer} 1 when KLRCache now holds a usable image, 0 otherwise.
KLR_CacheAttach(md, logPath) {
	Path := KLR_CachePath(md)
	if !FSExists(Path)
		return 0
	AttachTick := A_TickCount
	stored := SQLite_Open(Path, SQLiteConst.OPEN_RO)
	if !stored {
		KLR_PrefetchDebug(logPath, "KLR cache rejected: unreadable image")
		KLR_CacheDiscard(md, logPath)
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

		Offsets := Map()
		Snapshots := Map()
		Rows := SQLite_Query(stored,
			"SELECT path, end_offset, volume, index_high, index_low, size "
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
				"index_high", Row["index_high"], "index_low", Row["index_low"], "size", Row["size"])
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
	} catch Error as Err {
		rejected := true
		try LoggerError("KLReader", "Metrics cache read failed: {1} Rebuilding the rejected image.", Err.Message)
		return 0
	} finally {
		try SQLite_Close(stored)
		if rejected
			KLR_CacheDiscard(md, logPath)
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

KLR_CacheDiscard(md, logPath) {
	Path := KLR_CachePath(md)
	if !FSExists(Path)
		return 1
	if FSDelete(Path) {
		KLR_PrefetchDebug(logPath, "KLR cache discarded")
		return 1
	}
	KLR_PrefetchDebug(logPath, "KLR cache could not be discarded")
	return 0
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
	try {
		if SQLite_Query(db, "SELECT name FROM main.sqlite_schema WHERE name='klr_reader_typing_payload';").Length
			throw Error("Ordered typing payloads must not belong to the durable main schema.")
	} catch Error as Failure {
		try LoggerError("KLReader", "Metrics cache publication refused: {1}.", Failure.Message)
		return 0
	}
	for LedgerPath, EndOffset in sizes {
		Consumed := snapshots.Get(LedgerPath, 0)
		Current := KLR_LedgerSnapshot(LedgerPath)
		if !KLR_LedgerFileIsSame(Consumed, Current)
				|| Consumed.Get("size", -1) < EndOffset || Current.Get("size", -1) < EndOffset {
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
	; The metrics store is a synced folder for most users and a git working tree
	; for some. A rebuilt half-gigabyte projection must never be committed or
	; copied between machines: it is derived from data.sql, and a copy carrying
	; another machine's byte offsets would be rejected on arrival anyway.
	Ignore := Dir . ".gitignore"
	if !FSExists(Ignore)
		try FSWriteCreateDurable(Ignore,
			"# Rebuilt reader projection. Derived from data.sql, never synced.`n*`n")
	; A_ScriptHwnd is unique per process, so two workers staging at the same
	; millisecond cannot share a scratch name and splice each other's pages.
	Path := KLR_CachePath(md)
	Staged := Path . ".stage." . A_ScriptHwnd . "." . A_TickCount
	try FSDelete(Staged)

	dest := SQLite_Open(Staged)
	if !dest {
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
			. SQLite_Q(A_Now) . ");"
		for LedgerPath, EndOffset in sizes {
			Snapshot := snapshots[LedgerPath]
			Sql .= "INSERT INTO klr_cache_ledger (path, end_offset, volume, "
				. "index_high, index_low, size) VALUES ("
				. SQLite_Q(LedgerPath) . "," . EndOffset . ","
				. Snapshot["volume"] . "," . Snapshot["index_high"] . ","
				. Snapshot["index_low"] . "," . Snapshot["size"] . ");"
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
