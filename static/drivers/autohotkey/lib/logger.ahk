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
; ==============================================================
; ======= 1/ Constants and shared state =======
; ==============================================================
; ==============================================================

; Maximum number of log lines kept in the in-memory ring buffer. 200 lines is
; enough to cover ~30 s of typical activity at INFO level while staying small
; in memory (~30 KB at 150 chars/line).
global LOGGER_RING_BUFFER_SIZE := 200

; Numeric severity used to filter messages against the user-configured minimum
; level. Lifecycle helpers map back onto these via _LevelSeverity().
global LOGGER_SEVERITY := Map(
    "DEBUG",   10,
    "TRACE",   10,
    "DONE",    10,
    "INFO",    20,
    "START",   20,
    "SUCCESS", 20,
    "WARNING", 30,
    "ERROR",   40,
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




; ==================================================
; ==================================================
; ======= 2/ Public API =======
; ==================================================
; ==================================================

; Initialise the logger. Reads the minimum level from the ini and resolves the
; log file path. Safe to call multiple times — later calls just refresh the
; minimum level (e.g. after the user changes it via the menu).
LoggerInit() {
    global LOGGER_LOG_PATH, LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL, ConfigurationFile
    global _LOGGER_FLUSH_TIMER_STARTED, LOGGER_FLUSH_INTERVAL_MS
    LOGGER_LOG_PATH := A_ScriptDir . "\ErgoptiPlus.log"
    LOGGER_MIN_LEVEL := LOGGER_DEFAULT_LEVEL
    if IsSet(ConfigurationFile) and FileExist(ConfigurationFile) {
        try {
            Value := IniRead(ConfigurationFile, "Script", "LogLevel", LOGGER_DEFAULT_LEVEL)
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
; warning emits that must survive a subsequent crash.
_LoggerFlush() {
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
    for _, Line in Pending {
        Blob .= Line . "`r`n"
    }
    try FileAppend(Blob, LOGGER_LOG_PATH, "UTF-8")
}

_LoggerOnExitFlush(ExitReason, ExitCode) {
    _LoggerFlush()
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
    _LOGGER_INFO_ENABLED  := (_LOGGER_MIN_SEVERITY <= 20)
    _LOGGER_WARN_ENABLED  := (_LOGGER_MIN_SEVERITY <= 30)
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
        for _, Line in LOGGER_RING_BUFFER {
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
; ==========================================
; ======= 3/ Internal helpers =======
; ==========================================
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
    Stamp := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    ; AHK Format uses ``{N:flags width}`` (printf-like) and a colon — the
    ; ``-7`` flag/width pair pads Level to 7 characters left-aligned.
    Line := Format("{1} [{2:-7}] [{3}] {4}", Stamp, Level, Tag, Body)
    _LoggerPushRing(Line)
    if LOGGER_LOG_PATH != "" {
        _LOGGER_PENDING.Push(Line)
        ; Force a synchronous flush for diagnostics that must survive a
        ; subsequent crash — WARNING and ERROR only; the other levels can
        ; tolerate the ~500 ms worst-case flush latency.
        if LOGGER_SEVERITY[Level] >= LOGGER_SEVERITY["WARNING"] {
            _LoggerFlush()
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
