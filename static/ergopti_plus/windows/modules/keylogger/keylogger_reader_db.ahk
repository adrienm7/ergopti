; modules/keylogger/keylogger_reader_db.ahk

; ==============================================================================
; MODULE: Keylogger Reader — Database layer
; DESCRIPTION:
; Constants, schema loading, in-memory SQLite database construction, incremental
; update pass, and aggregate rebuilding. Extracted from keylogger_reader.ahk so
; the database-access layer can be read and maintained independently from the
; JSON projection layer (keylogger_reader_manifest.ahk + keylogger_reader_ngrams.ahk).
;
; FEATURES & RATIONALE:
; 1. KLRCache: persists the :memory: DB handle across ingest ticks to avoid
;    reloading the full data.sql on every 500 ms timer fire.
; 2. KLR_ExecLargeFile / SQLite_ExecReturnCarry: stream multi-GB files in 4 MB
;    chunks with a carry buffer so statement boundaries are never split.
; 3. KLR_ApplyIncremental: only exec()s the NEW bytes of each device's data.sql.
; 4. KLR_RebuildAggregates: GROUP BY projection from raw events_* rows, called
;    after every full load or incremental update.
; ==============================================================================





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class KLReadConst {
		; Maximum number of n-gram rows projected per (date-range, table). We
		; ship the whole dataset to the page (filters apply client-side per
		; the « niveau 1 » contract) so this only kicks in to defuse a corner
		; case where the user has accumulated millions of rows after months
		; of capture. 50_000 keeps the JSON under ~5 MB which Edge handles
		; without breaking a sweat.
		static MAX_NGRAM_ROWS := 50000
		; Bound the transient walker batch during a cold reconstruction.  Raw
		; events remain the durable source of truth, while this cap keeps a large
		; multi-month history from creating one enormous AHK Map / SQL string.
		static REPLAY_FLUSH_ENTRIES := 500
}





; ================================
; ================================
; ======= 2/ Schema loader =======
; ================================
; ================================

; Resolve the canonical schema.sql path. The shared schema lives at
; `static/ergopti_plus/_shared/data/db/schema.sql`; _StaticDir already
; resolves to the right root in both dev and compiled modes.
KLR_ResolveSchemaPath() {
		global _SharedDir
		base := _SharedDir . "\data\db\schema.sql"
		loop files, base
				return A_LoopFileFullPath
		return base
}

KLR_LoadSchema(db) {
		schema_path := KLR_ResolveSchemaPath()
		if !FileExist(schema_path)
				return false
		try schema := FileRead(schema_path, "UTF-8")
		catch as err {
				try LoggerError("KLReader", "Schema read failed: {1}.", err.Message)
				return false
		}
		return SQLite_Exec(db, schema)
}





; =======================================
; =======================================
; ======= 3/ Database materialise =======
; =======================================
; =======================================

; Module-level cache for the in-memory SQLite database. Rebuilding the
; entire schema + every device's data.sql on every ingest tick was
; turning each push into a multi-second freeze. We now keep the DB
; alive across calls and only exec the NEW bytes appended to each
; data.sql since the last call.
class KLRCache {
		static db := 0
		static last_sizes := Map()    ; absolute_path → byte_offset already loaded
		; Only bounded file metadata survives an incomplete writer boundary. SQL is
		; reread from last_sizes[path] after a snapshot changes, so a transaction
		; containing hundreds of MB cannot become session-lifetime AHK heap state.
		static pending_snapshots := Map() ; absolute_path → {snapshot, end_offset}
}

KLR_ResetCache() {
		if KLRCache.db {
				try SQLite_Close(KLRCache.db)
				KLRCache.db := 0
		}
		KLRCache.last_sizes := Map()
		KLRCache.pending_snapshots := Map()
}

; Append a single diagnostic line to prefetch.log, but only when the logger
; is at DEBUG level. KLR_BuildDatabase runs on every ingest tick (every ~5 s
; while a dashboard is open) — sometimes on the keystroke-servicing thread —
; so each FileAppend pays the open+write+close NTFS/AV tax that the rest of
; this module works hard to avoid. Routing every line through this gate makes
; the whole instrumentation path a single boolean test in normal operation
; (LOGGER_MIN_LEVEL=INFO) while keeping full tracing available on demand.
KLR_PrefetchDebug(logPath, line, MaxBytes := 0) {
		return LoggerAppendBoundedDebug(logPath, "[" . A_Now . "] " . line, MaxBytes)
}

