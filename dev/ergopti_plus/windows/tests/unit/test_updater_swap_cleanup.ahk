; tests/unit/test_updater_swap_cleanup.ahk

; ==============================================================================
; MODULE: Native Updater Fixture Cleanup Tests
; DESCRIPTION: Swap and parent-crash cleanup failures cannot produce green tests.
; ==============================================================================

#Requires AutoHotkey v2.0

_USCL_LockFixture(State, PrimaryFailure, TestDir) {
	_USTX_LockCanceledFixtureForCleanup(State, TestDir)
	if PrimaryFailure
		throw Error("synthetic primary transaction failure")
}

_USCL_RefusedCleanup(Mode, PrimaryFailure := false) {
	State := { Handle: 0, TestDir: "" }
	Failure := 0
	try {
		try {
			Hook := _USCL_LockFixture.Bind(State, PrimaryFailure)
			if Mode = "swap"
				_USTX_RunSwapCase(true, false, false, Hook)
			else
				_USTX_ParentExitBeforeFinalExitAbandonsWithoutMutation(Hook)
		} catch as Err {
			Failure := Err
		}
		Assert(State.Handle and State.Handle != -1, "the real transaction must reach the cleanup lock")
		Assert(Failure is Error, "a locked fixture must not report successful cleanup")
		AssertContains(Failure.Message, "Updater fixture directory cleanup failed:")
		if PrimaryFailure
			AssertContains(Failure.Message, "synthetic primary transaction failure",
				"cleanup must retain the original transaction diagnosis")
		Assert(DirExist(State.TestDir), "the refused cleanup must retain the exact fixture directory")
	} finally {
		if State.Handle and State.Handle != -1
			Assert(DllCall("CloseHandle", "Ptr", State.Handle, "Int"))
		if State.TestDir != "" and DirExist(State.TestDir)
			DirDelete(State.TestDir, true)
	}
}
for Mode in ["swap", "parent"]
	Test("updater fixture: refused " . Mode . " cleanup is visible (updater-sibling-cleanup)",
		_USCL_RefusedCleanup.Bind(Mode))
Test("updater fixture: cleanup retains primary swap failure (updater-sibling-cleanup)",
	_USCL_RefusedCleanup.Bind("swap", true))

_USCL_ZeroTimeoutObservesHandle() {
	Handle := DllCall("CreateEventW", "Ptr", 0, "Int", true, "Int", false, "Ptr", 0, "Ptr")
	AssertTrue(Handle != 0, "the fixture must own a native manual-reset event")
	try {
		AssertFalse(_USTX_WaitForEvent(Handle, 0), "an unsignaled event must fail an immediate poll")
		AssertTrue(DllCall("SetEvent", "Ptr", Handle, "Int"))
		AssertTrue(_USTX_WaitForEvent(Handle, 0),
			"a zero timeout must still observe an already signaled native handle")
		AssertFalse(_USTX_WaitForEvent(0, 0), "an invalid handle must not look terminated")
	} finally AssertTrue(DllCall("CloseHandle", "Ptr", Handle, "Int"))
}
Test("updater fixture: zero-timeout waits observe native state (updater-fixture-zero-wait)",
	_USCL_ZeroTimeoutObservesHandle)
