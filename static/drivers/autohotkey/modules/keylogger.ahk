; modules/keylogger.ahk

; ==============================================================================
; MODULE: Keylogger (AHK)
; DESCRIPTION:
; Windows port of the Hammerspoon keylogger. Mirrors the on-disk format
; specified in ../KEYLOGGER_SPEC.md byte-for-byte:
;
;   <config_dir>/metrics/by_device/<device_id>/device.json
;   <config_dir>/metrics/by_device/<device_id>/data.sql      (append-only SQL)
;   <config_dir>/metrics/by_device/<device_id>/today.log     (JSONL hot path)
;   <config_dir>/metrics/by_device/<device_id>/state.json    (small offset/counter file)
;
; FEATURES & RATIONALE:
; 1. SQLite-free hot path: this driver never opens db.sqlite. The launcher
;    (re)builds the cache from every device's data.sql on demand.
; 2. data.sql is the single source of truth on disk — Git-friendly,
;    sync-safe, identical to the Hammerspoon side so a Mac and a PC sharing
;    a cloud folder cumulate naturally.
; 3. Per-device subdirectory: each machine writes to its own folder (keyed
;    on a UUID derived from MachineGuid) so concurrent writers cannot
;    corrupt each other's files.
; 4. Crash-safe: today_log_offset is persisted in state.json on every
;    successful ingest tick. Replay is idempotent thanks to per-device
;    PRIMARY KEY (device_id, id) on every event table.
;
; SCOPE OF THIS PORT:
; The current iteration covers raw event persistence (typing, app_switch,
; window_switch, shortcut, hotstring, llm, system, session). The rich
; aggregation walker (n-grams, bursts, sessions, ergonomic streaks) is NOT
; yet ported; agg_* / ngram_* tables stay empty on Windows-only setups
; until the dedicated walker port lands. Mac users sharing a synced
; metrics folder cover this gap automatically: the HS walker on the Mac
; ingests the PC's data.sql via foreign-sync and populates the agg_*/
; ngram_* tables for every device's events.
;
; HOT PATH LATENCY (KL_AppendLog):
; Every cost on the keystroke flush path was scrutinised:
;   - Persistent FileObject handle for today.log (Section 3 KL_OpenTodayFh).
;     A FileAppend()-per-keystroke would re-open + close the file every
;     time, adding ~1 ms each on NTFS once an antivirus filter driver
;     hooks the path. Caching the handle drops that to a memcpy.
;   - Pre-encoded device_id SQL literal cached in Keylogger._device_id_lit.
;     Every INSERT used to call KL_SqlStr() on the same UUID; we now read
;     a static string instead.
;   - No fh.Flush() per call — OS-level write buffering already provides
;     sub-frame durability, and the ingest tick Flush()es before reading.
;   - JSON encoder is iterative (single string accumulator) so a flush of
;     50 events stays under one allocation per character.
;   - The only AHK-level work on the per-keystroke append is: array push
;     into Keylogger.buffer_events, two scalar increments. Real fsync
;     happens at most every 5 s in the ingest tick, never inline.
;
; PASSWORD FIELD FILTER:
; Marked TODO_UIA below. The proper Windows implementation uses UIA's
; IsPasswordPattern in combination with the focused control type and class
; name. See KEYLOGGER_SPEC §6 — to be done in a dedicated session.
; ==============================================================================

#Requires Autohotkey v2.0+




; ===================================
; ===================================
; ======= 1/ Constants =======
; ===================================
; ===================================

class KeylogConst {
    static INGEST_TICK_MS         := 5000     ; Background ingest tick.
    static INGEST_BATCH_LINES     := 5000     ; Max lines per ingest cycle.
    static THINK_PAUSE_MS         := 2000     ; Active vs thinking pause threshold.
    static WPM_MAX_DELAY_MS       := 5000     ; Outlier cap for WPM bucketing.
    static MIDNIGHT_CHECK_TICK_MS := 60000    ; Day rollover check cadence.
    static SCHEMA_VERSION         := 1
}




; ===================================
; ===================================
; ======= 2/ Module State =======
; ===================================
; ===================================

class Keylogger {
    static initialized      := false
    static device_id        := ""
    static device_obj       := Map()
    static metrics_dir      := ""
    static by_device_dir    := ""
    static device_json_path := ""
    static data_sql_path    := ""
    static today_log_path   := ""
    static gitignore_path   := ""
    static state_json_path  := ""

    ; Persisted state (state.json).
    static next_event_id    := 1
    static today_log_offset := 0
    static today_log_date   := ""

    ; Per-flush typing buffer.
    static buffer_events    := []          ; Array of [char, delay_ms, meta_obj]
    static buffer_text      := ""
    static rich_chunks      := []
    static last_time        := 0
    static last_flush_time  := 0
    static session_app      := "Unknown"
    static session_title    := ""
    static session_layout   := ""
    static session_url      := ""
    static session_field_role := ""
    static session_clicks   := 0
    static session_scrolls  := 0
    static mouse_distance   := 0
    static current_pause_ms := 0

    ; Timers (lifecycle).
    static _ingest_timer    := unset
    static _midnight_timer  := unset

    ; Logger reference (lib/logger.ahk).
    static log              := unset

    ; In-RAM queue of entries awaiting ingest. Populated by KL_AppendLog
    ; alongside the JSONL today.log write, drained by KL_IngestOnce.
    ; This avoids the round-trip through KL_JsonDecode (COM ScriptControl
    ; is x86-only and silently returns empty Maps on 64-bit AHK) which
    ; would otherwise leave data.sql empty even when today.log fills.
    static _pending_entries := []

    ; ─── Hot-path latency caches ─────────────────────────────────────────
    ; Keeping today.log open across calls eliminates the open+close cost
    ; on every keystroke flush (NTFS + antivirus filter drivers turn that
    ; into milliseconds otherwise). The handle is reopened on day rollover.
    static _today_fh        := unset
    static _today_fh_date   := ""
    ; Pre-escaped device_id literal — avoids re-running KL_SqlStr on every
    ; INSERT (the device_id never changes during a process lifetime).
    static _device_id_lit   := ""
}




