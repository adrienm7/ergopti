; modules/keylogger_walker.ahk

; ==============================================================================
; MODULE: Keylogger Aggregation Walker (AHK)
; DESCRIPTION:
; Stateful walker that mirrors the Lua `_walk_typing_entry` byte-for-byte.
; Replays the per-keystroke events captured into today.log and emits UPSERT
; statements into data.sql for every aggregate / n-gram table the dashboard
; reads from.
;
; FEATURES & RATIONALE:
; 1. Same on-disk shape as the Mac side. UPSERTs land in data.sql; the
;    launcher (or any peer Mac) applies them to db.sqlite. Cross-device
;    aggregation already groups by device_id so AHK rows naturally sum
;    with HS rows in the dashboard projection.
; 2. Stateful context (p1..p6, cur_word, current_burst, current_session,
;    ergo streaks, lookback ring) is keyed per-app and persists across
;    ingest ticks via state.json. Day rollover wipes the context — a
;    yesterday partial word / streak is meaningless at midnight.
; 3. Per-tick batch dicts accumulate UPSERT deltas; the walker flushes
;    them in a single block of statements appended to data.sql.
; 4. Replay-safe: every emitted UPSERT uses ON CONFLICT DO UPDATE with
;    additive semantics (chars=chars+excluded.chars). Re-applying after
;    a watermark reset is harmless and matches the Lua side exactly.
;
; SCOPE OF THIS PORT:
; All metrics computed by the Lua walker are reproduced here:
; - n-grams 1..7 + words / word_bigrams / shortcuts / sc_bigrams / keycodes
; - bursts (count, max_cpm, max_chars, length histogram, inter-key delay
;   variance) and sessions (count, longest_ms/chars, durations array).
; - error cascades + recovery time, ergonomic streaks (same-finger /
;   same-hand / auto-repeat), kc_hold (tap vs hold).
; - hourly + 5-min heatmaps with cumulative e_buckets.
; - layouts_seen, win_titles (cap 100), chars_class breakdown,
;   app_time, switches_to, agg_system_day.
;
; NB: The Windows finger map (KLW_VK_FINGER) is QWERTY-specific. Users on
; alternative layouts can override it before the walker runs; for now the
; same-finger/same-hand streaks will only be accurate on QWERTY.
; ==============================================================================

#Requires Autohotkey v2.0+





; ===================================
; ===================================
; ======= 1/ Constants =======
; ===================================
; ===================================

class KLWConst {
    static MAX_KEYSTROKE_DELAY_MS    := 5000
    static THINK_PAUSE_MS            := 2000
    static UI_PAUSE_BUCKETS_MS       := [1000, 2000, 3000, 5000, 10000, 20000, 30000, 60000]
    static TRIGGER_LOOKBACK_LEN      := 50
    static BURST_GAP_MS              := 1000
    static MIN_BURST_FOR_CPM         := 10
    static SESSION_GAP_MS            := 300000
    static BURST_LENGTH_BUCKETS      := [1, 5, 10, 20, 50, 100, 200, 500]
    static SESSION_DURATIONS_CAP     := 100
    static AUTO_REPEAT_MAX_DELAY_MS  := 50
    static CASCADE_MIN_BS            := 3
    static HOLD_THRESHOLD_MS         := 250
    static TITLE_CAP_PER_APP_DAY     := 100
}

; QWERTY VK → finger column. Modifiers + thumb keys absent on purpose so
; they cannot break a streak when interleaved. Override via KLW_VK_FINGER
; before KL_Init() if your layout differs.
global KLW_VK_FINGER := Map(
    0x41, "l_pinky", 0x53, "l_ring", 0x44, "l_mid", 0x46, "l_idx", 0x47, "l_idx",   ; A S D F G
    0x48, "r_idx",   0x4A, "r_idx",  0x4B, "r_mid", 0x4C, "r_ring", 0xBA, "r_pinky", ; H J K L ;
    0x51, "l_pinky", 0x57, "l_ring", 0x45, "l_mid", 0x52, "l_idx", 0x54, "l_idx",   ; Q W E R T
    0x59, "r_idx",   0x55, "r_idx",  0x49, "r_mid", 0x4F, "r_ring", 0x50, "r_pinky", ; Y U I O P
    0x5A, "l_pinky", 0x58, "l_ring", 0x43, "l_mid", 0x56, "l_idx", 0x42, "l_idx",   ; Z X C V B
    0x4E, "r_idx",   0x4D, "r_idx",  0xBC, "r_mid", 0xBE, "r_ring", 0xBF, "r_pinky"  ; N M , . /
)





; ===================================
; ===================================
; ======= 2/ Module state =======
; ===================================
; ===================================

class KLW {
    ; Per-app n-gram + burst + session walking context. Map(app => Map(...)).
    ; Persisted in state.json under "ngram_ctx" key.
    static ctx := Map()

    ; Per-tick batch dicts. Reset after KLW_BuildBatchSql() emits SQL.
    ; Initialised to an empty Map so accessing it before the first
    ; KLW_ResetBatch() does not throw — KLW_BuildBatchSql() short-circuits
    ; when no sub-key is present.
    static batch := Map()
}





; ===========================================
; ===========================================
; ======= 3/ Batch reset / accessors =======
; ===========================================
; ===========================================

KLW_ResetBatch() {
    KLW.batch := Map(
        "app_day",     Map(),
        "app_time",    Map(),
        "app_buckets", Map(),
        "ngram",       Map(
            "ngram_chars",        Map(),
            "ngram_bigrams",      Map(),
            "ngram_trigrams",     Map(),
            "ngram_quadgrams",    Map(),
            "ngram_pentagrams",   Map(),
            "ngram_hexagrams",    Map(),
            "ngram_heptagrams",   Map(),
            "ngram_words",        Map(),
            "ngram_word_bigrams", Map()
        ),
        "kc_ngram",    Map(),
        "sc_kb_ngram", Map(),
        "sc_ngram",    Map(
            "ngram_shortcuts",        Map(),
            "ngram_shortcut_bigrams", Map()
        ),
        "kc_hold",     Map(),
        "titles",      Map(),
        "hourly",      Map(),
        "hourly_min5", Map(),
        "layouts",     Map(),
        "chars_class", Map(),
        "errors",      Map(),
        "ergo",        Map(),
        "bursts",      Map(),
        "sessions",    Map(),
        "switches_to", Map(),
        "system_day",  Map()
    )
}

; Get-or-create a sub-map at tbl[k], returning the populated default.
KLW_GC(tbl, k, default_map) {
    if !tbl.Has(k)
        tbl[k] := default_map
    return tbl[k]
}





; =========================================
; =========================================
; ======= 4/ Helpers =======
; =========================================
; =========================================

KLW_BucketAdd(target_map, delay, value) {
    for t in KLWConst.UI_PAUSE_BUCKETS_MS {
        if (delay <= t) {
            k := String(t)
            target_map[k] := (target_map.Has(k) ? target_map[k] : 0) + value
        }
    }
}

KLW_BurstLengthBucket(n) {
    for b in KLWConst.BURST_LENGTH_BUCKETS {
        if (n <= b)
            return String(b)
    }
    return "500+"
}