; Build a fresh in-memory SQLite from the union of every device's
; data.sql under the metrics directory. Returns a handle the caller
; closes via SQLite_Close when done.
KLR_BuildDatabase(metrics_dir) {
		md := metrics_dir
		if !RegExMatch(md, "[\\/]$")
				md .= "\"
		global _ConfigDir, _AhkSubDir
		logPath := _ConfigDir . _AhkSubDir . "logs\prefetch.log"
		KLR_PrefetchDebug(logPath, "KLR PtrSize=" . A_PtrSize . " DLL=" . SQLiteConst.DLL)
		KLR_PrefetchDebug(logPath, "KLR DLL exists=" . (FileExist(SQLiteConst.DLL) ? "yes" : "NO!"))
		; Explicit LoadLibrary so we know whether the DLL even maps into the
		; process. A nullptr from LoadLibrary means a dependency is missing
		; or the binary is malformed. AHK's DllCall hits LoadLibrary too,
		; but it does so silently and a load failure on some hosts comes
		; back as a hard process crash rather than an exception.
		hmod := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
		KLR_PrefetchDebug(logPath, "LoadLibrary returned hmod=" . hmod)
		if !hmod {
				gle := DllCall("kernel32\GetLastError", "UInt")
				KLR_PrefetchDebug(logPath, "LoadLibrary FAILED, GetLastError=" . gle)
				try LoggerError("KLReader", "Metrics DB build failed — winsqlite3.dll not loadable (GetLastError={1}). Dashboard shows no data.", gle)
				return 0
		}
		proc := DllCall("kernel32\GetProcAddress", "Ptr", hmod, "AStr", "sqlite3_libversion", "Ptr")
		KLR_PrefetchDebug(logPath, "GetProcAddress(libversion)=" . proc)
		if !proc {
				KLR_PrefetchDebug(logPath, "symbol not found - wrong DLL?")
				try LoggerError("KLReader", "Metrics DB build failed — sqlite3_libversion symbol not found in winsqlite3.dll. Dashboard shows no data.")
				return 0
		}
		try {
				ver_ptr := DllCall(proc, "Ptr")
				ver := ver_ptr ? StrGet(ver_ptr, "UTF-8") : "(null)"
				KLR_PrefetchDebug(logPath, "pre-open libversion=" . ver)
		} catch as err {
				KLR_PrefetchDebug(logPath, "pre-open libversion FAILED: " . err.Message)
				try LoggerError("KLReader", "Metrics DB build failed — sqlite3_libversion call failed ({1}). Dashboard shows no data.", err.Message)
				return 0
		}
		KLR_PrefetchDebug(logPath, "KLR opening :memory:")
		; A warm refresh never mutates the published handle. Collect all new bytes,
		; clone the last-good database, and apply/re-project on that private handle.
		; Publication swaps both DB and offsets only after every ledger reaches a
		; complete autocommit boundary.
		if KLRCache.db {
				KLR_PrefetchDebug(logPath, "KLR reusing cached db=" . KLRCache.db)
				update := KLR_PrepareIncremental(md, logPath)
				if !update.Get("ok", false) {
						if update.Get("rebuild", false) {
								cold := KLR_BuildColdCandidate(md, logPath)
								if cold.Get("ok", false) {
										KLR_PublishCandidate(cold["db"], cold["sizes"])
										return KLRCache.db
								}
						}
						return KLRCache.db
				}
				if (KLRCache.pending_snapshots.Count > 0
								&& !update.Get("changed", false)) {
						; A crashed/interrupted writer can leave a tail incomplete for hours.
						; Retry only after a participating snapshot changes, instead of cloning
						; the whole database every five seconds while all files are stable.
						return KLRCache.db
				}
				if (update["tails"].Count = 0) {
						if update.Get("changed", false)
								KLRCache.pending_snapshots := Map()
						; Preserve the existing zero-copy live-walker path. In production each
						; projection already runs in a disposable worker, and an unchanged
						; ledger must not pay an O(database-size) sqlite3_backup every tick.
						if !KLR_RebuildAggregates(KLRCache.db) {
								try LoggerError("KLReader",
										"Aggregate refresh failed; retaining the existing dashboard projection.")
								return KLRCache.db
						}
						KLR_InjectKlwBatch(KLRCache.db)
						return KLRCache.db
				}

				clone_tick := HotPath_Now()
				candidate := 0
				try {
						candidate := SQLite_CloneMemory(KLRCache.db)
				} finally {
						HotPath_LogIfSlow("KLR.CandidateClone", clone_tick,
								update["tails"].Count . " ledger tail(s)")
				}
				if !candidate {
						try LoggerError("KLReader", "Metrics DB candidate clone failed; retaining the last-good dashboard projection.")
						return KLRCache.db
				}
				applied := KLR_ApplyIncremental(candidate, update["tails"], logPath)
				if !applied.Get("ok", false) {
						try SQLite_Close(candidate)
						; Retain only bounded identity/size/mtime metadata. Whether the tail
						; is incomplete or invalid, a stable file cannot become valid; after
						; any append or in-place repair, all discarded sibling tails are read
						; again from their unchanged published offsets.
						KLRCache.pending_snapshots := KLR_TailSnapshots(update["tails"])
						return KLRCache.db
				}

				; Re-project only the SQL-owned fields from append-only raw events, then
				; drain the live walker delta into the same unpublished candidate.
				if !KLR_PrepareTypingProjection(candidate) {
						try LoggerError("KLReader",
								"Encrypted typing projection failed; retaining the last-good dashboard projection.")
						try SQLite_Close(candidate)
						return KLRCache.db
				}
				if !KLR_RebuildAggregates(candidate) {
						try LoggerError("KLReader",
								"Aggregate refresh failed; retaining the last-good dashboard projection.")
						try SQLite_Close(candidate)
						return KLRCache.db
				}
				KLR_InjectKlwBatch(candidate)
				next_sizes := KLR_CopyOffsets(KLRCache.last_sizes)
				for sql_path, tail in update["tails"]
						next_sizes[sql_path] := tail["end_offset"]
				KLR_PublishCandidate(candidate, next_sizes)
				return KLRCache.db
		}

		cold := KLR_BuildColdCandidate(md, logPath)
		if !cold.Get("ok", false)
				return 0
		KLR_PublishCandidate(cold["db"], cold["sizes"])
		return KLRCache.db
}

KLR_CopyOffsets(offsets) {
		copy := Map()
		for path, offset in offsets
				copy[path] := offset
		return copy
}

KLR_TailSnapshots(tails) {
		snapshots := Map()
		for path, tail in tails {
				snapshots[path] := Map(
						"snapshot", tail["snapshot"],
						"end_offset", tail["end_offset"]
				)
		}
		return snapshots
}

KLR_PublishCandidate(candidate, sizes) {
		old_db := 0
		previous_critical := A_IsCritical
		Critical("On")
		try {
				; This three-field tuple is the reader's publication boundary. No timer
				; or WebView callback may observe a new handle with old offsets/carry.
				old_db := KLRCache.db
				KLRCache.db := candidate
				KLRCache.last_sizes := sizes
				KLRCache.pending_snapshots := Map()
		} finally {
				Critical(previous_critical ? previous_critical : "Off")
		}
		; sqlite3_close_v2 may enter the OS allocator. Keep it outside the critical
		; publication window. Immediate close relies on KLR_BuildDatabase running in
		; the disposable, single-flow /force worker guarded by
		; tests/meta/test_keylogger_prefetch_worker.ahk. A future in-process caller
		; must add borrower ownership/deferred close before reusing this publication.
		if (old_db && old_db != candidate)
				try SQLite_Close(old_db)
}

; Materialise a cold database without touching KLRCache.  This also supplies
; the recovery path for a ledger that was compacted, removed, or replaced while
; a dashboard was open: the old projection remains live until this candidate is
; completely rebuilt and atomically published.
KLR_BuildColdCandidate(md, logPath) {
		global KLRLastReplayFailure, KLRReplayDiagnosticFn
		db := SQLite_Open(":memory:")
		KLR_PrefetchDebug(logPath, "KLR open returned db=" . db)
		if !db {
				try LoggerError("KLReader", "Metrics DB build failed — SQLite :memory: open returned null. Dashboard shows no data.")
				return Map("ok", false, "db", 0, "sizes", Map())
		}
		KLR_PrefetchDebug(logPath, "KLR loading schema...")
		if !KLR_LoadSchema(db) {
				KLR_PrefetchDebug(logPath, "KLR schema load FAILED")
				try LoggerError("KLReader", "Metrics DB build failed — schema.sql missing or invalid. Dashboard shows no data.")
				try SQLite_Close(db)
				return Map("ok", false, "db", 0, "sizes", Map())
		}
		KLR_PrefetchDebug(logPath, "KLR schema OK")

		loaded_sizes := Map()
		by_root := md . "by_device\"
		if DirExist(by_root) {
				; Fan out every device ledger into the private handle.  The offset
				; comes from the FileObject position actually read, never a later
				; FileGetSize that could include a concurrent append not yet executed.
				loop files, by_root . "*", "D" {
						sql_path := A_LoopFileFullPath . "\data.sql"
						if !FileExist(sql_path)
								continue
						loaded_offset := 0
						if !KLR_ExecLargeFile(db, sql_path, &loaded_offset) {
								try LoggerError("KLReader", "Metrics DB build failed while loading a device ledger. Dashboard retains its last-good data.")
								try SQLite_Close(db)
								return Map("ok", false, "db", 0, "sizes", Map())
						}
						loaded_sizes[sql_path] := loaded_offset
				}
		}

		; Durable raw rows are authoritative on a cold build. Reconstruct every
		; derived table on the candidate before it becomes observable.
		if !KLR_PrepareTypingProjection(db) {
				try LoggerError("KLReader",
						"Metrics DB build failed while decrypting typing projections. Dashboard retains its last-good data.")
				try SQLite_Close(db)
				return Map("ok", false, "db", 0, "sizes", Map())
		}
		KLR_ClearAggregates(db)
		if !KLR_RebuildAggregates(db) {
				try LoggerError("KLReader",
						"Metrics DB aggregate rebuild failed. Dashboard retains its last-good data.")
				try SQLite_Close(db)
				return Map("ok", false, "db", 0, "sizes", Map())
		}
		replayed := KLR_RebuildWalkerAggregates(db, true)
		if (replayed < 0) {
				Failure := KLRLastReplayFailure is Map
						? KLRLastReplayFailure.Clone() : Map()
				if Failure.Count && HasMethod(KLRReplayDiagnosticFn, "Call")
						try KLRReplayDiagnosticFn.Call(Failure)
				try SQLite_Close(db)
				return Map("ok", false, "db", 0, "sizes", Map(),
						"failure", Failure)
		}
		if (replayed > 0) {
				; The live batch contains the same flushed events that replay consumed.
				KLW_ResetBatch()
		} else {
				KLR_InjectKlwBatch(db)
		}
		return Map("ok", true, "db", db, "sizes", loaded_sizes)
}

