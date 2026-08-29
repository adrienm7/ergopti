; infra/logger.ahk

; ==============================================================================
; MODULE: Logger
; DESCRIPTION:
; Lightweight central logger for ErgoptiPlus, matching the 8-variant taxonomy
; in _shared/modules/logger/SPEC.md (debug / trace / done / info / start / success /
; warn / error). Writes structured lines to ``ErgoptiPlus.log`` next to the
; script and keeps a small in-memory ring buffer that the tray menu can dump
; for live debugging without re-reading the file.
;
; FEATURES & RATIONALE:
; 1. Eight variants on two axes (importance × lifecycle role) so every call
;    site is unambiguous: lifecycle pairs (start/success, trace/done) make
;    silent failures jump out — a START with no SUCCESS is a smoking gun.
; 2. All log lines are best-effort; a failed complete append retains its queue
;    so a locked log file can never break the keyboard driver or acknowledge a
;    partial record.
; 3. Format strings follow the shared logger contract's punctuation conventions
;    (in-progress ``…``, completed ``.``).
; 4. Minimum level is configurable via the ini under [Script] LogLevel so users
;    can crank it to DEBUG when troubleshooting and back to INFO afterwards.
; 5. The optional in-memory ring buffer (200 last lines) supports a future
;    "Dump recent logs" menu entry without needing a file read.
; 6. Dedicated errors-only sink: every WARNING/ERROR line is also appended to
;    ErgoptiPlus_errors_YYYY-MM-DD.log (same daily rotation/purge policy). This
;    gives a small, focused file for quick triage of problems.
; ==============================================================================





; =============================================
; =============================================
; ======= 1/ Constants and shared state =======
; =============================================
; =============================================

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
;
; The pre-init defaults are deliberately PERMISSIVE. These flags decide what
; survives during the whole boot window that precedes LoggerInit — the entire
; #Include graph's top-level code, the onboarding wizard, the config parse and
; I18nInit — because the public wrappers short-circuit on them before
; _LoggerEmit's unconditional "queue it, the path is not resolved yet" push is
; ever reached. With DEBUG defaulting to off, every boot-phase DEBUG/TRACE/DONE
; line was DISCARDED rather than queued, so a user running at log_level = DEBUG
; never saw them at all (logger-preinit-level-drop). A queued line can still be
; dropped once the configured level is known — LoggerInit narrows the queue via
; _LoggerDropPreInitBelowLevel — but a line that was never emitted cannot be
; recovered.
global _LOGGER_MIN_SEVERITY := 10   ; DEBUG until the configured level is read
global _LOGGER_DEBUG_ENABLED := True    ; DEBUG / TRACE / DONE
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

; Calendar date (yyyy-MM-dd) the two paths above were built for. The driver
; commonly runs for days at a time, so resolving the dated filename once at
; init would pin every later entry to the start date: entries would land in a
; file named for the wrong day, and _LoggerPurgeOldLogs — which ages files by
; the date in their NAME — would delete recent data early. _LoggerFlush
; compares this against today and re-resolves on a change.
global _LOGGER_PATH_DATE := ""

; Retention window for dated log files, in days. Single source of truth: both
; LoggerInit and the midnight rollover in _LoggerFlush purge with this value.
global LOGGER_RETENTION_DAYS := 14

; Fixed-name diagnostic files used by detached helpers cannot participate in
; the dated-log retention sweep. Keep one current file plus one rotated archive,
; each capped here, so every auxiliary logger has the same bounded owner.
global LOGGER_AUXILIARY_LOG_MAX_BYTES := 1048576

; In-memory ring buffer (Array) and write cursor (1-based index). RemoveAt is
; avoided to keep the hot path O(1) — we overwrite the oldest slot directly.
global LOGGER_RING_BUFFER := []
global LOGGER_RING_CURSOR := 0

; Pending-lines queue — each ``_LoggerEmit`` call pushes a line here; the
; background ``_LoggerFlush`` (ticked by a SetTimer started in LoggerInit)
; drains the queue with one verified append every LOGGER_FLUSH_INTERVAL_MS.
; This collapses N individual FileOpen/Write/Close round-trips per tick into
; one. Errors and warnings force a synchronous flush so a crash that follows
; cannot swallow the diagnostic line.
global LOGGER_FLUSH_INTERVAL_MS := 500
global _LOGGER_PENDING := []
global _LOGGER_PENDING_ERRORS := []
global _LOGGER_FLUSH_TIMER_STARTED := False
global _LOGGER_FLUSH_ACTIVE := False
global _LOGGER_FORCE_FLUSH_PENDING := False

