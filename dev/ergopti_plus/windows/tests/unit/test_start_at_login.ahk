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

; ==============================================================================
; Source command ownership: only private shortcuts and inert fixture files.
; The interpreter is shared, so script arguments and working directory must be
; checked along with its target. No shortcut here is ever launched.
; ==============================================================================

_TestStartupSourceCommand(Scenario) {
	Directory := A_Temp . "\ergopti-startup-source-" . DllCall("GetCurrentProcessId")
		. "-" . A_TickCount . "-" . Random(100000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	try {
		ScriptDirectory := Directory . "\script space é"
		InterpreterDirectory := Directory . "\interpreter"
		DirCreate(ScriptDirectory)
		DirCreate(InterpreterDirectory)
		Script := ScriptDirectory . "\owned-script.ahk"
		OtherScript := ScriptDirectory . "\Other.ahk"
		Interpreter := InterpreterDirectory . "\AutoHotkey64.exe"
		Link := Directory . "\ErgoptiPlus.lnk"
		FileAppend("inert script fixture", Script)
		FileAppend("inert other fixture", OtherScript)
		FileAppend("inert interpreter fixture", Interpreter)
		ScriptInput := Scenario == "dot" ? ScriptDirectory . "\.\owned-script.ahk" : Script
		Command := StartupLaunchCommand(true, ScriptInput, Interpreter)
		AssertEqual(_StartupExistingFilePath(Interpreter), Command["target"])
		AssertEqual('"' . _StartupExistingFilePath(Script) . '"', Command["arguments"])
		AssertEqual(_StartupDirectoryPath(ScriptDirectory), Command["directory"])
		if Scenario == "missing-script" {
			FileDelete(Script)
			AssertThrows(StartupLaunchCommand.Bind(true, Script, Interpreter),
				"a missing source script must never become an owned command")
			AssertFalse(FileExist(Link))
			return
		}
		if Scenario == "missing-interpreter" {
			FileDelete(Interpreter)
			AssertThrows(StartupLaunchCommand.Bind(true, Script, Interpreter),
				"a missing source interpreter must never become an owned command")
			AssertFalse(FileExist(Link))
			return
		}
		if Scenario == "compiled" {
			Compiled := StartupLaunchCommand(false, Script, Directory . "\absent.exe")
			AssertEqual(_StartupExistingFilePath(Script), Compiled["target"])
			AssertEqual("", Compiled["arguments"])
			AssertEqual(Command["directory"], Compiled["directory"])
			AssertTrue(SetStartupShortcut(true, Link, Compiled["target"]))
			AssertTrue(StartupShortcutOwned(Link, Compiled["target"]))
			AssertThrows(SetStartupShortcut.Bind(false, Link, Command["target"],
				Command["arguments"], Command["directory"]), "a compiled command is not a source command")
			AssertTrue(FileExist(Link) != "")
			AssertTrue(SetStartupShortcut(false, Link, Compiled["target"]))
			return
		}
		if Scenario == "foreign-script" || Scenario == "extra-argument" || Scenario == "foreign-target"
				|| Scenario == "foreign-directory" || Scenario == "argument-case" {
			ForeignArguments := Scenario == "foreign-script"
				? '"' . _StartupExecutablePath(OtherScript) . '"' : Command["arguments"]
			if Scenario == "extra-argument"
				ForeignArguments .= " --foreign"
			if Scenario == "argument-case"
				ForeignArguments := StrUpper(ForeignArguments)
			ForeignTarget := Scenario == "foreign-target" ? OtherScript : Command["target"]
			ForeignDirectory := Scenario == "foreign-directory" ? InterpreterDirectory : Command["directory"]
			FileCreateShortcut(ForeignTarget, Link, ForeignDirectory, ForeignArguments)
			AssertThrows(SetStartupShortcut.Bind(false, Link, Command["target"],
				Command["arguments"], Command["directory"]), "foreign source shortcuts must not be deleted")
			AssertThrows(SetStartupShortcut.Bind(true, Link, Command["target"],
				Command["arguments"], Command["directory"]), "foreign source shortcuts must not be overwritten")
			AssertTrue(FileExist(Link) != "")
			FileGetShortcut(Link, &RetainedTarget, &RetainedDirectory, &RetainedArguments)
			AssertEqual(ForeignArguments, RetainedArguments)
			AssertEqual(_StartupExecutablePath(ForeignTarget), _StartupExecutablePath(RetainedTarget))
			AssertEqual(_StartupDirectoryPath(ForeignDirectory), _StartupDirectoryPath(RetainedDirectory))
			return
		}
		AssertFalse(StartupShortcutOwned(Link, Command["target"], Command["arguments"], Command["directory"]))
		AssertTrue(SetStartupShortcut(true, Link, Command["target"], Command["arguments"], Command["directory"]))
		FileGetShortcut(Link, &ActualTarget, &ActualDirectory, &ActualArguments)
		AssertEqual(Command["target"], _StartupExistingFilePath(ActualTarget))
		AssertEqual(Command["arguments"], ActualArguments)
		AssertEqual(Command["directory"], _StartupDirectoryPath(ActualDirectory))
		AssertTrue(SetStartupShortcut(true, Link, Command["target"], Command["arguments"], Command["directory"]))
		AssertTrue(SetStartupShortcut(false, Link, Command["target"], Command["arguments"], Command["directory"]))
		AssertFalse(FileExist(Link))
	} finally {
		; Exclusive creation above acquired this exact root; recursion owns only fixtures.
		DirDelete(Directory, true)
	}
}
Test("Startup: source Unicode command round-trips without launching (source-login-startup)", _TestStartupSourceCommand.Bind("source"))
Test("Startup: source dot-segment command remains owned (source-login-startup)", _TestStartupSourceCommand.Bind("dot"))
Test("Startup: compiled command remains argument-free (source-login-startup)", _TestStartupSourceCommand.Bind("compiled"))
Test("Startup: another script on the same interpreter is foreign (source-login-startup)", _TestStartupSourceCommand.Bind("foreign-script"))
Test("Startup: extra source arguments are foreign (source-login-startup)", _TestStartupSourceCommand.Bind("extra-argument"))
Test("Startup: source arguments retain exact spelling (source-login-startup)", _TestStartupSourceCommand.Bind("argument-case"))
Test("Startup: another executable remains foreign (source-login-startup)", _TestStartupSourceCommand.Bind("foreign-target"))
Test("Startup: interpreter directory is not the source working directory (source-login-startup)", _TestStartupSourceCommand.Bind("foreign-directory"))
Test("Startup: missing source script is refused (source-login-startup)", _TestStartupSourceCommand.Bind("missing-script"))
Test("Startup: missing source interpreter is refused (source-login-startup)", _TestStartupSourceCommand.Bind("missing-interpreter"))

; Code-only binding cannot be certified by a comment or quoted command example.
_TestStartupRequireCommandCall(Body, Pattern, Expected, Message) {
	Code := _DriverMaskNonCode(&Body)
	Count := 0
	Position := 1
	while RegExMatch(Code, Pattern, &Found, Position) {
		Count += 1
		Position := Found.Pos + Found.Len
	}
	AssertEqual(Expected, Count, Message)
}

_TestStartupCommandBinding(Body, Name) {
	Assert(Body != "", Name . " must be defined")
	Code := _DriverMaskNonCode(&Body)
	Pattern := "i)\bCommand\s*:=\s*StartupLaunchCommand\s*\(\s*Updater_IsLocalSource\s*\(\s*\)"
		. "\s*,\s*A_ScriptFullPath\s*,\s*A_AhkPath\s*\)"
	Position := RegExMatch(Code, Pattern, &Binding)
	Assert(Position > 0, Name . " must resolve the complete runtime launch command")
	Assert(!RegExMatch(Code, Pattern, , Position + Binding.Len), Name . " has one command resolution")
	Assert(!RegExMatch(Code, "i)\bif\s+Updater_IsLocalSource\s*\("), Name . " must not refuse the source command")
	if Name == "StartAtLoginEnabled" {
		_TestStartupRequireCommandCall(Body,
			"i)StartupFolderEnabled\s*\(\s*A_Startup\s*,\s*Command\s*\)", 1,
			"getter must check discovered startup commands")
	} else {
		_TestStartupRequireCommandCall(Body,
			"i)SetStartupFolder\s*\(\s*true\s*,\s*A_Startup\s*,\s*Command\s*\)", 1,
			"toggle enable must pass the complete command")
		_TestStartupRequireCommandCall(Body,
			"i)SetStartupFolder\s*\(\s*!Enabled\s*,\s*A_Startup\s*,\s*Command\s*\)", 1,
			"toggle final mutation must pass the complete command")
		_TestStartupRequireCommandCall(Body,
			"i)StartupFolderEnabled\s*\(\s*A_Startup\s*,\s*Command\s*\)", 1,
			"toggle must preserve approval admission after enabling")
	}
}

_TestStartupRuntimeBinding() {
	Getter := _DriverFuncBody("StartAtLoginEnabled")
	Toggle := _DriverFuncBody("ToggleStartAtLogin")
	Assert(Getter != "" && Toggle != "", "both runtime startup owners must exist")
	_TestStartupCommandBinding(Getter, "StartAtLoginEnabled")
	_TestStartupCommandBinding(Toggle, "ToggleStartAtLogin")
}
Test("Startup: getter and toggle share source launch ownership (source-login-startup)", _TestStartupRuntimeBinding)

_TestStartupApprovalPort(Values, Seen, Name) {
	Seen.Push(Name)
	return Values[Name]
}

_TestStartupManualFolder(Scenario) {
	Directory := A_Temp . "\ergopti-startup-manual-" . DllCall("GetCurrentProcessId")
		. "-" . A_TickCount . "-" . Random(100000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	OriginalWorkingDirectory := A_WorkingDir
	try {
		ScriptDirectory := Directory . "\script space é"
		DirCreate(ScriptDirectory)
		Script := ScriptDirectory . "\owned-script.ahk"
		Interpreter := Directory . "\interpreter.exe"
		Foreign := Directory . "\foreign.exe"
		FileAppend("inert script", Script)
		FileAppend("inert interpreter", Interpreter)
		FileAppend("inert foreign application", Foreign)
		FileAppend("retained non-link content", Directory . "\unrelated.txt")
		Command := StartupLaunchCommand(true, Script, Interpreter)
		Manual := Directory . "\ErgoptiPlus.ahk.lnk"
		Second := Directory . "\Other manual name.lnk"
		Canonical := Directory . "\ErgoptiPlus.lnk"
		ForeignLink := Directory . "\Foreign application.lnk"
		FileCreateShortcut(Foreign, ForeignLink, Directory, "--foreign")
		Values := Map()
		Seen := []
		ApprovalFn := _TestStartupApprovalPort.Bind(Values, Seen)
		if Scenario == "relative-other-cwd" {
			OtherDirectory := Directory . "\other"
			DirCreate(OtherDirectory)
			FileAppend("another script with the same basename", OtherDirectory . "\owned-script.ahk")
			FileCreateShortcut(Command["target"], Manual, OtherDirectory, "owned-script.ahk")
			SetWorkingDir(ScriptDirectory)
			Values["ErgoptiPlus.ahk.lnk"] := "020000000000000000000000"
			AssertEqual(0, StartupOwnedShortcuts(Directory, Command).Length,
				"relative arguments cannot acquire the running script's command identity")
			AssertFalse(StartupFolderEnabled(Directory, Command, ApprovalFn),
				"relative script arguments are not resolved using the running driver's cwd")
			AssertTrue(SetStartupFolder(false, Directory, Command))
			AssertTrue(FileExist(Manual) != "", "a relative command for another cwd is not removed")
			return
		}
		if Scenario == "foreign-interpreter-script" || Scenario == "foreign-interpreter-flags"
				|| Scenario == "unquoted-spaces" {
			ForeignArguments := Scenario == "foreign-interpreter-script"
				? '"' . _StartupExecutablePath(Foreign) . '"' : Command["arguments"] . " --foreign"
			if Scenario == "unquoted-spaces"
				ForeignArguments := Command["script"]
			FileCreateShortcut(Command["target"], Manual, "", ForeignArguments)
			AssertFalse(StartupFolderEnabled(Directory, Command, ApprovalFn))
			AssertEqual(0, Seen.Length, "foreign interpreter commands have no approval authority")
			AssertTrue(SetStartupFolder(true, Directory, Command))
			Values["ErgoptiPlus.lnk"] := "020000000000000000000000"
			AssertTrue(StartupFolderEnabled(Directory, Command, ApprovalFn))
			AssertEqual(1, StartupOwnedShortcuts(Directory, Command).Length)
			AssertTrue(SetStartupFolder(false, Directory, Command))
			AssertFalse(FileExist(Canonical))
			AssertTrue(FileExist(Manual) != "", "foreign manual command remains untouched")
			FileGetShortcut(Manual, , , &RetainedArguments)
			AssertEqual(ForeignArguments, RetainedArguments)
			AssertTrue(FileExist(ForeignLink) != "")
			return
		}
		if Scenario == "none-foreign" {
			FileCreateShortcut(Foreign, Canonical, Directory, "--foreign")
			AssertFalse(StartupFolderEnabled(Directory, Command, ApprovalFn))
			AssertEqual(0, Seen.Length)
			AssertThrows(SetStartupFolder.Bind(true, Directory, Command),
				"foreign canonical collision refuses creation without modifying it")
			AssertTrue(FileExist(Canonical) != "")
			FileGetShortcut(Canonical, &Retained, , &Arguments)
			AssertEqual("--foreign", Arguments)
			AssertEqual(_StartupExecutablePath(Foreign), _StartupExecutablePath(Retained))
			return
		}
		if Scenario == "create" {
			AssertFalse(StartupFolderEnabled(Directory, Command, ApprovalFn))
			AssertTrue(SetStartupFolder(true, Directory, Command))
			Values["ErgoptiPlus.lnk"] := ""
			AssertTrue(StartupFolderEnabled(Directory, Command, ApprovalFn))
			AssertEqual("ErgoptiPlus.lnk", Seen[1])
			AssertTrue(SetStartupFolder(false, Directory, Command))
			AssertFalse(FileExist(Canonical))
			AssertTrue(FileExist(ForeignLink) != "")
			return
		}
		if Scenario == "interpreter" || Scenario == "interpreter-case" || Scenario == "interpreter-alias" {
			ManualArguments := Command["arguments"]
			if Scenario == "interpreter-case"
				ManualArguments := '"' . StrUpper(Command["script"]) . '"'
			if Scenario == "interpreter-alias"
				ManualArguments := '"' . StrReplace(ScriptDirectory . "\.\owned-script.ahk", "\", "/") . '"'
			FileCreateShortcut(Command["target"], Manual, Command["directory"], ManualArguments)
		} else {
			FileCreateShortcut(Command["script"], Manual,
				Scenario == "empty-directory" ? "" : Command["directory"], "")
		}
		if Scenario == "empty-directory" {
			FileGetShortcut(Manual, , &EmptyDirectory)
			AssertEqual("", EmptyDirectory, "blank manual working directory is the actual fixture")
		}
		Values["ErgoptiPlus.ahk.lnk"] := Scenario == "disabled" ? "030000000000000000000000" : ""
		if Scenario == "duplicates" || Scenario == "mixed-approval" {
			FileCreateShortcut(Command["target"], Second, Command["directory"], Command["arguments"])
			Values["Other manual name.lnk"] := "030000000000000000000000"
			if Scenario == "mixed-approval"
				Values["ErgoptiPlus.ahk.lnk"] := "020000000000000000000000"
		}
		if Scenario == "foreign-canonical"
			FileCreateShortcut(Foreign, Canonical, Directory, "--foreign")
		if Scenario == "foreign-folder"
			FileCreateShortcut(ScriptDirectory, Second, Directory, "")
		Expected := Scenario != "disabled"
		AssertEqual(Expected, StartupFolderEnabled(Directory, Command, ApprovalFn))
		AssertEqual(Scenario == "duplicates" || Scenario == "mixed-approval" ? 2 : 1, Seen.Length,
			"approval is read for every owned actual filename")
		for Name in Seen
			AssertTrue(Values.Has(Name), "approval never reads a fabricated canonical name")
		Before := StartupOwnedShortcuts(Directory, Command).Length
		AssertTrue(SetStartupFolder(true, Directory, Command))
		AssertEqual(Before, StartupOwnedShortcuts(Directory, Command).Length,
			"enabling an existing manual command does not duplicate it")
		AssertEqual(Expected, StartupFolderEnabled(Directory, Command, ApprovalFn),
			"enabling cannot overwrite OS approval")
		AssertTrue(SetStartupFolder(false, Directory, Command))
		AssertFalse(FileExist(Manual))
		if Scenario == "foreign-folder"
			AssertTrue(FileExist(Second) != "", "folder shortcuts are foreign and retained")
		else
			AssertFalse(FileExist(Second))
		AssertEqual(0, StartupOwnedShortcuts(Directory, Command).Length)
		AssertTrue(FileExist(ForeignLink) != "")
		AssertEqual("retained non-link content", FileRead(Directory . "\unrelated.txt"))
		if Scenario == "foreign-canonical" {
			AssertTrue(FileExist(Canonical) != "")
			FileGetShortcut(Canonical, &Retained, , &Arguments)
			AssertEqual("--foreign", Arguments)
			AssertEqual(_StartupExecutablePath(Foreign), _StartupExecutablePath(Retained))
		} else {
			AssertFalse(FileExist(Canonical), "manual command never creates a canonical duplicate")
		}
	} finally {
		SetWorkingDir(OriginalWorkingDirectory)
		; Creation above acquired the exact root; all contained links are inert fixtures.
		DirDelete(Directory, true)
	}
}
Test("Startup: manually named direct source link is checked (source-login-startup)", _TestStartupManualFolder.Bind("direct"))
Test("Startup: manually named interpreter source link is checked (source-login-startup)", _TestStartupManualFolder.Bind("interpreter"))
Test("Startup: blank manual working directory remains owned (source-login-startup)", _TestStartupManualFolder.Bind("empty-directory"))
Test("Startup: manual interpreter script path is case-insensitive (source-login-startup)", _TestStartupManualFolder.Bind("interpreter-case"))
Test("Startup: manual interpreter script path alias remains owned (source-login-startup)", _TestStartupManualFolder.Bind("interpreter-alias"))
Test("Startup: relative same-basename script from another cwd is foreign (source-login-startup)", _TestStartupManualFolder.Bind("relative-other-cwd"))
Test("Startup: unrelated folder shortcut does not hide manual startup (source-login-startup)", _TestStartupManualFolder.Bind("foreign-folder"))
Test("Startup: another interpreter script has no startup authority (source-login-startup)", _TestStartupManualFolder.Bind("foreign-interpreter-script"))
Test("Startup: manual interpreter flags remain foreign (source-login-startup)", _TestStartupManualFolder.Bind("foreign-interpreter-flags"))
Test("Startup: unquoted space path is not one interpreter argument (source-login-startup)", _TestStartupManualFolder.Bind("unquoted-spaces"))
Test("Startup: disabled manual link keeps Windows approval authoritative (source-login-startup)", _TestStartupManualFolder.Bind("disabled"))
Test("Startup: all owned duplicates are removed without a new link (source-login-startup)", _TestStartupManualFolder.Bind("duplicates"))
Test("Startup: mixed approval reads every actual link filename (source-login-startup)", _TestStartupManualFolder.Bind("mixed-approval"))
Test("Startup: manual enabled plus foreign canonical link stays checked (source-login-startup)", _TestStartupManualFolder.Bind("foreign-canonical"))
Test("Startup: foreign canonical collision refuses new source link (source-login-startup)", _TestStartupManualFolder.Bind("none-foreign"))
Test("Startup: new source link creation preserves unrelated files (source-login-startup)", _TestStartupManualFolder.Bind("create"))

_TestStartupBindingRefused(Action) {
	Refused := false
	try Action.Call()
	catch as Err {
		if Type(Err) != "Error"
			throw Err
		Refused := true
	}
	AssertTrue(Refused, "the actual code-only binding guard must reject the mutated owner")
}

_TestStartupBindingControls() {
	Body := _DriverFuncBody("StartAtLoginEnabled")
	Assert(Body != "", "actual getter is required for mutation controls")
	Binding := "Command := StartupLaunchCommand(Updater_IsLocalSource(), A_ScriptFullPath, A_AhkPath)"
	Assert(InStr(Body, Binding, true), "actual getter binding is the mutation subject")
	_TestStartupCommandBinding(Body, "StartAtLoginEnabled")
	_TestStartupBindingRefused(_TestStartupCommandBinding.Bind(StrReplace(Body, Binding, ""), "StartAtLoginEnabled"))
	_TestStartupBindingRefused(_TestStartupCommandBinding.Bind(StrReplace(Body, Binding, "; " . Binding), "StartAtLoginEnabled"))
	_TestStartupBindingRefused(_TestStartupCommandBinding.Bind(StrReplace(Body, Binding, "'" . Binding . "'"), "StartAtLoginEnabled"))
	_TestStartupBindingRefused(_TestStartupCommandBinding.Bind(StrReplace(Body, Binding, Binding . Chr(10) . Binding), "StartAtLoginEnabled"))
	_TestStartupBindingRefused(_TestStartupCommandBinding.Bind(StrReplace(Body, "StartupFolderEnabled(A_Startup, Command)",
		"StartupFolderEnabled(A_Startup, OtherCommand)"), "StartAtLoginEnabled"))
}
Test("Startup: real runtime binding refuses missing and decoy commands (source-login-startup)", _TestStartupBindingControls)

_TestStartupAbsoluteCommands() {
	AssertTrue(_StartupIsAbsolutePath("C:\folder\script.ahk"))
	AssertTrue(_StartupIsAbsolutePath("C:/folder/script.ahk"))
	AssertTrue(_StartupIsAbsolutePath("\\server\share\script.ahk"))
	AssertFalse(_StartupIsAbsolutePath("script.ahk"))
	AssertFalse(_StartupIsAbsolutePath("\folder\script.ahk"))
	AssertFalse(_StartupIsAbsolutePath("C:script.ahk"))
	AssertFalse(_StartupIsAbsolutePath("\\server"))
	AssertFalse(_StartupIsAbsolutePath(""))
}
Test("Startup: command path grammar refuses relative authority (source-login-startup)", _TestStartupAbsoluteCommands)

_TestStartupDirectoryAdapter() {
	Body := _DriverFuncBody("_StartupDirectoryPath")
	Assert(Body != "", "startup directory wrapper must exist")
	Code := _DriverMaskNonCode(&Body)
	Assert(RegExMatch(Code, "im)^\s*return\s+FSResolveDirectoryPath\s*\(\s*Path\s*\)\s*$"),
		"startup directory resolution must delegate to the filesystem adapter")
	Assert(!RegExMatch(Code, "i)\bDllCall\s*\("),
		"startup directory wrapper cannot bypass the filesystem adapter")
	Adapter := _DriverFuncBody("FSResolveDirectoryPath")
	Assert(Adapter != "", "the actual directory adapter owner must exist")
	AdapterCode := _DriverMaskNonCode(&Adapter)
	Assert(RegExMatch(AdapterCode, "i)\bDirExist\s*\(\s*Path\s*\)"),
		"directory adapter validates the actual directory before resolution")
}
Test("Startup: directory resolution uses the actual filesystem adapter (source-login-startup)", _TestStartupDirectoryAdapter)
