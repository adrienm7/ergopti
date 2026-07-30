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
    schema := FileRead(schema_path, "UTF-8")
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
}

KLR_ResetCache() {
    if KLRCache.db {
        try SQLite_Close(KLRCache.db)
        KLRCache.db := 0
    }
    KLRCache.last_sizes := Map()
}

; Append a single diagnostic line to prefetch.log, but only when the logger
; is at DEBUG level. KLR_BuildDatabase runs on every ingest tick (every ~5 s
; while a dashboard is open) — sometimes on the keystroke-servicing thread —
; so each FileAppend pays the open+write+close NTFS/AV tax that the rest of
; this module works hard to avoid. Routing every line through this gate makes
; the whole instrumentation path a single boolean test in normal operation
; (LOGGER_MIN_LEVEL=INFO) while keeping full tracing available on demand.
KLR_PrefetchDebug(logPath, line) {
    if !LoggerIsDebugEnabled()
        return
    try FileAppend("[" . A_Now . "] " . line . "`r`n", logPath, "UTF-8")
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
    ; Reuse the cached DB when present — only the new bytes of each
    ; device's data.sql get exec'd this round. First call (cache empty)
    ; loads the schema + the entire current contents.
    if KLRCache.db {
        KLR_PrefetchDebug(logPath, "KLR reusing cached db=" . KLRCache.db)
        ; Only need to exec deltas; skip the libversion / schema loads.
        if !KLR_ApplyIncremental(KLRCache.db, md, logPath)
            return 0
        ; Re-project only the SQL-owned fields from the append-only raw
        ; events.  Do not clear the tables here: walker-owned metrics (WPM,
        ; ngrams, correction and ergonomic details) exist only in this cache
        ; and are updated below from the incremental KLW batch.
        KLR_RebuildAggregates(KLRCache.db)
        KLR_InjectKlwBatch(KLRCache.db)
        return KLRCache.db
    }
    db := SQLite_Open(":memory:")
    KLR_PrefetchDebug(logPath, "KLR open returned db=" . db)
    if !db {
        try LoggerError("KLReader", "Metrics DB build failed — SQLite :memory: open returned null. Dashboard shows no data.")
        return 0
    }
    KLR_PrefetchDebug(logPath, "KLR loading schema...")
    if !KLR_LoadSchema(db) {
        KLR_PrefetchDebug(logPath, "KLR schema load FAILED")
        try LoggerError("KLReader", "Metrics DB build failed — schema.sql missing or invalid. Dashboard shows no data.")
        SQLite_Close(db)
        return 0
    }
    KLR_PrefetchDebug(logPath, "KLR schema OK")

    ; Fan out: every per-device folder under by_device/<uuid>/data.sql
    ; gets exec()-ed in. The schema's INSERT OR IGNORE / UPSERT clauses
    ; make this idempotent across overlapping device files.
    by_root := md . "by_device\"
    if !DirExist(by_root) {
        ; No device folder yet (first run / metrics reset) — still need to
        ; rebuild aggregates and inject the walker batch so today's live
        ; typing shows up immediately without requiring a data.sql.
        KLRCache.db := db
        KLR_ClearAggregates(db)
        KLR_RebuildAggregates(db)
        KLR_InjectKlwBatch(db)
        return db
    }
    loop files, by_root . "*", "D" {
        sql_path := A_LoopFileFullPath . "\data.sql"
        if !FileExist(sql_path)
            continue
        ; Read in 4 MB chunks to avoid OOM on large data.sql files (can be
        ; several GB after months of capture). SQLite_Exec handles partial
        ; statements gracefully — each chunk ends on a COMMIT boundary so we
        ; accumulate a carry buffer of any trailing incomplete transaction and
        ; prepend it to the next chunk.
        KLR_ExecLargeFile(db, sql_path)
        try KLRCache.last_sizes[sql_path] := FileGetSize(sql_path)
    }
    KLRCache.db := db
    ; Rebuild every derived table from durable events_* on a cold cache.  The
    ; live walker deliberately no longer writes aggregate UPSERTs to data.sql
    ; (they caused disproportionate file growth), so SQL-only rollups are not
    ; enough after a restart: speed, corrections, ergonomics and n-grams must
    ; be replayed from their raw event payloads too.
    KLR_ClearAggregates(db)
    KLR_RebuildAggregates(db)
    replayed := KLR_RebuildWalkerAggregates(db)
    if (replayed < 0) {
        KLR_ResetCache()
        return 0
    }
    if (replayed > 0) {
        ; KLUI flushes raw events before opening a dashboard.  Those same
        ; events are therefore represented by the replay above; discarding the
        ; live delta prevents a second warm refresh from adding them again.
        KLW_ResetBatch()
    } else {
        ; First run with no durable raw events yet: expose the in-RAM delta.
        KLR_InjectKlwBatch(db)
    }
    return db
}

