; diagnostics/ui/log_export.ahk

; ==============================================================================
; MODULE: Log Export Action (Windows)
; DESCRIPTION:
; « Export the logs (zip) » in the Debug menu: one archive a tester sends
; instead of dozens of files (maintainer decision, 2026-11-25). It holds the
; daily logs and errors mirrors of the last N days, the bootstrap log and the
; crash reports, each copied without the user's typed text
; (diagnostics/engine/log_export.ahk), and lands in the Downloads folder (the
; Desktop when there is none), selected in Explorer with its path on the
; clipboard and a translated notification.
;
; FEATURES & RATIONALE:
; 1. Never a partial archive. The scrubbed copies are staged in a private
;    folder under A_Temp, the archive is written beside its final name and
;    renamed in the same folder, and every failure removes both.
; 2. The system bsdtar (System32\tar.exe, shipped since Windows 10 1803) builds
;    the ZIP, started by its absolute path for the reason
;    core/lifecycle/engine/bundle.ahk gives; no PowerShell child.
; 3. Never silent. An empty folder and every failure are told to the user, the
;    failure with its English reason in the log.
; 4. Every outside effect is a seam of LogExport_Command, so the action is
;    tested headlessly without a tar, an Explorer window or a notification.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================
; ===============================
; ======= 1/ Helpers ============
; ===============================
; ===============================

; Names of the regular files directly in Dir (no folder, no reparse point).
; @param Dir {String} Folder with its trailing backslash; absent lists nothing.
; @returns {Array}
_LogExport_RegularFiles(Dir) {
	Names := []
	if !DirExist(Dir)
		return Names
	loop files, Dir . "*", "F" {
		if !InStr(A_LoopFileAttrib, "L")
			Names.Push(A_LoopFileName)
	}
	return Names
}