; Stream a potentially multi-GB SQL file into `db` in 4 MB chunks.
; Reads raw UTF-8 bytes to avoid AHK string size limits and passes each
; chunk directly to SQLite_ExecBuf. A carry buffer (≤ one SQL line) holds
; any incomplete statement that was split across a chunk boundary —
; sqlite3_prepare_v2 consumes one statement per call via the tail pointer,
; so it is safe to split between complete statements at any semicolon.
KLR_ExecLargeFile(db, path, &loaded_offset) {
		static CHUNK_BYTES := 4 * 1024 * 1024   ; 4 MB per read
		loaded_offset := 0
		; Open in binary mode (no encoding conversion). The raw bytes are UTF-8
		; exactly as SQLite expects — StrPut inside SQLite_ExecBuf handles the
		; AHK-side conversion only for the tiny carry string.
		try fh := FileOpen(path, "r`n", "UTF-8")
		catch as err {
				try LoggerError("KLReader", "Metrics ledger open failed: {1}.", err.Message)
				return false
		}
		if !IsObject(fh)
				return false
		carry := ""
		try {
				loop {
						chunk := fh.Read(CHUNK_BYTES)
						if (chunk = "")
								break
						; Append the previous incomplete tail and execute every complete
						; statement. A complete invalid statement fails immediately.
						result := SQLite_ExecReturnCarry(db, carry . chunk)
						if !result.Get("ok", false)
								return false
						carry := result.Get("carry", "")
				}
				loaded_offset := fh.Pos
		} catch as err {
				try LoggerError("KLReader", "Metrics ledger read failed: {1}.", err.Message)
				return false
		} finally {
				try fh.Close()
		}
		; Flush any trailing SQL (open transaction being written by keylogger,
		; or a compacted file whose last COMMIT has no trailing newline).
		if (carry != "" && !SQLite_Exec(db, carry))
				return false
		; A writer can be pre-empted after a complete INSERT semicolon but before
		; COMMIT. sqlite3_prepare then reports no textual carry even though the
		; transaction is incomplete. Never publish or advance that boundary.
		if !SQLite_IsAutocommit(db) {
				try LoggerError("KLReader", "Metrics ledger ended inside an open transaction; retaining the last-good projection.")
				return false
		}
		return true
}

; Execute as many complete SQL statements from `sql` as sqlite3_prepare_v2
; can parse. Returns {ok, carry, error}: carry is populated only when
; sqlite3_complete proves the remaining bytes are an incomplete statement,
; while complete invalid SQL and step failures return ok=false. This lets
; KLR_ExecLargeFile keep a carry of ≤ 1 statement rather than the entire
; pre-COMMIT block (which can be 170 MB for compacted files).
SQLite_ExecReturnCarry(db, sql) {
		if !db
				return Map("ok", false, "carry", "", "error", "missing database")
		n := StrPut(sql, "UTF-8")
		if (n <= 1)
				return Map("ok", true, "carry", "", "error", "")
		sql_buf := Buffer(n, 0)
		StrPut(sql, sql_buf, "UTF-8")

		cur  := sql_buf.Ptr
		end_ := cur + n - 1   ; exclude trailing NUL
		pstmt_buf := Buffer(8, 0)
		ptail_buf := Buffer(8, 0)
		while (cur < end_) {
				NumPut("Ptr", 0, pstmt_buf, 0)
				NumPut("Ptr", 0, ptail_buf, 0)
				rc := DllCall(SQLiteConst.DLL . "\sqlite3_prepare_v2",
						"Ptr",  db,
						"Ptr",  cur,
						"Int",  -1,
						"Ptr",  pstmt_buf.Ptr,
						"Ptr",  ptail_buf.Ptr,
						"Int")
				pstmt := NumGet(pstmt_buf, 0, "Ptr")
				ptail := NumGet(ptail_buf, 0, "Ptr")
				if (rc != SQLiteConst.OK) {
						remaining_bytes := end_ - cur
						remaining := remaining_bytes > 0
								? StrGet(cur, remaining_bytes, "UTF-8") : ""
						complete := DllCall(SQLiteConst.DLL . "\sqlite3_complete",
								"Ptr", cur, "Int")
						if !complete
								return Map("ok", true, "carry", remaining, "error", "")
						try LoggerError("KLReader", "Metrics SQL prepare failed (rc={1}): {2}", rc, SQLite_LastError(db))
						return Map("ok", false, "carry", "", "error", SQLite_LastError(db))
				}
				if pstmt {
						Loop {
								step_rc := DllCall(SQLiteConst.DLL . "\sqlite3_step", "Ptr", pstmt, "Int")
								if (step_rc != SQLiteConst.ROW)
										break
						}
						if (step_rc != SQLiteConst.DONE) {
								try LoggerError("KLReader", "Metrics SQL step failed (rc={1}): {2}", step_rc, SQLite_LastError(db))
								SQLite_FinalizeStatement(pstmt)
								return Map("ok", false, "carry", "", "error", SQLite_LastError(db))
						}
						finalize_rc := SQLite_FinalizeStatement(pstmt)
						if (finalize_rc != SQLiteConst.OK) {
								try LoggerError("KLReader", "Metrics SQL finalize failed (rc={1}): {2}", finalize_rc, SQLite_LastError(db))
								return Map("ok", false, "carry", "", "error", SQLite_LastError(db))
						}
				}
				if (!ptail || ptail <= cur) {
						try LoggerError("KLReader", "Metrics SQL parser made no forward progress.")
						return Map("ok", false, "carry", "", "error", "no parser progress")
				}
				cur  := ptail
		}
		return Map("ok", true, "carry", "", "error", "")
}

; Read from a byte boundary that was observed on the FileObject itself.  The
; returned end_offset therefore names exactly the bytes present in `sql`, even
; when the writer appends between FileGetSize and Read.
KLR_LedgerSnapshotFromHandle(file_handle) {
		; The adapter owns the Win32 call. Volume/file index identifies replacement
		; files; the 100 ns FILETIME detects a same-length in-place repair.
		return FSHandleSnapshot(file_handle)
}

KLR_LedgerSnapshot(path) {
		try fh := FileOpen(path, "r")
		catch as err {
				try LoggerError("KLReader", "Metrics ledger snapshot open failed: {1}.", err.Message)
				return Map("ok", false)
		}
		if !IsObject(fh)
				return Map("ok", false)
		try {
				return KLR_LedgerSnapshotFromHandle(fh.Handle)
		} finally {
				try fh.Close()
		}
}

KLR_LedgerFileIsSame(left, right) {
		if !(left is Map) || !(right is Map)
				return false
		return left.Get("ok", false) && right.Get("ok", false)
				&& left.Get("volume", -1) = right.Get("volume", -2)
				&& left.Get("index_high", -1) = right.Get("index_high", -2)
				&& left.Get("index_low", -1) = right.Get("index_low", -2)
}

