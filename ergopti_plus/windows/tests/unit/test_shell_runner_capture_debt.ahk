; tests/unit/test_shell_runner_capture_debt.ahk

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
