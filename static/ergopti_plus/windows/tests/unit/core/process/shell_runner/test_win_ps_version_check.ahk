; tests/unit/core/process/shell_runner/test_win_ps_version_check.ahk

; ==============================================================================
; MODULE: Windows PowerShell Version Check
; DESCRIPTION:
; The owned-runtimes decision (SYS): the driver checks the Windows PowerShell
; version at start and refuses in words, not with a worker's obscure failure.
; ==============================================================================

#Requires AutoHotkey v2.0

_WPSV_Value(Value) {
	return Value
}

_WPSV_Record(Notices, Text) {
	Notices.Push(Text)
}

_WPSV_Check() {
	global SHELL_RUNNER_MIN_WIN_PS_VERSION
	Notices := []
	Notice := _WPSV_Record.Bind(Notices)
	for Version in ["5.1", "5.1.26100.1", "7.4.1", "10.0"]
		AssertTrue(ShellRunner_CheckWinPsAtStart(_WPSV_Value.Bind(Version), Notice), Version . " is supported")
	AssertEqual(0, Notices.Length, "a supported version says nothing")
	AssertFalse(ShellRunner_CheckWinPsAtStart(_WPSV_Value.Bind("5.0.10586.117"), Notice), "5.0 is refused")
	AssertEqual(1, Notices.Length, "the refusal speaks")
	AssertContains(Notices[1], SHELL_RUNNER_MIN_WIN_PS_VERSION, "it names the version needed")
	AssertContains(Notices[1], "5.0.10586.117", "and the one found")
	Assert(InStr(Notices[1], "Windows PowerShell", true) > 0, "it spells the product's name, from one literal in the code")
	AssertFalse(ShellRunner_CheckWinPsAtStart(_WPSV_Value.Bind(""), Notice), "no PowerShell is refused")
	AssertEqual(2, Notices.Length, "that refusal speaks too")
	AssertFalse(InStr(Notices[2], "{"), "no placeholder is left")
	Assert(StrCompare(Notices[1], Notices[2]) != 0, "a missing one is told apart from an old one")
}
Test("win-ps-version: the start check refuses in words below 5.1", _WPSV_Check)

; The real registry of a machine that runs this suite, and the entry's call.
_WPSV_RealReadingAndEntry() {
	Version := ShellRunner_WinPsVersion()
	Assert(RegExMatch(Version, "^\d+\.\d+"), "this Windows reports its PowerShell, got '" . Version . "'")
	AssertTrue(ShellRunner_CheckWinPsAtStart(), "this machine is supported, so no dialog opens")
	Entry := _DriverSourceConcat()
	AssertContains(Entry, "SetTimer(ShellRunner_CheckWinPsAtStart, -1)", "the entry runs the check after ready")
	Assert(InStr(Entry, "SetTimer(ShellRunner_CheckWinPsAtStart") > InStr(Entry, '_DriverBootPhase := "ready"'),
		"a dialog must not freeze the boot")
}
Test("win-ps-version: the registry reading and the entry's scheduling", _WPSV_RealReadingAndEntry)
