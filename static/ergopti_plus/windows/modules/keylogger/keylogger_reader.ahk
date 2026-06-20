; modules/keylogger_reader.ahk

; ==============================================================================
; MODULE: Keylogger SQLite Reader (AHK)
; DESCRIPTION:
; Windows port of modules/keylogger/sqlite_reader.lua. Builds an in-memory
; SQLite database from `_shared/data/db/schema.sql` + the device's
; `data.sql`, then projects the result into the JSON shape consumed by the
; metrics_typing / metrics_apps webview frontends.
;
; FEATURES & RATIONALE:
; 1. In-memory database: opening a `:memory:` SQLite handle and exec()-ing
;    schema + data.sql is fast (10-50 ms for a few hundred kB) and avoids
;    creating a stale db.sqlite file on disk that would diverge from the
;    canonical text source.
; 2. Cross-device aggregation: the dashboard JS expects a single global
;    stat per (date, app); the SQL projection sums across every
;    device_id row that survived the load.
; 3. Format-stable: the emitted manifest / today_idx shapes match
;    sqlite_reader.lua bit-for-bit so the JS can read either source
;    without a switch.
; 4. Fail-fast: a missing schema.sql, an invalid data.sql, or an absent
;    winsqlite3.dll all surface immediately as Logger.error and return
;    an empty manifest — the dashboard will show "no data" rather than
;    a half-projected blob.
; ==============================================================================

#Requires Autohotkey v2.0+





; ===================================
; ============================
; ======= 1/ Constants =======
; ============================
; ===================================

class KLReadConst {
    ; Maximum number of n-gram rows projected per (date-range, table). We
    ; ship the whole dataset to the page (filters apply client-side per
    ; the « niveau 1 » contract) so this only kicks in to defuse a corner
    ; case where the user has accumulated millions of rows after months
    ; of capture. 50_000 keeps the JSON under ~5 MB which Edge handles
    ; without breaking a sweat.
    static MAX_NGRAM_ROWS := 50000
}





; ===================================
; ================================
; ======= 2/ Schema loader =======
; ================================
; ===================================

; Resolve the canonical schema.sql path. The shared schema lives at
; `static/ergopti_plus/shared/data/db/schema.sql`; _StaticDir already
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





