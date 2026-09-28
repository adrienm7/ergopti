; tests/unit/test_logs_dir_resolver.ahk

; ==============================================================================
; MODULE: Logs Folder Resolver Tests
; DESCRIPTION:
; The logger is the one resolver of the logs folder and of today's files:
; LoggerLogsDir, LoggerTodayLogPath, LoggerTodayErrorsPath and
; LoggerCrashReportsDir. The Debug menu, the gesture actions, the health check
; and the crash reporter all ask it.
;
; ROOT CAUSES ENCODED (logs-dir-resolver):
; 1. The folder was <ConfigDir>\autohotkey\logs\, re-derived in four places;
;    it is now %LOCALAPPDATA%\ergopti_plus\logs\, or the LogsDirPath override.
; 2. An override naming a folder the user merely picked gets an ergopti_plus
;    subfolder, so retention never deletes in the user's own folder.
; 3. The errors file only exists once something warned that day; opening it
;    blindly made Notepad offer to create an empty file. The user is told.
; 4. Lines written before paths.toml is read (a yielding second instance, a
;    refused configuration transition) went to bootstrap.log beside
;    paths.toml, outside every logs folder.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Folder resolution =========
; ======================================
; ======================================

_LDIR_DefaultIsLocalAppData() {
	Expected := EnvGet("LOCALAPPDATA") . "\ergopti_plus\logs\"
	Assert(EnvGet("LOCALAPPDATA") != "", "the test host must define LOCALAPPDATA")
	AssertEqual(Expected, LoggerDefaultLogsDir(),
		"the default logs folder is local machine state, never the roaming profile")
}
Test("logs folder: the default is %LOCALAPPDATA%\ergopti_plus\logs (logs-dir-resolver)",
	_LDIR_DefaultIsLocalAppData)

_LDIR_OverrideIsNormalizedIntoAnOwnedFolder() {
	Default := "C:\Default\ergopti_plus\logs\"
	AssertEqual(Default, LoggerResolveLogsDir("", Default), "an empty override is the default")
	AssertEqual(Default, LoggerResolveLogsDir("c:/default/ergopti_plus/logs", Default),
		"the default folder, however spelled, is not a foreign folder")
	AssertEqual("D:\Sync\Logs\ergopti_plus\", LoggerResolveLogsDir("D:\Sync\Logs", Default),
		"a picked folder gets the application subfolder")
	AssertEqual("D:\Sync\ergopti_plus\", LoggerResolveLogsDir("D:/Sync/ergopti_plus/", Default),
		"a folder already named after the application is used as is")
	AssertEqual("\\nas\share\ergopti_plus\", LoggerResolveLogsDir("\\nas\share", Default),
		"a UNC share is an absolute folder")
	AssertEqual(Default, LoggerResolveLogsDir("relative\logs", Default),
		"a relative override is refused and the default is used")
}
Test("logs folder: LogsDirPath resolves to a folder the application owns (logs-dir-resolver)",
	_LDIR_OverrideIsNormalizedIntoAnOwnedFolder)

