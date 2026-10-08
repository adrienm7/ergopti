; tests/meta/test_runner_failure_ergonomics.ahk

; ==============================================================================
; MODULE: Test Runner Failure-Ergonomics Meta Test
; DESCRIPTION:
; Behaviour guard for _TestCallSite (test_framework.ahk): when a test fails, the
; reported ``[file:line]`` must point at the TEST's own call site — the first
; stack frame outside test_framework.ahk — not at the assert helper where the
; throw physically happened. Without this a red test reads ``[test_framework.ahk:78]``
; for every failure, which locates nothing.
;
; These are real behaviour tests: they call _TestCallSite directly with synthetic
; stack strings and assert the parsed result, rather than scanning source.
; ==============================================================================

#Requires AutoHotkey v2.0

_TRFE_PicksTestFrameNotFramework() {
	Stack := "C:\drv\windows\tests\test_framework.ahk (78) : [Assert] throw Error(Message)`n"
		. "C:\drv\windows\tests\meta\test_foo.ahk (42) : [_Foo] Assert(cond, msg)`n"
		. "C:\drv\windows\tests\run_all.ahk (300) : [RunTests] TestEntry.callback.Call()"
	Got := _TestCallSite(Stack)
	Assert(Got == "test_foo.ahk:42",
		"_TestCallSite must return the first frame outside test_framework.ahk - got <" . Got . ">")
}
Test("runner failure: [file:line] points at the test, not the assert helper", _TRFE_PicksTestFrameNotFramework)

_TRFE_EmptyStackFallsBack() {
	Assert(_TestCallSite("") == "",
		"an empty stack must yield an empty call site so RunTests falls back to the raw throw location")
}
Test("runner failure: empty stack yields empty call site (caller falls back)", _TRFE_EmptyStackFallsBack)

_TRFE_HandlesWindowsPathWithSpaces() {
	Stack := "C:\Program Files\drv\tests\meta\test_bar.ahk (7) : [_Bar] Assert(x)"
	Got := _TestCallSite(Stack)
	Assert(Got == "test_bar.ahk:7",
		"_TestCallSite must handle a Windows path containing spaces - got <" . Got . ">")
}
Test("runner failure: call site parses a path containing spaces", _TRFE_HandlesWindowsPathWithSpaces)

; A terminal stdout receipt cannot compensate for a dropped disk observation.
_TRFE_ResultWrite(Locked) {
	global TEST_RESULTS_FILE
	Saved := TEST_RESULTS_FILE
	Directory := A_Temp . "\ergopti-tap-write-" . DllCall("GetCurrentProcessId", "UInt") . "-" . A_TickCount
	if !DllCall("Kernel32\CreateDirectoryW", "Str", Directory, "Ptr", 0, "Int")
		throw OSError(A_LastError, "Cannot acquire the owned TAP write fixture")
	Receipt := Directory . "\receipt.tap"
	Handle := 0
	try {
		TEST_RESULTS_FILE := Receipt
		if Locked {
			Handle := FileOpen(Receipt, "w-rwd", "UTF-8")
			Thrown := false
			try _TestPrint("# owned locked receipt")
			catch OSError
				Thrown := true
			AssertTrue(Thrown, "a rejected disk write must escape the progress printer")
			Handle.Close()
			Handle := 0
			AssertEqual("", FileRead(Receipt, "UTF-8"), "a denied write must not fabricate disk progress")
		} else {
			Line := "# owned Unicode receipt " . Chr(0xE9) . Chr(0x1F642)
			_TestPrint(Line)
			AssertEqual(Line . Chr(13) . Chr(10), FileRead(Receipt, "UTF-8"), "the actual printer preserves a complete Unicode line")
		}
	} finally {
		TEST_RESULTS_FILE := Saved
		if IsObject(Handle)
			Handle.Close()
		if FileExist(Receipt)
			FileDelete(Receipt)
		DirDelete(Directory)
	}
}
Test("runner receipt write: disk failure escapes (receipt-write)", _TRFE_ResultWrite.Bind(true))
Test("runner receipt write: complete Unicode disk line (receipt-write)", _TRFE_ResultWrite.Bind(false))

