; tests/unit/test_start_at_login_other_source.ahk
;
; ==============================================================================
; MODULE: Authored Other-Source Startup Command Tests
; DESCRIPTION:
; Observes independently authored private commands and real shortcuts without
; reading driver source. No Startup folder or registry is changed, and no executable is launched.
; ==============================================================================

; The whole observation is exercised against exact private commands, never Startup.
_TestStartupOtherSourceConflict(Scenario) {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	Directory := A_Temp . "\ergopti-startup-conflict-" . DllCall("GetCurrentProcessId")
		. "-" . A_TickCount . "-" . Random(100000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	try {
		Driver := Directory . "\windows"
		DirCreate(Driver . "\infra")
		DirCreate(Directory . "\_shared\modules\updater")
		Script := Driver . "\ErgoptiPlus.ahk"
		Entry := "#Requires Autohotkey v2.0+" . Chr(10)
			. "#Include infra/bundle.ahk" . Chr(10) . "#Include modules/updater.ahk" . Chr(10)
		FileAppend(Entry, Script, "UTF-8")
		Version := Scenario == "wrong-version" ? 'global BUNDLE_VERSION := "foreign"'
			: 'global BUNDLE_VERSION := "__BUNDLE_VERSION__"'
		FileAppend(Version . Chr(10), Driver . "\infra\bundle.ahk", "UTF-8")
		Owner := Scenario == "wrong-repository" ? "foreign" : UPDATER_GH_OWNER
		Json := '{"github":{"owner":"' . Owner . '","repo":"' . UPDATER_GH_REPO . '"}}'
		FileAppend(Json, Directory . "\_shared\modules\updater\defaults.json", "UTF-8")
		Compiled := Directory . "\current.exe"
		FileAppend("inert executable", Compiled)
		Command := StartupLaunchCommand(false, Compiled, Compiled)
		Folder := Directory . "\links"
		DirCreate(Folder)
		Link := Folder . "\retained manual.lnk"
		Args := Scenario == "extra-arguments" ? "--foreign" : ""
		FileCreateShortcut(Script, Link, Driver, Args)
		Approval := (*) => Scenario == "disabled" ? "030000000000000000000000" : "020000000000000000000000"
		Expected := Scenario == "approved"
		AssertEqual(Expected, StartupOtherSourceConfigured(Folder, Command, Approval),
			"only the exact enabled, identified local source command disables the compiled toggle")
		AssertFalse(StartupFolderEnabled(Folder, Command, Approval),
			"the foreign source is never acquired as this compiled startup command")
		FileGetShortcut(Link, &Retained, , &RetainedArgs)
		AssertEqual(_StartupExecutablePath(Script), _StartupExecutablePath(Retained))
		AssertEqual(Args, RetainedArgs)
		AssertTrue(FileExist(Link) != "", "observation never removes or migrates the retained command")
		SourceCommand := StartupLaunchCommand(true, Script, Script)
		AssertFalse(StartupOtherSourceConfigured(Folder, SourceCommand, Approval),
			"the current local source remains the original per-command owner")
	} finally {
		DirDelete(Directory, true)
	}
}
Test("Startup: enabled other local source disables compiled mutation only (startup-other-command)", _TestStartupOtherSourceConflict.Bind("approved"))
Test("Startup: OS-disabled other source is not an enabled conflict (startup-other-command)", _TestStartupOtherSourceConflict.Bind("disabled"))
Test("Startup: extra source arguments have no conflict authority (startup-other-command)", _TestStartupOtherSourceConflict.Bind("extra-arguments"))
Test("Startup: source version sibling must identify an unbuilt source (startup-other-command)", _TestStartupOtherSourceConflict.Bind("wrong-version"))
Test("Startup: source repository sibling must identify the canonical product (startup-other-command)", _TestStartupOtherSourceConflict.Bind("wrong-repository"))
