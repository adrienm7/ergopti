; tests/unit/test_start_at_login.ahk
;
; ==============================================================================
; MODULE: Login Startup Ownership Tests
; DESCRIPTION:
; Exercises real shortcuts only in a temporary directory, never the user's
; Startup folder. No executable is launched and no registry value is changed.
; ==============================================================================

_TestStartupShortcutOwnership(Alias := false) {
	Directory := A_Temp . "\ergopti-startup-test-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount
	DirCreate(Directory)
	Target := Directory . (Alias ? "\.\" : "\") . "application.exe"
	Link := Directory . "\ErgoptiPlus.lnk"
	FileAppend("fixture", Target)
	try {
		AssertFalse(StartupShortcutOwned(Link, Target))
		AssertTrue(SetStartupShortcut(true, Link, Target))
		AssertTrue(StartupShortcutOwned(Link, Target))
		AssertTrue(SetStartupShortcut(false, Link, Target))
		AssertFalse(FileExist(Link))
		FileCreateShortcut(Target, Link, Directory, "--foreign")
		Refused := false
		try SetStartupShortcut(false, Link, Target)
		catch
			Refused := true
		AssertTrue(Refused, "foreign shortcut arguments are never removed")
		AssertTrue(FileExist(Link) != "")
	} finally {
		if FileExist(Link)
			FileDelete(Link)
		FileDelete(Target)
		DirDelete(Directory)
	}
}
Test("Startup: exact owned shortcut only (login-startup)", _TestStartupShortcutOwnership)
Test("Startup: Shell-normalized path remains owned (login-startup)", _TestStartupShortcutOwnership.Bind(true))

_TestStartupApprovalState() {
	AssertTrue(StartupApprovalEnabled(""))
	AssertTrue(StartupApprovalEnabled("020000000000000000000000"))
	AssertFalse(StartupApprovalEnabled("030000000000000000000000"))
	AssertFalse(StartupApprovalEnabled("070000000000000000000000"))
	Refused := false
	try StartupApprovalEnabled("ff0000000000000000000000")
	catch
		Refused := true
	AssertTrue(Refused, "unknown Windows approval is not guessed")
}
Test("Startup: OS approval remains authoritative (login-startup)", _TestStartupApprovalState)