; UTF-8-aware character classifier — mirrors the Lua _char_class.
KLW_CharClass(c) {
    if (c = "" || StrLen(c) = 0)
        return "other"
    if (c = " " || c = "`t" || c = "`n"
            || c = Chr(0xA0)         ; nbsp
            || c = Chr(0x202F))      ; narrow nbsp
        return "space"
    code := Ord(c)
    if (code >= 48 && code <= 57)
        return "digit"
    if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122))
        return "letter"
    ; Latin Extended (BMP) — feeds the breakdown chart, accuracy non-critical.
    if (code >= 0xC0 && code <= 0x024F)
        return "letter"
    ; Bracket markers like [BS], [TAB] from the keylogger pipeline.
    if (SubStr(c, 1, 1) = "[" && SubStr(c, -1) = "]")
        return "other"
    ; Punctuation — coarse but matches the Lua %p pattern semantics.
    if RegExMatch(c, "^[[:punct:]<>=+*/\\|\-]$")
        return "punct"
    return "other"
}

; Pop the last UTF-16 code unit (AHK strings are UTF-16 internally).
KLW_PopLast(s) {
    if (s = "" || StrLen(s) = 0)
        return ""
    return SubStr(s, 1, StrLen(s) - 1)
}

; Get-or-create the per-app walking context.
KLW_GetAppCtx(app) {
    if !KLW.ctx.Has(app) {
        ctx := Map(
            "p1", "", "p2", "", "p3", "", "p4", "", "p5", "", "p6", "",
            "cur_word", "", "word_err", false, "hist", [],
            "prev_word", "", "prev_sc", "",
            "recent_typing", [],
            "bs_run_len", 0, "last_was_bs", false,
            "last_finger", "", "same_finger_run", 0, "same_hand_run", 0,
            "last_char", ""
        )
        ; ``current_burst`` / ``current_session`` are added on demand below;
        ; their *absence* from the Map signals "no burst / session in flight".
        KLW.ctx[app] := ctx
    }
    return KLW.ctx[app]
}

KLW_GetMap(m, k, default_val := "") {
    if (m is Map && m.Has(k))
        return m[k]
    return default_val
}

; Bump a metric in the n-gram batch dict. Mirrors `_add_ngram_metric` Lua.
KLW_AddNgramMetric(table_name, key, delay, is_error, synth_type) {
    if !KLW.batch["ngram"].Has(table_name)
        return
    tbl := KLW.batch["ngram"][table_name]
    if !tbl.Has(key)
        tbl[key] := Map("c", 0, "td", 0, "cd", 0, "e", 0, "esrc", Map())
    item := tbl[key]
    if is_error {
        item["e"] += 1
        if (synth_type != "" && synth_type != "none")
            item["esrc"][synth_type] := (item["esrc"].Has(synth_type) ? item["esrc"][synth_type] : 0) + 1
    } else {
        item["c"] += 1
        if (synth_type = "hotstring" || synth_type = "llm"
                || (synth_type != "" && synth_type != "none"))
            item["esrc"][synth_type] := (item["esrc"].Has(synth_type) ? item["esrc"][synth_type] : 0) + 1
        else if (delay > 0) {
            item["td"] += delay
            item["cd"] += 1
        }
    }
}

KLW_PushNgram(table_name, date_str, app, token, delay, is_error, synth_type) {
    key := date_str . Chr(1) . app . Chr(1) . token
    KLW_AddNgramMetric(table_name, key, delay, is_error, synth_type)
}

; Bump a per-app-day numeric counter on KLW.batch["app_day"].
KLW_BumpAppDay(date_str, app, field, value) {
    key := date_str . Chr(1) . app
    if !KLW.batch["app_day"].Has(key)
        KLW.batch["app_day"][key] := Map("date", date_str, "app", app)
    row := KLW.batch["app_day"][key]
    row[field] := (row.Has(field) ? row[field] : 0) + value
}





; ====================================
; ====================================
; ======= 5/ Burst / Session =======
; ====================================
; ====================================

KLW_FinalizeBurst(date_str, app, b) {
    if !(b is Map) || b["char_count"] <= 0
        return
    key := date_str . Chr(1) . app
    if !KLW.batch["bursts"].Has(key) {
        KLW.batch["bursts"][key] := Map(
            "date", date_str, "app", app,
            "count_total", 0, "max_cpm", 0.0, "max_chars", 0,
            "length_buckets", Map(),
            "inter_count", 0, "inter_sum", 0, "inter_sumsq", 0
        )
    }
    r := KLW.batch["bursts"][key]
    r["count_total"] += 1
    if (b["char_count"] > r["max_chars"])
        r["max_chars"] := b["char_count"]
    if (b["char_count"] >= KLWConst.MIN_BURST_FOR_CPM && b["sum_delays"] > 0) {
        cpm := b["char_count"] * 60000 / b["sum_delays"]
        if (cpm > r["max_cpm"])
            r["max_cpm"] := cpm
    }
    bk := KLW_BurstLengthBucket(b["char_count"])
    r["length_buckets"][bk] := (r["length_buckets"].Has(bk) ? r["length_buckets"][bk] : 0) + 1
    delta := b["char_count"] - 1
    if (delta < 0)
        delta := 0
    r["inter_count"] += delta
    r["inter_sum"]   += b["sum_delays"]
    r["inter_sumsq"] += b["sum_delays_sq"]
}

KLW_FinalizeSession(date_str, app, s) {
    if !(s is Map) || s["char_count"] <= 0
        return
    key := date_str . Chr(1) . app
    if !KLW.batch["sessions"].Has(key) {
        KLW.batch["sessions"][key] := Map(
            "date", date_str, "app", app,
            "count_total", 0, "longest_ms", 0, "longest_chars", 0,
            "total_active_ms", 0, "durations", []
        )
    }
    r := KLW.batch["sessions"][key]
    r["count_total"] += 1
    if (s["total_ms"] > r["longest_ms"])
        r["longest_ms"] := s["total_ms"]
    if (s["char_count"] > r["longest_chars"])
        r["longest_chars"] := s["char_count"]
    r["total_active_ms"] += s["total_ms"]
    if (r["durations"].Length < KLWConst.SESSION_DURATIONS_CAP)
        r["durations"].Push(s["total_ms"])
}





; =================================
; =================================
; ======= 6/ Typing walker =======
; =================================
; =================================

