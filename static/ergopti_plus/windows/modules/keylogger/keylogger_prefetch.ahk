; modules/keylogger/keylogger_prefetch.ahk

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
; ==================================
; ======= 1/ Path resolution =======
; ==================================
; =====================================

; Resolve the dashboard assets folder for a given page key (« typing »
; or « apps »). The dashboards live under
; ``<repo>/static/ergopti_plus/_shared/ui/metrics_<key>/``.
KLPF_AssetsDir(which) {
    global _SharedDir
    base := _SharedDir . "\ui\metrics_" . which . "\"
    loop files, base, "D"
        return A_LoopFileFullPath . "\"
    return base
}

; The prefetch file is written to the system temp folder to avoid
; polluting the repository with generated runtime data. The page reads
; it via a file:// URL extracted from the #prefetch= hash fragment
; injected into the --app= URL by KLUI_ResolveAssetUrl.
KLPF_PrefetchPath(which) {
    return A_Temp . "\ergopti_metrics_prefetch_" . which . ".json"
}

; Background projection protocol.  A projection is CPU/SQLite heavy enough to
; exceed the keyboard hook timeout, so the foreground driver only starts a
; disposable AHK worker and atomically publishes its finished staging file.
; The monotonic generation is the ownership fence: a cancelled/late worker can
; finish, but can never replace a newer dashboard result.
class KLPFWorker {
    static generation := 0
    static jobs := Map()
    ; Test seam: production leaves this at 0 and always uses ShellRunner.
    static spawn_fn := 0
}

KLPF_IsWorkerInvocation() {
    for _, arg in A_Args {
        if (arg = "--keylogger-prefetch-worker")
            return true
    }
    return false
}

KLPF_RequestBuild(which, metrics_dir, mode := "full", epoch := 0, on_ready := unset) {
    global _ConfigDir
    if A_IsSuspended || (which != "typing" && which != "apps") || (metrics_dir = "")
        return false

    KLPF_CancelBuild(which)

    generation := ++KLPFWorker.generation
    stage := KLPF_PrefetchPath(which) . ".stage." . generation
    try FileDelete(stage)
    executable := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
    args := A_IsCompiled
        ? ["/force", "--keylogger-prefetch-worker", which, metrics_dir, mode, stage, _ConfigDir,
            KLWConst.MAX_KEYSTROKE_DELAY_MS, KLWConst.THINK_PAUSE_MS, KLWConst.BURST_GAP_MS,
            KLWConst.SESSION_GAP_MS, KLWConst.AUTO_REPEAT_MAX_DELAY_MS, KLWConst.HOLD_THRESHOLD_MS]
        : ["/force", A_ScriptFullPath, "--keylogger-prefetch-worker", which, metrics_dir, mode, stage, _ConfigDir,
            KLWConst.MAX_KEYSTROKE_DELAY_MS, KLWConst.THINK_PAUSE_MS, KLWConst.BURST_GAP_MS,
            KLWConst.SESSION_GAP_MS, KLWConst.AUTO_REPEAT_MAX_DELAY_MS, KLWConst.HOLD_THRESHOLD_MS]
    done := KLPF_OnWorkerDone.Bind(which, generation)
    spawn := IsObject(KLPFWorker.spawn_fn) ? KLPFWorker.spawn_fn : ShellRunner_Spawn
    handle := spawn.Call(executable, args, done)
    if !handle.start()
        return false
    KLPFWorker.jobs[which] := Map(
        "generation", generation,
        "epoch", epoch,
        "stage", stage,
        "handle", handle,
        "kind", "prefetch",
        "on_ready", IsSet(on_ready) ? on_ready : 0
    )
    return true
}

