; tests/unit/core/logger/test_retired_topical_logs.ahk

; ==============================================================================
; MODULE: Retired Topical Log Cleanup Tests
; DESCRIPTION:
; One daily log is the only log (maintainer decision, 2026-11-25): testers had
; to send dozens of files, and every line of the topical sub-files
; (ErgoptiPlus_hotstrings.log, ErgoptiPlus_menu.log...) was also in the daily
; log. The logger no longer writes them, and its retention sweep deletes the
; old ones by their exact generated names (AppDirsRetiredTopicalLogs).
;
; ROOT CAUSE ENCODED:
; 1. The sweep deletes every retired name that is a regular file directly in
;    the logs folder, and nothing else: not the daily log, not a user file that
;    merely starts with the prefix, not a folder that carries a retired name.
; 2. A routed tag no longer produces a topical file: a "[Hotstring]" line
;    reaches the daily log alone, and no fan-out call is left in the logger.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==========================================
; ==========================================
; ======= 1/ Helpers =======================
; ==========================================
; ==========================================

; A fresh logs folder under A_Temp, with its trailing backslash.
_LRTL_Folder() {
	Dir := A_Temp . "\ergopti_retired_topical_" . DllCall("Kernel32\GetCurrentProcessId", "UInt")
		. "_" . A_TickCount . "\"
	DirCreate(Dir)
	return Dir
}

_LRTL_Today() {
	return AppDirsLogUnifiedPrefix() . FormatTime(, "yyyy-MM-dd") . AppDirsLogExtension()
}




; ==========================================
; ==========================================
; ======= 2/ Test implementations ==========
; ==========================================
; ==========================================

; Runs Body with warnings and info lines dropped, so the sweep's own report
; reaches neither the runner's log nor the health check counters.
_LRTL_Quiet(Body) {
	global LOGGER_MIN_LEVEL
	State := _TLOG_CaptureLoggerState()
	try {
		LOGGER_MIN_LEVEL := "ERROR"
		_LoggerRefreshFastFlags()
		Body.Call()
	} finally {
		_TLOG_RestoreLoggerState(State)
	}
}

_LRTL_SweepDeletesOnlyRetiredRegularFiles() {
	_LRTL_Quiet(_LRTL_SweepDeletesOnlyRetiredRegularFilesBody)
}

_LRTL_SweepDeletesOnlyRetiredRegularFilesBody() {
	Retired := AppDirsRetiredTopicalLogs()
	AssertEqual(13, Retired.Length, "the 13 topical files every driver used to write")
	Dir := _LRTL_Folder()
	; A folder carrying a retired name is not a file the logger wrote.
	KeptFolder := Retired[Retired.Length]
	try {
		for Name in Retired {
			if (Name == KeptFolder)
				DirCreate(Dir . Name)
			else
				FileAppend("old topical copy`n", Dir . Name, "UTF-8")
		}
		FileAppend("a note the user keeps here`n", Dir . AppDirsLogUnifiedPrefix() . "notes.txt", "UTF-8")
		FileAppend("today`n", Dir . _LRTL_Today(), "UTF-8")

		_LoggerPurgeOldLogs(Dir, 14)

		for Name in Retired {
			if (Name == KeptFolder)
				AssertTrue(InStr(FileExist(Dir . Name), "D") > 0, "a folder named " . Name . " must be kept")
			else
				AssertEqual("", FileExist(Dir . Name), Name . " must be deleted by the sweep")
		}
		AssertTrue(FileExist(Dir . AppDirsLogUnifiedPrefix() . "notes.txt") != "",
			"a file that is not a retired name must be kept")
		AssertTrue(FileExist(Dir . _LRTL_Today()) != "", "today's daily log must be kept")
	} finally {
		try DirDelete(Dir, true)
	}
}

global _LRTL_DELETED := []

_LRTL_FakeExists(Attributes, Path) {
	return Attributes
}

_LRTL_FakeDelete(Refused, Path) {
	global _LRTL_DELETED
	if (Refused != "" && InStr(Path, Refused))
		throw OSError(5, A_ThisFunc, "injected refusal")
	_LRTL_DELETED.Push(Path)
}

