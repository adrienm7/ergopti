; tests/unit/test_llm_hotkeys_deferred_by_pause.ahk

; ==============================================================================
; MODULE: The AI hotkeys of a menu first built under a pause wait for the resume
; DESCRIPTION:
; Regression for llm-hotkeys-deferred-by-pause (2026-10-01). A driver reloaded
; while paused builds its first tray root under the restored pause. That build
; activates the AI profile and navigation hotkeys, and the native navigation
; owner, suspended by the pause, refuses every plan: the build failed three
; times, the root was retired and the paused driver had no menu. The hotkeys
; cannot fire under a pause, so the first build defers them and the resume
; activates them.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body(Calls) with the deferred flag cleared, then restores it.
_LHDP_Run(Body) {
	global _LLM_Menu_FirstRestoreHotkeysDeferred
	Saved := _LLM_Menu_FirstRestoreHotkeysDeferred
	try {
		_LLM_Menu_FirstRestoreHotkeysDeferred := false
		Body({ Profile: 0, Nav: 0, Activate: 0, Scheduled: [] })
	} finally {
		_LLM_Menu_FirstRestoreHotkeysDeferred := Saved
	}
}

_LHDP_ProfilePort(Calls) {
	global _LLM_PROFILE_HOTKEY_STATUS_READY
	Calls.Profile += 1
	return _LLM_PROFILE_HOTKEY_STATUS_READY
}

_LHDP_NavPort(Calls) {
	Calls.Nav += 1
	return true
}

_LHDP_PausedFirstBuildDefersTheHotkeys() {
	_LHDP_Run(_Body)
	_Body(Calls) {
		global _LLM_Menu_FirstRestoreHotkeysDeferred
		Profile := _LHDP_ProfilePort.Bind(Calls)
		Nav := _LHDP_NavPort.Bind(Calls)
		AssertTrue(_LLM_Menu_RequireFirstRestoreHotkeys(true, Profile, Nav, true),
			"a first build under a pause must not fail on its hotkeys (llm-hotkeys-deferred-by-pause)")
		AssertEqual(0, Calls.Profile + Calls.Nav,
			"no hotkey owner may be asked for a plan under a pause")
		AssertTrue(_LLM_Menu_FirstRestoreHotkeysDeferred,
			"the activation must be recorded for the resume")

		_LLM_Menu_FirstRestoreHotkeysDeferred := false
		AssertTrue(_LLM_Menu_RequireFirstRestoreHotkeys(false, Profile, Nav, true),
			"a later build under a pause has nothing to activate")
		AssertFalse(_LLM_Menu_FirstRestoreHotkeysDeferred,
			"only the first build defers")

		AssertTrue(_LLM_Menu_RequireFirstRestoreHotkeys(true, Profile, Nav, false),
			"an active driver activates its hotkeys in the first build")
		AssertEqual(1, Calls.Profile, "the profile hotkeys are bound once")
		AssertEqual(1, Calls.Nav, "the navigation hotkeys are bound once")
		AssertFalse(_LLM_Menu_FirstRestoreHotkeysDeferred,
			"an active first build defers nothing")
	}
}
Test("LLM menu: a first build under a pause defers the AI hotkeys (llm-hotkeys-deferred-by-pause)",
	_LHDP_PausedFirstBuildDefersTheHotkeys)

_LHDP_ResumeActivatesTheDeferredHotkeys() {
	_LHDP_Run(_Body)
	_Body(Calls) {
		global _LLM_Menu_FirstRestoreHotkeysDeferred
		Activate := () => (Calls.Activate += 1, true)
		Schedule := (Retry, DelayMs) => Calls.Scheduled.Push(Retry)
		AssertTrue(LLM_Menu_ActivateDeferredHotkeys(Activate, 1, Schedule, false),
			"nothing deferred means nothing to do")
		AssertEqual(0, Calls.Activate)

		_LLM_Menu_FirstRestoreHotkeysDeferred := true
		AssertFalse(LLM_Menu_ActivateDeferredHotkeys(Activate, 1, Schedule, true),
			"a driver paused again keeps the activation for the next resume")
		AssertEqual(0, Calls.Activate)
		AssertTrue(_LLM_Menu_FirstRestoreHotkeysDeferred)

		AssertTrue(LLM_Menu_ActivateDeferredHotkeys(Activate, 1, Schedule, false),
			"the resume must activate the deferred hotkeys (llm-hotkeys-deferred-by-pause)")
		AssertEqual(1, Calls.Activate)
		AssertFalse(_LLM_Menu_FirstRestoreHotkeysDeferred,
			"an activated surface is no longer deferred")
		AssertEqual(0, Calls.Scheduled.Length, "a success schedules no retry")
	}
}
Test("LLM menu: the resume activates the AI hotkeys a pause deferred (llm-hotkeys-deferred-by-pause)",
	_LHDP_ResumeActivatesTheDeferredHotkeys)

_LHDP_RefusedActivationRetriesThenSucceeds() {
	_LHDP_Run(_Body)
	_Body(Calls) {
		global _LLM_Menu_FirstRestoreHotkeysDeferred
		; The native owner is still finishing its resume on the first attempt.
		Activate := () => (Calls.Activate += 1, Calls.Activate >= 2)
		Schedule := (Retry, DelayMs) => Calls.Scheduled.Push(Retry)
		_LLM_Menu_FirstRestoreHotkeysDeferred := true
		AssertFalse(LLM_Menu_ActivateDeferredHotkeys(Activate, 1, Schedule, false),
			"a refused activation is not a success")
		AssertTrue(_LLM_Menu_FirstRestoreHotkeysDeferred,
			"a refused activation stays owed")
		AssertEqual(1, Calls.Scheduled.Length, "a refused activation is retried once")
		Calls.Scheduled[1].Call()
		AssertEqual(2, Calls.Activate)
		AssertFalse(_LLM_Menu_FirstRestoreHotkeysDeferred,
			"the retry that succeeds ends the debt")
		AssertEqual(1, Calls.Scheduled.Length, "a success schedules no further retry")
	}
}
Test("LLM menu: a refused deferred activation is retried (llm-hotkeys-deferred-by-pause)",
	_LHDP_RefusedActivationRetriesThenSucceeds)