KLPF_RequestRange(which, metrics_dir, query, epoch := 0, on_ready := unset) {
    global _ConfigDir
    if A_IsSuspended || (which != "typing") || (metrics_dir = "") || !(query is Map)
        return false
    job_key := "range:" . which
    KLPF_CancelBuild(job_key)
    generation := ++KLPFWorker.generation
    stage := A_Temp . "\ergopti_metrics_range_" . which . ".stage." . generation . ".json"
    try FileDelete(stage)
    apps_json := KL_JsonEncode(query["apps"])
    executable := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
    args := A_IsCompiled
        ? ["/force", "--keylogger-prefetch-worker", which, metrics_dir, "range", stage, _ConfigDir,
            KLWConst.MAX_KEYSTROKE_DELAY_MS, KLWConst.THINK_PAUSE_MS, KLWConst.BURST_GAP_MS,
            KLWConst.SESSION_GAP_MS, KLWConst.AUTO_REPEAT_MAX_DELAY_MS, KLWConst.HOLD_THRESHOLD_MS,
            query["start_date"], query["end_date"], apps_json]
        : ["/force", A_ScriptFullPath, "--keylogger-prefetch-worker", which, metrics_dir, "range", stage, _ConfigDir,
            KLWConst.MAX_KEYSTROKE_DELAY_MS, KLWConst.THINK_PAUSE_MS, KLWConst.BURST_GAP_MS,
            KLWConst.SESSION_GAP_MS, KLWConst.AUTO_REPEAT_MAX_DELAY_MS, KLWConst.HOLD_THRESHOLD_MS,
            query["start_date"], query["end_date"], apps_json]
    done := KLPF_OnWorkerDone.Bind(job_key, generation)
    spawn := IsObject(KLPFWorker.spawn_fn) ? KLPFWorker.spawn_fn : ShellRunner_Spawn
    handle := spawn.Call(executable, args, done)
    if !handle.start()
        return false
    KLPFWorker.jobs[job_key] := Map(
        "generation", generation,
        "epoch", epoch,
        "stage", stage,
        "handle", handle,
        "kind", "range",
        "on_ready", IsSet(on_ready) ? on_ready : 0
    )
    return true
}

KLPF_CancelBuild(which) {
    if !KLPFWorker.jobs.Has(which)
        return
    job := KLPFWorker.jobs[which]
    try job["handle"].terminate()
    try FileDelete(job["stage"])
    KLPFWorker.jobs.Delete(which)
}

KLPF_OnWorkerDone(which, generation, exit_code, stdout, stderr) {
    if !KLPFWorker.jobs.Has(which)
        return
    job := KLPFWorker.jobs[which]
    if (job["generation"] != generation)
        return
    KLPFWorker.jobs.Delete(which)
    stage := job["stage"]
    if A_IsSuspended || (exit_code != 0) || !FileExist(stage) {
        try FileDelete(stage)
        try LoggerWarn("KLReader", "Background metrics projection failed for '{1}' (exit={2}).", which, exit_code)
        return
    }
    if (job["kind"] = "range") {
        if IsObject(job["on_ready"]) {
            try job["on_ready"].Call(SubStr(which, 7), job["epoch"], stage)
        } else {
            try FileDelete(stage)
        }
        return
    }
    if !KLPF_MoveAtomic(stage, KLPF_PrefetchPath(which)) {
        try FileDelete(stage)
        try LoggerError("KLReader", "Background metrics projection could not publish '{1}'.", which)
        return
    }
    if IsObject(job["on_ready"])
        try job["on_ready"].Call(which, job["epoch"])
}

; Runs in the detached /force instance.  It exits before the normal boot block,
; so it never registers a hook, hotkey, timer, tray menu, or WebView callback.
KLPF_WorkerMain() {
    if !KLPF_IsWorkerInvocation()
        return false
    if (A_Args.Length < 12)
        ExitApp(2)
    which := A_Args[2]
    metrics_dir := A_Args[3]
    mode := A_Args[4]
    stage := A_Args[5]
    global _ConfigDir, _AhkSubDir
    _ConfigDir := A_Args[6]
    _AhkSubDir := "autohotkey\"
    try {
        KLWConst.MAX_KEYSTROKE_DELAY_MS := Integer(A_Args[7])
        KLWConst.THINK_PAUSE_MS := Integer(A_Args[8])
        KLWConst.BURST_GAP_MS := Integer(A_Args[9])
        KLWConst.SESSION_GAP_MS := Integer(A_Args[10])
        KLWConst.AUTO_REPEAT_MAX_DELAY_MS := Integer(A_Args[11])
        KLWConst.HOLD_THRESHOLD_MS := Integer(A_Args[12])
        if (which != "typing" && which != "apps") || (mode != "full" && mode != "live" && mode != "manifest" && mode != "range")
            ExitApp(2)
        if (mode = "range") {
            if (A_Args.Length < 15)
                ExitApp(2)
            apps := KL_JsonDecode(A_Args[15])
            if !(apps is Array)
                ExitApp(2)
            db := KLR_BuildDatabase(metrics_dir)
            if !db || !KLPF_WriteAtomic(stage, KL_JsonEncode(KLR_ReadRangeSplitToday(db, A_Args[13], A_Args[14], apps)))
                ExitApp(1)
        } else if !KLPF_BuildAndWriteToPath(which, metrics_dir, stage, "", mode) {
            ExitApp(1)
        }
    } catch {
        try FileDelete(stage)
        ExitApp(1)
    }
    ExitApp(0)
}





