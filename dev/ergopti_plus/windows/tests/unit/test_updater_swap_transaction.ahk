; tests/unit/test_updater_swap_transaction.ahk

; ==============================================================================
; MODULE: Updater Swap Transaction Behavior Tests
; DESCRIPTION:
; Exercises the generated PowerShell swapper through its real named-event and
; inherited exact-parent-HANDLE protocol. The fixtures prove both successful
; replacement and rollback after Current has already moved to .bak.
; ==============================================================================

#Requires AutoHotkey v2.0

global _USTX_TransactionCounter := 0
; Allowance for the fixture's own steps only. A worker phase is bounded by the
; production deadline that governs it, never by this shorter fixture guess.
global USTX_WAIT_TIMEOUT_MS := 10000
global USTX_FIXTURE_SETTLE_MS := 1400
global USTX_PROCESS_TERMINATE := 0x0001
global USTX_DIAGNOSTIC_CHAR_LIMIT := 2048
; The FinalExit negative window: never shorter than the floor, otherwise this
; many times the worker's measured reaction to Commit, within the step allowance.
global USTX_FINAL_EXIT_WINDOW_FLOOR_MS := 150
global USTX_FINAL_EXIT_WINDOW_FACTOR := 4

_USTX_WaitForTreeExit(Job, TimeoutMs := unset) {
	if !Job
		throw ValueError("Updater fixture requires its owned job handle")
	if !IsSet(TimeoutMs)
		TimeoutMs := USTX_WAIT_TIMEOUT_MS
	Started := A_TickCount
	loop {
		Diagnostic := ""
		Active := _SR_TreeActiveProcessCount(Job, &Diagnostic)
		if Active < 0
			throw Error("Updater fixture tree query failed: " . Diagnostic)
		if Active = 0
			return true
		if TickElapsed(Started) >= TimeoutMs
			return false
		Sleep(10)
	}
}

_USTX_CloseFixtureTree(Job, Failure) {
	Problem := 0
	Quiescent := false
	try {
		if !_USTX_WaitForTreeExit(Job)
			throw Error("Updater fixture descendants did not exit before the deadline")
		Quiescent := true
	} catch as Err {
		Problem := Err
		Errors := []
		if DllCall("Kernel32\TerminateJobObject", "Ptr", Job, "UInt", 1, "Int")
			Quiescent := _SR_TreeConfirmJobEmpty(Job, Errors)
		if !Quiescent
			Problem.Message .= " - forced tree cleanup could not be confirmed"
	} finally {
		if !DllCall("Kernel32\CloseHandle", "Ptr", Job, "Int") {
			if !IsObject(Problem)
				Problem := Error("Updater fixture job handle close failed")
			else
				Problem.Message .= " - job handle close failed"
		}
	}
	if IsObject(Problem) {
		if Failure is Error
			Failure.Message .= "`n" . Problem.Message
		else
			throw Problem
	}
	return Quiescent
}

_USTX_ReadDiagnostic(Path) {
	global USTX_DIAGNOSTIC_CHAR_LIMIT
	if !FileExist(Path)
		return "[missing]"
	try {
		Reader := FileOpen(Path, "r", "UTF-8")
		if !IsObject(Reader)
			throw Error("Cannot open fixture diagnostic")
		try Text := Reader.Read(USTX_DIAGNOSTIC_CHAR_LIMIT + 1)
		finally Reader.Close()
		return StrLen(Text) > USTX_DIAGNOSTIC_CHAR_LIMIT
			? SubStr(Text, 1, USTX_DIAGNOSTIC_CHAR_LIMIT) . " [truncated]" : Text
	} catch as Err {
		return "[unreadable: " . SubStr(Err.Message, 1, USTX_DIAGNOSTIC_CHAR_LIMIT) . "]"
	}
}

