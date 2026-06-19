; static/ergopti_plus/windows/lib/logger.ahk

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
; 6. Dedicated errors-only sink: every WARNING/ERROR line is also appended to
;    ErgoptiPlus_errors_YYYY-MM-DD.log (same daily rotation/purge policy). This
;    gives a small, focused file for quick triage of problems.
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

; Absolute path to the errors-only log (WARNING + ERROR levels only).
; Separate daily file so the user can quickly triage issues without wading
; through thousands of normal lines in the unified log.
global LOGGER_ERRORS_LOG_PATH := ""

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
global _LOGGER_PENDING_ERRORS := []
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
    Map("name", "ErgoptiPlus_gestures.log", "tags", ["[gestures"]),
    Map("name", "ErgoptiPlus_layout.log", "tags", ["[LayoutShift]", "[LayoutCaps]", "[LayoutAltGr]"]),
    Map("name", "ErgoptiPlus_dispatch.log", "tags", ["[Dispatch]", "[ScriptShortcuts]", "[TomlLoader]"]),
    Map("name", "ErgoptiPlus_tray.log", "tags", ["[ErgoptiPlus]"]),
]

; Resolved absolute paths for each sub-file (populated by LoggerInit).
global _LOGGER_SUB_PATHS := Map()

; Per-sub-file pending queues — keyed by sub-file name; drained by _LoggerFlush
; alongside the main pending queue so fan-out lines are batched, not synchronous.
global _LOGGER_SUB_PENDING := Map()

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
    global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL, ConfigurationFile
    global _LOGGER_FLUSH_TIMER_STARTED, LOGGER_FLUSH_INTERVAL_MS, _ConfigDir, _AhkSubDir

    ; Daily-rotating log file under <ConfigDir>/autohotkey/logs/. Resolves
    ; _ConfigDir at call time so any later override (paths.toml) is picked up.
    LogDir := (IsSet(_ConfigDir) and _ConfigDir != "")
        ? _ConfigDir . _AhkSubDir . "logs\"
        : A_ScriptDir . "\logs\"
    if !DirExist(LogDir) {
        try DirCreate(LogDir)
    }
    LOGGER_LOG_PATH := LogDir . "ErgoptiPlus_" . FormatTime(, "yyyy-MM-dd") . ".log"
    LOGGER_ERRORS_LOG_PATH := LogDir . "ErgoptiPlus_errors_" . FormatTime(, "yyyy-MM-dd") . ".log"
    _LoggerPurgeOldLogs(LogDir, 14)
    ; Load sub-file routing rules from _shared/logger/sub_files.toml so adding a
    ; new topical log requires only a TOML edit, not a code change in both drivers.
    _LoggerLoadSubFilesToml(A_ScriptDir . "\")
    _LoggerInitSubFiles(LogDir)
    LOGGER_MIN_LEVEL := LOGGER_DEFAULT_LEVEL
    if IsSet(ConfigurationFile) and FileExist(ConfigurationFile) {
        try {
            Value := TOML_Read(ConfigurationFile, "script", "log_level", LOGGER_DEFAULT_LEVEL)
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
    ; Drain any lines that were emitted before LoggerInit resolved the log path.
    ; Without this flush, every _LoggerEmit call that fired during early boot
    ; (before LOGGER_LOG_PATH was set) would silently stay in the pending queue
    ; until the next periodic tick (~500 ms), or be lost entirely on a crash.
    _LoggerFlush(false)
}

; Drain the pending-lines queue into the log file in a single FileAppend.
; Called by the SetTimer installed in LoggerInit and synchronously by error /
; warning emits that must survive a subsequent crash. When ``ForceFlush`` is
; true, the write goes through an explicit FileOpen → Write → Close sequence
; so a subsequent hard crash (OS kill, power loss) cannot swallow the entry
; sitting in the stdlib buffer — ``FileAppend`` provides no flush guarantee.
_LoggerFlush(ForceFlush := false) {
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	global _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	; Prevent the timer from re-entering while we swap-and-drain the pending queues.
	; Without Critical, a hotkey or OnMessage callback fired mid-swap could push a
	; line into the OLD array reference that we have already captured — losing it.
	local _crit := Critical("On")
	try {
		Pending := _LOGGER_PENDING
		_LOGGER_PENDING := []
		PendingErr := _LOGGER_PENDING_ERRORS
		_LOGGER_PENDING_ERRORS := []
	} finally {
		Critical(_crit)
	}

	Blob := ""
	for _, Line in Pending {
		Blob .= Line . "`r`n"
	}

	BlobErr := ""
	for _, Line in PendingErr {
		BlobErr .= Line . "`r`n"
	}

	if (LOGGER_LOG_PATH != "" and Blob != "") {
		if ForceFlush {
			try {
				f := FileOpen(LOGGER_LOG_PATH, "a", "UTF-8")
				if f {
					f.Write(Blob)
					f.Close()  ; Close forces a flush of the underlying buffer.
				}
			}
		} else {
			try FileAppend(Blob, LOGGER_LOG_PATH, "UTF-8")
		}
	}

	if (LOGGER_ERRORS_LOG_PATH != "" and BlobErr != "") {
		if ForceFlush {
			try {
				f := FileOpen(LOGGER_ERRORS_LOG_PATH, "a", "UTF-8")
				if f {
					f.Write(BlobErr)
					f.Close()
				}
			}
		} else {
			try FileAppend(BlobErr, LOGGER_ERRORS_LOG_PATH, "UTF-8")
		}
	}

	; Drain per-sub-file queues with a single FileAppend each, same batch approach
	; as the main log, avoiding one FileAppend call per matching log line.
	local _crit2 := Critical("On")
	try {
		SubSnap := _LOGGER_SUB_PENDING.Clone()
		_LOGGER_SUB_PENDING := Map()
	} finally {
		Critical(_crit2)
	}
	for Name, Lines in SubSnap {
		if !_LOGGER_SUB_PATHS.Has(Name)
			continue
		SubBlob := ""
		for _, SLine in Lines {
			SubBlob .= SLine . "`r`n"
		}
		if SubBlob != ""
			try FileAppend(SubBlob, _LOGGER_SUB_PATHS[Name], "UTF-8")
	}
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

; Cheap predicate for hot-path call sites (per-keystroke dispatch) that want to
; skip building a debug line entirely — its variadic argument array and string
; interpolation — when DEBUG is off. LoggerDebug already short-circuits inside,
; but the call + arg-array build still costs something per keystroke; gating at
; the call site removes even that. Mirrors the macOS Logger.is_enabled(DEBUG).
LoggerIsDebugEnabled() {
    global _LOGGER_DEBUG_ENABLED
    return _LOGGER_DEBUG_ENABLED
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
; ===================================
; ======= 3/ Internal helpers =======
; ===================================
; ==========================================

; Format and emit a log line if the current level allows it. Best-effort —
; never raises so a logging failure cannot break the driver. Hot-path-safe.
_LoggerEmit(Level, Tag, Msg, Args*) {
    global LOGGER_LOG_PATH, LOGGER_MIN_LEVEL, LOGGER_SEVERITY, _LOGGER_PENDING
    ; Safety net for unknown levels — the public wrappers already short-circuit
    ; on the per-level fast-path flags, so a severity comparison here would be
    ; a redundant second filter. Only guard against a completely unrecognised Level.
    if !LOGGER_SEVERITY.Has(Level) {
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
    ; FormatTime of the full date string is the dominant per-emit cost and is
    ; identical for every line within the same second. On the DEBUG path it runs
    ; several times per keystroke (the prefix-watcher hot path), which is the
    ; source of the « debug mode lag ». Cache the second-resolution part keyed on
    ; A_Now and only recompute the millisecond suffix.
    static _StampSecKey := ""
    static _StampSecStr := ""
    SecKey := A_Now
    if (SecKey != _StampSecKey) {
        _StampSecKey := SecKey
        _StampSecStr := FormatTime(SecKey, "yyyy-MM-dd HH:mm:ss")
    }
    Stamp := _StampSecStr . ":" . Format("{:03}", A_MSec)
    Line := Format("{1} [{2}] [{3}] {4}", Stamp, Level, Tag, Body)

    ; ── ERROR deduplication ──
    ; Suppress identical consecutive ERROR messages (same tag and body) to
    ; prevent log flooding during tight loops or repeat failures. The 5000 ms
    ; window ensures the same error is re-emitted after a cooldown period so
    ; it is never suppressed forever.
    static _LastErrTag := "", _LastErrBody := "", _LastErrTime := 0
    if (Level == "ERROR") {
        if (Tag == _LastErrTag and Body == _LastErrBody and ((A_TickCount - _LastErrTime + 0x100000000) & 0xFFFFFFFF) < 5000) {
            return
        }
        _LastErrTag := Tag
        _LastErrBody := Body
        _LastErrTime := A_TickCount
    }

    _LoggerPushRing(Line)
    if _LOGGER_TEST_SINK != 0 {
        try _LOGGER_TEST_SINK(Line)
    }
	if (Level == "WARNING") {
		if IsSet(HealthCheck_RecordWarn)
			HealthCheck_RecordWarn()
	} else if (Level == "ERROR") {
		if IsSet(HealthCheck_RecordError)
			HealthCheck_RecordError(Body)
	}
	; Always enqueue the line unconditionally so pre-init messages (emitted
	; before LoggerInit has resolved LOGGER_LOG_PATH) survive until the first
	; flush. _LoggerFlush() skips the FileAppend when the path is still empty,
	; and LoggerInit() calls _LoggerFlush(false) to drain them once the path
	; is known.
	_LOGGER_PENDING.Push(Line)
	if LOGGER_SEVERITY[Level] >= LOGGER_SEVERITY["WARNING"] {
		global _LOGGER_PENDING_ERRORS
		_LOGGER_PENDING_ERRORS.Push(Line)
	}

	; Force a synchronous, file-handle-closed flush for ERROR and above only.
	; WARNING lines are safely batched; flushing on every WARNING would cause
	; double-writes when the buffered path also flushes during the same tick.
	if LOGGER_SEVERITY[Level] >= LOGGER_SEVERITY["ERROR"] {
		_LoggerFlush(true)
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
    for _, Entry in LOGGER_SUB_FILES {
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

; Appends Line to every sub-file whose tag list contains a pattern that is a
; substring of Line. Patterns in sub_files.toml are bracketed fragments like
; "[LayoutShift]" matched against the full formatted log line — exact tag
; equality would never match because the line already wraps the tag in brackets.
_LoggerFanOut(Tag, Line) {
    global LOGGER_SUB_FILES, _LOGGER_SUB_PATHS, _LOGGER_SUB_PENDING
    if !IsSet(_LOGGER_SUB_PATHS) or _LOGGER_SUB_PATHS.Count == 0 {
        return
    }
    for _, Entry in LOGGER_SUB_FILES {
        for _, Pat in Entry["tags"] {
            if InStr(Line, Pat, true) {   ; case-sensitive substring vs full line
                Name := Entry["name"]
                if !_LOGGER_SUB_PENDING.Has(Name)
                    _LOGGER_SUB_PENDING[Name] := []
                _LOGGER_SUB_PENDING[Name].Push(Line)
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
    global LOGGER_SUB_FILES, LOGGER_SUB_FILES_FALLBACK, _SharedDir
    ; Prefer the canonical _SharedDir resolved at boot by ErgoptiPlus.ahk; fall back
    ; to the corrected one-level relative path (windows/ → ergopti_plus/shared/).
    if (IsSet(_SharedDir) and _SharedDir != "")
        TomlPath := _SharedDir . "\logger\sub_files.toml"
    else
        TomlPath := ScriptDir . "..\shared\logger\sub_files.toml"
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
        for _, P in CurrentPlatforms {
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
    for _, Line in Lines {
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
            for _, S in Extracted {
                CurrentPatterns.Push(S)
            }
            if InStr(Line, "]") {
                InPatternsArray := false
            }
            continue
        }
        if InPlatformsArray {
            Extracted := _ExtractStrings(Line)
            for _, S in Extracted {
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
            for _, S in Extracted {
                CurrentPlatforms.Push(S)
            }
            if !InStr(Fragment, "]") {
                InPlatformsArray := true
            }
        } else if RegExMatch(Line, '^patterns\s*=\s*\[(.*)$', &M) {
            Fragment := M[1]
            Extracted := _ExtractStrings(Fragment)
            for _, S in Extracted {
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

; Removes ErgoptiPlus_*.log (and ErgoptiPlus_errors_*.log) files in LogDir whose
; date prefix is older than MaxAgeDays. Best-effort: errors are swallowed so a
; permission issue cannot break logger init.
_LoggerPurgeOldLogs(LogDir, MaxAgeDays) {
    if !DirExist(LogDir) {
        return
    }
    CutoffStamp := DateAdd(A_Now, -MaxAgeDays, "Days")
    CutoffDate := SubStr(CutoffStamp, 1, 8)  ; YYYYMMDD
    try {
        loop files, LogDir . "ErgoptiPlus_*.log" {
            ; Supports both unified (ErgoptiPlus_YYYY-MM-DD.log) and the dedicated
            ; errors file (ErgoptiPlus_errors_YYYY-MM-DD.log).
            if RegExMatch(A_LoopFileName, "^ErgoptiPlus(?:_errors)?_(\d{4})-(\d{2})-(\d{2})\.log$",
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
