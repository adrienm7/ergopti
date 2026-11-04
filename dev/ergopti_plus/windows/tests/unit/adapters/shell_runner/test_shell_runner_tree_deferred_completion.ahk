; tests/unit/adapters/shell_runner/test_shell_runner_tree_deferred_completion.ahk

; ==============================================================================
; MODULE: Tree-Owned Deferred Completion Tests
; DESCRIPTION:
; Native tree cleanup and callback admission have independent completion states.
; Pause during capture, then revoke or resume delivery without changing the
; already-confirmed empty-tree receipt. An independent job handle guards cleanup.
; ==============================================================================

#Requires AutoHotkey v2.0

_SRTDC_PauseAfterCapture(Action) {
	AssertEqual(0, _SR_ActiveTasks.Count, "fixture requires no foreign legacy tasks")
	AssertEqual(0, _SR_TreeOwnedTasks.Count, "fixture requires no foreign tree tasks")
	AssertEqual(0, _SR_PendingCallbacks.Count, "fixture requires no foreign deliveries")
	Handle := 0, State := 0, Claim := 0, GuardJob := 0
	Reads := [], Results := [], CallbackState := {Reentered: false}
	PreviousSuspend := A_IsSuspended
	PreviousCritical := Critical("On")
	OnAdopt(ObservedState, Native) {
		State := ObservedState
		GuardJob := _SRTOW_DuplicateNativeHandle(Native["JobHandle"])
	}
	ReadAndPause(Path) {
		Reads.Push(Path)
		Text := FileRead(Path)
		Suspend(true)
		return Text
	}
	OnDone(Code, Output, Diagnostic) {
		Results.Push({Code: Code, Output: Output, Diagnostic: Diagnostic, Paused: A_IsSuspended})
		_SR_TreePoll()
		_SR_Poll()
		CallbackState.Reentered := true
		if Action = "throw"
			throw Error("Injected tree callback failure after cross-poller reentry.")
	}
	try {
		Suspend(false)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut", A_ScriptDir . "\support\legacy_exit_code_child.ahk", "37"],
			OnDone, 0, OnAdopt, Action = "ceiling" ? 1 : 0)
		AssertTrue(Handle.start())
		AssertTrue(IsObject(State) && GuardJob != 0)
		AssertTrue(_SRTOW_WaitForExactProcessExit(State["ProcessHandle"]))
		Claim := _SR_TreeClaimTask(State, true)
		AssertTrue(_SR_TreeQuiesceNative(Claim, true))
		_SR_TreeRecordQuiesced(State, Claim)
		if Action = "ceiling"
			Suspend(true)
		AssertTrue(_SR_TreeFinishClaim(Claim, ReadAndPause))
		AssertTrue(A_IsSuspended)
		AssertEqual(0, Results.Length)
		AssertEqual(Action = "ceiling" ? 0 : 1, Reads.Length)
		if Reads.Length
			AssertEqual(State["TmpFile"], Reads[1], "verify the caught reader's argument outside its callback")
		AssertTrue(State["TreeQuiesced"] && !State["FinalizationPending"])
		AssertEqual(0, _SRTOW_ExactJobActiveProcessCount(GuardJob))
		for Key in ["ProcessHandle", "ThreadHandle", "JobHandle"]
			AssertEqual(0, Claim[Key], "paused delivery must retain no native " . Key)
		AssertFalse(DirExist(State["CaptureDir"]) != "")
		AssertTrue(_SR_PendingCallbacks.Has(ObjPtr(Claim)))
		AssertFalse(_SR_CompletionDispatch(Claim.Clone()))
		_SR_Poll()
		_SR_TreePoll()
		AssertEqual(0, Results.Length)
		AssertTrue(_SR_PollRunning, "the common delivery poller must survive the empty tree registry")
		Revoked := Action = "detach" || Action = "terminate"
		switch Action {
			case "detach":
				AssertTrue(Handle.detach())
			case "terminate":
				AssertTrue(Handle.terminate(), "notification deferral cannot invalidate native quiescence")
			case "request":
				AssertTrue(Handle.requestTerminate(), "a repeated request must preserve the pending notification")
		}
		Suspend(false)
		_SR_TreePoll()
		_SR_Poll()
		_SR_TreePoll()
		AssertEqual(Revoked ? 0 : 1, Results.Length)
		AssertFalse(_SR_PendingCallbacks.Has(ObjPtr(Claim)))
		AssertEqual(0, Claim["CompletionResult"])
		AssertEqual(Action = "ceiling" ? 0 : 1, Reads.Length, "delivery never rereads deleted output")
		if !Revoked {
			AssertTrue(CallbackState.Reentered)
			AssertFalse(Results[1].Paused)
			AssertEqual(Action = "ceiling" ? 63 : 37, Results[1].Code)
			AssertEqual(Action = "ceiling" ? "" : "legacy-exit-37", Results[1].Output)
			AssertEqual("", Results[1].Diagnostic)
		}
	} finally {
		try {
			if IsObject(Handle) {
				Handle.detach()
				AssertTrue(Handle.terminate(), "fixture must leave its native tree quiesced")
				_SR_Poll()
				_SR_TreePoll()
			}
			if IsObject(Claim)
				AssertFalse(_SR_PendingCallbacks.Has(ObjPtr(Claim)))
		} finally {
			try {
				if GuardJob {
					try {
						if _SRTOW_ExactJobActiveProcessCount(GuardJob) != 0 {
							AssertTrue(DllCall("Kernel32\TerminateJobObject", "Ptr", GuardJob,
								"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int"))
							Started := A_TickCount
							while _SRTOW_ExactJobActiveProcessCount(GuardJob) != 0 {
								AssertTrue(TickElapsed(Started) < SRTOW_EXIT_SIGNAL_SETTLE_MS)
								Sleep(SRTOW_PID_POLL_MS)
							}
						}
					} finally {
						AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", GuardJob, "Int"))
					}
				}
			} finally {
				Suspend(PreviousSuspend)
				Critical(PreviousCritical)
			}
		}
	}
}
for Action in ["resume", "detach", "terminate", "request", "throw", "ceiling"]
	Test("shell runner: tree capture pause preserves native and callback receipts " . Action . " (shell-tree-deferred-completion)",
		_SRTDC_PauseAfterCapture.Bind(Action))