; Replays a typing entry and pushes every metric into KLW.batch.
; Mirrors the Lua _walk_typing_entry() byte-for-byte.
KLW_WalkTypingEntry(entry) {
    if !(entry is Map)
        return
    app      := KLW_GetMap(entry, "app", "Unknown")
    ts       := KLW_GetMap(entry, "timestamp", "")
    date_str := (ts != "") ? SubStr(ts, 1, 10) : KL_Today()
    events   := KLW_GetMap(entry, "events", "")
    if !(events is Array)
        return

    ctx := KLW_GetAppCtx(app)
    p1 := ctx["p1"], p2 := ctx["p2"], p3 := ctx["p3"]
    p4 := ctx["p4"], p5 := ctx["p5"], p6 := ctx["p6"]
    cur_word  := ctx["cur_word"]
    word_err  := ctx["word_err"]
    backtrack := ctx["hist"]
    prev_word := ctx["prev_word"]
    prev_sc   := ctx["prev_sc"]
    prev_synth_type := "none"

    ; Hour / 5-min slot from the entry timestamp.
    hh := (ts != "") ? SubStr(ts, 12, 2) : FormatTime(A_Now, "HH")
    mm := (ts != "") ? SubStr(ts, 15, 2) : FormatTime(A_Now, "mm")
    if (hh = "")
        hh := FormatTime(A_Now, "HH")
    if (mm = "")
        mm := FormatTime(A_Now, "mm")
    current_hour := hh
    mn5 := Floor(Integer(mm) / 5) * 5
    current_min5 := hh . ":" . Format("{:02d}", mn5)

    app_day_key := date_str . Chr(1) . app
    hourly_key  := app_day_key . Chr(1) . current_hour
    min5_key    := app_day_key . Chr(1) . current_min5

    if !KLW.batch["hourly"].Has(hourly_key) {
        KLW.batch["hourly"][hourly_key] := Map(
            "date", date_str, "app", app, "hour", current_hour,
            "c", 0, "e", 0, "em", 0, "es", 0, "e_buckets", Map()
        )
    }
    hr := KLW.batch["hourly"][hourly_key]

    if !KLW.batch["hourly_min5"].Has(min5_key) {
        KLW.batch["hourly_min5"][min5_key] := Map(
            "date", date_str, "app", app, "slot", current_min5,
            "c", 0, "e", 0, "es", 0, "e_buckets", Map()
        )
    }
    m5 := KLW.batch["hourly_min5"][min5_key]

    if !KLW.batch["chars_class"].Has(app_day_key) {
        KLW.batch["chars_class"][app_day_key] := Map(
            "date", date_str, "app", app,
            "letter", 0, "digit", 0, "punct", 0, "space", 0, "other", 0
        )
    }
    cc := KLW.batch["chars_class"][app_day_key]

    if !KLW.batch["errors"].Has(app_day_key) {
        KLW.batch["errors"][app_day_key] := Map(
            "date", date_str, "app", app,
            "bs_total", 0, "cascade_count", 0, "cascade_max_len", 0,
            "recovery_sum_ms", 0, "recovery_count", 0
        )
    }
    er := KLW.batch["errors"][app_day_key]

    if !KLW.batch["ergo"].Has(app_day_key) {
        KLW.batch["ergo"][app_day_key] := Map(
            "date", date_str, "app", app,
            "same_finger_streak_max", 0, "same_hand_streak_max", 0,
            "auto_repeat_count", 0
        )
    }
    eg := KLW.batch["ergo"][app_day_key]

    ; Layout tag.
    layout := KLW_GetMap(entry, "layout", "")
    if (layout != "") {
        lk := app_day_key . Chr(1) . layout
        if !KLW.batch["layouts"].Has(lk)
            KLW.batch["layouts"][lk] := Map("date", date_str, "app", app,
                "layout", layout, "count", 0)
        KLW.batch["layouts"][lk]["count"] += 1
    }

    ; Window-title tag (count bump; ms credited via window_switch).
    title := KLW_GetMap(entry, "title", "")
    if (title != "") {
        tk := app_day_key . Chr(1) . title
        if !KLW.batch["titles"].Has(tk)
            KLW.batch["titles"][tk] := Map("date", date_str, "app", app,
                "title", title, "c", 0, "ms", 0)
        KLW.batch["titles"][tk]["c"] += 1
    }

    for ev in events {
        ; ev = [char, delay_ms, meta?]
        if !(ev is Array) || ev.Length < 2
            continue
        char     := ev[1]
        delay    := ev[2]
        meta     := (ev.Length >= 3 && ev[3] is Map) ? ev[3] : Map()
        shortcut_key := KLW_GetMap(meta, "sc", "")
        is_backspace := (char = "[BS]")
        synth_type   := KLW_GetMap(meta, "st", "none")
        is_synthetic := KLW_GetMap(meta, "s", false) ? true : false

        if (shortcut_key != "") {
            ; Shortcuts: indexed separately, no n-gram chain participation.
            sc_tbl   := KLW.batch["sc_ngram"]["ngram_shortcuts"]
            scbg_tbl := KLW.batch["sc_ngram"]["ngram_shortcut_bigrams"]
            sk := app_day_key . Chr(1) . shortcut_key
            if !sc_tbl.Has(sk)
                sc_tbl[sk] := Map("date", date_str, "app", app,
                    "token", shortcut_key, "count", 0)
            sc_tbl[sk]["count"] += 1
            if (prev_sc != "") {
                bgt := prev_sc . "→" . shortcut_key
                bk := app_day_key . Chr(1) . bgt
                if !scbg_tbl.Has(bk)
                    scbg_tbl[bk] := Map("date", date_str, "app", app,
                        "token", bgt, "count", 0)
                scbg_tbl[bk]["count"] += 1
            }
            prev_sc := shortcut_key
        } else {
            ; Long pause breaks N-gram continuity.
            if (delay >= KLWConst.MAX_KEYSTROKE_DELAY_MS && !is_synthetic) {
                p1 := "", p2 := "", p3 := "", p4 := "", p5 := "", p6 := ""
                backtrack := []
                if (StrLen(cur_word) > 0) {
                    if (prev_word != "")
                        KLW_PushNgram("ngram_word_bigrams", date_str, app,
                            prev_word . " " . cur_word, 0, word_err, "none")
                    KLW_PushNgram("ngram_words", date_str, app,
                        cur_word, 0, word_err, "none")
                }
                cur_word := "", word_err := false, prev_word := "", prev_sc := ""
            }

            ; Count synth triggers once per burst.
            if (is_synthetic && synth_type != "none" && synth_type != prev_synth_type) {
                if (synth_type = "hotstring")
                    KLW_BumpAppDay(date_str, app, "hs_triggers", 1)
                else if (synth_type = "llm")
                    KLW_BumpAppDay(date_str, app, "llm_triggers", 1)
            }
            prev_synth_type := is_synthetic ? synth_type : "none"

            if is_backspace {
                if (backtrack.Length > 0) {
                    last_entry := backtrack.Pop()
                    if (KLW_GetMap(last_entry, "c", "") != "[BS]") {
                        if last_entry.Has("c")  && last_entry["c"]  != ""
                            KLW_PushNgram("ngram_chars",      date_str, app, last_entry["c"],  0, true, synth_type)
                        if last_entry.Has("bg") && last_entry["bg"] != ""
                            KLW_PushNgram("ngram_bigrams",    date_str, app, last_entry["bg"], 0, true, synth_type)
                        if last_entry.Has("tg") && last_entry["tg"] != ""
                            KLW_PushNgram("ngram_trigrams",   date_str, app, last_entry["tg"], 0, true, synth_type)
                        if last_entry.Has("qg") && last_entry["qg"] != ""
                            KLW_PushNgram("ngram_quadgrams",  date_str, app, last_entry["qg"], 0, true, synth_type)
                        if last_entry.Has("pg") && last_entry["pg"] != ""
                            KLW_PushNgram("ngram_pentagrams", date_str, app, last_entry["pg"], 0, true, synth_type)
                        if last_entry.Has("hx") && last_entry["hx"] != ""
                            KLW_PushNgram("ngram_hexagrams",  date_str, app, last_entry["hx"], 0, true, synth_type)
                        if last_entry.Has("hp") && last_entry["hp"] != ""
                            KLW_PushNgram("ngram_heptagrams", date_str, app, last_entry["hp"], 0, true, synth_type)
                    }
                }
                cur_word := KLW_PopLast(cur_word)
                word_err := true

                if is_synthetic {
                    hr["es"] += 1
                    m5["es"] += 1
                    trigger_evt := ""
                    if (ctx["recent_typing"].Length > 0)
                        trigger_evt := ctx["recent_typing"].Pop()
                    if (synth_type = "hotstring") {
                        KLW_BumpAppDay(date_str, app, "hs_chars", -1)
                        KLW_BumpAppDay(date_str, app, "hs_input_chars", 1)
                        if (trigger_evt is Map)
                            KLW_BumpInputBuckets(date_str, app, trigger_evt["delay"], "hs", app_day_key)
                    } else if (synth_type = "llm") {
                        KLW_BumpAppDay(date_str, app, "llm_chars", -1)
                        KLW_BumpAppDay(date_str, app, "llm_input_chars", 1)
                        if (trigger_evt is Map)
                            KLW_BumpInputBuckets(date_str, app, trigger_evt["delay"], "llm", app_day_key)
                    }
                } else {
                    hr["e"] += 1
                    hr["em"] += 1
                    m5["e"] += 1
                    KLW_BumpAppDay(date_str, app, "chars", 1)
                    if (delay > KLWConst.THINK_PAUSE_MS) {
                        KLW_BumpAppDay(date_str, app, "think_time_ms", delay)
                        KLW_BumpAppDay(date_str, app, "pauses", 1)
                    } else {
                        KLW_BumpAppDay(date_str, app, "time_ms", delay)
                    }
                    KLW_BucketAdd(hr["e_buckets"], delay, 1)
                    KLW_BucketAdd(m5["e_buckets"], delay, 1)
                    if (ctx["recent_typing"].Length > 0)
                        ctx["recent_typing"].Pop()
                    ctx["bs_run_len"] += 1
                    ctx["last_was_bs"] := true
                    er["bs_total"] += 1
                    ctx["last_finger"] := ""
                    ctx["same_finger_run"] := 0
                    ctx["same_hand_run"] := 0
                    ctx["last_char"] := ""
                }

                bs_entry := Map()
                KLW_PushNgram("ngram_chars", date_str, app, "[BS]", delay, false, synth_type)
                bs_entry["c"] := "[BS]"
                if (p1 != "") {
                    KLW_PushNgram("ngram_bigrams",  date_str, app, p1 . "[BS]", delay, false, synth_type)
                    bs_entry["bg"] := p1 . "[BS]"
                }
                if (p2 != "") {
                    KLW_PushNgram("ngram_trigrams", date_str, app, p2 . p1 . "[BS]", delay, false, synth_type)
                    bs_entry["tg"] := p2 . p1 . "[BS]"
                }
                backtrack.Push(bs_entry)
                p6 := p5, p5 := p4, p4 := p3, p3 := p2, p2 := p1, p1 := "[BS]"
            } else {
                k_c  := char
                k_bg := (p1 != "") ? p1 . k_c : ""
                k_tg := (p2 != "") ? p2 . p1 . k_c : ""
                k_qg := (p3 != "") ? p3 . p2 . p1 . k_c : ""
                k_pg := (p4 != "") ? p4 . p3 . p2 . p1 . k_c : ""
                k_hx := (p5 != "") ? p5 . p4 . p3 . p2 . p1 . k_c : ""
                k_hp := (p6 != "") ? p6 . p5 . p4 . p3 . p2 . p1 . k_c : ""

                is_bracket_key := (StrLen(k_c) > 0
                    && SubStr(k_c, 1, 1) = "["
                    && SubStr(k_c, -1) = "]")
                record_delay := (delay < KLWConst.MAX_KEYSTROKE_DELAY_MS) ? delay : 0

                entry_marks := Map()
                if (is_synthetic || is_bracket_key || delay < KLWConst.MAX_KEYSTROKE_DELAY_MS) {
                    KLW_PushNgram("ngram_chars", date_str, app, k_c, record_delay, false, synth_type)
                    entry_marks["c"] := k_c
                    if (k_bg != "") {
                        KLW_PushNgram("ngram_bigrams",    date_str, app, k_bg, record_delay, false, synth_type)
                        entry_marks["bg"] := k_bg
                    }
                    if (k_tg != "") {
                        KLW_PushNgram("ngram_trigrams",   date_str, app, k_tg, record_delay, false, synth_type)
                        entry_marks["tg"] := k_tg
                    }
                    if (k_qg != "") {
                        KLW_PushNgram("ngram_quadgrams",  date_str, app, k_qg, record_delay, false, synth_type)
                        entry_marks["qg"] := k_qg
                    }
                    if (k_pg != "") {
                        KLW_PushNgram("ngram_pentagrams", date_str, app, k_pg, record_delay, false, synth_type)
                        entry_marks["pg"] := k_pg
                    }
                    if (k_hx != "") {
                        KLW_PushNgram("ngram_hexagrams",  date_str, app, k_hx, record_delay, false, synth_type)
                        entry_marks["hx"] := k_hx
                    }
                    if (k_hp != "") {
                        KLW_PushNgram("ngram_heptagrams", date_str, app, k_hp, record_delay, false, synth_type)
                        entry_marks["hp"] := k_hp
                    }

                    if !is_synthetic {
                        KLW_BumpAppDay(date_str, app, "chars", 1)
                        hr["c"] += 1
                        m5["c"] += 1
                        if (record_delay > KLWConst.THINK_PAUSE_MS) {
                            KLW_BumpAppDay(date_str, app, "think_time_ms", record_delay)
                            KLW_BumpAppDay(date_str, app, "pauses", 1)
                        } else {
                            KLW_BumpAppDay(date_str, app, "time_ms", record_delay)
                        }
                        ; time / credited buckets.
                        for t in KLWConst.UI_PAUSE_BUCKETS_MS {
                            if (record_delay <= t) {
                                bkey := app_day_key . Chr(1) . String(t)
                                if !KLW.batch["app_buckets"].Has(bkey) {
                                    KLW.batch["app_buckets"][bkey] := Map(
                                        "date", date_str, "app", app, "bucket_ms", t,
                                        "time_sum", 0, "credited", 0,
                                        "hs_in_t", 0, "hs_in_c", 0,
                                        "llm_in_t", 0, "llm_in_c", 0
                                    )
                                }
                                row := KLW.batch["app_buckets"][bkey]
                                row["time_sum"] += record_delay
                                row["credited"] += 1
                            }
                        }
                        ctx["recent_typing"].Push(Map("delay", record_delay))
                        if (ctx["recent_typing"].Length > KLWConst.TRIGGER_LOOKBACK_LEN)
                            ctx["recent_typing"].RemoveAt(1)

                        ; Burst tracking.
                        if !ctx.Has("current_burst") || record_delay > KLWConst.BURST_GAP_MS {
                            if ctx.Has("current_burst")
                                KLW_FinalizeBurst(date_str, app, ctx["current_burst"])
                            ctx["current_burst"] := Map(
                                "char_count", 1, "sum_delays", 0,
                                "sum_delays_sq", 0, "max_delay", 0)
                        } else {
                            b := ctx["current_burst"]
                            b["char_count"]    += 1
                            b["sum_delays"]    += record_delay
                            b["sum_delays_sq"] += record_delay * record_delay
                            if (record_delay > b["max_delay"])
                                b["max_delay"] := record_delay
                        }

                        ; Session tracking.
                        if !ctx.Has("current_session") || record_delay > KLWConst.SESSION_GAP_MS {
                            if ctx.Has("current_session")
                                KLW_FinalizeSession(date_str, app, ctx["current_session"])
                            ctx["current_session"] := Map("char_count", 1, "total_ms", 0)
                        } else {
                            s := ctx["current_session"]
                            s["char_count"] += 1
                            s["total_ms"]   += record_delay
                        }

                        ; Cascade close + recovery.
                        if ctx["last_was_bs"] {
                            if (ctx["bs_run_len"] >= KLWConst.CASCADE_MIN_BS) {
                                er["cascade_count"] += 1
                                if (ctx["bs_run_len"] > er["cascade_max_len"])
                                    er["cascade_max_len"] := ctx["bs_run_len"]
                            }
                            if (record_delay <= KLWConst.MAX_KEYSTROKE_DELAY_MS) {
                                er["recovery_sum_ms"] += record_delay
                                er["recovery_count"]  += 1
                            }
                            ctx["bs_run_len"] := 0
                            ctx["last_was_bs"] := false
                        }

                        ; Same-finger / same-hand streaks.
                        kc_num := KLW_GetMap(meta, "kc", "")
                        cur_finger := ""
                        if (kc_num != "" && IsNumber(kc_num) && KLW_VK_FINGER.Has(kc_num))
                            cur_finger := KLW_VK_FINGER[kc_num]
                        if (cur_finger != "") {
                            if (ctx["last_finger"] = cur_finger)
                                ctx["same_finger_run"] += 1
                            else
                                ctx["same_finger_run"] := 1
                            if (ctx["same_finger_run"] > eg["same_finger_streak_max"])
                                eg["same_finger_streak_max"] := ctx["same_finger_run"]
                            cur_hand  := SubStr(cur_finger, 1, 1)
                            last_hand := (ctx["last_finger"] != "") ? SubStr(ctx["last_finger"], 1, 1) : ""
                            if (last_hand = cur_hand)
                                ctx["same_hand_run"] += 1
                            else
                                ctx["same_hand_run"] := 1
                            if (ctx["same_hand_run"] > eg["same_hand_streak_max"])
                                eg["same_hand_streak_max"] := ctx["same_hand_run"]
                            ctx["last_finger"] := cur_finger
                        } else {
                            ctx["last_finger"] := ""
                            ctx["same_finger_run"] := 0
                            ctx["same_hand_run"] := 0
                        }

                        ; Auto-repeat.
                        if (ctx["last_char"] = k_c && record_delay > 0
                                && record_delay <= KLWConst.AUTO_REPEAT_MAX_DELAY_MS)
                            eg["auto_repeat_count"] += 1
                        ctx["last_char"] := k_c

                        ; Char class.
                        cls := KLW_CharClass(k_c)
                        if (cls = "letter") {
                            cc["letter"] += 1
                        } else if (cls = "digit") {
                            cc["digit"] += 1
                        } else if (cls = "punct") {
                            cc["punct"] += 1
                        } else if (cls = "space") {
                            cc["space"] += 1
                        } else {
                            cc["other"] += 1
                        }

                        if !cc.Has("first_typed_min") || cc["first_typed_min"] = ""
                            cc["first_typed_min"] := current_min5
                        cc["last_typed_min"] := current_min5
                    } else {
                        if (synth_type = "hotstring")
                            KLW_BumpAppDay(date_str, app, "hs_chars", 1)
                        else if (synth_type = "llm")
                            KLW_BumpAppDay(date_str, app, "llm_chars", 1)
                    }

                    ; Word boundary detection.
                    is_separator := false
                    if (StrLen(k_c) > 0) {
                        if RegExMatch(k_c, '[\s.,!?;:"' . "'" . '()%{}\[\]<>=+*/\\|\-]')
                            is_separator := true
                        else if (k_c = "`n" || k_c = Chr(0xA0) || k_c = Chr(0x202F))
                            is_separator := true
                    }
                    if is_separator {
                        if (StrLen(cur_word) > 0) {
                            if (prev_word != "")
                                KLW_PushNgram("ngram_word_bigrams", date_str, app,
                                    prev_word . " " . cur_word, 0, word_err, "none")
                            KLW_PushNgram("ngram_words", date_str, app,
                                cur_word, 0, word_err, "none")
                            prev_word := cur_word
                            cur_word := ""
                            word_err := false
                        }
                    } else {
                        cur_word .= k_c
                    }
                }

                backtrack.Push(entry_marks)
                p6 := p5, p5 := p4, p4 := p3, p3 := p2, p2 := p1, p1 := k_c
            }
        }

        ; Physical keycode + scancode tally (non-synthetic only).
        if !is_synthetic {
            kc := KLW_GetMap(meta, "kc", "")
            if (kc != "" && IsNumber(kc)) {
                kk := app_day_key . Chr(1) . String(kc)
                if !KLW.batch["kc_ngram"].Has(kk)
                    KLW.batch["kc_ngram"][kk] := Map("date", date_str, "app", app,
                        "keycode", Integer(kc), "count", 0)
                KLW.batch["kc_ngram"][kk]["count"] += 1
            }
            ; ``sk`` is the hardware scancode (set by the AHK input hook).
            ; The walker's ``sc`` meta slot is already taken by shortcut keys,
            ; so we use a distinct identifier here.
            sk_code := KLW_GetMap(meta, "sk", "")
            if (sk_code != "" && IsNumber(sk_code)) {
                skey := app_day_key . Chr(1) . String(sk_code)
                if !KLW.batch["sc_kb_ngram"].Has(skey)
                    KLW.batch["sc_kb_ngram"][skey] := Map("date", date_str, "app", app,
                        "scancode", Integer(sk_code), "count", 0)
                KLW.batch["sc_kb_ngram"][skey]["count"] += 1
            }
        }
    }

    ; Persist context for next tick.
    ctx["p1"] := p1, ctx["p2"] := p2, ctx["p3"] := p3
    ctx["p4"] := p4, ctx["p5"] := p5, ctx["p6"] := p6
    ctx["cur_word"]  := cur_word
    ctx["word_err"]  := word_err
    ctx["hist"]      := backtrack
    ctx["prev_word"] := prev_word
    ctx["prev_sc"]   := prev_sc
}