; ============================================
; ============================================
; ======= 3/ Filesystem Helpers =======
; ============================================
; ============================================

KL_MkdirP(path) {
    ; AHK DirCreate is mkdir -p equivalent — no-op if directory exists.
    try DirCreate(path)
}

KL_FileExists(path) {
    return FileExist(path) ? true : false
}

KL_ReadAll(path) {
    if !FileExist(path)
        return ""
    return FileRead(path, "UTF-8")
}

KL_WriteAtomic(path, content) {
    ; Write via .tmp + rename so a crash mid-write cannot corrupt the file.
    tmp := path . ".tmp"
    try FileDelete(tmp)
    FileAppend(content, tmp, "UTF-8")
    if FileExist(path)
        FileDelete(path)
    FileMove(tmp, path)
}

KL_AppendLine(path, line) {
    ; Append a single JSONL line with explicit newline. UTF-8 always.
    ; Slow fallback path — AppendLog uses the cached file handle instead.
    FileAppend(line . "`n", path, "UTF-8")
}

KL_OpenTodayFh() {
    ; Open today.log for append with shared-read mode so a tail -f / git diff
    ; can inspect the file without blocking us. The handle stays open until
    ; the script exits or the day rolls over.
    today := KL_Today()
    if Keylogger.HasOwnProp("_today_fh") && IsObject(Keylogger._today_fh)
        && Keylogger._today_fh_date = today
        return Keylogger._today_fh
    if Keylogger.HasOwnProp("_today_fh") && IsObject(Keylogger._today_fh) {
        try Keylogger._today_fh.Close()
    }
    fh := FileOpen(Keylogger.today_log_path, "a", "UTF-8")
    Keylogger._today_fh      := fh
    Keylogger._today_fh_date := today
    return fh
}

KL_CloseTodayFh() {
    if Keylogger.HasOwnProp("_today_fh") && IsObject(Keylogger._today_fh) {
        try Keylogger._today_fh.Close()
        Keylogger._today_fh := unset
        Keylogger._today_fh_date := ""
    }
}




; =====================================
; =====================================
; ======= 4/ Path Resolution =======
; =====================================
; =====================================

KL_ResolveTmpdir() {
    tmp := EnvGet("TMP")
    if (tmp = "")
        tmp := EnvGet("TEMP")
    if (tmp = "")
        tmp := A_Temp
    return RTrim(tmp, "\/") . "\"
}

KL_ResolvePaths(metrics_dir, device_id) {
    md := metrics_dir
    if !RegExMatch(md, "[\\/]$")
        md .= "\"
    by_dev := md . "by_device\" . device_id . "\"

    Keylogger.metrics_dir      := md
    Keylogger.by_device_dir    := by_dev
    Keylogger.device_json_path := by_dev . "device.json"
    Keylogger.data_sql_path    := by_dev . "data.sql"
    Keylogger.today_log_path   := by_dev . "today.log"
    Keylogger.state_json_path  := by_dev . "state.json"
    Keylogger.gitignore_path   := md   . ".gitignore"
}

KL_EnsureGitignore() {
    if FileExist(Keylogger.gitignore_path)
        return
    body := "# Local hot-path log — never commit, never sync.`n"
         .  "# One writer per device; another machine appending here would`n"
         .  "# corrupt the file. Ingested into data.sql by the keylogger.`n"
         .  "today.log`n"
    FileAppend(body, Keylogger.gitignore_path, "UTF-8")
}




; ============================================
; ============================================
; ======= 5/ Device Identity =======
; ============================================
; ============================================

KL_HostSignature() {
    ; Use HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid — stable per OS
    ; install, mirrors the macOS IOPlatformUUID role.
    try {
        guid := RegRead("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography", "MachineGuid")
        if (guid != "")
            return guid
    }
    return "fallback:" . A_ComputerName
}

KL_UuidV4() {
    ; CoCreateGuid via DllCall, formatted RFC 4122.
    guid_buf := Buffer(16, 0)
    DllCall("ole32\CoCreateGuid", "Ptr", guid_buf)
    bytes := []
    Loop 16
        bytes.Push(NumGet(guid_buf, A_Index - 1, "UChar"))
    return Format("{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        (bytes[1] << 24) | (bytes[2] << 16) | (bytes[3] << 8) | bytes[4],
        (bytes[5] << 8) | bytes[6],
        (bytes[7] << 8) | bytes[8],
        (bytes[9] << 8) | bytes[10],
        (bytes[11] << 40) | (bytes[12] << 32) | (bytes[13] << 24) | (bytes[14] << 16) | (bytes[15] << 8) | bytes[16])
}

KL_NowTimestamp() {
    ; "YYYY-MM-DD HH:MM:SS.mmm"
    base := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
    ms   := A_MSec
    return base . "." . Format("{:03d}", ms)
}

KL_Today() {
    return FormatTime(A_Now, "yyyy-MM-dd")
}

KL_ResolveDevice(metrics_dir) {
    md := metrics_dir
    if !RegExMatch(md, "[\\/]$")
        md .= "\"
    by_root := md . "by_device\"
    KL_MkdirP(by_root)

    current_host := KL_HostSignature()

    ; Scan existing device folders, reuse the one whose host_signature
    ; matches this machine.
    ;
    ; We use a regex over the raw bytes rather than a full JSON parse —
    ; AHK v2 64-bit has no built-in JSON decoder and the COM
    ; ScriptControl bridge we used initially is x86-only, which made
    ; this scan silently fail on 64-bit hosts and mint a new device
    ; folder on every reload. The shape of device.json is fixed (we
    ; write it ourselves), so a targeted regex is both faster and
    ; impervious to the bitness mismatch.
    if DirExist(by_root) {
        Loop Files, by_root . "*", "D" {
            djpath := A_LoopFileFullPath . "\device.json"
            if FileExist(djpath) {
                try {
                    raw := FileRead(djpath, "UTF-8")
                    if RegExMatch(raw, '"host_signature"\s*:\s*"([^"]+)"', &m) {
                        if (m[1] = current_host) {
                            ; Reconstruct the minimal Map we need from
                            ; the same raw blob — same regex trick.
                            obj := Map(
                                "device_id",      "",
                                "name",           "",
                                "os",             "windows",
                                "os_version",     "",
                                "host_signature", current_host,
                                "created_at",     "",
                                "schema_version", KeylogConst.SCHEMA_VERSION
                            )
                            for field in ["device_id", "name", "os", "os_version", "created_at"] {
                                if RegExMatch(raw, '"' . field . '"\s*:\s*"([^"]+)"', &mm)
                                    obj[field] := mm[1]
                            }
                            return obj
                        }
                    }
                }
            }
        }
    }

    ; Fresh install or clone-from-other-device → mint a new identity.
    obj := Map(
        "device_id",      KL_UuidV4(),
        "name",           A_ComputerName,
        "os",             "windows",
        "os_version",     A_OSVersion,
        "host_signature", current_host,
        "created_at",     KL_NowTimestamp(),
        "schema_version", KeylogConst.SCHEMA_VERSION
    )
    return obj
}

