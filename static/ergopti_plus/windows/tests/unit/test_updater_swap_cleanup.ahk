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

_USCL_TreeWaitObservesNativeState() {
	Path := _FSWL_Path()
	Owner := 0
	Job := 0
	try {
		AssertThrows(() => _USTX_WaitForTreeExit(0, 0),
			"failed accounting must not report an empty tree")
		AssertThrows(() => _USTX_WaitForTreeExit(-1, 0),
			"a native query failure must not report an empty tree")
		Command := '"' . A_AhkPath . '" /ErrorStdOut "' . A_ScriptDir
			. '\support\legacy_exit_code_child.ahk" 0'
		Owner := _SR_TreeCreateSuspended(A_AhkPath, Command, Path)
		Job := _SRTOW_DuplicateNativeHandle(Owner["JobHandle"])
		AssertTrue(Job != 0)
		AssertFalse(_USTX_WaitForTreeExit(Job, 0),
			"a live suspended process must prevent cleanup even with a zero timeout")
		AssertTrue(_SR_TreeQuiesceNative(Owner, true))
		AssertTrue(_USTX_WaitForTreeExit(Job, 0),
			"an already empty tree must complete without a fixed settle period")
		AssertTrue(_USTX_CloseFixtureTree(Job, 0))
		Job := 0
	} finally {
		if IsObject(Owner)
			AssertTrue(_SR_TreeQuiesceNative(Owner, true))
		if Job
			AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", Job, "Int"))
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("updater fixture: tree waits distinguish live empty and failed accounting (updater-fixture-tree-wait)",
	_USCL_TreeWaitObservesNativeState)

_USCL_TreeCleanupRetainsFailure() {
	AssertThrows(() => _USTX_CloseFixtureTree(-1, 0),
		"a failed native cleanup must fail an otherwise successful case")
	Failure := Error("primary fixture failure")
	AssertFalse(_USTX_CloseFixtureTree(0, Failure),
		"failed accounting must prevent fixture deletion")
	AssertTrue(InStr(Failure.Message, "primary fixture failure") > 0)
	AssertTrue(InStr(Failure.Message, "requires its owned job handle") > 0,
		"the accounting failure must remain visible beside the primary error")
	AssertTrue(InStr(Failure.Message, "job handle close failed") > 0,
		"native handle release failures must remain visible")
}
Test("updater fixture: tree cleanup preserves native and primary failures (updater-fixture-tree-failure)",
	_USCL_TreeCleanupRetainsFailure)
