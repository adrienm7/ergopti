; tests/unit/diagnostics/ui/test_log_export.ahk

; ==============================================================================
; MODULE: Log Export Tests (Windows)
; DESCRIPTION:
; « Export the logs (zip) » in the Debug menu (maintainer decision,
; 2026-11-25): testers sent dozens of log files, with their typed text in them.
;
; ROOT CAUSE ENCODED:
; 1. The AutoHotkey port selects, names and scrubs exactly as the shared
;    vectors (_shared/tests/corpus/logger/log_export_vectors.json) say, which
;    the macOS and Linux suites replay through the shared Lua engine.
; 2. The action archives only scrubbed copies, lands one archive in the
;    Downloads folder, copies its path, reveals it and tells the user; an empty
;    folder and a refused tar are told too, and no partial archive or staging
;    folder is left behind.
; 3. The Debug menu draws the row right after « open today's errors file ».
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================
; ===============================
; ======= 1/ Helpers ============
; ===============================
; ===============================

_LEX_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\logger\log_export_vectors.json", "UTF-8"))
}

; A fresh folder under A_Temp, with its trailing backslash.
_LEX_Folder(Name) {
	Dir := A_Temp . "\ergopti_log_export_" . Name . "_" . DllCall("Kernel32\GetCurrentProcessId", "UInt")
		. "_" . A_TickCount . "\"
	DirCreate(Dir)
	return Dir
}

; Runs Body with the logger, the health check counters and the error dialog
; policy restored afterwards: the failure cases log an ERROR on purpose.
; The export reads the logs only after LoggerFlushForRead, which refuses while
; any line is still owed to a sink. The suite's shared logger has no errors
; sink (test_logger.ahk), so any WARNING or ERROR queued for it stays owed
; and made every export refuse before it looked at a file. Each case starts
; from an empty logger writing to sinks of its own, as the log openers do.
_LEX_Isolated(Body) {
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy
	global _LOGGER_REPEAT_ENABLED, _LOGGER_TEST_SINK, LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	SavedLogger := _TLOG_CaptureLoggerState()
	Repeat := _LOGGER_REPEAT_ENABLED, Sink := _LOGGER_TEST_SINK
	SavedOptional := Map()
	for Name in ["_HealthCheckWarnCount", "_HealthCheckLastError", "_HealthCheckErrCount", "_ED_Policy"]
		SavedOptional[Name] := { Present: IsSet(%Name%), Value: IsSet(%Name%) ? %Name% : 0 }
	Sinks := _LEX_Folder("sinks")
	try {
		_ResetLogger()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_TEST_SINK := 0
		LOGGER_LOG_PATH := Sinks . "main.log", LOGGER_ERRORS_LOG_PATH := Sinks . "errors.log"
		_LoggerRefreshFastFlags()
		AssertTrue(LoggerFlushForRead(), "the isolated logger owes nothing to a sink")
		_ED_Policy := 0
		Body.Call()
	} finally {
		_TLOG_RestoreLoggerState(SavedLogger)
		_LOGGER_REPEAT_ENABLED := Repeat, _LOGGER_TEST_SINK := Sink
		_LoggerRefreshFastFlags()
		for Name, Saved in SavedOptional
			%Name% := Saved.Present ? Saved.Value : unset
		try DirDelete(Sinks, true)
	}
}

; Records every call of a seam and answers with Result.
_LEX_Recorder(Calls, Result, Args*) {
	Calls.Push(Args)
	return Result
}

; The tar seam: checks the staged copies, then writes the archive tar would.
_LEX_FakeTar(State, ExitCode, Command) {
	State.Commands.Push(Command)
	AssertTrue(RegExMatch(Command, '-C "([^"]+)"', &Staging), "the command names its staging folder")
	State.Staging := Staging[1]
	Staged := ""
	loop files, Staging[1] . "\*", "FR"
		Staged .= FileRead(A_LoopFileFullPath, "UTF-8")
	State.Staged := Staged
	AssertTrue(RegExMatch(Command, '-f "([^"]+)"', &Zip), "the command names its archive")
	FileAppend("PK fake archive", Zip[1], "UTF-8-RAW")
	return ExitCode
}