; Hard ceiling on a pending queue, enforced only on the requeue path. A failed
; A failed append re-injects its whole snapshot ahead of lines emitted meanwhile,
; so a CHRONIC sink failure — a full disk, precisely when the driver is logging
; the errors that matter — made every 500 ms tick re-stack everything plus the
; new lines, with no bound over a 10 h session. 5000 lines is far more history
; than a triage ever reads back (~1.5 MB per queue) and turns an unbounded leak
; into a fixed cost. The nominal path is deliberately NOT capped: it drains on
; every tick, and testing a length per emitted line would put a check on the
; DEBUG hot path to guard a state that cannot occur while the timer runs.
global LOGGER_PENDING_CAP := 5000

; Lines sacrificed to the cap since the last successful write. Emitted as one
; summary line once the sink recovers, so a truncation is never silent — the
; counter exists to keep the loss fail-fast without logging while the sink is
; dead (which would be the very recursion the cap is defending against).
global _LOGGER_DROPPED_LINES := 0

; Sub-file fan-out: each entry maps a filename suffix to a list of tag substrings.
; Lines whose [Tag] matches any pattern are appended to that sub-file in addition
; to the main unified log. Sub-files are ephemeral (today only) — stale ones from
; previous days are deleted at init time. Paths are resolved relative to LogDir.
;
; Filled at LoggerInit from _generated/logger_sub_files.ahk, which is generated
; from the canonical _shared/modules/logger/sub_files.toml.
;
; This used to be populated by a 112-line hand-rolled [[array_of_tables]] parser
; living right here, backed by a hardcoded fallback list. Both were liabilities.
; The parser was one of TWO copies of the same grammar (the macOS driver had its
; own), so the same bug had to be found and fixed twice — a "]" inside a quoted
; pattern closed the array early and silently dropped every pattern after it,
; and the shared file's own guidance is to prefer bracketed tag patterns like
; "[gestures". The fallback was a second copy of the data, free to drift, and
; the macOS one already had: it routed gestures on one pattern where the
; canonical file declares two.
global LOGGER_SUB_FILES := []

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

; Window during which a repeated identical line is suppressed. Named rather than
; inlined because the macOS driver holds the same duration in SECONDS, and two
; bare literals in two units, each with a comment claiming to match the other,
; are indistinguishable from two literals that have drifted apart.
; Single source: _shared/modules/timings/constants.toml [logger] dedup_window_ms.
global LOGGER_DEDUP_WINDOW_MS := 5000

; Deduplication state (module-level so tests can reset it via _ResetLogger).
; Suppresses consecutive identical lines within LOGGER_DEDUP_WINDOW_MS; a streak
; that outlives the window re-surfaces. _LastErrTime keeps its historical name for
; the logger-dedup-tick regression guard. Mirrors the macOS driver's _dedup table.
global _LOGGER_DEDUP_KEY := ""
global _LOGGER_DEDUP_LEVEL := ""
global _LOGGER_DEDUP_COUNT := 0
global _LastErrTime := 0





; =============================
; =============================
; ======= 2/ Public API =======
; =============================
; =============================

; Resolve the dated log-file paths for TODAY under <ConfigDir>/autohotkey/logs/,
; creating the directory if needed, and record the date they were built for.
; Resolves _ConfigDir at call time so any later override (paths.toml) is picked
; up. Shared by LoggerInit and the midnight rollover in _LoggerFlush so the
; filename format lives in exactly one place.
; @returns {String} The resolved log directory, with a trailing backslash.
_LoggerResolveDatedPaths() {
		global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_PATH_DATE
		global _ConfigDir, _AhkSubDir

		LogDir := (IsSet(_ConfigDir) and _ConfigDir != "")
				? _ConfigDir . _AhkSubDir . "logs\"
				: A_ScriptDir . "\logs\"
		if !DirExist(LogDir) {
				try DirCreate(LogDir)
		}
		Today := FormatTime(, "yyyy-MM-dd")
		LOGGER_LOG_PATH := LogDir . "ErgoptiPlus_" . Today . ".log"
		LOGGER_ERRORS_LOG_PATH := LogDir . "ErgoptiPlus_errors_" . Today . ".log"
		_LOGGER_PATH_DATE := Today
		return LogDir
}

