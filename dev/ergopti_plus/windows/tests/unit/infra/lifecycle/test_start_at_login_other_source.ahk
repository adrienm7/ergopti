; tests/unit/infra/lifecycle/test_start_at_login_other_source.ahk
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


; The system temporary directory permits a real whitespace-free argument fixture
; independently of the current user's profile name. Only this exclusive child is owned.
_TestStartupInterpreterArgument(Scenario) {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	Directory := A_WinDir . "\Temp\ergopti-startup-argument-" . DllCall("Kernel32\GetCurrentProcessId", "UInt")
		. "-" . A_TickCount . "-" . Random(100000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	try {
		Driver := Directory . (InStr(Scenario, "spaced") ? "\source space" : "\windows")
		DirCreate(Driver . "\infra")
		DirCreate(Directory . "\_shared\modules\updater")
		Script := Driver . "\ErgoptiPlus.ahk"
		FileAppend("#Requires Autohotkey v2.0+`n#Include infra/bundle.ahk`n#Include modules/updater.ahk`n",
			Script, "UTF-8")
		FileAppend('global BUNDLE_VERSION := "__BUNDLE_VERSION__"' . "`n", Driver . "\infra\bundle.ahk", "UTF-8")
		FileAppend('{"github":{"owner":"' . UPDATER_GH_OWNER . '","repo":"' . UPDATER_GH_REPO . '"}}',
			Directory . "\_shared\modules\updater\defaults.json", "UTF-8")
		Interpreter := Directory . "\interpreter.exe"
		Compiled := Directory . "\current.exe"
		FileAppend("inert interpreter", Interpreter)
		FileAppend("inert compiled application", Compiled)
		Command := StartupLaunchCommand(false, Compiled, Interpreter)
		SourceCommand := StartupLaunchCommand(true, Script, Interpreter)
		Folder := Directory . "\links"
		DirCreate(Folder)
		Link := Folder . "\Manual source.lnk"
		Quoted := Scenario == "quoted" || Scenario == "spaced-quoted"
		Args := Quoted ? '"' . Script . '"' : Script
		if Scenario == "flagged"
			Args .= " --foreign"
		FileCreateShortcut(Interpreter, Link, Driver, Args)
		Approval := (*) => Scenario == "unquoted-disabled" ? "030000000000000000000000" : "020000000000000000000000"
		ValidSource := Scenario != "flagged" && Scenario != "spaced-unquoted"
		AssertEqual(ValidSource ? 1 : 0, StartupOwnedShortcuts(Folder, SourceCommand).Length,
			"the genuine source command owner independently classifies the native shortcut")
		Expected := ValidSource && Scenario != "unquoted-disabled"
		AssertEqual(Expected, StartupFolderEnabled(Folder, SourceCommand, Approval),
			"the existing source getter independently admits the exact argument and actual approval")
		AssertEqual(Expected, StartupOtherSourceConfigured(Folder, Command, Approval),
			"an enabled source command admitted by its real owner must also conflict with compiled startup")
		AssertFalse(StartupFolderEnabled(Folder, Command, Approval), "observation cannot acquire a foreign source command")
		FileGetShortcut(Link, &RetainedTarget, , &RetainedArguments)
		AssertEqual(_StartupExecutablePath(Interpreter), _StartupExecutablePath(RetainedTarget), "the interpreter target is retained")
		AssertEqual(Args, RetainedArguments, "observation retains the exact actual argument string")
		AssertTrue(FileExist(Link), "observation never removes the source shortcut")
	} finally DirDelete(Directory, true)
}
for _StartupArgument_Scenario in ["quoted", "unquoted", "unquoted-disabled", "flagged", "spaced-unquoted", "spaced-quoted"]
	Test("Startup argument custody: " . _StartupArgument_Scenario . " keeps source conflict parity (startup-argument-parity)",
		_TestStartupInterpreterArgument.Bind(_StartupArgument_Scenario))


_TestStartupArgumentGrammar() {
	for Pair in [["C:\driver\ErgoptiPlus.ahk", "C:\driver\ErgoptiPlus.ahk"],
			['"C:\source space\ErgoptiPlus.ahk"', "C:\source space\ErgoptiPlus.ahk"],
			['"C:\driver\ErgoptiPlus.ahk"', "C:\driver\ErgoptiPlus.ahk"],
			["C:/driver/ErgoptiPlus.ahk", "C:/driver/ErgoptiPlus.ahk"],
			["", ""], ["C:\source space\ErgoptiPlus.ahk", ""],
			['"C:\driver\ErgoptiPlus.ahk" --foreign', ""],
			["C:\driver\ErgoptiPlus.ahk --foreign", ""],
			['"C:\driver\ErgoptiPlus.ahk', ""],
			['C:\driver\ErgoptiPlus.ahk"', ""]] {
		AssertEqual(Pair[2], _StartupScriptArgumentPath(Pair[1]),
			"both native source readers must receive one exact script argument shape")
	}
}
Test("Startup argument grammar: one source argument is shared by both readers (startup-argument-parity)",
	_TestStartupArgumentGrammar)