KL_WriteDeviceJson(obj) {
    KL_WriteAtomic(Keylogger.device_json_path, KL_JsonEncode(obj))
}




; ===========================================
; ===========================================
; ======= 6/ State persistence =======
; ===========================================
; ===========================================

KL_LoadState() {
    if !FileExist(Keylogger.state_json_path)
        return
    try {
        raw := FileRead(Keylogger.state_json_path, "UTF-8")
        s   := KL_JsonDecode(raw)
        if !(s is Map)
            return
        if s.Has("next_event_id")    && IsNumber(s["next_event_id"])
            Keylogger.next_event_id    := Integer(s["next_event_id"])
        if s.Has("today_log_offset") && IsNumber(s["today_log_offset"])
            Keylogger.today_log_offset := Integer(s["today_log_offset"])
        if s.Has("today_log_date")
            Keylogger.today_log_date   := String(s["today_log_date"])
        ; Restore the walker context if present. A missing key is fine:
        ; the walker rebuilds context on the next typing entry.
        if s.Has("ngram_ctx") {
            try KLW_RestoreCtx(s["ngram_ctx"])
        }
    }
}

KL_SaveState() {
    ngram_ctx := Map()
    try ngram_ctx := KLW_SerializeCtx()
    s := Map(
        "next_event_id",    Keylogger.next_event_id,
        "today_log_offset", Keylogger.today_log_offset,
        "today_log_date",   Keylogger.today_log_date,
        "ngram_ctx",        ngram_ctx
    )
    KL_WriteAtomic(Keylogger.state_json_path, KL_JsonEncode(s))
}




; =================================
; =================================
; ======= 7/ JSON helpers =======
; =================================
; =================================
; AHK v2 ships no built-in JSON parser. We use a minimal encoder/decoder
; tailored for our types (Maps, Arrays, strings, numbers, booleans, null).
; For larger payloads (events array on typing flush) the encoder emits a
; compact one-line representation suitable for JSONL.

KL_JsonEncode(v) {
    if (v = "")           ; AHK distinguishes empty string from unset.
        return "`"`""
    if v is Map
        return KL_JsonEncodeMap(v)
    if v is Array
        return KL_JsonEncodeArray(v)
    if (v is Number)
        return String(v)
    if (Type(v) = "String")
        return KL_JsonEncodeString(v)
    if (v = true)
        return "true"
    if (v = false)
        return "false"
    return "null"
}

KL_JsonEncodeString(s) {
    out := ""
    Loop Parse, s {
        c := A_LoopField
        switch c {
            case '"' : out .= '\"'
            case '\' : out .= '\\'
            case '`n': out .= '\n'
            case '`r': out .= '\r'
            case '`t': out .= '\t'
            case '`b': out .= '\b'
            case '`f': out .= '\f'
            default:
                code := Ord(c)
                if (code < 0x20)
                    out .= Format('\u{:04x}', code)
                else
                    out .= c
        }
    }
    return '"' . out . '"'
}

KL_JsonEncodeMap(m) {
    parts := []
    for k, v in m
        parts.Push(KL_JsonEncodeString(String(k)) . ":" . KL_JsonEncode(v))
    return "{" . KL_JoinArray(parts, ",") . "}"
}

KL_JsonEncodeArray(a) {
    parts := []
    for v in a
        parts.Push(KL_JsonEncode(v))
    return "[" . KL_JoinArray(parts, ",") . "]"
}

KL_JoinArray(arr, sep) {
    out := ""
    for i, v in arr
        out .= (i = 1 ? "" : sep) . v
    return out
}

KL_JsonDecode(s) {
    ; AHK 2 has no built-in. Use COM ScriptControl bridge — works on every
    ; Windows install with cscript-compatible scripting. For our use case
    ; (small device.json / state.json) the perf cost is negligible.
    static sc := ""
    if (sc = "") {
        try sc := ComObject("ScriptControl")
        catch
            return Map()
        sc.Language := "JScript"
    }
    try {
        ; Wrap in parens so JS evaluates as expression, not block.
        result := sc.Eval("(function(){return " . s . ";})()")
        return KL_ComToMap(result)
    }
    return Map()
}

KL_ComToMap(v) {
    ; ScriptControl returns COM JS objects; recursively convert to Map/Array.
    if !IsObject(v)
        return v
    ; Try array indexing.
    try {
        if (HasProp(v, "length")) {
            arr := []
            Loop v.length
                arr.Push(KL_ComToMap(v[A_Index - 1]))
            return arr
        }
    }
    out := Map()
    try {
        for prop in v
            out[prop] := KL_ComToMap(v[prop])
    }
    return out
}




; ============================================
; ============================================
; ======= 8/ Hot path — append_log =======
; ============================================
; ============================================