; Initialise the logger. Reads the minimum level from the ini and resolves the
; log file path. Safe to call multiple times — later calls just refresh the
; minimum level (e.g. after the user changes it via the menu).
LoggerInit() {
		global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL, ConfigurationFile
		global _LOGGER_FLUSH_TIMER_STARTED, LOGGER_FLUSH_INTERVAL_MS, _ConfigDir, _AhkSubDir, _LOGGER_PENDING
		global LOGGER_RETENTION_DAYS

		LogDir := _LoggerResolveDatedPaths()
		_LoggerPurgeOldLogs(LogDir, LOGGER_RETENTION_DAYS)
		; Sub-file routing comes from _generated/logger_sub_files.ahk, generated from
		; _shared/modules/logger/sub_files.toml — adding a topical log is a TOML edit
		; plus a codegen run, never a parser change in two drivers.
		global LOGGER_SUB_FILES
		LOGGER_SUB_FILES := LoggerSubFilesData()
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
		; Now that the user's level is finally known, apply it retroactively to
		; everything the permissive pre-init defaults let through. This is the half
		; of logger-preinit-level-drop that keeps the fail-open default honest.
		_LoggerDropPreInitBelowLevel()

		; Start the background flusher once. LoggerInit may be called again when
		; the user toggles the log level via the menu — we do not restart the
		; timer in that case. OnExit ensures any pending lines are flushed before
		; the driver terminates so crash diagnostics are not lost.
		if !_LOGGER_FLUSH_TIMER_STARTED {
				SetTimer(_LoggerFlush, LOGGER_FLUSH_INTERVAL_MS)
				OnExit(_LoggerOnExitFlush)
				_LOGGER_FLUSH_TIMER_STARTED := True
				; Session boundary marker (matches the macOS driver) so tailing the log
				; reveals where the driver (re)started. Written once per session to the
				; main unified log only — not the ring, errors, or sub-files. The blank
				; line precedes the banner; Chr(0x2014) is the em-dash, kept out of the
				; source so a UTF-8/BOM regression cannot corrupt it.
				SessionStamp := WallClockTimestamp()
				_LOGGER_PENDING.Push("")
				_LOGGER_PENDING.Push("===== " . SessionStamp . " " . Chr(0x2014) . " ErgoptiPlus session opened =====")
		}
		; Drain any lines that were emitted before LoggerInit resolved the log path.
		; Without this flush, every _LoggerEmit call that fired during early boot
		; (before LOGGER_LOG_PATH was set) would silently stay in the pending queue
		; until the next periodic tick (~500 ms), or be lost entirely on a crash.
		_LoggerFlush(false)
}

; Truncates an incomplete append back to its exact pre-write byte boundary.
; The caller retains the logical queue unless the complete append (and, for a
; forced flush, its stable-storage fence) succeeds.
_LoggerTruncateAppend(FileObject, Boundary, FlushFn) {
	try {
		FileObject.Pos := Boundary
		if !DllCall("SetEndOfFile", "Ptr", FileObject.Handle, "Int")
			return false
		return FlushFn.Call(FileObject) == true
	} catch {
		return false
	}
}

; Appends one complete UTF-8 batch or restores the original byte boundary.
; Injectable seams make short writes and failed stable flushes deterministic in
; regression tests without weakening the production filesystem boundary.
_LoggerAppendComplete(Path, Blob, ForceFlush := false, OpenFn := 0,
		FlushFn := 0, TruncateFn := 0) {
	if !(Path is String) or Path = "" or !(Blob is String)
		return false
	ResolvedOpen := HasMethod(OpenFn, "Call") ? OpenFn : FileOpen
	ResolvedFlush := HasMethod(FlushFn, "Call") ? FlushFn : FSFlushFileBuffers
	ResolvedTruncate := HasMethod(TruncateFn, "Call")
		? TruncateFn : _LoggerTruncateAppend
	FileObject := 0
	Boundary := 0
	try {
		FileObject := ResolvedOpen.Call(Path, "a", "UTF-8")
		if !IsObject(FileObject)
			return false
		Boundary := FileObject.Pos
		Written := FileObject.Write(Blob)
		ExpectedBytes := StrPut(Blob, "UTF-8") - 1
		if Written != ExpectedBytes
			throw Error("short logger append")
		if ForceFlush && ResolvedFlush.Call(FileObject) != true
			throw Error("logger stable flush failed")
		FileObject.Close()
		FileObject := 0
		return true
	} catch {
		if IsObject(FileObject)
			try ResolvedTruncate.Call(FileObject, Boundary, ResolvedFlush)
		return false
	} finally {
		if IsObject(FileObject)
			try FileObject.Close()
	}
}