KLR_LedgerSnapshotIsSame(left, right) {
		return KLR_LedgerFileIsSame(left, right)
				&& left.Get("size", -1) = right.Get("size", -2)
				&& left.Get("write_high", -1) = right.Get("write_high", -2)
				&& left.Get("write_low", -1) = right.Get("write_low", -2)
}

KLR_ReadLedgerTail(path, start_offset) {
		try fh := FileOpen(path, "r", "UTF-8")
		catch as err {
				try LoggerError("KLReader", "Incremental ledger open failed: {1}.", err.Message)
				return Map("ok", false, "sql", "", "end_offset", start_offset)
		}
		if !IsObject(fh)
				return Map("ok", false, "sql", "", "end_offset", start_offset)
		try {
				fh.Seek(start_offset, 0)
				appended := fh.Read()
				end_offset := fh.Pos
				snapshot := KLR_LedgerSnapshotFromHandle(fh.Handle)
				if !snapshot.Get("ok", false) {
						try LoggerError("KLReader", "Incremental ledger snapshot failed after reading '{1}'.", path)
						return Map("ok", false, "sql", "",
								"end_offset", start_offset)
				}
		} catch as err {
				try LoggerError("KLReader", "Incremental ledger read failed: {1}.", err.Message)
				return Map("ok", false, "sql", "", "end_offset", start_offset)
		} finally {
				try fh.Close()
		}
		return Map("ok", true, "sql", appended,
				"end_offset", end_offset, "snapshot", snapshot)
}

; Snapshot every ledger without mutating the published DB or offsets. A failed
; candidate retains only bounded snapshots. Once any participating file changes,
; every tail is reread from its unchanged published offset so multiple devices
; still participate in one all-or-nothing publication.
KLR_PrepareIncremental(md, logPath) {
		by_root := md . "by_device\"
		if !DirExist(by_root) {
				if KLRCache.last_sizes.Count {
						try LoggerError("KLReader", "The cached metrics ledger root disappeared; rebuilding from source.")
						return Map("ok", false, "rebuild", true, "changed", false,
								"tails", Map())
				}
				return Map("ok", true, "rebuild", false, "changed", false,
						"tails", Map())
		}

		current_snapshots := Map()
		seen_paths := Map()
		changed := false
		loop files, by_root . "*", "D" {
				sql_path := A_LoopFileFullPath . "\data.sql"
				if !FileExist(sql_path)
						continue
				seen_paths[sql_path] := true
				snapshot := KLR_LedgerSnapshot(sql_path)
				if !snapshot.Get("ok", false) {
						try LoggerError("KLReader", "Incremental ledger snapshot failed for '{1}'.", sql_path)
						return Map("ok", false, "rebuild", false, "changed", changed,
								"tails", Map())
				}
				current_snapshots[sql_path] := snapshot
				size := snapshot["size"]
				published := KLRCache.last_sizes.Has(sql_path)
						? KLRCache.last_sizes[sql_path] : 0
				if (size < published) {
						try LoggerError("KLReader", "Metrics ledger shrank after its cached offset; rebuilding from source.")
						return Map("ok", false, "rebuild", true, "changed", changed,
								"tails", Map())
				}

				if KLRCache.pending_snapshots.Has(sql_path) {
						pending := KLRCache.pending_snapshots[sql_path]
						pending_end := pending.Get("end_offset", published)
						pending_snapshot := pending.Get("snapshot", 0)
						if !KLR_LedgerFileIsSame(snapshot, pending_snapshot) {
								; A replacement file invalidates every old byte boundary. Rebuild
								; all ledgers cold rather than seeking an offset from another file.
								try LoggerWarn("KLReader", "Metrics ledger identity changed for '{1}' while a writer tail was pending; rebuilding from source.", sql_path)
								return Map("ok", false, "rebuild", true,
										"changed", true, "tails", Map())
						}
						if !KLR_LedgerSnapshotIsSame(snapshot, pending_snapshot)
								|| pending_end < published || size != pending_end {
								; Size alone cannot distinguish a stable partial write from an in-place
								; repair of exactly the same byte length. Identity + 100 ns FILETIME +
								; the exact FileObject end offset form the retry-change detector.
								changed := true
						}
				} else if (size > published) {
						changed := true
				}
		}

		for cached_path, _ in KLRCache.last_sizes {
				if !seen_paths.Has(cached_path) {
						try LoggerError("KLReader", "A cached metrics ledger disappeared; rebuilding from source.")
						return Map("ok", false, "rebuild", true, "changed", changed,
								"tails", Map())
				}
		}
		for pending_path, _ in KLRCache.pending_snapshots {
				if !seen_paths.Has(pending_path) {
						; A never-published new ledger can disappear without appearing in
						; last_sizes. Mark the pending snapshot consumed so the stable-tail
						; fast path cannot retain an orphan forever.
						changed := true
				}
		}

		; A stable failed boundary cannot become valid. Avoid both the O(database)
		; clone and rereading a potentially huge SQL transaction until its snapshot
		; changes. No SQL string survives the call that first observed the failure.
		if (KLRCache.pending_snapshots.Count > 0 && !changed)
				return Map("ok", true, "rebuild", false, "changed", false,
						"tails", Map())

		tails := Map()
		for sql_path, snapshot in current_snapshots {
				published := KLRCache.last_sizes.Has(sql_path)
						? KLRCache.last_sizes[sql_path] : 0
				if (snapshot["size"] = published)
						continue
				tail := KLR_ReadLedgerTail(sql_path, published)
				if !tail.Get("ok", false)
						return Map("ok", false, "rebuild", false,
								"changed", changed, "tails", tails)
				if (tail.Get("end_offset", published) <= published
								|| tail.Get("sql", "") = "") {
						try LoggerError("KLReader", "Incremental ledger grew but produced no readable SQL bytes.")
						return Map("ok", false, "rebuild", false, "changed", changed,
								"tails", tails)
				}
				tails[sql_path] := tail
		}
		return Map("ok", true, "rebuild", false, "changed", changed,
				"tails", tails)
}

; Execute prepared tails on an unpublished candidate. A textual carry OR an
; open SQLite transaction is an interrupted append, not a successful refresh.
; The caller discards the candidate and retains bounded path-specific metadata.
KLR_ApplyIncremental(db, tails, logPath) {
		total_new := 0
		for sql_path, tail in tails {
				result := SQLite_ExecReturnCarry(db, tail["sql"])
				if !result.Get("ok", false) {
						try LoggerError("KLReader", "Incremental metrics SQL is invalid; retaining the last-good dashboard projection.")
						return Map("ok", false, "incomplete", false)
				}
				if (result.Get("carry", "") != "" || !SQLite_IsAutocommit(db)) {
						KLR_PrefetchDebug(logPath, "KLR incremental writer boundary incomplete for " . sql_path)
						return Map("ok", false, "incomplete", true)
				}
				published := KLRCache.last_sizes.Has(sql_path)
						? KLRCache.last_sizes[sql_path] : 0
				total_new += tail["end_offset"] - published
		}
		KLR_PrefetchDebug(logPath, "KLR incremental: " . total_new . " new byte(s) validated")
		return Map("ok", true, "incomplete", false)
}





; ================================================================
; ================================================================
; ======= 4/ Aggregate rebuild from raw events (in-memory) =======
; ================================================================
; ================================================================

