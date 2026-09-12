; tests/unit/test_shell_runner_native_exit_code.ahk

; ==============================================================================
; MODULE: Native Exit Code Tests
; DESCRIPTION:
; AHK-908: reopening a collected PID silently replaced a child's failure with
; success. Exercise the public launcher without a second retained process handle.
; ==============================================================================

#Requires AutoHotkey v2.0

_SRNE_ExitCode(ExpectedCode, SuspendCompletion := false, Tree := false) {
	static TimeoutMs := 5000, PollMs := 10
	Receipt := {Calls: 0, Code: -1, Output: "", Errors: ""}
	OnDone(Code, Output, Errors) {
		Receipt.Calls += 1
		Receipt.Code := Code
		Receipt.Output := Output
		Receipt.Errors := Errors
	}
	WasSuspended := A_IsSuspended
	Spawn := Tree ? ShellRunner_SpawnTreeOwned : ShellRunner_Spawn
	Poll := Tree ? _SR_TreePoll : _SR_Poll
	Handle := Spawn.Call(A_AhkPath,
		["/ErrorStdOut", A_ScriptDir . "\support\legacy_exit_code_child.ahk", ExpectedCode . ""], OnDone)
	try {
		Suspend(SuspendCompletion)
		AssertTrue(Handle.start(), "the native exit-code child must start")
		if SuspendCompletion {
			; Do not hold another process handle: that would keep the old PID query
			; working and mask the defect this test is meant to expose.
			Started := A_TickCount
			while ProcessExist(Handle.processId()) && TickElapsed(Started) < TimeoutMs
				Sleep(PollMs)
			AssertFalse(ProcessExist(Handle.processId()), "the child must exit while suspended")
			Poll.Call()
			AssertEqual(0, Receipt.Calls, "suspension must defer the completion callback")
			Suspend(false)
		}
		Started := A_TickCount
		while !Receipt.Calls && TickElapsed(Started) < TimeoutMs
			Sleep(PollMs)
		AssertEqual(1, Receipt.Calls, "the child must complete exactly once within the test budget")
		AssertEqual("legacy-exit-" . ExpectedCode, Receipt.Output,
			"the callback must belong to the intended native child")
		AssertEqual("", Receipt.Errors)
		AssertEqual(ExpectedCode, Receipt.Code, "a native failure must not become successful completion")
		Poll.Call()
		Poll.Call()
		AssertEqual(1, Receipt.Calls, "duplicate polling must not dispatch completion twice")
	} finally {
		; The self-exiting child remains owned by the poller on a test timeout.
		; Revoke only this callback, without terminating a potentially reused PID.
		try Handle.detach()
		finally Suspend(WasSuspended)
	}
}

for Code in [0, 37, 259]
	Test("shell runner: preserves native exit " . Code . " (shell-native-exit-code)",
		_SRNE_ExitCode.Bind(Code))
Test("shell runner: retains failure across suspension (shell-native-exit-code)",
	_SRNE_ExitCode.Bind(37, true))

for Code in [0, 37, 259]
	Test("shell runner: preserves tree exit " . Code . " (shell-tree-native-exit-code)",
		_SRNE_ExitCode.Bind(Code, false, true))
Test("shell runner: retains tree exit 259 across suspension (shell-tree-native-exit-code)",
	_SRNE_ExitCode.Bind(259, true, true))
