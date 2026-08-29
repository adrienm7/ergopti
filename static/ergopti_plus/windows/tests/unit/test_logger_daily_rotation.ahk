; static/ergopti_plus/windows/tests/unit/test_logger_daily_rotation.ahk

; ==============================================================================
; MODULE: Logger Daily Rotation Tests
; DESCRIPTION:
; Regression guard for the "daily-rotating" log file that only ever rotated on
; restart. LOGGER_LOG_PATH was built from FormatTime once inside LoggerInit, so
; a driver left running across midnight kept appending to the file named for its
; START date. Field evidence: ErgoptiPlus_2026-07-11.log held entries dated
; 07-11 through 07-14.
;
; FEATURES & RATIONALE:
; 1. Encodes the ROOT CAUSE, not the symptom: the assertion is that the flush
;    path RE-RESOLVES the dated paths when the calendar date has moved, rather
;    than that some file happens to carry today's name. A fix that merely
;    renamed things would still fail this.
; 2. Behavioural, not a source grep: it drives _LoggerFlush with a stale
;    _LOGGER_PATH_DATE and inspects the resulting globals.
; 3. Guards the second-order consequence too. _LoggerPurgeOldLogs ages files by
;    the date in their NAME, so a stale name meant recent data was discarded
;    early; the retention window must therefore be one shared constant.
; 4. Hermetic: _ConfigDir is redirected into A_Temp for the duration so the
;    rollover's purge can never touch the developer's real log directory.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================
; ==========================================
; ======= 1/ Test implementations ==========
; ==========================================
; ==========================================

; Redirect the logger's directory resolution into a throwaway temp folder and
; run ``Body`` there. Restores the previous globals unconditionally so a failing
; assertion cannot leak the redirection into the rest of the suite.
_LDR_WithTempConfigDir(Body) {
	global _ConfigDir, _AhkSubDir, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_PATH_DATE

	HadConfigDir := IsSet(_ConfigDir)
	HadSubDir := IsSet(_AhkSubDir)
	PrevConfigDir := HadConfigDir ? _ConfigDir : ""
	PrevSubDir := HadSubDir ? _AhkSubDir : ""
	PrevPath := LOGGER_LOG_PATH
	PrevErrPath := LOGGER_ERRORS_LOG_PATH
	PrevDate := _LOGGER_PATH_DATE

	_ConfigDir := A_Temp . "\ergopti_logrotate_test\"
	_AhkSubDir := "autohotkey\"
	try {
		Body()
	} finally {
		_ConfigDir := PrevConfigDir
		_AhkSubDir := PrevSubDir
		LOGGER_LOG_PATH := PrevPath
		LOGGER_ERRORS_LOG_PATH := PrevErrPath
		_LOGGER_PATH_DATE := PrevDate
	}
}

; The core regression: a flush that happens after the calendar date has moved
; must re-resolve both dated paths. Before the fix _LoggerFlush had no notion of
; the date at all, so the stale path survived and every later entry was misfiled.
_LDR_FlushRotatesOnDateChange() {
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_PATH_DATE

	_LDR_WithTempConfigDir(() => _LDR_AssertRotation())
}

_LDR_AssertRotation() {
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_PATH_DATE

	_LoggerResolveDatedPaths()
	Today := FormatTime(, "yyyy-MM-dd")
	Assert(InStr(LOGGER_LOG_PATH, Today) > 0,
		"_LoggerResolveDatedPaths must build the main log path for today")
	Assert(_LOGGER_PATH_DATE == Today,
		"_LoggerResolveDatedPaths must record the date it resolved for")

	; Simulate the driver having been started on an earlier day: the paths still
	; point at that day's files, exactly as they did after a real overnight run.
	StaleDate := "2000-01-01"
	_LOGGER_PATH_DATE := StaleDate
	LOGGER_LOG_PATH := A_Temp . "\ergopti_logrotate_test\autohotkey\logs\ErgoptiPlus_" . StaleDate . ".log"
	LOGGER_ERRORS_LOG_PATH := A_Temp . "\ergopti_logrotate_test\autohotkey\logs\ErgoptiPlus_errors_" . StaleDate . ".log"

	_LoggerFlush(false)

	Assert(_LOGGER_PATH_DATE == Today,
		"_LoggerFlush must re-resolve the dated paths once the calendar date has moved — otherwise the log keeps the start date forever")
	Assert(InStr(LOGGER_LOG_PATH, Today) > 0,
		"the main log path must carry today's date after a rollover flush")
	Assert(InStr(LOGGER_ERRORS_LOG_PATH, Today) > 0,
		"the errors-only log path must rotate together with the main log")
	Assert(InStr(LOGGER_LOG_PATH, StaleDate) == 0,
		"the stale start-date filename must not survive the rollover")
}