_USTX_FailureEvidence(TestDir) {
	Evidence := ""
	for Name in ["swap.ps1.log", "old.marker", "new.marker"]
		Evidence .= "`n" . Name . ": " . _USTX_ReadDiagnostic(TestDir . "\" . Name)
	return Evidence
}

_USTX_DeleteFixtureAfterCase(TestDir, Failure) {
	try DirDelete(TestDir, true)
	catch as CleanupErr {
		Message := "Updater fixture directory cleanup failed: " . CleanupErr.Message
		if Failure is Error
			Failure.Message .= "`n" . Message
		else
			throw Error(Message)
		return false
	}
	Assert(!DirExist(TestDir), "successful cleanup must remove the owned fixture directory")
	return true
}

_USTX_DiagnosticsSurviveCleanup(Oversized) {
	global USTX_DIAGNOSTIC_CHAR_LIMIT
	TestDir := _FSWL_Path() . ".diagnostics"
	DirCreate(TestDir)
	try {
		LogText := Oversized
			? StrReplace(Format("{:" . USTX_DIAGNOSTIC_CHAR_LIMIT * 2 . "}", ""), " ", "X")
			: "SWAP_ERROR:synthetic probation failure"
		FileAppend(LogText, TestDir . "\swap.ps1.log", "UTF-8-RAW")
		FileAppend("OLD", TestDir . "\old.marker", "UTF-8-RAW")
		Evidence := _USTX_FailureEvidence(TestDir)
		FileDelete(TestDir . "\swap.ps1.log")
		FileDelete(TestDir . "\old.marker")
		AssertContains(Evidence, "old.marker: OLD")
		AssertContains(Evidence, "new.marker: [missing]")
		if Oversized {
			AssertContains(Evidence, SubStr(LogText, 1, USTX_DIAGNOSTIC_CHAR_LIMIT) . " [truncated]")
			AssertTrue(StrLen(Evidence) < StrLen(LogText), "failure output must remain bounded")
		} else
			AssertContains(Evidence, LogText, "cleanup must not erase the captured worker diagnosis")
	} finally {
		for Name in ["swap.ps1.log", "old.marker"] {
			Path := TestDir . "\" . Name
			if FileExist(Path)
				FileDelete(Path)
		}
		DirDelete(TestDir)
	}
}
for Oversized in [false, true]
	Test("updater fixture: diagnostics survive cleanup oversized=" . Oversized
		. " (updater-fixture-diagnostics)", _USTX_DiagnosticsSurviveCleanup.Bind(Oversized))

_USTX_WaitForEvent(Handle, TimeoutMs := unset) {
	global USTX_WAIT_TIMEOUT_MS
	if !IsSet(TimeoutMs)
		TimeoutMs := USTX_WAIT_TIMEOUT_MS
	StartedTick := A_TickCount
	loop {
		State := _Updater_WaitHandleState(Handle)
		if (State == 1)
			return true
		if (State < 0)
			return false
		; A zero timeout is an immediate observation, not an unconditional failure.
		if TickExpired(StartedTick, TimeoutMs)
			return false
		Sleep(10)
	}
}

_USTX_WaitForProcessExit(Owner, TimeoutMs := unset) {
	global USTX_WAIT_TIMEOUT_MS
	if !IsSet(TimeoutMs)
		TimeoutMs := USTX_WAIT_TIMEOUT_MS
	return _USTX_WaitForEvent(Owner.Get("ProcessHandle", 0), TimeoutMs)
}

; Ready and Ack get exactly the deadlines the updater itself grants the worker.
_USTX_WaitForSwapSignal(Owner, Role) {
	global UPDATER_SWAP_READY_TIMEOUT_MS, UPDATER_SWAP_ACK_TIMEOUT_MS
	if Role = "Ready"
		TimeoutMs := UPDATER_SWAP_READY_TIMEOUT_MS
	else if Role = "Ack"
		TimeoutMs := UPDATER_SWAP_ACK_TIMEOUT_MS
	else
		throw ValueError("Unknown swap worker signal: " . Role)
	return _USTX_WaitForEvent(Owner.Get(Role . "Handle", 0), TimeoutMs)
}

; After the exact parent exits, the worker bounds its own relaunch: the driver
; has the production boot-ready deadline, then probation. The fixture allowance
; covers only the process start and file work outside those native waits.
_USTX_WorkerCompletionTimeoutMs() {
	global UPDATER_SWAP_BOOT_READY_TIMEOUT_MS, UPDATER_SWAP_PROBATION_MS, USTX_WAIT_TIMEOUT_MS
	return UPDATER_SWAP_BOOT_READY_TIMEOUT_MS + UPDATER_SWAP_PROBATION_MS + USTX_WAIT_TIMEOUT_MS
}

; See USTX_FINAL_EXIT_WINDOW_FLOOR_MS.
_USTX_FinalExitWindowMs(CommitReactionMs) {
	global USTX_FINAL_EXIT_WINDOW_FLOOR_MS, USTX_FINAL_EXIT_WINDOW_FACTOR, USTX_WAIT_TIMEOUT_MS
	return Min(USTX_WAIT_TIMEOUT_MS, Max(USTX_FINAL_EXIT_WINDOW_FLOOR_MS,
		CommitReactionMs * USTX_FINAL_EXIT_WINDOW_FACTOR))
}

_USTX_CreateFixtureEvent(Name) {
	Handle := DllCall("CreateEventW", "Ptr", 0, "Int", true, "Int", false, "Str", Name, "Ptr")
	if !Handle
		throw OSError()
	if A_LastError = 183 {
		DllCall("CloseHandle", "Ptr", Handle, "Int")
		throw Error("Updater fixture event already exists: " . Name)
	}
	return Handle
}

_USTX_GetExitCode(Owner) {
	ExitCode := 0xFFFFFFFF
	Handle := Owner.Get("ProcessHandle", 0)
	if !Handle
		return ExitCode
	try {
		if !DllCall("GetExitCodeProcess", "Ptr", Handle, "UInt*", &ExitCode, "Int")
			return 0xFFFFFFFF
	} catch {
		return 0xFFFFFFFF
	}
	return ExitCode
}

; The launch receipt is written before boot-ready, so a worker verdict that saw
; boot-ready already proves which fixture ran. A nonempty ReleaseName holds the
; child until the fixture signals that event, so the worker's probation check
; never races a fixed child lifetime; the worker completion deadline only bounds
; a child orphaned by a dead fixture. An empty ReleaseName exits after boot-ready.
_USTX_WriteBatchFixture(Path, MarkerPath, Label, ReleaseName := "", BootDelayMs := 0) {
	Hold := ReleaseName != ""
	Command := (Hold ? "$h=[Threading.EventWaitHandle]::OpenExisting('" . ReleaseName . "');" : "")
		. (BootDelayMs > 0 ? "Start-Sleep -Milliseconds " . BootDelayMs . ";" : "")
		. "$e=[Threading.EventWaitHandle]::OpenExisting($env:ERGOPTI_UPDATER_BOOT_READY);$null=$e.Set();$e.Dispose()"
		. (Hold ? ";$null=$h.WaitOne(" . _USTX_WorkerCompletionTimeoutMs() . ");$h.Dispose()" : "")
	Script := '@echo off' . "`r`n"
		. 'echo ' . Label . '>"' . MarkerPath . '"' . "`r`n"
		. '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "'
		. Command . '"' . "`r`n"
	FileAppend(Script, Path, "UTF-8-RAW")
	return Script
}

_USTX_StartParentGate(TestId, &ParentPid) {
	Name := "Local\ErgoptiUpdaterFixtureParentExit_" . TestId
	Handle := _USTX_CreateFixtureEvent(Name)
	try {
		Run('"' . A_AhkPath . '" /ErrorStdOut "' . A_ScriptDir
			. '\support\updater_parent_gate.ahk" "' . Name . '"', , "Hide", &ParentPid)
		return Handle
	} catch {
		DllCall("CloseHandle", "Ptr", Handle, "Int")
		throw
	}
}

_USTX_RunSwapCase(NewExists, CurrentStartsAsBak := false, ExitAfterReady := false, BeforeCleanup := 0, NewBootDelayMs := 0) {
	global _USTX_TransactionCounter, USTX_FIXTURE_SETTLE_MS
	global UPDATER_SWAP_SYNCHRONIZE, USTX_PROCESS_TERMINATE
	Failure := 0
	TestId := DllCall("GetCurrentProcessId", "UInt") . "_" . A_TickCount
		. "_" . ++_USTX_TransactionCounter
	TestDir := A_Temp . "\ergopti_updater_swap_test_" . TestId
	CurrentExe := TestDir . "\current.cmd"
	NewExe := TestDir . "\new.cmd"
	BakExe := CurrentExe . ".bak"
	SwapScriptPath := TestDir . "\swap.ps1"
	ParentExitHandle := 0
	OldMarker := TestDir . "\old.marker"
	NewMarker := TestDir . "\new.marker"
	Owner := 0
	ParentHandle := 0
	ParentCleanupHandle := 0
	ParentPid := 0
	TrackerJob := 0
	ReleaseName := "Local\ErgoptiUpdaterFixtureRelease_" . TestId
	ReleaseHandle := 0
	DirCreate(TestDir)
	try {
		ReleaseHandle := _USTX_CreateFixtureEvent(ReleaseName)
		_USTX_WriteBatchFixture(CurrentExe, OldMarker, "OLD", ReleaseName)
		if CurrentStartsAsBak
			FileMove(CurrentExe, BakExe)
		if NewExists
			_USTX_WriteBatchFixture(NewExe, NewMarker, "NEW",
				ExitAfterReady ? "" : ReleaseName, NewBootDelayMs)
		FileAppend(_Updater_BuildSwapWorkerScript(), SwapScriptPath, "UTF-8-RAW")

		ParentExitHandle := _USTX_StartParentGate(TestId, &ParentPid)
		Assert(ParentPid > 0 and ProcessExist(ParentPid),
			"positive control: the exact parent-gate process must be alive")
		; Keep a non-inheritable exact handle for failure cleanup. A PID can be
		; recycled after an unexpected parent exit, so ProcessClose(ParentPid)
		; would make the test capable of killing an unrelated process.
		ParentCleanupHandle := DllCall("OpenProcess", "UInt",
			UPDATER_SWAP_SYNCHRONIZE | USTX_PROCESS_TERMINATE,
			"Int", false, "UInt", ParentPid, "Ptr")
		Assert(ParentCleanupHandle != 0,
			"the behavior test must own an exact parent cleanup HANDLE")
		ParentHandle := DllCall("OpenProcess", "UInt", UPDATER_SWAP_SYNCHRONIZE,
			"Int", true, "UInt", ParentPid, "Ptr")
		Assert(ParentHandle != 0,
			"the behavior test must own an inheritable exact parent HANDLE")

		TransactionId := 1000000 + _USTX_TransactionCounter
		InheritedParentHandle := ParentHandle
		ParentHandle := 0
		Owner := _Updater_CreateSuspendedSwapOwner(
			SwapScriptPath, NewExe, CurrentExe, TransactionId,
			InheritedParentHandle)
		TrackerJob := DllCall("Kernel32\CreateJobObjectW", "Ptr", 0, "Ptr", 0, "Ptr")
		AssertTrue(TrackerJob != 0, "the fixture must own a process-tree job")
		AssertTrue(DllCall("Kernel32\AssignProcessToJobObject", "Ptr", TrackerJob,
			"Ptr", Owner["ProcessHandle"], "Int"), "the suspended worker must enter its fixture job")
		Assert(_Updater_ResumeSwapOwner(Owner),
			"the real PowerShell swap worker must resume from CREATE_SUSPENDED")
		Assert(_USTX_WaitForSwapSignal(Owner, "Ready"),
			"the real swap worker must signal Ready after opening every event and the parent handle")
		if CurrentStartsAsBak {
			Assert(!FileExist(CurrentExe),
				"Ready must not recreate an interrupted Current before authorization")
			AssertContains(FileRead(BakExe, "UTF-8-RAW"), "OLD",
				"Ready must retain the interrupted transaction's last known-good Bak")
		} else
			AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "OLD",
				"Ready alone must not mutate the current executable")

		CommitAt := A_TickCount
		Assert(_Updater_SetSwapEvent(Owner.Get("CommitHandle", 0)),
			"the test must be able to authorize Commit")
		Assert(_USTX_WaitForSwapSignal(Owner, "Ack"),
			"the real swap worker must acknowledge Commit")
		CommitReactionMs := A_TickCount - CommitAt
		if CurrentStartsAsBak {
			Assert(!FileExist(CurrentExe),
				"Commit and Ack must not recover Bak before FinalExit and exact-parent exit")
			AssertContains(FileRead(BakExe, "UTF-8-RAW"), "OLD",
				"Commit and Ack must preserve the interrupted Bak")
		} else
			AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "OLD",
				"Commit and Ack must still leave the current executable untouched")

		Assert(_Updater_SetSwapEvent(Owner.Get("FinalExitHandle", 0)),
			"the test must be able to authorize FinalExit")
		; Waking from a wait and acting took the worker CommitReactionMs just now;
		; give it several times that to misbehave before checking it did not.
		Sleep(_USTX_FinalExitWindowMs(CommitReactionMs))
		AssertEqual(0, _Updater_WaitHandleState(Owner["ProcessHandle"]),
			"the worker must still be alive, blocked on the parent, or the checks below prove nothing")
		if CurrentStartsAsBak {
			Assert(!FileExist(CurrentExe),
				"FinalExit must not recover Bak while the exact parent HANDLE is alive")
			AssertContains(FileRead(BakExe, "UTF-8-RAW"), "OLD",
				"FinalExit must retain Bak while the exact parent is alive")
		} else
			AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "OLD",
				"FinalExit must not mutate files while the exact parent HANDLE is alive")
		AssertEqual(0, _Updater_WaitHandleState(ParentCleanupHandle), "the parent must remain alive until signaled")
		Assert(DllCall("SetEvent", "Ptr", ParentExitHandle, "Int"), "the parent exit must be authorized")
		Assert(_USTX_WaitForProcessExit(Owner, _USTX_WorkerCompletionTimeoutMs()),
			"the real swap worker must finish after the exact parent exits")
		ExitCode := _USTX_GetExitCode(Owner)

		; Each launch receipt precedes its boot-ready signal, so the worker's
		; verdict already proves which fixture ran: observe markers without waiting.
		if NewExists {
			AssertEqual(0, ExitCode,
				"a valid replacement must complete the real swap transaction")
			AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "NEW",
				"success must publish the replacement at Current")
			Assert(!FileExist(BakExe),
				"success may delete Bak only after the replacement survives probation")
			Assert(_USTX_WaitForFile(NewMarker, 0),
				"success must relaunch the replacement fixture")
			Assert(!FileExist(OldMarker),
				"success must not relaunch the retired current fixture")
		} else {
			Assert(ExitCode != 0,
				"a missing New after Current-to-Bak must fail the swap transaction")
			AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "OLD",
				"rollback must restore the old Current after New is missing")
			Assert(!FileExist(BakExe),
				"rollback must consume Bak when restoring Current")
			Assert(_USTX_WaitForFile(OldMarker, 0),
				"rollback must explicitly relaunch the restored old fixture")
			Assert(!FileExist(NewMarker),
				"rollback must never launch a missing replacement")
		}
		if BeforeCleanup
			BeforeCleanup.Call(TestDir)
	} catch as Err {
		; Cleanup must not erase the only explanation of a native worker failure.
		Failure := Err
		Err.Message .= _USTX_FailureEvidence(TestDir)
		throw Err
	} finally {
		if (Owner is Map)
			_Updater_CloseSwapOwner(Owner, true)
		if ParentHandle
			_Updater_CloseNativeSwapHandle(ParentHandle)
		if ParentCleanupHandle {
			if (_Updater_WaitHandleState(ParentCleanupHandle) == 0)
				try DllCall("TerminateProcess", "Ptr", ParentCleanupHandle,
					"UInt", 1, "Int")
			_Updater_CloseNativeSwapHandle(ParentCleanupHandle)
		}
		if ParentExitHandle
			Assert(DllCall("CloseHandle", "Ptr", ParentExitHandle, "Int"))
		; Released only after the worker verdict, so every probation check saw a
		; live child; the tree wait below then observes the held child exiting.
		if ReleaseHandle {
			Assert(DllCall("SetEvent", "Ptr", ReleaseHandle, "Int"),
				"the fixture must release its relaunched child")
			Assert(DllCall("CloseHandle", "Ptr", ReleaseHandle, "Int"))
		}
		if TrackerJob {
			if _USTX_CloseFixtureTree(TrackerJob, Failure)
				_USTX_DeleteFixtureAfterCase(TestDir, Failure)
		} else {
			Sleep(USTX_FIXTURE_SETTLE_MS)
			_USTX_DeleteFixtureAfterCase(TestDir, Failure)
		}
	}
}

