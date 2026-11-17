; tests/unit/gestures/engine/test_user_actions.ahk

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



; A separate strict scope leaves the historical helper untouched. No foreign
; binding is stopped: only the exact acquired command handle may be retired.
_UAN_Effect(Record, State, Kind, Text) {
	_UAN_Observe(State, Kind, Text)
	Record[Kind == "notify" ? "notices" : (Kind == "copy" ? "copied" : "typed")].Push(Text)
	return true
}
_UAN_Run(Command, Output, State) {
	global _UserActionPorts, GestureActionParameters, _UserCommandEntries
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unacknowledged exact command must retain its source and ports before any successor test")
	AssertEqual(0, _UserCommandEntries.Count, "Global effect recorders require an idle command owner; no foreign command may be observed or stopped")
	Record := Map("notices", [], "copied", [], "typed", [], "started", false, "finished", false)
	SavedPorts := _UserActionPorts, SavedParameters := GestureActionParameters
	State.Retired := false
	_UserActionPorts := Map(
		"notify", _UAN_Effect.Bind(Record, State, "notify"),
		"copy", _UAN_Effect.Bind(Record, State, "copy"),
		"type", _UAN_Effect.Bind(Record, State, "type"),
		"open_terminal", (*) => true, "shell_open", (*) => true)
	try {
		GestureActionParameters := Map(GestureActionParameterKey(State.Binding, "run_command"),
			UserActionSpellCommand(Command, "hidden", Output))
		Record["started"] := UserActions_RunCommand(State.Binding)
		if _UserCommandEntries.Has(State.Binding)
			State.Entry := _UserCommandEntries[State.Binding]
		Started := A_TickCount
		while _UserCommandEntries.Has(State.Binding) && TickElapsed64(Started) < 30000
			Sleep(20)
		; Retiring a timeout afterward cannot turn the original deadline green.
		Record["finished"] := !_UserCommandEntries.Has(State.Binding)
	} finally {
		if !IsObject(State.Entry) && _UserCommandEntries.Has(State.Binding)
			State.Entry := _UserCommandEntries[State.Binding]
		Receipt := 0
		if State.Entry is Map && State.Entry.Has("handle") {
			try Receipt := State.Entry["handle"].terminate()
		}
		if Receipt is Integer && Receipt == 1 {
			State.Retired := true
			try {
				if State.Entry is Map && !State.Entry["finished"]
					_UserCommandFinish(State.Entry)
			} finally {
				_UserActionPorts := SavedPorts
				GestureActionParameters := SavedParameters
			}
		} else {
			; Keep the live observer, exact process/captures, private source root
			; and prior state strongly reachable. Late completion must not use
			; restored foreign effect ports; the next probe must not replace it.
			RetirementDebt := {State: State, Ports: _UserActionPorts, Parameters: GestureActionParameters,
				SavedPorts: SavedPorts, SavedParameters: SavedParameters}
		}
	}
	AssertTrue(State.Retired, "The exact native command tree must acknowledge retirement before ports or private source cleanup")
	return Record
}