_LEX_Seams(State, LogsDir, DefaultDir, Destination, ExitCode := 0) {
	State.Commands := [], State.Clipboard := [], State.Reveal := [], State.Notify := []
	State.Staging := "", State.Staged := ""
	return Map(
		"run_wait", _LEX_FakeTar.Bind(State, ExitCode),
		"clipboard", _LEX_Recorder.Bind(State.Clipboard, true),
		"reveal", _LEX_Recorder.Bind(State.Reveal, true),
		"notify", _LEX_Recorder.Bind(State.Notify, 1),
		"downloads", () => Destination,
		"now", () => "20261125103000",
		"logs_dir", LogsDir,
		"default_dir", DefaultDir,
		"temp_dir", State.Temp)
}




; ==========================================
; ==========================================
; ======= 2/ Test implementations ==========
; ==========================================
; ==========================================

_LEX_SelectionVectors() {
	Corpus := _LEX_Corpus()
	Replayed := 0
	for Vector in Corpus["selection"] {
		if Vector["platform"] != "ahk"
			continue
		Replayed += 1
		Selected := LogExport_Select(Map("platform", "ahk", "today", Vector["today"], "days", Vector["days"],
			"logs", Vector["logs"], "default", Vector["default"], "crash_reports", Vector["crash_reports"]))
		AssertEqual(Vector["expected"].Length, Selected.Length, Vector["name"] . ": count")
		for Index, Expected in Vector["expected"] {
			for Field in ["folder", "name", "archive"]
				AssertEqual(Expected[Field], Selected[Index][Field], Vector["name"] . " #" . Index . " " . Field)
		}
	}
	AssertTrue(Replayed >= 1, "the corpus holds a Windows selection vector")
	AssertEqual(0, LogExport_Select(Map("today", "2026-11-25", "logs", AppDirsRetiredTopicalLogs(),
		"default", [], "crash_reports", [])).Length, "a retired topical file is never archived")
}

_LEX_ArchiveNameVector() {
	Vector := _LEX_Corpus()["archive_name"]
	Stamp := Vector["stamp"]
	Compact := Format("{:04}{:02}{:02}{:02}{:02}{:02}", Stamp["year"], Stamp["month"], Stamp["day"],
		Stamp["hour"], Stamp["min"], Stamp["sec"])
	AssertEqual(Vector["expected"], LogExport_ArchiveName(Compact))
}

_LEX_ScrubVectors() {
	Corpus := _LEX_Corpus()
	AssertTrue(Corpus["scrub"].Length >= 10, "the corpus holds its scrub vectors")
	for Vector in Corpus["scrub"] {
		Input := Chr(0xFEFF)
		for Line in Vector["input"]
			Input .= Line . "`r`n"
		Expected := ""
		for Line in Vector["expected"]
			Expected .= Line . "`n"
		Output := LogExport_ScrubText(Input)
		AssertEqual(Expected, Output, Vector["name"])
		for Secret in Vector["secrets"]
			AssertEqual(0, InStr(Output, Secret, true), Vector["name"] . " keeps " . Secret)
	}
}

_LEX_RefusesMalformedInput() {
	AssertThrows(() => LogExport_WindowDates("25/11/2026", 3))
	AssertThrows(() => LogExport_WindowDates("2026-11-25", 0))
	AssertThrows(() => LogExport_Select(Map("platform", "hs", "today", "2026-11-25")))
	AssertThrows(() => LogExport_ArchiveName("2026-11-25"))
	AssertEqual(3, LogExport_WindowDates("2027-01-01", 3).Length)
	AssertEqual("2026-12-30", LogExport_WindowDates("2027-01-01", 3)[3], "the window crosses a year boundary")
}