; The durable events_typing row remains encrypted. Projection consumers use a
; reader-owned table that exists only inside the disposable in-memory database.
; Keeping it in the main in-memory schema (rather than TEMP) lets sqlite_backup
; clone already-decrypted rows during warm refreshes; only newly appended raw
; identities need decryption.
KLR_EnsureTypingProjectionTable(db) {
		return SQLite_Exec(db,
				"CREATE TABLE IF NOT EXISTS klr_reader_typing_payload ("
				. "device_id TEXT NOT NULL, event_id INTEGER NOT NULL, "
				. "events_json TEXT NOT NULL, "
				. "PRIMARY KEY (device_id, event_id)) WITHOUT ROWID;")
}

KLR_NormalizeTypingEventsJson(RawValue, DeviceId, EventId, &ClearJson) {
		Encrypted := KL_Enc_IsEncrypted(RawValue)
		ClearJson := RawValue
		if Encrypted {
				try ClearJson := KL_Enc_Decrypt(RawValue)
				catch as err {
						try LoggerError("KLReader",
								"Encrypted typing projection decrypt failed for device={1} id={2}: {3}.",
								DeviceId, EventId, err.Message)
						return false
				}
				if (ClearJson = "") {
						try LoggerError("KLReader",
								"Encrypted typing projection decrypt failed for device={1} id={2}.",
								DeviceId, EventId)
						return false
				}
		}

		Decoded := 0
		try Decoded := KL_JsonDecode(ClearJson)
		if (Decoded is Array)
				return true
		if Encrypted {
				try LoggerError("KLReader",
						"Encrypted typing projection decoded to an invalid payload for device={1} id={2}.",
						DeviceId, EventId)
				return false
		}
		; Legacy plaintext rows could contain an empty/object payload. Preserve the
		; established safe-skip semantics without letting one malformed JSON value
		; abort every otherwise valid aggregate query.
		ClearJson := "[]"
		return true
}

; Populate the clear in-memory projection in bounded pages. The authoritative
; events_typing ciphertext is never updated, and a corrupt/undecryptable
; envelope rejects the unpublished candidate rather than silently dropping its
; historical metrics.
KLR_PrepareTypingProjection(db) {
		static PAGE_ROWS := 128
		if !KLR_EnsureTypingProjectionTable(db)
				return false
		HaveCursor := false
		LastDevice := ""
		LastId := 0
		loop {
				CursorWhere := HaveCursor
						? " AND (t.device_id > " . SQLite_Q(LastDevice)
								. " OR (t.device_id = " . SQLite_Q(LastDevice)
								. " AND t.id > " . LastId . "))"
						: ""
				Rows := SQLite_Query(db,
						"SELECT t.device_id, t.id, t.events_json "
						. "FROM events_typing AS t "
						. "LEFT JOIN klr_reader_typing_payload AS p "
						. "ON p.device_id=t.device_id AND p.event_id=t.id "
						. "WHERE p.device_id IS NULL" . CursorWhere
						. " ORDER BY t.device_id, t.id LIMIT " . PAGE_ROWS . ";")
				if (Rows.Length = 0)
						break
				BatchSql := "BEGIN IMMEDIATE;"
				for Row in Rows {
						DeviceId := KLR_RowValue(Row, "device_id", "")
						EventId := KLR_RowValue(Row, "id", 0)
						ClearJson := ""
						if !KLR_NormalizeTypingEventsJson(
								KLR_RowValue(Row, "events_json", ""),
								DeviceId, EventId, &ClearJson)
								return false
						BatchSql .= "INSERT INTO klr_reader_typing_payload "
								. "(device_id,event_id,events_json) VALUES ("
								. SQLite_Q(DeviceId) . "," . EventId . ","
								. SQLite_Q(ClearJson) . ");"
						LastDevice := DeviceId
						LastId := EventId
				}
				BatchSql .= "COMMIT;"
				if !SQLite_Exec(db, BatchSql) {
						try LoggerError("KLReader",
								"Typing projection cache write failed; retaining the last-good dashboard projection.")
						return false
				}
				HaveCursor := true
		}
		return true
}

; Delete all agg_* rows from the in-memory DB so that KLR_RebuildAggregates
; can recalculate them cleanly from events_*.  Called once per refresh cycle
; before KLR_RebuildAggregates.
;
; Every derived table is cleared only on a COLD cache build.  `data.sql`
; contains durable raw events, not an authoritative aggregate cache; keeping
; old ngram_* rows would make a new raw replay double-count them after a
; restart.  The warm-cache branch deliberately does not call this function.
KLR_ClearAggregates(db) {
	for tbl in ["agg_app_day", "agg_app_day_buckets", "agg_app_day_burst",
	            "agg_app_day_session", "agg_app_day_chars_class",
	            "agg_app_day_errors", "agg_app_day_ergo", "agg_app_day_layouts",
	            "agg_app_day_kc_hold", "agg_app_day_titles",
	            "agg_app_day_hourly", "agg_app_day_hourly_min5",
	            "agg_app_day_switches_to", "agg_system_day",
	            "ngram_chars", "ngram_bigrams", "ngram_trigrams",
	            "ngram_quadgrams", "ngram_pentagrams", "ngram_hexagrams",
	            "ngram_heptagrams", "ngram_words", "ngram_word_bigrams",
	            "ngram_shortcuts", "ngram_shortcut_bigrams", "ngram_keycodes",
	            "ngram_scancodes"]
		try SQLite_Exec(db, "DELETE FROM " . tbl . ";")
}

; Reconstruct the primary agg_* tables from raw events_* rows using SQL
; GROUP BY. This is called after loading events_* from data.sql so the
; reader never depends on pre-computed aggregates being stored in the file.
; Tables that require character-level iteration or ring-buffer logic
; (chars_class, errors, ergo, burst, session, kc_hold, buckets, layouts,
; all ngrams) are rebuilt by KLR_RebuildWalkerAggregates on a cold cache, and
; by KLR_InjectKlwBatch for subsequent live deltas.
KLR_ExecAggregateStep(db, StepName, Sql) {
		try {
				if SQLite_Exec(db, Sql)
						return true
		} catch as err {
				try LoggerError("KLReader", "Aggregate rebuild step {1} threw: {2}.",
						StepName, err.Message)
				return false
		}
		try LoggerError("KLReader", "Aggregate rebuild step {1} failed: {2}.",
				StepName, SQLite_LastError(db))
		return false
}