_UAN_Hex(Bytes) {
	Hex := ""
	loop Bytes.Size
		Hex .= Format("{:02X}", NumGet(Bytes, A_Index - 1, "UChar"))
	return Hex
}
_UAN_Observe(State, Kind, Text) {
	global _UserCommandEntries
	try {
		State.Reads += 1
		if !_UserCommandEntries.Has(State.Binding)
			throw Error("The exact public command must still own its capture at the delivery/refusal port")
		Entry := _UserCommandEntries[State.Binding]
		State.Entry := Entry
		if Entry["finished"]
			throw Error("No retired capture may prove the original command output")
		Bytes := FSReadBytesStrict(Entry[State.HasOwnProp("CaptureField") ? State.CaptureField : "out"])
		State.CaptureHex := _UAN_Hex(Bytes)
		State.DeliveredUnits := StrLen(Text)
		State.Kind := Kind
	} catch Any as Failure {
		if !IsObject(State.Failure)
			State.Failure := Failure
	}
}
_UAN_Case(Mode) {
	Raw := Mode == "unicode" ? [0xC3, 0xA9, 0xF0, 0x9F, 0x98, 0x80]
		: (Mode == "invalid-utf8" ? [0xC3, 0x28] : [0x41, 0, 0x42])
	Bytes := Buffer(Raw.Length)
	for Index, Byte in Raw
		NumPut("UChar", Byte, Bytes, Index - 1)
	ExpectedHex := _UAN_Hex(Bytes)
	IsNul := Mode == "nul-copy" || Mode == "nul-type" || Mode == "nul-stderr"
	ValidUtf8 := HTTPIsValidUtf8(Bytes, Bytes.Size)
	AssertEqual(Mode != "invalid-utf8", !!ValidUtf8, "The native decoder precondition must distinguish valid UTF-8 containing NUL from malformed bytes")
	if IsNul {
		Positive := StrGet(Bytes, Bytes.Size, "UTF-8"), Counted := StrGet(Bytes, -Bytes.Size, "UTF-8")
		AssertEqual(1, StrLen(Positive), "The actual positive-length AHK conversion must exhibit its first-NUL boundary")
		AssertEqual(3, StrLen(Counted), "The negative-length native control must retain all original units")
		AssertEqual(0, NumGet(StrPtr(Counted), 2, "UShort"))
		AssertEqual(0x42, NumGet(StrPtr(Counted), 4, "UShort"))
	}
	Directory := A_Temp . "\ergopti_command_bytes_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := FSCreateDirectoryExclusiveStrict(Directory)
	AssertTrue(Created is Integer && Created == 1, "The raw stdout witness directory must be acquired exclusively before any write or cleanup")
	Path := Directory . "\stdout.raw", Handle := 0, OwnedFile := false
	State := {Reads: 0, CaptureHex: "", DeliveredUnits: -1, Kind: "", Failure: 0,
		Binding: "ua_counted_output", Entry: 0, Retired: true, Root: Directory,
		CaptureField: Mode == "nul-stderr" ? "err" : "out"}
	try {
		Handle := DllCall("Kernel32\CreateFileW", "WStr", Path, "UInt", 0x40000000, "UInt", 1,
			"Ptr", 0, "UInt", 1, "UInt", 0x80, "Ptr", 0, "Ptr")
		AssertTrue(Handle && Handle != -1, "The raw witness itself must be acquired by native CREATE_NEW")
		OwnedFile := true
		Written := 0
		AssertTrue(DllCall("Kernel32\WriteFile", "Ptr", Handle, "Ptr", Bytes, "UInt", Bytes.Size,
			"UInt*", &Written, "Ptr", 0, "Int") && Written == Bytes.Size,
			"The private raw witness must acknowledge every original byte")
		AssertTrue(DllCall("Kernel32\FlushFileBuffers", "Ptr", Handle, "Int"), "The native raw fixture must flush before the real shell reads it")
		AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int"), "The exact writer must retire before running the public command")
		Handle := 0
		AssertEqual(ExpectedHex, _UAN_Hex(FSReadBytesStrict(Path)), "The independent source file must retain every original byte")
		Output := Mode == "nul-type" ? "type" : "copy"
		Command := 'type "' . Path . '"' . (Mode == "nul-stderr" ? " 1>&2 & exit /b 3" : "")
		Record := _UAN_Run(Command, Output, State)
		_TestPrint("# user-command-counted mode=" . Mode . " started=" . Record["started"]
			. " finished=" . Record["finished"] . " expected_hex=" . ExpectedHex . " capture_hex=" . State.CaptureHex
			. " valid_utf8=" . !!ValidUtf8 . " observations=" . State.Reads . " port=" . State.Kind
			. " delivered_units=" . State.DeliveredUnits . " copies=" . Record["copied"].Length
			. " types=" . Record["typed"].Length . " notices=" . Record["notices"].Length)
		AssertTrue(Record["started"] && Record["finished"], "The genuine public command must run through the actual owned cmd process to completion")
		if IsObject(State.Failure)
			throw State.Failure
		AssertEqual(1, State.Reads, "The real producer capture must be independently observed at its one final effect/refusal port")
		AssertEqual(ExpectedHex, State.CaptureHex, "The actual cmd capture must retain the original bytes at the final effect/refusal port after decoding and before cleanup")
		AssertEqual(ExpectedHex, _UAN_Hex(FSReadBytesStrict(Path)), "The command cannot mutate its exclusively owned raw source witness")
		if Mode == "unicode" {
			ExpectedText := Chr(0xE9) . Chr(0x1F600)
			AssertEqual(0, Record["notices"].Length)
			AssertEqual(1, Record["copied"].Length)
			AssertEqual(ExpectedText, Record["copied"][1], "Ordinary accented and supplementary UTF-8 must retain complete output")
			AssertEqual(3, StrLen(Record["copied"][1]))
		} else if Mode == "nul-stderr" {
			AssertEqual(0, Record["copied"].Length)
			AssertEqual(0, Record["typed"].Length)
			AssertEqual(1, Record["notices"].Length)
			AssertEqual(StrReplace(t("user_actions.command_failed"), "{1}", "3"), Record["notices"][1],
				"A binary error stream must keep the existing generic failed-exit receipt, never a truncated first-line detail")
		} else {
			AssertEqual(0, Record["copied"].Length, "Binary/invalid stdout must never publish a silently shortened copy")
			AssertEqual(0, Record["typed"].Length, "Binary/invalid stdout must never publish a silently shortened typed prefix")
			AssertEqual(1, Record["notices"].Length, "Refused output must use the existing explicit not-text receipt")
			AssertEqual(t("user_actions.output_not_text"), Record["notices"][1])
		}
	} finally {
		if Handle && Handle != -1 {
			AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int"), "An acquired fixture writer must retire before exact cleanup")
			Handle := 0
		}
		if State.Retired {
			if OwnedFile
				FileDelete(Path)
			DirDelete(Directory)
		} else
			_TestPrint("# user-command-counted retirement UNACKNOWLEDGED; exact source/captures/ports retained")
	}
}
for _UAN_Mode in ["nul-copy", "nul-type", "unicode", "invalid-utf8"]
	Test("Public command counted stdout: " . _UAN_Mode . " preserves or explicitly refuses the complete capture (user-command-counted-output)",
		_UAN_Case.Bind(_UAN_Mode))