KLW_BumpInputBuckets(date_str, app, trigger_delay, kind, app_day_key) {
    for t in KLWConst.UI_PAUSE_BUCKETS_MS {
        if (trigger_delay <= t) {
            bkey := app_day_key . Chr(1) . String(t)
            if !KLW.batch["app_buckets"].Has(bkey) {
                KLW.batch["app_buckets"][bkey] := Map(
                    "date", date_str, "app", app, "bucket_ms", t,
                    "time_sum", 0, "credited", 0,
                    "hs_in_t", 0, "hs_in_c", 0,
                    "llm_in_t", 0, "llm_in_c", 0
                )
            }
            row := KLW.batch["app_buckets"][bkey]
            if (kind = "hs") {
                row["hs_in_t"] += trigger_delay
                row["hs_in_c"] += 1
            } else {
                row["llm_in_t"] += trigger_delay
                row["llm_in_c"] += 1
            }
        }
    }
}




; =============================================
; =============================================
; ===== 7/ Non-typing event aggregation =====
; =============================================
; =============================================

KLW_WalkAppSwitch(entry) {
    prev_app := KLW_GetMap(entry, "prev_app", "")
    if (prev_app = "")
        return
    ts := KLW_GetMap(entry, "timestamp", "")
    date_str := (ts != "") ? SubStr(ts, 1, 10) : KL_Today()
    duration := KLW_GetMap(entry, "duration_ms", 0)

    key := date_str . Chr(1) . prev_app
    if !KLW.batch["app_time"].Has(key)
        KLW.batch["app_time"][key] := Map("date", date_str, "app", prev_app, "ms", 0)
    KLW.batch["app_time"][key]["ms"] += duration

    next_app := KLW_GetMap(entry, "next_app", "")
    if (next_app != "") {
        sk := date_str . Chr(1) . prev_app . Chr(1) . next_app
        if !KLW.batch["switches_to"].Has(sk)
            KLW.batch["switches_to"][sk] := Map("date", date_str,
                "app_from", prev_app, "app_to", next_app, "count", 0)
        KLW.batch["switches_to"][sk]["count"] += 1
    }
}