KL_AppendLog(entry) {
    ; Hot path. Optimisations applied (see Section 2 latency caches):
    ;  - persistent FileObject handle: avoids open/close ≈ 0.5-2 ms each
    ;    that NTFS + AV filter drivers tax on every keystroke flush;
    ;  - direct fh.Write() instead of FileAppend(): bypasses the PATH
    ;    re-resolution and locale-encoding negotiation that FileAppend
    ;    redoes on every call;
    ;  - no FormatTime when timestamp is already set by the caller.
    if !Keylogger.initialized
        return
    if !(entry is Map) || !entry.Has("type")
        return
    ; Privacy filters — drop anything captured while the focused window is
    ; on the user's exclusion list, in private browsing, or in a system-
    ; auth dialog. The check is cached for ~250 ms so the per-keystroke
    ; cost is negligible. Wrapped in try so an unloaded module degrades
    ; gracefully (filters stay off rather than crashing the hot path).
    filtered := false
    try filtered := MF_ShouldFilter()
    if filtered
        return
    if !entry.Has("timestamp")
        entry["timestamp"] := KL_NowTimestamp()
    ; Queue the live Map for the ingest tick — no JSON round-trip needed
    ; for entries originating in this process.
    Keylogger._pending_entries.Push(entry)
    line := KL_JsonEncode(entry)
    line := StrReplace(line, "`n", "\n")
    line := StrReplace(line, "`r", "")
    fh := KL_OpenTodayFh()
    if !IsObject(fh)
        return
    fh.Write(line . "`n")
    ; No fh.Flush() per call — the OS / FileObject already buffers efficiently
    ; and a crash recovery would only lose a few hundred ms of in-flight events.
    ; The ingest tick does its own Flush before reading.
}




; ===========================================
; ===========================================
; ======= 9/ flush_buffer (typing) =======
; ===========================================
; ===========================================

KL_FlushBuffer() {
    if !Keylogger.initialized
        return
    if (Keylogger.buffer_events.Length = 0
        && Keylogger.session_clicks  = 0
        && Keylogger.session_scrolls = 0)
        return

    total_time_ms := 0
    total_chars   := 0
    for ev in Keylogger.buffer_events {
        meta := ev[3]
        if !(meta is Map) || !meta.Has("s") || !meta["s"] {
            d := ev[2]
            if (d > KeylogConst.WPM_MAX_DELAY_MS)
                d := KeylogConst.WPM_MAX_DELAY_MS
            total_time_ms += d
            total_chars   += 1
        }
    }
    wpm := (total_time_ms > 0) ? ((total_chars / 5) / (total_time_ms / 60000)) : 0

    app_cat := "unknown"
    try app_cat := KL_AppCat_Get(Keylogger.session_app)

    entry := Map(
        "type",              "typing",
        "text",              Keylogger.buffer_text,
        "rich_text",         "",
        "app",               Keylogger.session_app,
        "app_category",      app_cat,
        "title",             Keylogger.session_title,
        "url",               Keylogger.session_url,
        "field_role",        Keylogger.session_field_role,
        "layout",            Keylogger.session_layout,
        "is_fullscreen",     0,
        "in_meeting",        0,
        "mouse_clicks",      Keylogger.session_clicks,
        "mouse_scrolls",     Keylogger.session_scrolls,
        "mouse_distance_px", Keylogger.mouse_distance,
        "pause_before_ms",   Keylogger.current_pause_ms,
        "wpm",               Round(wpm, 1),
        "events",            Keylogger.buffer_events
    )
    KL_AppendLog(entry)

    Keylogger.buffer_events    := []
    Keylogger.buffer_text      := ""
    Keylogger.rich_chunks      := []
    Keylogger.last_time        := 0
    Keylogger.session_clicks   := 0
    Keylogger.session_scrolls  := 0
    Keylogger.mouse_distance   := 0
    Keylogger.last_flush_time  := A_TickCount
}




; ============================================================
; ============================================================
; ======= 10/ Public log_* event entry points =======
; ============================================================
; ============================================================

KL_LogAppSwitch(prev_app, next_app, duration_ms := 0) {
    KL_AppendLog(Map(
        "type",        "app_switch",
        "prev_app",    prev_app,
        "next_app",    next_app,
        "duration_ms", duration_ms
    ))
}

KL_LogWindowSwitch(app_name, prev_title, next_title, duration_ms := 0) {
    KL_AppendLog(Map(
        "type",        "window_switch",
        "app",         app_name,
        "prev_title",  prev_title,
        "next_title",  next_title,
        "duration_ms", duration_ms
    ))
}

KL_LogShortcut(shortcut_key, app_name := "Unknown") {
    if (shortcut_key = "")
        return
    KL_AppendLog(Map(
        "type", "shortcut",
        "key",  shortcut_key,
        "app",  app_name
    ))
}

KL_LogSystemEvent(action, metadata := unset) {
    e := Map("type", "system_event", "action", action)
    if IsSet(metadata) && (metadata is Map) {
        for k, v in metadata
            e[k] := v
    }
    KL_AppendLog(e)
}

; Logs a hotstring expansion event. Mirrors hammerspoon/modules/keylogger/init.lua:1148
; (M.log_hotstring) byte-for-byte:
;   - flushes the typing buffer FIRST so the fire is ordered after the
;     trigger characters that produced it,
;   - auto-computes ``net_saved_chars`` from StrLen so callers do not have
;     to (HS does the same with utf8.len),
;   - falls back to the session app when the caller omits ``app_name``,
;   - emits the same ``tag`` marker (`<hotstring>…</hotstring>`) HS writes.
KL_LogHotstring(trigger, replacement, h_type := "unknown", app_name := "") {
    if !Keylogger.initialized
        return
    KL_FlushBuffer()
    app := (app_name != "") ? app_name : Keylogger.session_app
    net_saved := StrLen(replacement) - StrLen(trigger)
    KL_AppendLog(Map(
        "type",            "hotstring",
        "app",             app,
        "trigger",         trigger,
        "replacement",     replacement,
        "h_type",          h_type,
        "net_saved_chars", net_saved,
        "tag",             "<hotstring>" . replacement . "</hotstring>"
    ))
    Keylogger.last_flush_time := A_TickCount
}

