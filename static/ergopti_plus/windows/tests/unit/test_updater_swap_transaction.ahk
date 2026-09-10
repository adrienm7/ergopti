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
global USTX_WAIT_TIMEOUT_MS := 10000
global USTX_FIXTURE_SETTLE_MS := 1400
global USTX_PROCESS_TERMINATE := 0x0001
global USTX_DIAGNOSTIC_CHAR_LIMIT := 2048

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

_USTX_WriteBatchFixture(Path, MarkerPath, Label, ExitAfterReady := false) {
	Script := '@echo off' . "`r`n"
		. '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command "$e=[Threading.EventWaitHandle]::OpenExisting($env:ERGOPTI_UPDATER_BOOT_READY);$null=$e.Set();$e.Dispose()"' . "`r`n"
		. 'echo ' . Label . '>"' . MarkerPath . '"' . "`r`n"
	if !ExitAfterReady
		Script .= 'ping -n 2 127.0.0.1 >nul' . "`r`n"
	FileAppend(Script, Path, "UTF-8-RAW")
	return Script
}

_USTX_WriteParentGate(Path, ExitFlag) {
	Script := '@echo off' . "`r`n"
		. ':wait' . "`r`n"
		. 'if exist "' . ExitFlag . '" exit /b 0' . "`r`n"
		. 'ping -n 2 127.0.0.1 >nul' . "`r`n"
		. 'goto wait' . "`r`n"
	FileAppend(Script, Path, "UTF-8-RAW")
}

_USTX_RunSwapCase(NewExists, CurrentStartsAsBak := false, ExitAfterReady := false, BeforeCleanup := 0) {
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
	ParentGatePath := TestDir . "\parent_gate.cmd"
	ParentExitFlag := TestDir . "\parent_exit.flag"
	OldMarker := TestDir . "\old.marker"
	NewMarker := TestDir . "\new.marker"
	Owner := 0
	ParentHandle := 0
	ParentCleanupHandle := 0
	ParentPid := 0
	DirCreate(TestDir)
	try {
		_USTX_WriteBatchFixture(CurrentExe, OldMarker, "OLD")
		if CurrentStartsAsBak
			FileMove(CurrentExe, BakExe)
		if NewExists
			_USTX_WriteBatchFixture(NewExe, NewMarker, "NEW", ExitAfterReady)
		_USTX_WriteParentGate(ParentGatePath, ParentExitFlag)
		FileAppend(_Updater_BuildSwapWorkerScript(), SwapScriptPath, "UTF-8-RAW")

		Run(A_ComSpec . ' /d /c "' . ParentGatePath . '"', , "Hide", &ParentPid)
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
		Assert(_Updater_ResumeSwapOwner(Owner),
			"the real PowerShell swap worker must resume from CREATE_SUSPENDED")
		Assert(_USTX_WaitForEvent(Owner.Get("ReadyHandle", 0)),
			"the real swap worker must signal Ready after opening every event and the parent handle")
		if CurrentStartsAsBak {
			Assert(!FileExist(CurrentExe),
				"Ready must not recreate an interrupted Current before authorization")
			AssertContains(FileRead(BakExe, "UTF-8-RAW"), "OLD",
				"Ready must retain the interrupted transaction's last known-good Bak")
		} else
			AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "OLD",
				"Ready alone must not mutate the current executable")

		Assert(_Updater_SetSwapEvent(Owner.Get("CommitHandle", 0)),
			"the test must be able to authorize Commit")
		Assert(_USTX_WaitForEvent(Owner.Get("AckHandle", 0)),
			"the real swap worker must acknowledge Commit")
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
		Sleep(150)
		if CurrentStartsAsBak {
			Assert(!FileExist(CurrentExe),
				"FinalExit must not recover Bak while the exact parent HANDLE is alive")
			AssertContains(FileRead(BakExe, "UTF-8-RAW"), "OLD",
				"FinalExit must retain Bak while the exact parent is alive")
		} else
			AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "OLD",
				"FinalExit must not mutate files while the exact parent HANDLE is alive")
		FileAppend("exit", ParentExitFlag, "UTF-8-RAW")
		Assert(_USTX_WaitForProcessExit(Owner),
			"the real swap worker must finish after the exact parent exits")
		ExitCode := _USTX_GetExitCode(Owner)

		if NewExists {
			AssertEqual(0, ExitCode,
				"a valid replacement must complete the real swap transaction")
			AssertContains(FileRead(CurrentExe, "UTF-8-RAW"), "NEW",
				"success must publish the replacement at Current")
			Assert(!FileExist(BakExe),
				"success may delete Bak only after the replacement survives probation")
			Assert(_USTX_WaitForFile(NewMarker),
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
			Assert(_USTX_WaitForFile(OldMarker),
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
		Sleep(USTX_FIXTURE_SETTLE_MS)
		_USTX_DeleteFixtureAfterCase(TestDir, Failure)
	}
}

_USTX_WaitForFile(Path, TimeoutMs := unset) {
	global USTX_WAIT_TIMEOUT_MS
	if !IsSet(TimeoutMs)
		TimeoutMs := USTX_WAIT_TIMEOUT_MS
	StartedTick := A_TickCount
	while !TickExpired(StartedTick, TimeoutMs) {
		if FileExist(Path)
			return true
		Sleep(10)
	}
	return false
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
