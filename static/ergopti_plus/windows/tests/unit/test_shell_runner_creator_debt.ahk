; tests/unit/test_shell_runner_creator_debt.ahk

; ==============================================================================
; MODULE: Legacy Creator Failure Ownership Tests
; DESCRIPTION:
; AHK-907: adopt both native capabilities before resume or thread-close can fail.
; An independent process observer obtained inside the fault seam guards cleanup.
; ==============================================================================

#Requires AutoHotkey v2.0

_SRCR_CreatorRefusal(RefuseResume, RefuseObserver := false) {
	global _SR_TaskCounter
	CaptureDir := _SR_AcquireCaptureDirectory()
	CapturePath := CaptureDir . "output.tmp"
	State := _SR_LegacyNewState(++_SR_TaskCounter, CapturePath, 0)
	State["CaptureDir"] := CaptureDir
	Claim := 0, Native := 0, Observer := 0, ObservedThread := 0, Diagnostic := ""
	Observe(ThreadHandle) {
		ObservedThread := ThreadHandle
		if RefuseObserver
			throw Error("Injected independent observer admission refusal.")
		ProcessId := DllCall("Kernel32\GetProcessIdOfThread", "Ptr", ThreadHandle, "UInt")
		if !ProcessId
			throw Error("Creator fixture cannot identify its exact child thread.")
		; The live thread pins this PID while the independent observer is acquired
		Observer := DllCall("Kernel32\OpenProcess", "UInt", 0x101001,
			"Int", false, "UInt", ProcessId, "Ptr")
		if !Observer
			throw Error("Creator fixture cannot acquire its independent observer.")
	}
	RejectResume(ThreadHandle) {
		Observe(ThreadHandle)
		return 0xFFFFFFFF
	}
	RejectClose(ThreadHandle) {
		Observe(ThreadHandle)
		return false
	}
	RejectTermination(*) {
		return false
	}
	PreviousCritical := Critical("On")
	try {
		_SR_LegacyBeginStart(State)
		try _SR_LegacyCreateDirect(A_AhkPath,
			_SR_BuildDirectCommandLine(A_AhkPath,
				["/ErrorStdOut", A_ScriptDir . "\support\legacy_cleanup_child.ahk"]),
			CapturePath, State, RefuseResume ? RejectResume : 0, RefuseResume ? 0 : RejectClose)
		catch as Err
			Diagnostic := Err.Message
		if RefuseObserver {
			AssertContains(Diagnostic, "Injected independent observer admission refusal.")
			AssertTrue(IsObject(State["Native"]), "fallback cleanup needs the creator's exact capability")
			AssertTrue(State["Native"]["ProcessHandle"] != 0)
			AssertEqual(ObservedThread, State["Native"]["ThreadHandle"])
			AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(State["Native"]["ProcessHandle"]),
				"observer refusal must leave a real live child for the fallback cleanup")
			; The finally path must terminate, observe exit and close both capabilities
			return
		}
		AssertContains(Diagnostic, RefuseResume ? "ResumeThread failed" : "CloseHandle(ThreadHandle) failed",
			"the intended native boundary must report refusal")
		AssertTrue(Observer != 0)
		AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(Observer))
		Native := State["Native"]
		AssertTrue(IsObject(Native), "creator failure must leave its native owner reachable")
		AssertTrue(Native["ProcessHandle"] != 0)
		AssertEqual(ObservedThread, Native["ThreadHandle"], "a refused close must retain the original thread")
		AssertEqual(Native["Pid"], State["Pid"], "failure before return must still publish the owned PID")
		Claim := _SR_LegacyFailStart(State, 0)
		AssertEqual(ObjPtr(Native), ObjPtr(Claim["Native"]))
		AssertEqual(Native["Pid"], Claim["Pid"])
		AssertFalse(_SR_LegacyTerminateClaim(Claim, true, RejectTermination, RejectTermination))
		AssertTrue(_SR_LegacyReleaseOwners.Has(ObjPtr(Claim)))
		AssertTrue(DllCall("Kernel32\TerminateProcess", "Ptr", Observer,
			"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int"))
		AssertTrue(_SRTOW_WaitForExactProcessExit(Observer))
		AssertTrue(_SR_LegacyTerminateClaim(Claim, true, RejectTermination, RejectTermination))
		AssertEqual(0, Native["ProcessHandle"])
		AssertEqual(0, Native["ThreadHandle"])
		AssertFalse(_SR_LegacyReleaseOwners.Has(ObjPtr(Claim)))
		AssertFalse(DirExist(CaptureDir) != "")
	} finally {
		try {
			CleanupNative := IsObject(Native) ? Native : State["Native"]
			CleanupProcess := Observer ? Observer
				: IsObject(CleanupNative) ? CleanupNative["ProcessHandle"] : 0
			try {
				if CleanupProcess && _SRTOW_ExactProcessWait(CleanupProcess) = SRTOW_WAIT_TIMEOUT {
					AssertTrue(DllCall("Kernel32\TerminateProcess", "Ptr", CleanupProcess,
						"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int"))
					AssertTrue(_SRTOW_WaitForExactProcessExit(CleanupProcess))
				}
			} finally {
				if Observer
					AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Observer, "Int"))
			}
		} finally {
			try {
				if !IsObject(Native)
					Native := State["Native"]
				if IsObject(Native) {
					for Key in ["ThreadHandle", "ProcessHandle"] {
						if Native[Key] {
							AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Native[Key], "Int"))
							Native[Key] := 0
						}
					}
				}
				if IsObject(Claim) && _SR_LegacyReleaseOwners.Has(ObjPtr(Claim))
					_SR_LegacyReleaseOwners.Delete(ObjPtr(Claim))
				_SRTLC_DeleteCapture(CapturePath)
				if DirExist(CaptureDir)
					DirDelete(CaptureDir)
			} finally {
				Critical(PreviousCritical)
			}
		}
	}
}
Test("shell runner: creator retains suspended child after resume refusal (shell-creator-debt)",
	_SRCR_CreatorRefusal.Bind(true))
Test("shell runner: creator retains running child after thread close refusal (shell-creator-debt)",
	_SRCR_CreatorRefusal.Bind(false))
Test("shell runner: creator fixture cleans suspended child when observer admission fails (shell-creator-debt)",
	_SRCR_CreatorRefusal.Bind(true, true))
Test("shell runner: creator fixture cleans running child when observer admission fails (shell-creator-debt)",
	_SRCR_CreatorRefusal.Bind(false, true))
