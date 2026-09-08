; tests/unit/test_shell_runner_exit_query_failure.ahk

; ==============================================================================
; MODULE: Tree Exit Query Failure Tests
; DESCRIPTION:
; A signaled HANDLE proves exit, not permission to read its code. Real restricted
; handles must not let observation failure become successful task completion.
; ==============================================================================

#Requires AutoHotkey v2.0

_SREQ_RestrictedHandle(Original) {
	static Synchronize := 0x00100000
	CurrentProcess := DllCall("Kernel32\GetCurrentProcess", "Ptr")
	Restricted := 0
	if !DllCall("Kernel32\DuplicateHandle", "Ptr", CurrentProcess, "Ptr", Original,
			"Ptr", CurrentProcess, "Ptr*", &Restricted, "UInt", Synchronize,
			"Int", false, "UInt", 0, "Int")
		throw OSError(A_LastError, "DuplicateHandle")
	return Restricted
}

_SREQ_NativeFailure(Mode) {
	global _SR_ActiveTasks, _SR_TreeOwnedTasks, _SR_PendingCallbacks, _SR_TreePollRunning
	static TimeoutMs := 5000, PollMs := 10
	AssertEqual(0, _SR_ActiveTasks.Count, "global polling fixture requires no foreign legacy tasks")
	AssertEqual(0, _SR_TreeOwnedTasks.Count, "global polling fixture requires no foreign tree tasks")
	AssertEqual(0, _SR_PendingCallbacks.Count, "global polling fixture requires no foreign deliveries")
	Scope := {State: 0, FullHandle: 0, RestrictedDebt: 0, Claim: 0, Calls: 0, Code: -1, Output: ""}
	Observe(State, Native) {
		Scope.State := State
	}
	Done(Code, Output, Errors) {
		Scope.Calls += 1
		Scope.Code := Code
		Scope.Output := Output
	}
	WasSuspended := A_IsSuspended
	WasPollRunning := _SR_TreePollRunning
	Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
		["/ErrorStdOut", A_ScriptDir . "\support\legacy_exit_code_child.ahk", "37"], Done, , Observe)
	try {
		Suspend(true)
		AssertTrue(Handle.start(), "the native child must start")
		PreviousCritical := Critical("On")
		try _SR_TreeSetPollerRunningLocked(false)
		finally Critical(PreviousCritical)
		State := Scope.State
		Started := A_TickCount
		while !_SR_TreeProcessHasExited(State["ProcessHandle"], &WaitDiagnostic := "")
				&& TickElapsed(Started) < TimeoutMs
			Sleep(PollMs)
		AssertTrue(_SR_TreeProcessHasExited(State["ProcessHandle"], &WaitDiagnostic),
			"the exact native child must have exited before fault injection")
		Suspend(false)
		if Mode = "natural-guard" {
			Scope.Claim := _SR_TreeClaimTask(State, false, true)
			Original := Scope.Claim["ProcessHandle"]
			Rejected := false
			try _SR_TreeQuiesceNative(Scope.Claim, false)
			catch Error as Err
				Rejected := InStr(Err.Message, "Natural tree quiescence requires a reaped root") > 0
			AssertTrue(Rejected, "natural quiescence must reject an unreaped root before taking handles")
			AssertEqual(Original, Scope.Claim["ProcessHandle"], "the rejected claim must retain its exact handle")
			AssertTrue(_SR_TreeReadExitCode(Original, &Code := 0, &Diagnostic := ""))
			AssertEqual(37, Code, "rejected natural teardown must preserve native query authority")
			AssertEqual(0, Scope.Calls)
			return
		}
		Restricted := _SREQ_RestrictedHandle(State["ProcessHandle"])
		Scope.FullHandle := State["ProcessHandle"]
		State["ProcessHandle"] := Restricted
		AssertTrue(_SR_TreeProcessHasExited(Restricted, &WaitDiagnostic), "restricted wait must succeed")
		AssertFalse(_SR_TreeReadExitCode(Restricted, &Code := 0, &Diagnostic := ""),
			"the native fault must be query refusal, not an unsignaled process")
		AssertTrue(InStr(Diagnostic, "GetExitCodeProcess failed") > 0)
		if Mode = "terminate" {
			AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Scope.FullHandle, "Int"))
			Scope.FullHandle := 0
			Scope.Claim := _SR_TreeClaimTask(State, true)
			AssertTrue(_SR_TreeQuiesceNative(Scope.Claim, true), "termination must still confirm native tree exit")
			AssertEqual(SR_TREE_TERMINATE_EXIT_CODE, Scope.Claim["ExitCode"],
				"a refused query must retain the explicit termination result, never default success")
			AssertTrue(Scope.Claim["NativeErrors"].Length > 0, "the native query failure must remain diagnostic")
			_SR_TreeRecordQuiesced(State, Scope.Claim)
			_SR_TreeFinishClaim(Scope.Claim)
			AssertEqual(1, Scope.Calls)
			AssertEqual(SR_TREE_TERMINATE_EXIT_CODE, Scope.Code)
			return
		}
		loop 2 {
			_SR_TreePoll()
			AssertEqual(0, Scope.Calls, "query failure must not publish any completion")
			AssertFalse(State["RootReaped"], "a refused exit query must not mark the root reaped")
			AssertEqual(Restricted, State["ProcessHandle"], "query refusal must retain exact native ownership")
			AssertTrue(_SR_TreeOwnedTasks.Has(State["TaskId"]), "the task must remain eligible for retry")
			AssertEqual(Diagnostic, State["ExitQueryDiagnostic"], "identical query failures must retain one diagnostic")
		}
		Scope.RestrictedDebt := Restricted
		State["ProcessHandle"] := Scope.FullHandle
		Scope.FullHandle := 0
		AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Scope.RestrictedDebt, "Int"))
		Scope.RestrictedDebt := 0
		Started := A_TickCount
		while !Scope.Calls && TickElapsed(Started) < TimeoutMs {
			_SR_TreePoll()
			Sleep(PollMs)
		}
		AssertEqual(1, Scope.Calls, "recovered native query must complete once")
		AssertEqual(37, Scope.Code, "recovery must publish the actual child failure")
		AssertEqual("legacy-exit-37", Scope.Output)
		AssertEqual("", State["ExitQueryDiagnostic"], "successful query must clear the failure episode")
		_SR_TreePoll()
		AssertEqual(1, Scope.Calls, "later polling must not repeat completion")
	} finally {
		CleanupError := 0
		try {
			; Release only handles separately owned by this fixture before job drain
			for Name in ["FullHandle", "RestrictedDebt"] {
				try {
					if Scope.%Name% {
						if !DllCall("Kernel32\CloseHandle", "Ptr", Scope.%Name%, "Int")
							throw OSError(A_LastError, "CloseHandle")
						Scope.%Name% := 0
					}
				} catch as Err {
					; Finish the other owners and restore global state before surfacing
					; a close failure, instead of skipping cleanup of the whole fixture
					CleanupError := Err
				}
			}
			if IsObject(Scope.Claim) {
				if !Scope.Claim["TreeQuiesced"]
					AssertTrue(_SR_TreeQuiesceNative(Scope.Claim, true), "fixture claim cleanup must confirm exit")
				_SR_TreeRecordQuiesced(Scope.State, Scope.Claim)
				_SR_TreeFinishClaim(Scope.Claim)
			} else {
				AssertTrue(Handle.terminate(), "fixture task cleanup must confirm exit")
			}
		} finally {
			Suspend(WasSuspended)
			PreviousCritical := Critical("On")
			try _SR_TreeSetPollerRunningLocked(WasPollRunning || _SR_TreeOwnedTasks.Count != 0)
			finally Critical(PreviousCritical)
		}
		if IsObject(CleanupError)
			throw CleanupError
	}
}

for Mode in ["retry", "terminate", "natural-guard"]
	Test("shell runner: native query refusal " . Mode . " (shell-tree-exit-query-failure)",
		_SREQ_NativeFailure.Bind(Mode))
