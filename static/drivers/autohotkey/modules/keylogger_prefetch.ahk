; modules/keylogger_prefetch.ahk

; ==============================================================================
; MODULE: Keylogger Prefetch (AHK)
; DESCRIPTION:
; Builds the JSON blob the metrics_typing / metrics_apps webview pages
; consume on load. Mirrors the « load_and_inject » codepath of
; ui/metrics_typing/init.lua on macOS, except that we cannot push JS
; into Edge --app= externally (no JS bridge without WebView2). Instead
; we serialise the projection to a sidecar file the page reads via
; ``fetch('./prefetch.json')`` on load.
;
; FEATURES & RATIONALE:
; 1. Single chokepoint: every dashboard launch goes through
;    KLPF_BuildAndWrite which (a) materialises an in-memory SQLite
;    database from data.sql, (b) projects the manifest + range data,
;    (c) writes a single JSON file the page picks up.
; 2. Per-asset prefetch: each dashboard reads its own prefetch file
;    located alongside its index.html. This avoids a stale "typing"
;    blob being served to the "apps" dashboard or vice versa.
; 3. Atomic write: the JSON is written to a .tmp sibling and renamed
;    so a half-flushed file can never reach the page mid-fetch.
; 4. Disposable build: we do NOT cache the in-memory db across opens.
;    A fresh build of <100 MB of data.sql still completes in well under
;    a second on a modern SSD; cache invalidation would buy nothing
;    that's worth the bookkeeping.
; ==============================================================================

#Requires Autohotkey v2.0+




; =====================================
; =====================================
; ======= 1/ Path resolution =======
; =====================================
; =====================================

; Resolve the dashboard assets folder for a given page key (« typing »
; or « apps »). The dashboards live under
; ``<repo>/static/drivers/_shared/ui/metrics_<key>/``.
KLPF_AssetsDir(which) {
    base := A_ScriptDir . "\..\_shared\ui\metrics_" . which . "\"
    Loop Files, base, "D"
        return A_LoopFileFullPath . "\"
    return base
}

; The prefetch file lives alongside index.html and is loaded via a
; <script src="prefetch.js"> tag rather than fetch(). Chromium blocks
; fetch() across file:// URLs (every file:// is a unique origin) but
; <script> tags work fine, so we ship a tiny JS that assigns a global.
KLPF_PrefetchPath(which) {
    return KLPF_AssetsDir(which) . "prefetch.js"
}




; ====================================
; ====================================
; ======= 2/ Public entry =======
; ====================================
; ====================================

; Build and write the prefetch blob for the named dashboard. Returns true
; on success, false on any failure (a failure leaves the previous file
; intact so the page degrades gracefully to the old data rather than to
; an empty state).
KLPF_BuildAndWrite(which, metrics_dir, dbg := "") {
    ; Step-by-step diagnostic so a silent failure points us straight at
    ; the broken stage. Caller provides a log path; default is alongside
    ; the prefetch sidecar so the function still works on its own.
    if (dbg = "")
        dbg := KLPF_AssetsDir(which) . "prefetch_debug.txt"
    KLPF_DbgWrite(dbg, "=== " . A_Now . " — which=" . which . " md=" . metrics_dir)

    db := KLR_BuildDatabase(metrics_dir)
    if !db {
        KLPF_DbgWrite(dbg, "FAIL: KLR_BuildDatabase returned 0 (winsqlite3 open or schema load failed)")
        return false
    }
    KLPF_DbgWrite(dbg, "OK: db opened, schema + data.sql loaded")

    ; Cheap sanity probe — count agg_app_day rows so we know the data
    ; actually landed. SQLite_Query returns Array<Map>.
    rows := SQLite_Query(db, "SELECT COUNT(*) AS n FROM agg_app_day")
    n := (rows.Length > 0 && rows[1].Has("n")) ? rows[1]["n"] : "?"
    KLPF_DbgWrite(dbg, "agg_app_day row count = " . n)

    blob := Map()
    if (which = "typing") {
        blob := KLPF_BuildTyping(db)
    } else if (which = "apps") {
        blob := KLPF_BuildApps(db)
    }
    SQLite_Close(db)
    KLPF_DbgWrite(dbg, "OK: blob projected (" . (blob is Map ? blob.Count : "?") . " top-level keys)")

    json := KL_JsonEncode(blob)
    KLPF_DbgWrite(dbg, "OK: JSON encoded, len=" . StrLen(json))

    body := "window._ergopti_prefetch = " . json . ";"
    path := KLPF_PrefetchPath(which)
    written := KLPF_WriteAtomic(path, body)
    KLPF_DbgWrite(dbg, written ? ("OK: wrote " . path) : ("FAIL: WriteAtomic to " . path))
    return written
}