_LEX_TarCommandIsAbsoluteAndQuoted() {
	Command := LogExport_BuildTarCommand("C:\Out\logs.zip.partial", "C:\Stage", ["a.log", "crash_reports/b.json"])
	AssertEqual('"' . A_WinDir . '\System32\tar.exe" -c --format zip -f "C:\Out\logs.zip.partial" -C "C:\Stage"'
		. ' "a.log" "crash_reports/b.json"', Command)
	AssertThrows(() => LogExport_BuildTarCommand('C:\O"ut.zip', "C:\Stage", ["a.log"]))
	AssertThrows(() => LogExport_BuildTarCommand("C:\Out.zip", "C:\Stage\", ["a.log"]))
	AssertThrows(() => LogExport_BuildTarCommand("C:\Out.zip", "C:\Stage", ["../a.log"]))
	AssertThrows(() => LogExport_BuildTarCommand("C:\Out.zip", "C:\Stage", []))
}

_LEX_ExportsOneScrubbedArchive() {
	_LEX_Isolated(_LEX_ExportsOneScrubbedArchiveBody)
}

_LEX_ExportsOneScrubbedArchiveBody() {
	State := { Temp: _LEX_Folder("temp") }
	LogsDir := _LEX_Folder("logs"), DefaultDir := _LEX_Folder("default"), Destination := _LEX_Folder("downloads")
	try {
		Today := AppDirsLogUnifiedPrefix() . "2026-11-25" . AppDirsLogExtension()
		FileAppend("2026-11-25 10:00:00:000 [DEBUG] [Hotstring] Auto-expand: 'adr' → 'secret street'.`r`n",
			LogsDir . Today, "UTF-8")
		FileAppend("kept elsewhere`n", LogsDir . AppDirsRetiredTopicalLogs()[1], "UTF-8")
		FileAppend("before the logger`n", DefaultDir . AppDirsLogBootstrapName(), "UTF-8")
		DirCreate(LogsDir . AppDirsCrashReportsDir())
		FileAppend("{}`n", LogsDir . AppDirsCrashReportsDir() . "\crash.json", "UTF-8")
		Seams := _LEX_Seams(State, LogsDir, DefaultDir, RTrim(Destination, "\"))

		AssertTrue(LogExport_Command(Seams), "the export succeeds")

		Final := RTrim(Destination, "\") . "\" . LogExport_ArchiveName("20261125103000")
		AssertTrue(FileExist(Final) != "", "the archive lands in the Downloads folder")
		AssertEqual("", FileExist(Final . ".partial"), "no partial archive is left")
		AssertEqual(1, State.Commands.Length, "tar runs once")
		for Name in [Today, AppDirsLogBootstrapName(), AppDirsCrashReportsDir() . "/crash.json"]
			AssertTrue(InStr(State.Commands[1], '"' . Name . '"') > 0, "the archive holds " . Name)
		AssertEqual(0, InStr(State.Commands[1], AppDirsRetiredTopicalLogs()[1]), "a retired file is not archived")
		AssertEqual(0, InStr(State.Staged, "secret street"), "the staged copies hold no typed text")
		AssertTrue(InStr(State.Staged, "<text withheld>") > 0, "the expansion is withheld, not dropped")
		AssertEqual("", FileExist(RTrim(State.Staging, "\")), "the staging folder is removed")
		AssertEqual(Final, State.Clipboard[1][1], "the path is on the clipboard")
		AssertEqual(Final, State.Reveal[1][1], "Explorer selects the archive")
		AssertEqual(1, State.Notify.Length)
		AssertTrue(InStr(State.Notify[1][1], Final) > 0, "the notice names the path")
		AssertEqual(t("log_export.done_title"), State.Notify[1][2]["title"])
	} finally {
		for Dir in [State.Temp, LogsDir, DefaultDir, Destination]
			try DirDelete(Dir, true)
	}
}

_LEX_TellsAnEmptyFolder() {
	_LEX_Isolated(_LEX_TellsAnEmptyFolderBody)
}

_LEX_TellsAnEmptyFolderBody() {
	State := { Temp: _LEX_Folder("temp") }
	LogsDir := _LEX_Folder("logs"), DefaultDir := _LEX_Folder("default"), Destination := _LEX_Folder("downloads")
	try {
		AssertTrue(LogExport_Command(_LEX_Seams(State, LogsDir, DefaultDir, RTrim(Destination, "\"))),
			"an empty folder is an answer")
		AssertEqual(0, State.Commands.Length, "no archive is built")
		AssertEqual(1, State.Notify.Length)
		AssertEqual(t("log_export.empty"), State.Notify[1][1])
		loop files, Destination . "*"
			AssertTrue(false, "nothing is written to the destination: " . A_LoopFileName)
	} finally {
		for Dir in [State.Temp, LogsDir, DefaultDir, Destination]
			try DirDelete(Dir, true)
	}
}

_LEX_RefusedTarLeavesNothing() {
	_LEX_Isolated(_LEX_RefusedTarLeavesNothingBody)
}

_LEX_RefusedTarLeavesNothingBody() {
	State := { Temp: _LEX_Folder("temp") }
	LogsDir := _LEX_Folder("logs"), DefaultDir := _LEX_Folder("default"), Destination := _LEX_Folder("downloads")
	try {
		FileAppend("2026-11-25 10:00:00:000 [INFO] [x] one`n",
			LogsDir . AppDirsLogUnifiedPrefix() . "2026-11-25" . AppDirsLogExtension(), "UTF-8")
		AssertFalse(LogExport_Command(_LEX_Seams(State, LogsDir, DefaultDir, RTrim(Destination, "\"), 1)),
			"a refused tar is a failure")
		AssertEqual(1, State.Commands.Length, "tar ran before it refused")
		loop files, Destination . "*"
			AssertTrue(false, "no partial or final archive is left: " . A_LoopFileName)
		AssertEqual("", FileExist(RTrim(State.Staging, "\")), "the staging folder is removed")
		AssertEqual(0, State.Clipboard.Length, "nothing is copied")
		AssertEqual(0, State.Reveal.Length, "nothing is revealed")
		AssertEqual(1, State.Notify.Length)
		AssertEqual(t("log_export.failed"), State.Notify[1][1])
		AssertEqual(t("log_export.failed_title"), State.Notify[1][2]["title"])
	} finally {
		for Dir in [State.Temp, LogsDir, DefaultDir, Destination]
			try DirDelete(Dir, true)
	}
}

_LEX_ExistingArchiveIsNotReplaced() {
	_LEX_Isolated(_LEX_ExistingArchiveIsNotReplacedBody)
}

_LEX_ExistingArchiveIsNotReplacedBody() {
	State := { Temp: _LEX_Folder("temp") }
	LogsDir := _LEX_Folder("logs"), DefaultDir := _LEX_Folder("default"), Destination := _LEX_Folder("downloads")
	try {
		FileAppend("2026-11-25 10:00:00:000 [INFO] [x] one`n",
			LogsDir . AppDirsLogUnifiedPrefix() . "2026-11-25" . AppDirsLogExtension(), "UTF-8")
		Final := Destination . LogExport_ArchiveName("20261125103000")
		FileAppend("the user's file", Final, "UTF-8-RAW")
		AssertFalse(LogExport_Command(_LEX_Seams(State, LogsDir, DefaultDir, RTrim(Destination, "\"))))
		AssertEqual("the user's file", FileRead(Final, "UTF-8"), "an existing file is never replaced")
		AssertEqual(0, State.Commands.Length, "tar never runs over an existing name")
		AssertEqual(t("log_export.failed"), State.Notify[1][1])
	} finally {
		for Dir in [State.Temp, LogsDir, DefaultDir, Destination]
			try DirDelete(Dir, true)
	}
}

_LEX_DebugRowFollowsTheErrorsFile() {
	Built := _MI_BuildDebuggingMenu()
	try {
		Errors := _MLG_RowStarting(Built, "menu.debug.open_error_log")
		Export := _MLG_RowStarting(Built, "menu.debug.export_logs")
		AssertTrue(Errors >= 0, "the errors row is drawn")
		AssertEqual(Errors + 1, Export, "« Export the logs (zip) » follows « open today's errors file »")
	} finally _CTC_ReleaseMenu(Built)
	Fallback := _DriverFuncBody("_MM_DebugFallback")
	Assert(InStr(Fallback, "MenuCommand.EXPORT_LOGS") > 0, "the fallback order lists the export row")
}





; =====================================
; =====================================
; ======= 3/ Test registrations =======
; =====================================
; =====================================

Test("log export: the Windows port replays the shared selection vectors (log-export-selection)",
	_LEX_SelectionVectors)
Test("log export: the archive is named after the export instant (log-export-archive-name)",
	_LEX_ArchiveNameVector)
Test("log export: every scrub vector loses its typed text (log-export-scrub)", _LEX_ScrubVectors)
Test("log export: malformed dates, platforms and stamps are refused", _LEX_RefusesMalformedInput)
Test("log export: tar starts by its absolute path with quoted arguments", _LEX_TarCommandIsAbsoluteAndQuoted)
Test("log export: one scrubbed archive lands in Downloads, revealed and copied", _LEX_ExportsOneScrubbedArchive)
Test("log export: an empty logs folder is told, never silent", _LEX_TellsAnEmptyFolder)
Test("log export: a refused tar leaves no archive and is told", _LEX_RefusedTarLeavesNothing)
Test("log export: an existing archive name is never replaced", _LEX_ExistingArchiveIsNotReplaced)
Test("log export: the Debug row follows today's errors file", _LEX_DebugRowFollowsTheErrorsFile)