_LDIR_EveryArtifactFollowsTheFolder() {
	global _LogsDir
	Saved := _LogsDir
	_LogsDir := A_Temp . "\ergopti_ldir_artifacts\ergopti_plus\"
	try {
		Today := FormatTime(, "yyyy-MM-dd")
		AssertEqual(_LogsDir, LoggerLogsDir())
		AssertEqual(_LogsDir . "ErgoptiPlus_" . Today . ".log", LoggerTodayLogPath())
		AssertEqual(_LogsDir . "ErgoptiPlus_errors_" . Today . ".log", LoggerTodayErrorsPath())
		AssertEqual(_LogsDir . "crash_reports\", LoggerCrashReportsDir())
		LogDir := _LoggerResolveDatedPaths()
		AssertEqual(_LogsDir, LogDir, "the sink writes into the resolved folder")
	} finally {
		_LogsDir := Saved
		try DirDelete(A_Temp . "\ergopti_ldir_artifacts", true)
	}
}
Test("logs folder: logs, errors file and crash reports follow the resolved folder (logs-dir-resolver)",
	_LDIR_EveryArtifactFollowsTheFolder)





_LDIR_PathsTomlKeepsTheLogsOverride() {
	global _LogsDir, _DefaultLogsDir
	SavedLogs := _LogsDir
	SavedDefault := _DefaultLogsDir
	try {
		Content := ConfigTransitionPathsTomlContent("C:\Config", "C:\Default\",
			"D:\Sync\ergopti_plus\", "C:\Local\ergopti_plus\logs\")
		AssertContains(Content, 'ConfigDirPath = "C:/Config/"')
		AssertContains(Content, 'LogsDirPath = "D:/Sync/ergopti_plus/"')
		AssertContains(Content, "logs are written to: C:/Local/ergopti_plus/logs/")
		AssertFalse(InStr(ConfigTransitionPathsTomlContent("C:\Config", "C:\Default\"), "LogsDirPath ="),
			"no override, no LogsDirPath line")
		AssertThrows(() => ConfigTransitionPathsTomlContent("C:\Config", "C:\Default\", "relative"),
			"an invalid logs folder must never reach paths.toml bytes")

		_DefaultLogsDir := "C:\Local\ergopti_plus\logs\"
		_LogsDir := _DefaultLogsDir
		AssertEqual("", ConfigTransitionCurrentLogsOverride(), "the default is never written as an override")
		_LogsDir := "D:\Sync\ergopti_plus\"
		AssertEqual("D:\Sync\ergopti_plus\", ConfigTransitionCurrentLogsOverride(),
			"a configuration-folder rewrite keeps the user's logs folder")
	} finally {
		_LogsDir := SavedLogs
		_DefaultLogsDir := SavedDefault
	}
}
Test("logs folder: rewriting paths.toml keeps LogsDirPath (logs-dir-resolver)",
	_LDIR_PathsTomlKeepsTheLogsOverride)

_LDIR_BootstrapLinesGoToTheDefaultLogsFolder() {
	global _DefaultLogsDir
	SavedDefault := _DefaultLogsDir
	SavedLocal := EnvGet("LOCALAPPDATA")
	Root := A_Temp . "\ergopti_ldir_bootstrap_" . A_TickCount
	try {
		; A refused configuration transition: boot has named the default
		; folder, paths.toml has not been read.
		_DefaultLogsDir := Root . "\smoke\ergopti_plus\logs\"
		Written := LoggerAppendBootstrapLine("ERROR", "ConfigTransition", "refused")
		AssertEqual(_DefaultLogsDir . "bootstrap.log", Written,
			"a line written before paths.toml is read lands in the default logs folder")
		AssertContains(FileRead(Written, "UTF-8"), "[ERROR] [ConfigTransition] refused")

		; The single-instance gate runs before boot has named any folder.
		_DefaultLogsDir := ""
		EnvSet("LOCALAPPDATA", Root . "\local")
		Written := LoggerAppendBootstrapLine("WARNING", "ErgoptiPlus", "yielded")
		AssertEqual(Root . "\local\ergopti_plus\logs\bootstrap.log", Written,
			"before boot, the OS-default logs folder is the sink, created on demand")
		AssertContains(FileRead(Written, "UTF-8"), "[WARNING] [ErgoptiPlus] yielded")
	} finally {
		EnvSet("LOCALAPPDATA", SavedLocal)
		_DefaultLogsDir := SavedDefault
		try DirDelete(Root, true)
	}
}
Test("logs folder: pre-boot lines go to the default logs folder, not beside paths.toml (logs-dir-resolver)",
	_LDIR_BootstrapLinesGoToTheDefaultLogsFolder)





; ================================
; ================================
; ======= 2/ Log openers =========
; ================================
; ================================

_LDIR_MissingErrorsFileIsAnnounced() {
	global _LogsDir
	Saved := _LogsDir
	Root := A_Temp . "\ergopti_ldir_openers_" . A_TickCount
	_LogsDir := Root . "\ergopti_plus\"
	Launched := []
	Notified := []
	RecordLaunch(Command) {
		Launched.Push(Command)
	}
	RecordNotice(Message, Opts) {
		Notified.Push(Message)
		return true
	}
	try {
		AssertTrue(LogOpeners_OpenTodayErrors(RecordLaunch, RecordNotice))
		AssertEqual(0, Launched.Length, "a missing errors file must never be handed to Notepad")
		AssertEqual(1, Notified.Length, "the user must be told that nothing warned today")
		AssertEqual(t("menu.debug.no_errors_today"), Notified[1])

		DirCreate(_LogsDir)
		FileAppend("x`n", LoggerTodayErrorsPath(), "UTF-8")
		AssertTrue(LogOpeners_OpenTodayErrors(RecordLaunch, RecordNotice))
		AssertEqual(1, Launched.Length, "an existing errors file is opened")
		AssertContains(Launched[1], LoggerTodayErrorsPath())
		AssertEqual(1, Notified.Length)
	} finally {
		_LogsDir := Saved
		try DirDelete(Root, true)
	}
}
Test("log openers: a missing errors file is announced, an existing one is opened (logs-dir-resolver)",
	_LDIR_MissingErrorsFileIsAnnounced)

; The notice is the whole answer to the click, so a notice that never reached
; the user is a failed click, as on macOS and Linux, not a success.
_LDIR_UndeliveredNoticeIsAFailure() {
	global _LogsDir
	Saved := _LogsDir
	Root := A_Temp . "\ergopti_ldir_notice_" . A_TickCount
	_LogsDir := Root . "\ergopti_plus\"
	Launched := []
	RecordLaunch(Command) {
		Launched.Push(Command)
	}
	RefuseNotice(Message, Opts) {
		return false
	}
	try {
		AssertFalse(LogOpeners_OpenTodayErrors(RecordLaunch, RefuseNotice),
			"an undelivered notice must not report the click as handled")
		AssertEqual(0, Launched.Length, "a missing errors file is still never opened")
	} finally {
		_LogsDir := Saved
		try DirDelete(Root, true)
	}
}
Test("log openers: an undelivered no-errors notice is a failure (logs-dir-resolver)",
	_LDIR_UndeliveredNoticeIsAFailure)

_LDIR_OpenersUseTheResolver() {
	global _LogsDir
	Saved := _LogsDir
	Root := A_Temp . "\ergopti_ldir_folder_" . A_TickCount
	_LogsDir := Root . "\ergopti_plus\"
	Launched := []
	RecordLaunch(Command) {
		Launched.Push(Command)
	}
	try {
		AssertTrue(LogOpeners_OpenFolder(RecordLaunch))
		AssertTrue(DirExist(_LogsDir) != "", "the folder is created before Explorer opens it")
		AssertContains(Launched[1], _LogsDir)
		AssertTrue(LogOpeners_OpenTodayLog(RecordLaunch))
		AssertContains(Launched[2], LoggerTodayLogPath())
	} finally {
		_LogsDir := Saved
		try DirDelete(Root, true)
	}
}
Test("log openers: the folder and today's log come from the resolver (logs-dir-resolver)",
	_LDIR_OpenersUseTheResolver)