; The topical sub-files are the missed sibling of the same defect. Their paths
; are undated, so they look immune — but they are documented as "today only"
; and the check that truncates a previous day's file lives in
; _LoggerInitSubFiles, which only ran at init. A rollover must re-run it, or a
; driver up past midnight silently presents several days as today's.
_LDR_RolloverAlsoRollsSubFiles() {
	FlushBody := _DriverFuncBody("_LoggerFlushOwned")
	Assert(FlushBody != "", "_LoggerFlushOwned must exist in infra/logger.ahk")

	Found := RegExMatch(FlushBody,
		"_LOGGER_PATH_DATE\s*!=\s*FormatTime[^}]*_LoggerInitSubFiles\(")
	Assert(Found,
		"the midnight rollover branch in _LoggerFlush must re-run _LoggerInitSubFiles, otherwise the topical sub-files keep accumulating a previous day's lines")
}

; A flush on the SAME day must not churn the paths. This pins the guard to a
; date comparison rather than an unconditional re-resolve on every tick, which
; would put a DirExist + FormatTime + two string builds on the flush path.
_LDR_FlushIsStableWithinTheSameDay() {
	_LDR_WithTempConfigDir(() => _LDR_AssertStability())
}

_LDR_AssertStability() {
	global LOGGER_LOG_PATH, _LOGGER_PATH_DATE

	_LoggerResolveDatedPaths()
	Before := LOGGER_LOG_PATH
	_LoggerFlush(false)
	Assert(LOGGER_LOG_PATH == Before,
		"_LoggerFlush must leave the paths untouched when the date has not changed")
}

; The rollover purge and the boot purge must share one retention constant. When
; the two drifted apart, a rotation could apply a different window than boot and
; silently delete more than intended.
_LDR_RetentionIsSingleSourced() {
	global LOGGER_RETENTION_DAYS

	Assert(IsSet(LOGGER_RETENTION_DAYS),
		"LOGGER_RETENTION_DAYS must exist as the single source of truth for the retention window")
	Assert(LOGGER_RETENTION_DAYS > 0,
		"LOGGER_RETENTION_DAYS must be a positive number of days")

	Body := _DriverFuncBody("LoggerInit")
	Assert(Body != "", "LoggerInit must exist in infra/logger.ahk")
	Assert(RegExMatch(Body, "_LoggerPurgeOldLogs\([^)]*LOGGER_RETENTION_DAYS") > 0,
		"LoggerInit must purge using LOGGER_RETENTION_DAYS, never a bare literal")

	FlushBody := _DriverFuncBody("_LoggerFlushOwned")
	Assert(FlushBody != "", "_LoggerFlushOwned must exist in infra/logger.ahk")
	Assert(RegExMatch(FlushBody, "_LoggerPurgeOldLogs\([^)]*LOGGER_RETENTION_DAYS") > 0,
		"the midnight rollover must purge using the same LOGGER_RETENTION_DAYS constant as boot")
}