_LoggerFlush(ForceFlush := false) {
	global _LOGGER_FLUSH_ACTIVE, _LOGGER_FORCE_FLUSH_PENDING
	PreviousCritical := Critical("On")
	try {
		if _LOGGER_FLUSH_ACTIVE {
			if ForceFlush
				_LOGGER_FORCE_FLUSH_PENDING := true
			return false
		}
		_LOGGER_FLUSH_ACTIVE := true
	} finally {
		Critical(PreviousCritical)
	}

	ReplayForced := false
	try {
		_LoggerFlushOwned(ForceFlush)
		return true
	} finally {
		PreviousCritical := Critical("On")
		try {
			_LOGGER_FLUSH_ACTIVE := false
			ReplayForced := _LOGGER_FORCE_FLUSH_PENDING
			_LOGGER_FORCE_FLUSH_PENDING := false
		} finally {
			Critical(PreviousCritical)
		}
		; An ERROR emitted while an append was in flight must cross its durable
		; boundary before the owning flush returns. Replay only after relinquishing
		; ownership so rollback boundaries can never overlap.
		if ReplayForced
			_LoggerFlush(true)
	}
}

; Return true only when no queue remains solely owned by this process. The
; inspection is atomic with emitters and flush snapshot publication, so the
; lifecycle can use it as a refusal-capable terminal preflight.
_LoggerHasPendingDebt() {
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_SUB_PENDING
	PreviousCritical := Critical("On")
	try {
		if _LOGGER_PENDING.Length > 0 || _LOGGER_PENDING_ERRORS.Length > 0
			return true
		for _, Lines in _LOGGER_SUB_PENDING {
			if Lines.Length > 0
				return true
		}
		return false
	} finally {
		Critical(PreviousCritical)
	}
}

; Establish the logger's durable shutdown boundary while OnExit may still
; refuse. A successful recovery can enqueue one dropped-lines summary, so one
; bounded successor flush is required before the queues can be declared empty.
; An in-flight owner returns false: after OnExit refusal that owner resumes and
; completes its append instead of being abandoned with its snapshot detached.
LoggerPrepareShutdown() {
	if !_LoggerFlush(true)
		return false
	if _LoggerHasPendingDebt() && !_LoggerFlush(true)
		return false
	return !_LoggerHasPendingDebt()
}

