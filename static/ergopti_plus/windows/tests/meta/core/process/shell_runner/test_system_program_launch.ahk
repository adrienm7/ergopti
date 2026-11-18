; tests/meta/core/process/shell_runner/test_system_program_launch.ahk

; ==============================================================================
; MODULE: System Program Launch Meta Test
; DESCRIPTION:
; A program Windows ships must start by its absolute path. Run, RunWait,
; ShellExecute and CreateProcess resolve a bare name through the search path,
; which looks in the folder of the running exe and in the current folder before
; System32: a powershell.exe or notepad.exe planted next to the portable exe, or
; in the folder it was started from, would run instead, elevated when the
; launch asks for *RunAs. ShellRunner_SystemProgramPath and
; ShellRunner_SystemProgramCommand own the absolute spelling
; (system-program-absolute-path).
;
; The scan reads every production file through _DriverSourceNoComments, so a
; moved or renamed call site stays covered. It looks for a system program name
; at the start of a string literal in a launch position: the first argument of
; a launch call, an assigned command line, a ternary branch of a command line,
; or the first element of an assigned argument vector. A process name kept as
; data (an app category, a terminal list, an ahk_exe criterion) is not a launch
; and is left alone.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================
; ========================================
; ======= 1/ Bare Launch Detection =======
; ========================================
; ========================================

; Every launch of a program Windows ships that names it without a path.
; @param Src {String} Comment-stripped AutoHotkey source.
; @returns {Array} The matched launch heads, in source order.
_SPL_BareLaunches(Src) {
	static Names := "powershell|pwsh|cmd|conhost|explorer|notepad|regedit|reg|taskkill|tasklist|rundll32"
		. "|msiexec|mshta|wscript|cscript|schtasks|sc|netsh|icacls|takeown|tar|curl|certutil|wmic|whoami"
		. "|control|mmc|timeout|where|robocopy|xcopy|attrib|bcdedit|mstsc|calc|osk|charmap|mspaint|wt"
	Quote := "['" . Chr(34) . "]"
	Patterns := [
		; The first argument of a launch call; Run and RunWait take a bare name too.
		"i)(?:(?<![\w.])(?:Run|RunWait|ShellExecute\w*)|\.(?:Call|Run|Exec|Launch\w*)"
			. "|(?<![\w.])(?:\w*Spawn\w*|\w+_Start|GestureRunShellTarget))\(\s*" . Quote
			. "(?:\*RunAs\s+)?(?:" . Names . ")(?:\.exe|\.com)?(?=" . Quote . "|\s)",
		; A command line assigned, or chosen by a ternary, before its launch.
		"i)(?:\?|:=)\s*" . Quote . "(?:\*RunAs\s+)?(?:" . Names . ")\.(?:exe|com)\s",
		; The program of an assigned argument vector.
		"i):=\s*\[\s*" . Quote . "(?:" . Names . ")\.(?:exe|com)" . Quote]
	Found := []
	for Pattern in Patterns {
		Position := 1
		while RegExMatch(Src, Pattern, &Match, Position) {
			Found.Push(Match[0])
			Position := Match.Pos + Match.Len
		}
	}
	return Found
}

; The detector must see each shape of the original sites, or a green scan
; would prove nothing.
_SPL_DetectorCatchesEveryShape() {
	Q := Chr(34)
	Bare := [
		"try Handle := Spawn.Call(" . Q . "powershell.exe" . Q . ", Args,",
		"Argv := [" . Q . "powershell.exe" . Q . ", " . Q . "-NoProfile" . Q . "]",
		"Run('*RunAs powershell.exe -NoProfile -File " . Q . "' . ScriptPath . '" . Q . "', , " . Q . "Hide" . Q . ", &Pid)",
		"Run('notepad.exe " . Q . "' . Path . '" . Q . "')",
		"(HasMethod(RunFn, " . Q . "Call" . Q . ") ? RunFn : Run).Call('explorer.exe " . Q . "' . LogDir . '" . Q . "')",
		"return _HCReport_Start(InStr(FileExist(Path), " . Q . "D" . Q . ") ? 'explorer.exe " . Q . "' . Path : '')",
		"Command := 'cmd.exe /k set " . Q . "OLLAMA_HOST=' . BaseUrl",
		"RunFn.Call(" . Q . "Regedit.exe" . Q . ")",
		"Run(" . Q . "taskkill.exe /PID " . Q . " . Pid, , " . Q . "Hide" . Q . ")",
		"Fn: (*) => GestureRunShellTarget(" . Q . "explorer.exe" . Q . ", " . Q . "open_file_manager" . Q . "),",
		"Run(" . Q . "cmd" . Q . ")"]
	for Line in Bare
		AssertEqual(1, _SPL_BareLaunches(Line).Length, "the scan must flag: " . Line)
	Absolute := [
		"Run(ShellRunner_SystemProgramCommand(" . Q . "notepad.exe" . Q . ", '" . Q . "' . Path . '" . Q . "'))",
		"Run('*RunAs " . Q . "' . ShellRunner_WinPsPath() . '" . Q . " -NoProfile')",
		"SearchInExplorer := WinActive(" . Q . "ahk_exe explorer.exe" . Q . ") != 0",
		Q . "pwsh.exe" . Q . ", true, " . Q . "powershell.exe" . Q . ", true, " . Q . "cmd.exe" . Q . ", true)",
		"try LoggerWarn(" . Q . "LLM.ollama" . Q . ", " . Q . "curl cannot enforce the limit." . Q . ")",
		"Run(" . Q . "ms-settings:startupapps" . Q . ")",
		"reservation[" . Q . "transport" . Q . "] := " . Q . "curl" . Q]
	for Line in Absolute
		AssertEqual(0, _SPL_BareLaunches(Line).Length, "the scan must leave alone: " . Line)
}
Test("system-program-absolute-path: the launch scan recognises every bare launch shape", _SPL_DetectorCatchesEveryShape)





; ===========================================
; ===========================================
; ======= 2/ Production Launch Census =======
; ===========================================
; ===========================================

_SPL_NoBareSystemLaunch() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for the system program launch scan")
	Found := _SPL_BareLaunches(Src)
	Listing := ""
	for Head in Found
		Listing .= "`n  " . Head
	AssertEqual(0, Found.Length, "a program Windows ships must start through ShellRunner_SystemProgramPath, "
		. "ShellRunner_SystemProgramCommand or ShellRunner_WinPsPath, never by its bare name:" . Listing)
}
Test("system-program-absolute-path: no production launch names a system program without its path", _SPL_NoBareSystemLaunch)
