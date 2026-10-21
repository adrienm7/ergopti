; tests/unit/adapters/shell_runner/test_shell_runner_nul_arguments.ahk

; ==============================================================================
; MODULE: Shell Runner NUL Argument Refusal Tests
; DESCRIPTION:
; A Windows command line is a NUL-terminated string, and AutoHotkey's
; Loop Parse stops at the first NUL code unit, so an argument holding one
; reached the child shortened: "keep" NUL "drop" arrived as "keep" while the
; caller believed the whole value was passed. The executable path and the
; synchronous shell command have the same boundary. Every spawn entry must
; refuse such input before any child exists; a healthy control proves that the
; same launch otherwise runs and transports its arguments unchanged.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../support/filesystem_write_lock.ahk

_SRNUL_Done(State, Code, Output, Errors) {
	State["code"] := Code
	State["done"] := true
}

; Launches the argv echo fixture and returns whether start() admitted it. On
; admission the completion is awaited so the receipt (if any) is final.
_SRNUL_Launch(SpawnFn, Executable, Values, ReceiptPath) {
	static TimeoutMs := 10000
	State := Map("done", false)
	Args := ["/ErrorStdOut", A_ScriptDir . "\support\argv_echo.ahk", ReceiptPath]
	for Value in Values
		Args.Push(Value)
	Handle := SpawnFn.Call(Executable, Args, _SRNUL_Done.Bind(State))
	Started := false
	try {
		Started := Handle.start()
		if Started {
			Begin := A_TickCount
			while !State["done"] && TickElapsed(Begin) < TimeoutMs
				Sleep(20)
			AssertTrue(State["done"], "an admitted fixture child must complete within its budget")
		}
	} finally {
		if Started && !State["done"]
			Handle.terminate()
	}
	return Started
}

_SRNUL_ReceiptLines(ReceiptPath) {
	return StrSplit(RTrim(FileRead(ReceiptPath, "UTF-8"), "`n"), "`n")
}

_SRNUL_Cleanup(ReceiptPath) {
	for Path in [ReceiptPath, ReceiptPath . ".writing"]
		if FileExist(Path)
			FileDelete(Path)
}

_SRNUL_ArgumentRefused(SpawnFn) {
	ReceiptPath := _FSWL_Path()
	try {
		for Position in ["middle", "leading", "trailing"] {
			Value := Position == "leading" ? Chr(0) . "drop"
				: Position == "trailing" ? "keep" . Chr(0) : "keep" . Chr(0) . "drop"
			Started := _SRNUL_Launch(SpawnFn, A_AhkPath, ["before", Value, "after"], ReceiptPath)
			Observed := FileExist(ReceiptPath) ? _SRNUL_ReceiptLines(ReceiptPath) : []
			_SRNUL_Cleanup(ReceiptPath)
			AssertFalse(Started, "a " . Position . " NUL argument must be refused before any child starts"
				. (Observed.Length >= 3 ? " (child received hex " . Observed[3] . ")" : ""))
			AssertEqual(0, Observed.Length, "a refused " . Position . " NUL argument must leave no child receipt")
		}
	} finally _SRNUL_Cleanup(ReceiptPath)
}

_SRNUL_ExecutableRefused(SpawnFn) {
	ReceiptPath := _FSWL_Path()
	try {
		Started := _SRNUL_Launch(SpawnFn, A_AhkPath . Chr(0) . ".ignored.exe", ["control"], ReceiptPath)
		Received := FileExist(ReceiptPath) != ""
		_SRNUL_Cleanup(ReceiptPath)
		AssertFalse(Started, "an executable path holding NUL must be refused before CreateProcessW")
		AssertFalse(Received, "a refused executable path must not run its NUL-terminated prefix")
	} finally _SRNUL_Cleanup(ReceiptPath)
}

_SRNUL_ControlStillTransports(SpawnFn) {
	ReceiptPath := _FSWL_Path()
	try {
		AssertTrue(_SRNUL_Launch(SpawnFn, A_AhkPath, ["before", "keep drop", "", "after"], ReceiptPath),
			"the same NUL-free launch must start")
		Lines := _SRNUL_ReceiptLines(ReceiptPath)
		AssertEqual(5, Lines.Length, "the control child must report every argument")
		AssertEqual("4", Lines[1], "the control child must receive four arguments")
		AssertEqual("6B6565702064726F70", Lines[3], "the control argument must arrive byte for byte")
		AssertEqual("", Lines[4], "an empty control argument must stay a distinct empty argument")
	} finally _SRNUL_Cleanup(ReceiptPath)
}

/** Registers both argv entries without publishing global loop variables. */
_SRNUL_RegisterSpawnCases() {
	local Name, SpawnFn
	for Name, SpawnFn in Map("legacy", ShellRunner_Spawn, "tree", ShellRunner_SpawnTreeOwned) {
		Test("shell runner: " . Name . " spawn refuses a NUL argument (shell-nul-argv)",
			_SRNUL_ArgumentRefused.Bind(SpawnFn))
		Test("shell runner: " . Name . " spawn refuses a NUL executable path (shell-nul-argv)",
			_SRNUL_ExecutableRefused.Bind(SpawnFn))
		Test("shell runner: " . Name . " spawn still transports NUL-free arguments (shell-nul-argv)",
			_SRNUL_ControlStillTransports.Bind(SpawnFn))
	}
}
_SRNUL_RegisterSpawnCases()

; The synchronous entry hands a whole command string to cmd.exe through Run.
; Truncation there runs the prefix and drops the capture redirection, so the
; caller sees an empty result for a command that partly executed.
_SRNUL_ExecRefusesNulCommand() {
	; A directory is the side effect: it does not compete with the capture redirection.
	Target := _FSWL_Path() . ".dir"
	try {
		Result := ShellRunner_Exec('mkdir "' . Target . '"' . Chr(0) . " & echo hidden")
		Created := DirExist(Target) != ""
		if Created
			DirDelete(Target)
		AssertEqual("", Result, "a refused NUL command must return the adapter's empty failure result")
		AssertFalse(Created, "a NUL command must never execute its NUL-terminated prefix")
		; cmd.exe keeps the space before the capture redirection in echo output.
		AssertEqual("ok", Trim(ShellRunner_Exec("echo ok")), "a NUL-free command must still run and capture")
		ShellRunner_Exec('mkdir "' . Target . '"')
		AssertTrue(DirExist(Target) != "", "the NUL-free control command must still run")
	} finally {
		if DirExist(Target)
			DirDelete(Target)
	}
}
Test("shell runner: exec refuses a NUL command before cmd.exe runs (shell-nul-argv)",
	_SRNUL_ExecRefusesNulCommand)
