; static/drivers/autohotkey/lib/logger.ahk

; ==============================================================================
; MODULE: Logger
; DESCRIPTION:
; Lightweight central logger for ErgoptiPlus, matching the 8-variant taxonomy
; mandated by CLAUDE.md §4 (debug / trace / done / info / start / success /
; warn / error). Writes structured lines to ``ErgoptiPlus.log`` next to the
; script and keeps a small in-memory ring buffer that the tray menu can dump
; for live debugging without re-reading the file.
;
; FEATURES & RATIONALE:
; 1. Eight variants on two axes (importance × lifecycle role) so every call
;    site is unambiguous: lifecycle pairs (start/success, trace/done) make
;    silent failures jump out — a START with no SUCCESS is a smoking gun.
; 2. All log lines are best-effort; FileAppend is wrapped in try/finally so a
;    locked log file (anti-virus, OneDrive sync) can never break the keyboard
;    driver. The driver MUST stay responsive even if logging fails.
; 3. Format strings follow CLAUDE.md §4.3 punctuation conventions
;    (in-progress ``…``, completed ``.``).
; 4. Minimum level is configurable via the ini under [Script] LogLevel so users
;    can crank it to DEBUG when troubleshooting and back to INFO afterwards.
; 5. The optional in-memory ring buffer (200 last lines) supports a future
;    "Dump recent logs" menu entry without needing a file read.
; ==============================================================================





; ==============================================================
; =============================================
; ======= 1/ Constants and shared state =======
; =============================================
; ==============================================================

; Maximum number of log lines kept in the in-memory ring buffer. 200 lines is
; enough to cover ~30 s of typical activity at INFO level while staying small
; in memory (~30 KB at 150 chars/line).
global LOGGER_RING_BUFFER_SIZE := 200

; Numeric severity used to filter messages against the user-configured minimum
; level. Lifecycle helpers map back onto these via _LevelSeverity().
global LOGGER_SEVERITY := Map(
    "DEBUG", 10,
    "TRACE", 10,
    "DONE", 10,
    "INFO", 20,
    "START", 20,
    "SUCCESS", 20,
    "WARNING", 30,
    "ERROR", 40,
)

; Default log level when nothing is configured in the ini. INFO keeps the file
; quiet during normal use while still surfacing lifecycle pairs and warnings.
global LOGGER_DEFAULT_LEVEL := "INFO"

; Resolved at boot from the ini (Script.LogLevel) or LOGGER_DEFAULT_LEVEL.
global LOGGER_MIN_LEVEL := LOGGER_DEFAULT_LEVEL

; Cached severity threshold (integer) and per-level fast-path flags, refreshed
; by LoggerInit whenever LOGGER_MIN_LEVEL changes. Hot-path callers (notably
; LoggerDebug / LoggerTrace / LoggerDone invoked from per-keystroke dispatch)
; check the flag before doing any work, so a disabled level collapses to a
; single boolean test instead of a Map lookup + Format + FileAppend.
global _LOGGER_MIN_SEVERITY := 20   ; INFO
global _LOGGER_DEBUG_ENABLED := False   ; DEBUG / TRACE / DONE
global _LOGGER_INFO_ENABLED := True     ; INFO / START / SUCCESS
global _LOGGER_WARN_ENABLED := True     ; WARNING
global _LOGGER_ERROR_ENABLED := True    ; ERROR

; Absolute path to the log file. Resolved lazily so the script directory is
; always correct even when running from a temporary copy.
global LOGGER_LOG_PATH := ""

; In-memory ring buffer (Array) and write cursor (1-based index). RemoveAt is
; avoided to keep the hot path O(1) — we overwrite the oldest slot directly.
global LOGGER_RING_BUFFER := []
global LOGGER_RING_CURSOR := 0

; Pending-lines queue — each ``_LoggerEmit`` call pushes a line here; the
; background ``_LoggerFlush`` (ticked by a SetTimer started in LoggerInit)
; drains the queue with a single ``FileAppend`` every LOGGER_FLUSH_INTERVAL_MS.
; This collapses N individual FileOpen/Write/Close round-trips per tick into
; one. Errors and warnings force a synchronous flush so a crash that follows
; cannot swallow the diagnostic line.
global LOGGER_FLUSH_INTERVAL_MS := 500
global _LOGGER_PENDING := []
global _LOGGER_FLUSH_TIMER_STARTED := False