; Process-local requests select the receipt without changing legacy CI defaults.
_TRFE_ResultPath(Requested) {
	Name := "ERGOPTI_AHK_RESULTS_FILE"
	Saved := EnvGet(Name)
	try {
		EnvSet(Name, Requested)
		AssertEqual(Requested != "" ? Requested : "owned-default.tap", _TestResultsPath("owned-default.tap"))
	} finally {
		EnvSet(Name, Saved)
	}
}
for _TRFE_Path in ["", "D:\owned receipt\result.tap", "D:\owned-" . Chr(0xE9) . "\" . Chr(0x1F642) . ".tap"]
	Test("runner receipt path: explicit request " . _TRFE_Path . " (receipt-path)", _TRFE_ResultPath.Bind(_TRFE_Path))

_TRFE_E2eResultPath() {
	; Runner ownership is selected by directory; individual source paths may move.
	Source := _DriverDirConcat("tests/e2e")
	AssertTrue(Source != "", "the E2E runner source must be readable")
	Code := _DriverMaskNonCode(&Source)
	Count := 0
	Position := 1
	while RegExMatch(Code, "m)^global TEST_RESULTS_FILE\s*:=\s*_TestResultsPath\(", &Found, Position) {
		Count += 1
		Position := Found.Pos + Found.Len
	}
	AssertEqual(1, Count, "the E2E owner must use the same explicit receipt resolver as the framework")
}
Test("runner E2E receipt path: explicit resolver wiring (receipt-path)", _TRFE_E2eResultPath)

; This callback runs after RunTests has selected its actual printer destination.
_TRFE_LiveResultPath() {
	global TEST_RESULTS_FILE
	Requested := EnvGet("ERGOPTI_AHK_RESULTS_FILE")
	if Requested != ""
		AssertEqual(Requested, TEST_RESULTS_FILE, "live progress must stay at the requested launch receipt")
	AssertTrue(FileExist(TEST_RESULTS_FILE), "the preceding RUNNING observation must already be durable")
}
Test("runner receipt path: actual live printer destination (receipt-path)", _TRFE_LiveResultPath)


; CI keeps a read handle open while every subsequent observation is appended.
; These handles have exactly the workflow's ReadWrite sharing, without Delete.
_TRFE_WithSharedTap(Body) {
	global _TEST_RESULTS_INITIALIZED_PATH
	Saved := _TEST_RESULTS_INITIALIZED_PATH
	Directory := A_Temp . "\ergopti-tap-sharing-" . DllCall("GetCurrentProcessId", "UInt") . "-" . A_TickCount
	if !DllCall("Kernel32\CreateDirectoryW", "Str", Directory, "Ptr", 0, "Int")
		throw OSError(A_LastError, "Cannot acquire the owned shared TAP fixture")
	Owned := _TRFE_AbsoluteTapPath(Directory)
	Receipt := Directory . "\receipt.tap"
	try {
		Body.Call(Receipt)
	} finally {
		_TEST_RESULTS_INITIALIZED_PATH := Saved
		; Refuse teardown if the exclusive leaf was replaced or its spelling escaped.
		Attributes := DllCall("Kernel32\GetFileAttributesW", "Str", Directory, "UInt")
		if _TRFE_AbsoluteTapPath(Directory) != Owned
			|| _TRFE_AbsoluteTapPath(Receipt) != Owned . "\receipt.tap"
			|| Attributes == 0xFFFFFFFF || (Attributes & 0x400)
			throw Error("Owned TAP fixture cleanup refused.")
		if FileExist(Receipt)
			FileDelete(Receipt)
		DirDelete(Directory)
	}
}

_TRFE_AbsoluteTapPath(Path) {
	Needed := DllCall("Kernel32\GetFullPathNameW", "Str", Path, "UInt", 0, "Ptr", 0, "Ptr", 0, "UInt")
	if !Needed
		throw OSError(A_LastError, "Cannot resolve the owned TAP fixture")
	Resolved := Buffer(Needed * 2, 0)
	Length := DllCall("Kernel32\GetFullPathNameW", "Str", Path, "UInt", Needed, "Ptr", Resolved, "Ptr", 0, "UInt")
	if !Length || Length >= Needed
		throw Error("Owned TAP fixture path changed during resolution.")
	return StrGet(Resolved, "UTF-16")
}

_TRFE_OpenTapReader(Receipt, Sharing) {
	Handle := DllCall("Kernel32\CreateFileW", "Str", Receipt, "UInt", 0x80000000,
		"UInt", Sharing, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
	if Handle == -1
		throw OSError(A_LastError, "Cannot retain the owned TAP reader")
	return Handle
}

_TRFE_ReadTapHandle(Handle) {
	Size := 0
	if !DllCall("Kernel32\GetFileSizeEx", "Ptr", Handle, "Int64*", &Size, "Int")
		throw OSError(A_LastError, "Cannot inspect the held TAP reader")
	Bytes := Buffer(Size + 1, 0)
	Read := 0
	if !DllCall("Kernel32\ReadFile", "Ptr", Handle, "Ptr", Bytes,
		"UInt", Size, "UInt*", &Read, "Ptr", 0, "Int")
		throw OSError(A_LastError, "Cannot read the held TAP receipt")
	return Map("bytes", Bytes, "read", Read, "size", Size)
}

_TRFE_SharedTapAppend(Receipt) {
	_TestResultsInitialize(Receipt)
	_TestResultsWrite(Receipt, "# bootstrap`r`n")
	Handle := _TRFE_OpenTapReader(Receipt, 3)
	try {
		First := _TRFE_ReadTapHandle(Handle)
		AssertEqual(3, NumGet(First["bytes"], 0, "UChar") == 239
			? (NumGet(First["bytes"], 1, "UChar") == 187
				&& NumGet(First["bytes"], 2, "UChar") == 191 ? 3 : 0) : 0,
			"the initial receipt keeps exactly one UTF-8 BOM")
		AssertEqual(First["size"], First["read"])
		; Selecting the same path at RunTests must keep the consumed cursor valid.
		_TestResultsInitialize(Receipt)
		Line := "ok 1 - owned " . Chr(0xE9) . Chr(0x1F642) . "`r`n"
		_TestResultsWrite(Receipt, "1..1`r`n")
		_TestResultsWrite(Receipt, Line)
		_TestResultsWrite(Receipt, "# Passed: 1 Failed: 0`r`n")
		Next := _TRFE_ReadTapHandle(Handle)
		Expected := "1..1`r`n" . Line . "# Passed: 1 Failed: 0`r`n"
		AssertEqual(StrPut(Expected, "UTF-8") - 1, Next["read"], "the same held cursor receives every new observation")
		AssertEqual(Expected, StrGet(Next["bytes"], Next["read"], "UTF-8"))
		AssertEqual("# bootstrap`r`n" . Expected, FileRead(Receipt, "UTF-8"))
	} finally {
		DllCall("Kernel32\CloseHandle", "Ptr", Handle)
	}
}
Test("runner receipt sharing: retained CI reader receives complete Unicode progress (receipt-sharing)",
	_TRFE_WithSharedTap.Bind(_TRFE_SharedTapAppend))

_TRFE_SharedTapReset(Receipt) {
	_TestResultsWrite(Receipt, "obsolete`r`n")
	Handle := _TRFE_OpenTapReader(Receipt, 3)
	try {
		_TestResultsWrite(Receipt, "", true)
		_TestResultsWrite(Receipt, "1..0`r`n")
		Result := _TRFE_ReadTapHandle(Handle)
		AssertEqual(3 + StrPut("1..0`r`n", "UTF-8") - 1, Result["read"], "reset preserves the held file object")
		AssertEqual(239, NumGet(Result["bytes"], 0, "UChar"))
		AssertEqual(187, NumGet(Result["bytes"], 1, "UChar"))
		AssertEqual(191, NumGet(Result["bytes"], 2, "UChar"))
		AssertEqual("1..0`r`n", StrGet(Result["bytes"].Ptr + 3, Result["read"] - 3, "UTF-8"))
		AssertEqual("1..0`r`n", FileRead(Receipt, "UTF-8"))
	} finally {
		DllCall("Kernel32\CloseHandle", "Ptr", Handle)
	}
}
Test("runner receipt sharing: reset preserves a retained file identity (receipt-sharing)",
	_TRFE_WithSharedTap.Bind(_TRFE_SharedTapReset))

_TRFE_ExclusiveTapRefusal(Reset, Receipt) {
	_TestResultsWrite(Receipt, "preserved`r`n")
	Handle := _TRFE_OpenTapReader(Receipt, 0)
	Thrown := false
	try {
		try _TestResultsWrite(Receipt, "forbidden`r`n", Reset)
		catch OSError as Failure {
			Thrown := true
			AssertEqual(32, Failure.Number, "an exclusive reader must retain the native refusal")
		}
		AssertTrue(Thrown, "a denied open cannot publish success")
	} finally {
		DllCall("Kernel32\CloseHandle", "Ptr", Handle)
	}
	AssertEqual("preserved`r`n", FileRead(Receipt, "UTF-8"), "open refusal must preserve the old bytes")
}
Test("runner receipt sharing: exclusive reader refuses append (receipt-sharing)",
	_TRFE_WithSharedTap.Bind(_TRFE_ExclusiveTapRefusal.Bind(false)))
Test("runner receipt sharing: exclusive reader refuses reset (receipt-sharing)",
	_TRFE_WithSharedTap.Bind(_TRFE_ExclusiveTapRefusal.Bind(true)))

class _TRFE_ShortTapFile {
	Handle := 0
	Length := 0
	Closed := 0
	Calls := 0
	RawWrite(Bytes, Count) {
		this.Calls += 1
		return Count - 1
	}
	Close() {
		this.Closed += 1
	}
}

_TRFE_OpenShortTap(Opened, Path, Mode, Encoding) {
	Opened.Path := Path
	Opened.Mode := Mode
	Opened.Encoding := Encoding
	return Opened
}

_TRFE_ShortTapWrite(Opened, Bytes, Count) {
	return Opened.RawWrite(Bytes, Count)
}

_TRFE_ShortTapRefusal(Reset) {
	Opened := _TRFE_ShortTapFile()
	Thrown := false
	try _TestResultsWrite("owned synthetic port", "# incomplete`r`n", Reset,
		_TRFE_OpenShortTap.Bind(Opened), _TRFE_ShortTapWrite)
	catch Error as Failure {
		AssertEqual("Error", Type(Failure), "a write refusal must come from the actual completion guard")
		AssertContains(Failure.Message, "TAP receipt write was incomplete")
		Thrown := true
	}
	AssertTrue(Thrown)
	AssertEqual(1, Opened.Calls, "a short write is never retried as success")
	AssertEqual(1, Opened.Closed, "the acquired writer is released on refusal")
	AssertEqual(Reset ? "w" : "a", Opened.Mode)
	AssertEqual("UTF-8-RAW", Opened.Encoding)
}
Test("runner receipt sharing: incomplete append is refused and closed (receipt-sharing)", _TRFE_ShortTapRefusal.Bind(false))
Test("runner receipt sharing: incomplete reset is refused and closed (receipt-sharing)", _TRFE_ShortTapRefusal.Bind(true))

; Read by semantic owner through canonical masking; prose cannot supply wiring.
_TRFE_SharedReceiptWiring() {
	Source := _DriverDirConcat("tests")
	AssertTrue(Source != "", "registered test owners must be readable")
	Code := _DriverMaskNonCode(&Source)
	for Name in ["_TestPrint", "_LogBootProgress"] {
		Body := _DriverExtractFunctionBody(&Code, Name, 1, true)
		AssertTrue(Body != "", "the actual receipt owner must be nonempty")
		Calls := RegExReplace(Body, "(?i)\b_TestResultsWrite\s*\(\s*TEST_RESULTS_FILE\s*,", "", &Count)
		AssertEqual(1, Count, "each actual writer delegates once to shared strict publication")
	}
	Body := _DriverExtractFunctionBody(&Code, "RunTests", 1, true)
	AssertTrue(Body != "", "the actual runner must be readable")
	RegExReplace(Body, "(?i)\b_TestResultsBeginRun\s*\(\s*\)", "", &Count)
	AssertEqual(1, Count, "RunTests initializes the selected destination without resetting bootstrap progress")
	AssertFalse(RegExMatch(Body, "(?i)\bFileDelete\s*\(\s*TEST_RESULTS_FILE"), "RunTests cannot retire a live reader's destination")
	; The shared selector runs at real entries, never while importing assertions.
	Body := _DriverExtractFunctionBody(&Code, "_TestResultsBeginRun", 1, true)
	AssertTrue(Body != "", "the actual entry selection owner must be nonempty")
	RegExReplace(Body, "(?i)\b_TestResultsInitializeOrExit\s*\(\s*TEST_RESULTS_FILE\s*\)", "", &Count)
	AssertEqual(1, Count, "entry selection must enter the headless refusal boundary exactly once")
	RegExReplace(Code, "(?m)^_TestResultsInitializeOrExit\s*\(\s*TEST_RESULTS_FILE\s*\)", "", &Count)
	AssertEqual(0, Count, "a library include cannot initialize the parent's requested receipt")
	RegExReplace(Code, "(?m)^_TestResultsBeginRun\(\)\s*$", "", &Count)
	AssertEqual(2, Count, "the unit and E2E entry points initialize before their bootstrap graph")
	RegExReplace(Code, "(?im)^global\s+TEST_RESULTS_FILE\s*:=\s*_TestResultsPath\s*\(\s*A_ScriptDir[^\r\n]*\r?\n\s*_TestResultsBeginRun\s*\(\s*\)", "", &Count)
	AssertEqual(1, Count, "the E2E default selection must enter the shared refusal boundary")
	Body := _DriverExtractFunctionBody(&Code, "_TestResultsInitializeOrExit", 1, true)
	AssertTrue(Body != "", "entry-point refusal handling must be readable")
	AssertTrue(RegExMatch(Body, "(?i)\bfinally\s*\{[\s\S]*\bExitApp\s*\(\s*1\s*\)"),
		"a failed error publication still executes process failure")
	AssertTrue(RegExMatch(Body, "(?i)\breturn\s+false\b"), "a recording exit cannot turn refusal into success")
}
Test("runner receipt sharing: actual writer and runner use the shared owners (receipt-sharing)", _TRFE_SharedReceiptWiring)

; An invalid native handle exercises the actual BOOL/error branch without I/O.
_TRFE_NativeTapWriteRefusal(Reset) {
	Opened := _TRFE_ShortTapFile()
	Thrown := false
	try _TestResultsWrite("owned invalid native handle", "# refused native write", Reset,
		_TRFE_OpenShortTap.Bind(Opened))
	catch OSError as Failure {
		Thrown := true
		AssertEqual(6, Failure.Number, "the actual native write keeps ERROR_INVALID_HANDLE")
	}
	AssertTrue(Thrown)
	AssertEqual(0, Opened.Calls, "a refused native write never falls back to a buffered writer")
	AssertEqual(1, Opened.Closed, "native refusal releases the acquired file port exactly once")
}
Test("runner receipt sharing: native append refusal escapes and closes (receipt-sharing)", _TRFE_NativeTapWriteRefusal.Bind(false))
Test("runner receipt sharing: native reset refusal escapes and closes (receipt-sharing)", _TRFE_NativeTapWriteRefusal.Bind(true))

; Empty input must be refused even before any destination has been initialized.
_TRFE_InvalidTapInitialization() {
	global _TEST_RESULTS_INITIALIZED_PATH
	Saved := _TEST_RESULTS_INITIALIZED_PATH
	Opened := _TRFE_ShortTapFile()
	Thrown := false
	try {
		_TEST_RESULTS_INITIALIZED_PATH := ""
		try _TestResultsInitialize("", _TRFE_OpenShortTap.Bind(Opened))
		catch TypeError as Failure {
			Thrown := true
			AssertContains(Failure.Message, "Invalid TAP receipt destination")
		}
		AssertTrue(Thrown, "an empty first destination cannot be accepted as already initialized")
		AssertFalse(HasProp(Opened, "Mode"), "invalid input cannot acquire a writer")
		AssertEqual(0, Opened.Closed)
	} finally {
		_TEST_RESULTS_INITIALIZED_PATH := Saved
	}
}
Test("runner receipt sharing: empty first initialization is refused (receipt-sharing)", _TRFE_InvalidTapInitialization)

; Recording exit ports preserve the parent runner while exercising real refusals.
class _TRFE_InitializationExitPort {
	Messages := []
	ExitCodes := []
	ThrowOutput := false
	ErrorOutput(Message) {
		this.Messages.Push(Message)
		if this.ThrowOutput
			throw Error("Owned TAP stderr port refusal.")
	}
	Exit(Code) {
		this.ExitCodes.Push(Code)
	}
}

_TRFE_AssertInitializationRefusal(Port, ExpectedType, ExpectedNumber) {
	AssertEqual(1, Port.Messages.Length, "one typed diagnostic reports the initialization refusal")
	AssertContains(Port.Messages[1], ExpectedType . "|" . ExpectedNumber . ":")
	AssertEqual(1, Port.ExitCodes.Length, "a refusal cannot return without requesting process failure")
	AssertEqual(1, Port.ExitCodes[1])
}

_TRFE_ExclusiveInitializationExit(Receipt) {
	_TestResultsWrite(Receipt, "preserved startup`r`n")
	Handle := _TRFE_OpenTapReader(Receipt, 0)
	Port := _TRFE_InitializationExitPort()
	try {
		AssertFalse(_TestResultsInitializeOrExit(Receipt,
			Port.ErrorOutput.Bind(Port), Port.Exit.Bind(Port)), "refused initialization cannot report success")
		_TRFE_AssertInitializationRefusal(Port, "OSError", 32)
	} finally {
		DllCall("Kernel32\CloseHandle", "Ptr", Handle)
	}
	AssertEqual("preserved startup`r`n", FileRead(Receipt, "UTF-8"))
}
Test("runner receipt sharing: exclusive initialization requests headless exit (receipt-sharing)",
	_TRFE_WithSharedTap.Bind(_TRFE_ExclusiveInitializationExit))

_TRFE_MissingParentInitializationExit(Receipt) {
	Port := _TRFE_InitializationExitPort()
	AssertFalse(_TestResultsInitializeOrExit(Receipt . ".missing\receipt.tap",
		Port.ErrorOutput.Bind(Port), Port.Exit.Bind(Port)), "a missing destination parent cannot report success")
	_TRFE_AssertInitializationRefusal(Port, "OSError", 3)
	AssertFalse(FileExist(Receipt . ".missing"), "a refused initialization never invents a parent directory")
}
Test("runner receipt sharing: missing parent initialization requests headless exit (receipt-sharing)",
	_TRFE_WithSharedTap.Bind(_TRFE_MissingParentInitializationExit))

_TRFE_InvalidInitializationExit() {
	for Path in ["", 123] {
		Port := _TRFE_InitializationExitPort()
		AssertFalse(_TestResultsInitializeOrExit(Path,
			Port.ErrorOutput.Bind(Port), Port.Exit.Bind(Port)), "invalid initialization cannot return success")
		_TRFE_AssertInitializationRefusal(Port, "TypeError", 0)
	}
}
Test("runner receipt sharing: invalid initialization requests headless exit (receipt-sharing)", _TRFE_InvalidInitializationExit)

_TRFE_FailedInitializationDiagnosticExit() {
	Port := _TRFE_InitializationExitPort()
	Port.ThrowOutput := true
	Thrown := false
	try _TestResultsInitializeOrExit("", Port.ErrorOutput.Bind(Port), Port.Exit.Bind(Port))
	catch Error as Failure {
		Thrown := true
		AssertEqual("Error", Type(Failure))
		AssertEqual("Owned TAP stderr port refusal.", Failure.Message)
	}
	AssertTrue(Thrown, "a secondary publication refusal remains observable")
	_TRFE_AssertInitializationRefusal(Port, "TypeError", 0)
}
Test("runner receipt sharing: failed stderr still requests headless exit (receipt-sharing)", _TRFE_FailedInitializationDiagnosticExit)

; Entry selection must not discard observations already consumed by a CI reader.
_TRFE_BeginRunPreservesBootstrap(Receipt) {
	global TEST_RESULTS_FILE, TEST_RESULTS_CANONICAL
	SavedFile := TEST_RESULTS_FILE
	SavedCanonical := TEST_RESULTS_CANONICAL
	try {
		; A distinct default models E2E's sibling receipt without changing the parent environment.
		TEST_RESULTS_FILE := Receipt
		TEST_RESULTS_CANONICAL := Receipt . ".canonical"
		AssertTrue(_TestResultsBeginRun())
		_TestResultsWrite(Receipt, "# bootstrap before RunTests`r`n")
		AssertTrue(_TestResultsBeginRun())
		AssertEqual(Receipt, TEST_RESULTS_FILE, "the selected entry destination stays unchanged")
		AssertEqual("# bootstrap before RunTests`r`n", FileRead(Receipt, "UTF-8"),
			"RunTests initialization cannot truncate an entry's already-published bootstrap")
	} finally {
		TEST_RESULTS_FILE := SavedFile
		TEST_RESULTS_CANONICAL := SavedCanonical
	}
}
Test("runner receipt sharing: entry initialization retains bootstrap (receipt-sharing)",
	_TRFE_WithSharedTap.Bind(_TRFE_BeginRunPreservesBootstrap))

; A helper-only child imports the actual framework with a private requested path.
; Its environment is set in the child source, never in the active parent process.
_TRFE_LibraryIncludeIsolation() {
	global _StaticDir
	Framework := _StaticDir . "\ergopti_plus\windows\tests\test_framework.ahk"
	Directory := A_Temp . "\ergopti-tap-include-" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . "-" . A_TickCount
	if !DllCall("Kernel32\CreateDirectoryW", "Str", Directory, "Ptr", 0, "Int")
		throw OSError(A_LastError, "Cannot acquire the owned framework include fixture")
	Owned := _TRFE_AbsoluteTapPath(Directory)
	Requested := Directory . "\requested.tap"
	Legacy := Directory . "\test_results.txt"
	Child := Directory . "\include.ahk"
	FrameworkCopy := Directory . "\framework.ahk"
	Handle := 0
	CanRetire := true
	Observation := {Calls: 0, Code: -1, Output: "", Errors: ""}
	Completed(Code, Output, Errors) {
		Observation.Calls += 1
		Observation.Code := Code
		Observation.Output := Output
		Observation.Errors := Errors
	}
	try {
		FileAppend("preserved requested receipt", Requested, "UTF-8")
		FileAppend("preserved legacy receipt", Legacy, "UTF-8")
		; Copy the real complete library; this is execution rather than a source-shape surrogate.
		FileCopy(Framework, FrameworkCopy)
		Quoted := StrReplace(StrReplace(Requested, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34))
		Source := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n"
			. 'EnvSet("ERGOPTI_AHK_RESULTS_FILE", "' . Quoted . '")' . "`n"
			. "OnError(_TRFE_IncludeFatal)`n#Include framework.ahk`n"
			. 'FileAppend("owned-framework-include-only", "*", "UTF-8-RAW")' . "`nExitApp(0)`n"
			. '_TRFE_IncludeFatal(Problem, *) {' . "`n"
			. 'try FileAppend("owned-framework-include-error|" . Type(Problem), "**", "UTF-8-RAW")' . "`n"
			. "finally ExitApp(2)`n}`n"
		FileAppend(Source, Child, "UTF-8")
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut", Child], Completed)
		AssertTrue(Handle.start(), "the owned include-only child must start")
		Started := DllCall("Kernel32\GetTickCount64", "UInt64")
		while !Observation.Calls && DllCall("Kernel32\GetTickCount64", "UInt64") - Started < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observation.Calls, "the helper-only child completes exactly once")
		AssertEqual(0, Observation.Code, "the actual included framework parses and returns: "
			. Observation.Output . Observation.Errors)
		AssertEqual("", Observation.Errors, "including helpers cannot hide a native error")
		AssertEqual("owned-framework-include-only", Observation.Output,
			"including the actual library emits no warnings or runner transcript")
		AssertEqual("preserved requested receipt", FileRead(Requested, "UTF-8"),
			"the include-only child cannot reset its inherited requested receipt")
		AssertEqual("preserved legacy receipt", FileRead(Legacy, "UTF-8"),
			"the include-only child cannot delete its legacy sibling receipt")
	} finally {
		if IsObject(Handle) {
			CanRetire := Handle.terminate()
			AssertTrue(CanRetire, "the exact include-only child must retire before its fixture")
		}
		if CanRetire {
			Attributes := DllCall("Kernel32\GetFileAttributesW", "Str", Directory, "UInt")
			if _TRFE_AbsoluteTapPath(Directory) != Owned || Attributes == 0xFFFFFFFF || (Attributes & 0x400)
				throw Error("Owned framework include fixture cleanup refused.")
			for Leaf in [Requested, Legacy, Child, FrameworkCopy] {
				if _TRFE_AbsoluteTapPath(Leaf) != Owned . "\" . SubStr(Leaf, StrLen(Directory) + 2)
					throw Error("Owned framework include leaf cleanup refused.")
				if FileExist(Leaf)
					FileDelete(Leaf)
			}
			DirDelete(Directory)
		}
	}
}
Test("runner receipt sharing: helper-only child preserves receipts and clean stdout (receipt-sharing)",
	_TRFE_LibraryIncludeIsolation)
