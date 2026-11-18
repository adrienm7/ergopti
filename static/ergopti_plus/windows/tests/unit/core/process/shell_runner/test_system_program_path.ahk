; tests/unit/core/process/shell_runner/test_system_program_path.ahk

; ==============================================================================
; MODULE: System Program Path Tests
; DESCRIPTION:
; A program Windows ships starts by its absolute path: a bare name is resolved
; through the search path, which looks in the exe's folder and the current
; folder before System32, so a planted copy there would run instead
; (system-program-absolute-path).
; ==============================================================================

#Requires AutoHotkey v2.0

_SPP_Resolves() {
	for Name, Folder in Map("notepad.exe", "\System32\", "cmd.exe", "\System32\", "taskkill.exe", "\System32\",
			"explorer.exe", "\", "regedit.exe", "\") {
		Path := ShellRunner_SystemProgramPath(Name)
		AssertEqual(A_WinDir . Folder . Name, Path, Name . " resolves under the Windows directory, never by search")
		Attributes := FileExist(Path)
		AssertTrue(Attributes != "" && !InStr(Attributes, "D"), Name . " is the file this Windows ships at that path")
	}
	AssertEqual(ShellRunner_WinPsPath(), ShellRunner_SystemProgramPath("powershell.exe"),
		"Windows PowerShell keeps its one spelling")
	AssertEqual(A_WinDir . "\explorer.exe", ShellRunner_SystemProgramPath("Explorer.EXE"),
		"a file name is matched as Windows matches it, without case")
}
Test("system-program-absolute-path: every program resolves under the Windows directory", _SPP_Resolves)

_SPP_RefusesNonNames() {
	; A path or a relative name would reopen the search the helper exists to close.
	for Value in ["", "notepad", "notepad.com", ".\notepad.exe", "..\notepad.exe", "sub\notepad.exe",
			"C:\Windows\notepad.exe", "note pad.exe", "notepad.exe /a"]
		AssertThrows(ShellRunner_SystemProgramPath.Bind(Value), "refuses " . Value)
	AssertThrows(ShellRunner_SystemProgramPath.Bind(0), "refuses a non-string")
}
Test("system-program-absolute-path: anything but a plain .exe file name is refused", _SPP_RefusesNonNames)

_SPP_Command() {
	Quoted := '"' . A_WinDir . '\System32\notepad.exe"'
	AssertEqual(Quoted, ShellRunner_SystemProgramCommand("notepad.exe"), "no argument adds no trailing space")
	AssertEqual(Quoted . ' "C:\a b\log.txt"', ShellRunner_SystemProgramCommand("notepad.exe", '"C:\a b\log.txt"'),
		"the quoted absolute path comes first, then the arguments as given")
	AssertThrows(ShellRunner_SystemProgramCommand.Bind("notepad.exe", 1), "the arguments are one string")
}
Test("system-program-absolute-path: a command line quotes the absolute path", _SPP_Command)
