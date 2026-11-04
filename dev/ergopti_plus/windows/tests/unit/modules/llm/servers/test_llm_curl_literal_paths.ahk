; tests/unit/modules/llm/servers/test_llm_curl_literal_paths.ahk

; ==============================================================================
; MODULE: Curl Literal Path Tests
; DESCRIPTION:
; Runs the production command builder against private files and a silent
; loopback peer. Shell expansion and cancellation retain exact owned artifacts.
; ==============================================================================

#Requires AutoHotkey v2.0

; The first cmd.exe and curl.exe of a shard can take seconds to start on a
; loaded hosted runner: one wait expired at 5.5 s in run 39713353269 where
; the whole test usually takes 0.7 s. Every wait ends as soon as its
; condition holds, so the generous bound costs nothing on success.
global _CLP_CHILD_WAIT_MS := 30000

_CLP_RunOwnedCommand(Command) {
	global _CLP_CHILD_WAIT_MS
	Owner := _LLM_CurlRunOwned(_LLM_CurlArtifactRun, Command, "", "Hide", &Pid)
	try {
		Started := DllCall("Kernel32\GetTickCount64", "UInt64")
		while !_LLM_CurlProcessExited(Owner) && DllCall("Kernel32\GetTickCount64", "UInt64") - Started < _CLP_CHILD_WAIT_MS
			Sleep(10)
		AssertTrue(_LLM_CurlProcessExited(Owner), "the bounded file-only curl Job must finish")
		AssertTrue(Owner.Get("terminal", 0) is Map, "the exact native completion must carry its exit code")
		return Owner["terminal"]["exit"]
	} finally _CLP_RetireOwner(Owner)
}

