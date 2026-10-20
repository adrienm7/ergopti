; tests/unit/adapters/shell_runner/test_shell_runner_native_argv.ahk

; ==============================================================================
; MODULE: Shell Runner Native Argument Transport Tests
; DESCRIPTION:
; A trailing directory separator absorbed every metrics timing argument after
; cmd.exe launch. Only a real child argv receipt can prove transport fidelity.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../support/filesystem_write_lock.ahk
_SRAV_Done(State, Code, Output, Errors) {
	State["code"] := Code
	State["output"] := Output
	State["errors"] := Errors
	State["done"] := true
}

_SRAV_Expected(Values) {
	Expected := Values.Length . "`n"
	for Value in Values {
		Bytes := Buffer(StrPut(Value, "UTF-8"))
		Count := StrPut(Value, Bytes, "UTF-8") - 1
		loop Count
			Expected .= Format("{:02X}", NumGet(Bytes, A_Index - 1, "UChar"))
		Expected .= "`n"
	}
	return Expected
}

_SRAV_RoundTrip(SpawnFn, Values) {
	static TimeoutMs := 10000, PollMs := 20
	State := Map("done", false)
	ReceiptPath := _FSWL_Path()
	Args := ["/ErrorStdOut", A_ScriptDir . "\support\argv_echo.ahk", ReceiptPath]
	for Value in Values
		Args.Push(Value)
	Handle := SpawnFn.Call(A_AhkPath, Args, _SRAV_Done.Bind(State))
	; Construction owns the validated vector, even when the caller reuses its array
	Args.Push("late`nmutation")
	try {
		AssertTrue(Handle.start(), "the actual AHK child must start")
		Started := A_TickCount
		while (!State["done"] || !FileExist(ReceiptPath)) && TickElapsed(Started) < TimeoutMs
			Sleep(PollMs)
		AssertTrue(State["done"], "native child must report completion within its test budget")
		AssertEqual(0, State["code"])
		AssertEqual("", State["errors"])
		AssertTrue(FileExist(ReceiptPath) != "", "the actual child must publish its complete receipt")
		AssertEqual(_SRAV_Expected(Values), FileRead(ReceiptPath, "UTF-8"),
			"native child must receive every argument byte and boundary unchanged")
	} finally {
		if !State["done"]
			Handle.terminate()
		for Path in [ReceiptPath, ReceiptPath . ".writing"] {
			if FileExist(Path)
				FileDelete(Path)
		}
	}
}