; Stream a potentially multi-GB SQL file into `db` in 4 MB chunks.
; Reads raw UTF-8 bytes to avoid AHK string size limits and passes each
; chunk directly to SQLite_ExecBuf. A carry buffer (≤ one SQL line) holds
; any incomplete statement that was split across a chunk boundary —
; sqlite3_prepare_v2 consumes one statement per call via the tail pointer,
; so it is safe to split between complete statements at any semicolon.
KLR_ExecLargeFile(db, path) {
    static CHUNK_BYTES := 4 * 1024 * 1024   ; 4 MB per read
    ; Open in binary mode (no encoding conversion). The raw bytes are UTF-8
    ; exactly as SQLite expects — StrPut inside SQLite_ExecBuf handles the
    ; AHK-side conversion only for the tiny carry string.
    fh := FileOpen(path, "r`n", "UTF-8")
    if !fh
        return
    carry := ""
    loop {
        chunk := fh.Read(CHUNK_BYTES)
        if (chunk = "")
            break
        ; Append the previous carry (incomplete statement tail) and exec.
        ; The carry is at most one SQL line (a few hundred bytes) so
        ; concatenation cost is negligible.
        sql := carry . chunk
        carry := SQLite_ExecReturnCarry(db, sql)
    }
    fh.Close()
    ; Flush any trailing SQL (open transaction being written by keylogger,
    ; or a compacted file whose last COMMIT has no trailing newline).
    if (carry != "")
        SQLite_Exec(db, carry)
}

; Execute as many complete SQL statements from `sql` as sqlite3_prepare_v2
; can parse, and return whatever tail bytes remain (the start of an
; incomplete statement that was cut at the chunk boundary). This lets
; KLR_ExecLargeFile keep a carry of ≤ 1 statement rather than the entire
; pre-COMMIT block (which can be 170 MB for compacted files).
SQLite_ExecReturnCarry(db, sql) {
    if !db
        return sql
    n := StrPut(sql, "UTF-8")
    if (n <= 1)
        return ""
    sql_buf := Buffer(n, 0)
    StrPut(sql, sql_buf, "UTF-8")

    cur  := sql_buf.Ptr
    tail := cur
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
            ; Incomplete statement (syntax error OR statement cut at boundary).
            ; Return remainder as carry so the caller can prepend the next chunk.
            break
        }
        if pstmt {
            Loop {
                step_rc := DllCall(SQLiteConst.DLL . "\sqlite3_step", "Ptr", pstmt, "Int")
                if (step_rc != SQLiteConst.ROW)
                    break
            }
            DllCall(SQLiteConst.DLL . "\sqlite3_finalize", "Ptr", pstmt)
        }
        if (!ptail || ptail <= cur)
            break
        tail := ptail
        cur  := ptail
    }
    ; Return the unparsed tail as a UTF-16 AHK string so the caller can
    ; prepend it to the next chunk. The tail is at most one SQL statement
    ; (typically a single INSERT line), so StrGet cost is negligible.
    remaining_bytes := end_ - cur
    if (remaining_bytes <= 0)
        return ""
    return StrGet(cur, remaining_bytes, "UTF-8")
}