; =========================================
; =======================================
; ======= 3/ Database materialise =======
; =======================================
; =========================================

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
        return 0
    }
    proc := DllCall("kernel32\GetProcAddress", "Ptr", hmod, "AStr", "sqlite3_libversion", "Ptr")
    KLR_PrefetchDebug(logPath, "GetProcAddress(libversion)=" . proc)
    if !proc {
        KLR_PrefetchDebug(logPath, "symbol not found - wrong DLL?")
        return 0
    }
    try {
        ver_ptr := DllCall(proc, "Ptr")
        ver := ver_ptr ? StrGet(ver_ptr, "UTF-8") : "(null)"
        KLR_PrefetchDebug(logPath, "pre-open libversion=" . ver)
    } catch as err {
        KLR_PrefetchDebug(logPath, "pre-open libversion FAILED: " . err.Message)
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
        ; Rebuild aggregates from events_* on every cycle — agg_* are no
        ; longer stored in data.sql so they must be recomputed in memory.
        KLR_ClearAggregates(KLRCache.db)
        KLR_RebuildAggregates(KLRCache.db)
        KLR_InjectKlwBatch(KLRCache.db)
        return KLRCache.db
    }
    db := SQLite_Open(":memory:")
    KLR_PrefetchDebug(logPath, "KLR open returned db=" . db)
    if !db
        return 0
    KLR_PrefetchDebug(logPath, "KLR loading schema...")
    if !KLR_LoadSchema(db) {
        KLR_PrefetchDebug(logPath, "KLR schema load FAILED")
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
    ; Rebuild aggregates from events_* — agg_* are no longer persisted in
    ; data.sql, so they must be computed in memory on every full load too.
    KLR_ClearAggregates(db)
    KLR_RebuildAggregates(db)
    KLR_InjectKlwBatch(db)
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





; =================================================================
; ================================================================
; ======= 4/ Aggregate rebuild from raw events (in-memory) =======
; ================================================================
; =================================================================

; Delete all agg_* rows from the in-memory DB so that KLR_RebuildAggregates
; can recalculate them cleanly from events_*.  Called once per refresh cycle
; before KLR_RebuildAggregates.
;
; Ngram tables are intentionally NOT cleared here: their data comes from the
; persisted data.sql file (loaded on open) and from KLW.batch injected by
; KLR_InjectKlwBatch.  Clearing them would wipe historical ngram counts that
; are never repopulated by KLR_RebuildAggregates, leaving statistics empty
; until the next walker flush.
KLR_ClearAggregates(db) {
	for tbl in ["agg_app_day", "agg_app_day_buckets", "agg_app_day_burst",
	            "agg_app_day_session", "agg_app_day_chars_class",
	            "agg_app_day_errors", "agg_app_day_ergo", "agg_app_day_layouts",
	            "agg_app_day_kc_hold", "agg_app_day_titles",
	            "agg_app_day_hourly", "agg_app_day_hourly_min5",
	            "agg_app_day_switches_to", "agg_system_day"]
		try SQLite_Exec(db, "DELETE FROM " . tbl . ";")
}

; Reconstruct the primary agg_* tables from raw events_* rows using SQL
; GROUP BY. This is called after loading events_* from data.sql so the
; reader never depends on pre-computed aggregates being stored in the file.
; Tables that require character-level iteration or ring-buffer logic
; (chars_class, errors, ergo, burst, session, kc_hold, buckets, layouts,
; all ngrams) are left empty here and populated by KLR_InjectKlwBatch
; which drains the in-RAM KLW.batch accumulated by the ingest walker.
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
	try SQLite_Exec(db, "INSERT INTO agg_app_day (device_id, date, app, chars, pauses, think_time_ms) SELECT device_id, date, app, SUM((SELECT COUNT(*) FROM json_each(events_json) AS ev WHERE COALESCE(json_extract(ev.value,'$[2].s'),0)<>1)), SUM(CASE WHEN pause_before_ms > 2000 THEN 1 ELSE 0 END), SUM(CASE WHEN pause_before_ms > 2000 THEN COALESCE(pause_before_ms,0) ELSE 0 END) FROM events_typing GROUP BY device_id, date, app ON CONFLICT(device_id, date, app) DO UPDATE SET chars=chars+excluded.chars, pauses=pauses+excluded.pauses, think_time_ms=think_time_ms+excluded.think_time_ms;")

	; agg_app_day — hotstring metrics from events_hotstring. `hs_chars` is the
	; GROSS expander output (= net_saved_chars + trigger length = the full
	; replacement length). The dashboard subtracts the trigger itself via
	; hs_chars - hs_input_chars, so feeding the already-net net_saved_chars
	; here would subtract the trigger twice and understate the savings.
	try SQLite_Exec(db, "INSERT INTO agg_app_day (device_id, date, app, hs_chars, hs_triggers, hs_input_chars) SELECT device_id, date, app, SUM(COALESCE(net_saved_chars,0) + LENGTH(COALESCE(trigger,''))), COUNT(*), SUM(LENGTH(COALESCE(trigger,''))) FROM events_hotstring WHERE kind = 'fired' GROUP BY device_id, date, app ON CONFLICT(device_id, date, app) DO UPDATE SET hs_chars=hs_chars+excluded.hs_chars, hs_triggers=hs_triggers+excluded.hs_triggers, hs_input_chars=hs_input_chars+excluded.hs_input_chars;")
	; agg_app_day — hotstring suggestion count (denominator for the acceptance rate KPI).
	; fired / suggested are separate rows; we join them here rather than duplicating the
	; fired INSERT above so each kind gets a clean COUNT(*).
	try SQLite_Exec(db, "INSERT INTO agg_app_day (device_id, date, app, hs_suggested) SELECT device_id, date, app, COUNT(*) FROM events_hotstring WHERE kind = 'suggested' GROUP BY device_id, date, app ON CONFLICT(device_id, date, app) DO UPDATE SET hs_suggested=hs_suggested+excluded.hs_suggested;")

	; agg_app_day — app foreground time from events_app_switch.
	try SQLite_Exec(db, "INSERT INTO agg_app_day (device_id, date, app, app_time_ms) SELECT device_id, date, prev_app, SUM(COALESCE(duration_ms,0)) FROM events_app_switch WHERE prev_app IS NOT NULL AND prev_app != '' GROUP BY device_id, date, prev_app ON CONFLICT(device_id, date, app) DO UPDATE SET app_time_ms=app_time_ms+excluded.app_time_ms;")

	; agg_app_day_hourly — keystrokes per hour from events_typing. Uses the
	; same non-synthetic json_each keystroke count as `chars` above so the
	; per-hour totals reconcile with the daily chars figure (LENGTH(text)
	; would under-count and break that invariant). Only `c` is written here;
	; the per-hour error columns (e/em/es/e_buckets) stay walker-owned.
	try SQLite_Exec(db, "INSERT INTO agg_app_day_hourly (device_id, date, app, hour, c) SELECT device_id, date, app, substr(ts,12,2) AS hour, SUM((SELECT COUNT(*) FROM json_each(events_json) AS ev WHERE COALESCE(json_extract(ev.value,'$[2].s'),0)<>1)) FROM events_typing GROUP BY device_id, date, app, hour ON CONFLICT(device_id, date, app, hour) DO UPDATE SET c=c+excluded.c;")

	; agg_app_day_hourly_min5 — keystrokes per 5-min slot from events_typing
	; (same non-synthetic json_each count as the hourly rollup).
	try SQLite_Exec(db, "INSERT INTO agg_app_day_hourly_min5 (device_id, date, app, slot, c) SELECT device_id, date, app, substr(ts,12,2) || ':' || CASE WHEN (CAST(substr(ts,15,2) AS INTEGER)/5)*5 < 10 THEN '0' ELSE '' END || CAST((CAST(substr(ts,15,2) AS INTEGER)/5)*5 AS TEXT) AS slot, SUM((SELECT COUNT(*) FROM json_each(events_json) AS ev WHERE COALESCE(json_extract(ev.value,'$[2].s'),0)<>1)) FROM events_typing GROUP BY device_id, date, app, slot ON CONFLICT(device_id, date, app, slot) DO UPDATE SET c=c+excluded.c;")

	; agg_app_day_titles — window titles seen per app from events_window_switch.
	try SQLite_Exec(db, "INSERT INTO agg_app_day_titles (device_id, date, app, title, c) SELECT device_id, date, app, next_title, COUNT(*) FROM events_window_switch WHERE next_title IS NOT NULL AND next_title != '' GROUP BY device_id, date, app, next_title ON CONFLICT(device_id, date, app, title) DO UPDATE SET c=c+excluded.c;")

	; agg_app_day_switches_to — app switch destinations from events_app_switch.
	; The real schema columns are (app_from, app_to, count); the former
	; (app, switched_to, c) names did not exist, so this INSERT failed
	; silently and the table was left walker-only. Now SQL owns it all-time.
	try SQLite_Exec(db, "INSERT INTO agg_app_day_switches_to (device_id, date, app_from, app_to, count) SELECT device_id, date, prev_app, next_app, COUNT(*) FROM events_app_switch WHERE prev_app IS NOT NULL AND next_app IS NOT NULL GROUP BY device_id, date, prev_app, next_app ON CONFLICT(device_id, date, app_from, app_to) DO UPDATE SET count=count+excluded.count;")

	; agg_system_day — system events (wifi, lock, sleep) from events_system.
	try SQLite_Exec(db, "INSERT INTO agg_system_day (device_id, date, wifi_changes, locked_ms, sleep_ms, awake_ms) SELECT device_id, date, SUM(CASE WHEN action='wifi_change' THEN 1 ELSE 0 END), SUM(CASE WHEN action='lock' THEN CAST(json_extract(metadata_json,'$.duration_ms') AS INTEGER) ELSE 0 END), SUM(CASE WHEN action='sleep' THEN CAST(json_extract(metadata_json,'$.duration_ms') AS INTEGER) ELSE 0 END), SUM(CASE WHEN action='wake' THEN CAST(json_extract(metadata_json,'$.duration_ms') AS INTEGER) ELSE 0 END) FROM events_system GROUP BY device_id, date ON CONFLICT(device_id, date) DO UPDATE SET wifi_changes=wifi_changes+excluded.wifi_changes, locked_ms=locked_ms+excluded.locked_ms, sleep_ms=sleep_ms+excluded.sleep_ms, awake_ms=awake_ms+excluded.awake_ms;")
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





; ===============================================
; ======================================
; ======= 5/ Manifest projection =======
; ======================================
; ===============================================

; Build the legacy `manifest[date][app] = { chars, time, … }` Map.
; Mirrors sqlite_reader.lua read_manifest line-for-line but in AHK.
KLR_ReadManifest(db, start_date := "", end_date := "") {
    manifest := Map()
    if !db
        return manifest

    where := KLR_DateFilter(start_date, end_date)
    KLR__SumAppDay(db, manifest, where)
    KLR__SumBuckets(db, manifest, where)
    KLR__SumBurst(db, manifest, where)
    KLR__SumSession(db, manifest, where)
    KLR__SumCharsClass(db, manifest, where)
    KLR__SumErrors(db, manifest, where)
    KLR__SumErgo(db, manifest, where)
    KLR__SumLayouts(db, manifest, where)
    KLR__SumKcHold(db, manifest, where)
    KLR__SumTitles(db, manifest, where)
    KLR__SumHourly(db, manifest, where)
    KLR__SumHourlyMin5(db, manifest, where)
    return manifest
}

KLR_DateFilter(start_date, end_date) {
    clauses := []
    if (start_date != "")
        clauses.Push("date >= " . SQLite_Q(start_date))
    if (end_date != "")
        clauses.Push("date <= " . SQLite_Q(end_date))
    if (clauses.Length = 0)
        return ""
    out := " WHERE "
    for i, c in clauses
        out .= (i = 1 ? "" : " AND ") . c
    return out
}

KLR_NewAppEntry() {
    return Map(
        "chars", 0, "pauses", 0, "time", 0, "think_time", 0,
        "hs_chars", 0, "llm_chars", 0,
        "hs_triggers", 0, "llm_triggers", 0,
        "hs_suggested", 0, "llm_suggested", 0,
        "hs_input_chars", 0, "llm_input_chars", 0,
        "app_time_ms", 0, "category", "",
        "burst_count_total", 0, "burst_max_cpm", 0, "burst_max_chars", 0,
        "burst_length_buckets", Map(),
        "burst_inter_delay_count", 0, "burst_inter_delay_sum", 0, "burst_inter_delay_sumsq", 0,
        "session_count_total", 0, "session_longest_ms", 0, "session_longest_chars", 0,
        "session_total_active_ms", 0, "session_durations", [],
        "bs_total", 0, "cascade_count_total", 0, "cascade_max_len", 0,
        "recovery_time_sum_ms", 0, "recovery_time_count", 0,
        "same_finger_streak_max", 0, "same_hand_streak_max", 0, "auto_repeat_count", 0,
        "char_letter", 0, "char_digit", 0, "char_punct", 0,
        "char_space", 0, "char_other", 0,
        "first_typed_min", "", "last_typed_min", "",
        "layouts_seen", Map(), "kc_hold", Map(), "win_titles", Map(),
        "hourly", Map(), "hourly_min5", Map(),
        "time_buckets", Map(), "credited_buckets", Map(),
        "hs_input_time_buckets", Map(), "hs_input_credited_buckets", Map(),
        "llm_input_time_buckets", Map(), "llm_input_credited_buckets", Map()
    )
}

KLR_GetCell(manifest, date_str, app) {
    if !manifest.Has(date_str)
        manifest[date_str] := Map()
    d := manifest[date_str]
    if !d.Has(app)
        d[app] := KLR_NewAppEntry()
    return d[app]
}

KLR__SumAppDay(db, manifest, where) {
    sql := "SELECT date, app,"
        . " SUM(chars) AS chars, SUM(pauses) AS pauses,"
        . " SUM(time_ms) AS time_ms, SUM(think_time_ms) AS think_time_ms,"
        . " SUM(hs_chars) AS hs_chars, SUM(llm_chars) AS llm_chars,"
        . " SUM(hs_triggers) AS hs_triggers, SUM(llm_triggers) AS llm_triggers,"
        . " SUM(hs_suggested) AS hs_suggested, SUM(llm_suggested) AS llm_suggested,"
        . " SUM(hs_input_chars) AS hs_input_chars, SUM(llm_input_chars) AS llm_input_chars,"
        . " SUM(app_time_ms) AS app_time_ms, MAX(category) AS category"
        . " FROM agg_app_day" . where . " GROUP BY date, app"
    for r in SQLite_Query(db, sql) {
        a := KLR_GetCell(manifest, r["date"], r["app"])
        a["chars"] := r["chars"]
        a["pauses"] := r["pauses"]
        a["time"] := r["time_ms"]
        a["think_time"] := r["think_time_ms"]
        a["hs_chars"] := r["hs_chars"]
        a["llm_chars"] := r["llm_chars"]
        a["hs_triggers"] := r["hs_triggers"]
        a["llm_triggers"] := r["llm_triggers"]
        a["hs_suggested"] := r["hs_suggested"]
        a["llm_suggested"] := r["llm_suggested"]
        a["hs_input_chars"] := r["hs_input_chars"]
        a["llm_input_chars"] := r["llm_input_chars"]
        a["app_time_ms"] := r["app_time_ms"]
        a["category"] := r["category"]
    }
}

KLR__SumBuckets(db, manifest, where) {
    sql := "SELECT date, app, bucket_ms,"
        . " SUM(time_sum) AS time_sum, SUM(credited) AS credited,"
        . " SUM(hs_input_time_sum) AS hs_in_t, SUM(hs_input_credited) AS hs_in_c,"
        . " SUM(llm_input_time_sum) AS llm_in_t, SUM(llm_input_credited) AS llm_in_c"
        . " FROM agg_app_day_buckets" . where . " GROUP BY date, app, bucket_ms"
    for r in SQLite_Query(db, sql) {
        a := KLR_GetCell(manifest, r["date"], r["app"])
        k := String(r["bucket_ms"])
        KLR_BumpMap(a["time_buckets"], k, r["time_sum"])
        KLR_BumpMap(a["credited_buckets"], k, r["credited"])
        KLR_BumpMap(a["hs_input_time_buckets"], k, r["hs_in_t"])
        KLR_BumpMap(a["hs_input_credited_buckets"], k, r["hs_in_c"])
        KLR_BumpMap(a["llm_input_time_buckets"], k, r["llm_in_t"])
        KLR_BumpMap(a["llm_input_credited_buckets"], k, r["llm_in_c"])
    }
}

KLR_BumpMap(m, k, delta) {
    if (delta = "" || !IsNumber(delta))
        delta := 0
    if m.Has(k)
        m[k] := m[k] + delta
    else
        m[k] := delta
}

KLR__SumBurst(db, manifest, where) {
    sql := "SELECT date, app,"
        . " SUM(count_total) AS count_total, MAX(max_cpm) AS max_cpm, MAX(max_chars) AS max_chars,"
        . " SUM(inter_delay_count) AS inter_count, SUM(inter_delay_sum) AS inter_sum,"
        . " SUM(inter_delay_sumsq) AS inter_sumsq, MIN(length_buckets_json) AS length_buckets_json"
        . " FROM agg_app_day_burst" . where . " GROUP BY date, app"
    for r in SQLite_Query(db, sql) {
        a := KLR_GetCell(manifest, r["date"], r["app"])
        a["burst_count_total"] := r["count_total"]
        a["burst_max_cpm"] := r["max_cpm"]
        a["burst_max_chars"] := r["max_chars"]
        a["burst_inter_delay_count"] := r["inter_count"]
        a["burst_inter_delay_sum"] := r["inter_sum"]
        a["burst_inter_delay_sumsq"] := r["inter_sumsq"]
        ; Lossy passthrough — the JSON sub-blob is opaque to AHK; emit it
        ; back as a raw JSON-string field so JS can JSON.parse() if needed.
        a["burst_length_buckets_json"] := r["length_buckets_json"]
    }
}

KLR__SumSession(db, manifest, where) {
    sql := "SELECT date, app, count_total, longest_ms, longest_chars, total_active_ms, durations_json"
        . " FROM agg_app_day_session" . where
    for r in SQLite_Query(db, sql) {
        a := KLR_GetCell(manifest, r["date"], r["app"])
        a["session_count_total"] := a["session_count_total"] + (r["count_total"] = "" ? 0 : r["count_total"])
        if (IsNumber(r["longest_ms"]) && r["longest_ms"] > a["session_longest_ms"])
            a["session_longest_ms"] := r["longest_ms"]
        if (IsNumber(r["longest_chars"]) && r["longest_chars"] > a["session_longest_chars"])
            a["session_longest_chars"] := r["longest_chars"]
        a["session_total_active_ms"] := a["session_total_active_ms"] + (r["total_active_ms"] = "" ? 0 : r[
            "total_active_ms"])
        a["session_durations_json"] := r["durations_json"]
    }
}

KLR__SumCharsClass(db, manifest, where) {
    sql := "SELECT date, app,"
        . " SUM(letter) AS letter, SUM(digit) AS digit, SUM(punct) AS punct,"
        . " SUM(space) AS space, SUM(other) AS other,"
        . " MIN(first_typed_min) AS first_min, MAX(last_typed_min) AS last_min"
        . " FROM agg_app_day_chars_class" . where . " GROUP BY date, app"
    for r in SQLite_Query(db, sql) {
        a := KLR_GetCell(manifest, r["date"], r["app"])
        a["char_letter"] := r["letter"]
        a["char_digit"] := r["digit"]
        a["char_punct"] := r["punct"]
        a["char_space"] := r["space"]
        a["char_other"] := r["other"]
        a["first_typed_min"] := r["first_min"]
        a["last_typed_min"] := r["last_min"]
    }
}

KLR__SumErrors(db, manifest, where) {
    sql := "SELECT date, app,"
        . " SUM(bs_total) AS bs_total, SUM(cascade_count) AS cascade_count,"
        . " MAX(cascade_max_len) AS cascade_max_len, SUM(recovery_sum_ms) AS recovery_sum,"
        . " SUM(recovery_count) AS recovery_count"
        . " FROM agg_app_day_errors" . where . " GROUP BY date, app"
    for r in SQLite_Query(db, sql) {
        a := KLR_GetCell(manifest, r["date"], r["app"])
        a["bs_total"] := r["bs_total"]
        a["cascade_count_total"] := r["cascade_count"]
        a["cascade_max_len"] := r["cascade_max_len"]
        a["recovery_time_sum_ms"] := r["recovery_sum"]
        a["recovery_time_count"] := r["recovery_count"]
    }
}

KLR__SumErgo(db, manifest, where) {
    sql := "SELECT date, app,"
        . " MAX(same_finger_streak_max) AS f_max,"
        . " MAX(same_hand_streak_max) AS h_max,"
        . " SUM(auto_repeat_count) AS ar_count"
        . " FROM agg_app_day_ergo" . where . " GROUP BY date, app"
    for r in SQLite_Query(db, sql) {
        a := KLR_GetCell(manifest, r["date"], r["app"])
        a["same_finger_streak_max"] := r["f_max"]
        a["same_hand_streak_max"] := r["h_max"]
        a["auto_repeat_count"] := r["ar_count"]
    }
}

KLR__SumLayouts(db, manifest, where) {
    sql := "SELECT date, app, layout, SUM(count) AS count"
        . " FROM agg_app_day_layouts" . where . " GROUP BY date, app, layout"
    for r in SQLite_Query(db, sql) {
        a := KLR_GetCell(manifest, r["date"], r["app"])
        KLR_BumpMap(a["layouts_seen"], r["layout"], r["count"])
    }
}

KLR__SumKcHold(db, manifest, where) {
    sql := "SELECT date, app, keycode,"
        . " SUM(sum_ms) AS s, SUM(count) AS c, MAX(max_ms) AS mx,"
        . " SUM(tap_count) AS t, SUM(hold_count) AS h"
        . " FROM agg_app_day_kc_hold" . where . " GROUP BY date, app, keycode"
    for r in SQLite_Query(db, sql) {
        a := KLR_GetCell(manifest, r["date"], r["app"])
        a["kc_hold"][String(r["keycode"])] := Map(
            "sum", r["s"],
            "count", r["c"],
            "max", r["mx"],
            "tap", r["t"],
            "hold", r["h"]
        )
    }
}

KLR__SumTitles(db, manifest, where) {
    sql := "SELECT date, app, title, SUM(c) AS c, SUM(ms) AS ms"
        . " FROM agg_app_day_titles" . where . " GROUP BY date, app, title"
    for r in SQLite_Query(db, sql) {
        a := KLR_GetCell(manifest, r["date"], r["app"])
        a["win_titles"][r["title"]] := Map("c", r["c"], "ms", r["ms"])
    }
}

KLR__SumHourly(db, manifest, where) {
    sql := "SELECT date, app, hour,"
        . " SUM(c) AS c, SUM(e) AS e, SUM(em) AS em, SUM(es) AS es,"
        . " MIN(e_buckets_json) AS e_buckets_json"
        . " FROM agg_app_day_hourly" . where . " GROUP BY date, app, hour"
    for r in SQLite_Query(db, sql) {
        a := KLR_GetCell(manifest, r["date"], r["app"])
        a["hourly"][r["hour"]] := Map(
            "c", r["c"],
            "e", r["e"],
            "em", r["em"],
            "es", r["es"],
            "e_buckets_json", r["e_buckets_json"]
        )
    }
}

KLR__SumHourlyMin5(db, manifest, where) {
    sql := "SELECT date, app, slot,"
        . " SUM(c) AS c, SUM(e) AS e, SUM(es) AS es,"
        . " MIN(e_buckets_json) AS e_buckets_json"
        . " FROM agg_app_day_hourly_min5" . where . " GROUP BY date, app, slot"
    for r in SQLite_Query(db, sql) {
        a := KLR_GetCell(manifest, r["date"], r["app"])
        a["hourly_min5"][r["slot"]] := Map(
            "c", r["c"],
            "e", r["e"],
            "es", r["es"],
            "e_buckets_json", r["e_buckets_json"]
        )
    }
}





; =====================================
; ====================================
; ======= 5/ N-gram projection =======
; ====================================
; =====================================

global KLR_NGRAM_TYPE_TABLE := Map(
    "c", "ngram_chars",
    "bg", "ngram_bigrams",
    "tg", "ngram_trigrams",
    "qg", "ngram_quadgrams",
    "pg", "ngram_pentagrams",
    "hx", "ngram_hexagrams",
    "hp", "ngram_heptagrams",
    "w", "ngram_words",
    "w_bg", "ngram_word_bigrams"
)

; Subset of n-gram tables fetched on the fast 500 ms 'live' path. The
; deeper tables (penta/hexa/hepta) explode in unique-token count and
; are rarely viewed, so we skip them on the hot path; the slower 'full'
; cadence (first paint) still fetches everything.
global KLR_NGRAM_LIVE_TABLE := Map(
    "c", "ngram_chars",
    "bg", "ngram_bigrams",
    "tg", "ngram_trigrams",
    "qg", "ngram_quadgrams",
    "w", "ngram_words",
    "w_bg", "ngram_word_bigrams"
)

KLR_BuildNgramFilter(start_date, end_date, selected_apps) {
    clauses := []
    if (start_date != "")
        clauses.Push("date >= " . SQLite_Q(start_date))
    if (end_date != "")
        clauses.Push("date <= " . SQLite_Q(end_date))
    if (selected_apps is Array && selected_apps.Length > 0) {
        quoted := []
        for _, a in selected_apps
            quoted.Push(SQLite_Q(a))
        clause := "app IN ("
        for i, q in quoted
            clause .= (i = 1 ? "" : ",") . q
        clause .= ")"
        clauses.Push(clause)
    }
    if (clauses.Length = 0)
        return ""
    out := " WHERE "
    for i, c in clauses
        out .= (i = 1 ? "" : " AND ") . c
    return out
}

KLR_NewNgramItem(c, t, e, esrc_json) {
    item := Map("c", c, "t", t, "e", e, "hs", 0, "llm", 0, "o", 0)
    ; esrc_json is a small fixed-shape JSON object {"hotstring":N,"llm":N,
    ; "none":N}. The dashboard reads item.hs / item.llm / item.o directly
    ; (and derives manual = c - hs - llm - o); it NEVER parses esrc_json.
    ; So decode the synthetic source counts here with a cheap regex — a
    ; full JSON parser is overkill for this shape — mirroring the macOS
    ; sqlite_reader.lua read_ngrams path. Without this the per-n-gram
    ; hotstring/LLM colouring is silently lost (every token reads hs=llm=0).
    if (esrc_json != "" && esrc_json != "{}") {
        if RegExMatch(esrc_json, '"hotstring"\s*:\s*(\d+)', &m_hs)
            item["hs"] := Integer(m_hs[1])
        if RegExMatch(esrc_json, '"llm"\s*:\s*(\d+)', &m_llm)
            item["llm"] := Integer(m_llm[1])
        item["esrc_json"] := esrc_json
    }
    return item
}

KLR_ReadNgrams(db, start_date := "", end_date := "", selected_apps := unset) {
    if !IsSet(selected_apps)
        selected_apps := []
    out := Map(
        "c", Map(),
        "bg", Map(),
        "tg", Map(),
        "qg", Map(),
        "pg", Map(),
        "hx", Map(),
        "hp", Map(),
        "w", Map(),
        "sc", Map(),
        "sc_bg", Map(),
        "w_bg", Map(),
        "kc", Map(),
        "sc_kb", Map()
    )
    if !db
        return out

    where := KLR_BuildNgramFilter(start_date, end_date, selected_apps)

    for code, tbl in KLR_NGRAM_TYPE_TABLE {
        sql := "SELECT token,"
            . " SUM(c) AS c, SUM(td) AS t, SUM(e) AS e,"
            . " MIN(esrc_json) AS esrc_json"
            . " FROM " . tbl . where . " GROUP BY token"
            . " LIMIT " . KLReadConst.MAX_NGRAM_ROWS
        for r in SQLite_Query(db, sql)
            out[code][r["token"]] := KLR_NewNgramItem(r["c"], r["t"], r["e"], r["esrc_json"])
    }

    sc_sql := "SELECT token, SUM(c) AS c FROM ngram_shortcuts" . where . " GROUP BY token"
    for r in SQLite_Query(db, sc_sql)
        out["sc"][r["token"]] := KLR_NewNgramItem(r["c"], 0, 0, "")

    scbg_sql := "SELECT token, SUM(c) AS c FROM ngram_shortcut_bigrams" . where . " GROUP BY token"
    for r in SQLite_Query(db, scbg_sql)
        out["sc_bg"][r["token"]] := KLR_NewNgramItem(r["c"], 0, 0, "")

    kc_sql := "SELECT keycode, SUM(c) AS c FROM ngram_keycodes" . where . " GROUP BY keycode"
    for r in SQLite_Query(db, kc_sql)
        out["kc"][String(r["keycode"])] := KLR_NewNgramItem(r["c"], 0, 0, "")

    return out
}

; Fast path used by the 500 ms live update tick. Returns the same
; { historical, today } shape KLR_ReadRangeSplitToday produces, but:
;   - historical is empty (cached client-side from the first paint).
;   - today fetches only the most-frequent KLR_FAST_LIMIT tokens per
;     table, skipping pentagrams/hexagrams/heptagrams entirely.
; Result: a few hundred Map allocations instead of tens of thousands,
; which keeps the per-tick cost well under 500 ms even on big DBs.
KLR_FAST_LIMIT := 500

; SQL-side JSON projection. Builds the entire today_idx JSON string
; directly via SQLite's json_group_object / json_object aggregations.
; Iterating thousands of n-gram rows in AHK + per-row Map allocation
; was making the live tick take ~1 s; this version pushes the work
; into SQLite which produces the final JSON in well under 100 ms.
;
; Returns a string fragment ready to splice into prefetch JSON:
;   {"app1": {"c": {…}, "bg": {…}, …}, "app2": {…}, …}
KLR_BuildTodayIdxJson(db, selected_apps := unset) {
    if !IsSet(selected_apps)
        selected_apps := []
    if !db
        return "{}"
    today := FormatTime(A_Now, "yyyy-MM-dd")

    app_clause := ""
    if (selected_apps is Array && selected_apps.Length > 0) {
        quoted := []
        for _, a in selected_apps
            quoted.Push(SQLite_Q(a))
        app_clause := " AND app IN ("
        for i, q in quoted
            app_clause .= (i = 1 ? "" : ",") . q
        app_clause .= ")"
    }

    ; Per-(app, type) aggregations. Each row maps a single app to a
    ; JSON object of all its tokens for that ngram type. We accumulate
    ; into a per-app dict here, then assemble the outer JSON.
    per_app := Map()

    ; Generic n-gram types (chars / bigrams / trigrams / quadgrams /
    ; words / word_bigrams). 6 SELECT queries; each returns 1 row per
    ; app in O(rows-aggregated) on the SQLite side.
    for code, tbl in KLR_NGRAM_LIVE_TABLE {
        sql := "SELECT app, json_group_object(token, json_object("
            . "'c', c, 't', t, 'e', e, 'hs', 0, 'llm', 0, 'o', 0)) AS j"
            . " FROM (SELECT app, token,"
            . "        SUM(c) AS c, SUM(td) AS t, SUM(e) AS e"
            . "        FROM " . tbl
            . "        WHERE date = " . SQLite_Q(today) . app_clause
            . "        GROUP BY app, token)"
            . " GROUP BY app"
        for r in SQLite_Query(db, sql)
            KLR__StashAppTypeJson(per_app, r["app"], code, r["j"])
    }

    ; Keycode heatmap (macOS / virtual keycode side).
    kc_sql := "SELECT app, json_group_object(CAST(keycode AS TEXT), json_object("
        . "'c', c, 't', 0, 'e', 0, 'hs', 0, 'llm', 0, 'o', 0)) AS j"
        . " FROM (SELECT app, keycode, SUM(c) AS c FROM ngram_keycodes"
        . "        WHERE date = " . SQLite_Q(today) . app_clause
        . "        GROUP BY app, keycode)"
        . " GROUP BY app"
    for r in SQLite_Query(db, kc_sql)
        KLR__StashAppTypeJson(per_app, r["app"], "kc", r["j"])

    ; Scancode heatmap (Windows / hardware scancode side).
    sc_kb_sql := "SELECT app, json_group_object(CAST(scancode AS TEXT), json_object("
        . "'c', c, 't', 0, 'e', 0, 'hs', 0, 'llm', 0, 'o', 0)) AS j"
        . " FROM (SELECT app, scancode, SUM(c) AS c FROM ngram_scancodes"
        . "        WHERE date = " . SQLite_Q(today) . app_clause
        . "        GROUP BY app, scancode)"
        . " GROUP BY app"
    for r in SQLite_Query(db, sc_kb_sql)
        KLR__StashAppTypeJson(per_app, r["app"], "sc_kb", r["j"])

    ; Shortcuts + shortcut bigrams.
    sc_sql := "SELECT app, json_group_object(token, json_object("
        . "'c', c, 't', 0, 'e', 0, 'hs', 0, 'llm', 0, 'o', 0)) AS j"
        . " FROM (SELECT app, token, SUM(c) AS c FROM ngram_shortcuts"
        . "        WHERE date = " . SQLite_Q(today) . app_clause
        . "        GROUP BY app, token)"
        . " GROUP BY app"
    for r in SQLite_Query(db, sc_sql)
        KLR__StashAppTypeJson(per_app, r["app"], "sc", r["j"])

    scbg_sql := "SELECT app, json_group_object(token, json_object("
        . "'c', c, 't', 0, 'e', 0, 'hs', 0, 'llm', 0, 'o', 0)) AS j"
        . " FROM (SELECT app, token, SUM(c) AS c FROM ngram_shortcut_bigrams"
        . "        WHERE date = " . SQLite_Q(today) . app_clause
        . "        GROUP BY app, token)"
        . " GROUP BY app"
    for r in SQLite_Query(db, scbg_sql)
        KLR__StashAppTypeJson(per_app, r["app"], "sc_bg", r["j"])

    ; Stitch the per-app dict into one outer JSON object. We trust the
    ; per-type fragments coming from json_group_object are valid JSON
    ; objects already.
    if (per_app.Count = 0)
        return "{}"
    parts := []
    empty := '{}'
    for app, types in per_app {
        ; A complete bucket has all 11 type slots so the JS side can
        ; always read out[code][token] without a defensive check.
        type_parts := []
        for code in ["c", "bg", "tg", "qg", "pg", "hx", "hp", "w", "sc", "sc_bg", "w_bg", "kc", "sc_kb"] {
            j := types.Has(code) ? types[code] : empty
            type_parts.Push('"' . code . '":' . (j != "" ? j : empty))
        }
        joined := ""
        for i, tp in type_parts
            joined .= (i = 1 ? "" : ",") . tp
        parts.Push('"' . KLR__JsonEscape(app) . '":{' . joined . '}')
    }
    out := "{"
    for i, p in parts
        out .= (i = 1 ? "" : ",") . p
    out .= "}"
    return out
}

KLR__StashAppTypeJson(per_app, app, code, j) {
    if (j = "")
        return
    if !per_app.Has(app)
        per_app[app] := Map()
    per_app[app][code] := j
}

KLR__JsonEscape(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    return s
}

KLR_ReadRangeSplitTodayFast(db, selected_apps := unset) {
    if !IsSet(selected_apps)
        selected_apps := []
    today := FormatTime(A_Now, "yyyy-MM-dd")
    today_idx := Map()
    if !db
        return Map("historical", Map(), "today", today_idx)

    app_clause := ""
    if (selected_apps is Array && selected_apps.Length > 0) {
        quoted := []
        for _, a in selected_apps
            quoted.Push(SQLite_Q(a))
        app_clause := " AND app IN ("
        for i, q in quoted
            app_clause .= (i = 1 ? "" : ",") . q
        app_clause .= ")"
    }

    for code, tbl in KLR_NGRAM_LIVE_TABLE {
        sql := "SELECT app, token,"
            . " SUM(c) AS c, SUM(td) AS t, SUM(e) AS e,"
            . " MIN(esrc_json) AS esrc_json"
            . " FROM " . tbl
            . " WHERE date = " . SQLite_Q(today) . app_clause
            . " GROUP BY app, token"
            . " ORDER BY c DESC"
            . " LIMIT " . KLR_FAST_LIMIT
        for r in SQLite_Query(db, sql) {
            app := r["app"]
            if !today_idx.Has(app)
                today_idx[app] := KLR_NewTodayBucket()
            today_idx[app][code][r["token"]] := KLR_NewNgramItem(r["c"], r["t"], r["e"], r["esrc_json"])
        }
    }

    ; Keycode heatmap data (ngram_keycodes). The dashboard renders a
    ; per-keyboard-key colour map from this table; the user expects it
    ; to track typing live.
    kc_sql := "SELECT app, keycode, SUM(c) AS c FROM ngram_keycodes"
        . " WHERE date = " . SQLite_Q(today) . app_clause
        . " GROUP BY app, keycode"
    for r in SQLite_Query(db, kc_sql) {
        app := r["app"]
        if !today_idx.Has(app)
            today_idx[app] := KLR_NewTodayBucket()
        today_idx[app]["kc"][String(r["keycode"])] := KLR_NewNgramItem(r["c"], 0, 0, "")
    }

    ; Scancode heatmap data (ngram_scancodes) — Windows side.
    sc_kb_sql := "SELECT app, scancode, SUM(c) AS c FROM ngram_scancodes"
        . " WHERE date = " . SQLite_Q(today) . app_clause
        . " GROUP BY app, scancode"
    for r in SQLite_Query(db, sc_kb_sql) {
        app := r["app"]
        if !today_idx.Has(app)
            today_idx[app] := KLR_NewTodayBucket()
        today_idx[app]["sc_kb"][String(r["scancode"])] := KLR_NewNgramItem(r["c"], 0, 0, "")
    }

    ; Shortcuts (sc) and shortcut bigrams — also commonly viewed tabs.
    sc_sql := "SELECT app, token, SUM(c) AS c FROM ngram_shortcuts"
        . " WHERE date = " . SQLite_Q(today) . app_clause
        . " GROUP BY app, token"
    for r in SQLite_Query(db, sc_sql) {
        app := r["app"]
        if !today_idx.Has(app)
            today_idx[app] := KLR_NewTodayBucket()
        today_idx[app]["sc"][r["token"]] := KLR_NewNgramItem(r["c"], 0, 0, "")
    }
    scbg_sql := "SELECT app, token, SUM(c) AS c FROM ngram_shortcut_bigrams"
        . " WHERE date = " . SQLite_Q(today) . app_clause
        . " GROUP BY app, token"
    for r in SQLite_Query(db, scbg_sql) {
        app := r["app"]
        if !today_idx.Has(app)
            today_idx[app] := KLR_NewTodayBucket()
        today_idx[app]["sc_bg"][r["token"]] := KLR_NewNgramItem(r["c"], 0, 0, "")
    }
    return Map("historical", Map(), "today", today_idx)
}

KLR_ReadRangeSplitToday(db, start_date := "", end_date := "", selected_apps := unset) {
    if !IsSet(selected_apps)
        selected_apps := []
    today := FormatTime(A_Now, "yyyy-MM-dd")

    ; Historical: everything strictly before today.
    yesterday := KLR_PrevDay(today)
    ; AHK v2 throws « Expected a Number but got a String » when comparing
    ; two strings with `<`. Use StrCompare for the lexicographic test.
    hist_end := (end_date != "" && StrCompare(end_date, today) < 0) ? end_date : yesterday
    historical := KLR_ReadNgrams(db, start_date, hist_end, selected_apps)

    ; Today: per-app n-gram dict for each app touched today.
    today_idx := Map()
    if !db
        return Map("historical", historical, "today", today_idx)

    app_clause := ""
    if (selected_apps is Array && selected_apps.Length > 0) {
        quoted := []
        for _, a in selected_apps
            quoted.Push(SQLite_Q(a))
        app_clause := " AND app IN ("
        for i, q in quoted
            app_clause .= (i = 1 ? "" : ",") . q
        app_clause .= ")"
    }

    for code, tbl in KLR_NGRAM_TYPE_TABLE {
        sql := "SELECT app, token,"
            . " SUM(c) AS c, SUM(td) AS t, SUM(e) AS e,"
            . " MIN(esrc_json) AS esrc_json"
            . " FROM " . tbl
            . " WHERE date = " . SQLite_Q(today) . app_clause
            . " GROUP BY app, token"
            . " LIMIT " . KLReadConst.MAX_NGRAM_ROWS
        for r in SQLite_Query(db, sql) {
            app := r["app"]
            if !today_idx.Has(app)
                today_idx[app] := KLR_NewTodayBucket()
            today_idx[app][code][r["token"]] := KLR_NewNgramItem(r["c"], r["t"], r["e"], r["esrc_json"])
        }
    }

    return Map("historical", historical, "today", today_idx)
}

KLR_NewTodayBucket() {
    return Map(
        "c", Map(),
        "bg", Map(),
        "tg", Map(),
        "qg", Map(),
        "pg", Map(),
        "hx", Map(),
        "hp", Map(),
        "w", Map(),
        "sc", Map(),
        "sc_bg", Map(),
        "w_bg", Map(),
        "kc", Map(),
        "sc_kb", Map()
    )
}

KLR_PrevDay(yyyy_mm_dd) {
    ; Subtract one day from a YYYY-MM-DD string. AHK's DateAdd works on
    ; ``YYYYMMDDHH24MISS`` so we flatten and re-format.
    flat := SubStr(yyyy_mm_dd, 1, 4) . SubStr(yyyy_mm_dd, 6, 2) . SubStr(yyyy_mm_dd, 9, 2)
    flat := DateAdd(flat, -1, "Days")
    return SubStr(flat, 1, 4) . "-" . SubStr(flat, 5, 2) . "-" . SubStr(flat, 7, 2)
}