KLR_RebuildAggregates(db) {
	; agg_app_day — core typing metrics from events_typing. `chars` is the
	; manual KEYSTROKE count: one per non-synthetic events_json entry
	; (backspaces included) so it matches the macOS walk semantics the
	; dashboard JS is built against — NOT LENGTH(text), which counts the
	; shorter committed string (~2.9x smaller). events_json is an array of
	; [char, dur_ms, {kc,sk,s?,st?}] triples; synthetic keystrokes carry
	; s=1 in the meta dict (index $[2]) and are excluded. `time_ms` is NOT
	; written here: it stays walker-owned because the walker's capped
	; inter-key logic is far more accurate than a naive json_each delta sum.
	TypingDailySql := "INSERT INTO agg_app_day (device_id, date, app, chars, pauses, think_time_ms, category) "
		. "SELECT t.device_id, t.date, t.app, "
		. "SUM((SELECT COUNT(*) FROM json_each(p.events_json) AS ev WHERE COALESCE(json_extract(ev.value,'$[2].s'),0)<>1)), "
		. "SUM(CASE WHEN t.pause_before_ms > 2000 THEN 1 ELSE 0 END), "
		. "SUM(CASE WHEN t.pause_before_ms > 2000 THEN COALESCE(t.pause_before_ms,0) ELSE 0 END), "
		. "COALESCE((SELECT latest.app_category FROM events_typing AS latest "
		. "WHERE latest.device_id=t.device_id AND latest.date=t.date AND latest.app=t.app "
		. "AND COALESCE(latest.app_category,'')!='' ORDER BY latest.id DESC LIMIT 1),'') "
		. "FROM events_typing AS t JOIN klr_reader_typing_payload AS p "
		. "ON p.device_id=t.device_id AND p.event_id=t.id "
		. "GROUP BY t.device_id, t.date, t.app "
		. "ON CONFLICT(device_id, date, app) DO UPDATE SET chars=excluded.chars, "
		. "pauses=excluded.pauses, think_time_ms=excluded.think_time_ms, "
		. "category=excluded.category;"
	if !KLR_ExecAggregateStep(db, "typing-daily", TypingDailySql)
		return false

	; agg_app_day — hotstring metrics from events_hotstring. `hs_chars` is the
	; GROSS expander output (= net_saved_chars + trigger length = the full
	; replacement length). The dashboard subtracts the trigger itself via
	; hs_chars - hs_input_chars, so feeding the already-net net_saved_chars
	; here would subtract the trigger twice and understate the savings.
	if !KLR_ExecAggregateStep(db, "hotstring-fired", "INSERT INTO agg_app_day (device_id, date, app, hs_chars, hs_triggers, hs_input_chars) SELECT device_id, date, app, SUM(COALESCE(net_saved_chars,0) + LENGTH(COALESCE(trigger,''))), COUNT(*), SUM(LENGTH(COALESCE(trigger,''))) FROM events_hotstring WHERE kind = 'fired' GROUP BY device_id, date, app ON CONFLICT(device_id, date, app) DO UPDATE SET hs_chars=excluded.hs_chars, hs_triggers=excluded.hs_triggers, hs_input_chars=excluded.hs_input_chars;")
		return false
	; agg_app_day — hotstring suggestion count (denominator for the acceptance rate KPI).
	; fired / suggested are separate rows; we join them here rather than duplicating the
	; fired INSERT above so each kind gets a clean COUNT(*).
	if !KLR_ExecAggregateStep(db, "hotstring-suggested", "INSERT INTO agg_app_day (device_id, date, app, hs_suggested) SELECT device_id, date, app, COUNT(*) FROM events_hotstring WHERE kind = 'suggested' GROUP BY device_id, date, app ON CONFLICT(device_id, date, app) DO UPDATE SET hs_suggested=excluded.hs_suggested;")
		return false
	; agg_app_day — LLM suggestion count (denominator for the acceptance rate
	; KPI), mirroring the hs_suggested rollup immediately above. events_llm
	; was previously written to but never read anywhere (F19); this is the
	; SQL-side half of wiring it up end-to-end.
	if !KLR_ExecAggregateStep(db, "llm-suggested", "INSERT INTO agg_app_day (device_id, date, app, llm_suggested) SELECT device_id, date, app, COUNT(*) FROM events_llm WHERE kind = 'suggested' GROUP BY device_id, date, app ON CONFLICT(device_id, date, app) DO UPDATE SET llm_suggested=excluded.llm_suggested;")
		return false
	; agg_app_day — app foreground time from events_app_switch.
	if !KLR_ExecAggregateStep(db, "app-time", "INSERT INTO agg_app_day (device_id, date, app, app_time_ms) SELECT device_id, date, prev_app, SUM(COALESCE(duration_ms,0)) FROM events_app_switch WHERE prev_app IS NOT NULL AND prev_app != '' GROUP BY device_id, date, prev_app ON CONFLICT(device_id, date, app) DO UPDATE SET app_time_ms=excluded.app_time_ms;")
		return false

	; agg_app_day_hourly — keystrokes per hour from events_typing. Uses the
	; same non-synthetic json_each keystroke count as `chars` above so the
	; per-hour totals reconcile with the daily chars figure (LENGTH(text)
	; would under-count and break that invariant). Only `c` is written here;
	; the per-hour error columns (e/em/es/e_buckets) stay walker-owned.
	if !KLR_ExecAggregateStep(db, "typing-hourly", "INSERT INTO agg_app_day_hourly (device_id, date, app, hour, c) SELECT t.device_id, t.date, t.app, substr(t.ts,12,2) AS hour, SUM((SELECT COUNT(*) FROM json_each(p.events_json) AS ev WHERE COALESCE(json_extract(ev.value,'$[2].s'),0)<>1)) FROM events_typing AS t JOIN klr_reader_typing_payload AS p ON p.device_id=t.device_id AND p.event_id=t.id GROUP BY t.device_id, t.date, t.app, hour ON CONFLICT(device_id, date, app, hour) DO UPDATE SET c=excluded.c;")
		return false

	; agg_app_day_hourly_min5 — keystrokes per 5-min slot from events_typing
	; (same non-synthetic json_each count as the hourly rollup).
	if !KLR_ExecAggregateStep(db, "typing-min5", "INSERT INTO agg_app_day_hourly_min5 (device_id, date, app, slot, c) SELECT t.device_id, t.date, t.app, substr(t.ts,12,2) || ':' || CASE WHEN (CAST(substr(t.ts,15,2) AS INTEGER)/5)*5 < 10 THEN '0' ELSE '' END || CAST((CAST(substr(t.ts,15,2) AS INTEGER)/5)*5 AS TEXT) AS slot, SUM((SELECT COUNT(*) FROM json_each(p.events_json) AS ev WHERE COALESCE(json_extract(ev.value,'$[2].s'),0)<>1)) FROM events_typing AS t JOIN klr_reader_typing_payload AS p ON p.device_id=t.device_id AND p.event_id=t.id GROUP BY t.device_id, t.date, t.app, slot ON CONFLICT(device_id, date, app, slot) DO UPDATE SET c=excluded.c;")
		return false

	; agg_app_day_titles — window titles seen per app from events_window_switch.
	if !KLR_ExecAggregateStep(db, "window-titles", "INSERT INTO agg_app_day_titles (device_id, date, app, title, c) SELECT device_id, date, app, next_title, COUNT(*) FROM events_window_switch WHERE next_title IS NOT NULL AND next_title != '' GROUP BY device_id, date, app, next_title ON CONFLICT(device_id, date, app, title) DO UPDATE SET c=excluded.c;")
		return false
	; …then trim each (device_id, date, app) group back to the same per-app-day
	; cap the live walker enforces. The GROUP BY above replays the entire
	; events_window_switch history, so a cold rebuild would otherwise
	; reintroduce every distinct title an app ever produced and silently undo
	; the walker's cleanup — the table, and the win_titles list the dashboard
	; downloads with it, must stay bounded on both paths.
	if !KLR_ExecAggregateStep(db, "window-title-cap", "DELETE FROM agg_app_day_titles WHERE title NOT IN (SELECT t.title FROM agg_app_day_titles AS t WHERE t.device_id = agg_app_day_titles.device_id AND t.date = agg_app_day_titles.date AND t.app = agg_app_day_titles.app ORDER BY (t.c + t.ms) DESC LIMIT " . KLWConst.TITLE_CAP_PER_APP_DAY . ");")
		return false

	; agg_app_day_switches_to — app switch destinations from events_app_switch.
	; The real schema columns are (app_from, app_to, count); the former
	; (app, switched_to, c) names did not exist, so this INSERT failed
	; silently and the table was left walker-only. Now SQL owns it all-time.
	if !KLR_ExecAggregateStep(db, "app-switches", "INSERT INTO agg_app_day_switches_to (device_id, date, app_from, app_to, count) SELECT device_id, date, prev_app, next_app, COUNT(*) FROM events_app_switch WHERE prev_app IS NOT NULL AND next_app IS NOT NULL GROUP BY device_id, date, prev_app, next_app ON CONFLICT(device_id, date, app_from, app_to) DO UPDATE SET count=excluded.count;")
		return false

	; agg_system_day — system events (wifi, lock, sleep) from events_system.
	if !KLR_ExecAggregateStep(db, "system-day", "INSERT INTO agg_system_day (device_id, date, wifi_changes, locked_ms, sleep_ms, awake_ms) SELECT device_id, date, SUM(CASE WHEN action='wifi_change' THEN 1 ELSE 0 END), SUM(CASE WHEN action='lock' THEN CAST(json_extract(metadata_json,'$.duration_ms') AS INTEGER) ELSE 0 END), SUM(CASE WHEN action='sleep' THEN CAST(json_extract(metadata_json,'$.duration_ms') AS INTEGER) ELSE 0 END), SUM(CASE WHEN action='wake' THEN CAST(json_extract(metadata_json,'$.duration_ms') AS INTEGER) ELSE 0 END) FROM events_system GROUP BY device_id, date ON CONFLICT(device_id, date) DO UPDATE SET wifi_changes=excluded.wifi_changes, locked_ms=excluded.locked_ms, sleep_ms=excluded.sleep_ms, awake_ms=excluded.awake_ms;")
		return false
	return true
}