; Logs that a hotstring tooltip was shown to the user. Mirrors HS init.lua:1196.
; The call site (prefix watcher) drives suggested/dismissed pairing — there
; is at most one suggestion live at any time per device.
KL_LogHotstringSuggested(trigger, replacement, h_type := "unknown", app_name := "") {
    if !Keylogger.initialized
        return
    app := (app_name != "") ? app_name : Keylogger.session_app
    KL_AppendLog(Map(
        "type",        "hotstring_suggested",
        "app",         app,
        "trigger",     trigger,
        "replacement", replacement,
        "h_type",      h_type
    ))
}

; Logs that a previously-suggested hotstring tooltip was dismissed without
; firing. Mirrors HS init.lua:1214.
KL_LogHotstringDismissed(trigger, replacement, h_type := "unknown", app_name := "") {
    if !Keylogger.initialized
        return
    app := (app_name != "") ? app_name : Keylogger.session_app
    KL_AppendLog(Map(
        "type",        "hotstring_dismissed",
        "app",         app,
        "trigger",     trigger,
        "replacement", replacement,
        "h_type",      h_type
    ))
}

KL_LogLlm(kind, payload) {
    e := Map("type", "llm_" . kind)
    if (payload is Map) {
        for k, v in payload
            e[k] := v
    }
    KL_AppendLog(e)
}

KL_LogSession(kind, duration_ms := unset) {
    e := Map("type", kind)
    if IsSet(duration_ms)
        e["duration_ms"] := duration_ms
    KL_AppendLog(e)
}




; ============================================
; ============================================
; ======= 11/ SQL Builders =======
; ============================================
; ============================================
; Only INSERT statements are emitted from AHK. They go straight into
; data.sql; no SQLite is opened on the AHK side. The launcher rebuilds
; db.sqlite from data.sql on demand.

KL_SqlStr(s) {
    if (s = "" && !IsNumber(s))
        return "''"
    s := String(s)
    s := StrReplace(s, "'", "''")
    return "'" . s . "'"
}

KL_SqlNum(n) {
    if (n = "" || !IsNumber(n))
        return "NULL"
    if (n = true)
        return "1"
    if (n = false)
        return "0"
    return String(n)
}

KL_SqlNullable(s) {
    if (s = "")
        return "NULL"
    return KL_SqlStr(s)
}

KL_SqlJson(obj) {
    if !IsSet(obj) || obj = ""
        return "'{}'"
    return KL_SqlStr(KL_JsonEncode(obj))
}

KL_AllocEventId() {
    id := Keylogger.next_event_id
    Keylogger.next_event_id := id + 1
    return id
}

KL_BuildInsertTyping(e, id) {
    ts := e["timestamp"]
    return Format(
        "INSERT OR IGNORE INTO events_typing (device_id, id, ts, date, app, title, url, field_role, layout, document_path, is_fullscreen, in_meeting, mouse_clicks, mouse_scrolls, mouse_distance_px, pause_before_ms, battery_level, audio_volume, wpm, text, rich_text, events_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10}, {11}, {12}, {13}, {14}, {15}, {16}, {17}, {18}, {19}, {20}, {21}, {22});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlNullable(KL_GetMap(e, "title", "")),
        KL_SqlNullable(KL_GetMap(e, "url", "")),
        KL_SqlNullable(KL_GetMap(e, "field_role", "")),
        KL_SqlNullable(KL_GetMap(e, "layout", "")),
        KL_SqlNullable(KL_GetMap(e, "document_path", "")),
        KL_SqlNum(KL_GetMap(e, "is_fullscreen", 0)),
        KL_SqlNum(KL_GetMap(e, "in_meeting", 0)),
        KL_SqlNum(KL_GetMap(e, "mouse_clicks", 0)),
        KL_SqlNum(KL_GetMap(e, "mouse_scrolls", 0)),
        KL_SqlNum(KL_GetMap(e, "mouse_distance_px", 0)),
        KL_SqlNum(KL_GetMap(e, "pause_before_ms", 0)),
        KL_SqlNum(KL_GetMap(e, "battery_level", "")),
        KL_SqlNum(KL_GetMap(e, "audio_volume", "")),
        KL_SqlNum(KL_GetMap(e, "wpm", 0)),
        KL_SqlStr(KL_GetMap(e, "text", "")),
        KL_SqlNullable(KL_GetMap(e, "rich_text", "")),
        KL_SqlJson(KL_GetMap(e, "events", ""))
    )
}

KL_BuildInsertAppSwitch(e, id) {
    ts := e["timestamp"]
    return Format(
        "INSERT OR IGNORE INTO events_app_switch (device_id, id, ts, date, prev_app, next_app, duration_ms) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlNullable(KL_GetMap(e, "prev_app", "")),
        KL_SqlNullable(KL_GetMap(e, "next_app", "")),
        KL_SqlNum(KL_GetMap(e, "duration_ms", 0))
    )
}

KL_BuildInsertWindowSwitch(e, id) {
    ts := e["timestamp"]
    return Format(
        "INSERT OR IGNORE INTO events_window_switch (device_id, id, ts, date, app, prev_title, next_title, duration_ms) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7}, {8});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlNullable(KL_GetMap(e, "prev_title", "")),
        KL_SqlNullable(KL_GetMap(e, "next_title", "")),
        KL_SqlNum(KL_GetMap(e, "duration_ms", 0))
    )
}

KL_BuildInsertShortcut(e, id) {
    ts := e["timestamp"]
    return Format(
        "INSERT OR IGNORE INTO events_shortcut (device_id, id, ts, date, app, key) VALUES ({1}, {2}, {3}, {4}, {5}, {6});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlStr(KL_GetMap(e, "key", ""))
    )
}

KL_BuildInsertSystem(e, id) {
    ts   := e["timestamp"]
    meta := Map()
    for k, v in e {
        if (k != "type" && k != "timestamp" && k != "action")
            meta[k] := v
    }
    return Format(
        "INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(KL_GetMap(e, "action", "")),
        KL_SqlJson(meta)
    )
}