; A completed native program cannot hide capture loss behind its genuine exit code.
_SRTDC_NativeCaptureRead(Vector) {
	AssertEqual(0, _SR_TreeOwnedTasks.Count, "fixture requires no foreign tree tasks")
	AssertEqual(0, _SR_PendingCallbacks.Count, "fixture requires no foreign deliveries")
	Handle := 0, State := 0, Claim := 0, GuardJob := 0, LockHandle := 0, LogContext := 0
	Results := [], NativeFailure := 0
	PreviousSuspend := A_IsSuspended
	PreviousCritical := Critical("On")
	OnAdopt(ObservedState, Native) {
		State := ObservedState
		GuardJob := _SRTOW_DuplicateNativeHandle(Native["JobHandle"])
	}
	OnDone(Code, Output, Diagnostic) {
		Results.Push({Code: Code, Output: Output, Diagnostic: Diagnostic})
	}
	try {
		Suspend(false)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut", A_ScriptDir . "\support\legacy_exit_code_child.ahk", "" . Vector.Code],
			OnDone, 0, OnAdopt, 0, Vector.Mode != "uncaptured", Vector.Private)
		AssertTrue(Handle.start(), "the actual capture child must start")
		AssertTrue(IsObject(State) && GuardJob != 0, "retain the actual launch and independent job query owner")
		AssertTrue(_SRTOW_WaitForExactProcessExit(State["ProcessHandle"]), "the exact child must really exit")
		Claim := _SR_TreeClaimTask(State, true)
		AssertTrue(_SR_TreeQuiesceNative(Claim, true), "native completion must settle before capture inspection")
		_SR_TreeRecordQuiesced(State, Claim)
		AssertEqual(Vector.Code, Claim["ExitCode"], "the fixture must retain the real completed child's exit code")
		CapturePath := State["TmpFile"]
		if Vector.Mode == "uncaptured" {
			AssertEqual("", CapturePath, "uncaptured launch has no expected capture")
		} else {
			AssertEqual("legacy-exit-" . Vector.Code, FileRead(CapturePath, "UTF-8"), "actual child output is readable before the fault")
			if Vector.Mode == "locked" {
				LockHandle := DllCall("Kernel32\CreateFileW", "Str", CapturePath,
					"UInt", 0x80000000, "UInt", 0, "Ptr", 0, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")
				AssertTrue(LockHandle != 0 && LockHandle != -1, "own a genuine exclusive capture handle")
				AssertTrue(FileExist(CapturePath) != "", "the locked source still exists")
			} else if Vector.Mode == "missing" {
				FileDelete(CapturePath)
			}
			if Vector.Mode == "locked" || Vector.Mode == "missing" {
				try FileRead(CapturePath, "UTF-8")
				catch OSError as Failure
					NativeFailure := Failure
				AssertTrue(IsObject(NativeFailure), "the actual native read must refuse before testing completion")
				AssertEqual(Vector.Mode == "locked" ? 32 : 2, NativeFailure.Number, "the fault must have its exact Win32 provenance")
			}
		}
		if Vector.Private
			LogContext := _SRCL_BeginLog()
		AssertTrue(_SR_TreeFinishClaim(Claim), "the genuine completion owner must settle once")
		AssertEqual(1, Results.Length, "native completion must deliver its one-shot callback")
		AssertEqual(Vector.Code, Results[1].Code, "capture failure must not invent or replace a process exit code")
		AssertEqual(Vector.Mode == "normal" ? "legacy-exit-" . Vector.Code : "", Results[1].Output)
		AssertTrue(State["TreeQuiesced"] && !State["FinalizationPending"])
		AssertEqual(0, _SRTOW_ExactJobActiveProcessCount(GuardJob), "the actual completed job must contain no process")
		for Key in ["ProcessHandle", "ThreadHandle", "JobHandle"]
			AssertEqual(0, Claim[Key], "completion must release its actual native " . Key)
		if LockHandle != 0 && LockHandle != -1 {
			AssertTrue(_SR_TreeCaptureDebts.Has(ObjPtr(Claim)), "a real sharing refusal retains capture cleanup ownership")
			AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", LockHandle, "Int"), "release the exact capture lock")
			LockHandle := 0
		}
		_SR_TreeDrainCaptureDebts()
		AssertFalse(_SR_TreeCaptureDebts.Has(ObjPtr(Claim)), "resource retry must retire the owned capture debt")
		if State["CaptureDir"] != ""
			AssertFalse(DirExist(State["CaptureDir"]) != "", "the owned capture directory must be retired")
		AssertTrue(Handle.terminate(), "an already-completed owner must remain safely retired")
		_SR_TreePoll()
		AssertEqual(1, Results.Length, "native cleanup retries cannot deliver completion again")
		if Vector.Private {
			AssertTrue(LogContext.Lines.Length > 0, "the genuine read refusal must be logged")
			for Line in LogContext.Lines
				AssertFalse(InStr(Line, CapturePath), "private diagnostics cannot expose the capture path")
		}
		_TestPrint("# tree-capture-read mode=" . Vector.Mode . " native_exit=" . Results[1].Code
			. " native_read_error=" . (IsObject(NativeFailure) ? NativeFailure.Number : 0)
			. " callback_diagnostic_present=" . (Results[1].Diagnostic != ""))
		AssertEqual(IsObject(NativeFailure) ? NativeFailure.Message : "", Results[1].Diagnostic,
			"the callback must receive the original native capture refusal instead of healthy empty output")
	} finally {
		try {
			if LockHandle != 0 && LockHandle != -1
				AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", LockHandle, "Int"))
		} finally {
			try {
				if IsObject(Handle) {
					Handle.detach()
					AssertTrue(Handle.terminate(), "the exact child must retire before fixture cleanup")
				}
				_SR_TreeDrainCaptureDebts()
			} finally {
				try {
					if GuardJob {
						AssertEqual(0, _SRTOW_ExactJobActiveProcessCount(GuardJob))
						AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", GuardJob, "Int"))
					}
				} finally {
					if IsObject(LogContext)
						_SRCL_EndLog(LogContext)
					Suspend(PreviousSuspend)
					Critical(PreviousCritical)
				}
			}
		}
	}
}
_SRTDC_ReadCases := [
	{Mode: "normal", Code: 0, Private: false},
	{Mode: "normal", Code: 37, Private: false},
	{Mode: "locked", Code: 0, Private: false},
	{Mode: "locked", Code: 37, Private: false},
	{Mode: "locked", Code: 0, Private: true},
	{Mode: "missing", Code: 0, Private: false},
	{Mode: "uncaptured", Code: 0, Private: false}
]
for _SRTDC_ReadVector in _SRTDC_ReadCases
	Test("shell runner: actual capture " . _SRTDC_ReadVector.Mode . " exit=" . _SRTDC_ReadVector.Code
		. " private=" . _SRTDC_ReadVector.Private . " preserves refusal provenance (shell-tree-read-refusal)",
		_SRTDC_NativeCaptureRead.Bind(_SRTDC_ReadVector))