_LDR_PreMidnightBatchKeepsItsEmissionDate() {
	global _ConfigDir, _AhkSubDir, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	global _LOGGER_PATH_DATE, _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS

	PreviousConfigDir := _ConfigDir
	PreviousAhkSubDir := _AhkSubDir
	PreviousPath := LOGGER_LOG_PATH
	PreviousErrorsPath := LOGGER_ERRORS_LOG_PATH
	PreviousPathDate := _LOGGER_PATH_DATE
	PreviousPending := _LOGGER_PENDING
	PreviousPendingErrors := _LOGGER_PENDING_ERRORS
	PreviousSubFiles := LOGGER_SUB_FILES
	PreviousSubPending := _LOGGER_SUB_PENDING
	PreviousSubPaths := _LOGGER_SUB_PATHS
	Root := A_Temp . "\ergopti_logger_midnight_route_"
		. DllCall("Kernel32\GetCurrentProcessId", "UInt") . "_" . A_TickCount . "\"
	YesterdayCompact := DateAdd(FormatTime(, "yyyyMMdd"), -1, "Days")
	Yesterday := FormatTime(YesterdayCompact, "yyyy-MM-dd")
	OldLine := Yesterday . " 23:59:59:999 [INFO] [test] before midnight"
	SubName := "midnight-topic.log"
	try {
		_ConfigDir := Root
		_AhkSubDir := "autohotkey\"
		LogDir := Root . _AhkSubDir . "logs\"
		DirCreate(LogDir)
		_LOGGER_PATH_DATE := Yesterday
		LOGGER_LOG_PATH := LogDir . "ErgoptiPlus_" . Yesterday . ".log"
		LOGGER_ERRORS_LOG_PATH := LogDir . "ErgoptiPlus_errors_" . Yesterday . ".log"
		LOGGER_SUB_FILES := [Map("name", SubName, "tags", ["[test]"])]
		_LOGGER_PENDING := [OldLine]
		_LOGGER_PENDING_ERRORS := [OldLine]
		_LOGGER_SUB_PENDING := Map(SubName, [OldLine])
		_LOGGER_SUB_PATHS := Map()

		_LoggerFlush(false)

		OldText := FileExist(LogDir . "ErgoptiPlus_" . Yesterday . ".log")
			? FileRead(LogDir . "ErgoptiPlus_" . Yesterday . ".log", "UTF-8") : ""
		TodayText := FileExist(LOGGER_LOG_PATH)
			? FileRead(LOGGER_LOG_PATH, "UTF-8") : ""
		OldErrorsPath := LogDir . "ErgoptiPlus_errors_" . Yesterday . ".log"
		OldErrorsText := FileExist(OldErrorsPath) ? FileRead(OldErrorsPath, "UTF-8") : ""
		TodayErrorsText := FileExist(LOGGER_ERRORS_LOG_PATH)
			? FileRead(LOGGER_ERRORS_LOG_PATH, "UTF-8") : ""
		TodaySubPath := LogDir . SubName
		TodaySubText := FileExist(TodaySubPath) ? FileRead(TodaySubPath, "UTF-8") : ""
		Assert(InStr(OldText, OldLine) > 0,
			"a line emitted before midnight must be appended to its dated file")
		Assert(InStr(TodayText, OldLine) == 0,
			"a rollover flush must not misroute a previous-day line into today's file")
		Assert(InStr(OldErrorsText, OldLine) > 0,
			"the errors-only archive must use the line's emission date too")
		Assert(InStr(TodayErrorsText, OldLine) == 0,
			"the current errors file must not adopt a previous-day warning")
		Assert(InStr(TodaySubText, OldLine) == 0,
			"a today-only topical file must discard a delayed previous-day projection")
	} finally {
		_ConfigDir := PreviousConfigDir
		_AhkSubDir := PreviousAhkSubDir
		LOGGER_LOG_PATH := PreviousPath
		LOGGER_ERRORS_LOG_PATH := PreviousErrorsPath
		_LOGGER_PATH_DATE := PreviousPathDate
		_LOGGER_PENDING := PreviousPending
		_LOGGER_PENDING_ERRORS := PreviousPendingErrors
		LOGGER_SUB_FILES := PreviousSubFiles
		_LOGGER_SUB_PENDING := PreviousSubPending
		_LOGGER_SUB_PATHS := PreviousSubPaths
		try DirDelete(Root, true)
	}
}


Test("logger: a flush after midnight re-resolves the dated log paths",
	_LDR_FlushRotatesOnDateChange)
Test("logger: a flush within the same day leaves the log paths untouched",
	_LDR_FlushIsStableWithinTheSameDay)
Test("logger: boot and rollover purge share one retention constant",
	_LDR_RetentionIsSingleSourced)
Test("logger: the midnight rollover also rolls the topical sub-files",
	_LDR_RolloverAlsoRollsSubFiles)
Test("logger: a queued pre-midnight line keeps its emission-date file "
	. "(logger-midnight-batch-routing)",
	_LDR_PreMidnightBatchKeepsItsEmissionDate)
