; tests/unit/modules/gestures/test_user_actions.ahk

; ==============================================================================
; MODULE: User Actions
; DESCRIPTION:
; Replays the command and Windows path vectors of the shared user action corpus
; through the gesture validator, then runs real commands through a real cmd.exe:
; the shell's job, its private captures and the failure notices are the behaviour
; under test. Only the notification, the clipboard and the typing are recorded.
; ==============================================================================

#Requires AutoHotkey v2.0

_UA_Corpus() {
	static Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\action_parameters\user_action_vectors.json", "UTF-8"))
	return Corpus
}

_UA_Replay() {
	Corpus := _UA_Corpus()
	Commands := 0
	for Vector in Corpus["vectors"] {
		if (Vector["kind"] != "command")
			continue
		Commands += 1
		Label := "command vector " . Vector["id"]
		Parsed := UserActionParseCommand(Vector["value"])
		ErrorText := ""
		if Vector.Has("valid") {
			AssertFalse(Parsed is Map, Label . " is refused")
			AssertFalse(GestureValidateActionParameter("run_command", Vector["value"], &ErrorText), Label)
			Assert(ErrorText != "", Label . " names its refusal")
			continue
		}
		AssertTrue(Parsed is Map, Label . " is accepted")
		AssertTrue(GestureValidateActionParameter("run_command", Vector["value"]), Label)
		for Key, Value in Vector["parsed"]
			AssertEqual(Value, Parsed[Key], Label . " holds its " . Key)
		AssertEqual(Vector["value"], UserActionSpellCommand(Parsed["command"], Parsed["mode"], Parsed["output"]),
			Label . " has one spelling")
	}
	Assert(Commands >= 20, "the corpus holds the command vectors, got " . Commands)
	Paths := 0
	for Vector in Corpus["windows_path_vectors"] {
		Paths += 1
		Label := "path vector " . Vector["id"]
		ErrorText := ""
		if Vector.Has("valid") {
			AssertFalse(UserActionParsePath(Vector["value"]) is Map, Label . " is refused")
			AssertFalse(GestureValidateActionParameter("open_path", Vector["value"], &ErrorText), Label)
			Assert(ErrorText != "", Label . " names its refusal")
			continue
		}
		AssertEqual(Vector["value"], UserActionParsePath(Vector["value"])["path"], Label . " is accepted")
		AssertTrue(GestureValidateActionParameter("open_path", Vector["value"]), Label)
		AssertEqual(Vector["label"], UserActionPathLabel(Vector["value"]), Label . " shows its last component")
	}
	Assert(Paths >= 15, "the corpus holds the Windows path vectors, got " . Paths)
	; The POSIX spelling of the same corpus names no Windows path.
	for Vector in Corpus["vectors"]
		if (Vector["kind"] == "path")
			AssertFalse(UserActionParsePath(Vector["value"]) is Map, "POSIX vector " . Vector["id"] . " is no Windows path")
}
Test("user actions: the shared corpus replays through the validator (user-actions)", _UA_Replay)

_UA_Labels() {
	Secret := UserActionSpellCommand("secret-token", "hidden", "none")
	Saved := GestureActionParameters
	try {
		global GestureActionParameters := Map(GestureActionParameterKey("b", "run_command"), Secret,
			GestureActionParameterKey("b", "open_path"), "C:\Rapports\final.pdf")
		AssertFalse(InStr(GestureActionDisplayLabel("run_command", "b"), "secret-token"),
			"a command's text may hold a secret: no menu shows it")
		AssertContains(GestureActionDisplayLabel("open_path", "b"), "[final.pdf]", "a path shows its last component")
	} finally GestureActionParameters := Saved
}
Test("user actions: a label shows a path's name and never a command (user-actions)", _UA_Labels)

_UA_Script() {
	AssertEqual("cd src & git pull", UserActionCommandLine("cd src`n`tgit pull`n"), "the lines of a script run in turn")
	AssertEqual("echo a", UserActionCommandLine("  echo a  "), "one line stays one line")
	AssertEqual(3, UserActionCodePoints("é`n🚀"), "a surrogate pair counts once, a line break too")
	AssertEqual("", UserActionFirstLine("", 10), "no line")
	AssertEqual("first", UserActionFirstLine("`r`n  `r`nfirst`r`nsecond", 10), "the first non-blank line")
	AssertEqual("éé…", UserActionFirstLine("ééééé", 4), "a long line is cut within its byte bound")
}
Test("user actions: a script's lines and a failure's first line (user-actions)", _UA_Script)