KLPF_DbgWrite(path, line) {
    try FileAppend(line . "`r`n", path, "UTF-8")
}

KLPF_WriteAtomic(path, content) {
    tmp := path . ".tmp"
    try FileDelete(tmp)
    try FileAppend(content, tmp, "UTF-8-RAW")
    catch
        return false
    if FileExist(path)
        try FileDelete(path)
    try FileMove(tmp, path)
    catch
        return false
    return true
}




; =========================================
; =========================================
; ======= 3/ Typing dashboard blob =======
; =========================================
; =========================================

KLPF_BuildTyping(db) {
    manifest  := KLR_ReadManifest(db)

    ; Date range = (first manifest date) → today. Mirrors HS first_date
    ; computation in ui/metrics_typing/init.lua §4.
    first_date := ""
    apps_set   := Map()
    apps_list  := []
    for date_str, day_data in manifest {
        if (first_date = "" || StrCompare(date_str, first_date) < 0)
            first_date := date_str
        for app_name, _ in day_data {
            if (app_name = "Unknown")
                continue
            if !apps_set.Has(app_name) {
                apps_set[app_name] := true
                apps_list.Push(app_name)
            }
        }
    }
    KLPF_SortInPlace(apps_list)

    today := FormatTime(A_Now, "yyyy-MM-dd")
    range_data := Map("historical", Map(), "today", Map())
    if (first_date != "")
        range_data := KLR_ReadRangeSplitToday(db, first_date, today, apps_list)

    return Map(
        "metrics_manifest",  manifest,
        "app_icons",         Map(),                      ; icon extraction is HS-only for now.
        "_prefetch_data",    range_data,
        "keycode_layout",    KLPF_KeycodeLayout()
    )
}




; =======================================
; =======================================
; ======= 4/ Apps dashboard blob =======
; =======================================
; =======================================

KLPF_BuildApps(db) {
    ; metrics_apps reads (date, app) totals only — no n-grams. The same
    ; manifest projection covers it.
    manifest := KLR_ReadManifest(db)
    return Map(
        "metrics_manifest",  manifest,
        "app_icons",         Map()
    )
}




; ============================================
; ============================================
; ======= 5/ Keycode layout (heatmap) =======
; ============================================
; ============================================

; The HS dashboard injects a numeric-keycode → character map computed
; from hs.keycodes.map. On Windows the closest equivalent is the
; user-active layout, but the QWERTY VK→char lookup the n-gram heatmap
; expects is stable enough across layouts that we ship a static map.
; A future iteration can read the active layout via GetKeyboardLayout.
KLPF_KeycodeLayout() {
    static MAP := unset
    if IsSet(MAP)
        return MAP
    MAP := Map()
    static QWERTY := Map(
        65,  "a", 66, "b", 67, "c", 68, "d", 69, "e", 70, "f",
        71,  "g", 72, "h", 73, "i", 74, "j", 75, "k", 76, "l",
        77,  "m", 78, "n", 79, "o", 80, "p", 81, "q", 82, "r",
        83,  "s", 84, "t", 85, "u", 86, "v", 87, "w", 88, "x",
        89,  "y", 90, "z",
        48, "0", 49, "1", 50, "2", 51, "3", 52, "4",
        53, "5", 54, "6", 55, "7", 56, "8", 57, "9",
        32, " ", 8, "[BS]", 9, "[TAB]", 13, "[ENTER]", 27, "[ESC]",
        37, "[LEFT]", 38, "[UP]", 39, "[RIGHT]", 40, "[DOWN]"
    )
    for vk, ch in QWERTY
        MAP[String(vk)] := ch
    return MAP
}




; ===================================
; ===================================
; ======= 6/ Tiny helpers =======
; ===================================
; ===================================

; Insertion sort over an Array of Strings (case-insensitive). Plenty fast
; for the typical "few dozen apps" range; AHK has no built-in Array.Sort.
KLPF_SortInPlace(arr) {
    n := arr.Length
    Loop n {
        i := A_Index
        j := i
        while (j > 1 && StrCompare(arr[j], arr[j - 1], false) < 0) {
            tmp := arr[j]
            arr[j] := arr[j - 1]
            arr[j - 1] := tmp
            j -= 1
        }
    }
}