; Drain the pending-lines queue into the log file in one complete append.
; Called only by the serialized owner above. When ``ForceFlush`` is true, both
; the exact byte count and the FlushFileBuffers receipt must succeed before the
; batch is acknowledged. Failure restores the pre-append boundary.
_LoggerFlushOwned(ForceFlush := false) {
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	global _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _LOGGER_PATH_DATE, LOGGER_RETENTION_DAYS

	; Midnight rollover. The driver routinely stays up across several days, so
	; without this the dated filename resolved at init would capture every later
	; entry — misdating the log and making _LoggerPurgeOldLogs, which ages files
	; by the date in their NAME, discard still-recent data. Cheap enough for the
	; flush tick: one FormatTime and a string compare.
	;
	; The topical sub-files ride along. Their paths are undated and stay valid,
	; but they are documented as "today only" and are truncated by the
	; day-change check inside _LoggerInitSubFiles — which, like the dated paths,
	; only ever ran at init. Re-running it here is what actually makes them
	; daily; without it a driver up past midnight accumulates several days in a
	; file the operator reads as today's.
	if (_LOGGER_PATH_DATE != "" and _LOGGER_PATH_DATE != FormatTime(, "yyyy-MM-dd")) {
		RolledDir := _LoggerResolveDatedPaths()
		_LoggerPurgeOldLogs(RolledDir, LOGGER_RETENTION_DAYS)
		_LoggerInitSubFiles(RolledDir)
	}

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

	; A timer can detach this snapshot before midnight and resume after the path
	; rollover above. Route by each line's sampled date, not by the wall clock at
	; flush time, so valid diagnostics never move into the wrong daily archive.
	MainResult := _LoggerAppendDatedQueue(Pending, false,
		_LOGGER_PATH_DATE, ForceFlush)
	if MainResult["failed"].Length > 0
		_LoggerRequeue(MainResult["failed"], [])
	ErrorsResult := _LoggerAppendDatedQueue(PendingErr, true,
		_LOGGER_PATH_DATE, ForceFlush)
	if ErrorsResult["failed"].Length > 0
		_LoggerRequeue([], ErrorsResult["failed"])
	WriteSucceeded := MainResult["wrote"]

	; Drain per-sub-file queues with one verified append each, avoiding one write
	; per matching log line.
	local _crit2 := Critical("On")
	try {
		SubSnap := _LOGGER_SUB_PENDING.Clone()
		_LOGGER_SUB_PENDING := Map()
	} finally {
		Critical(_crit2)
		}
		for Name, Lines in SubSnap {
						DatedLines := _LoggerGroupLinesByDate(Lines, _LOGGER_PATH_DATE)
						; Topical files are deliberately an ephemeral view of today. A delayed
						; previous-day batch remains durable in the dated unified log above but
						; must not repopulate the just-rotated topical files.
						if !DatedLines.Has(_LOGGER_PATH_DATE)
										continue
						Lines := DatedLines[_LOGGER_PATH_DATE]
						if !_LOGGER_SUB_PATHS.Has(Name) {
										_LoggerRequeueSub(Name, Lines)
										continue
						}
						SubBlob := ""
						for _, SLine in Lines {
										SubBlob .= SLine . "`r`n"
						}
						if SubBlob == ""
										continue
						SubWritten := _LoggerAppendComplete(
								_LOGGER_SUB_PATHS[Name], SubBlob, ForceFlush)
						if !SubWritten
										_LoggerRequeueSub(Name, Lines)
	}

	; Report the truncation only once the sink is proven writable again. Emitting
	; while it is dead would push the report onto the very queue that is
	; overflowing; queuing it here means it goes out on the next tick.
	if (WriteSucceeded and _LOGGER_DROPPED_LINES > 0)
		_LoggerEmitDroppedSummary()
}

; Partition a detached queue using the immutable date prefix emitted with each
; formatted line. Undated separators are attached to the next dated record (the
; session banner shape); trailing legacy/test lines use the active path date.
_LoggerGroupLinesByDate(Lines, FallbackDate) {
	Groups := Map()
	Undated := []
	for _, Line in Lines {
		LineDate := ""
		if RegExMatch(Line, "^(\d{4}-\d{2}-\d{2})(?:\s|$)", &DateMatch)
			LineDate := DateMatch[1]
		if (LineDate == "") {
			Undated.Push(Line)
			continue
		}
		if !Groups.Has(LineDate)
			Groups[LineDate] := []
		for _, PrefixLine in Undated
			Groups[LineDate].Push(PrefixLine)
		Undated := []
		Groups[LineDate].Push(Line)
	}
	if Undated.Length > 0 {
		if !Groups.Has(FallbackDate)
			Groups[FallbackDate] := []
		for _, Line in Undated
			Groups[FallbackDate].Push(Line)
	}
	return Groups
}