; Runs one stored command through the real shell and waits for its own completion.
_UA_Run(Command, Output := "none", TimeoutMs := 30000) {
	global _UserActionPorts, GestureActionParameters, _UserCommandEntries
	Record := Map("notices", [], "copied", [], "typed", [])
	SavedPorts := _UserActionPorts, SavedParameters := GestureActionParameters
	_UserActionPorts := Map(
		"notify", (Text) => Record["notices"].Push(Text),
		"copy", (Text) => (Record["copied"].Push(Text), true),
		"type", (Text) => (Record["typed"].Push(Text), true),
		"open_terminal", (*) => true,
		"shell_open", (*) => true)
	try {
		GestureActionParameters := Map(GestureActionParameterKey("ua", "run_command"),
			UserActionSpellCommand(Command, "hidden", Output))
		Started := UserActions_RunCommand("ua")
		Record["started"] := Started
		Deadline := A_TickCount + TimeoutMs
		while (_UserCommandEntries.Has("ua") && A_TickCount < Deadline)
			Sleep(20)
		Record["finished"] := !_UserCommandEntries.Has("ua")
	} finally {
		if _UserCommandEntries.Has("ua")
			UserActions_StopCommands()
		_UserActionPorts := SavedPorts
		GestureActionParameters := SavedParameters
	}
	return Record
}

_UA_RealCommands() {
	Typed := _UA_Run('echo café 日本', "type")
	AssertTrue(Typed["started"] && Typed["finished"], "the command runs to its end")
	AssertEqual("café 日本", Typed["typed"][1], "stdout is typed, in UTF-8, without its line break")
	AssertEqual(0, Typed["notices"].Length, "a success says nothing")

	Copied := _UA_Run('echo "a & b" | findstr /c:"a" & echo %COMSPEC% ^& x', "copy")
	AssertContains(Copied["copied"][1], '"a & b"', "the shell's metacharacters are the command's own")
	AssertContains(Copied["copied"][1], "cmd.exe & x", "and the shell expands its own variables")

	Failed := _UA_Run('echo to-stdout & echo first-error 1>&2 & echo second-error 1>&2 & exit /b 3', "copy")
	AssertEqual(1, Failed["notices"].Length, "a failure is notified")
	AssertContains(Failed["notices"][1], "3", "with its exit code")
	AssertContains(Failed["notices"][1], "first-error", "and its first stderr line")
	AssertFalse(InStr(Failed["notices"][1], "second-error"), "only the first")
	AssertFalse(InStr(Failed["notices"][1], "to-stdout"), "stdout is not stderr")
	AssertEqual(0, Failed["copied"].Length, "a failed command delivers nothing")

	Script := _UA_Run("echo one`n`techo two", "copy")
	AssertEqual("one `ntwo", Script["copied"][1], "a script's lines run in turn")
}
Test("user actions: real commands run through the shell (user-actions)", _UA_RealCommands)

_UA_Bounds() {
	; A command that prints without end is stopped at the output bound, while it runs.
	Limit := TimingsGet("limits", "user_action_output_bytes")
	Over := _UA_Run("for /l %i in (1,1,1000000) do @echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "copy")
	AssertTrue(Over["finished"], "the bound stops it")
	AssertContains(Over["notices"][1], String(Limit), "the notice names the bound")
	AssertEqual(0, Over["copied"].Length, "nothing is kept")
}
Test("user actions: the output bound stops a running command (user-actions)", _UA_Bounds)

_UA_Path() {
	global _UserActionPorts, GestureActionParameters
	Opened := [], Notices := []
	SavedPorts := _UserActionPorts, SavedParameters := GestureActionParameters
	_UserActionPorts := Map("notify", (Text) => Notices.Push(Text),
		"shell_open", (Path) => (Opened.Push(Path), true))
	try {
		Missing := A_Temp . "\ergopti_ua_missing_" . A_TickCount . ".txt"
		GestureActionParameters := Map(GestureActionParameterKey("up", "open_path"), Missing)
		AssertFalse(UserActions_OpenPath("up"), "a missing path is refused")
		AssertEqual(0, Opened.Length, "and never reaches the shell")
		AssertContains(Notices[1], Missing, "the notice names it")
		GestureActionParameters := Map(GestureActionParameterKey("up", "open_path"), A_Temp)
		AssertTrue(UserActions_OpenPath("up"), "an existing folder opens")
		AssertEqual(A_Temp, Opened[1])
		GestureActionParameters := Map(GestureActionParameterKey("up", "open_path"), "/tmp/posix")
		AssertFalse(UserActions_OpenPath("up"), "a stored POSIX path is no value here")
	} finally {
		_UserActionPorts := SavedPorts
		GestureActionParameters := SavedParameters
	}
}
Test("user actions: open_path refuses a missing path (user-actions)", _UA_Path)

_UA_Registered() {
	global GESTURE_ACTIONS, GESTURE_ACTION_CATALOGUE
	for Id, Kind in Map("run_command", "command", "open_path", "path") {
		AssertTrue(GESTURE_ACTIONS.Has(Id), Id . " has a handler")
		AssertEqual(Kind, GESTURE_ACTION_CATALOGUE.Actions[Id].Parameter, Id . " declares its parameter")
		Assert(GestureActionParameterPrompt(Id) != "", Id . " asks for it")
	}
	AssertFalse(InStr(GestureActionParameterPrompt("run_command"), "/bin/sh"), "Windows names its own shell")
	AssertContains(GestureActionParameterPrompt("run_command"), "cmd.exe")
}
Test("user actions: both actions are registered on Windows (user-actions)", _UA_Registered)