_UAFP_Count(State, This, Text) {
	State.Calls += 1
	State.Units += StrLen(Text)
	return Func.Prototype.Call.Call(This, Text)
}
_UAFP_Work() {
	global _UserCommandEntries, USER_ACTION_NOTICE_LINE_BYTES
	AssertEqual(0, _UserCommandEntries.Count, "The pure measurement cannot instrument another active command")
	Limit := TimingsGet("limits", "user_action_output_bytes")
	Maximum := USER_ACTION_NOTICE_LINE_BYTES
	AssertTrue(Limit > Maximum && Maximum > 0, "The real capture bound must exceed its actual notification prefix")
	Bytes := Buffer(Limit, 0x78), Input := StrGet(Bytes, -Bytes.Size, "UTF-8")
	State := {Calls: 0, Units: 0}
	Owner := _UserActionBytes
	AssertFalse(Owner.HasOwnProp("Call"), "The exact pure byte-count owner must not already belong to another observer")
	Installed := false
	try {
		Owner.DefineProp("Call", {Call: _UAFP_Count.Bind(State)})
		Installed := true
		AssertEqual(1, _UserActionBytes("x"), "The observer must forward the exact native production result")
		AssertEqual(1, State.Calls, "The real named AHK call must enter the genuine Func.Call observer before work is attributed")
		State.Calls := 0, State.Units := 0
		Started := A_TickCount
		Actual := UserActionFirstLine(Input, Maximum)
		Elapsed := TickElapsed64(Started)
		_TestPrint("# OBSERVATION user-command-firstline-work input_bytes=" . Limit . " notice_bytes=" . Maximum
			. " encoding_calls=" . State.Calls . " encoded_utf16_units=" . State.Units
			. " elapsed_ms=" . Elapsed . " result_units=" . StrLen(Actual))
		AssertTrue(State.Calls > 0, "The actual first-line owner must invoke the byte boundary being measured")
		; One full capture scan and work bounded by the notice width may size the prefix.
		AssertTrue(State.Units <= Limit + (Maximum + 1) ** 2,
			"A short notification must not repeatedly size the complete command capture")
		AssertEqual(SubStr(Input, 1, Maximum) . "…", Actual, "The observation must retain the complete established first-line behavior")
		; Deliberately no elapsed-time threshold: this is native evidence, not a
		; hardware-dependent pass/fail performance budget or a new product policy.
	} finally {
		if Installed
			Owner.DeleteProp("Call")
	}
}
Test("User command first-line work at the actual capture limit retains its prefix (user-command-firstline-work-observation)",
	_UAFP_Work)

#Include test_user_command_lifecycle_owner.ahk

Test("Public command counted stderr: NUL capture retains the generic failed-exit receipt (user-command-counted-stderr)",
	_UAN_Case.Bind("nul-stderr"))