KL_BuildInsertHotstring(e, id, kind) {
    ts := e["timestamp"]
    return Format(
        "INSERT OR IGNORE INTO events_hotstring (device_id, id, ts, date, app, kind, trigger, replacement, h_type, net_saved_chars) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7}, {8}, {9}, {10});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlStr(kind),
        KL_SqlStr(KL_GetMap(e, "trigger", "")),
        KL_SqlStr(KL_GetMap(e, "replacement", "")),
        KL_SqlNullable(KL_GetMap(e, "h_type", "")),
        KL_SqlNum(KL_GetMap(e, "net_saved_chars", ""))
    )
}

KL_BuildInsertSession(e, id, kind) {
    ts := e["timestamp"]
    return Format(
        "INSERT OR IGNORE INTO events_session (device_id, id, ts, date, kind, duration_ms) VALUES ({1}, {2}, {3}, {4}, {5}, {6});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(kind),
        KL_SqlNum(KL_GetMap(e, "duration_ms", ""))
    )
}

KL_GetMap(m, key, default := "") {
    if (m is Map && m.Has(key))
        return m[key]
    return default
}

KL_BuildInserts(entry) {
    t := entry["type"]
    id := KL_AllocEventId()
    switch t {
        case "typing":              return [KL_BuildInsertTyping(entry, id)]
        case "app_switch":          return [KL_BuildInsertAppSwitch(entry, id)]
        case "window_switch":       return [KL_BuildInsertWindowSwitch(entry, id)]
        case "shortcut":            return [KL_BuildInsertShortcut(entry, id)]
        case "system_event":        return [KL_BuildInsertSystem(entry, id)]
        case "hotstring":           return [KL_BuildInsertHotstring(entry, id, "fired")]
        case "hotstring_suggested": return [KL_BuildInsertHotstring(entry, id, "suggested")]
        case "hotstring_dismissed":          return [KL_BuildInsertHotstring(entry, id, "dismissed")]
        case "hotstring_near_miss":
        case "manual_typed_known_trigger":   return [KL_BuildInsertHotstring(entry, id, t)]
        case "session_start":       return [KL_BuildInsertSession(entry, id, "session_start")]
        case "session_end":         return [KL_BuildInsertSession(entry, id, "session_end")]
        case "idle_start":          return [KL_BuildInsertSession(entry, id, "idle_start")]
        case "idle_end":            return [KL_BuildInsertSession(entry, id, "idle_end")]
        case "ergo_event":              return [KL_BuildInsertErgoEvent(entry, id)]
        case "window_resize":
        case "window_move":
        case "window_state_change":
        case "monitor_focus_change":
        case "virtual_desktop_switch": return [KL_BuildInsertWindowTopoEvent(entry, id)]
        case "mouse_click":
        case "mouse_drag":
        case "mouse_scroll":
        case "mouse_idle_park":     return [KL_BuildInsertMouseEvent(entry, id)]
    }
    ; Unknown type — silently skip; future schemas may handle it on replay.
    return []
}

KL_BuildInsertWindowTopoEvent(e, id) {
    ts   := e["timestamp"]
    t    := e["type"]
    meta := Map()
    for k, v in e {
        if (k != "type" && k != "timestamp" && k != "app")
            meta[k] := v
    }
    return Format(
        "INSERT OR IGNORE INTO events_window_topo (device_id, id, ts, date, kind, app, meta_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(t),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlJson(meta)
    )
}

KL_BuildInsertErgoEvent(e, id) {
    ts   := e["timestamp"]
    meta := Map()
    for k, v in e {
        if (k != "type" && k != "timestamp" && k != "kind" && k != "app")
            meta[k] := v
    }
    return Format(
        "INSERT OR IGNORE INTO events_ergo (device_id, id, ts, date, kind, app, meta_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(KL_GetMap(e, "kind", "")),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlJson(meta)
    )
}

KL_BuildInsertMouseEvent(e, id) {
    ts   := e["timestamp"]
    t    := e["type"]
    meta := Map()
    for k, v in e {
        if (k != "type" && k != "timestamp" && k != "app")
            meta[k] := v
    }
    return Format(
        "INSERT OR IGNORE INTO events_mouse (device_id, id, ts, date, kind, app, meta_json) VALUES ({1}, {2}, {3}, {4}, {5}, {6}, {7});",
        Keylogger._device_id_lit, id,
        KL_SqlStr(ts), KL_SqlStr(SubStr(ts, 1, 10)),
        KL_SqlStr(t),
        KL_SqlStr(KL_GetMap(e, "app", "Unknown")),
        KL_SqlJson(meta)
    )
}




; ===============================
; ===============================
; ======= 12/ Ingest Tick =======
; ===============================
; ===============================

KL_ReadNewTodayLog() {
    today := KL_Today()
    if (Keylogger.today_log_date != "" && Keylogger.today_log_date != today) {
        Keylogger.today_log_date   := today
        Keylogger.today_log_offset := 0
    }
    if (Keylogger.today_log_date = "")
        Keylogger.today_log_date := today

    if !FileExist(Keylogger.today_log_path)
        return [Keylogger.today_log_offset, []]

    ; Flush the writer's pending buffer so the reader sees every line that
    ; the hot path appended since the last tick — without this, in-flight
    ; events stay invisible until OS buffer pressure forces a flush.
    if Keylogger.HasOwnProp("_today_fh") && IsObject(Keylogger._today_fh) {
        try Keylogger._today_fh.RawWriteFlush := 0  ; no-op, kept as a marker
        try Keylogger._today_fh.Flush()
    }

    ; Read everything past current offset.
    fh := FileOpen(Keylogger.today_log_path, "r", "UTF-8")
    if !fh
        return [Keylogger.today_log_offset, []]
    fh.Seek(Keylogger.today_log_offset, 0)

    entries := []
    lines   := 0
    while (lines < KeylogConst.INGEST_BATCH_LINES && !fh.AtEOF) {
        line := fh.ReadLine()
        if (line = "")
            continue
        try {
            entry := KL_JsonDecode(line)
            if (entry is Map && entry.Has("type"))
                entries.Push(entry)
        }
        lines += 1
    }
    new_offset := fh.Pos
    fh.Close()
    return [new_offset, entries]
}