_USTX_WaitForFile(Path, TimeoutMs := unset) {
	global USTX_WAIT_TIMEOUT_MS
	if !IsSet(TimeoutMs)
		TimeoutMs := USTX_WAIT_TIMEOUT_MS
	StartedTick := A_TickCount
	loop {
		Attributes := FileExist(Path)
		if Attributes != "" && !InStr(Attributes, "D")
			return true
		; A marker is a file receipt; poll once even when no wait is requested.
		if TickExpired(StartedTick, TimeoutMs)
			return false
		Sleep(10)
	}
}

_USTX_SuccessReplacesAndRelaunches() {
	_USTX_RunSwapCase(true)
}

_USTX_NativeFailureRetainsDiagnosis() {
	Failure := 0
	try _USTX_RunSwapCase(true, false, true)
	catch as Err
		Failure := Err
	AssertTrue(Failure is Error, "an exiting replacement must fail the real swap transaction")
	AssertContains(Failure.Message, "a valid replacement must complete the real swap transaction")
	AssertContains(Failure.Message, "SWAP_ERROR:Driver exited",
		"the native worker diagnosis must survive the transaction fixture cleanup")
}
Test("updater fixture: native child exit retains worker diagnosis (updater-fixture-diagnostics)",
	_USTX_NativeFailureRetainsDiagnosis)

