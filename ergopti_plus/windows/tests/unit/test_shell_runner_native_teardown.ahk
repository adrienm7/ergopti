; tests/unit/test_shell_runner_native_teardown.ahk

; ==============================================================================
; MODULE: Legacy Native Teardown Tests
; DESCRIPTION:
; AHK-907: refused termination must retain the exact process and capture owner.
; A separate guardian job cleans up the child even when production cleanup lies.
; ==============================================================================

#Requires AutoHotkey v2.0

_SRNT_RefusedTermination(Route := "published-failure", Reenter := false) {
	global _SR_TaskCounter
	CaptureDir := _SR_AcquireCaptureDirectory()
	CapturePath := CaptureDir . "output.tmp"
	Guardian := 0, Native := 0, State := 0, Claim := 0, CollisionState := 0
	PreviousCritical := A_IsCritical
	Calls := {Tree: 0, Direct: 0, Done: 0, TreePid: 0, DirectHandle: 0,
		Reentry: true, AcceptedTree: 0, AcceptedDirect: 0}
	RejectTree(Pid) {
		Calls.Tree += 1
		Calls.TreePid := Pid
		if Reenter
			Calls.Reentry := _SR_LegacyTerminateClaim(Claim, true, RejectTree, RejectDirect)
		throw Error("Injected legacy tree termination refusal.")
	}
	RejectDirect(ProcessHandle) {
		Calls.Direct += 1
		Calls.DirectHandle := ProcessHandle
		throw Error("Injected legacy direct termination refusal.")
	}
	OnDone(*) {
		Calls.Done += 1
	}
	AcceptTree(Pid) {
		Calls.AcceptedTree += 1
		return Pid = Guardian["Pid"]
	}
	AcceptDirect(ProcessHandle) {
		Calls.AcceptedDirect += 1
		if ProcessHandle != LegacyProcessHandle
			return false
		return DllCall("Kernel32\TerminateProcess", "Ptr", ProcessHandle,
			"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int")
	}
	try {
		Guardian := _SR_TreeCreateSuspended(A_AhkPath,
			_SR_BuildDirectCommandLine(A_AhkPath,
				["/ErrorStdOut", A_ScriptDir . "\support\legacy_cleanup_child.ahk"]), CapturePath, true)
		Native := Map("Pid", Guardian["Pid"],
			"ProcessHandle", _SRTOW_DuplicateNativeHandle(Guardian["ProcessHandle"]))
		AssertTrue(Native["ProcessHandle"] != 0, "legacy fixture must own its own native capability")
		LegacyProcessHandle := Native["ProcessHandle"]
		AssertTrue(DllCall("Kernel32\ResumeThread", "Ptr", Guardian["ThreadHandle"], "UInt") != 0xFFFFFFFF)
		AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(Guardian["ProcessHandle"]),
			"the independently observed child must still be running")
		Critical("On")
		State := _SR_LegacyNewState(++_SR_TaskCounter, CapturePath, OnDone)
		State["CaptureDir"] := CaptureDir
		State["Native"] := Native
		_SR_LegacyBeginStart(State)
		if Route = "private-failure" {
			Claim := _SR_LegacyFailStart(State, Guardian["Pid"])
		} else if Route = "launch-cancel" {
			_SR_LegacyClaimTerminate(State)
			Claim := _SR_LegacyPublishStart(State, Guardian["Pid"])["Claim"]
		} else if Route = "collision" {
			CollisionState := _SR_LegacyNewState(State["TaskId"], "", 0)
			_SR_LegacyBeginStart(CollisionState)
			AssertTrue(_SR_LegacyPublishStart(CollisionState, 424242)["Published"])
			Claim := _SR_LegacyPublishStart(State, Guardian["Pid"])["Claim"]
		} else {
			AssertTrue(_SR_LegacyPublishStart(State, Guardian["Pid"])["Published"])
			Claim := Route = "terminate" ? _SR_LegacyClaimTerminate(State)
				: _SR_LegacyFailStart(State, Guardian["Pid"])
		}
		Receipt := _SR_LegacyTerminateClaim(Claim, true, RejectTree, RejectDirect)
		Alive := _SRTOW_ExactProcessWait(Guardian["ProcessHandle"]) = SRTOW_WAIT_TIMEOUT
		FileAppend(Format("# legacy teardown receipt={1}, alive={2}, finished={3}, native_owner={4}`n",
			Receipt, Alive, Claim["Finished"], _SR_LegacyReleaseOwners.Has(ObjPtr(Claim))), "*")
		AssertTrue(Alive, "the exact child must survive the two injected refusals")
		AssertEqual(1, Calls.Tree)
		AssertEqual(1, Calls.Direct)
		AssertEqual(Guardian["Pid"], Calls.TreePid, "tree request must target the fixture's child")
		AssertEqual(LegacyProcessHandle, Calls.DirectHandle, "direct request must use the exact capability")
		if Reenter
			AssertFalse(Calls.Reentry, "reentrant teardown cannot take a busy cleanup owner")
		AssertFalse(Receipt, "refused termination must not report completed cleanup")
		AssertFalse(Claim["Finished"], "physical teardown cannot be finalized while the child is alive")
		AssertTrue(_SR_LegacyReleaseOwners.Has(ObjPtr(Claim)), "refusal must retain its retry owner")
		AssertTrue(Native["ProcessHandle"] != 0, "refusal must retain the exact native capability")
		AssertTrue(FileExist(CapturePath) != "", "a live writer must retain its private capture")
		AssertEqual(0, Calls.Done, "failed start cleanup must not dispatch stale callbacks")
		AssertFalse(_SR_LegacyTerminateClaim(Claim.Clone(), true, RejectTree, RejectDirect),
			"copying the claim cannot acquire its physical resources")
		AssertEqual(1, Calls.Tree, "a copied claim must not request another tree kill")
		AssertEqual(1, Calls.Direct, "a copied claim must not request another direct kill")
		if IsObject(CollisionState)
			AssertEqual(ObjPtr(CollisionState), ObjPtr(_SR_ActiveTasks[State["TaskId"]]),
				"private cleanup must preserve the unrelated live identity with the same task ID")
		Started := A_TickCount
		loop {
			if _SR_LegacyTerminateClaim(Claim, true, AcceptTree, AcceptDirect)
				break
			AssertTrue(TickElapsed(Started) < SRTOW_EXIT_SIGNAL_SETTLE_MS,
				"accepted native termination must eventually settle its cleanup debt")
			Sleep(SRTOW_PID_POLL_MS)
		}
		AssertEqual(SRTOW_WAIT_OBJECT_0, _SRTOW_ExactProcessWait(Guardian["ProcessHandle"]),
			"a successful cleanup receipt must follow actual process exit")
		AssertTrue(Claim["Finished"] && Claim["TeardownComplete"])
		AssertFalse(_SR_LegacyReleaseOwners.Has(ObjPtr(Claim)))
		AssertEqual(0, Native["ProcessHandle"])
		AssertFalse(FileExist(CapturePath) != "")
		AssertFalse(DirExist(CaptureDir) != "")
		AssertTrue(_SR_LegacyTerminateClaim(Claim, true, RejectTree, RejectDirect),
			"a completed cleanup has an idempotent success receipt")
		AssertEqual(1, Calls.AcceptedTree)
		AssertEqual(1, Calls.AcceptedDirect)
		AssertEqual(0, Calls.Done)
	} finally {
		; Retire only fixture-owned entries before independently cleaning native state
		if IsObject(State) && _SR_ActiveTasks.Has(State["TaskId"])
			&& ObjPtr(_SR_ActiveTasks[State["TaskId"]]) = ObjPtr(State)
			_SR_ActiveTasks.Delete(State["TaskId"])
		if IsObject(Claim) && _SR_LegacyReleaseOwners.Has(ObjPtr(Claim))
			_SR_LegacyReleaseOwners.Delete(ObjPtr(Claim))
		if IsObject(CollisionState) && _SR_ActiveTasks.Has(CollisionState["TaskId"])
			&& ObjPtr(_SR_ActiveTasks[CollisionState["TaskId"]]) = ObjPtr(CollisionState)
			_SR_ActiveTasks.Delete(CollisionState["TaskId"])
		Critical(PreviousCritical)
		try {
			if IsObject(Guardian) {
				AssertTrue(DllCall("Kernel32\TerminateJobObject", "Ptr", Guardian["JobHandle"],
					"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int"), "the independent guardian must accept cleanup")
				AssertTrue(_SRTOW_WaitForExactProcessExit(Guardian["ProcessHandle"]),
					"the independent guardian must observe the child's exit")
			}
		} finally {
			try {
				if IsObject(Native) && Native["ProcessHandle"] {
					AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Native["ProcessHandle"], "Int"))
					Native["ProcessHandle"] := 0
				}
			} finally {
				if IsObject(Guardian)
					AssertTrue(_SR_TreeQuiesceNative(Guardian, true), "the guardian must release its native resources")
				_SRTLC_DeleteCapture(CapturePath)
				if DirExist(CaptureDir)
					DirDelete(CaptureDir)
			}
		}
	}
}
for Route in ["published-failure", "private-failure", "terminate", "launch-cancel", "collision"]
	Test("shell runner: refused termination retains physical ownership " . Route . " (shell-native-teardown)",
		_SRNT_RefusedTermination.Bind(Route))
Test("shell runner: teardown excludes reentrant requests (shell-native-teardown)",
	_SRNT_RefusedTermination.Bind("published-failure", true))