_LRTL_SweepSkipsReparsePointsAndSurvivesRefusals() {
	_LRTL_Quiet(_LRTL_SweepSkipsReparsePointsAndSurvivesRefusalsBody)
}

_LRTL_SweepSkipsReparsePointsAndSurvivesRefusalsBody() {
	global _LRTL_DELETED
	Retired := AppDirsRetiredTopicalLogs()
	_LRTL_DELETED := []
	AssertEqual(0, _LoggerDeleteRetiredTopicalLogs("X:\logs\", _LRTL_FakeExists.Bind("AL"),
		_LRTL_FakeDelete.Bind("")), "a reparse point carrying a retired name is never deleted")
	AssertEqual(0, _LRTL_DELETED.Length)
	AssertEqual(0, _LoggerDeleteRetiredTopicalLogs("X:\logs\", _LRTL_FakeExists.Bind(""),
		_LRTL_FakeDelete.Bind("")), "an absent file is not a deletion")
	Deleted := _LoggerDeleteRetiredTopicalLogs("X:\logs\", _LRTL_FakeExists.Bind("A"),
		_LRTL_FakeDelete.Bind(Retired[1]))
	AssertEqual(Retired.Length - 1, Deleted, "one refusal must not stop the other deletions")
	for Path in _LRTL_DELETED
		AssertEqual("X:\logs\", SubStr(Path, 1, 8), "only names directly in the logs folder")
}

_LRTL_RoutedTagWritesTheDailyLogOnly() {
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH, _LOGGER_PATH_DATE, LOGGER_MIN_LEVEL
	global _LOGGER_REPEAT_ENABLED, _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_COUNT
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	Source := _DriverSourceNoComments()
	Assert(Source != "", "driver source must be readable")
	AssertEqual(0, InStr(Source, "_LoggerFanOut("), "no topical fan-out may remain in the logger")
	InitBody := _DriverFuncBody("LoggerInit")
	Assert(InitBody != "", "LoggerInit must be readable")
	AssertEqual(0, InStr(InitBody, "LoggerSubFilesData("), "LoggerInit no longer reads a topical routing table")

	State := _TLOG_CaptureLoggerState()
	SavedPathDate := _LOGGER_PATH_DATE
	WasRepeating := _LOGGER_REPEAT_ENABLED
	Dir := _LRTL_Folder()
	try {
		if WasRepeating
			_LoggerRepeatDisable()
		LOGGER_LOG_PATH := Dir . _LRTL_Today()
		LOGGER_ERRORS_LOG_PATH := ""
		; Fresh queues: the runner's own pending lines stay out of the fixture.
		_LOGGER_PENDING := [], _LOGGER_PENDING_ERRORS := []
		; An empty path date keeps the exact fixture path without a rollover.
		_LOGGER_PATH_DATE := ""
		LOGGER_MIN_LEVEL := "DEBUG"
		_LoggerRefreshFastFlags()
		_LOGGER_DEDUP_KEY := "", _LOGGER_DEDUP_COUNT := 0
		LoggerInfo("Hotstring", "retired topical routing probe")
		_LoggerFlush(true)
		AssertContains(FileRead(LOGGER_LOG_PATH, "UTF-8"), "[Hotstring] retired topical routing probe",
			"the line must reach the daily log")
		loop files, Dir . "*"
			AssertEqual(_LRTL_Today(), A_LoopFileName, "the daily log must be the only file written")
	} finally {
		_LOGGER_PATH_DATE := SavedPathDate
		_TLOG_RestoreLoggerState(State)
		if (WasRepeating && !_LOGGER_REPEAT_ENABLED)
			_LoggerRepeatEnable()
		try DirDelete(Dir, true)
	}
}





; =====================================
; =====================================
; ======= 3/ Test registrations =======
; =====================================
; =====================================

Test("logger: the sweep deletes the retired topical files and nothing else (logs-single-file)",
	_LRTL_SweepDeletesOnlyRetiredRegularFiles)
Test("logger: the retired topical sweep skips reparse points and survives a refusal (logs-single-file)",
	_LRTL_SweepSkipsReparsePointsAndSurvivesRefusals)
Test("logger: a routed tag reaches the daily log and creates no topical file (logs-single-file)",
	_LRTL_RoutedTagWritesTheDailyLogOnly)