Test("updater swap transaction: success waits for authorization and relaunches the replacement",
	_USTX_SuccessReplacesAndRelaunches)

_USTX_MissingNewRestoresAndRelaunchesOld() {
	_USTX_RunSwapCase(false)
}

Test("updater swap transaction: missing New after Current-to-Bak restores and relaunches old",
	_USTX_MissingNewRestoresAndRelaunchesOld)

_USTX_InterruptedCurrentBakIsAdoptedForRecovery() {
	_USTX_RunSwapCase(false, true)
}

Test("updater swap transaction: interrupted Bak without Current is restored and relaunched",
	_USTX_InterruptedCurrentBakIsAdoptedForRecovery)

; A loaded host stretches worker phases without breaking the production
; contract: boot-ready may outlast the fixture's own step allowance, and the
; worker may observe the relaunched child long after it signaled. Both must
; still complete, or the fixture fails where the updater would not.
_USTX_SlowWorkerPhaseCompletes(Phase) {
	global USTX_WAIT_TIMEOUT_MS, UPDATER_SWAP_BOOT_READY_TIMEOUT_MS, UPDATER_SWAP_PROBATION_MS
	if Phase = "boot" {
		BootDelayMs := USTX_WAIT_TIMEOUT_MS + 1000
		Assert(BootDelayMs < UPDATER_SWAP_BOOT_READY_TIMEOUT_MS,
			"positive control: the slow boot must stay inside the worker boot-ready deadline")
		_USTX_RunSwapCase(true, false, false, 0, BootDelayMs)
		return
	}
	if Phase != "probation"
		throw ValueError("Unknown worker phase: " . Phase)
	SavedProbationMs := UPDATER_SWAP_PROBATION_MS
	UPDATER_SWAP_PROBATION_MS := SavedProbationMs * 3
	try _USTX_RunSwapCase(true)
	finally UPDATER_SWAP_PROBATION_MS := SavedProbationMs
}
for Phase in ["boot", "probation"]
	Test("updater swap transaction: slow " . Phase . " phase completes inside the worker contract"
		. " (updater-fixture-worker-deadline)", _USTX_SlowWorkerPhaseCompletes.Bind(Phase))

