; modules/keylogger_reader.ahk

; ==============================================================================
; MODULE: Keylogger SQLite Reader (AHK)
; DESCRIPTION:
; Windows port of modules/keylogger/sqlite_reader.lua. Builds an in-memory
; SQLite database from `_shared/schema/schema.sql` + the device's
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
; ===================================
; ======= 1/ Constants =======
; ===================================
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
; ===================================
; ======= 2/ Schema loader =======
; ===================================
; ===================================

; Resolve the canonical schema.sql path. The shared schema lives at
; `<repo>/static/drivers/_shared/schema/schema.sql`; from
; `<repo>/static/drivers/autohotkey/` (A_ScriptDir) it sits at
; ``..\_shared\schema\schema.sql``.
KLR_ResolveSchemaPath() {
    base := A_ScriptDir . "\..\_shared\schema\schema.sql"
    Loop Files, base
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
; =========================================
; ======= 3/ Database materialise =======
; =========================================
; =========================================

; Build a fresh in-memory SQLite from the union of every device's
; data.sql under the metrics directory. Returns a handle the caller
; closes via SQLite_Close when done.
KLR_BuildDatabase(metrics_dir) {
    md := metrics_dir
    if !RegExMatch(md, "[\\/]$")
        md .= "\"
    global _ConfigDir
    log := _ConfigDir . "logs\prefetch.log"
    try FileAppend("[" . A_Now . "] KLR PtrSize=" . A_PtrSize . " DLL=" . SQLiteConst.DLL . "`r`n", log, "UTF-8")
    try FileAppend("[" . A_Now . "] KLR DLL exists=" . (FileExist(SQLiteConst.DLL) ? "yes" : "NO!") . "`r`n", log, "UTF-8")
    ; Explicit LoadLibrary so we know whether the DLL even maps into the
    ; process. A nullptr from LoadLibrary means a dependency is missing
    ; or the binary is malformed. AHK's DllCall hits LoadLibrary too,
    ; but it does so silently and a load failure on some hosts comes
    ; back as a hard process crash rather than an exception.
    hmod := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
    try FileAppend("[" . A_Now . "] LoadLibrary returned hmod=" . hmod . "`r`n", log, "UTF-8")
    if !hmod {
        gle := DllCall("kernel32\GetLastError", "UInt")
        try FileAppend("[" . A_Now . "] LoadLibrary FAILED, GetLastError=" . gle . "`r`n", log, "UTF-8")
        return 0
    }
    proc := DllCall("kernel32\GetProcAddress", "Ptr", hmod, "AStr", "sqlite3_libversion", "Ptr")
    try FileAppend("[" . A_Now . "] GetProcAddress(libversion)=" . proc . "`r`n", log, "UTF-8")
    if !proc {
        try FileAppend("[" . A_Now . "] symbol not found — wrong DLL?`r`n", log, "UTF-8")
        return 0
    }
    try {
        ver_ptr := DllCall(proc, "Ptr")
        ver := ver_ptr ? StrGet(ver_ptr, "UTF-8") : "(null)"
        FileAppend("[" . A_Now . "] pre-open libversion=" . ver . "`r`n", log, "UTF-8")
    } catch as err {
        FileAppend("[" . A_Now . "] pre-open libversion FAILED: " . err.Message . "`r`n", log, "UTF-8")
        return 0
    }
    try FileAppend("[" . A_Now . "] KLR opening :memory:`r`n", log, "UTF-8")
    db := SQLite_Open(":memory:")
    try FileAppend("[" . A_Now . "] KLR open returned db=" . db . "`r`n", log, "UTF-8")
    if !db
        return 0
    try FileAppend("[" . A_Now . "] KLR loading schema…`r`n", log, "UTF-8")
    if !KLR_LoadSchema(db) {
        try FileAppend("[" . A_Now . "] KLR schema load FAILED`r`n", log, "UTF-8")
        SQLite_Close(db)
        return 0
    }
    try FileAppend("[" . A_Now . "] KLR schema OK`r`n", log, "UTF-8")

    ; Fan out: every per-device folder under by_device/<uuid>/data.sql
    ; gets exec()-ed in. The schema's INSERT OR IGNORE / UPSERT clauses
    ; make this idempotent across overlapping device files.
    by_root := md . "by_device\"
    if !DirExist(by_root) {
        return db   ; empty but valid handle.
    }
    Loop Files, by_root . "*", "D" {
        sql_path := A_LoopFileFullPath . "\data.sql"
        if !FileExist(sql_path)
            continue
        sql := FileRead(sql_path, "UTF-8")
        if (sql = "")
            continue
        SQLite_Exec(db, sql)
    }
    return db
}




; ===============================================
; ===============================================
; ======= 4/ Manifest projection =======
; ===============================================
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
        "hs_input_chars", 0, "llm_input_chars", 0,
        "app_time", 0, "category", "",
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
        . " SUM(hs_input_chars) AS hs_input_chars, SUM(llm_input_chars) AS llm_input_chars,"
        . " SUM(app_time_ms) AS app_time, MAX(category) AS category"
        . " FROM agg_app_day" . where . " GROUP BY date, app"
    for r in SQLite_Query(db, sql) {
        a := KLR_GetCell(manifest, r["date"], r["app"])
        a["chars"]            := r["chars"]
        a["pauses"]           := r["pauses"]
        a["time"]             := r["time_ms"]
        a["think_time"]       := r["think_time_ms"]
        a["hs_chars"]         := r["hs_chars"]
        a["llm_chars"]        := r["llm_chars"]
        a["hs_triggers"]      := r["hs_triggers"]
        a["llm_triggers"]     := r["llm_triggers"]
        a["hs_input_chars"]   := r["hs_input_chars"]
        a["llm_input_chars"]  := r["llm_input_chars"]
        a["app_time"]         := r["app_time"]
        a["category"]         := r["category"]
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
        KLR_BumpMap(a["time_buckets"],               k, r["time_sum"])
        KLR_BumpMap(a["credited_buckets"],           k, r["credited"])
        KLR_BumpMap(a["hs_input_time_buckets"],      k, r["hs_in_t"])
        KLR_BumpMap(a["hs_input_credited_buckets"],  k, r["hs_in_c"])
        KLR_BumpMap(a["llm_input_time_buckets"],     k, r["llm_in_t"])
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
        a["burst_count_total"]       := r["count_total"]
        a["burst_max_cpm"]           := r["max_cpm"]
        a["burst_max_chars"]         := r["max_chars"]
        a["burst_inter_delay_count"] := r["inter_count"]
        a["burst_inter_delay_sum"]   := r["inter_sum"]
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
        a["session_count_total"]     := a["session_count_total"] + (r["count_total"] = "" ? 0 : r["count_total"])
        if (IsNumber(r["longest_ms"]) && r["longest_ms"] > a["session_longest_ms"])
            a["session_longest_ms"] := r["longest_ms"]
        if (IsNumber(r["longest_chars"]) && r["longest_chars"] > a["session_longest_chars"])
            a["session_longest_chars"] := r["longest_chars"]
        a["session_total_active_ms"] := a["session_total_active_ms"] + (r["total_active_ms"] = "" ? 0 : r["total_active_ms"])
        a["session_durations_json"]  := r["durations_json"]
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
        a["char_digit"]  := r["digit"]
        a["char_punct"]  := r["punct"]
        a["char_space"]  := r["space"]
        a["char_other"]  := r["other"]
        a["first_typed_min"] := r["first_min"]
        a["last_typed_min"]  := r["last_min"]
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
        a["bs_total"]              := r["bs_total"]
        a["cascade_count_total"]   := r["cascade_count"]
        a["cascade_max_len"]       := r["cascade_max_len"]
        a["recovery_time_sum_ms"]  := r["recovery_sum"]
        a["recovery_time_count"]   := r["recovery_count"]
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
        a["same_hand_streak_max"]   := r["h_max"]
        a["auto_repeat_count"]      := r["ar_count"]
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
            "sum",   r["s"],
            "count", r["c"],
            "max",   r["mx"],
            "tap",   r["t"],
            "hold",  r["h"]
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
            "c",  r["c"],
            "e",  r["e"],
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
            "c",  r["c"],
            "e",  r["e"],
            "es", r["es"],
            "e_buckets_json", r["e_buckets_json"]
        )
    }
}




