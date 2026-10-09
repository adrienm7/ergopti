; tests/unit/test_llm_curl_literal_paths.ahk

; ==============================================================================
; MODULE: Curl Literal Path Tests
; DESCRIPTION:
; Runs the production command builder against file-only curl transfers. Shell
; expansion must not redirect owned response and terminal artifacts elsewhere.
; ==============================================================================

#Requires AutoHotkey v2.0

_CLP_RunOwnedCommand(Command) {
	Owner := _LLM_CurlRunOwned(_LLM_CurlArtifactRun, Command, "", "Hide", &Pid)
	try {
		AssertEqual(0, DllCall("Kernel32\WaitForSingleObject", "Ptr", Owner["handle"], "UInt", 5000, "UInt"),
			"the bounded file-only curl process must finish")
		ExitCode := 0
		AssertTrue(DllCall("Kernel32\GetExitCodeProcess", "Ptr", Owner["handle"], "UInt*", &ExitCode),
			"the exact owned process must expose its terminal code")
		return ExitCode
	} finally _LLM_CurlReleaseProcess(Owner, true)
}

_CLP_QuotedPathsRemainLiteral(Names := unset) {
	if !IsSet(Names)
		Names := ["plain", "literal ^^", "literal & (group) }"]
	Root := A_Temp . "\ergopti_curl_literal_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount
	AssertFalse(DirExist(Root), "the fixture must own a new private directory")
	DirCreate(Root)
	try {
		InputPath := Root . "\input.txt"
		FileAppend("owned-file-fixture", InputPath, "UTF-8-RAW")
		InputUrl := "file:///" . StrReplace(StrReplace(InputPath, "\", "/"), " ", "%20")
		for Name in Names {
			Directory := Root . "\" . Name
			DirCreate(Directory)
			for Missing in [false, true] {
				Stem := Directory . (Missing ? "\missing" : "\success")
				OutputPath := Stem . ".out"
				StatusPath := Stem . ".status"
				ExitPath := Stem . ".exit"
				CurlCommand := _Q(A_WinDir . "\System32\curl.exe")
					. " --silent --globoff --max-time 2 --proto =file --output " . _Q(OutputPath)
					. " " . _Q(InputUrl . (Missing ? ".absent" : ""))
				ExitCode := _CLP_RunOwnedCommand(_LLM_CurlOwnedCommand(CurlCommand, StatusPath, ExitPath))
				AssertEqual(Missing ? 37 : 0, ExitCode, "the wrapper must preserve the curl exit status: " . Name)
				AssertTrue(FileExist(StatusPath), "the HTTP-status artifact must use the exact literal path: " . Name)
				AssertTrue(FileExist(ExitPath), "the exit artifact must use the exact literal path: " . Name)
				AssertEqual("000", Trim(FileRead(StatusPath)), "file-only transfers must not pretend to be HTTP responses")
				AssertEqual(String(ExitCode), Trim(FileRead(ExitPath), " `t`r`n"), "the terminal receipt must preserve success and failure")
				if !Missing
					AssertEqual("owned-file-fixture", FileRead(OutputPath), "the body must reach its exact owned path")
			}
		}
	} finally DirDelete(Root, true)
}
Test("curl command: quoted paths preserve literal shell characters (curl-literal-paths)",
	_CLP_QuotedPathsRemainLiteral)
Test("curl command: exclamation paths stay literal (curl-literal-paths)",
	_CLP_QuotedPathsRemainLiteral.Bind(["literal !CD!", "literal ^!CD!"]))
Test("curl command: percent paths stay literal (curl-literal-paths)",
	_CLP_QuotedPathsRemainLiteral.Bind(["literal %CD%"]))
Test("curl command: mixed Unicode and shell characters stay literal (curl-literal-paths)",
	_CLP_QuotedPathsRemainLiteral.Bind(["mixed %CD% !CD! ^ & (group) } é"]))

_CLP_ChildEnvironmentIsIsolated() {
	Sentinels := Map("ERRORLEVEL", "999", "_ergopti_curl_command", "must-not-run",
		"_ergopti_curl_status", "must-not-write", "_ergopti_curl_exit", "must-not-write")
	Saved := Map()
	for Name in Sentinels
		Saved[Name] := EnvGet(Name)
	try {
		for Name, Value in Sentinels
			EnvSet(Name, Value)
		_CLP_QuotedPathsRemainLiteral(["plain"])
		for Name, Value in Sentinels
			AssertEqual(Value, EnvGet(Name), "child overrides must not mutate the parent environment")
	} finally {
		for Name, Value in Saved
			EnvSet(Name, Value)
	}
}
Test("curl command: inherited variable collisions cannot change results (curl-literal-paths)",
	_CLP_ChildEnvironmentIsIsolated)

_CLP_InvalidLaunchRecordsCannotAcquireOwnership() {
	SafeCommand := _Q(A_ComSpec) . ' /D /C "exit /b 0"'
	for Candidate in [0, "", Map(), Map("command_line", 0, "environment", Map()),
		Map("command_line", SafeCommand, "environment", []),
		Map("command_line", SafeCommand, "environment", Map("bad=name", "value")),
		Map("command_line", SafeCommand, "environment", Map("value", []))] {
		Pid := 0
		Owner := 0
		Rejected := false
		try {
			try _LLM_CurlArtifactRun(Candidate, "", "Hide", &Pid, &Owner)
			catch TypeError
				Rejected := true
			AssertTrue(Rejected, "malformed launch input must fail before native process creation")
			AssertEqual(0, Pid, "rejection must not publish a process identity")
			AssertEqual(0, Owner, "rejection must not publish an ownership receipt")
		} finally {
			if Owner is Map
				_LLM_CurlReleaseProcess(Owner, true)
		}
	}
}
Test("curl command: malformed launch records fail before process creation (curl-literal-paths)",
	_CLP_InvalidLaunchRecordsCannotAcquireOwnership)