; After FinalExit the worker must leave every file alone while the exact parent
; lives. A fixed 150 ms was that check's whole window: on a loaded host the
; worker had not even woken from its wait by then, so the check passed without
; testing anything (updater-fixture-final-exit-window). The window now scales
; with the worker's measured reaction to Commit, and the worker must still be
; alive, blocked on the parent, when the window closes.
_USTX_FinalExitWindowScalesWithTheWorker() {
	global USTX_FINAL_EXIT_WINDOW_FLOOR_MS, USTX_FINAL_EXIT_WINDOW_FACTOR, USTX_WAIT_TIMEOUT_MS
	AssertEqual(USTX_FINAL_EXIT_WINDOW_FLOOR_MS, _USTX_FinalExitWindowMs(0),
		"a fast worker still gets the floor window")
	AssertEqual(2000 * USTX_FINAL_EXIT_WINDOW_FACTOR, _USTX_FinalExitWindowMs(2000),
		"a worker that took 2 s to react to Commit must be given several times that after FinalExit")
	AssertEqual(USTX_WAIT_TIMEOUT_MS, _USTX_FinalExitWindowMs(USTX_WAIT_TIMEOUT_MS),
		"the window stays inside the fixture's own step allowance")
	Src := FileRead(A_LineFile, "UTF-8")
	Start := InStr(Src, "`n_USTX_RunSwapCase(")
	Body := Start ? _StripFullLineComments(SubStr(Src, Start, InStr(Src, "`n}`n", , Start) - Start)) : ""
	Assert(Body != "", "the swap case runner must be readable")
	Assert(InStr(Body,"Sleep(_USTX_FinalExitWindowMs(CommitReactionMs))") > 0
			and InStr(Body, "Sleep(150)") = 0,
		"the FinalExit negative check must wait the scaled window, not a fixed 150 ms")
	Assert(InStr(Body, "_Updater_WaitHandleState(Owner[" . Chr(34) . "ProcessHandle" . Chr(34) . "])") > 0,
		"the FinalExit negative check must prove the worker is still waiting on the parent")
}
Test("updater swap transaction: the FinalExit window scales with the worker"
	. " (updater-fixture-final-exit-window)", _USTX_FinalExitWindowScalesWithTheWorker)
