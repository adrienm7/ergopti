; modules/keylogger/keylogger_reader_manifest.ahk

; ==============================================================================
; MODULE: Keylogger Reader — Manifest projection
; DESCRIPTION:
; Projects the in-memory SQLite aggregates into the legacy manifest Map shape
; consumed by the metrics_typing and metrics_apps webview frontends. Extracted
; from keylogger_reader.ahk so the manifest projection can be read and maintained
; independently from the database layer (keylogger_reader_db.ahk) and the n-gram
; projection (keylogger_reader_ngrams.ahk).
;
; FEATURES & RATIONALE:
; 1. KLR_ReadManifest: entry-point that fans out to every KLR__Sum* helper,
;    mirroring sqlite_reader.lua read_manifest line-for-line.
; 2. KLR_GetCell: lazily materialises the manifest[date][app] bucket on first
;    access, keyed by the canonical YYYY-MM-DD / app strings.
; 3. KLR_BumpMap: safe numeric accumulator (nil-tolerant) used for all per-key
;    sub-maps (time_buckets, layouts_seen, kc_hold, etc.).
; ==============================================================================





; ======================================
; ======================================
; ======= 1/ Manifest projection =======
; ======================================
; ======================================

; Build the legacy `manifest[date][app] = { chars, time, ... }` Map.
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
    KLR_AddLiveForegroundTime(manifest, start_date, end_date)
    return manifest
}

; Adds the foreground interval that has not yet ended in an app_switch event.
; Aggregates are persisted at focus changes, so without this projection-only
; addition a dashboard opened during a long uninterrupted task reports zero
; time for the current application until the user leaves it.
KLR_AddLiveForegroundTime(manifest, start_date := "", end_date := "") {
    if !(manifest is Map)
        return
    if (KLHook.prev_app = "" || KLHook.app_entered_at = 0)
        return
    now := A_TickCount
    elapsed := (now - KLHook.app_entered_at) & 0xFFFFFFFF
    if (elapsed <= 0)
        return
    ; A full abandoned session must not be rendered as foreground work.
    if (KLHook.last_tick > 0 && ((now - KLHook.last_tick) & 0xFFFFFFFF) >= KLWatchConst.SESSION_TIMEOUT_MS)
        return
    date_str := A_YYYY . "-" . A_MM . "-" . A_DD
    if (start_date != "" && date_str < start_date)
        return
    if (end_date != "" && date_str > end_date)
        return
    cell := KLR_GetCell(manifest, date_str, KLHook.prev_app)
    cell["app_time_ms"] += elapsed
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