; Apply only the bytes appended to each device's data.sql since the
; previous KLR_BuildDatabase / KLR_ApplyIncremental pass. Returns true
; on success (regardless of whether anything actually changed); false
; on a hard read failure.
KLR_ApplyIncremental(db, md, logPath) {
    by_root := md . "by_device\"
    if !DirExist(by_root)
        return true
    total_new := 0
    loop files, by_root . "*", "D" {
        sql_path := A_LoopFileFullPath . "\data.sql"
        if !FileExist(sql_path)
            continue
        size := FileGetSize(sql_path)
        prev := KLRCache.last_sizes.Has(sql_path) ? KLRCache.last_sizes[sql_path] : 0
        if (size <= prev)
            continue   ; no new data on this device.
        ; Read just the new tail. AHK's FileRead doesn't support offsets
        ; so we open a FileObject and Seek explicitly. ReadString reads
        ; the rest of the file from the current position. Encoding must
        ; match what the writer produced (UTF-8 with BOM).
        fh := FileOpen(sql_path, "r", "UTF-8")
        if !fh
            continue
        try fh.Seek(prev, 0)
        delta := fh.Read()
        fh.Close()
        if (delta = "")
            continue
        SQLite_Exec(db, delta)
        KLRCache.last_sizes[sql_path] := size
        total_new += size - prev
    }
    KLR_PrefetchDebug(logPath, "KLR incremental: " . total_new . " new byte(s) exec'd")
    return true
}





