; modules/keylogger/keylogger_reader_ngrams.ahk

; ==============================================================================
; MODULE: Keylogger Reader — N-gram projection
; DESCRIPTION:
; Projects the in-memory SQLite n-gram tables into the Map / JSON shapes
; consumed by the metrics_typing and metrics_apps webview frontends. Extracted
; from keylogger_reader.ahk so n-gram projection can be read and maintained
; independently from the database layer and the manifest projection.
;
; FEATURES & RATIONALE:
; 1. KLR_ReadNgrams: full historical n-gram read (all tables, all date range).
;    Used on first paint (slow but complete).
; 2. KLR_BuildTodayIdxJson: SQL-side JSON projection for today's n-grams.
;    Pushes json_group_object aggregation into SQLite, avoiding thousands of
;    per-row AHK Map allocations on the hot 500 ms live-tick path.
; 3. KLR_ReadRangeSplitTodayFast: lightweight 500 ms live-tick path — skips
;    heavy tables (penta/hexa/hepta) and caps each table at KLR_FAST_LIMIT rows.
; 4. KLR_ReadRangeSplitToday: full first-paint path that splits the result into
;    { historical (before today), today (per-app bucket) }.
; ==============================================================================





; =====================================
; ====================================
; ======= 1/ N-gram projection =======
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

    ; The scancode heatmap, mirroring the keycode projection above. The walker
    ; WRITES ngram_scancodes and the live 500 ms path fills today, so the
    ; dashboard looked populated — while this reader declared the "sc_kb" slot,
    ; returned it empty, and left every historical and range scancode heatmap
    ; blank. The macOS twin keys its heatmap on "kc", which IS read, so no amount
    ; of cross-driver testing could surface a gap that exists only here.
    sc_kb_sql := "SELECT scancode, SUM(c) AS c FROM ngram_scancodes" . where . " GROUP BY scancode"
    for r in SQLite_Query(db, sc_kb_sql)
        out["sc_kb"][String(r["scancode"])] := KLR_NewNgramItem(r["c"], 0, 0, "")

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
;   {"app1": {"c": {...}, "bg": {...}, ...}, "app2": {...}, ...}
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

    KLR__FillTodayAuxTables(db, today, app_clause, today_idx)
    return Map("historical", Map(), "today", today_idx)
}

; Fill the four today slots that KLR_NGRAM_TYPE_TABLE does not cover — kc
; (keycode heatmap), sc_kb (scancode heatmap), sc (shortcuts) and sc_bg
; (shortcut bigrams) — into ``today_idx``, creating each per-app bucket on
; demand.
;
; One owner for the three today projections. KLR_NewTodayBucket declares
; thirteen slots while KLR_NGRAM_TYPE_TABLE names only nine, so every projection
; has to add these four explicitly. KLR_ReadRangeSplitTodayFast and
; KLR_BuildTodayIdxJson did; KLR_ReadRangeSplitToday — the full first-paint AND
; user-range path — did not, and returned them as well-formed EMPTY maps. A
; declared-but-unfed slot is worse than a missing one: every downstream merge is
; a valid no-op, so a custom date range that includes today rendered the
; Shortcuts tab and today's share of the keyboard heatmap as nothing at all,
; with no log line and no exception. Copying the queries into the third caller
; would only have set up the next drift.
; @param db {Integer} Open SQLite handle.
; @param today {String} Today's date as "yyyy-MM-dd".
; @param app_clause {String} Pre-built " AND app IN (…)" filter, or "".
; @param today_idx {Map} Per-app bucket index, mutated in place.
KLR__FillTodayAuxTables(db, today, app_clause, today_idx) {
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

    ; KLR_NGRAM_TYPE_TABLE stops at the nine text n-gram tables; the shortcut,
    ; shortcut-bigram, keycode and scancode slots KLR_NewTodayBucket also
    ; declares are filled here, exactly as on the fast and live paths.
    KLR__FillTodayAuxTables(db, today, app_clause, today_idx)

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
