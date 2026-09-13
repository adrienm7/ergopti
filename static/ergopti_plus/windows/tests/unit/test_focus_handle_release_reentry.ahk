; static/ergopti_plus/windows/tests/unit/test_focus_handle_release_reentry.ahk

; Direct releases must share the same exclusive cleanup owner as reset/drain.
_FHR_ReentrantRelease(AcceptClose) {
	Saved := Map()
	for Name in ["process_id", "process_handle", "process_name", "generation",
		"cleanup_debt", "cleanup_draining", "acquire_fn", "alive_fn", "close_fn"]
		Saved[Name] := WIFocusProcessCache.%Name%
	State := { attempts: 0, nested: true }
	Close := (Handle) => _FHR_CloseDuringRelease(State, AcceptClose, Handle)
	try {
		WIFocusProcessCache.process_id := 0
		WIFocusProcessCache.process_handle := 0
		WIFocusProcessCache.process_name := ""
		WIFocusProcessCache.cleanup_debt := []
		WIFocusProcessCache.cleanup_draining := false
		WIFocusProcessCache.close_fn := Close
		Result := _WIFocusReleaseProcessHandle(9102)
		AssertEqual(1, State.attempts,
			"a reentrant drain must not close a handle already being released")
		AssertFalse(State.nested,
			"nested cleanup must report that the outer close still owns the handle")
		AssertEqual(AcceptClose, Result)
		AssertFalse(WIFocusProcessCache.cleanup_draining)
		AssertEqual(AcceptClose ? 0 : 1, WIFocusProcessCache.cleanup_debt.Length)
		if !AcceptClose {
			AssertEqual(9102, WIFocusProcessCache.cleanup_debt[1])
			WIFocusProcessCache.close_fn := (*) => true
			AssertTrue(_WIFocusDrainProcessCleanupDebt(),
				"a refused outer close must remain retryable")
		}
	} finally {
		for Name, Value in Saved
			WIFocusProcessCache.%Name% := Value
	}
}

_FHR_CloseDuringRelease(State, AcceptClose, Handle) {
	AssertEqual(9102, Handle)
	State.attempts += 1
	if State.attempts = 1
		State.nested := _WIFocusDrainProcessCleanupDebt()
	return AcceptClose
}

Test("metrics focus: successful direct release excludes nested cleanup "
	. "(focus-handle-release-reentry)", () => _FHR_ReentrantRelease(true))
Test("metrics focus: refused direct release excludes nested cleanup "
	. "(focus-handle-release-reentry)", () => _FHR_ReentrantRelease(false))