; ================================================================
; ================================================================
; ======= 4/ Aggregate rebuild from raw events (in-memory) =======
; ================================================================
; ================================================================

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
	try SQLite_Exec(db, "INSERT INTO agg_app_day (device_id, date, app, chars, pauses, think_time_ms) SELECT device_id, date, app, SUM((SELECT COUNT(*) FROM json_each(events_json) AS ev WHERE COALESCE(json_extract(ev.value,'$[2].s'),0)<>1)), SUM(CASE WHEN pause_before_ms > 2000 THEN 1 ELSE 0 END), SUM(CASE WHEN pause_before_ms > 2000 THEN COALESCE(pause_before_ms,0) ELSE 0 END) FROM events_typing GROUP BY device_id, date, app ON CONFLICT(device_id, date, app) DO UPDATE SET chars=excluded.chars, pauses=excluded.pauses, think_time_ms=excluded.think_time_ms;")

	; agg_app_day — hotstring metrics from events_hotstring. `hs_chars` is the
	; GROSS expander output (= net_saved_chars + trigger length = the full
	; replacement length). The dashboard subtracts the trigger itself via
	; hs_chars - hs_input_chars, so feeding the already-net net_saved_chars
	; here would subtract the trigger twice and understate the savings.
	try SQLite_Exec(db, "INSERT INTO agg_app_day (device_id, date, app, hs_chars, hs_triggers, hs_input_chars) SELECT device_id, date, app, SUM(COALESCE(net_saved_chars,0) + LENGTH(COALESCE(trigger,''))), COUNT(*), SUM(LENGTH(COALESCE(trigger,''))) FROM events_hotstring WHERE kind = 'fired' GROUP BY device_id, date, app ON CONFLICT(device_id, date, app) DO UPDATE SET hs_chars=excluded.hs_chars, hs_triggers=excluded.hs_triggers, hs_input_chars=excluded.hs_input_chars;")
	; agg_app_day — hotstring suggestion count (denominator for the acceptance rate KPI).
	; fired / suggested are separate rows; we join them here rather than duplicating the
	; fired INSERT above so each kind gets a clean COUNT(*).
	try SQLite_Exec(db, "INSERT INTO agg_app_day (device_id, date, app, hs_suggested) SELECT device_id, date, app, COUNT(*) FROM events_hotstring WHERE kind = 'suggested' GROUP BY device_id, date, app ON CONFLICT(device_id, date, app) DO UPDATE SET hs_suggested=excluded.hs_suggested;")
	; agg_app_day — LLM suggestion count (denominator for the acceptance rate
	; KPI), mirroring the hs_suggested rollup immediately above. events_llm
	; was previously written to but never read anywhere (F19); this is the
	; SQL-side half of wiring it up end-to-end.
	try SQLite_Exec(db, "INSERT INTO agg_app_day (device_id, date, app, llm_suggested) SELECT device_id, date, app, COUNT(*) FROM events_llm WHERE kind = 'suggested' GROUP BY device_id, date, app ON CONFLICT(device_id, date, app) DO UPDATE SET llm_suggested=excluded.llm_suggested;")

	; agg_app_day — app foreground time from events_app_switch.
	try SQLite_Exec(db, "INSERT INTO agg_app_day (device_id, date, app, app_time_ms) SELECT device_id, date, prev_app, SUM(COALESCE(duration_ms,0)) FROM events_app_switch WHERE prev_app IS NOT NULL AND prev_app != '' GROUP BY device_id, date, prev_app ON CONFLICT(device_id, date, app) DO UPDATE SET app_time_ms=excluded.app_time_ms;")

	; agg_app_day_hourly — keystrokes per hour from events_typing. Uses the
	; same non-synthetic json_each keystroke count as `chars` above so the
	; per-hour totals reconcile with the daily chars figure (LENGTH(text)
	; would under-count and break that invariant). Only `c` is written here;
	; the per-hour error columns (e/em/es/e_buckets) stay walker-owned.
	try SQLite_Exec(db, "INSERT INTO agg_app_day_hourly (device_id, date, app, hour, c) SELECT device_id, date, app, substr(ts,12,2) AS hour, SUM((SELECT COUNT(*) FROM json_each(events_json) AS ev WHERE COALESCE(json_extract(ev.value,'$[2].s'),0)<>1)) FROM events_typing GROUP BY device_id, date, app, hour ON CONFLICT(device_id, date, app, hour) DO UPDATE SET c=excluded.c;")

	; agg_app_day_hourly_min5 — keystrokes per 5-min slot from events_typing
	; (same non-synthetic json_each count as the hourly rollup).
	try SQLite_Exec(db, "INSERT INTO agg_app_day_hourly_min5 (device_id, date, app, slot, c) SELECT device_id, date, app, substr(ts,12,2) || ':' || CASE WHEN (CAST(substr(ts,15,2) AS INTEGER)/5)*5 < 10 THEN '0' ELSE '' END || CAST((CAST(substr(ts,15,2) AS INTEGER)/5)*5 AS TEXT) AS slot, SUM((SELECT COUNT(*) FROM json_each(events_json) AS ev WHERE COALESCE(json_extract(ev.value,'$[2].s'),0)<>1)) FROM events_typing GROUP BY device_id, date, app, slot ON CONFLICT(device_id, date, app, slot) DO UPDATE SET c=excluded.c;")

	; agg_app_day_titles — window titles seen per app from events_window_switch.
	try SQLite_Exec(db, "INSERT INTO agg_app_day_titles (device_id, date, app, title, c) SELECT device_id, date, app, next_title, COUNT(*) FROM events_window_switch WHERE next_title IS NOT NULL AND next_title != '' GROUP BY device_id, date, app, next_title ON CONFLICT(device_id, date, app, title) DO UPDATE SET c=excluded.c;")
	; …then trim each (device_id, date, app) group back to the same per-app-day
	; cap the live walker enforces. The GROUP BY above replays the entire
	; events_window_switch history, so a cold rebuild would otherwise
	; reintroduce every distinct title an app ever produced and silently undo
	; the walker's cleanup — the table, and the win_titles list the dashboard
	; downloads with it, must stay bounded on both paths.
	try SQLite_Exec(db, "DELETE FROM agg_app_day_titles WHERE title NOT IN (SELECT t.title FROM agg_app_day_titles AS t WHERE t.device_id = agg_app_day_titles.device_id AND t.date = agg_app_day_titles.date AND t.app = agg_app_day_titles.app ORDER BY (t.c + t.ms) DESC LIMIT " . KLWConst.TITLE_CAP_PER_APP_DAY . ");")

	; agg_app_day_switches_to — app switch destinations from events_app_switch.
	; The real schema columns are (app_from, app_to, count); the former
	; (app, switched_to, c) names did not exist, so this INSERT failed
	; silently and the table was left walker-only. Now SQL owns it all-time.
	try SQLite_Exec(db, "INSERT INTO agg_app_day_switches_to (device_id, date, app_from, app_to, count) SELECT device_id, date, prev_app, next_app, COUNT(*) FROM events_app_switch WHERE prev_app IS NOT NULL AND next_app IS NOT NULL GROUP BY device_id, date, prev_app, next_app ON CONFLICT(device_id, date, app_from, app_to) DO UPDATE SET count=excluded.count;")

	; agg_system_day — system events (wifi, lock, sleep) from events_system.
	try SQLite_Exec(db, "INSERT INTO agg_system_day (device_id, date, wifi_changes, locked_ms, sleep_ms, awake_ms) SELECT device_id, date, SUM(CASE WHEN action='wifi_change' THEN 1 ELSE 0 END), SUM(CASE WHEN action='lock' THEN CAST(json_extract(metadata_json,'$.duration_ms') AS INTEGER) ELSE 0 END), SUM(CASE WHEN action='sleep' THEN CAST(json_extract(metadata_json,'$.duration_ms') AS INTEGER) ELSE 0 END), SUM(CASE WHEN action='wake' THEN CAST(json_extract(metadata_json,'$.duration_ms') AS INTEGER) ELSE 0 END) FROM events_system GROUP BY device_id, date ON CONFLICT(device_id, date) DO UPDATE SET wifi_changes=excluded.wifi_changes, locked_ms=excluded.locked_ms, sleep_ms=excluded.sleep_ms, awake_ms=excluded.awake_ms;")
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

