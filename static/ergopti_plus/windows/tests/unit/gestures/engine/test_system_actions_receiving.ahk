; tests/unit/gestures/engine/test_system_actions_receiving.ahk

; ==============================================================================
; MODULE: Recycle Bin Worker Receiving Scenarios
; DESCRIPTION:
; The native receiving scenario of WDS-002 (docs/audits/platform-parity/
; 2026-11-04-flows/windows-desktop): empty_trash starts a real hidden Windows
; PowerShell worker through the real SystemControl and ShellRunner, and its
; real exit reaches the action's error channel. The worker runs the real
; Clear-RecycleBin cmdlet, scoped to a drive letter this machine does not
; have, so it fails natively and never empties the signed-in user's bin; the
; control runs a worker that exits 0 without deleting anything.
; Registered as interactive: only the receiving runner selects them.
; ==============================================================================

#Requires AutoHotkey v2.0

; How long a real worker may take to start PowerShell and exit.
global PWRT_WORKER_TIMEOUT_MS := 60000

; The real SystemControl, refusing any command but the scenario's own, so the
; production Clear-RecycleBin of every drive can never run here.
class _PWRT_GuardedSystem {
	__New(Expected) {
		this.Real := SystemControl()
		this.Expected := Expected
		this.Starts := 0
	}
	SpawnObserved(Executable, Args, OnDone) {
		if (Args.Length == 0 || Args[Args.Length] !== this.Expected)
			throw Error("The receiving scenario refuses an unexpected worker command.")
		this.Starts += 1
		return this.Real.SpawnObserved(Executable, Args, OnDone)
	}
}

; A drive letter this machine does not have.
_PWRT_AbsentDrive() {
	Present := DriveGetList()
	loop parse "ZYXWVUTSRQPONMLKJIHG"
		if !InStr(Present, A_LoopField)
			return A_LoopField
	throw Error("Every drive letter from G to Z is in use.")
}

; Runs empty_trash with Script as its worker and waits for the worker's own
; terminal line. Returns the Recycle Bin log lines.
_PWRT_RunWorker(Script) {
	global GESTURE_SYS_EMPTY_TRASH_SCRIPT, PWRT_WORKER_TIMEOUT_MS
	ReceivingProfileRoot()
	Saved := GESTURE_SYS_EMPTY_TRASH_SCRIPT
	Lines := []
	GESTURE_SYS_EMPTY_TRASH_SCRIPT := Script
	LoggerSetTestSink((Line) => InStr(Line, "Recycle Bin") ? Lines.Push(Line) : 0)
	try {
		Sys := _PWRT_GuardedSystem(Script)
		AssertTrue(GestureSysEmptyTrash(Sys), "the real worker started")
		AssertEqual(1, Sys.Starts, "exactly one worker")
		Started := A_TickCount
		while (Lines.Length < 2 && A_TickCount - Started < PWRT_WORKER_TIMEOUT_MS)
			Sleep(50)
	} finally {
		LoggerClearTestSink()
		GESTURE_SYS_EMPTY_TRASH_SCRIPT := Saved
	}
	AssertEqual(2, Lines.Length, "the start line and the worker's own terminal line, nothing more")
	return Lines
}

; The real cmdlet fails after a successful launch: its exit code and its own
; message reach one ERROR line, and nothing claims the bin was emptied.
_PWRT_WorkerFailureIsReported() {
	Drive := _PWRT_AbsentDrive()
	Lines := _PWRT_RunWorker("Clear-RecycleBin -DriveLetter " . Drive . " -Force -ErrorAction Stop")
	AssertContains(Lines[1], "Emptying the Recycle Bin.", "the launch is reported as a start only")
	AssertContains(Lines[2], "[ERROR]", "the native failure is an error")
	AssertContains(Lines[2], "could not be emptied: its PowerShell worker exited with 1", "with the worker's real exit code")
	AssertContains(Lines[2], Drive, "and the cmdlet's own message")
	for Line in Lines
		AssertFalse(InStr(Line, "Recycle Bin emptied."), "a failed worker is never reported as an emptied bin")
}
Test("system actions receiving: a real Clear-RecycleBin failure after launch reaches the error channel (phys-w-receiving-recycle-bin)",
	_PWRT_WorkerFailureIsReported, true)

; Control: a real worker that exits 0 is reported as done, with no error.
_PWRT_WorkerSuccessIsReported() {
	Lines := _PWRT_RunWorker("$null = Get-Command Clear-RecycleBin -ErrorAction Stop")
	AssertContains(Lines[2], "Recycle Bin emptied.", "a zero exit is the completion line")
	for Line in Lines
		AssertFalse(InStr(Line, "[ERROR]"), "a zero exit raises no error")
}
Test("system actions receiving: a real worker exiting 0 is reported as done (phys-w-receiving-recycle-bin)",
	_PWRT_WorkerSuccessIsReported, true)
