; tests/unit/test_shell_runner_tree_native_refusal.ahk

; ==============================================================================
; MODULE: Tree Native Refusal Tests
; DESCRIPTION:
; A restricted native job handle rejects termination while a full-rights guardian
; keeps the child alive. Refusal must retain cleanup authority, not notify Done.
; ==============================================================================

#Requires AutoHotkey v2.0

_SRTNR_QueryOnlyJob(Original) {
	static JobQuery := 0x0004
	CurrentProcess := DllCall("Kernel32\GetCurrentProcess", "Ptr")
	Duplicate := 0
	if !DllCall("Kernel32\DuplicateHandle", "Ptr", CurrentProcess, "Ptr", Original,
			"Ptr", CurrentProcess, "Ptr*", &Duplicate, "UInt", JobQuery,
			"Int", false, "UInt", 0, "Int")
		throw OSError(A_LastError, "DuplicateHandle")
	return Duplicate
}

_SRTNR_RefusedRequest(Mode := "deliver") {
	global _SR_ActiveTasks, _SR_TreeOwnedTasks, _SR_PendingCallbacks, _SR_TreePollRunning
	AssertEqual(0, _SR_ActiveTasks.Count, "native refusal fixture requires no foreign legacy tasks")
	AssertEqual(0, _SR_TreeOwnedTasks.Count, "native refusal fixture requires no foreign tree tasks")
	AssertEqual(0, _SR_PendingCallbacks.Count, "native refusal fixture requires no foreign deliveries")
	Scope := {State: 0, GuardianJob: 0, Observer: 0, Done: 0, CallbackQuiesced: true,
		Reentered: false, ReentryReceipt: true}
	WasSuspended := A_IsSuspended
	WasPollRunning := _SR_TreePollRunning
	Failure := 0
	CleanupErrors := []
	Observe(State, Native) {
		Scope.State := State
		Scope.Observer := _SRTOW_DuplicateNativeHandle(Native["ProcessHandle"])
		if !Scope.Observer
			throw Error("Native refusal fixture could not retain its process observer")
		LimitedJob := _SRTNR_QueryOnlyJob(Native["JobHandle"])
		; Transfer the full capability to the guardian, not a borrowed PID
		Scope.GuardianJob := Native["JobHandle"]
		Native["JobHandle"] := LimitedJob
	}
	Done(*) {
		Scope.Done += 1
		Scope.CallbackQuiesced := Scope.State["TreeQuiesced"]
	}
	Reenter(*) {
		Scope.Reentered := Scope.State["TerminalClaim"].Get("NativeBusy", false)
		Scope.ReentryReceipt := Handle.requestTerminate()
	}
	Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
		["/ErrorStdOut", A_ScriptDir . "\support\legacy_cleanup_child.ahk"], Done, , Observe)
	try {
		Suspend(false)
		AssertTrue(Handle.start(), "the native job fixture must start")
		AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(Scope.Observer),
			"the exact child must be alive before the termination request")
		Diagnostic := ""
		AssertTrue(_SR_TreeActiveProcessCount(Scope.State["JobHandle"], &Diagnostic) > 0,
			"the restricted handle must still authorize job accounting")
		AssertEqual("", Diagnostic)
		if Mode = "reenter"
			SetTimer(Reenter, -10)
		Receipt := Handle.requestTerminate()
		if Mode = "reenter" {
			AssertTrue(Scope.Reentered, "the real yielding teardown must admit a competing request")
			AssertFalse(Scope.ReentryReceipt, "reentrant termination must not certify unfinished native cleanup")
		}
		Alive := _SRTOW_ExactProcessWait(Scope.Observer) = SRTOW_WAIT_TIMEOUT
		FileAppend(Format("# tree refusal receipt={1}, alive={2}, done={3}, callback_quiesced={4}`n",
			Receipt, Alive, Scope.Done, Scope.CallbackQuiesced), "*")
		AssertFalse(Receipt, "native refusal must not certify an empty tree")
		AssertTrue(Alive, "the independent guardian must prove the child still lives")
		TerminationRefused := false
		for NativeError in Scope.State["TerminalClaim"]["NativeErrors"]
			if InStr(NativeError, "TerminateJobObject failed")
				TerminationRefused := true
		AssertTrue(TerminationRefused, "the native termination API must report the refusal")
		AssertEqual(0, Scope.Done, "refused tree termination must not publish completion while the child lives")
		AssertTrue(Scope.State["TerminalClaim"]["JobHandle"] != 0,
			"refused quiescence must retain its exact native cleanup authority")
		AssertTrue(_SR_TreeNativeDebts.Has(ObjPtr(Scope.State["TerminalClaim"])),
			"the refused terminal owner must have a scheduled retry owner")
		if Mode = "detach"
			Handle.detach()
		if Mode = "pause"
			Suspend(true)
		AssertTrue(DllCall("Kernel32\TerminateJobObject", "Ptr", Scope.GuardianJob,
			"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int"))
		AssertTrue(_SRTOW_WaitForExactProcessExit(Scope.Observer))
		; Release the independent reference before asking job accounting to drain
		AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Scope.Observer, "Int"))
		Scope.Observer := 0
		Started := A_TickCount
		while !Scope.State["TreeQuiesced"] && TickElapsed(Started) < SRTOW_EXIT_SIGNAL_SETTLE_MS {
			_SR_TreePoll()
			Sleep(SRTOW_PID_POLL_MS)
		}
		AssertTrue(Scope.State["TreeQuiesced"], "the retained timer owner must recover after native exit")
		AssertFalse(Scope.State["FinalizationPending"])
		AssertFalse(_SR_TreeNativeDebts.Has(ObjPtr(Scope.State["TerminalClaim"])))
		AssertEqual(Mode = "deliver" || Mode = "reenter" ? 1 : 0, Scope.Done,
			"recovered completion must respect callback revocation and pause")
		Suspend(false)
		_SR_TreePoll()
		AssertEqual(Mode = "detach" ? 0 : 1, Scope.Done)
		AssertTrue(Handle.requestTerminate(), "a settled owner must return an honest success receipt")
		_SR_TreePoll()
		AssertEqual(Mode = "detach" ? 0 : 1, Scope.Done, "retries must not redeliver completion")
	} catch as Err {
		Failure := Err
	} finally {
		try SetTimer(Reenter, 0)
		catch as Err
			CleanupErrors.Push(Err.Message)
		try Handle.detach()
		catch as Err
			CleanupErrors.Push(Err.Message)
		try {
			if Scope.GuardianJob {
				AssertTrue(DllCall("Kernel32\TerminateJobObject", "Ptr", Scope.GuardianJob,
					"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int"), "the exact guardian must terminate its own child")
				if Scope.Observer
					AssertTrue(_SRTOW_WaitForExactProcessExit(Scope.Observer), "guardian cleanup must observe native exit")
			}
		} catch as Err {
			CleanupErrors.Push(Err.Message)
		} finally {
			try {
				if Scope.Observer {
					AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Scope.Observer, "Int"))
					Scope.Observer := 0
				}
				if IsObject(Scope.State) && IsObject(Scope.State["TerminalClaim"]) {
					Claim := Scope.State["TerminalClaim"]
					AssertTrue(_SR_TreeQuiesceNative(Claim, true), "fixture terminal claim must settle after guardian exit")
					_SR_TreeRecordQuiesced(Scope.State, Claim)
					_SR_TreeFinishClaim(Claim)
				} else {
					AssertTrue(Handle.terminate(), "fixture launch cleanup must settle")
				}
			} catch as Err {
				CleanupErrors.Push(Err.Message)
			} finally {
				try {
					if Scope.GuardianJob {
						AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Scope.GuardianJob, "Int"))
						Scope.GuardianJob := 0
					}
					if IsObject(Scope.State) {
						_SRTLC_DeleteCapture(Scope.State["TmpFile"])
						if DirExist(Scope.State["CaptureDir"])
							DirDelete(Scope.State["CaptureDir"])
					}
				} catch as Err {
					CleanupErrors.Push(Err.Message)
				} finally {
					Suspend(WasSuspended)
					PreviousCritical := Critical("On")
					try _SR_TreeSetPollerRunningLocked(WasPollRunning || _SR_TreeOwnedTasks.Count != 0)
					finally Critical(PreviousCritical)
				}
			}
		}
	}
	if CleanupErrors.Length {
		Message := Failure is Error ? Failure.Message : "Native refusal fixture cleanup failed"
		for CleanupError in CleanupErrors
			Message .= "`nCleanup: " . CleanupError
		throw Error(Message)
	}
	if Failure is Error
		throw Failure
}

