; tests/unit/test_shell_runner_launch_cleanup.ahk

; ==============================================================================
; MODULE: Native Launch Cleanup Tests
; DESCRIPTION:
; A refused stream close must not abandon an already created suspended child.
; Independent native handles distinguish cleanup from mere launch refusal.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../support/filesystem_write_lock.ahk

global SRTLC_ERROR_INVALID_HANDLE := 6

_SRTLC_CreateObserved(State, Application, Command, Flags, Startup, ProcessInfo) {
	PLC_CreateProcessWithInheritedHandles(Application, Command, Flags, Startup, ProcessInfo)
	State.Created := true
	try {
		State.Observer := _SRTOW_DuplicateNativeHandle(NumGet(ProcessInfo, 0, "Ptr"))
		if !State.Observer
			throw Error("Native process observer duplication failed")
	} catch as Err {
		; Setup owns a successful creation until it can return the native receipt.
		_SR_TreeQuiesceNative(Map("ProcessHandle", NumGet(ProcessInfo, 0, "Ptr"),
			"ThreadHandle", NumGet(ProcessInfo, A_PtrSize, "Ptr"), "JobHandle", 0,
			"Assigned", false), true)
		throw Err
	}
	return true
}

_SRTLC_CloseStream(State, Handle) {
	global SRTLC_ERROR_INVALID_HANDLE
	State.CloseCalls += 1
	if State.CloseCalls = State.FailAt {
		State.WaitBeforeFailure := _SRTOW_ExactProcessWait(State.Observer)
		DllCall("Kernel32\SetLastError", "UInt", SRTLC_ERROR_INVALID_HANDLE)
		return false
	}
	return DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int")
}

_SRTLC_DeleteCapture(Path) {
	global SRTOW_EXIT_SIGNAL_SETTLE_MS, SRTOW_PID_POLL_MS
	Started := A_TickCount
	loop {
		try {
			if FileExist(Path)
				FileDelete(Path)
			return
		} catch as Err {
			; The healthy job control can report zero before its capture unlocks.
			; This bounded fixture cleanup does not alter the prior exit assertions.
			if TickElapsed(Started) >= SRTOW_EXIT_SIGNAL_SETTLE_MS
				throw Err
		}
		Sleep(SRTOW_PID_POLL_MS)
	}
}

_SRTLC_Cleanup(Owner, State, JobObserver, Path) {
	global SRTOW_WAIT_TIMEOUT, SR_TREE_TERMINATE_EXIT_CODE
	Errors := []
	if Owner is Map {
		if Owner["Assigned"] && State.Observer {
			try {
				AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", State.Observer, "Int") != 0)
				State.Observer := 0
			} catch as Err
				Errors.Push(Err.Message)
		}
		try AssertTrue(_SR_TreeQuiesceNative(Owner, true), "native owner cleanup must complete")
		catch as Err
			Errors.Push(Err.Message)
	}
	if JobObserver {
		try AssertTrue(DllCall("Kernel32\TerminateJobObject", "Ptr", JobObserver,
			"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int") != 0)
		catch as Err
			Errors.Push(Err.Message)
		try AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", JobObserver, "Int") != 0)
		catch as Err
			Errors.Push(Err.Message)
	}
	if State.Observer {
		try {
			if _SRTOW_ExactProcessWait(State.Observer) = SRTOW_WAIT_TIMEOUT
				AssertTrue(DllCall("Kernel32\TerminateProcess", "Ptr", State.Observer,
					"UInt", SR_TREE_TERMINATE_EXIT_CODE, "Int") != 0)
			AssertTrue(_SRTOW_WaitForExactProcessExit(State.Observer))
		} catch as Err
			Errors.Push(Err.Message)
		try AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", State.Observer, "Int") != 0)
		catch as Err
			Errors.Push(Err.Message)
	}
	try _SRTLC_DeleteCapture(Path)
	catch as Err
		Errors.Push(Err.Message)
	return Errors
}

_SRTLC_StreamCloseOwnsChild(FailAt, OwnTree) {
	global SRTOW_WAIT_TIMEOUT, SR_TREE_TERMINATE_EXIT_CODE, SRTLC_ERROR_INVALID_HANDLE
	Path := _FSWL_Path()
	State := {Created: false, Observer: 0, CloseCalls: 0, FailAt: FailAt,
		WaitBeforeFailure: -1}
	Owner := 0
	JobObserver := 0
	Failure := 0
	AssertionFailure := 0
	try {
		try Owner := _SR_TreeCreateSuspended(A_ComSpec,
			'"' . A_ComSpec . '" /d /c exit 0', Path, OwnTree,
			_SRTLC_CreateObserved.Bind(State), _SRTLC_CloseStream.Bind(State))
		catch as Err
			Failure := Err
		AssertTrue(State.Created && State.Observer != 0, "a real suspended child must be observed")
		AssertEqual(FailAt ? FailAt : 2, State.CloseCalls)
		if FailAt {
			AssertTrue(Failure is Error)
			AssertContains(Failure.Message, "CloseHandle(" . (FailAt = 1 ? "input" : "output") . ") failed")
			AssertContains(Failure.Message, "Win32 " . SRTLC_ERROR_INVALID_HANDLE)
			AssertEqual(SRTOW_WAIT_TIMEOUT, State.WaitBeforeFailure,
				"the injected failure must occur while the exact child is still alive")
			AssertTrue(_SRTOW_WaitForExactProcessExit(State.Observer),
				"a refused stream close must terminate its already created child")
		} else {
			AssertEqual(0, Failure)
			AssertTrue(Owner is Map)
			AssertEqual(OwnTree, Owner["Assigned"])
			AssertEqual(SRTOW_WAIT_TIMEOUT, _SRTOW_ExactProcessWait(State.Observer))
			if OwnTree {
				JobObserver := _SRTOW_DuplicateNativeHandle(Owner["JobHandle"])
				AssertTrue(JobObserver != 0)
				; A retained process reference itself delays empty-job accounting.
				AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", State.Observer, "Int") != 0)
				State.Observer := 0
			}
			Quiesced := _SR_TreeQuiesceNative(Owner, true)
			AssertTrue(Quiesced, "healthy native cleanup: " . _DescribeValue(Owner["NativeErrors"]))
			if OwnTree
				AssertEqual(0, _SRTOW_ExactJobActiveProcessCount(JobObserver))
			else
				AssertTrue(_SRTOW_WaitForExactProcessExit(State.Observer))
		}
	} catch as Err {
		AssertionFailure := Err
		throw Err
	} finally {
		CleanupErrors := _SRTLC_Cleanup(Owner, State, JobObserver, Path)
		if CleanupErrors.Length {
			Detail := "Fixture cleanup: " . _DescribeValue(CleanupErrors)
			if AssertionFailure is Error
				AssertionFailure.Message .= "`n" . Detail
			else
				throw Error(Detail)
		}
	}
}

for OwnTree in [false, true] {
	for FailAt in [0, 1, 2]
		Test("shell launch: stream close=" . FailAt . " tree=" . OwnTree
			. " (shell-launch-close-cleanup)", _SRTLC_StreamCloseOwnsChild.Bind(FailAt, OwnTree))
}