_CLP_RetireOwner(Owner) {
	global _CLP_CHILD_WAIT_MS
	if !(Owner is Map)
		return
	Started := DllCall("Kernel32\GetTickCount64", "UInt64")
	Retired := _LLM_CurlReleaseProcess(Owner, true)
	while !Retired && DllCall("Kernel32\GetTickCount64", "UInt64") - Started < _CLP_CHILD_WAIT_MS {
		Sleep(10)
		Retired := _LLM_CurlReleaseProcess(Owner, true)
	}
	AssertTrue(Retired, "the fixture must receive native owner retirement before deleting artifacts")
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

/** Retains the real curl child while its deliberate cmd terminal writer is live. */
_CLP_OpenCurlChild(WrapperPid) {
	Snapshot := DllCall("Kernel32\CreateToolhelp32Snapshot", "UInt", 2, "UInt", 0, "Ptr")
	if Snapshot == -1 || !Snapshot
		throw OSError(A_LastError)
	try {
		Entry := Buffer(A_PtrSize == 8 ? 568 : 556, 0)
		NumPut("UInt", Entry.Size, Entry)
		Next := DllCall("Kernel32\Process32FirstW", "Ptr", Snapshot, "Ptr", Entry, "Int")
		while Next {
			Parent := NumGet(Entry, A_PtrSize == 8 ? 32 : 24, "UInt")
			Image := StrGet(Entry.Ptr + (A_PtrSize == 8 ? 44 : 36), 260, "UTF-16")
			if Parent == WrapperPid && StrCompare(Image, "curl.exe", false) == 0 {
				Pid := NumGet(Entry, 8, "UInt")
				Handle := DllCall("Kernel32\OpenProcess", "UInt", 0x00101001, "Int", false, "UInt", Pid, "Ptr")
				if Handle {
					try {
						Name := Buffer(32768 * 2, 0), Length := 32768
						if DllCall("Kernel32\QueryFullProcessImageNameW", "Ptr", Handle, "UInt", 0,
							"Ptr", Name, "UInt*", &Length, "Int")
								&& StrCompare(StrGet(Name, Length, "UTF-16"), A_WinDir . "\System32\curl.exe", false) == 0
							return Handle
					} catch as Err {
						DllCall("Kernel32\CloseHandle", "Ptr", Handle)
						throw Err
					}
					DllCall("Kernel32\CloseHandle", "Ptr", Handle)
				}
			}
			Next := DllCall("Kernel32\Process32NextW", "Ptr", Snapshot, "Ptr", Entry, "Int")
		}
		return 0
	} finally DllCall("Kernel32\CloseHandle", "Ptr", Snapshot)
}

/** Closes only a fixture-retained exact child object, including a failed assertion. */
_CLP_DrainChild(Handle) {
	if !Handle
		return
	try {
		if DllCall("Kernel32\WaitForSingleObject", "Ptr", Handle, "UInt", 0, "UInt") != 0 {
			AssertTrue(DllCall("Kernel32\TerminateProcess", "Ptr", Handle, "UInt", 1, "Int"),
				"the private fixture child must accept exact-object rescue")
			AssertEqual(0, DllCall("Kernel32\WaitForSingleObject", "Ptr", Handle, "UInt", 5000, "UInt"),
				"the exact rescued fixture child must drain before its files retire")
		}
	} finally DllCall("Kernel32\CloseHandle", "Ptr", Handle)
}

_CLP_DuplicateNativeHandle(Handle) {
	Duplicate := 0
	AssertTrue(DllCall("Kernel32\DuplicateHandle", "Ptr", -1, "Ptr", Handle, "Ptr", -1,
		"Ptr*", &Duplicate, "UInt", 0, "Int", false, "UInt", 2, "Int"), "the fixture must retain its exact native witness")
	return Duplicate
}

_CLP_RecordJob(Witness, State, Native) {
	AssertEqual(0, Witness["job"], "one native creation owns one exact Job")
	Witness["job"] := _CLP_DuplicateNativeHandle(Native["JobHandle"])
	Witness["root"] := _CLP_DuplicateNativeHandle(Native["ProcessHandle"])
}

_CLP_JobFactory(Witness, Application, Command, Environment, Directory, Done, Chunk?, BeforeAdopt?,
		MaxBytes := 0, Capture := true, Private := false) {
	AssertFalse(IsSet(BeforeAdopt), "the production curl owner does not inject a native adoption seam")
	return ShellRunner_SpawnTreeOwnedCommand(Application, Command, Environment, Directory, Done, Chunk?,
		_CLP_RecordJob.Bind(Witness), MaxBytes, Capture, Private)
}

_CLP_RunWithJobWitness(Witness, Command, Directory, Options, &Pid, &Owner) {
	return _LLM_CurlArtifactRun(Command, Directory, Options, &Pid, &Owner, _CLP_JobFactory.Bind(Witness))
}

_CLP_JobProcessCount(Job) {
	Info := Buffer(48, 0)
	AssertTrue(DllCall("Kernel32\QueryInformationJobObject", "Ptr", Job, "Int", 1,
		"Ptr", Info, "UInt", Info.Size, "Ptr", 0, "Int"), "the independent native Job accounting query must succeed")
	return NumGet(Info, 40, "UInt")
}

_CLP_JobProcessIds(Job) {
	Info := Buffer(8 + 64 * A_PtrSize, 0)
	AssertTrue(DllCall("Kernel32\QueryInformationJobObject", "Ptr", Job, "Int", 3,
		"Ptr", Info, "UInt", Info.Size, "Ptr", 0, "Int"), "the complete bounded native Job PID census must succeed")
	Assigned := NumGet(Info, 0, "UInt"), Count := NumGet(Info, 4, "UInt")
	AssertTrue(Count <= 64)
	AssertEqual(Assigned, Count, "the native census must include every assigned process")
	Ids := Map()
	loop Count {
		Pid := NumGet(Info, 8 + (A_Index - 1) * A_PtrSize, "UPtr")
		AssertTrue(Pid > 0 && !Ids.Has(Pid), "the complete Job census contains distinct positive identities")
		Ids[Pid] := true
	}
	return Ids
}

_CLP_RecordJobImages(Job, Ids) {
	for Pid in Ids {
		Handle := DllCall("Kernel32\OpenProcess", "UInt", 0x1000, "Int", false, "UInt", Pid, "Ptr")
		if !Handle {
			_TestAppendProgress("# curl-owned-job pid=" . Pid . " image_observation_error=" . A_LastError)
			continue
		}
		try {
			Member := -1
			AssertTrue(DllCall("Kernel32\IsProcessInJob", "Ptr", Handle, "Ptr", Job, "Int*", &Member, "Int"))
			Name := Buffer(32768 * 2, 0), Length := 32768
			if DllCall("Kernel32\QueryFullProcessImageNameW", "Ptr", Handle, "UInt", 0,
					"Ptr", Name, "UInt*", &Length, "Int")
				_TestAppendProgress("# curl-owned-job pid=" . Pid . " current_member=" . Member
					. " image=" . JsonStringLiteral(StrGet(Name, Length, "UTF-16")))
			else
				_TestAppendProgress("# curl-owned-job pid=" . Pid . " image_observation_error=" . A_LastError)
		} finally DllCall("Kernel32\CloseHandle", "Ptr", Handle)
	}
}

/** Opens a private loopback peer which accepts HTTP but sends no response. */
_CLP_OpenSilentListener() {
	Data := Buffer(512, 0)
	AssertEqual(0, DllCall("Ws2_32\WSAStartup", "UShort", 0x202, "Ptr", Data, "Int"),
		"the fixture must acquire its own Winsock reference")
	Socket := -1
	try {
		Socket := DllCall("Ws2_32\socket", "Int", 2, "Int", 1, "Int", 6, "Ptr")
		AssertTrue(Socket != -1, "the private listener socket must open")
		Address := Buffer(16, 0)
		NumPut("UShort", 2, Address, 0)
		NumPut("UChar", 127, Address, 4)
		NumPut("UChar", 1, Address, 7)
		AssertEqual(0, DllCall("Ws2_32\bind", "Ptr", Socket, "Ptr", Address, "Int", Address.Size, "Int"))
		Length := Address.Size
		AssertEqual(0, DllCall("Ws2_32\getsockname", "Ptr", Socket, "Ptr", Address, "Int*", &Length, "Int"))
		Port := NumGet(Address, 2, "UChar") * 256 + NumGet(Address, 3, "UChar")
		AssertTrue(Port > 0, "the OS must choose a private ephemeral port")
		AssertEqual(0, DllCall("Ws2_32\listen", "Ptr", Socket, "Int", 1, "Int"))
		NonBlocking := 1
		AssertEqual(0, DllCall("Ws2_32\ioctlsocket", "Ptr", Socket, "UInt", 0x8004667E,
			"UInt*", &NonBlocking, "Int"), "the native test must never block AHK while accepting")
		return Map("socket", Socket, "port", Port)
	} catch as Err {
		if Socket != -1
			DllCall("Ws2_32\closesocket", "Ptr", Socket)
		DllCall("Ws2_32\WSACleanup")
		throw Err
	}
}

_CLP_CancelWrappedTransferRetiresRealCurl(WithJobWitness := false) {
	global _CLP_CHILD_WAIT_MS
	Root := A_Temp . "\ergopti_curl_tree_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount
	AssertFalse(DirExist(Root))
	DirCreate(Root)
	Owner := 0, Child := 0, Peer := -1, Listener := 0
	ControlOwner := 0, ControlWitness := 0, ControlListener := 0
	Witness := Map("job", 0, "root", 0)
	try {
		Listener := _CLP_OpenSilentListener()
		CurlCommand := _Q(A_WinDir . "\System32\curl.exe")
			. " --disable --silent --globoff --noproxy * --max-time 20 --proto =http --output "
			. _Q(Root . "\response.out") . " " . _Q("http://127.0.0.1:" . Listener["port"] . "/fixture")
		Command := _LLM_CurlOwnedCommand(CurlCommand, Root . "\response.status", Root . "\response.exit")
		RunFn := WithJobWitness ? _CLP_RunWithJobWitness.Bind(Witness) : _LLM_CurlArtifactRun
		Owner := _LLM_CurlRunOwned(RunFn, Command, "", "Hide", &Pid)
		Started := DllCall("Kernel32\GetTickCount64", "UInt64")
		while (Peer == -1 || !Child) && DllCall("Kernel32\GetTickCount64", "UInt64") - Started < _CLP_CHILD_WAIT_MS {
			if Peer == -1 {
				Peer := DllCall("Ws2_32\accept", "Ptr", Listener["socket"], "Ptr", 0, "Ptr", 0, "Ptr")
				if Peer == -1
					AssertEqual(10035, DllCall("Ws2_32\WSAGetLastError", "Int"), "only a pending nonblocking accept may retry")
			}
			if !Child
				Child := _CLP_OpenCurlChild(Pid)
			if Peer == -1 || !Child
				Sleep(10)
		}
		AssertTrue(Peer != -1, "the actual curl transfer must connect to the controlled silent peer")
		AssertTrue(Child != 0, "the actual wrapped command must retain a distinct native curl child")
		AssertEqual(0x102, DllCall("Kernel32\WaitForSingleObject", "Ptr", Child, "UInt", 0, "UInt"),
			"the retained curl transfer must still await HTTP before cancellation")
		if WithJobWitness {
			Ids := _CLP_JobProcessIds(Witness["job"])
			RootId := DllCall("Kernel32\GetProcessId", "Ptr", Witness["root"], "UInt")
			CurlId := DllCall("Kernel32\GetProcessId", "Ptr", Child, "UInt")
			AssertEqual(Pid, RootId, "the census observes the exact wrapper retained before resume")
			AssertTrue(CurlId > 0 && CurlId != RootId && Ids.Has(RootId) && Ids.Has(CurlId),
				"the complete Job census must contain the distinct exact wrapper and curl identities")
			for Handle in [Witness["root"], Child] {
				Member := -1
				AssertTrue(DllCall("Kernel32\IsProcessInJob", "Ptr", Handle, "Ptr", Witness["job"], "Int*", &Member, "Int"))
				AssertEqual(1, Member, "both retained exact process objects must belong to the request Job")
			}
			Active := _CLP_JobProcessCount(Witness["job"])
			AssertTrue(Active >= 2, "the Job must account for the blocked wrapper and curl, including any native auxiliary processes")
			_TestAppendProgress("# curl-owned-job active=" . Active . " census=" . Ids.Count)
			_CLP_RecordJobImages(Witness["job"], Ids)
			ControlListener := _CLP_OpenSilentListener()
			ControlCommand := _Q(A_WinDir . "\System32\curl.exe")
				. " --disable --silent --globoff --noproxy * --max-time 20 --proto =http "
				. _Q("http://127.0.0.1:" . ControlListener["port"] . "/unrelated")
			ControlOwner := _LLM_CurlRunOwned(_LLM_CurlArtifactRun, ControlCommand, "", "Hide", &ControlPid)
			ControlWitness := _CLP_DuplicateNativeHandle(ControlOwner["handle"])
			Member := -1
			AssertTrue(DllCall("Kernel32\IsProcessInJob", "Ptr", ControlWitness, "Ptr", Witness["job"], "Int*", &Member, "Int"))
			AssertEqual(0, Member, "an unrelated direct curl process is outside the request Job")
			AssertEqual(0x102, DllCall("Kernel32\WaitForSingleObject", "Ptr", ControlWitness, "UInt", 0, "UInt"))
		}
		AssertEqual(0x102, DllCall("Kernel32\WaitForSingleObject", "Ptr", Child, "UInt", 0, "UInt"),
			"the original exact curl must still be live immediately before cancellation")
		Retired := _LLM_CurlReleaseProcess(Owner, true)
		AssertEqual(0, DllCall("Kernel32\WaitForSingleObject", "Ptr", Child, "UInt", 1000, "UInt"),
			"the termination request must reach the actual retained curl child")
		; Do not keep a process reference while waiting for final Job accounting.
		AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Child, "Int"))
		Child := 0
		if Witness["root"] {
			AssertEqual(0, DllCall("Kernel32\WaitForSingleObject", "Ptr", Witness["root"], "UInt", 1000, "UInt"),
				"the termination request must also retire the exact retained wrapper")
			AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Witness["root"], "Int"))
			Witness["root"] := 0
		}
		Started := DllCall("Kernel32\GetTickCount64", "UInt64")
		while !Retired && DllCall("Kernel32\GetTickCount64", "UInt64") - Started < _CLP_CHILD_WAIT_MS {
			Sleep(10)
			Retired := _LLM_CurlReleaseProcess(Owner, true)
		}
		AssertTrue(Retired, "the production owner must receive exact native retirement")
		if WithJobWitness {
			AssertEqual(0, _CLP_JobProcessCount(Witness["job"]), "retirement must mean the entire exact Job is quiescent")
			AssertEqual(0x102, DllCall("Kernel32\WaitForSingleObject", "Ptr", ControlWitness, "UInt", 0, "UInt"),
				"retiring one request must preserve an unrelated exact curl process")
		}
	} finally {
		if Peer != -1
			DllCall("Ws2_32\closesocket", "Ptr", Peer)
		if Listener is Map {
			DllCall("Ws2_32\closesocket", "Ptr", Listener["socket"])
			DllCall("Ws2_32\WSACleanup")
		}
		if ControlListener is Map {
			DllCall("Ws2_32\closesocket", "Ptr", ControlListener["socket"])
			DllCall("Ws2_32\WSACleanup")
		}
		try _CLP_DrainChild(Child)
		finally {
			try _CLP_DrainChild(ControlWitness)
			finally {
				try {
					try _CLP_DrainChild(Witness["root"])
					finally {
						try _CLP_RetireOwner(Owner)
						finally _CLP_RetireOwner(ControlOwner)
					}
				} finally {
					if Witness["job"]
						DllCall("Kernel32\CloseHandle", "Ptr", Witness["job"])
				}
				DirDelete(Root, true)
			}
		}
	}
}
Test("curl command: cancellation retires the retained curl descendant (curl-wrapped-tree-retirement)",
	_CLP_CancelWrappedTransferRetiresRealCurl)