; =====================================
; =====================================
; ======= 5/ N-gram projection =======
; =====================================
; =====================================

global KLR_NGRAM_TYPE_TABLE := Map(
    "c",     "ngram_chars",
    "bg",    "ngram_bigrams",
    "tg",    "ngram_trigrams",
    "qg",    "ngram_quadgrams",
    "pg",    "ngram_pentagrams",
    "hx",    "ngram_hexagrams",
    "hp",    "ngram_heptagrams",
    "w",     "ngram_words",
    "w_bg",  "ngram_word_bigrams"
)

KLR_BuildNgramFilter(start_date, end_date, selected_apps) {
    clauses := []
    if (start_date != "")
        clauses.Push("date >= " . SQLite_Q(start_date))
    if (end_date != "")
        clauses.Push("date <= " . SQLite_Q(end_date))
    if (selected_apps is Array && selected_apps.Length > 0) {
        quoted := []
        for a in selected_apps
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
    ; esrc_json is a JSON object {"hotstring":N, "llm":N, "none":N, …}.
    ; We do NOT decode it here (no JSON parser on AHK 64-bit) — the JS
    ; consumer parses the per-row source breakdown when it cares.
    if (esrc_json != "")
        item["esrc_json"] := esrc_json
    return item
}

KLR_ReadNgrams(db, start_date := "", end_date := "", selected_apps := unset) {
    if !IsSet(selected_apps)
        selected_apps := []
    out := Map(
        "c",     Map(),
        "bg",    Map(),
        "tg",    Map(),
        "qg",    Map(),
        "pg",    Map(),
        "hx",    Map(),
        "hp",    Map(),
        "w",     Map(),
        "sc",    Map(),
        "sc_bg", Map(),
        "w_bg",  Map(),
        "kc",    Map()
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

KLR_ReadRangeSplitToday(db, start_date := "", end_date := "", selected_apps := unset) {
    if !IsSet(selected_apps)
        selected_apps := []
    today := FormatTime(A_Now, "yyyy-MM-dd")

    ; Historical: everything strictly before today.
    yesterday := KLR_PrevDay(today)
    hist_end  := (end_date != "" && end_date < today) ? end_date : yesterday
    historical := KLR_ReadNgrams(db, start_date, hist_end, selected_apps)

    ; Today: per-app n-gram dict for each app touched today.
    today_idx := Map()
    if !db
        return Map("historical", historical, "today", today_idx)

    app_clause := ""
    if (selected_apps is Array && selected_apps.Length > 0) {
        quoted := []
        for a in selected_apps
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
        "c",     Map(),
        "bg",    Map(),
        "tg",    Map(),
        "qg",    Map(),
        "pg",    Map(),
        "hx",    Map(),
        "hp",    Map(),
        "w",     Map(),
        "sc",    Map(),
        "sc_bg", Map(),
        "w_bg",  Map(),
        "kc",    Map()
    )
}

KLR_PrevDay(yyyy_mm_dd) {
    ; Subtract one day from a YYYY-MM-DD string. AHK's DateAdd works on
    ; ``YYYYMMDDHH24MISS`` so we flatten and re-format.
    flat := SubStr(yyyy_mm_dd, 1, 4) . SubStr(yyyy_mm_dd, 6, 2) . SubStr(yyyy_mm_dd, 9, 2)
    flat := DateAdd(flat, -1, "Days")
    return SubStr(flat, 1, 4) . "-" . SubStr(flat, 5, 2) . "-" . SubStr(flat, 7, 2)
}