; ====================================
; ===============================
; ======= 2/ Public entry =======
; ===============================
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
    return KLPF_BuildAndWriteToPath(which, metrics_dir, KLPF_PrefetchPath(which), dbg, mode)
}

KLPF_BuildAndWriteToPath(which, metrics_dir, path, dbg := "", mode := "full") {
    if (dbg = "") {
        global _ConfigDir, _AhkSubDir
        try DirCreate(_ConfigDir . _AhkSubDir . "logs")
        dbg := _ConfigDir . _AhkSubDir . "logs\prefetch_debug.log"
    }
    KLPF_DbgWrite(dbg, "=== " . A_Now . " — which=" . which . " mode=" . mode)
    t0 := A_TickCount

    db := KLR_BuildDatabase(metrics_dir)
    if !db {
        KLPF_DbgWrite(dbg, "FAIL: KLR_BuildDatabase returned 0")
        try LoggerError("KLReader", "Metrics DB build failed (winsqlite3.dll/schema.sql/data.sql) — dashboard '{1}' shows no data.", which)
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

    written := KLPF_WriteAtomic(path, json)
    t_write := A_TickCount
    KLPF_DbgWrite(dbg, "PERF write=" . (t_write - t_json) . "ms total=" . (t_write - t0) . "ms")
    return written
}

KLPF_DbgWrite(path, line) {
    try FileAppend(line . "`r`n", path, "UTF-8")
}

KLPF_WriteAtomic(path, content) {
    ; Publish the tmp file onto ``path`` with the same atomic-rename primitive
    ; KL_WriteAtomic (keylogger.ahk) uses: MoveFileExW(MOVEFILE_REPLACE_EXISTING
    ; | MOVEFILE_WRITE_THROUGH) is a kernel-level directory-entry swap with NO
    ; absent-file window. The previous delete-then-move sequence left
    ; a gap where the destination did not exist — a dashboard fetch('./prefetch.json')
    ; landing between the two saw a 404, and an AV/indexer transiently holding
    ; the freshly-deleted name made the move fail with no retry, stranding the
    ; page on stale data. We retry the rename once to ride out a transient AV /
    ; indexer lock before giving up.
    ;
    ; The tmp write stays UTF-8-RAW (no BOM): the JSON is fetched and parsed by
    ; the dashboard, and we never want a BOM in the served blob. The function
    ; keeps its boolean contract — false leaves the previous prefetch file
    ; intact so the page degrades to old data rather than to an empty state.
    static MOVEFILE_REPLACE_EXISTING := 0x1
    static MOVEFILE_WRITE_THROUGH    := 0x8
    static FLAGS := MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH
    static RETRY_DELAY_MS            := 50

    tmp := path . ".tmp"
    try FileDelete(tmp)
    try FileAppend(content, tmp, "UTF-8-RAW")
    catch
        return false

    if !KLPF_MoveAtomic(tmp, path, FLAGS) {
        Sleep RETRY_DELAY_MS
        if !KLPF_MoveAtomic(tmp, path, FLAGS) {
            try FileDelete(tmp)
            return false
        }
    }
    return true
}

KLPF_MoveAtomic(source, destination, flags := unset) {
    static MOVEFILE_REPLACE_EXISTING := 0x1
    static MOVEFILE_WRITE_THROUGH := 0x8
    if !IsSet(flags)
        flags := MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH
    return DllCall("Kernel32\MoveFileExW", "Str", source, "Str", destination,
        "UInt", flags, "Int") != 0
}





; =========================================
; ========================================
; ======= 3/ Typing dashboard blob =======
; ========================================
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
; ======================================
; ======= 4/ Apps dashboard blob =======
; ======================================
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
; ===========================================
; ======= 5/ Keycode layout (heatmap) =======
; ===========================================
; ============================================

; Build the « scancode → printable label » map for the heatmap. When
; the Ergopti base-layer emulation is enabled (Features["layout"]
; ["ergopti_base"]), we read the canonical mapping from
; modules/keymap/layout/layout_ergopti.ahk — the SAME data layout.ahk uses to install
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
; ===============================
; ======= 6/ Tiny helpers =======
; ===============================
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