; =================================================================
; ================================================================
; ======= 5/ Durable walker reconstruction (cold cache) ==========
; ================================================================
; =================================================================

; The Windows writer persists raw events only.  This keeps data.sql compact
; and sync-friendly, but it means that the stateful walker-owned metrics cannot
; be recovered by GROUP BY after a process restart.  Rebuild them here from the
; canonical events_* rows.  Each source device gets its own walker context and
; its own SQL device literal: n-gram continuity must not cross devices, and a
; remote device must never be credited to the host opening the dashboard.
;
; Return the number of replayed raw rows, or -1 on an SQL/flush failure.  The
; caller then retains the previous dashboard file rather than rendering a
; partially rebuilt (and therefore misleading) metric set.
global KLRReplay := Map()
global KLRLastReplayFailure := Map()
global KLRReplayDiagnosticFn := KLR_ReportWalkerReplayFailure

KLR_SanitizeReplayDiagnostic(Value) {
		Text := RegExReplace(String(Value), "[\x00-\x1F\x7F]+", " ")
		return SubStr(Text, 1, 240)
}

KLR_ReportWalkerReplayFailure(Failure) {
		if !(Failure is Map)
				return false
		try LoggerError("KLReader",
				"Walker replay rejected sweep={1} device={2} row={3} id={4} ts={5}: {6}.",
				KLR_SanitizeReplayDiagnostic(Failure.Get("sweep", "unknown")),
				KLR_SanitizeReplayDiagnostic(Failure.Get("device_id", "unknown")),
				Failure.Get("row_index", 0),
				KLR_SanitizeReplayDiagnostic(Failure.Get("row_id", "unknown")),
				KLR_SanitizeReplayDiagnostic(Failure.Get("timestamp", "unknown")),
				KLR_SanitizeReplayDiagnostic(Failure.Get("message", "unknown failure")))
		return true
}

KLR_CaptureReplayFailure(Sweep, DeviceId, RowIndex, RowId, Timestamp,
		Message, RootError := 0) {
		global KLRLastReplayFailure
		if KLRLastReplayFailure.Count
				return false
		KLRLastReplayFailure := Map(
				"sweep", Sweep,
				"device_id", DeviceId,
				"row_index", RowIndex,
				"row_id", RowId,
				"timestamp", Timestamp,
				"message", String(Message),
				"root_error", RootError)
		return true
}

KLR_ReplaySweep(db, sql, Consumer, Sweep, DeviceId) {
		Failure := Map()
		Delivered := SQLite_EachRow(db, sql, Consumer, 0, Failure)
		if Delivered >= 0
				return true
		if Failure.Has("error") {
				Err := Failure["error"]
				KLR_CaptureReplayFailure(Sweep, DeviceId,
						Failure.Get("row_index", 0),
						Failure.Get("row_id", "unknown"),
						Failure.Get("timestamp", "unknown"),
						Err.Message, Err)
		} else {
				KLR_CaptureReplayFailure(Sweep, DeviceId, 0,
						"unknown", "unknown",
						"SQLite row iteration failed")
		}
		return false
}

KLR_RebuildWalkerAggregates(db, TypingProjectionReady := false) {
		global KLRReplay, KLRLastReplayFailure
		KLRLastReplayFailure := Map()
		if !db
				return -1
		if (!TypingProjectionReady && !KLR_PrepareTypingProjection(db)) {
				KLR_CaptureReplayFailure("typing-projection", "unknown", 0,
						"unknown", "unknown",
						"typing projection preparation failed")
				return -1
		}

		; Live capture keeps its current per-app context.  The replay uses the
		; same walker implementation, temporarily with a fresh context, then
		; restores the live state without leaking historic n-grams into new input.
		saved_ctx := KLW.ctx
		saved_batch := KLW.batch
		replayed := 0
		ok := true
		try {
				accepted_marker := SQLite_Q(KLWConst.LLM_ACCEPTED_METRICS_SOURCE)
				devices := SQLite_Query(db,
						"SELECT DISTINCT device_id FROM ("
						. "SELECT device_id FROM events_typing "
						. "UNION SELECT device_id FROM events_shortcut "
						. "UNION SELECT device_id FROM events_llm WHERE kind='accepted' "
						. "AND context=" . accepted_marker . " "
						. "UNION SELECT device_id FROM events_window_switch "
						. "UNION SELECT device_id FROM events_system"
						. ") WHERE device_id IS NOT NULL AND device_id != '' ORDER BY device_id;")
				for _, device_row in devices {
						device_id := KLR_RowValue(device_row, "device_id", "")
						if (device_id = "")
								continue
						KLW.ctx := Map()
						KLW_ResetBatch()
						KLRReplay := Map(
								"db", db,
								"device_lit", SQLite_Q(device_id),
								"entries_since_flush", 0,
								"replayed", 0,
								"ok", true
						)

						device_where := " WHERE device_id=" . SQLite_Q(device_id)
						logical_sql := "SELECT ts, id, 'typing' AS source_kind, app, app_category, title, layout, "
								. "p.events_json, '' AS context, '' AS prediction, 0 AS deletes, "
								. "'' AS shortcut_key "
								. "FROM events_typing AS t JOIN klr_reader_typing_payload AS p "
								. "ON p.device_id=t.device_id AND p.event_id=t.id"
								. " WHERE t.device_id=" . SQLite_Q(device_id)
								. " UNION ALL SELECT ts, id, 'llm_accepted' AS source_kind, app, "
								. "'' AS app_category, '' AS title, '' AS layout, '' AS events_json, context, prediction, "
								. "COALESCE(deletes,0) AS deletes, '' AS shortcut_key FROM events_llm"
								. device_where . " AND kind='accepted' AND context=" . accepted_marker
								. " UNION ALL SELECT ts, id, 'shortcut' AS source_kind, app, "
								. "'' AS app_category, '' AS title, '' AS layout, '' AS events_json, '' AS context, "
								. "'' AS prediction, 0 AS deletes, key AS shortcut_key "
								. "FROM events_shortcut" . device_where
								. " ORDER BY id;"
						window_sql := "SELECT ts, app, prev_title, next_title, duration_ms FROM events_window_switch"
								. device_where . " ORDER BY ts, id;"
						system_sql := "SELECT ts, action, metadata_json FROM events_system"
								. device_where . " ORDER BY ts, id;"

						if !KLR_ReplaySweep(db, logical_sql,
								KLR_ReplayLogicalRow, "logical", device_id) {
								ok := false
								break
						}
						if !KLR_ReplaySweep(db, window_sql,
								KLR_ReplayWindowRow, "window", device_id) {
								ok := false
								break
						}
						if !KLR_ReplaySweep(db, system_sql,
								KLR_ReplaySystemRow, "system", device_id) {
								ok := false
								break
						}
						if !KLR_ReplayFlush() {
								KLR_CaptureReplayFailure("flush", device_id, 0,
										"unknown", "unknown",
										"walker aggregate flush failed")
								ok := false
								break
						}
						replayed += KLRReplay["replayed"]
				}
		} catch Error as Err {
				KLR_CaptureReplayFailure("driver",
						IsSet(device_id) ? device_id : "unknown", 0,
						"unknown", "unknown",
						Err.Message, Err)
				ok := false
		} finally {
				KLW.ctx := saved_ctx
				KLW.batch := saved_batch
				KLRReplay := Map()
		}
		return ok ? replayed : -1
}