; The tar command line that writes the ZIP at ZipPath from the entries of
; StagingDir. Windows paths cannot hold a double quote, and a trailing
; backslash would escape the closing quote, so both are refused rather than
; quoted into another argument vector (as _Bundle_BuildUnzipCommand does).
; @param ZipPath {String} Archive to write.
; @param StagingDir {String} Folder holding the entries, no trailing backslash.
; @param Entries {Array} Archive names, "/"-separated, relative to StagingDir.
; @returns {String}
LogExport_BuildTarCommand(ZipPath, StagingDir, Entries) {
	for Value in [ZipPath, StagingDir] {
		if (Value == "" || InStr(Value, '"') || SubStr(Value, -1) == "\")
			throw ValueError("Log export path cannot be quoted: " . Value)
	}
	if !Entries.Length
		throw ValueError("Log export has no entry to archive.")
	Arguments := '-c --format zip -f "' . ZipPath . '" -C "' . StagingDir . '"'
	for Entry in Entries {
		if (Entry == "" || InStr(Entry, '"') || InStr(Entry, "..") || SubStr(Entry, 1, 1) == "/")
			throw ValueError("Log export entry cannot be quoted: " . Entry)
		Arguments .= ' "' . Entry . '"'
	}
	return ShellRunner_SystemProgramCommand("tar.exe", Arguments)
}

; The folder the archive lands in: Downloads, else the Desktop.
; @param DownloadsFn {Func} Resolves the Downloads known folder.
; @returns {String} Existing folder, no trailing backslash.
_LogExport_Destination(DownloadsFn) {
	try {
		Downloads := RTrim(DownloadsFn.Call(), "\/")
		if (Downloads != "" && DirExist(Downloads))
			return Downloads
		LoggerWarn("LogExport", "The Downloads folder does not exist; the archive goes to the Desktop.")
	} catch as Err {
		LoggerWarn("LogExport", "The Downloads folder could not be resolved ({1}); the archive goes to the Desktop.",
			Err.Message)
	}
	Desktop := RTrim(A_Desktop, "\/")
	if (Desktop == "" || !DirExist(Desktop))
		throw Error("Neither the Downloads folder nor the Desktop exists.")
	return Desktop
}

; Shows a translated notification; a refused one is logged, never thrown.
_LogExport_Notify(NotifyFn, TitleKey, MessageKey, Level, Path := "") {
	Message := t(MessageKey)
	if (Path != "")
		Message := StrReplace(Message, "%s", Path)
	Delivered := NotifyFn.Call(Message, Map("title", t(TitleKey), "level", Level))
	if !Delivered
		LoggerError("LogExport", "The {1} notification was not delivered.", MessageKey)
	return Delivered
}




; ===============================
; ===============================
; ======= 2/ Public API =========
; ===============================
; ===============================

; Builds the archive, reveals it, copies its path and tells the user.
; @param Seams {Map|Integer} Tests only: "run_wait" (command line → exit code),
;   "reveal" (path → Boolean), "clipboard" (text → Boolean), "notify" (NotifierSend
;   signature), "downloads" (→ folder), "now" (→ YYYYMMDDHH24MISS), "logs_dir",
;   "default_dir" and "temp_dir" (folders with their trailing backslash).
; @returns {Boolean} True when the archive was exported, or an empty folder told.
LogExport_Command(Seams := 0) {
	Seams := (Seams is Map) ? Seams : Map()
	RunWaitFn := Seams.Get("run_wait", (Command) => RunWait(Command, , "Hide"))
	RevealFn := Seams.Get("reveal", _LogExport_Reveal)
	ClipboardFn := Seams.Get("clipboard", CB_Write)
	NotifyFn := Seams.Get("notify", NotifierSend)
	DownloadsFn := Seams.Get("downloads", GetKnownFolderDownloads)
	Now := Seams.Has("now") ? Seams["now"].Call() : A_Now
	LoggerStart("LogExport", "Exporting the logs as one archive.")
	Staging := "", Partial := "", Final := ""
	try {
		if !LoggerFlushForRead()
			throw Error("today's log could not be flushed before it is read")
		LogsDir := Seams.Has("logs_dir") ? Seams["logs_dir"] : LoggerLogsDir()
		DefaultDir := Seams.Has("default_dir") ? Seams["default_dir"] : LoggerDefaultLogsDir()
		CrashDir := LogsDir . AppDirsCrashReportsDir() . "\"
		Selected := LogExport_Select(Map(
			"platform", "ahk",
			"today", FormatTime(Now, "yyyy-MM-dd"),
			"logs", _LogExport_RegularFiles(LogsDir),
			"default", _LogExport_RegularFiles(DefaultDir),
			"crash_reports", _LogExport_RegularFiles(CrashDir)))
		if !Selected.Length {
			LoggerSuccess("LogExport", "No log to export in '{1}'; the user is told.", LogsDir)
			return _LogExport_Notify(NotifyFn, "log_export.done_title", "log_export.empty", "info")
		}
		TempRoot := Seams.Has("temp_dir") ? Seams["temp_dir"] : A_Temp . "\"
		Staging := TempRoot . "ergopti-log-export-" . DllCall("Kernel32\GetCurrentProcessId", "UInt")
			. "-" . A_TickCount
		DirCreate(Staging)
		Entries := []
		for Entry in Selected {
			Source := (Entry["folder"] == "logs" ? LogsDir
				: Entry["folder"] == "default" ? DefaultDir : CrashDir) . Entry["name"]
			Target := Staging . "\" . StrReplace(Entry["archive"], "/", "\")
			SplitPath(Target, , &TargetDir)
			DirCreate(TargetDir)
			FileAppend(LogExport_ScrubText(FileRead(Source, "UTF-8")), Target, "UTF-8-RAW")
			Entries.Push(Entry["archive"])
		}
		Destination := _LogExport_Destination(DownloadsFn)
		Final := Destination . "\" . LogExport_ArchiveName(Now)
		if FileExist(Final)
			throw Error("an archive named '" . Final . "' already exists")
		Partial := Final . ".partial"
		ExitCode := RunWaitFn.Call(LogExport_BuildTarCommand(Partial, Staging, Entries))
		if (ExitCode != 0)
			throw Error("tar.exe exited with code " . ExitCode)
		if !FileExist(Partial) || FileGetSize(Partial) == 0
			throw Error("tar.exe wrote no archive")
		FileMove(Partial, Final, 0)
		Partial := ""
	} catch as Err {
		LoggerError("LogExport", "The logs could not be exported: {1}.", Err.Message)
		if (Partial != "" && FileExist(Partial)) {
			try {
				FileDelete(Partial)
			} catch as CleanupErr {
				LoggerWarn("LogExport", "The partial archive '{1}' could not be removed: {2}.", Partial, CleanupErr.Message)
			}
		}
		_LogExport_Notify(NotifyFn, "log_export.failed_title", "log_export.failed", "error")
		return false
	} finally {
		if (Staging != "" && DirExist(Staging)) {
			try {
				DirDelete(Staging, true)
			} catch as CleanupErr {
				LoggerWarn("LogExport", "The staging folder '{1}' could not be removed: {2}.", Staging, CleanupErr.Message)
			}
		}
	}
	LoggerSuccess("LogExport", "Exported {1} file(s) to '{2}'.", Entries.Length, Final)
	if !ClipboardFn.Call(Final)
		LoggerWarn("LogExport", "The archive path could not be copied to the clipboard.")
	if !RevealFn.Call(Final)
		LoggerWarn("LogExport", "Explorer could not select the archive '{1}'.", Final)
	_LogExport_Notify(NotifyFn, "log_export.done_title", "log_export.done", "success", Final)
	return true
}

; Selects the archive in Explorer.
; @returns {Boolean} False when Explorer could not be started.
_LogExport_Reveal(Path) {
	try {
		Run(ShellRunner_SystemProgramCommand("explorer.exe", '/select,"' . Path . '"'))
		return true
	} catch as Err {
		LoggerWarn("LogExport", "Explorer could not be started: {1}.", Err.Message)
		return false
	}
}
