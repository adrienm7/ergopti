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

; Absolute path to the log file. Resolved lazily so the script directory is
; always correct even when running from a temporary copy.
global LOGGER_LOG_PATH := ""

; In-memory ring buffer (Array) and write cursor (1-based index). RemoveAt is
; avoided to keep the hot path O(1) — we overwrite the oldest slot directly.
global LOGGER_RING_BUFFER := []
global LOGGER_RING_CURSOR := 0




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
}

; Verbose detail — setter calls, state snapshots, per-keystroke events.
LoggerDebug(Tag, Msg, Args*) {
    _LoggerEmit("DEBUG", Tag, Msg, Args*)
}

; Start of a routine internal operation (debug granularity). Pair with Done.
LoggerTrace(Tag, Msg, Args*) {
    _LoggerEmit("TRACE", Tag, Msg, Args*)
}

; Successful end of a routine internal operation. Pair with Trace.
LoggerDone(Tag, Msg, Args*) {
    _LoggerEmit("DONE", Tag, Msg, Args*)
}

; General status worth knowing — config loaded, feature toggled, model changed.
LoggerInfo(Tag, Msg, Args*) {
    _LoggerEmit("INFO", Tag, Msg, Args*)
}

; Start of a significant action (init, HTTP request, user-triggered op).
; Pair with Success — a missing Success in the logs flags a silent failure.
LoggerStart(Tag, Msg, Args*) {
    _LoggerEmit("START", Tag, Msg, Args*)
}

; Successful completion of a significant action. Pair with Start.
LoggerSuccess(Tag, Msg, Args*) {
    _LoggerEmit("SUCCESS", Tag, Msg, Args*)
}

; Unexpected condition the code can recover from; must be investigated.
LoggerWarn(Tag, Msg, Args*) {
    _LoggerEmit("WARNING", Tag, Msg, Args*)
}

; Unrecoverable failure; execution should stop or degrade gracefully.
LoggerError(Tag, Msg, Args*) {
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
    global LOGGER_LOG_PATH, LOGGER_MIN_LEVEL, LOGGER_SEVERITY
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
    Line := Format("{1} [{2,-7}] [{3}] {4}", Stamp, Level, Tag, Body)
    _LoggerPushRing(Line)
    if LOGGER_LOG_PATH != "" {
        try FileAppend(Line . "`r`n", LOGGER_LOG_PATH, "UTF-8")
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