; Sub-file fan-out: each entry maps a filename suffix to a list of tag substrings.
; Lines whose [Tag] matches any pattern are appended to that sub-file in addition
; to the main unified log. Sub-files are ephemeral (today only) — stale ones from
; previous days are deleted at init time. Paths are resolved relative to LogDir.
;
; Populated by _LoggerLoadSubFilesToml() at LoggerInit time from the canonical
; _shared/logger/sub_files.toml; falls back to the hardcoded list when the
; shared file is unavailable (e.g. stripped builds, running from a temp copy).
global LOGGER_SUB_FILES := []

; Hardcoded fallback used when sub_files.toml cannot be found. Covers the
; minimum set of AHK-only sub-files required for production log triage.
global LOGGER_SUB_FILES_FALLBACK := [
    Map("name", "ErgoptiPlus_gestures.log", "tags", ["gestures"]),
    Map("name", "ErgoptiPlus_layout.log", "tags", ["LayoutShift", "LayoutCaps", "LayoutAltGr"]),
    Map("name", "ErgoptiPlus_dispatch.log", "tags", ["Dispatch", "ScriptShortcuts", "TomlLoader"]),
    Map("name", "ErgoptiPlus_tray.log", "tags", ["ErgoptiPlus"]),
]

; Resolved absolute paths for each sub-file (populated by LoggerInit).
global _LOGGER_SUB_PATHS := Map()

; Optional test sink — when set to a Callable, every emitted line is forwarded
; to it in addition to the ring buffer and pending-queue paths. Lets unit tests
; capture log output without filesystem I/O. Set via LoggerSetTestSink() and
; cleared via LoggerClearTestSink().
global _LOGGER_TEST_SINK := 0





; ==================================================
; =============================
; ======= 2/ Public API =======
; =============================
; ==================================================

