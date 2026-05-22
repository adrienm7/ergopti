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
    global _StaticDir
    base := _StaticDir . "\drivers\_shared\ui\metrics_" . which . "\"
    loop files, base, "D"
        return A_LoopFileFullPath . "\"
    return base
}

; The prefetch file lives alongside index.html and is loaded via fetch()
; on page boot. Earlier crashes against fetch() turned out to be caused
; by a query-string cache-buster on the URL; without it fetch works
; fine cross file:// in Edge --app= mode.
KLPF_PrefetchPath(which) {
    return KLPF_AssetsDir(which) . "prefetch.json"
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
; mode: "full" (default) — manifest + n-grams + range data.
;       "manifest" — skip n-grams. Used by the fast 500 ms flush tick
;       so the dashboard’s KPI counters update near-instantly without
;       paying the ~2-3 s n-gram projection + ~1 s JSON encode cost.
KLPF_BuildAndWrite(which, metrics_dir, dbg := "", mode := "full") {
    if (dbg = "") {
        global _ConfigDir
        try DirCreate(_ConfigDir . "ahk\logs")
        dbg := _ConfigDir . "ahk\logs\prefetch_debug.log"
    }
    KLPF_DbgWrite(dbg, "=== " . A_Now . " — which=" . which . " mode=" . mode)
    t0 := A_TickCount

    db := KLR_BuildDatabase(metrics_dir)
    if !db {
        KLPF_DbgWrite(dbg, "FAIL: KLR_BuildDatabase returned 0")
        return false
    }
    t_db := A_TickCount
    KLPF_DbgWrite(dbg, "PERF db=" . (t_db - t0) . "ms")

    ; Cheap sanity probe — count agg_app_day rows so we know the data
    ; actually landed. SQLite_Query returns Array<Map>.
    rows := SQLite_Query(db, "SELECT COUNT(*) AS n FROM agg_app_day")
    n := (rows.Length > 0 && rows[1].Has("n")) ? rows[1]["n"] : "?"
    KLPF_DbgWrite(dbg, "agg_app_day row count = " . n)

    blob := Map()
    if (which = "typing") {
        blob := KLPF_BuildTyping(db, mode)
    } else if (which = "apps") {
        blob := KLPF_BuildApps(db)
    }
    ; Pull and remove the side-channel today JSON before encoding —
    ; it would otherwise leak into the output as "__klpf_today_json"
    ; and the placeholder substitution wouldn't fire.
    today_json_raw := ""
    if blob.Has("__klpf_today_json") {
        today_json_raw := blob["__klpf_today_json"]
        blob.Delete("__klpf_today_json")
    }
    t_proj := A_TickCount
    KLPF_DbgWrite(dbg, "PERF projection=" . (t_proj - t_db) . "ms")

    json := KL_JsonEncode(blob)
    if (today_json_raw != "") {
        ; Replace the quoted sentinel with the raw object literal so
        ; the final output is valid JSON: "today":<...> without the
        ; encoder having had to walk thousands of n-gram rows itself.
        json := StrReplace(json, '"__KLPF_TODAY_PLACEHOLDER__"', today_json_raw)
    }
    t_json := A_TickCount
    KLPF_DbgWrite(dbg, "PERF json_encode=" . (t_json - t_proj) . "ms len=" . StrLen(json))

    ; Cache JSON in memory so the WebView2 push path can skip the
    ; round-trip through disk. The Edge --app= fallback still reads
    ; the sidecar file from disk on first paint.
    global KLPF_LAST_JSON
    if !IsSet(KLPF_LAST_JSON)
        KLPF_LAST_JSON := Map()
    KLPF_LAST_JSON[which] := json

    path := KLPF_PrefetchPath(which)
    written := KLPF_WriteAtomic(path, json)
    t_write := A_TickCount
    KLPF_DbgWrite(dbg, "PERF write=" . (t_write - t_json) . "ms total=" . (t_write - t0) . "ms")
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

; Manifest cache: historical days never change once persisted, so we keep
; the full projection and only re-query today's row on live ticks. Drops
; the per-tick manifest cost from ~150 ms to ~20 ms.
global KLPF_MANIFEST_CACHE := unset

KLPF_BuildTyping(db, mode := "full") {
    global KLPF_MANIFEST_CACHE
    today := FormatTime(A_Now, "yyyy-MM-dd")
    use_cache := (mode = "live" || mode = "manifest") && IsSet(KLPF_MANIFEST_CACHE) && KLPF_MANIFEST_CACHE
    if use_cache {
        manifest := KLPF_MANIFEST_CACHE
        ; Re-project ONLY today's entry and overwrite that date in the cache.
        today_only := KLR_ReadManifest(db, today, today)
        if today_only.Has(today) {
            manifest[today] := today_only[today]
        } else if manifest.Has(today) {
            manifest.Delete(today)
        }
    } else {
        manifest := KLR_ReadManifest(db)
        KLPF_MANIFEST_CACHE := manifest
    }
    ; OS hint — the UI uses this to pick between the macOS keycode
    ; layout (kc) and the Windows scancode layout (sc_kb) when rendering
    ; the heatmap.
    driver_os := Map("os", "win", "heatmap_id", "sc_kb")

    blob := Map(
        "metrics_manifest", manifest,
        "app_icons", Map(),                      ; icon extraction is HS-only for now.
        "keycode_layout", KLPF_KeycodeLayout(),
        "driver_meta", driver_os
    )

    ; The full n-gram projection is the dominant cost (~2-3 s).
    ; Mode dispatch:
    ;   manifest — KPIs only, ~50 ms. Omits _prefetch_data so the JS
    ;              bootstrap keeps the existing n-gram tables.
    ;   live     — KPIs + today's top-500 n-grams across the most-
    ;              viewed tables (chars/bigrams/.../words). Historical
    ;              stays cached client-side from the first paint.
    ;              ~150-300 ms.
    ;   full     — full projection (default), used at first paint to
    ;              seed the historical block.
    if (mode = "manifest") {
        return blob
    }
    if (mode = "live") {
        ; Splice the SQL-built today JSON in as a magic placeholder
        ; the encoder leaves alone. KLPF_BuildAndWrite detects the
        ; sentinel and post-substitutes the real JSON string after
        ; KL_JsonEncode runs. This bypasses ~600 ms of per-row Map
        ; allocation + ~300 ms of AHK-side JSON encoding for the
        ; n-gram tables, dropping live-tick total to under 200 ms.
        apps_list := []
        for date_str, day_data in manifest {
            for app_name, _ in day_data {
                if (app_name = "Unknown")
                    continue
                apps_list.Push(app_name)
            }
        }
        today_json := KLR_BuildTodayIdxJson(db, apps_list)
        blob["_prefetch_data"] := Map(
            "historical", Map(),
            "today", "__KLPF_TODAY_PLACEHOLDER__"
        )
        blob["__klpf_today_json"] := today_json
        return blob
    }

    first_date := ""
    apps_set := Map()
    apps_list := []
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

    range_data := Map("historical", Map(), "today", Map())
    if (first_date != "")
        range_data := KLR_ReadRangeSplitToday(db, first_date, today, apps_list)
    blob["_prefetch_data"] := range_data
    return blob
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
        "metrics_manifest", manifest,
        "app_icons", Map()
    )
}

; ============================================
; ============================================
; ======= 5/ Keycode layout (heatmap) =======
; ============================================
; ============================================

; Build the « scancode → printable label » map for the heatmap. When
; the Ergopti base-layer emulation is enabled (Features["layout"]
; ["ergopti_base"]), we read the canonical mapping from
; lib/layout_ergopti.ahk — the SAME data layout.ahk uses to install
; the actual remaps. Otherwise we resolve each scancode through the
; active Windows keyboard layout using MapVirtualKeyEx(MAPVK_VK_TO_CHAR).
; The latter sidesteps the dead-key state ToUnicodeEx leaves behind —
; passing through a dead key (¨, ^, …) on AZERTY-fr would otherwise
; return the precomposed character of the next call (« Ä » instead
; of « a »).
KLPF_KeycodeLayout() {
    global Features
    out := Map()

    ergopti_active := IsSet(Features)
    && Features.Has("layout")
    && Features["layout"].Has("ergopti_base")
    && Features["layout"]["ergopti_base"] = true
    if ergopti_active {
        for sc, ch in ErgoptiBaseLabels()
            out[String(sc)] := ch
        return out
    }

    ; Resolve the active layout for the foreground window. Falls back
    ; to the script thread’s layout if the lookup fails.
    hkl := 0
    try {
        hwnd := DllCall("GetForegroundWindow", "ptr")
        tid := DllCall("GetWindowThreadProcessId", "ptr", hwnd, "ptr", 0, "uint")
        hkl := DllCall("GetKeyboardLayout", "uint", tid, "ptr")
    }
    if !hkl
        try hkl := DllCall("GetKeyboardLayout", "uint", 0, "ptr")

    loop 87 {
        sc := A_Index
        ; Skip scancodes the JS side overlays (modifiers, whitespace,
        ; F-row) so the AHK map stays out of its way.
        if (sc = 1 || sc = 14 || sc = 15 || sc = 28 || sc = 29
            || sc = 42 || sc = 54 || sc = 56 || sc = 57 || sc = 58
            || (sc >= 59 && sc <= 68) || sc = 87 || sc = 88)
            continue
        vk := DllCall("MapVirtualKeyExW", "uint", sc, "uint", 3, "ptr", hkl, "uint")
        if !vk
            continue
        ; MAPVK_VK_TO_CHAR (uMapType=2) — returns the unshifted Unicode
        ; codepoint in the low 16 bits. The top bit signals a dead key
        ; (¨, ^, …). The next-higher bits encode the dead-key class on
        ; some layouts; mask them all to keep the literal codepoint.
        raw := DllCall("MapVirtualKeyExW", "uint", vk, "uint", 2, "ptr", hkl, "uint")
        if !raw
            continue
        cp := raw & 0xFFFF
        ; Strip any pending dead-key flag — the heatmap label is the
        ; resting form (¨, ^), not the composed accent.
        if (raw & 0x80000000)
            cp := cp & 0x7FFF
        if (cp <= 0)
            continue
        ch := Chr(cp)
        if (ch = "")
            continue
        out[String(sc)] := ch
    }
    return out
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
    loop n {
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