KLW_WalkWindowSwitch(entry) {
    prev_title := KLW_GetMap(entry, "prev_title", "")
    if (prev_title = "")
        return
    ts := KLW_GetMap(entry, "timestamp", "")
    date_str := (ts != "") ? SubStr(ts, 1, 10) : KL_Today()
    app := KLW_GetMap(entry, "app", "Unknown")
    duration := KLW_GetMap(entry, "duration_ms", 0)
    tk := date_str . Chr(1) . app . Chr(1) . prev_title
    if !KLW.batch["titles"].Has(tk)
        KLW.batch["titles"][tk] := Map("date", date_str, "app", app,
            "title", prev_title, "c", 0, "ms", 0)
    KLW.batch["titles"][tk]["ms"] += duration
}

KLW_WalkSystemEvent(entry) {
    ts := KLW_GetMap(entry, "timestamp", "")
    date_str := (ts != "") ? SubStr(ts, 1, 10) : KL_Today()
    action := KLW_GetMap(entry, "action", "")

    if (action = "modifier_hold" || action = "karabiner_release") {
        kc := KLW_GetMap(entry, "keycode", "")
        if (kc != "" && IsNumber(kc)) {
            app := KLW_GetMap(entry, "app", "Unknown")
            hold := KLW_GetMap(entry, "hold_ms", 0)
            key := date_str . Chr(1) . app . Chr(1) . String(kc)
            if !KLW.batch["kc_hold"].Has(key)
                KLW.batch["kc_hold"][key] := Map(
                    "date", date_str, "app", app, "keycode", Integer(kc),
                    "sum_ms", 0, "count", 0, "max_ms", 0,
                    "tap_count", 0, "hold_count", 0
                )
            r := KLW.batch["kc_hold"][key]
            r["sum_ms"] += hold
            r["count"]  += 1
            if (hold > r["max_ms"])
                r["max_ms"] := hold
            if (hold <= KLWConst.HOLD_THRESHOLD_MS)
                r["tap_count"] += 1
            else
                r["hold_count"] += 1
        }
    }

    if !KLW.batch["system_day"].Has(date_str) {
        KLW.batch["system_day"][date_str] := Map(
            "date", date_str, "wifi_changes", 0, "space_switches", 0,
            "audio_muted_ms", 0, "locked_ms", 0, "sleep_ms", 0, "awake_ms", 0,
            "passive_count", 0, "night_wake_count", 0
        )
    }
    s := KLW.batch["system_day"][date_str]
    if (action = "wifi_change") {
        s["wifi_changes"] += 1
    } else if (action = "space_change") {
        s["space_switches"] += 1
    } else if (action = "passive_period") {
        s["passive_count"] += 1
    } else if (action = "unlock") {
        s["locked_ms"] += KLW_GetMap(entry, "duration_ms", 0)
    } else if (action = "wake") {
        s["sleep_ms"] += KLW_GetMap(entry, "duration_ms", 0)
    }
}