; Pull a value from a SQLite row without allowing a missing nullable column to
; abort the whole recovery.  All supplied defaults are intentionally neutral
; values for the walker.
KLR_RowValue(row, key, default := "") {
		return (row is Map && row.Has(key)) ? row[key] : default
}

; Convert a durable typing row back to the exact entry shape the live walker
; receives.  The hand-written JSON parser works on the shipped 64-bit AHK,
; unlike the old ScriptControl path, so historical physical key metadata (`kc`
; and `sk`) survives the round trip as well.
KLR_TypingRowToEntry(row) {
		events := KL_JsonDecode(KLR_RowValue(row, "events_json", ""))
		if !(events is Array)
				return 0
		return Map(
				"timestamp", KLR_RowValue(row, "ts", ""),
				"app", KLR_RowValue(row, "app", "Unknown"),
				"app_category", KLR_RowValue(row, "app_category", ""),
				"title", KLR_RowValue(row, "title", ""),
				"layout", KLR_RowValue(row, "layout", ""),
				"events", events
		)
}

; Turn one accepted-only events_llm row into the synthetic typing burst the
; legacy walker already understands. Unmarked rows are ignored: their output
; came through the old hook path and is already canonical in events_typing.
KLR_LlmAcceptedRowToEntry(row) {
		if !(row is Map)
				return 0
		if (KLR_RowValue(row, "context", "") != KLWConst.LLM_ACCEPTED_METRICS_SOURCE)
				return 0

		Deletes := 0
		RawDeletes := KLR_RowValue(row, "deletes", 0)
		try {
				if IsNumber(RawDeletes)
						Deletes := Max(0, Round(Number(RawDeletes)))
		}
		Events := []
		Loop Deletes
				Events.Push(["[BS]", 0, Map("s", 1, "st", "llm")])
		for _, Character in KLW_StringToLogicalCharacters(
				KLR_RowValue(row, "prediction", ""))
				Events.Push([Character, 0, Map("s", 1, "st", "llm")])

		return Map(
				"timestamp", KLR_RowValue(row, "ts", ""),
				"app", KLR_RowValue(row, "app", "Unknown"),
				"title", KLR_RowValue(row, "title", ""),
				"layout", KLR_RowValue(row, "layout", ""),
				"events", Events
		)
}

KLR_ShortcutRowToEntry(row) {
		return Map(
				"timestamp", KLR_RowValue(row, "ts", ""),
				"app", KLR_RowValue(row, "app", "Unknown"),
				"key", KLR_RowValue(row, "shortcut_key", "")
		)
}

KLR_WindowRowToEntry(row) {
		return Map(
				"timestamp", KLR_RowValue(row, "ts", ""),
				"app", KLR_RowValue(row, "app", "Unknown"),
				"prev_title", KLR_RowValue(row, "prev_title", ""),
				"next_title", KLR_RowValue(row, "next_title", ""),
				"duration_ms", KLR_RowValue(row, "duration_ms", 0)
		)
}

KLR_SystemRowToEntry(row) {
		metadata := KL_JsonDecode(KLR_RowValue(row, "metadata_json", ""))
		if !(metadata is Map)
				metadata := Map()
		metadata["timestamp"] := KLR_RowValue(row, "ts", "")
		metadata["action"] := KLR_RowValue(row, "action", "")
		return metadata
}

KLR_ReplayTypingRow(row) {
		global KLRReplay
		entry := KLR_TypingRowToEntry(row)
		if !entry
				return true                         ; malformed legacy payload: skip safely.
		KLW_WalkTypingEntry(entry)
		return KLR_ReplayCountAndMaybeFlush()
}

KLR_ReplayLogicalRow(row) {
		source_kind := KLR_RowValue(row, "source_kind", "typing")
		if (source_kind = "shortcut") {
				if !KLW_WalkShortcut(KLR_ShortcutRowToEntry(row))
						return true
				return KLR_ReplayCountAndMaybeFlush()
		}
		if (source_kind = "llm_accepted") {
				entry := KLR_LlmAcceptedRowToEntry(row)
				if !entry
						return true
				KLW_WalkTypingEntry(entry)
				return KLR_ReplayCountAndMaybeFlush()
		}
		return KLR_ReplayTypingRow(row)
}

KLR_ReplayWindowRow(row) {
		global KLRReplay
		KLW_WalkWindowSwitch(KLR_WindowRowToEntry(row))
		return KLR_ReplayCountAndMaybeFlush()
}

KLR_ReplaySystemRow(row) {
		global KLRReplay
		KLW_WalkSystemEvent(KLR_SystemRowToEntry(row))
		return KLR_ReplayCountAndMaybeFlush()
}

KLR_ReplayCountAndMaybeFlush() {
		global KLRReplay
		KLRReplay["replayed"] += 1
		KLRReplay["entries_since_flush"] += 1
		if (KLRReplay["entries_since_flush"] < KLReadConst.REPLAY_FLUSH_ENTRIES)
				return true
		return KLR_ReplayFlush()
}

KLR_ReplayFlush() {
		global KLRReplay
		if !KLRReplay.Count
				return false
		sql := KLW_BuildBatchSql(KLRReplay["device_lit"])
		KLRReplay["entries_since_flush"] := 0
		if (sql = "")
				return true
		if !SQLite_Exec(KLRReplay["db"], "BEGIN TRANSACTION;`n" . sql . "`nCOMMIT;") {
				KLRReplay["ok"] := false
				return false
		}
		return true
}

; Drain KLW.batch (the in-RAM walker accumulator) into the in-memory DB.
; This populates the tables that cannot be reconstructed by SQL GROUP BY
; alone: agg_app_day_chars_class, agg_app_day_errors, agg_app_day_ergo,
; agg_app_day_burst, agg_app_day_session, agg_app_day_kc_hold,
; agg_app_day_layouts, agg_app_day_buckets, and all ngram_* tables.
; KLW_BuildBatchSql() resets KLW.batch after generating the SQL — so the
; next ingest tick starts with a clean accumulator.
KLR_InjectKlwBatch(db) {
	agg_sql := ""
	try agg_sql := KLW_BuildBatchSql()
	if (agg_sql != "")
		SQLite_Exec(db, "BEGIN TRANSACTION;`n" . agg_sql . "`nCOMMIT;")
}
