; diagnostics/adapters/log_export_files.ahk

; ==============================================================================
; MODULE: Log Export Files (Windows)
; DESCRIPTION:
; The native half of « Export the logs (zip) »: a staging name unique to this
; process, the scrubbed copy of one log, the rename that publishes the archive,
; the removal of a partial one, the hidden tar run and the Explorer selection.
; diagnostics/ui/log_export.ahk owns the decisions and receives the process
; effects as replaceable seams.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================
; ===============================
; ======= 1/ Files ==============
; ===============================
; ===============================

/**
 * A staging folder name unique to this process and moment.
 * @param {String} TempRoot Folder with its trailing backslash.
 * @returns {String} The folder path, not yet created.
 */
LogExportFiles_StagingPath(TempRoot) {
	return TempRoot . "ergopti-log-export-" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . "-" . A_TickCount
}

/**
 * Writes the scrubbed copy of one UTF-8 log file.
 * @param {String} Source The log to read.
 * @param {String} Target The staged copy to write; its folder exists.
 * @param {Func} ScrubFn Returns the text without the typed text.
 */
LogExportFiles_StageScrubbed(Source, Target, ScrubFn) {
	FileAppend(ScrubFn.Call(FileRead(Source, "UTF-8")), Target, "UTF-8-RAW")
}

/**
 * Renames the partial archive to its final name, never over an existing file.
 * @param {String} Partial The written archive.
 * @param {String} Final Its published name, in the same folder.
 */
LogExportFiles_Publish(Partial, Final) {
	FileMove(Partial, Final, 0)
}

/**
 * Removes a partial archive left by a failed export.
 * @param {String} Path The partial archive.
 */
LogExportFiles_Remove(Path) {
	FileDelete(Path)
}




; ===============================
; ===============================
; ======= 2/ Processes ==========
; ===============================
; ===============================

/**
 * Runs a command line hidden and waits for it.
 * @param {String} Command The complete command line.
 * @returns {Integer} The exit code.
 */
LogExportFiles_RunHidden(Command) {
	return RunWait(Command, , "Hide")
}

/**
 * Selects a file in Explorer, started by its absolute path.
 * @param {String} Path The file to select.
 */
LogExportFiles_SelectInExplorer(Path) {
	Run(ShellRunner_SystemProgramCommand("explorer.exe", '/select,"' . Path . '"'))
}
