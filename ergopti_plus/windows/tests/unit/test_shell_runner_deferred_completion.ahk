; tests/unit/test_shell_runner_deferred_completion.ahk

; ==============================================================================
; MODULE: Deferred Legacy Completion Ownership Tests
; DESCRIPTION:
; Suspending during capture I/O must retain one result, not native cleanup debt.
; Event handles prove release without pretending to prove native process exit;
; the public two-child pause fixture covers actual native completion separately.
; ==============================================================================

#Requires AutoHotkey v2.0

_SRDC_PauseAfterRead(Action) {
	global _SR_TaskCounter
	AssertEqual(0, _SR_ActiveTasks.Count, "global polling fixture requires no foreign legacy tasks")
	AssertEqual(0, _SR_PendingCallbacks.Count, "global polling fixture requires no foreign deliveries")
	CaptureDir := _SR_AcquireCaptureDirectory()
	CapturePath := CaptureDir . "output.tmp"
	EventHandle := 0, Native := 0, Claim := 0, State := 0
	Reads := [], Results := []
	CallbackState := {Reentered: false}
	PreviousSuspend := A_IsSuspended
	PreviousCritical := Critical("On")
	ReadAndPause(Path) {
		Reads.Push(Path)
		Text := FileRead(Path)
		Suspend(true)
		if Action = "read-error"
			throw Error("Injected capture read failure after suspension.")
		return Text
	}
	OnDone(Code, Output, Diagnostic) {
		Results.Push({Code: Code, Output: Output, Diagnostic: Diagnostic, Paused: A_IsSuspended})
		_SR_Poll()
		CallbackState.Reentered := true
		if Action = "throw"
			throw Error("Injected deferred callback failure after reentry.")
	}
	try {
		Suspend(false)
		FileAppend("deferred capture", CapturePath, "UTF-8-RAW")
		EventHandle := DllCall("Kernel32\CreateEventW", "Ptr", 0, "Int", true,
			"Int", true, "Ptr", 0, "Ptr")
		AssertTrue(EventHandle != 0)
		Native := Map("ProcessHandle", EventHandle)
		State := _SR_LegacyNewState(++_SR_TaskCounter, CapturePath, OnDone)
		State["CaptureDir"] := CaptureDir
		State["Native"] := Native
		_SR_LegacyBeginStart(State)
		AssertTrue(_SR_LegacyPublishStart(State, 424242)["Published"])
		Claim := _SR_LegacyClaimCompletion(State["TaskId"], State)
		AssertTrue(_SR_LegacyFinishCompletion(Claim, 37, ReadAndPause))
		AssertTrue(A_IsSuspended)
		AssertEqual(1, Reads.Length)
		AssertEqual(CapturePath, Reads[1], "capture identity is asserted outside the caught reader")
		AssertEqual(0, Results.Length, "capture completion cannot bypass a newly requested pause")
		AssertFalse(DirExist(CaptureDir) != "")
		AssertEqual(0, Native["ProcessHandle"], "callback suspension must not retain native handles")
		AssertFalse(_SR_LegacyReleaseOwners.Has(ObjPtr(Claim)))
		AssertTrue(_SR_PendingCallbacks.Has(ObjPtr(Claim)))
		AssertTrue(_SR_LegacyDrainReleases(), "deferred notification is not cleanup debt blocking admission")
		AssertFalse(_SR_CompletionDispatch(Claim.Clone()), "a shallow copy cannot consume the result")
		_SR_Poll()
		AssertEqual(0, Results.Length)
		AssertTrue(_SR_PollRunning, "a pending callback must keep the poller armed while paused")
		Revoked := Action = "detach" || Action = "terminate" || Action = "terminateAsync"
		switch Action {
			case "detach":
				AssertTrue(_SR_LegacyClaimDetach(State))
			case "terminate":
				_SR_LegacyClaimTerminate(State)
			case "terminateAsync":
				_SR_LegacyClaimAsyncTerminate(State)
		}
		if Revoked {
			_SR_Poll()
			AssertFalse(_SR_PendingCallbacks.Has(ObjPtr(Claim)), "revoked results are purged even while paused")
		}
		Suspend(false)
		_SR_Poll()
		_SR_Poll()
		AssertEqual(Revoked ? 0 : 1, Results.Length)
		AssertEqual(1, Reads.Length, "resume never rereads a deleted capture")
		AssertFalse(_SR_PendingCallbacks.Has(ObjPtr(Claim)))
		AssertEqual(0, Claim["CompletionResult"], "terminal delivery releases retained output")
		if !Revoked {
			AssertTrue(CallbackState.Reentered, "the nested poll must return without a swallowed failure")
			AssertFalse(Results[1].Paused)
			AssertEqual(37, Results[1].Code)
			AssertEqual(Action = "read-error" ? "" : "deferred capture", Results[1].Output)
			AssertEqual(Action = "read-error" ? "Injected capture read failure after suspension." : "",
				Results[1].Diagnostic)
		}
	} finally {
		try {
			if IsObject(State)
				_SR_LegacyClaimDetach(State)
			if IsObject(State) && !IsObject(Claim)
				Claim := _SR_LegacyFailStart(State, 0)
			if IsObject(Claim) {
				_SR_CompletionDispatch(Claim)
				AssertTrue(_SR_LegacyCleanupCaptureDirectory(Claim))
				AssertTrue(_SR_LegacyReleaseProcess(Claim))
				AssertFalse(_SR_PendingCallbacks.Has(ObjPtr(Claim)))
				AssertFalse(_SR_LegacyReleaseOwners.Has(ObjPtr(Claim)))
			}
			if IsObject(Native) && Native["ProcessHandle"] {
				AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Native["ProcessHandle"], "Int"))
				Native["ProcessHandle"] := 0
			} else if !IsObject(Native) && EventHandle
				AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", EventHandle, "Int"))
			_SRTLC_DeleteCapture(CapturePath)
			if DirExist(CaptureDir)
				DirDelete(CaptureDir)
		} finally {
			Suspend(PreviousSuspend)
			Critical(PreviousCritical)
		}
	}
}
for Action in ["resume", "detach", "terminate", "terminateAsync", "throw", "read-error"]
	Test("shell runner: pause after capture preserves completion ownership " . Action . " (shell-deferred-completion)",
		_SRDC_PauseAfterRead.Bind(Action))
