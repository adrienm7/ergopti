; tests/unit/test_shell_runner_native_argv.ahk

; ==============================================================================
; MODULE: Shell Runner Native Argument Transport Tests
; DESCRIPTION:
; A trailing directory separator absorbed every metrics timing argument after
; cmd.exe launch. Only a real child argv receipt can prove transport fidelity.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../support/filesystem_write_lock.ahk

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

for Name, SpawnFn in Map("legacy", ShellRunner_Spawn, "tree", ShellRunner_SpawnTreeOwned) {
	Test("shell runner: native argv control " . Name . " (shell-native-argv)",
		_SRAV_RoundTrip.Bind(SpawnFn, ["plain", "", "two words", "é😀", "after"]))
	Test("shell runner: trailing slashes preserve successor arguments " . Name . " (shell-native-argv)",
		_SRAV_RoundTrip.Bind(SpawnFn, ["C:\config\", "after-one", "\\server\share\\", "after-two",
			"D:\folder with spaces\\\", "after-three"]))
	Test("shell runner: metrics timings survive actual launch " . Name . " (shell-native-argv)",
		_SRAV_RoundTrip.Bind(SpawnFn, _SRAV_MetricsVector()))
}

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
for Name, SpawnFn in Map("legacy", ShellRunner_Spawn, "tree", ShellRunner_SpawnTreeOwned) {
	Test("shell runner: " . Name . " argv preserves literal percent values (shell-native-literal-percent)",
		_SRAV_PreservesLiteralPercentArguments.Bind(SpawnFn))
}