KL_IngestOnce() {
    if !Keylogger.initialized
        return
    ; Prefer the in-RAM queue when available — it sidesteps KL_JsonDecode
    ; entirely (COM ScriptControl is x86-only and silently empties Maps
    ; on 64-bit hosts). The JSONL pass is still used to drain anything
    ; that landed on disk while this process was not running.
    pair := KL_ReadNewTodayLog()
    new_offset := pair[1]
    entries    := pair[2]
    if (Keylogger._pending_entries.Length > 0) {
        for e in Keylogger._pending_entries
            entries.Push(e)
        Keylogger._pending_entries := []
    }
    if (entries.Length = 0) {
        ; Still advance today_log_offset so the cold-replay window keeps
        ; shrinking even when no entries were decodable on disk.
        if (new_offset != Keylogger.today_log_offset) {
            Keylogger.today_log_offset := new_offset
            KL_SaveState()
        }
        return
    }

    statements := []
    for entry in entries {
        for sql in KL_BuildInserts(entry)
            statements.Push(sql)
        ; Walk for aggregations (n-grams, bursts, sessions, …). The walker
        ; accumulates into KLW.batch; we flush below as a single SQL block
        ; appended to data.sql in the same transaction as the raw INSERTs.
        try {
            t := entry["type"]
            if (t = "typing") {
                KLW_WalkTypingEntry(entry)
            } else if (t = "app_switch") {
                KLW_WalkAppSwitch(entry)
            } else if (t = "window_switch") {
                KLW_WalkWindowSwitch(entry)
            } else if (t = "system_event") {
                KLW_WalkSystemEvent(entry)
            }
        }
    }
    agg_sql := ""
    try agg_sql := KLW_BuildBatchSql()

    if (statements.Length = 0 && agg_sql = "") {
        Keylogger.today_log_offset := new_offset
        KL_SaveState()
        return
    }

    body := "`n-- === ingest batch " . KL_NowTimestamp()
        .  " (offset " . Keylogger.today_log_offset
        .  " -> " . new_offset
        .  ", " . entries.Length . " entry(ies)) ===`nBEGIN TRANSACTION;`n"
    for sql in statements
        body .= sql . "`n"
    if (agg_sql != "")
        body .= agg_sql
    body .= "COMMIT;`n"

    try FileAppend(body, Keylogger.data_sql_path, "UTF-8")
    catch as err {
        ; Ingest failure must not lose data — leave today_log_offset alone
        ; so the next tick retries the same chunk. Log and bail.
        if Keylogger.HasProp("log") && IsObject(Keylogger.log)
            Keylogger.log.Error("Cannot append to data.sql: " . err.Message)
        return
    }
    Keylogger.today_log_offset := new_offset
    KL_SaveState()

    ; B niveau 2 hook: when the dashboard is hosted via WebView2, push
    ; the freshly-projected prefetch blob to the page so the user sees
    ; the new data without reloading. No-op when no WebView2 dashboards
    ; are open (KLWV.windows is empty) or the module is not loaded.
    try KLWV_NotifyIngest()
}

KL_DayRollover() {
    if !Keylogger.initialized
        return
    KL_IngestOnce()
    try FileAppend(
        "`n-- === day rollover " . Keylogger.today_log_date . " -> " . KL_Today() . " ===`n",
        Keylogger.data_sql_path, "UTF-8")
    KL_CloseTodayFh()  ; release the handle before deleting.
    try FileDelete(Keylogger.today_log_path)
    Keylogger.today_log_offset := 0
    Keylogger.today_log_date   := KL_Today()
    ; A new day starts every walker context fresh. Yesterday's partial
    ; word / streak / current_burst is meaningless at midnight.
    try KLW_DayRolloverReset()
    KL_SaveState()
}

KL_MidnightCheck() {
    if (Keylogger.today_log_date != "" && Keylogger.today_log_date != KL_Today())
        KL_DayRollover()
}




; ============================================================
; ============================================================
; ======= 13/ Password field filter (UIA + heuristics) =======
; ============================================================
; ============================================================
; Triple-layered detector — any positive layer returns true:
;
;   1. Win32 Edit class with ES_PASSWORD style
;      Native edit boxes (Win32 dialogs, old apps, RDP, Win Logon) expose
;      their password mode through ES_PASSWORD (0x20). Cheapest check.
;
;   2. Class-name allow-list
;      Some controls don't honour ES_PASSWORD but reliably advertise their
;      role via class name (e.g. WPF "PasswordBox", winforms RichEdit50W
;      hosted in credential dialogs).
;
;   3. UIA IsPasswordPattern (vendor/UIA.ahk)
;      The canonical UIA property — works for modern Edge/Chrome web
;      passwords, UWP password boxes, .NET WPF, Electron apps. Slowest
;      check, called last.
;
; The result is cached per-HWND for ``KLPW_CACHE_TTL_MS`` because UIA
; round-trips can take 5-15 ms; the focused control is unlikely to flip
; password-vs-not within a few hundred milliseconds.

global KLPW_CACHE_TTL_MS := 500

class KLPasswordCache {
    static last_hwnd := 0
    static last_at   := 0
    static last_val  := false
}

KL_IsFocusedFieldPassword() {
    hwnd := 0
    try hwnd := ControlGetFocus("A")
    if !hwnd
        try hwnd := WinGetID("A")
    if !hwnd
        return false

    ; Per-HWND cache.
    if (KLPasswordCache.last_hwnd = hwnd
        && (A_TickCount - KLPasswordCache.last_at) < KLPW_CACHE_TTL_MS)
        return KLPasswordCache.last_val

    result := KL_DetectPasswordFor(hwnd)
    KLPasswordCache.last_hwnd := hwnd
    KLPasswordCache.last_at   := A_TickCount
    KLPasswordCache.last_val  := result
    return result
}