_SRAV_MetricsVector() {
	Values := ["--keylogger-prefetch-worker", "typing", "C:\synthetic metrics", "full",
		"C:\stage.json", "C:\synthetic config\"]
	for Timing in KLPF_WorkerTimingArgs()
		Values.Push(Timing)
	return Values
}

/** Registers vectors without publishing global loop variables. */
_SRAV_RegisterArgumentCases() {
	local Name, SpawnFn
	for Name, SpawnFn in Map("legacy", ShellRunner_Spawn, "tree", ShellRunner_SpawnTreeOwned) {
		Test("shell runner: native argv control " . Name . " (shell-native-argv)",
			_SRAV_RoundTrip.Bind(SpawnFn, ["plain", "", "two words", "é😀", "after"]))
		Test("shell runner: trailing slashes preserve successor arguments " . Name . " (shell-native-argv)",
			_SRAV_RoundTrip.Bind(SpawnFn, ["C:\config\", "after-one", "\\server\share\\", "after-two",
				"D:\folder with spaces\\\", "after-three"]))
		Test("shell runner: metrics timings survive actual launch " . Name . " (shell-native-argv)",
			_SRAV_RoundTrip.Bind(SpawnFn, _SRAV_MetricsVector()))
	}
}
_SRAV_RegisterArgumentCases()

_SRAV_PreservesLiteralPercentArguments(SpawnFn) {
	EnvName := "ERGOPTI_SHELLRUNNER_LITERAL_20260907"
	Literal := "%" . EnvName . "%"
	Previous := EnvGet(EnvName)
	EnvSet(EnvName, "must-not-expand")
	try {
		_SRAV_RoundTrip(SpawnFn,
			[Literal, "after-literal-percent"])
	} finally {
		EnvSet(EnvName, Previous)
	}
}
/** Registers vectors without publishing global loop variables. */
_SRAV_RegisterLiteralPercentCases() {
	local Name, SpawnFn
	for Name, SpawnFn in Map("legacy", ShellRunner_Spawn, "tree", ShellRunner_SpawnTreeOwned) {
		Test("shell runner: " . Name . " argv preserves literal percent values (shell-native-literal-percent)",
			_SRAV_PreservesLiteralPercentArguments.Bind(SpawnFn))
	}
}
_SRAV_RegisterLiteralPercentCases()

_SRAV_PrivateEnvironment(Value) {
	Entries := ["ERGOPTI_RAW_CHILD_VALUE=" . Value, "SystemRoot=" . A_WinDir]
	Count := 1
	for Entry in Entries
		Count += StrLen(Entry) + 1
	Environment := Buffer(Count * 2, 0)
	Offset := 0
	for Entry in Entries {
		StrPut(Entry, Environment.Ptr + Offset, StrLen(Entry) + 1, "UTF-16")
		Offset += (StrLen(Entry) + 1) * 2
	}
	return Environment
}

_SRAV_RawCommandCapturesPrivateEnvironment() {
	Root := _FSWL_Path() . "_raw"
	AssertFalse(DirExist(Root))
	DirCreate(Root)
	Task := 0, State := Map("done", false)
	ParentValue := EnvGet("ERGOPTI_RAW_CHILD_VALUE")
	try {
		DirCreate(Root . "\scripts")
		DirCreate(Root . "\cwd")
		Child := Root . "\scripts\child.ahk", Receipt := Root . "\receipt.txt"
		Code := '#Requires AutoHotkey v2.0`n#NoTrayIcon`n'
			. 'FileAppend(EnvGet("ERGOPTI_RAW_CHILD_VALUE") . "``n" . A_WorkingDir, A_Args[1], "UTF-8-RAW")`nExitApp(37)`n'
		FileAppend(Code, Child, "UTF-8")
		Value := "captured-child-value é"
		Environment := _SRAV_PrivateEnvironment(Value)
		Command := _SR_BuildDirectCommandLine(A_AhkPath, ["/ErrorStdOut", Child, Receipt])
		Directory := Root . "\cwd"
		Task := ShellRunner_SpawnTreeOwnedCommand(A_AhkPath, Command, Environment, Directory, _SRAV_Done.Bind(State))
		; The lazy task owns a snapshot, even if its caller reuses both inputs.
		NumPut("UShort", Ord("X"), Environment, StrLen("ERGOPTI_RAW_CHILD_VALUE=") * 2)
		Directory := A_Temp
		AssertTrue(Task.start(), "the actual raw command must start with its captured native inputs")
		Started := DllCall("Kernel32\GetTickCount64", "UInt64")
		while !State["done"] && DllCall("Kernel32\GetTickCount64", "UInt64") - Started < 10000
			Sleep(10)
		AssertTrue(State["done"], "the raw child must deliver its complete canonical native receipt")
		AssertEqual(37, State["code"], "the canonical completion must preserve the actual native exit status")
		AssertEqual("", State["errors"])
		AssertEqual(Value . "`n" . Root . "\cwd", FileRead(Receipt, "UTF-8"),
			"the actual child must receive the frozen Unicode environment and working directory")
		AssertEqual(ParentValue, EnvGet("ERGOPTI_RAW_CHILD_VALUE"), "the private environment never mutates the parent")
	} finally {
		if IsObject(Task) {
			Retired := Task.requestTerminate()
			Started := DllCall("Kernel32\GetTickCount64", "UInt64")
			while !Retired && DllCall("Kernel32\GetTickCount64", "UInt64") - Started < 5000 {
				Sleep(10)
				Retired := Task.requestTerminate()
			}
			AssertTrue(Retired, "the raw fixture Job must retire before its private files")
		}
		DirDelete(Root, true)
	}
}
Test("shell runner: raw command freezes private environment and cwd (shell-raw-tree-launch)",
	_SRAV_RawCommandCapturesPrivateEnvironment)

_SRAV_RawCommandRejectsInvalidNativeInputs() {
	Environment := _SRAV_PrivateEnvironment("valid")
	Command := _SR_BuildDirectCommandLine(A_ComSpec, ["/D", "/C", "exit /b 0"])
	for Inputs in [[0, Command, Environment, ""], ["cmd.exe", Command, Environment, ""],
		[A_ComSpec, 0, Environment, ""], [A_ComSpec, "", Environment, ""],
		[A_ComSpec, Command, 0, ""], [A_ComSpec, Command, Buffer(3, 0), ""],
		[A_ComSpec, Command, Buffer(4, 65), ""], [A_ComSpec, Command, Environment, 0],
		[A_ComSpec, Command . Chr(0) . "unadmitted", Environment, ""],
		[A_ComSpec, Command, Environment, "C:\" . Chr(0) . "unadmitted"]] {
		AssertThrows(ShellRunner_SpawnTreeOwnedCommand.Bind(Inputs*),
			"invalid raw launch input must refuse before any native child can exist")
	}
}
Test("shell runner: raw command refuses malformed native inputs (shell-raw-tree-launch)",
	_SRAV_RawCommandRejectsInvalidNativeInputs)