Test("shell runner: native job refusal keeps completion unpublished (shell-tree-native-refusal)",
	_SRTNR_RefusedRequest)
Test("shell runner: recovered native refusal respects detach (shell-tree-native-refusal)",
	_SRTNR_RefusedRequest.Bind("detach"))
Test("shell runner: native refusal cleanup continues while paused (shell-tree-native-refusal)",
	_SRTNR_RefusedRequest.Bind("pause"))
Test("shell runner: reentrant native refusal cannot steal cleanup (shell-tree-native-refusal)",
	_SRTNR_RefusedRequest.Bind("reenter"))

_SRTNR_ProtectedJobClose() {
	static ProtectFromClose := 0x0002
	Job := DllCall("Kernel32\CreateJobObjectW", "Ptr", 0, "Ptr", 0, "Ptr")
	AssertTrue(Job != 0, "the fixture must own a real job")
	Claim := Map("ProcessHandle", 0, "ThreadHandle", 0, "JobHandle", Job, "Assigned", true)
	try {
		AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Job,
			"UInt", ProtectFromClose, "UInt", ProtectFromClose, "Int"))
		Receipt := _SR_TreeQuiesceNative(Claim, true)
		CloseRefused := false
		for NativeError in Claim["NativeErrors"]
			if InStr(NativeError, "CloseHandle(job) failed")
				CloseRefused := true
		AssertTrue(CloseRefused, "a protected valid handle must refuse native close")
		AssertEqual(Job, Claim["JobHandle"], "a refused close must retain the exact cleanup capability")
		AssertFalse(Receipt, "unreleased native ownership must not certify completed teardown")
	} finally {
		AssertTrue(DllCall("Kernel32\SetHandleInformation", "Ptr", Job,
			"UInt", ProtectFromClose, "UInt", 0, "Int"))
		; The original implementation forgets this still-valid fixture capability
		if !Claim["JobHandle"]
			Claim["JobHandle"] := Job
		AssertTrue(_SR_TreeQuiesceNative(Claim, true), "unprotected cleanup must release the exact job")
	}
}

Test("shell runner: protected native job close retains ownership (shell-tree-native-refusal)",
	_SRTNR_ProtectedJobClose)