_UA_FirstLineScalarBoundaries() {
	Rocket := Chr(0x1F600), Accent := Chr(0xE9)
	Ascii := StrGet(Buffer(201, 0x78), -201, "UTF-8")
	Cases := [
		[SubStr(Ascii, 1, 200), 200, SubStr(Ascii, 1, 200)],
		[Ascii, 200, SubStr(Ascii, 1, 200) . "…"],
		[Rocket . "x", 1, "…"], [Rocket . "x", 2, "…"],
		[Rocket . "x", 3, "…"], [Rocket . "x", 4, Rocket . "…"],
		[Rocket . "x", 5, Rocket . "x"],
		[Accent . Rocket . "x", 6, Accent . Rocket . "…"],
		["x", 0, "…"], ["x", -1, "…"],
		["`r`n `t`r`n" . Accent . "`r`nsecond", 2, Accent]
	]
	for Index, Row in Cases
		AssertEqual(Row[3], UserActionFirstLine(Row[1], Row[2]), "First-line UTF-8 boundary " . Index)
}
Test("User command first-line byte limits retain complete Unicode scalars (user-command-firstline-scalars)",
	_UA_FirstLineScalarBoundaries)


_UAE_Names() => ["ERGOPTI_USER_COMMAND", "ERGOPTI_USER_COMMAND_OUT", "ERGOPTI_USER_COMMAND_ERR"]
_UAE_SaveEnvironment() {
	Saved := Map()
	Saved.CaseSense := "Off"
	for Name in _UAE_Names()
		Saved[Name] := {Name: Name, Present: false, Value: ""}
	Source := DllCall("Kernel32\GetEnvironmentStringsW", "Ptr")
	AssertTrue(Source != 0, "The actual parent environment must be acquired before changing any private name")
	try {
		Cursor := Source
		while NumGet(Cursor, 0, "UShort") {
			Row := StrGet(Cursor, "UTF-16")
			Cursor += (StrLen(Row) + 1) * 2
			Separator := InStr(Row, "=", true, 2)
			if !Separator
				continue
			Name := SubStr(Row, 1, Separator - 1)
			if Saved.Has(Name) {
				AssertFalse(Saved[Name].Present, "A pre-existing duplicate private parent name cannot be normalized by this fixture")
				Saved[Name] := {Name: Name, Present: true, Value: SubStr(Row, Separator + 1)}
			}
		}
	} finally AssertTrue(DllCall("Kernel32\FreeEnvironmentStringsW", "Ptr", Source, "Int"), "The exact parent environment buffer must retire")
	return Saved
}
_UAE_RestoreEnvironment(Saved) {
	Current := _UAE_SaveEnvironment()
	for Name in _UAE_Names() {
		if Current[Name].Present
			AssertTrue(DllCall("Kernel32\SetEnvironmentVariableW", "Str", Name, "Ptr", 0, "Int"), "Only the three owned temporary names may be removed during restoration")
	}
	for _, Item in Saved {
		if Item.Present
			AssertTrue(DllCall("Kernel32\SetEnvironmentVariableW", "Str", Item.Name, "Ptr", StrPtr(Item.Value), "Int"),
				"The exact prior spelling, presence and value (including empty) must be restored")
	}
	Restored := _UAE_SaveEnvironment()
	for Name, Item in Saved {
		AssertEqual(Item.Present, Restored[Name].Present)
		if Item.Present
			AssertEqual(Item.Value, Restored[Name].Value)
	}
}
_UAE_Count(Block, Name) {
	Cursor := 0, Found := 0
	while Cursor + 2 <= Block.Size && NumGet(Block, Cursor, "UShort") {
		Start := Cursor
		while Cursor + 2 <= Block.Size && NumGet(Block, Cursor, "UShort")
			Cursor += 2
		AssertTrue(Cursor + 2 <= Block.Size, "The actual native environment block must remain within its counted Buffer")
		Row := StrGet(Block.Ptr + Start, -((Cursor - Start) // 2), "UTF-16")
		if StrCompare(SubStr(Row, 1, StrLen(Name) + 1), Name . "=", false) == 0
			Found += 1
		Cursor += 2
	}
	return Found
}
_UAE_Case(Mode) {
	global _UserCommandEntries
	AssertEqual(0, _UserCommandEntries.Count, "No existing command may observe this temporary parent environment")
	Root := A_Temp . "\ergopti_command_environment_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	Created := FSCreateDirectoryExclusiveStrict(Root)
	AssertTrue(Created is Integer && Created == 1, "The witness root must be acquired exclusively before any write or recursive cleanup")
	State := {Reads: 0, CaptureHex: "", DeliveredUnits: -1, Kind: "", Failure: 0,
		Binding: "ua_inherited_environment", Entry: 0, Retired: true, Root: Root}
	Saved := 0
	try {
		OutPath := Root . "\inherited.out", ErrPath := Root . "\inherited.err"
		Sentinel := "owned-inherited-redirection-sentinel"
		AssertTrue(FSWriteCreateDurable(OutPath, Sentinel) && FSWriteCreateDurable(ErrPath, Sentinel), "Only exclusively acquired private witnesses may receive inherited redirection")
		Saved := _UAE_SaveEnvironment()
		for Name in _UAE_Names() {
			if Saved[Name].Present
				EnvSet(Name)
		}
		; Both possible commands remain alive long enough for the strict helper
		; to capture its exact actual Entry. Only a local timer process is used.
		Delay := '"' . A_WinDir . '\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds 200" & '
		Command := Delay . (Mode == "err" ? "echo intended_error_canary 1>&2 & exit /b 3" : "echo intended_output_canary")
		if Mode == "command" || Mode == "command-lower"
			EnvSet(Mode == "command-lower" ? "ergopti_user_command" : "ERGOPTI_USER_COMMAND", Delay . "echo inherited_command_canary")
		else if Mode == "out"
			EnvSet("ERGOPTI_USER_COMMAND_OUT", OutPath)
		else if Mode == "err"
			EnvSet("ERGOPTI_USER_COMMAND_ERR", ErrPath)
		Overrides := Map("ERGOPTI_USER_COMMAND", Command, "ERGOPTI_USER_COMMAND_OUT", Root . "\preview.out", "ERGOPTI_USER_COMMAND_ERR", Root . "\preview.err")
		ActualBlock := _UserCommandEnvironment(Overrides)
		CanonicalBlock := ShellRunner_BuildEnvironment(Overrides)
		Name := Mode == "out" ? "ERGOPTI_USER_COMMAND_OUT" : (Mode == "err" ? "ERGOPTI_USER_COMMAND_ERR" : "ERGOPTI_USER_COMMAND")
		ActualCount := _UAE_Count(ActualBlock, Name), CanonicalCount := _UAE_Count(CanonicalBlock, Name)
		AssertEqual(1, CanonicalCount, "The existing canonical builder independently supplies a unique override")
		Record := _UAN_Run(Command, "copy", State)
		OutUnchanged := FSReadUtf8Exact(OutPath) == Sentinel
		ErrUnchanged := FSReadUtf8Exact(ErrPath) == Sentinel
		IntendedCopy := Record["copied"].Length == 1 && Record["copied"][1] == "intended_output_canary"
		InheritedCopy := Record["copied"].Length == 1 && Record["copied"][1] == "inherited_command_canary"
		IntendedError := Record["notices"].Length == 1 && InStr(Record["notices"][1], "intended_error_canary", true) > 0
		ModeNumber := Mode == "command" ? 1 : (Mode == "command-lower" ? 2 : (Mode == "out" ? 3 : (Mode == "err" ? 4 : 5)))
		_TestPrint("# OBSERVATION user-command-inherited-environment mode=" . ModeNumber
			. " started=" . Record["started"] . " finished=" . Record["finished"] . " retired=" . State.Retired
			. " actual_rows=" . ActualCount . " canonical_rows=" . CanonicalCount
			. " copies=" . Record["copied"].Length . " notices=" . Record["notices"].Length
			. " intended_copy=" . IntendedCopy . " inherited_copy=" . InheritedCopy . " intended_error=" . IntendedError
			. " out_unchanged=" . OutUnchanged . " err_unchanged=" . ErrUnchanged)
		AssertTrue(Record["started"] && Record["finished"] && State.Retired, "The public command must complete and its exact tree must acknowledge retirement")
		if IsObject(State.Failure)
			throw State.Failure
		AssertTrue(OutUnchanged && ErrUnchanged, "Inherited private redirections must not replace the public command's own capture destinations")
		if Mode == "err"
			AssertTrue(IntendedError && Record["copied"].Length == 0, "A genuine failed command must retain its intended error detail through its own stderr capture")
		else
			AssertTrue(IntendedCopy && Record["notices"].Length == 0, "The public stored command must override any earlier inherited spelling, irrespective of native duplicate normalization")
	} finally {
		; CreateProcess copied its block: restoring the parent cannot change a
		; retained child. Its private source/witnesses stay until strict ACK.
		try {
			if Saved is Map
				_UAE_RestoreEnvironment(Saved)
		} finally {
			if State.Retired
				DirDelete(Root, true)
			else
				_TestPrint("# command environment witnesses retained with exact unretired process debt")
		}
	}
}
for _UAE_Mode in ["command", "command-lower", "out", "err", "clean"]
	Test("Public command inherited environment: " . _UAE_Mode . " keeps its genuine private override (user-command-inherited-environment)",
		_UAE_Case.Bind(_UAE_Mode))