; ===========================================
; ===========================================
; ======= 8/ SQL emission helpers =======
; ===========================================
; ===========================================

KLW_SqlEscape(s) {
    return "'" . StrReplace(String(s), "'", "''") . "'"
}

KLW_JsonEscape(m) {
    return KLW_SqlEscape(KL_JsonEncode(m))
}

; Split a Chr(1)-delimited composite key into N parts.
KLW_SplitKey(k, n) {
    parts := []
    rest := k
    Loop n - 1 {
        pos := InStr(rest, Chr(1))
        if !pos {
            parts.Push(rest)
            rest := ""
            break
        }
        parts.Push(SubStr(rest, 1, pos - 1))
        rest := SubStr(rest, pos + 1)
    }
    parts.Push(rest)
    return parts
}





; ====================================
; ====================================
; ======= 9/ Batch flush =======
; ====================================
; ====================================

; Returns the SQL text accumulated this tick (or "" when nothing to emit).
; Caller appends it to data.sql in the same write that contains the raw
; INSERT statements.
KLW_BuildBatchSql() {
    if !KLW.batch.Has("app_day")
        return ""
    d := Keylogger._device_id_lit
    out := ""

    ; agg_app_day.
    for key, row in KLW.batch["app_day"] {
        out .= Format(
            "INSERT INTO agg_app_day (device_id, date, app, chars, pauses, time_ms, think_time_ms, hs_chars, llm_chars, hs_triggers, llm_triggers, hs_input_chars, llm_input_chars) VALUES ({1},{2},{3},{4},{5},{6},{7},{8},{9},{10},{11},{12},{13}) ON CONFLICT(device_id, date, app) DO UPDATE SET chars=chars+excluded.chars,pauses=pauses+excluded.pauses,time_ms=time_ms+excluded.time_ms,think_time_ms=think_time_ms+excluded.think_time_ms,hs_chars=hs_chars+excluded.hs_chars,llm_chars=llm_chars+excluded.llm_chars,hs_triggers=hs_triggers+excluded.hs_triggers,llm_triggers=llm_triggers+excluded.llm_triggers,hs_input_chars=hs_input_chars+excluded.hs_input_chars,llm_input_chars=llm_input_chars+excluded.llm_input_chars;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            KLW_GetMap(row, "chars", 0), KLW_GetMap(row, "pauses", 0),
            KLW_GetMap(row, "time_ms", 0), KLW_GetMap(row, "think_time_ms", 0),
            KLW_GetMap(row, "hs_chars", 0), KLW_GetMap(row, "llm_chars", 0),
            KLW_GetMap(row, "hs_triggers", 0), KLW_GetMap(row, "llm_triggers", 0),
            KLW_GetMap(row, "hs_input_chars", 0), KLW_GetMap(row, "llm_input_chars", 0))
    }

    ; agg_app_day app_time.
    for key, row in KLW.batch["app_time"] {
        out .= Format(
            "INSERT INTO agg_app_day (device_id, date, app, app_time_ms) VALUES ({1},{2},{3},{4}) ON CONFLICT(device_id, date, app) DO UPDATE SET app_time_ms=app_time_ms+excluded.app_time_ms;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]), row["ms"])
    }

    ; agg_app_day_buckets.
    for key, row in KLW.batch["app_buckets"] {
        out .= Format(
            "INSERT INTO agg_app_day_buckets (device_id, date, app, bucket_ms, time_sum, credited, hs_input_time_sum, hs_input_credited, llm_input_time_sum, llm_input_credited) VALUES ({1},{2},{3},{4},{5},{6},{7},{8},{9},{10}) ON CONFLICT(device_id, date, app, bucket_ms) DO UPDATE SET time_sum=time_sum+excluded.time_sum,credited=credited+excluded.credited,hs_input_time_sum=hs_input_time_sum+excluded.hs_input_time_sum,hs_input_credited=hs_input_credited+excluded.hs_input_credited,llm_input_time_sum=llm_input_time_sum+excluded.llm_input_time_sum,llm_input_credited=llm_input_credited+excluded.llm_input_credited;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            row["bucket_ms"], row["time_sum"], row["credited"],
            row["hs_in_t"], row["hs_in_c"], row["llm_in_t"], row["llm_in_c"])
    }

    ; n-gram tables.
    for tbl_name, tbl in KLW.batch["ngram"] {
        for key, item in tbl {
            parts := KLW_SplitKey(key, 3)
            out .= Format(
                "INSERT INTO {1} (device_id, date, app, token, c, td, cd, e, esrc_json) VALUES ({2},{3},{4},{5},{6},{7},{8},{9},{10}) ON CONFLICT(device_id, date, app, token) DO UPDATE SET c=c+excluded.c,td=td+excluded.td,cd=cd+excluded.cd,e=e+excluded.e,esrc_json=excluded.esrc_json;`n",
                tbl_name, d,
                KLW_SqlEscape(parts[1]), KLW_SqlEscape(parts[2]), KLW_SqlEscape(parts[3]),
                item["c"], item["td"], item["cd"], item["e"],
                KLW_JsonEscape(item["esrc"]))
        }
    }

    ; ngram_keycodes.
    for key, row in KLW.batch["kc_ngram"] {
        out .= Format(
            "INSERT INTO ngram_keycodes (device_id, date, app, keycode, c) VALUES ({1},{2},{3},{4},{5}) ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET c=c+excluded.c;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            row["keycode"], row["count"])
    }

    ; ngram_scancodes (Windows hardware scancodes — independent of layout).
    for key, row in KLW.batch["sc_kb_ngram"] {
        out .= Format(
            "INSERT INTO ngram_scancodes (device_id, date, app, scancode, c) VALUES ({1},{2},{3},{4},{5}) ON CONFLICT(device_id, date, app, scancode) DO UPDATE SET c=c+excluded.c;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            row["scancode"], row["count"])
    }

    ; ngram_shortcuts / ngram_shortcut_bigrams.
    for tbl_name, tbl in KLW.batch["sc_ngram"] {
        for key, row in tbl {
            out .= Format(
                "INSERT INTO {1} (device_id, date, app, token, c) VALUES ({2},{3},{4},{5},{6}) ON CONFLICT(device_id, date, app, token) DO UPDATE SET c=c+excluded.c;`n",
                tbl_name, d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
                KLW_SqlEscape(row["token"]), row["count"])
        }
    }

    ; agg_app_day_kc_hold.
    for key, row in KLW.batch["kc_hold"] {
        out .= Format(
            "INSERT INTO agg_app_day_kc_hold (device_id, date, app, keycode, sum_ms, count, max_ms, tap_count, hold_count) VALUES ({1},{2},{3},{4},{5},{6},{7},{8},{9}) ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET sum_ms=sum_ms+excluded.sum_ms,count=count+excluded.count,max_ms=MAX(max_ms, excluded.max_ms),tap_count=tap_count+excluded.tap_count,hold_count=hold_count+excluded.hold_count;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            row["keycode"], row["sum_ms"], row["count"],
            row["max_ms"], row["tap_count"], row["hold_count"])
    }

    ; agg_app_day_titles.
    for key, row in KLW.batch["titles"] {
        out .= Format(
            "INSERT INTO agg_app_day_titles (device_id, date, app, title, c, ms) VALUES ({1},{2},{3},{4},{5},{6}) ON CONFLICT(device_id, date, app, title) DO UPDATE SET c=c+excluded.c,ms=ms+excluded.ms;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            KLW_SqlEscape(row["title"]), row["c"], row["ms"])
    }

    ; agg_app_day_hourly.
    for key, row in KLW.batch["hourly"] {
        out .= Format(
            "INSERT INTO agg_app_day_hourly (device_id, date, app, hour, c, e, em, es, e_buckets_json) VALUES ({1},{2},{3},{4},{5},{6},{7},{8},{9}) ON CONFLICT(device_id, date, app, hour) DO UPDATE SET c=c+excluded.c,e=e+excluded.e,em=em+excluded.em,es=es+excluded.es,e_buckets_json=excluded.e_buckets_json;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            KLW_SqlEscape(row["hour"]), row["c"], row["e"], row["em"], row["es"],
            KLW_JsonEscape(row["e_buckets"]))
    }

    ; agg_app_day_hourly_min5.
    for key, row in KLW.batch["hourly_min5"] {
        out .= Format(
            "INSERT INTO agg_app_day_hourly_min5 (device_id, date, app, slot, c, e, es, e_buckets_json) VALUES ({1},{2},{3},{4},{5},{6},{7},{8}) ON CONFLICT(device_id, date, app, slot) DO UPDATE SET c=c+excluded.c,e=e+excluded.e,es=es+excluded.es,e_buckets_json=excluded.e_buckets_json;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            KLW_SqlEscape(row["slot"]), row["c"], row["e"], row["es"],
            KLW_JsonEscape(row["e_buckets"]))
    }

    ; agg_app_day_layouts.
    for key, row in KLW.batch["layouts"] {
        out .= Format(
            "INSERT INTO agg_app_day_layouts (device_id, date, app, layout, count) VALUES ({1},{2},{3},{4},{5}) ON CONFLICT(device_id, date, app, layout) DO UPDATE SET count=count+excluded.count;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            KLW_SqlEscape(row["layout"]), row["count"])
    }

    ; agg_app_day_chars_class.
    for key, row in KLW.batch["chars_class"] {
        first_lit := row.Has("first_typed_min") ? KLW_SqlEscape(row["first_typed_min"]) : "NULL"
        last_lit  := row.Has("last_typed_min")  ? KLW_SqlEscape(row["last_typed_min"])  : "NULL"
        out .= Format(
            "INSERT INTO agg_app_day_chars_class (device_id, date, app, letter, digit, punct, space, other, first_typed_min, last_typed_min) VALUES ({1},{2},{3},{4},{5},{6},{7},{8},{9},{10}) ON CONFLICT(device_id, date, app) DO UPDATE SET letter=letter+excluded.letter,digit=digit+excluded.digit,punct=punct+excluded.punct,space=space+excluded.space,other=other+excluded.other,first_typed_min=COALESCE(agg_app_day_chars_class.first_typed_min, excluded.first_typed_min),last_typed_min=COALESCE(excluded.last_typed_min, agg_app_day_chars_class.last_typed_min);`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            row["letter"], row["digit"], row["punct"], row["space"], row["other"],
            first_lit, last_lit)
    }

    ; agg_app_day_errors.
    for key, row in KLW.batch["errors"] {
        out .= Format(
            "INSERT INTO agg_app_day_errors (device_id, date, app, bs_total, cascade_count, cascade_max_len, recovery_sum_ms, recovery_count) VALUES ({1},{2},{3},{4},{5},{6},{7},{8}) ON CONFLICT(device_id, date, app) DO UPDATE SET bs_total=bs_total+excluded.bs_total,cascade_count=cascade_count+excluded.cascade_count,cascade_max_len=MAX(cascade_max_len, excluded.cascade_max_len),recovery_sum_ms=recovery_sum_ms+excluded.recovery_sum_ms,recovery_count=recovery_count+excluded.recovery_count;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            row["bs_total"], row["cascade_count"], row["cascade_max_len"],
            row["recovery_sum_ms"], row["recovery_count"])
    }

    ; agg_app_day_ergo.
    for key, row in KLW.batch["ergo"] {
        out .= Format(
            "INSERT INTO agg_app_day_ergo (device_id, date, app, same_finger_streak_max, same_hand_streak_max, auto_repeat_count) VALUES ({1},{2},{3},{4},{5},{6}) ON CONFLICT(device_id, date, app) DO UPDATE SET same_finger_streak_max=MAX(same_finger_streak_max, excluded.same_finger_streak_max),same_hand_streak_max=MAX(same_hand_streak_max, excluded.same_hand_streak_max),auto_repeat_count=auto_repeat_count+excluded.auto_repeat_count;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            row["same_finger_streak_max"], row["same_hand_streak_max"],
            row["auto_repeat_count"])
    }

    ; agg_app_day_burst.
    for key, row in KLW.batch["bursts"] {
        out .= Format(
            "INSERT INTO agg_app_day_burst (device_id, date, app, count_total, max_cpm, max_chars, length_buckets_json, inter_delay_count, inter_delay_sum, inter_delay_sumsq) VALUES ({1},{2},{3},{4},{5},{6},{7},{8},{9},{10}) ON CONFLICT(device_id, date, app) DO UPDATE SET count_total=count_total+excluded.count_total,max_cpm=MAX(max_cpm, excluded.max_cpm),max_chars=MAX(max_chars, excluded.max_chars),length_buckets_json=excluded.length_buckets_json,inter_delay_count=inter_delay_count+excluded.inter_delay_count,inter_delay_sum=inter_delay_sum+excluded.inter_delay_sum,inter_delay_sumsq=inter_delay_sumsq+excluded.inter_delay_sumsq;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            row["count_total"], row["max_cpm"], row["max_chars"],
            KLW_JsonEscape(row["length_buckets"]),
            row["inter_count"], row["inter_sum"], row["inter_sumsq"])
    }

    ; agg_app_day_session.
    for key, row in KLW.batch["sessions"] {
        out .= Format(
            "INSERT INTO agg_app_day_session (device_id, date, app, count_total, longest_ms, longest_chars, total_active_ms, durations_json) VALUES ({1},{2},{3},{4},{5},{6},{7},{8}) ON CONFLICT(device_id, date, app) DO UPDATE SET count_total=count_total+excluded.count_total,longest_ms=MAX(longest_ms, excluded.longest_ms),longest_chars=MAX(longest_chars, excluded.longest_chars),total_active_ms=total_active_ms+excluded.total_active_ms,durations_json=excluded.durations_json;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
            row["count_total"], row["longest_ms"], row["longest_chars"],
            row["total_active_ms"],
            KLW_JsonEscape(row["durations"]))
    }

    ; agg_app_day_switches_to.
    for key, row in KLW.batch["switches_to"] {
        out .= Format(
            "INSERT INTO agg_app_day_switches_to (device_id, date, app_from, app_to, count) VALUES ({1},{2},{3},{4},{5}) ON CONFLICT(device_id, date, app_from, app_to) DO UPDATE SET count=count+excluded.count;`n",
            d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app_from"]),
            KLW_SqlEscape(row["app_to"]), row["count"])
    }

    ; agg_system_day.
    for key, row in KLW.batch["system_day"] {
        out .= Format(
            "INSERT INTO agg_system_day (device_id, date, wifi_changes, space_switches, audio_muted_ms, locked_ms, sleep_ms, awake_ms, passive_count, night_wake_count) VALUES ({1},{2},{3},{4},{5},{6},{7},{8},{9},{10}) ON CONFLICT(device_id, date) DO UPDATE SET wifi_changes=wifi_changes+excluded.wifi_changes,space_switches=space_switches+excluded.space_switches,audio_muted_ms=audio_muted_ms+excluded.audio_muted_ms,locked_ms=locked_ms+excluded.locked_ms,sleep_ms=sleep_ms+excluded.sleep_ms,awake_ms=awake_ms+excluded.awake_ms,passive_count=passive_count+excluded.passive_count,night_wake_count=night_wake_count+excluded.night_wake_count;`n",
            d, KLW_SqlEscape(row["date"]),
            row["wifi_changes"], row["space_switches"], row["audio_muted_ms"],
            row["locked_ms"], row["sleep_ms"], row["awake_ms"],
            row["passive_count"], row["night_wake_count"])
    }

    KLW_ResetBatch()
    return out
}





; ===========================================
; ===========================================
; ======= 10/ Context persistence =======
; ===========================================
; ===========================================

; Serialise KLW.ctx into a Map suitable for state.json.
KLW_SerializeCtx() {
    return KLW.ctx
}

KLW_RestoreCtx(loaded) {
    if (loaded is Map)
        KLW.ctx := loaded
    else
        KLW.ctx := Map()
}

KLW_DayRolloverReset() {
    KLW.ctx := Map()
    KLW_ResetBatch()
}