KL_DetectPasswordFor(hwnd) {
    ; Layer 1 — ES_PASSWORD style on a Win32 Edit.
    try {
        cls := WinGetClass("ahk_id " . hwnd)
        if (cls = "Edit") {
            style := WinGetStyle("ahk_id " . hwnd)
            if (style & 0x20)   ; ES_PASSWORD
                return true
        }
        ; Layer 2 — known password class names.
        static PASSWORD_CLASSES := Map(
            "PasswordBox", true,           ; WPF / UWP
            "Edit;PASSWORD", true,         ; some older toolkits
            "TPasswordEdit", true,         ; Delphi
            "MaskedEdit", true,
            "TFormPassword", true
        )
        if PASSWORD_CLASSES.Has(cls)
            return true
        ; RichEdit50W is too generic to flag unconditionally — it only
        ; matters when hosted in a security dialog. Fall through to UIA.
    }

    ; Layer 3 — UIA.IsPasswordPattern. The vendor/UIA.ahk lib initialises
    ; the global ``UIA`` object on first use. Any failure (UIA not loaded,
    ; element not reachable) falls back to "not a password" so we keep
    ; logging by default — better-safe-but-noisy beats silent loss.
    if !IsSet(UIA)
        return false
    try {
        el := UIA.ElementFromHandle(hwnd)
        if !IsObject(el)
            return false
        ; IsPassword is exposed both as a direct property on the element
        ; (UIA-v2) and via the Pattern. Prefer the direct property; fall
        ; back to the pattern read.
        if el.HasOwnProp("IsPassword")
            return el.IsPassword ? true : false
        try
            return el.GetCurrentPropertyValue(UIA.Property.IsPassword) ? true : false
    }
    return false
}




; ============================================================
; ============================================================
; ======= 14/ Bootstrap data.sql =======
; ============================================================
; ============================================================

KL_BootstrapDataSql() {
    if FileExist(Keylogger.data_sql_path)
        return
    header := "-- ergopti metrics — device " . Keylogger.device_id
        .  " — schema_version " . KeylogConst.SCHEMA_VERSION . "`n"
        .  "-- This file is APPEND-ONLY. Do not edit by hand.`n"
        .  "-- The launcher rebuilds db.sqlite from this file on demand.`n"
        .  "PRAGMA foreign_keys = OFF;`n"
    FileAppend(header, Keylogger.data_sql_path, "UTF-8")
}




; ====================================
; ====================================
; ======= 15/ Lifecycle =======
; ====================================
; ====================================

KL_Init(metrics_dir) {
    if Keylogger.initialized
        return  ; idempotent.

    KL_MkdirP(metrics_dir)

    obj := KL_ResolveDevice(metrics_dir)
    Keylogger.device_obj := obj
    Keylogger.device_id  := obj["device_id"]

    Keylogger._device_id_lit := KL_SqlStr(Keylogger.device_id)
    KL_ResolvePaths(metrics_dir, Keylogger.device_id)
    KL_MkdirP(Keylogger.by_device_dir)
    KL_MkdirP(KL_ResolveTmpdir() . "ergopti_metrics\" . Keylogger.device_id)
    KL_EnsureGitignore()
    KL_WriteDeviceJson(obj)
    KL_LoadState()

    if (Keylogger.today_log_date = "")
        Keylogger.today_log_date := KL_Today()

    Keylogger.initialized := true
    KL_BootstrapDataSql()
    try KL_AppCat_Init(metrics_dir)

    ; Initialise the walker batch dicts. KL_LoadState() above already
    ; restored the per-app n-gram context (KLW.ctx) if state.json had one.
    try KLW_ResetBatch()

    ; Background timers — Bind() captures the function reference for SetTimer.
    Keylogger._ingest_timer   := KL_IngestOnce.Bind()
    Keylogger._midnight_timer := KL_MidnightCheck.Bind()
    SetTimer(Keylogger._ingest_timer,   KeylogConst.INGEST_TICK_MS)
    SetTimer(Keylogger._midnight_timer, KeylogConst.MIDNIGHT_CHECK_TICK_MS)

    ; Initial ingest pass to drain anything buffered while the script was
    ; not running.
    SetTimer(KL_IngestOnce.Bind(), -250)
}

KL_Stop() {
    if !Keylogger.initialized
        return
    ; Release the keystroke hook FIRST so no late event lands in a
    ; buffer we are about to flush + serialise.
    try KL_Hook_Stop()
    ; Drain idle / session state and unhook OnMessage handlers so the
    ; JSONL never ends with a dangling session_start / idle_start.
    try KL_Watchers_Stop()
    try KL_Mouse_Stop()
    try KL_Sensors_Stop()
    try KL_Topo_Stop()
    if Keylogger.HasProp("_ingest_timer")
        SetTimer(Keylogger._ingest_timer, 0)
    if Keylogger.HasProp("_midnight_timer")
        SetTimer(Keylogger._midnight_timer, 0)
    KL_FlushBuffer()
    KL_IngestOnce()
    KL_SaveState()
    KL_CloseTodayFh()
    Keylogger.initialized := false
}




; ====================================================
; ====================================================
; ======= 16/ Convenience / Public API =======
; ====================================================
; ====================================================

KL_GetSqlitePath() {
    ; The launcher uses this path to (re)build db.sqlite from data.sql on
    ; demand. The keylogger itself never opens the SQLite file.
    return KL_ResolveTmpdir() . "ergopti_metrics\" . Keylogger.device_id . "\db.sqlite"
}

KL_GetDeviceShortId() {
    if (Keylogger.device_id = "")
        return ""
    return SubStr(Keylogger.device_id, 1, 8) . "…"
}

; Setters mirroring HS CoreState — wire them from your event handlers.
KL_SetSessionApp(name) {
    Keylogger.session_app := name
}
KL_SetSessionTitle(title) {
    Keylogger.session_title := title
}
KL_SetSessionLayout(layout) {
    Keylogger.session_layout := layout
}
KL_SetSessionUrl(url) {
    Keylogger.session_url := url
}
KL_SetSessionFieldRole(role) {
    Keylogger.session_field_role := role
}
KL_BumpMouseClick() {
    Keylogger.session_clicks += 1
}
KL_BumpMouseScroll() {
    Keylogger.session_scrolls += 1
}
KL_BumpMouseDistance(px) {
    Keylogger.mouse_distance += px
}