KLR_RebuildWalkerAggregates(db) {
    global KLRReplay
    if !db
        return -1

    ; Live capture keeps its current per-app context.  The replay uses the
    ; same walker implementation, temporarily with a fresh context, then
    ; restores the live state without leaking historic n-grams into new input.
    saved_ctx := KLW.ctx
    saved_batch := KLW.batch
    replayed := 0
    ok := true
    try {
        devices := SQLite_Query(db,
            "SELECT DISTINCT device_id FROM ("
            . "SELECT device_id FROM events_typing "
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
            typed_sql := "SELECT ts, app, title, layout, events_json FROM events_typing"
                . device_where . " ORDER BY ts, id;"
            window_sql := "SELECT ts, app, prev_title, next_title, duration_ms FROM events_window_switch"
                . device_where . " ORDER BY ts, id;"
            system_sql := "SELECT ts, action, metadata_json FROM events_system"
                . device_where . " ORDER BY ts, id;"

            if (SQLite_EachRow(db, typed_sql, Func("KLR_ReplayTypingRow")) < 0
                    || SQLite_EachRow(db, window_sql, Func("KLR_ReplayWindowRow")) < 0
                    || SQLite_EachRow(db, system_sql, Func("KLR_ReplaySystemRow")) < 0
                    || !KLR_ReplayFlush()) {
                ok := false
                break
            }
            replayed += KLRReplay["replayed"]
        }
    } catch {
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
        "title", KLR_RowValue(row, "title", ""),
        "layout", KLR_RowValue(row, "layout", ""),
        "events", events
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
