; core/process/adapters/system_programs.ahk

; ==============================================================================
; MODULE: System Programs
; DESCRIPTION:
; The absolute paths of the programs Windows ships (PowerShell, Notepad,
; Explorer, cmd). Kept apart from the ShellRunner adapter because separate
; processes with a small include graph (the bundled App Cloner and Encryptor
; entry point) start these programs too and must not load the whole adapter.
; ==============================================================================

/**
 * Windows PowerShell's executable: the one spelling a PowerShell stage shares,
 * since the antivirus surface of the compiled script counts every copy.
 * @returns {String} Absolute path under the Windows directory.
 */
ShellRunner_WinPsPath() {
	return A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
}

/**
 * The absolute path of a program Windows ships. A bare name is resolved through
 * the search path, and CreateProcess, ShellExecute and SearchPath look in the
 * folder of the running exe and in the current folder before System32: a
 * program of that name planted next to the portable exe, or in the folder it
 * was started from, would run in its place.
 * @param {String} Name A plain file name, such as "notepad.exe".
 * @returns {String} Absolute path under the Windows directory.
 * @throws {ValueError} When Name is not a plain .exe file name.
 */
ShellRunner_SystemProgramPath(Name) {
	; Explorer and the Registry Editor live in the Windows folder itself.
	static WindowsFolderPrograms := Map("explorer.exe", true, "regedit.exe", true)
	if !(Name is String) || !RegExMatch(Name, "i)^[a-z0-9_-]+\.exe$")
		throw ValueError("A system program is named by a plain .exe file name.", -1, Name is String ? Name : Type(Name))
	Lower := StrLower(Name)
	if Lower == "powershell.exe"
		return ShellRunner_WinPsPath()
	return A_WinDir . (WindowsFolderPrograms.Has(Lower) ? "\" : "\System32\") . Lower
}

/**
 * A command line that starts a program Windows ships by its absolute path, for
 * Run and RunWait; see ShellRunner_SystemProgramPath.
 * @param {String} Name A plain file name, such as "explorer.exe".
 * @param {String} Arguments The rest of the command line, already quoted.
 * @returns {String} The quoted absolute path, then the arguments.
 */
ShellRunner_SystemProgramCommand(Name, Arguments := "") {
	if !(Arguments is String)
		throw TypeError("System program arguments must be a string.", -1, Type(Arguments))
	return '"' . ShellRunner_SystemProgramPath(Name) . '"' . (Arguments == "" ? "" : " " . Arguments)
}