Test("curl command: retirement proves exact Job quiescence and preserves another curl (curl-wrapped-tree-retirement)",
	_CLP_CancelWrappedTransferRetiresRealCurl.Bind(true))

class _CLP_RetirementTask {
	__New() {
		this.Mode := "refuse"
		this.Calls := 0
	}
	requestTerminate() {
		this.Calls += 1
		if this.Mode == "throw"
			throw Error("Controlled tree retirement observation failure")
		if this.Mode == "text"
			return "1"
		return this.Mode == "accept"
	}
}

_CLP_TreeRetirementRetainsDebt() {
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupRetryTimer
	SavedTimer := _LLM_CurlCleanupRetryTimer
	Task := _CLP_RetirementTask()
	Owner := Map("pid", 0, "handle", 0, "tree", Task, "terminal", 0,
		"released", false, "releasing", false, "cleanup_debt_id", 0)
	PreviousCritical := Critical("On")
	try {
		DebtId := 0
		for Mode in ["refuse", "text", "throw"] {
			Task.Mode := Mode
			AssertFalse(_LLM_CurlReleaseProcess(Owner, true), "an unconfirmed tree must not release its task: " . Mode)
			AssertTrue(Owner["tree"] == Task, "the same exact task remains the cleanup authority")
			AssertFalse(Owner["released"])
			AssertFalse(Owner["releasing"], "a thrown native observation must not wedge subsequent retries")
			if !DebtId
				DebtId := Owner["cleanup_debt_id"]
			AssertTrue(DebtId > 0 && _LLM_CurlCleanupDebt.Has(DebtId), "refusal must retain an explicit retry debt")
			AssertEqual(DebtId, Owner["cleanup_debt_id"], "every refusal reuses the same private debt")
			AssertTrue(_LLM_CurlCleanupDebt[DebtId]["owner"] == Owner)
		}
		Task.Mode := "accept"
		AssertTrue(_LLM_CurlReleaseProcess(Owner, true), "a strict canonical acknowledgement retires the owner")
		AssertEqual(4, Task.Calls, "each observation reaches the original retained task exactly once")
		AssertTrue(Owner["released"])
		AssertEqual(0, Owner["tree"])
		AssertEqual(0, Owner["cleanup_debt_id"])
		AssertFalse(_LLM_CurlCleanupDebt.Has(DebtId), "only the settled exact debt may disappear")
	} finally {
		try {
			Task.Mode := "accept"
			if !Owner["released"]
				_LLM_CurlReleaseProcess(Owner, true)
		} finally {
			CreatedTimer := _LLM_CurlCleanupRetryTimer
			if CreatedTimer != SavedTimer && HasMethod(CreatedTimer, "Call")
				SetTimer(CreatedTimer, 0)
			_LLM_CurlCleanupRetryTimer := SavedTimer
			Critical(PreviousCritical)
		}
	}
}
Test("curl command: false string and thrown tree receipts retain exact retry debt (curl-tree-retirement-debt)",
	_CLP_TreeRetirementRetainsDebt)
