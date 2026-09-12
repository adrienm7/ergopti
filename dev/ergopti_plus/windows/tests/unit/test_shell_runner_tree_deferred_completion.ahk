; tests/unit/test_shell_runner_tree_deferred_completion.ahk

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