_LoggerDatedPathForDate(Date, ErrorsOnly := false) {
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_PATH_DATE
	BasePath := ErrorsOnly ? LOGGER_ERRORS_LOG_PATH : LOGGER_LOG_PATH
	; An empty path date is the supported pre-init/test seam: callers may provide
	; an exact sink path without enabling daily rotation ownership.
	if (_LOGGER_PATH_DATE == "" || Date == _LOGGER_PATH_DATE)
		return BasePath
	SlashAt := InStr(BasePath, "\", false, -1)
	if (BasePath == "" || SlashAt == 0)
		return ""
	Prefix := ErrorsOnly ? "ErgoptiPlus_errors_" : "ErgoptiPlus_"
	return SubStr(BasePath, 1, SlashAt) . Prefix . Date . ".log"
}

_LoggerAppendDatedQueue(Lines, ErrorsOnly, FallbackDate, ForceFlush) {
	Result := Map("failed", [], "wrote", false)
	for Date, DatedLines in _LoggerGroupLinesByDate(Lines, FallbackDate) {
		Blob := ""
		for _, Line in DatedLines
			Blob .= Line . "`r`n"
		Path := _LoggerDatedPathForDate(Date, ErrorsOnly)
		if (Path != "" && _LoggerAppendComplete(Path, Blob, ForceFlush)) {
			Result["wrote"] := true
			continue
		}
		for _, Line in DatedLines
			Result["failed"].Push(Line)
	}
	return Result
}

; One-line report of the lines the cap sacrificed, modelled on
; _LoggerEmitDedupSummary: it bypasses _LoggerEmit, rebuilds the timestamp
; itself, and pushes straight onto the ring, the queues and the fan-out. It must
; NOT call _LoggerFlush — this runs FROM _LoggerFlush, so a forced re-entry
; there would recurse.
_LoggerEmitDroppedSummary() {
	global LOGGER_SEVERITY, _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_TEST_SINK
	global _LOGGER_DROPPED_LINES, LOGGER_PENDING_CAP
	Count := _LOGGER_DROPPED_LINES
	_LOGGER_DROPPED_LINES := 0
	Word := (Count == 1) ? "line" : "lines"
	MsgLine := Format("[WARNING] [logger] {1} pending {2} dropped: a queue hit the {3}-line cap while the sink was failing.", Count, Word, LOGGER_PENDING_CAP)
	Line := WallClockTimestamp() . " " . MsgLine
	_LoggerPushRing(Line)
	if _LOGGER_TEST_SINK != 0 {
		try _LOGGER_TEST_SINK(Line)
	}
	_LOGGER_PENDING.Push(Line)
	_LOGGER_PENDING_ERRORS.Push(Line)
	_LoggerFanOut("logger", Line)
}

; Drops the OLDEST entries of Queue until it fits LOGGER_PENDING_CAP, counting
; the casualties in _LOGGER_DROPPED_LINES. Truncating from the front is the
; whole point: the requeue re-inserts its snapshot at index 1, so index 1 is the
; oldest record and the newest diagnostics — the ones describing whatever is
; breaking right now — live at the end. Popping from the back would keep the
; stale history and throw away the evidence.
_LoggerTrimQueueToCap(Queue) {
	global LOGGER_PENDING_CAP, _LOGGER_DROPPED_LINES
	Excess := Queue.Length - LOGGER_PENDING_CAP
	if (Excess <= 0)
		return
	Queue.RemoveAt(1, Excess)
	_LOGGER_DROPPED_LINES += Excess
}

; Restore a failed flush snapshot ahead of records logged while the sink write
; was in flight. This preserves original order and makes the next periodic
; flush retry the exact records rather than silently discarding diagnostics.
_LoggerRequeue(Pending, PendingErr) {
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	local _crit := Critical("On")
	try {
		loop Pending.Length
			_LOGGER_PENDING.InsertAt(1, Pending[Pending.Length - A_Index + 1])
		loop PendingErr.Length
			_LOGGER_PENDING_ERRORS.InsertAt(1, PendingErr[PendingErr.Length - A_Index + 1])
		; Both queues are capped here rather than at each call site: the four
		; callers pass [] for the queue they do not own, so this is the single
		; place every requeued line has to pass through.
		_LoggerTrimQueueToCap(_LOGGER_PENDING)
		_LoggerTrimQueueToCap(_LOGGER_PENDING_ERRORS)
	} finally {
		Critical(_crit)
	}
}

_LoggerOnExitFlush(ExitReason, ExitCode) {
		global _LOGGER_DEDUP_COUNT, _LOGGER_DEDUP_LEVEL
		; If the very last log call before shutdown was itself a suppressed
		; duplicate, its streak's "N more identical lines" summary is still
		; pending — the streak only ever gets flushed when a DIFFERENT line
		; arrives (see _LoggerEmit). Emit it now so a repeating warning/error
		; storm immediately preceding this exit/reload is not silently lost
		; (logger-dedup-streak-lost-on-exit).
		if (_LOGGER_DEDUP_COUNT > 0) {
				_LoggerEmitDedupSummary(_LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT)
				_LOGGER_DEDUP_COUNT := 0
		}
		; Use the forced-flush path on exit too — a subsequent OS kill cannot
		; replay the buffered append.
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

; Retro-applies the configured level to everything that was logged BEFORE
; LoggerInit resolved it.
;
; The pre-init fast-path flags fail OPEN (see their declaration) so no boot-phase
; line is lost before the user's log_level can be read — but that would otherwise
; hand a user running at log_level = ERROR a full boot's worth of DEBUG and INFO
; noise, since _LoggerEmit queues unconditionally while the log path is unknown
; and LoggerInit later drains the whole queue to disk. Filtering the queue here,
; immediately after _LoggerRefreshFastFlags and before the drain, makes the
; pre-init window behave exactly like the post-init one for every level, in both
; directions (logger-preinit-level-drop).
;
; The ring buffer is intentionally NOT level-filtered so live debugging retains
; boot context. Crash reports consume only its redacted line-count summary.
_LoggerDropPreInitBelowLevel() {
		global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, LOGGER_MIN_LEVEL
		Before := _LOGGER_PENDING.Length
		_LOGGER_PENDING := _LoggerFilterQueueByLevel(_LOGGER_PENDING)
		_LOGGER_PENDING_ERRORS := _LoggerFilterQueueByLevel(_LOGGER_PENDING_ERRORS)
		Dropped := Before - _LOGGER_PENDING.Length
		if (Dropped > 0) {
				LoggerDebug("logger", "Dropped {1} pre-init line(s) below the configured level '{2}'.",
						Dropped, LOGGER_MIN_LEVEL)
		}
}

; Returns a copy of ``Queue`` holding only the lines at or above the cached
; minimum severity. A formatted line looks like
; "yyyy-MM-dd HH:mm:ss:fff [LEVEL] [Tag] body", so the first "[WORD] [" pair is
; always the level; anything without one is structural (the blank separator, the
; session banner) and is always kept.
_LoggerFilterQueueByLevel(Queue) {
		global LOGGER_SEVERITY, _LOGGER_MIN_SEVERITY
		Kept := []
		for _, Line in Queue {
				if !RegExMatch(Line, "\[([A-Z]+)\] \[", &M) {
						Kept.Push(Line)
						continue
				}
				if !LOGGER_SEVERITY.Has(M[1]) {
						Kept.Push(Line)
						continue
				}
				if (LOGGER_SEVERITY[M[1]] >= _LOGGER_MIN_SEVERITY) {
						Kept.Push(Line)
				}
		}
		return Kept
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

; Appends one DEBUG diagnostic to a fixed-name auxiliary log while retaining at
; most one bounded archive. The optional cap exists for deterministic regression
; tests; production callers share LOGGER_AUXILIARY_LOG_MAX_BYTES.
LoggerAppendBoundedDebug(Path, Line, MaxBytes := 0) {
	global LOGGER_AUXILIARY_LOG_MAX_BYTES
	if !LoggerIsDebugEnabled()
		return false
	if !(Path is String) || Path == "" || !(Line is String)
		return false
	if !MaxBytes
		MaxBytes := LOGGER_AUXILIARY_LOG_MAX_BYTES
	if Type(MaxBytes) != "Integer" || MaxBytes < 4
		return false
	Payload := Line . "`r`n"
	PayloadBytes := StrPut(Payload, "UTF-8") - 1
	; AHK writes a three-byte UTF-8 BOM when creating a new text file.
	if PayloadBytes + 3 > MaxBytes
		return false
	ArchivePath := Path . ".1"
	try {
		if FileExist(ArchivePath) && FileGetSize(ArchivePath) > MaxBytes
			FileDelete(ArchivePath)
		CurrentBytes := FileExist(Path) ? FileGetSize(Path) : 0
		NextBytes := CurrentBytes + PayloadBytes + (CurrentBytes == 0 ? 3 : 0)
		if NextBytes > MaxBytes {
			if FileExist(ArchivePath)
				FileDelete(ArchivePath)
			; A legacy file may already exceed the newly enforced cap. Rotating that
			; debt would merely preserve an oversized owner, so discard it once.
			if CurrentBytes > MaxBytes
				FileDelete(Path)
			else if FileExist(Path)
				FileMove(Path, ArchivePath, true)
		}
		if !_LoggerAppendComplete(Path, Payload)
			return false
		return FileGetSize(Path) <= MaxBytes
	} catch {
		return false
	}
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





; ===================================
; ===================================
; ======= 3/ Internal helpers =======
; ===================================
; ===================================

; Format and emit a log line if the current level allows it. Best-effort —
; never raises so a logging failure cannot break the driver. Hot-path-safe.
_LoggerEmit(Level, Tag, Msg, Args*) {
		global LOGGER_LOG_PATH, LOGGER_MIN_LEVEL, LOGGER_SEVERITY, _LOGGER_PENDING
		global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime
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
				} catch as FormatErr {
						; A bad format string must not break the driver, but falling back to
						; the raw template SILENTLY is the worst of both worlds: the line
						; still looks like a log entry while carrying none of its
						; information — every placeholder intact, every value gone — and
						; nothing anywhere records that the substitution failed (fail-fast contract).
						; Recursing into the logger to report it risks a loop on the hot
						; path, so the evidence rides on the emitted line itself.
						Body := Msg . "  [!! log format failed: " . FormatErr.Message
								. " — " . Args.Length . " arg(s) not substituted]"
				}
		}
		; The shared wall-clock helper caches the second-resolution text while
		; sampling seconds and milliseconds from one non-interruptible SYSTEMTIME.
		Stamp := WallClockTimestamp()
		; Timestamp-independent message identity — the dedup key. Matches the macOS
		; logger, which dedups on its "[LEVEL] [module] body" line.
		MsgLine := Format("[{1}] [{2}] {3}", Level, Tag, Body)
		Line := Stamp . " " . MsgLine

		; ── Deduplication ──
		; Suppress consecutive identical lines (any level) within a 5000 ms window so a
		; recurring line is de-bounced, not permanently silenced (logger-dedup-tick): a
		; streak that outlives the window re-surfaces. When the streak ends a single
		; "N identical lines suppressed" summary is emitted. Mirrors the macOS driver.
		if (MsgLine == _LOGGER_DEDUP_KEY and ((A_TickCount - _LastErrTime + 0x100000000) & 0xFFFFFFFF) < LOGGER_DEDUP_WINDOW_MS) {
				_LOGGER_DEDUP_COUNT += 1
				return
		}
		if (_LOGGER_DEDUP_COUNT > 0) {
				_LoggerEmitDedupSummary(_LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT)
		}
		_LOGGER_DEDUP_KEY := MsgLine
		_LOGGER_DEDUP_LEVEL := Level
		_LOGGER_DEDUP_COUNT := 0
		_LastErrTime := A_TickCount

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
	; flush. _LoggerFlush() skips the append when the path is still empty,
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

; Emits the "[LEVEL] [logger] (up-arrow) N identical lines suppressed" summary that
; closes a dedup streak, matching the macOS logger byte-for-byte. Chr(0x2191) keeps
; the up-arrow out of the source so a UTF-8/BOM encoding regression cannot corrupt it.
; Takes the same ring / pending / errors / fan-out path as a normal line, but never
; fires the healthcheck hooks (a suppressed warning/error storm is counted once, on
; its first occurrence, exactly like the deduped output).
_LoggerEmitDedupSummary(Level, Count) {
	global LOGGER_SEVERITY, _LOGGER_PENDING, _LOGGER_PENDING_ERRORS, _LOGGER_TEST_SINK
	Word := (Count == 1) ? "line" : "lines"
	MsgLine := Format("[{1}] [logger] {2} {3} identical {4} suppressed", Level, Chr(0x2191), Count, Word)
	Line := WallClockTimestamp() . " " . MsgLine
	_LoggerPushRing(Line)
	if _LOGGER_TEST_SINK != 0 {
		try _LOGGER_TEST_SINK(Line)
	}
	_LOGGER_PENDING.Push(Line)
	if LOGGER_SEVERITY[Level] >= LOGGER_SEVERITY["WARNING"] {
		_LOGGER_PENDING_ERRORS.Push(Line)
	}
	if LOGGER_SEVERITY[Level] >= LOGGER_SEVERITY["ERROR"] {
		_LoggerFlush(true)
	}
	_LoggerFanOut("logger", Line)
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

; Restore one failed sub-file snapshot ahead of entries emitted while its I/O
; was in flight. A sub-file is an operator-facing diagnostic sink, not a
; disposable view: losing it precisely when disk access fails hides recovery
; evidence from the person investigating the incident.
_LoggerRequeueSub(Name, Lines) {
		global _LOGGER_SUB_PENDING
		if (Lines.Length == 0)
						return
		local _crit := Critical("On")
		try {
						Current := _LOGGER_SUB_PENDING.Has(Name) ? _LOGGER_SUB_PENDING[Name] : []
						Restored := []
						for Index, Line in Lines
										Restored.Push(Line)
						for Index, Line in Current
										Restored.Push(Line)
						; _LOGGER_SUB_PENDING is a Map OF queues, one per sub-file, so the cap
						; has to apply per queue — capping the Map would bound the number of
						; sub-files, which is fixed anyway, and not their contents.
						_LoggerTrimQueueToCap(Restored)
						_LOGGER_SUB_PENDING[Name] := Restored
		} finally {
						Critical(_crit)
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
