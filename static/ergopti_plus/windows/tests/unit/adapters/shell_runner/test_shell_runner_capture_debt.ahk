; tests/unit/adapters/shell_runner/test_shell_runner_capture_debt.ahk

; ==============================================================================
; MODULE: Legacy Capture Cleanup Debt Tests
; DESCRIPTION:
; AHK-907: real Windows sharing refusal must retain capture cleanup ownership.
; Resource-only retries must neither reread output nor redeliver completion.
; ==============================================================================

#Requires AutoHotkey v2.0

_SRCD_CaptureRefusal(Complete, RefuseRead := false) {
	global _SR_TaskCounter
	CaptureDir := _SR_AcquireCaptureDirectory()
	CapturePath := CaptureDir . "output.tmp"
	LockHandle := 0, Claim := 0
	Calls := []
	OnDone(Code, Output, Diagnostic) {
		Calls.Push({Code: Code, Output: Output, Diagnostic: Diagnostic})
	}
	PreviousCritical := Critical("On")
	try {
		FileAppend("captured output", CapturePath, "UTF-8-RAW")
		; Omit FILE_SHARE_DELETE; optionally also deny the completion reader
		LockHandle := DllCall("Kernel32\CreateFileW", "WStr", CapturePath,
			"UInt", 0x80000000, "UInt", RefuseRead ? 0 : 3, "Ptr", 0,
			"UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")
		AssertTrue(LockHandle != -1 && LockHandle != 0, "fixture must hold a real capture lock")
		State := _SR_LegacyNewState(++_SR_TaskCounter, CapturePath, OnDone)
		State["CaptureDir"] := CaptureDir
		_SR_LegacyBeginStart(State)
		if Complete {
			AssertTrue(_SR_LegacyPublishStart(State, 424242)["Published"])
			Claim := _SR_LegacyClaimCompletion(State["TaskId"], State)
			AssertTrue(_SR_LegacyFinishCompletion(Claim, 37))
			AssertEqual(1, Calls.Length)
			AssertEqual(37, Calls[1].Code)
			AssertEqual(RefuseRead ? "" : "captured output", Calls[1].Output)
			AssertEqual(RefuseRead, Calls[1].Diagnostic != "",
				"read refusal must be reported to the one-shot completion callback")
		} else {
			; No process was created, so cleanup must never target a synthetic PID
			Claim := _SR_LegacyFailStart(State, 0)
			AssertFalse(_SR_LegacyTerminateClaim(Claim, true))
			AssertFalse(Claim["Finished"])
		}
		AssertTrue(Claim["CapturePending"])
		AssertTrue(_SR_LegacyReleaseOwners.Has(ObjPtr(Claim)))
		AssertTrue(FileExist(CapturePath) != "")
		AssertFalse(_SR_LegacyDrainReleases(), "persistent sharing refusal remains pending")
		AssertTrue(_SR_LegacyReleaseOwners.Has(ObjPtr(Claim)))
		AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", LockHandle, "Int"))
		LockHandle := 0
		AssertTrue(_SR_LegacyDrainReleases(), "retry must settle the released capture lock")
		AssertFalse(Claim["CapturePending"])
		AssertFalse(_SR_LegacyReleaseOwners.Has(ObjPtr(Claim)))
		AssertFalse(FileExist(CapturePath) != "")
		AssertFalse(DirExist(CaptureDir) != "")
		AssertTrue(_SR_LegacyDrainReleases())
		AssertEqual(Complete ? 1 : 0, Calls.Length, "cleanup retries never deliver another callback")
		if !Complete
			AssertTrue(Claim["Finished"] && Claim["TeardownComplete"])
	} finally {
		try {
			if LockHandle && LockHandle != -1
				AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", LockHandle, "Int"))
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
Test("shell runner: failed start retains locked capture cleanup (shell-capture-debt)",
	_SRCD_CaptureRefusal.Bind(false))
Test("shell runner: completion retries locked capture without duplicate callback (shell-capture-debt)",
	_SRCD_CaptureRefusal.Bind(true))
Test("shell runner: completion reports denied output read and retries cleanup (shell-capture-debt)",
	_SRCD_CaptureRefusal.Bind(true, true))

; Actual process completion must preserve capture loss as a distinct diagnostic.
_SRCD_ActualNativeCapture(Vector) {
	AssertEqual(0, _SR_ActiveTasks.Count, "private native fixture requires no foreign legacy task")
	AssertEqual(0, _SR_LegacyReleaseOwners.Count, "private fixture requires no foreign cleanup owner")
	Handle := 0, State := 0, Guard := 0, LockHandle := 0, NativeFailure := 0
	Results := []
	PreviousSuspend := A_IsSuspended
	PreviousCritical := Critical("On")
	OnDone(Code, Output, Diagnostic) {
		Results.Push({Code: Code, Output: Output, Diagnostic: Diagnostic})
	}
	try {
		Suspend(false)
		Handle := ShellRunner_Spawn(A_AhkPath,
			["/ErrorStdOut", A_ScriptDir . "\support\legacy_exit_code_child.ahk", "" . Vector.Code], OnDone)
		AssertTrue(Handle.start(), "the real legacy native child must start")
		AssertEqual(1, _SR_ActiveTasks.Count, "the actual launched native state must be published once")
		for TaskId, Candidate in _SR_ActiveTasks
			State := Candidate
		AssertTrue(State is Map && State["Native"] is Map)
		Native := State["Native"]
		Guard := _SRTOW_DuplicateNativeHandle(Native["ProcessHandle"])
		AssertTrue(Guard != 0, "retain an independent native process observation capability")
		AssertTrue(_SRTOW_WaitForExactProcessExit(Guard), "the original actual child must finish")
		AssertEqual(Vector.Code, _SR_LegacyReadExitCode(Guard), "retain the actual native code before any completion")
		Capture := State["TmpFile"]
		AssertEqual("legacy-exit-" . Vector.Code, FileRead(Capture, "UTF-8"), "the real native child output is initially readable")
		if Vector.Mode == "locked" {
			LockHandle := DllCall("Kernel32\CreateFileW", "Str", Capture,
				"UInt", 0x80000000, "UInt", 0, "Ptr", 0, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")
			AssertTrue(LockHandle != 0 && LockHandle != -1, "own a genuine native sharing refusal")
		} else if Vector.Mode == "missing" {
			FileDelete(Capture)
		}
		if Vector.Mode != "normal" {
			try FileRead(Capture, "UTF-8")
			catch OSError as NativeError
				NativeFailure := NativeError
			AssertTrue(IsObject(NativeFailure), "genuine native read refusal is a precondition")
			AssertEqual(Vector.Mode == "locked" ? 32 : 2, NativeFailure.Number, "the actual failure has its declared Win32 provenance")
		}
		_SR_Poll()
		AssertEqual(1, Results.Length, "the real public poller must deliver exactly once")
		AssertEqual(Vector.Code, Results[1].Code, "completion must preserve the original native process code")
		AssertEqual(Vector.Mode == "normal" ? "legacy-exit-" . Vector.Code : "", Results[1].Output)
		AssertEqual(0, Native["ProcessHandle"], "the original process query capability must retire")
		AssertEqual(0, DllCall("Kernel32\WaitForSingleObject", "Ptr", Guard, "UInt", 0, "UInt"), "the independent native owner confirms actual exit")
		AssertEqual(0, _SR_ActiveTasks.Count, "the actual completed registry entry must retire")
		if LockHandle != 0 && LockHandle != -1 {
			AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", LockHandle, "Int"))
			LockHandle := 0
		}
		AssertTrue(_SR_LegacyDrainReleases(), "released sharing refusal must settle actual cleanup debt")
		_SR_Poll()
		AssertEqual(0, _SR_LegacyReleaseOwners.Count)
		AssertEqual(1, Results.Length, "cleanup cannot deliver the completion twice")
		AssertFalse(DirExist(State["CaptureDir"]) != "", "the actual owned capture directory must retire")
		_TestPrint("# legacy-native-capture mode=" . Vector.Mode . " native_exit=" . Results[1].Code
			. " native_read_error=" . (IsObject(NativeFailure) ? NativeFailure.Number : 0)
			. " callback_diagnostic_present=" . (Results[1].Diagnostic != ""))
		AssertEqual(IsObject(NativeFailure) ? NativeFailure.Message : "", Results[1].Diagnostic,
			"the original native capture refusal must reach the actual legacy callback")
	} finally {
		try {
			if LockHandle != 0 && LockHandle != -1
				AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", LockHandle, "Int"))
		} finally {
			try {
				if IsObject(Handle) {
					if Results.Length == 0
					Handle.detach()
					if Guard && DllCall("Kernel32\WaitForSingleObject", "Ptr", Guard, "UInt", 0, "UInt") == 258 {
						AssertTrue(DllCall("Kernel32\TerminateProcess", "Ptr", Guard, "UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int"), "cleanup may target only its exact retained process")
						AssertTrue(_SRTOW_WaitForExactProcessExit(Guard))
					}
					_SR_Poll()
					_SR_LegacyDrainReleases()
				}
			} finally {
				try {
					if Guard
						AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Guard, "Int"))
				} finally {
					Suspend(PreviousSuspend)
					Critical(PreviousCritical)
				}
			}
		}
	}
}
_SRCD_ActualCases := [
	{Mode: "normal", Code: 0}, {Mode: "normal", Code: 37},
	{Mode: "locked", Code: 0}, {Mode: "locked", Code: 37},
	{Mode: "missing", Code: 0}, {Mode: "missing", Code: 37}
]
for _SRCD_ActualVector in _SRCD_ActualCases
	Test("shell runner: actual legacy capture " . _SRCD_ActualVector.Mode . " exit=" . _SRCD_ActualVector.Code . " (legacy-native-capture-loss)", _SRCD_ActualNativeCapture.Bind(_SRCD_ActualVector))