; Initialise the logger. Reads the minimum level from the ini and resolves the
; log file path. Safe to call multiple times — later calls just refresh the
; minimum level (e.g. after the user changes it via the menu).
LoggerInit() {
    global LOGGER_LOG_PATH, LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL, ConfigurationFile
    global _LOGGER_FLUSH_TIMER_STARTED, LOGGER_FLUSH_INTERVAL_MS, _ConfigDir

    ; Daily-rotating log file under <ConfigDir>/ahk/logs/. Resolves _ConfigDir
    ; at call time so any later override (paths.toml) is picked up
    LogDir := (IsSet(_ConfigDir) and _ConfigDir != "")
        ? _ConfigDir . "ahk\logs\"
        : A_ScriptDir . "\logs\"
    if !DirExist(LogDir) {
        try DirCreate(LogDir)
    }
    LOGGER_LOG_PATH := LogDir . "ErgoptiPlus_" . FormatTime(, "yyyy-MM-dd") . ".log"
    _LoggerPurgeOldLogs(LogDir, 14)
    ; Load sub-file routing rules from _shared/logger/sub_files.toml so adding a
    ; new topical log requires only a TOML edit, not a code change in both drivers.
    _LoggerLoadSubFilesToml(A_ScriptDir . "\")
    _LoggerInitSubFiles(LogDir)
    LOGGER_MIN_LEVEL := LOGGER_DEFAULT_LEVEL
    if IsSet(ConfigurationFile) and FileExist(ConfigurationFile) {
        try {
            Value := TOML_Read(ConfigurationFile, "Script", "LogLevel", LOGGER_DEFAULT_LEVEL)
            if LOGGER_SEVERITY.Has(Value) {
                LOGGER_MIN_LEVEL := Value
            }
        }
    }
    _LoggerRefreshFastFlags()

    ; Start the background flusher once. LoggerInit may be called again when
    ; the user toggles the log level via the menu — we do not restart the
    ; timer in that case. OnExit ensures any pending lines are flushed before
    ; the driver terminates so crash diagnostics are not lost.
    if !_LOGGER_FLUSH_TIMER_STARTED {
        SetTimer(_LoggerFlush, LOGGER_FLUSH_INTERVAL_MS)
        OnExit(_LoggerOnExitFlush)
        _LOGGER_FLUSH_TIMER_STARTED := True
    }
}

; Drain the pending-lines queue into the log file in a single FileAppend.
; Called by the SetTimer installed in LoggerInit and synchronously by error /
; warning emits that must survive a subsequent crash. When ``ForceFlush`` is
; true, the write goes through an explicit FileOpen → Write → Close sequence
; so a subsequent hard crash (OS kill, power loss) cannot swallow the entry
; sitting in the stdlib buffer — ``FileAppend`` provides no flush guarantee.
_LoggerFlush(ForceFlush := false) {
    global _LOGGER_PENDING, LOGGER_LOG_PATH
    if _LOGGER_PENDING.Length == 0 {
        return
    }
    if LOGGER_LOG_PATH == "" {
        ; No path resolved — drop the queue to avoid unbounded growth.
        _LOGGER_PENDING := []
        return
    }
    ; Swap-and-clear so a concurrent emit lands in a fresh queue while we
    ; write. AHK v2 is single-threaded for our purposes but timers and hotkey
    ; callbacks can interleave at well-defined points.
    Pending := _LOGGER_PENDING
    _LOGGER_PENDING := []
    Blob := ""
    for Line in Pending {
        Blob .= Line . "`r`n"
    }
    if ForceFlush {
        try {
            f := FileOpen(LOGGER_LOG_PATH, "a", "UTF-8")
            if f {
                f.Write(Blob)
                f.Close()  ; Close forces a flush of the underlying buffer.
            }
        }
        return
    }
    try FileAppend(Blob, LOGGER_LOG_PATH, "UTF-8")
}

_LoggerOnExitFlush(ExitReason, ExitCode) {
    ; Use the forced-flush path on exit too — a subsequent OS kill cannot
    ; replay the buffered FileAppend.
    _LoggerFlush(true)
    return 0
}

; Recompute the cached integer severity and per-level fast-path flags from
; ``LOGGER_MIN_LEVEL``. Called once from LoggerInit and anywhere the minimum
; level is mutated at runtime.
_LoggerRefreshFastFlags() {
    global LOGGER_MIN_LEVEL, LOGGER_SEVERITY
    global _LOGGER_MIN_SEVERITY, _LOGGER_DEBUG_ENABLED, _LOGGER_INFO_ENABLED
    global _LOGGER_WARN_ENABLED, _LOGGER_ERROR_ENABLED
    _LOGGER_MIN_SEVERITY := LOGGER_SEVERITY.Has(LOGGER_MIN_LEVEL)
        ? LOGGER_SEVERITY[LOGGER_MIN_LEVEL]
        : 20
    _LOGGER_DEBUG_ENABLED := (_LOGGER_MIN_SEVERITY <= 10)
    _LOGGER_INFO_ENABLED := (_LOGGER_MIN_SEVERITY <= 20)
    _LOGGER_WARN_ENABLED := (_LOGGER_MIN_SEVERITY <= 30)
    _LOGGER_ERROR_ENABLED := (_LOGGER_MIN_SEVERITY <= 40)
}

; Verbose detail — setter calls, state snapshots, per-keystroke events.
; Short-circuits on the cached flag so disabled DEBUG collapses to a
; single boolean test, no Format / FileAppend cost on the hot path.
LoggerDebug(Tag, Msg, Args*) {
    global _LOGGER_DEBUG_ENABLED
    if !_LOGGER_DEBUG_ENABLED {
        return
    }
    _LoggerEmit("DEBUG", Tag, Msg, Args*)
}

; Start of a routine internal operation (debug granularity). Pair with Done.
LoggerTrace(Tag, Msg, Args*) {
    global _LOGGER_DEBUG_ENABLED
    if !_LOGGER_DEBUG_ENABLED {
        return
    }
    _LoggerEmit("TRACE", Tag, Msg, Args*)
}

; Successful end of a routine internal operation. Pair with Trace.
LoggerDone(Tag, Msg, Args*) {
    global _LOGGER_DEBUG_ENABLED
    if !_LOGGER_DEBUG_ENABLED {
        return
    }
    _LoggerEmit("DONE", Tag, Msg, Args*)
}

; General status worth knowing — config loaded, feature toggled, model changed.
LoggerInfo(Tag, Msg, Args*) {
    global _LOGGER_INFO_ENABLED
    if !_LOGGER_INFO_ENABLED {
        return
    }
    _LoggerEmit("INFO", Tag, Msg, Args*)
}

; Start of a significant action (init, HTTP request, user-triggered op).
; Pair with Success — a missing Success in the logs flags a silent failure.
LoggerStart(Tag, Msg, Args*) {
    global _LOGGER_INFO_ENABLED
    if !_LOGGER_INFO_ENABLED {
        return
    }
    _LoggerEmit("START", Tag, Msg, Args*)
}

; Successful completion of a significant action. Pair with Start.
LoggerSuccess(Tag, Msg, Args*) {
    global _LOGGER_INFO_ENABLED
    if !_LOGGER_INFO_ENABLED {
        return
    }
    _LoggerEmit("SUCCESS", Tag, Msg, Args*)
}

; Unexpected condition the code can recover from; must be investigated.
LoggerWarn(Tag, Msg, Args*) {
    global _LOGGER_WARN_ENABLED
    if !_LOGGER_WARN_ENABLED {
        return
    }
    _LoggerEmit("WARNING", Tag, Msg, Args*)
}

; Unrecoverable failure; execution should stop or degrade gracefully.
LoggerError(Tag, Msg, Args*) {
    global _LOGGER_ERROR_ENABLED
    if !_LOGGER_ERROR_ENABLED {
        return
    }
    _LoggerEmit("ERROR", Tag, Msg, Args*)
}

; Registers a callable that receives every formatted log line (as a string).
; Used exclusively by tests — never call from production code.
; @param Fn {Callable} One-arity function receiving the formatted line string.
LoggerSetTestSink(Fn) {
	global _LOGGER_TEST_SINK
	_LOGGER_TEST_SINK := Fn
}

; Removes the registered test sink. Call in test cleanup to avoid bleed.
LoggerClearTestSink() {
	global _LOGGER_TEST_SINK
	_LOGGER_TEST_SINK := 0
}

; Return a snapshot of the in-memory ring buffer in chronological order, so
; the most recent line is last. Useful for a "Dump recent logs" menu entry.
LoggerRingBufferSnapshot() {
    global LOGGER_RING_BUFFER, LOGGER_RING_BUFFER_SIZE, LOGGER_RING_CURSOR
    if LOGGER_RING_BUFFER.Length == 0 {
        return []
    }
    if LOGGER_RING_BUFFER.Length < LOGGER_RING_BUFFER_SIZE {
        ; Buffer not yet full — entries are already in order.
        Snapshot := []
        for Line in LOGGER_RING_BUFFER {
            Snapshot.Push(Line)
        }
        return Snapshot
    }
    ; Buffer is full and wrapped — read from cursor (oldest) to wrap-around.
    Snapshot := []
    Idx := LOGGER_RING_CURSOR
    loop LOGGER_RING_BUFFER_SIZE {
        Idx := Mod(Idx, LOGGER_RING_BUFFER_SIZE) + 1
        Snapshot.Push(LOGGER_RING_BUFFER[Idx])
    }
    return Snapshot
}





; ==========================================
; ===================================
; ======= 3/ Internal helpers =======
; ===================================
; ==========================================

; Format and emit a log line if the current level allows it. Best-effort —
; never raises so a logging failure cannot break the driver. Hot-path-safe.
_LoggerEmit(Level, Tag, Msg, Args*) {
    global LOGGER_LOG_PATH, LOGGER_MIN_LEVEL, LOGGER_SEVERITY, _LOGGER_PENDING
    if !LOGGER_SEVERITY.Has(Level) {
        return
    }
    if LOGGER_SEVERITY[Level] < LOGGER_SEVERITY[LOGGER_MIN_LEVEL] {
        return
    }
    Body := Msg
    if Args.Length > 0 {
        try {
            Body := Format(Msg, Args*)
        } catch {
            ; Bad format string must not break the driver — fall back to raw message.
            Body := Msg
        }
    }
    Stamp := FormatTime(, "yyyy-MM-dd HH:mm:ss") . ":" . Format("{:03}", A_MSec)
    Line := Format("{1} [{2}] [{3}] {4}", Stamp, Level, Tag, Body)
    _LoggerPushRing(Line)
    if _LOGGER_TEST_SINK != 0 {
        try _LOGGER_TEST_SINK(Line)
    }
    if LOGGER_LOG_PATH != "" {
        _LOGGER_PENDING.Push(Line)
        ; Force a synchronous, file-handle-closed flush for diagnostics that
        ; must survive a subsequent crash — WARNING and ERROR only. Other
        ; levels can tolerate the ~500 ms worst-case flush latency through
        ; the buffered ``FileAppend`` path.
        if LOGGER_SEVERITY[Level] >= LOGGER_SEVERITY["WARNING"] {
            _LoggerFlush(true)
        }
    }
    _LoggerFanOut(Tag, Line)
}

; Resolves absolute paths for every sub-file and deletes any stale sub-file
; whose date does not match today. Sub-files are ephemeral (today only) — they
; are a filtered view of the main unified log, not an independent archive.
_LoggerInitSubFiles(LogDir) {
    global LOGGER_SUB_FILES, _LOGGER_SUB_PATHS
    Today := FormatTime(, "yyyy-MM-dd")
    _LOGGER_SUB_PATHS := Map()
    for Entry in LOGGER_SUB_FILES {
        SubPath := LogDir . Entry["name"]
        _LOGGER_SUB_PATHS[Entry["name"]] := SubPath
        ; Delete if the file exists but belongs to a previous day
        if FileExist(SubPath) {
            FileDate := ""
            try FileDate := FileGetTime(SubPath, "M")  ; last-modified YYYYMMDDHHMMSS
            FileDate := SubStr(FileDate, 1, 4) . "-" . SubStr(FileDate, 5, 2) . "-" . SubStr(FileDate, 7, 2)
            if (FileDate != Today) {
                try FileDelete(SubPath)
            }
        }
    }
}

; Appends Line to every sub-file whose tag list contains Tag. Best-effort —
; never raises so a sub-file I/O error cannot break the main logging path.
_LoggerFanOut(Tag, Line) {
    global LOGGER_SUB_FILES, _LOGGER_SUB_PATHS
    if !IsSet(_LOGGER_SUB_PATHS) or _LOGGER_SUB_PATHS.Count == 0 {
        return
    }
    for Entry in LOGGER_SUB_FILES {
        for TagPattern in Entry["tags"] {
            if (Tag = TagPattern) {
                SubPath := _LOGGER_SUB_PATHS[Entry["name"]]
                try FileAppend(Line . "`r`n", SubPath, "UTF-8")
                break
            }
        }
    }
}

; Parses _shared/logger/sub_files.toml and populates LOGGER_SUB_FILES with the
; entries whose platforms array includes "ahk". Falls back to LOGGER_SUB_FILES_FALLBACK
; when the file is absent or unreadable so the driver stays functional in stripped builds.
;
; The parser handles the fixed schema:
;   [[sub_files]]
;   name     = "gestures"
;   platforms = ["ahk", "hs"]
;   patterns = ["[gestures", "gesture"]
;
; Unknown keys (description) are silently skipped. Arrays may span multiple lines.
; The file is NOT the general-purpose TOML parser because [[array_of_tables]] is
; outside the scope of toml_helpers.ahk — this dedicated reader is intentionally minimal.
_LoggerLoadSubFilesToml(ScriptDir) {
    global LOGGER_SUB_FILES, LOGGER_SUB_FILES_FALLBACK
    ; Resolve path: ScriptDir\..\..\..\_shared\logger\sub_files.toml
    ; (autohotkey/ → drivers/ → _shared/logger/)
    TomlPath := ScriptDir . "..\..\..\_shared\logger\sub_files.toml"
    if !FileExist(TomlPath) {
        LOGGER_SUB_FILES := LOGGER_SUB_FILES_FALLBACK
        return
    }
    Raw := ""
    try {
        Raw := FileRead(TomlPath, "UTF-8")
    } catch {
        LOGGER_SUB_FILES := LOGGER_SUB_FILES_FALLBACK
        return
    }
    if Raw = "" {
        LOGGER_SUB_FILES := LOGGER_SUB_FILES_FALLBACK
        return
    }

    ; Collapse CRLF and LF to a single line-break token for uniform processing
    Raw := StrReplace(Raw, "`r`n", "`n")
    Raw := StrReplace(Raw, "`r", "`n")

    Result := []
    CurrentEntry := ""       ; "name" string while inside a [[sub_files]] block
    CurrentPlatforms := []   ; platforms array for the current entry
    CurrentPatterns  := []   ; patterns array for the current entry
    InPatternsArray := false ; true while accumulating a multi-line array value
    InPlatformsArray := false

    _FlushEntry() {
        if CurrentEntry = "" {
            return
        }
        ; Only include entries that list "ahk" in their platforms array
        IsAhk := false
        for P in CurrentPlatforms {
            if (P = "ahk") {
                IsAhk := true
                break
            }
        }
        if IsAhk and CurrentPatterns.Length > 0 {
            Result.Push(Map(
                "name", "ErgoptiPlus_" . CurrentEntry . ".log",
                "tags", CurrentPatterns
            ))
        }
        CurrentEntry := ""
        CurrentPlatforms := []
        CurrentPatterns  := []
        InPatternsArray  := false
        InPlatformsArray := false
    }

    ; Extracts all quoted strings from an array fragment like ["foo", "bar"]
    _ExtractStrings(Fragment) {
        Strings := []
        Pos := 1
        loop {
            if !RegExMatch(Fragment, '"([^"\\]*(?:\\.[^"\\]*)*)"', &M, Pos) {
                break
            }
            Strings.Push(M[1])
            Pos := M.Pos + M.Len
        }
        return Strings
    }

    Lines := StrSplit(Raw, "`n")
    for Line in Lines {
        ; Strip inline comments and trim
        Line := Trim(RegExReplace(Line, "\s*#.*$", ""))
        if Line = "" {
            continue
        }
        if (Line = "[[sub_files]]") {
            _FlushEntry()
            continue
        }
        ; Accumulate multi-line arrays
        if InPatternsArray {
            Extracted := _ExtractStrings(Line)
            for S in Extracted {
                CurrentPatterns.Push(S)
            }
            if InStr(Line, "]") {
                InPatternsArray := false
            }
            continue
        }
        if InPlatformsArray {
            Extracted := _ExtractStrings(Line)
            for S in Extracted {
                CurrentPlatforms.Push(S)
            }
            if InStr(Line, "]") {
                InPlatformsArray := false
            }
            continue
        }
        ; Key-value lines
        if RegExMatch(Line, '^name\s*=\s*"([^"]*)"', &M) {
            CurrentEntry := M[1]
        } else if RegExMatch(Line, '^platforms\s*=\s*\[(.*)$', &M) {
            Fragment := M[1]
            Extracted := _ExtractStrings(Fragment)
            for S in Extracted {
                CurrentPlatforms.Push(S)
            }
            if !InStr(Fragment, "]") {
                InPlatformsArray := true
            }
        } else if RegExMatch(Line, '^patterns\s*=\s*\[(.*)$', &M) {
            Fragment := M[1]
            Extracted := _ExtractStrings(Fragment)
            for S in Extracted {
                CurrentPatterns.Push(S)
            }
            if !InStr(Fragment, "]") {
                InPatternsArray := true
            }
        }
    }
    _FlushEntry()

    if Result.Length > 0 {
        LOGGER_SUB_FILES := Result
    } else {
        ; Parsed but no valid entries — fall back to avoid an empty fan-out table
        LOGGER_SUB_FILES := LOGGER_SUB_FILES_FALLBACK
    }
}

; Removes ErgoptiPlus_*.log files in LogDir whose date prefix is older than
; MaxAgeDays. Filename format: ErgoptiPlus_YYYY-MM-DD.log. Best-effort: errors
; are swallowed so a permission issue cannot break logger init.
_LoggerPurgeOldLogs(LogDir, MaxAgeDays) {
    if !DirExist(LogDir) {
        return
    }
    CutoffStamp := DateAdd(A_Now, -MaxAgeDays, "Days")
    CutoffDate := SubStr(CutoffStamp, 1, 8)  ; YYYYMMDD
    try {
        loop files, LogDir . "ErgoptiPlus_*.log" {
            ; Extract the date from the filename: ErgoptiPlus_YYYY-MM-DD.log
            if RegExMatch(A_LoopFileName, "^ErgoptiPlus_(\d{4})-(\d{2})-(\d{2})\.log$",
                &Match) {
                FileDate := Match[1] . Match[2] . Match[3]
                if (FileDate < CutoffDate) {
                    try FileDelete(A_LoopFileFullPath)
                }
            }
        }
    }
}

; Append to the in-memory ring buffer with O(1) overwrite once full.
_LoggerPushRing(Line) {
    global LOGGER_RING_BUFFER, LOGGER_RING_BUFFER_SIZE, LOGGER_RING_CURSOR
    if LOGGER_RING_BUFFER.Length < LOGGER_RING_BUFFER_SIZE {
        LOGGER_RING_BUFFER.Push(Line)
        LOGGER_RING_CURSOR := LOGGER_RING_BUFFER.Length
        return
    }
    LOGGER_RING_CURSOR := Mod(LOGGER_RING_CURSOR, LOGGER_RING_BUFFER_SIZE) + 1
    LOGGER_RING_BUFFER[LOGGER_RING_CURSOR] := Line
}
